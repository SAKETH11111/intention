import AppKit
import ApplicationServices
import Foundation
import os

/// Follows the text cursor in whichever app has keyboard focus, so the Own
/// Hand dot can rest above it.
///
/// It reads the focused element, whether it is a secure or editable field,
/// its selected range, the caret's screen bounds and the color of the text
/// beside the caret. Accessibility returns that color with its character;
/// the character is dropped at once and never kept or logged. A secure
/// field is recognised from its subrole before anything else is read.
///
/// Notifications from the focused app give prompt updates as the person
/// types, clicks and switches fields. Scrolling moves the caret without a
/// notification, so the owner also calls `refresh()` on a short interval.
///
/// The tracker has its own executor thread, so a slow app delays only the
/// dot. Native objects and the fields below are used only on that thread.
final class CaretTracker: @unchecked Sendable {
    private let executor = AccessibilityExecutor(capacity: 2)
    /// The caret and the frame of the field it is in, in Accessibility
    /// coordinates.
    struct Reading: Equatable, Sendable {
        var caret: CGRect
        var field: CGRect?
        /// The text's color beside the caret, or the last color seen in the
        /// same app when the field is empty.
        var ink: Ink?
    }

    struct Observation: Equatable, Sendable {
        /// Whether a missing reading means there is no caret to mark, or
        /// only that this read could not place one.
        typealias Status = CaretEvidenceStatus
        var reading: Reading?
        var visualTarget: VisualCaretTarget?
        var pid: pid_t?
        var generation: Int
        var startedAt: ContinuousClock.Instant
        var status: Status = .absent
        /// A writable field still has focus when a selection leaves no caret.
        var fieldFocused = false
        /// Changes whenever the focused text element changes.
        var focus: Int = 0
        /// Cached metadata-only classification for this focus identity.
        var isEmailBody = false
        /// Changes whenever the focused field's text or selection changes,
        /// so a watcher can tell a field the person is writing in.
        var edit: Int = 0
        /// Selection sampled by this observation, for notice-bound proposal reads.
        var selection: FieldRange? = nil
        /// The already-read body frame, including when a selection has no caret.
        var fieldFrame: CGRect? = nil
        /// An estimate shown while unresolved, until pixels confirm the
        /// caret: an empty rich editor's first line.
        var hint: Reading?
        /// The caret is in another app's floating panel, such as a launcher,
        /// which holds keyboard focus while the frontmost app stays in front.
        var panel = false
    }

    private let requiredWindowTitle: String?
    private let requiredPID: pid_t?
    private let requiredWindowID: CGWindowID?
    private let onChange: @Sendable (Observation) -> Void
    private let emailBody: CaretEmailBody
    private let onInvalidation: @Sendable () -> Void
    private var visualTarget: VisualCaretTarget?
    private var status: Observation.Status = .absent
    private var fieldFocused = false
    private var observedFieldFrame: CGRect?
    private var observedSelection: FieldRange?
    private var hint: Reading?
    private var reason = "absent.start"
    private var loggedReason: String?
    private var focusSerial = 0
    private var focusedAt: TimeInterval = 0
    /// The element `focusSerial` counts. Notifications clear the cached
    /// facts, but only a different element is a new field.
    private var focusIdentity: AXElement?
    /// The process whose floating panel holds keyboard focus this read.
    private var panelOwner: pid_t?
    /// When the focused app last reported a text or selection change.
    private let changedAt = OSAllocatedUnfairLock<TimeInterval>(initialState: 0)
    /// Counts the watched field's own text and selection notifications,
    /// for `Observation.edit`; another control's are not counted
    /// (`FieldEditNotice`).
    private let editSerial = OSAllocatedUnfairLock<Int>(initialState: 0)
    private var generatedCache: (element: AXElement, count: Int, generated: Bool)?
    private let pendingStart = OSAllocatedUnfairLock<(target: VisualCaretTarget, caret: CGRect)?>(initialState: nil)
    /// The caret pixels last placed the dot at, and the focus it was for,
    /// so a read can tell when something comes over it; see `noteShown`.
    /// Each reading has a serial of its own, so one found again at the same
    /// place is told from the one before.
    private let shownCaret = OSAllocatedUnfairLock<(reading: (focus: Int, caret: CGRect)?, serial: Int)>(initialState: (nil, 0))
    /// The field's and window's frames when the reading with `serial` was
    /// first seen, to forget it once they have moved from there, however
    /// slowly.
    private var pixelFrames: (serial: Int, field: CGRect?, window: CGRect?)?
    /// A native menu of the observed app is open. It holds the keyboard
    /// while it is, so the caret is not where typing goes, even where the
    /// menu does not cover it. Set from the app's menu notifications and
    /// cleared by the menu closing, a change of focus, window or app, the
    /// field's text or selection changing, or a click, so a close that
    /// never arrives cannot hide the dot for good.
    private var menuOpen = false
    private var menuOpenedAt: TimeInterval = 0
    /// When the person last clicked, from the controller; see `noteClick`.
    private let clickedAt = OSAllocatedUnfairLock<TimeInterval>(initialState: 0)
    /// What a caret pixels placed depends on: the focus, the selection, the
    /// field's and window's frames and the last edit or click.
    private struct PixelState: Equatable {
        var focus: Int
        var location: Int?
        var field: CGRect?
        var window: CGRect?
        var changed: TimeInterval
    }
    /// That state at the last read the caret was not covered, and as it was
    /// when a cover began: uncovering with all of it unchanged puts the dot
    /// straight back where pixels last found it.
    private var lastUncovered: PixelState?
    private var coveredFrom: PixelState?
    /// The focused field's ancestors up to its window, read once per field,
    /// for telling where the element at the caret meets them.
    private var ancestry: (field: AXElement, ancestors: [AXElement])?
    private var readWasSuperseded = false
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    /// The frontmost app, from AppKit on the main thread.
    private let frontmost = OSAllocatedUnfairLock<(pid: pid_t?, generation: Int)>(initialState: (nil, 0))

    private var observer: AXObserver?
    private var observedPID: pid_t?
    /// The frontmost app whose accessibility tree was requested this
    /// activation, see `prepare`.
    private var preparedPID: pid_t?
    /// Which focus check failed, for the outcome log.
    private var focusMiss = ""
    /// When the frontmost app was last asked for its accessibility tree.
    private var preparedAt: TimeInterval = 0
    /// Processes whose windows were found bare, see `opaqueTarget`.
    private var opaquePIDs: Set<pid_t> = []
    /// Whether a window exposed no text control or web area, cached briefly.
    private var opaqueCache: (window: AXElement, opaque: Bool, at: ContinuousClock.Instant)?
    /// The floating panel window whose frame last matched its window
    /// server bounds, see `keyboardFocus`.
    private var acceptedPanel: (pid: pid_t, window: AXElement)?
    /// When fresh frames last confirmed a caret outside them. Cached frames
    /// are then not read again for `refusalInterval`, so a caret scrolled
    /// out of view does not defeat the cache.
    private var outsideConfirmedAt = ContinuousClock.now - .seconds(1)
    /// The element whose last reading fell outside its field, see `caret`.
    private var outsideElement: AXElement?
    private var chromeBootstrapAttempts = 0
    private var chromeBootstrapNextAttempt = ContinuousClock.now
    private var observedElement: AXElement?
    private let readRequests = OSAllocatedUnfairLock(initialState: CaretReadRequests())
    /// Whether pixels can confirm an estimate: capture on and Screen
    /// Recording granted, from the controller. A flat control's estimate is
    /// shown only then, since its frame alone does not say where the caret
    /// is, and pixels correct it within a moment or not at all.
    private let pixelsCanConfirm = OSAllocatedUnfairLock(initialState: false)
    func setPixelsCanConfirm(_ can: Bool) { pixelsCanConfirm.withLock { $0 = can } }
    /// The last text color seen per app, for empty fields, with the field it
    /// was read in. A web page's colors are its own, so a web field reuses
    /// only its own last color, as an emptied composer does; before October
    /// 7, 2026 an empty Gmail body took the white of a dark page in another
    /// tab, and its dot could not be seen. A native app's fields share theirs.
    private var lastInk: [pid_t: (field: AXElement, web: Bool, ink: Ink)] = [:]

    /// The color an empty field may borrow: its own last color, or for a
    /// native field the app's last.
    private func rememberedInk(pid: pid_t, field: AXElement, web: Bool) -> Ink? {
        guard let last = lastInk[pid] else { return nil }
        if web || last.web { return last.field.sameElement(as: field) ? last.ink : nil }
        return last.ink
    }
    /// How each app's native text reports collapsed ranges, learned from
    /// characters on the caret's line.
    private var collapsedModes: [pid_t: CaretBounds.CollapsedMode] = [:]
    /// Where the focused web control's text starts, remembered while it has
    /// text so the caret stays marked once the control is emptied.
    private var webStart: (element: AXElement, field: CGRect?, caret: CGRect)?
    /// Facts about the focused element that only change with focus or
    /// window geometry, cached so each read costs few messages.
    private var element: ElementFacts?

    private struct ElementFacts {
        let element: AXElement
        /// Admitted as an editable, non-secure text control in an allowed
        /// window. An admission is fixed for the element's lifetime; a
        /// refusal is retried briefly after focus, see `refusalRetry`.
        let usable: Bool
        /// Why the element was refused, for the outcome log.
        let refusal: String?
        let admittedAt: ContinuousClock.Instant
        let isWeb: Bool
        /// A web area that is itself the editable text, as Mail's message
        /// body is. It reports its selection only as text markers.
        let document: Bool
        let pid: pid_t
        let window: AXElement?
        let windowFrame: CGRect?
        let frames: [CGRect]
        let field: CGRect?
        /// Read once per refresh of these facts; the text's color rarely
        /// changes within a field.
        var ink: Ink?
        var readAt: ContinuousClock.Instant
    }

    /// How long cached element and window frames stay trusted before a read
    /// fetches them again. Moves and resizes also refresh them.
    static let framesLifetime: Duration = .milliseconds(500)
    /// A panel or page can answer for a field before its ancestry and
    /// editability are complete, as Spotlight does while it opens. For this
    /// long after focus, a refusal is checked again every `refusalInterval`.
    static let refusalRetry: TimeInterval = 1.5
    static let refusalInterval: Duration = .milliseconds(100)

    /// Delivers a fresh observation on the tracker thread for each refresh.
    /// The caller rejects old input generations and expired observations.
    init(requiredWindowTitle: String? = nil, requiredPID: pid_t? = nil, requiredWindowID: CGWindowID? = nil, onInvalidation: @escaping @Sendable () -> Void = {}, onEmailBody: @escaping @Sendable (CaretEmailBody.Focus, Bool) -> Void = { _, _ in }, onChange: @escaping @Sendable (Observation) -> Void) {
        self.requiredWindowTitle = requiredWindowTitle
        self.requiredPID = requiredPID
        self.requiredWindowID = requiredWindowID
        self.onChange = onChange
        self.emailBody = CaretEmailBody(changed: onEmailBody)
        self.onInvalidation = onInvalidation
    }

    /// Reads the caret now, in the frontmost app. Skipped when reads are
    /// already queued, such as while an app is slow to answer, and while
    /// paused.
    func refresh(frontmost pid: pid_t?, generation: Int) {
        frontmost.withLock { $0 = (pid, generation) }
        scheduleRead()
    }

    /// Stops reading until `resume`, as while the dot is not the chosen
    /// indicator or the screen is locked: no refresh and no notification
    /// from the focused app starts a read, a read already queued is
    /// skipped, and the app stops being observed. What was cached about
    /// its field is dropped, since notifications that would have renewed
    /// it no longer arrive.
    func pause() {
        guard readRequests.withLock({ $0.pause() }) else { return }
        // After any read already running, on the thread that owns the observer.
        executor.submitCleanup {
            self.follow(nil)
            self.preparedPID = nil
            self.element = nil
            self.focusIdentity = nil
            self.emailBody.observe(nil, element: nil)
        }
    }

    func resume() {
        readRequests.withLock { $0.resume() }
    }

    /// Polling and notifications share one outstanding read. Repeated ticks
    /// must leave queue capacity for the capture's fresh validation checks.
    private func scheduleRead() {
        guard readRequests.withLock({ $0.request() }) else { return }
        enqueueRead()
    }

    private func enqueueRead() {
        let queued = executor.submit { expired in
            let (revision, paused) = self.readRequests.withLock { ($0.begin(), $0.paused) }
            if !expired, !paused { self.read() }
            // Defer scheduling until this executor slot has been released.
            // This closure only schedules; it makes no Accessibility calls.
            self.executor.submitCleanup {
                if self.readRequests.withLock({ $0.finish(revision) }) { self.enqueueRead() }
            }
        }
        if !queued { readRequests.withLock { $0.rejected() } }
    }

    private func read() {
        precondition(executor.isCurrent)
        let generation = frontmost.withLock { $0.generation }
        let startedAt = ContinuousClock.now
        visualTarget = nil
        status = .absent
        fieldFocused = false
        readWasSuperseded = false
        reason = "absent.none"
        hint = nil
        observedSelection = nil
        observedFieldFrame = nil
        let reading = caret()
        if reading != nil { reason = "placed" }
        if reason != loggedReason {
            loggedReason = reason
            AppLog.caret(reason)
            #if DEBUG
            DotLog.tracker(reason)
            if requiredPID != nil {
                let outcome = reason
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { CaretFixtureMode.diagnostic("tracker " + outcome) }
                }
            }
            #endif
        }
        #if DEBUG
        if requiredPID != nil {
            let elapsed = startedAt.duration(to: .now)
            let components = elapsed.components
            let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
            DispatchQueue.main.async {
                MainActor.assumeIsolated { CaretFixtureMode.diagnostic("ax-read", duration: seconds) }
            }
        }
        #endif
        if readWasSuperseded {
            // Coalescing schedules one immediate follow-up after this read.
            // No observation is published, so retained native evidence keeps
            // its original timestamp rather than receiving a stale renewal.
            scheduleRead()
            return
        }
        let emailFocus = observedPID.map { CaretEmailBody.Focus(serial: focusSerial, pid: $0) }
        onChange(Observation(reading: reading, visualTarget: visualTarget, pid: observedPID,
                             generation: generation, startedAt: startedAt,
                             status: reading == nil ? status : .placed, fieldFocused: fieldFocused, focus: focusSerial,
                             isEmailBody: fieldFocused && (emailFocus.map { emailBody.result(for: $0) } ?? false),
                             edit: editSerial.withLock { $0 }, selection: observedSelection, fieldFrame: observedFieldFrame,
                             hint: reading == nil ? hint : nil, panel: panelOwner != nil))
        emailBody.observe(focusIdentity == nil ? nil : emailFocus, element: focusIdentity)
    }

    /// A fresh identity and geometry check around every asynchronous
    /// capture. Nil when the reader was too busy to run it, which is not a
    /// denial: the caller skips this round.
    func validate(_ target: VisualCaretTarget) async -> Bool? {
        await withCheckedContinuation { continuation in
            let accepted = executor.submit(deadline: .now + .milliseconds(200)) { expired in
                guard !expired else { continuation.resume(returning: nil); return }
                if target.opaque {
                    // Still the same bare window of the frontmost app, which
                    // still answers that nothing has keyboard focus.
                    let window = try? AXElement.application(target.pid).element(kAXFocusedWindowAttribute).get()
                    continuation.resume(returning: AXIsProcessTrusted()
                        && self.frontmost.withLock({ $0.pid }) == target.pid
                        && self.keyboardFocus(front: target.pid) == nil && self.focusMiss == ".app.none"
                        && window.map { $0.sameElement(as: target.window) } == true
                        && window.flatMap { try? $0.frame().get() } == target.windowFrame
                        && self.allowedWindow(target.window, pid: target.pid, frame: target.windowFrame)
                        && self.opaque(target.window))
                    return
                }
                guard AXIsProcessTrusted(),
                      self.frontmost.withLock({ $0.pid }) == target.pid,
                      let focused = self.keyboardFocus(front: target.pid)?.element, focused.sameElement(as: target.element),
                      let metadata = self.windowMetadata(for: focused, pid: target.pid),
                      metadata.window.sameElement(as: target.window), metadata.frame == target.windowFrame
                else { continuation.resume(returning: false); return }
                let admitted = self.element.map { $0.usable && $0.element.sameElement(as: focused) } ?? false
                // The boundary must be unchanged; typing may move the
                // selection within it.
                continuation.resume(returning: VisualCaretTarget.read(focused, pid: target.pid, admitted: admitted)
                    .map { $0.sameBoundary(as: target) } == true
                    && self.allowedWindow(target.window, pid: target.pid, frame: target.windowFrame))
            }
            if !accepted { continuation.resume(returning: nil) }
        }
    }

    /// Metadata only: this must precede any field selection, character,
    /// marker, or anchor read, including capture's independent validation.
    private func windowMetadata(for focused: AXElement, pid: pid_t) -> (window: AXElement, frame: CGRect)? {
        guard ownsKeyboard(pid),
              requiredPID == nil || requiredPID == pid,
              let window = try? focused.element(kAXWindowAttribute).get(),
              let currentWindow = try? AXElement.application(pid).element(kAXFocusedWindowAttribute).get(),
              currentWindow.sameElement(as: window),
              let frame = try? window.frame().get(),
              frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0,
              allowedWindow(window, pid: pid, frame: frame),
              ownsKeyboard(pid) else { return nil }
        return (window, frame)
    }

    /// The frontmost app, or the owner of the floating panel found this read.
    private func ownsKeyboard(_ pid: pid_t) -> Bool {
        frontmost.withLock({ $0.pid }) == pid || panelOwner == pid
    }

    /// Demonstrations constrain reads to the exact fixture title and pinned
    /// WindowServer PID/ID/frame, not merely to another window in the same app.
    private func allowedWindow(_ window: AXElement, pid: pid_t, frame: CGRect) -> Bool {
        guard requiredPID == nil || requiredPID == pid else { return false }
        if let requiredWindowTitle {
            guard (try? window.string(kAXTitleAttribute).get()) == requiredWindowTitle else { return false }
        }
        if let requiredWindowID {
            guard let windows = CGWindowListCopyWindowInfo([.optionIncludingWindow, .excludeDesktopElements], requiredWindowID) as? [[String: Any]],
                  windows.count == 1, let entry = windows.first,
                  (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value == requiredWindowID,
                  let bounds = entry[kCGWindowBounds as String] as? [String: NSNumber],
                  CGRect(dictionaryRepresentation: bounds as CFDictionary) == frame else { return false }
        }
        return true
    }

    private func caret() -> Reading? {
        panelOwner = nil
        guard AXIsProcessTrusted() else {
            reason = "absent.untrusted"
            follow(nil)
            preparedPID = nil
            return nil
        }
        guard let front = frontmost.withLock({ $0.pid }), front != ownPID else {
            reason = "absent.application"
            follow(nil)
            preparedPID = nil
            element = nil
            focusIdentity = nil
            return nil
        }
        // Bootstrap a Chromium browser's AX tree before asking for its focused web field.
        // This touches only application/window metadata, never field contents.
        let frontAllowed = requiredPID == nil || requiredPID == front
        focusMiss = ""
        if frontAllowed { prepare(front) } else { preparedPID = nil }
        guard let (focused, pid) = keyboardFocus(front: front) else {
            reason = "absent.focus" + focusMiss
            if focusMiss == ".panel.changing" {
                reason = "unresolved.panelChanging"
                status = .unresolved
                panelOwner = acceptedPanel?.pid
                return nil
            }
            follow(frontAllowed ? front : nil)
            element = nil
            // An app that exposes no accessible text at all, as Codex's
            // Electron fork does: its focused window is the pixel target.
            if frontAllowed, focusMiss == ".app.none", let opaque = opaqueTarget(front) {
                reason = "unresolved.opaque"
                status = .unresolved
                visualTarget = opaque
                // The window is the field here; its parked caret can be
                // covered like any other.
                coverUnresolved(field: opaque.window, pid: front, window: opaque.window, fieldFrame: opaque.windowFrame,
                                windowFrame: opaque.windowFrame, location: nil)
                return nil
            }
            focusIdentity = nil
            return nil
        }
        if pid != front { panelOwner = pid }
        guard pid != ownPID, ownsKeyboard(pid), requiredPID == nil || requiredPID == pid else {
            reason = "absent.focusProcess"
            follow(nil)
            element = nil
            focusIdentity = nil
            return nil
        }
        // One process is observed per read: the panel owner while a panel
        // has the keyboard, otherwise the frontmost app.
        follow(pid)
        // Security, ancestry and window admission precede every selection,
        // character or geometry read. They are cached per element and the
        // window facts are refreshed on focus and window notifications.
        guard var facts = facts(for: focused, pid: pid) else {
            reason = "absent.window"
            return nil
        }
        guard facts.usable else {
            reason = "absent.notWritable." + (facts.refusal ?? "unknown")
            return nil
        }
        // Admission is cached, but a field or a wrapper around it can turn
        // secure in place, as a page's show-password toggle does. The field
        // and every ancestor up to its window are checked again before any
        // selection, character or geometry read. A secure one drops the
        // admission, so the next read refuses the element; one that fails
        // to answer reads nothing more this time and holds the last position
        // as any unresolved read does.
        switch facts.window.flatMap({ AXWritingSurface.secureAncestry(focused, window: $0) }) {
        case false?:
            break
        case true?:
            reason = "absent.secure"
            element = nil
            return nil
        case nil:
            reason = "unresolved.secureUnknown"
            status = .unresolved
            return nil
        }
        observeElement(focused)
        if menuShown() {
            reason = "absent.menu"
            return nil
        }
        fieldFocused = true
        observedFieldFrame = facts.field
        let selection: FieldRange
        switch selectedRange(of: focused, facts: facts) {
        case let .success(range):
            observedSelection = range
            // A selection has no insertion point to mark.
            guard range.location >= 0, range.length == 0 else {
                reason = "absent.selection"
                return nil
            }
            selection = range
        case let .failure(error) where error.code == .attributeUnsupported || error.code == .noValue:
            reason = "unresolved.noSelection"
            status = .unresolved
            visualTarget = visualCandidate(focused, pid: pid, facts: facts)
            coverUnresolved(field: focused, pid: pid, window: facts.window, fieldFrame: facts.field,
                            windowFrame: facts.windowFrame, location: nil, caret: facts.isWeb ? caretPlace(in: focused) : nil)
            return nil
        default:
            reason = "unresolved.selectionError"
            status = .unresolved
            return nil
        }
        status = .unresolved
        guard let caret = resolve(focused, at: selection.location, facts: facts) else {
            reason = "unresolved.geometry"
            if facts.isWeb, selection.location == 0 || emptyText(focused) || generatedPlaceholder(focused, at: selection.location),
               let line = CaretBounds.emptyEditorLine(in: focused, field: facts.field) {
                hint = Reading(caret: line, field: facts.field, ink: facts.ink ?? rememberedInk(pid: pid, field: focused, web: facts.isWeb))
            }
            // An editor that keeps focus in a control a point wide and a line
            // tall, moved to the caret, as Monaco does, or a control with a
            // width and no height, as Gmail's empty compose body: that frame,
            // read afresh each time since it moves with every key, is the
            // estimate, and pixels in a band around it confirm the caret.
            // The control's frame says nothing about the editor's surface,
            // so the page's own elements beside it never count as a cover
            // for it; another window, another app and a covering role do.
            // The fresh frame still says when the control has moved.
            var coverFrame = facts.field
            var besideCovers = true
            if facts.isWeb, hint == nil, case let .success(frame) = focused.frame() {
                if let line = CaretBounds.caretFromControlFrame(frame) {
                    reason = "unresolved.controlFrame"
                    hint = Reading(caret: line, field: frame, ink: rememberedInk(pid: pid, field: focused, web: true))
                    coverFrame = frame
                    besideCovers = false
                } else if pixelsCanConfirm.withLock({ $0 }), let line = CaretBounds.flatControlLine(frame) {
                    reason = "unresolved.flatFrame"
                    hint = Reading(caret: line, field: nil, ink: rememberedInk(pid: pid, field: focused, web: true))
                    coverFrame = frame
                    besideCovers = false
                }
            }
            // Visual confirmation replaces guesses where Accessibility has
            // no geometry, including a web control's first focus.
            visualTarget = visualCandidate(focused, pid: pid, facts: facts)
            // A flat control's estimate stands only with pixels to confirm it,
            // and only where its line lies inside the band they will see,
            // which is clipped to the window and the scroll views: one
            // scrolled out of view, in whole or in part, or without an editor
            // around it, gets no estimate, rather than a dot nothing checks.
            if reason == "unresolved.flatFrame",
               visualTarget.flatMap({ target in hint.map { target.field.insetBy(dx: -1, dy: -1).contains(CGRect(x: $0.caret.minX, y: $0.caret.minY, width: 0.5, height: $0.caret.height)) } }) != true {
                hint = nil
                reason = "unresolved.geometry"
            }
            coverUnresolved(field: focused, pid: pid, window: facts.window, fieldFrame: coverFrame,
                            windowFrame: facts.windowFrame, location: selection.location,
                            caret: facts.isWeb ? caretPlace(in: focused) : nil, besideCovers: besideCovers)
            return nil
        }
        let point = CGPoint(x: caret.minX, y: caret.midY)
        // A caret scrolled out of its field or window reports bounds outside
        // them; the dot would float over something else. Cached frames can
        // predate a field that just moved, so they are read again first.
        func inside(_ facts: ElementFacts) -> Bool { facts.frames.allSatisfy { $0.insetBy(dx: -4, dy: -4).contains(point) } }
        if !inside(facts), ContinuousClock.now - facts.readAt > .milliseconds(2),
           ContinuousClock.now - outsideConfirmedAt >= Self.refusalInterval {
            element?.readAt = .now - Self.framesLifetime
            guard let fresh = self.facts(for: focused, pid: pid), fresh.usable else {
                reason = "absent.window"
                status = .absent
                return nil
            }
            facts = fresh
            if !inside(facts) { outsideConfirmedAt = .now }
        }
        guard inside(facts) else {
            // One reading outside the field between readings inside it is
            // a transient answer while the text changes, as Terminal gives
            // during deletion: the last position holds for that read. A
            // second in a row is a caret scrolled out of view.
            if outsideElement?.sameElement(as: focused) != true {
                outsideElement = focused
                reason = "unresolved.outsideOnce"
                status = .unresolved
                return nil
            }
            reason = facts.field.map { $0.insetBy(dx: -4, dy: -4).contains(point) } == false ? "absent.outside.field" : "absent.outside.window"
            status = .absent
            return nil
        }
        outsideElement = nil
        // A placeholder's color is not the text's: a field whose only text is
        // its placeholder, or none, keeps no ink until something is typed.
        // WebKit answers a hint's character for an empty body's first range.
        if facts.ink == nil, !(facts.isWeb && (generatedPlaceholder(focused, at: selection.location) || emptyText(focused))) {
            facts.ink = CaretBounds.ink(in: focused, at: selection.location)
            element?.ink = facts.ink
        }
        // Where the caret's own text is, read before the check below so the
        // two belong to the same selection.
        let place = facts.isWeb ? caretPlace(in: focused) : nil
        // A key can edit the field during the geometry calls. Never publish
        // that mixed observation; a follow-up read runs at once.
        guard let currentSelection = try? selectedRange(of: focused, facts: facts).get() else {
            reason = "unresolved.selectionRecheck"
            return nil
        }
        guard currentSelection == selection else {
            reason = "superseded"
            readWasSuperseded = true
            return nil
        }
        // Something drawn over the caret, such as a menu or popover, hides
        // the dot until the caret shows again.
        if covered(caret, place: place, focused: focused, pid: pid, facts: facts) {
            reason = "absent.covered"
            status = .absent
            return nil
        }
        if let ink = facts.ink { lastInk[pid] = (focused, facts.isWeb, ink) }
        return Reading(caret: caret, field: facts.field, ink: facts.ink ?? rememberedInk(pid: pid, field: focused, web: facts.isWeb))
    }

    /// Whether something the person can see is drawn over `caret`, from the
    /// element the window server finds at its middle (`CaretCover`). One
    /// that cannot be told counts as uncovered.
    private func covered(_ caret: CGRect, place: CaretPlace?, focused: AXElement, pid: pid_t, facts: ElementFacts) -> Bool {
        cover(at: CGPoint(x: caret.midX, y: caret.midY), field: focused, fieldFrame: facts.field, window: facts.window, pid: pid,
              caret: place) == true
    }

    /// Where a web field's caret is: the element that holds that position,
    /// with its ancestors up to and including the field.
    private struct CaretPlace {
        let elements: [AXElement]

        func index(of element: AXElement) -> Int? { elements.firstIndex { $0.sameElement(as: element) } }

        /// Whether a menu, dialog or tooltip holds the caret from `index` up.
        /// Roles are read each time, since a page can turn an element into
        /// a tooltip, and a read that failed is tried again next time.
        func refused(from index: Int) -> Bool {
            CaretCover.refused(elements[index...].map { element in
                let role = (try? element.string(kAXRoleAttribute).get()) ?? ""
                return (role, role == kAXGroupRole ? try? element.string(kAXSubroleAttribute).get() : nil)
            })
        }
    }

    /// The caret's place from the field's selection markers, through
    /// `AXUIElementForTextMarker` at their start. Nil when the field has no
    /// markers, the selection is not a caret, or the walk does not reach
    /// the field.
    private func caretPlace(in field: AXElement) -> CaretPlace? {
        guard case let .success(selection) = field.value("AXSelectedTextMarkerRange"),
              CFGetTypeID(selection) == AXTextMarkerRangeGetTypeID() else { return nil }
        let markers = selection as! AXTextMarkerRange
        let start = AXTextMarkerRangeCopyStartMarker(markers)
        // A caret, as the read found a moment ago, and not a selection since,
        // measured both ways since WebKit measures a backward range as empty.
        let end = AXTextMarkerRangeCopyEndMarker(markers)
        guard field.length(from: start, to: end) == 0, field.length(from: end, to: start) == 0,
              case let .success(holder) = field.parameterized("AXUIElementForTextMarker", start),
              CFGetTypeID(holder) == AXUIElementGetTypeID() else { return nil }
        // Parents are read every time, since an element can move.
        var elements = [AXElement(ref: holder as! AXUIElement)]
        while let last = elements.last, !last.sameElement(as: field) {
            guard elements.count < Self.coverDepth, let parent = try? last.element(kAXParentAttribute).get() else { return nil }
            elements.append(parent)
        }
        return CaretPlace(elements: elements)
    }

    /// For a read that leaves the dot to an estimate or to pixels: hides it
    /// while a native menu is open or something covers the estimate or the
    /// caret pixels last found, and stops capture meanwhile. Uncovered with
    /// the focus, selection, frames and last edit or click as they were
    /// when the cover began, and the field's frame known and still holding
    /// that caret, the caret is where pixels last found it, shown at once
    /// until they find it again.
    /// `besideCovers` false leaves the page's own elements beside the
    /// field out of the cover decision, for a control a point wide whose
    /// frame says nothing about its editor; `fieldFrame` then still tells a
    /// moved control.
    private func coverUnresolved(field: AXElement, pid: pid_t, window: AXElement?, fieldFrame: CGRect?,
                                 windowFrame: CGRect?, location: Int?, caret: CaretPlace? = nil, besideCovers: Bool = true) {
        let state = PixelState(focus: focusSerial, location: location, field: fieldFrame, window: windowFrame,
                               changed: changedAt.withLock { $0 })
        // Where pixels found the caret says nothing once the field or its
        // window moves, and a cover over that old place would otherwise keep
        // the dot away and stop the capture that finds the new one.
        func moved(_ a: CGRect?, _ b: CGRect?) -> Bool {
            guard let a, let b else { return (a == nil) != (b == nil) }
            return abs(a.minX - b.minX) > 0.5 || abs(a.minY - b.minY) > 0.5 || abs(a.width - b.width) > 0.5 || abs(a.height - b.height) > 0.5
        }
        let shown = shownCaret.withLock { $0 }
        if shown.reading != nil {
            if let seen = pixelFrames, seen.serial == shown.serial {
                if moved(seen.field, fieldFrame) || moved(seen.window, windowFrame) {
                    shownCaret.withLock { if $0.serial == shown.serial { $0.reading = nil } }
                    pixelFrames = nil
                }
            } else {
                pixelFrames = (shown.serial, fieldFrame, windowFrame)
            }
        } else {
            pixelFrames = nil
        }
        let pixels = shownCaret.withLock { $0.reading?.focus == focusSerial ? $0.reading?.caret : nil }
        let menu = menuShown()
        // The dot is drawn where pixels found the caret while that holds and
        // at the estimate after, so either one covered hides it.
        let marks = [pixels, hint?.caret].compactMap { $0 }.reduce(into: [CGRect]()) { if !$0.contains($1) { $0.append($1) } }
        if menu || marks.contains(where: {
            cover(at: CGPoint(x: $0.midX, y: $0.midY), field: field, fieldFrame: besideCovers ? fieldFrame : nil, window: window, pid: pid, caret: caret) == true
        }) {
            reason = menu ? "absent.menu" : "absent.covered"
            status = .absent
            hint = nil
            visualTarget = nil
            if coveredFrom == nil { coveredFrom = lastUncovered }
            return
        }
        if let from = coveredFrom {
            // A field whose frame cannot be read could have moved unseen, so
            // only a known frame that still holds the old caret brings it back.
            if from == state, hint == nil, let pixels, let fieldFrame,
               CaretCover.inside(pixels, field: fieldFrame) {
                hint = Reading(caret: pixels, field: fieldFrame, ink: lastInk[pid].flatMap { $0.field.sameElement(as: field) ? $0.ink : nil })
            } else if from != state {
                coveredFrom = nil
            }
        }
        lastUncovered = state
    }

    /// Whether a native menu is open, after letting go of one a click has
    /// since ended.
    private func menuShown() -> Bool {
        if menuOpen, clickedAt.withLock({ $0 }) > menuOpenedAt { menuOpen = false }
        return menuOpen
    }

    /// The person clicked somewhere, which ends any menu that was open.
    func noteClick() {
        let now = ProcessInfo.processInfo.systemUptime
        clickedAt.withLock { $0 = now }
    }

    /// Whether `element` is inside a web page, from its first dozen
    /// ancestors' roles.
    private static func inWebArea(_ element: AXElement) -> Bool {
        var node = element
        for _ in 0..<12 {
            if (try? node.string(kAXRoleAttribute).get()) == "AXWebArea" { return true }
            guard let parent = try? node.element(kAXParentAttribute).get() else { return false }
            node = parent
        }
        return false
    }

    /// The deepest steps a walk takes before giving up, which counts as

    /// The deepest steps a walk takes before giving up, which counts as
    /// not covered.
    static let coverDepth = 32

    /// Whether the caret at `point`, in Accessibility's top-left screen
    /// coordinates, is covered for `field` in `pid`'s `window`, from the
    /// element the system-wide hit test finds there. Nil when the window
    /// server or the app does not answer, which says nothing, and when the
    /// element is in one of Intention's own windows, which cannot be seen
    /// beneath. Roles, window identity and one frame only. `caret`, where
    /// the field names the element holding its own text position, exempts
    /// the list being typed in from the covering roles, and nothing more:
    /// everything else inside the field leaves the caret showing.
    private func cover(at point: CGPoint, field: AXElement, fieldFrame: CGRect?, window: AXElement?, pid: pid_t,
                       caret: CaretPlace? = nil) -> Bool? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return nil }
        var owner: pid_t = 0
        guard AXUIElementGetPid(hit, &owner) == .success, owner != ownPID else { return nil }
        // Another app's window is on top at the caret.
        guard owner == pid else { return true }
        // The caret's own element, or one that holds it: nothing between,
        // unless that is a menu, dialog or tooltip.
        if let caret, let index = caret.index(of: AXElement(ref: hit)) { return caret.refused(from: index) }
        let ancestors = ancestors(of: field, window: window)
        var steps: [CaretCover.Step] = []
        var node = AXElement(ref: hit)
        var branch: AXElement?
        // A bare element: a group with no children and no subrole of its own,
        // as the see-through strip of a popup drawn around the field is.
        let hitRole = try? node.string(kAXRoleAttribute).get()
        let bare = hitRole == kAXGroupRole && ((try? node.children().get()) ?? []).isEmpty
            && ((try? node.string(kAXSubroleAttribute).get()) ?? "").isEmpty
        for _ in 0..<Self.coverDepth {
            if let caret, !node.sameElement(as: field), let index = caret.index(of: node) {
                // Met the caret's own ancestry below the field, as text
                // beside the caret meets its paragraph: a menu, dialog or
                // tooltip from there up covers it, and nothing else does.
                if caret.refused(from: index) { return true }
                steps.append(.field)
                break
            }
            if node.sameElement(as: field) {
                // Inside the field: a placeholder, a hint, ghost text or a
                // chip beside the caret belongs to it, and only a covering
                // role met on the way up, in `steps`, hides the caret.
                steps.append(.field)
                break
            }
            if ancestors.contains(where: { $0.sameElement(as: node) }) {
                // Met the field's own ancestors: the hit itself holds the
                // field, or came through a branch beside it.
                guard let branch else {
                    steps.append(.field)
                    break
                }
                let frame = try? branch.frame().get()
                steps.append(.joins(insideField: frame.flatMap { frame in fieldFrame.map { CaretCover.inside(frame, field: $0) } } ?? true))
                break
            }
            let role = try? node.string(kAXRoleAttribute).get()
            if role == kAXWindowRole {
                // A borderless window holding the whole field, met through a
                // bare element: a frame drawn around the field, not a cover.
                if bare, (try? node.string(kAXSubroleAttribute).get()) == "AXUnknown",
                   let fieldFrame, let frame = try? node.frame().get(), frame.contains(fieldFrame) {
                    steps.append(.frameAround)
                } else {
                    steps.append(.otherWindow)
                }
                break
            }
            if role == kAXApplicationRole { break }
            // Only groups carry the subroles that mark a dialog or a tooltip.
            let subrole = role == kAXGroupRole ? try? node.string(kAXSubroleAttribute).get() : nil
            steps.append(.element(role: role ?? "", subrole: subrole))
            guard let parent = try? node.element(kAXParentAttribute).get() else { break }
            branch = node
            node = parent
        }
        return CaretCover.covered(by: steps)
    }

    /// The field's ancestors up to and including its window, read once per
    /// field.
    private func ancestors(of field: AXElement, window: AXElement?) -> [AXElement] {
        if let ancestry, ancestry.field.sameElement(as: field) { return ancestry.ancestors }
        var found: [AXElement] = []
        var node = field
        for _ in 0..<Self.coverDepth {
            guard let parent = try? node.element(kAXParentAttribute).get() else { break }
            found.append(parent)
            if window.map({ parent.sameElement(as: $0) }) == true { break }
            node = parent
        }
        ancestry = (field, found)
        return found
    }

    /// Where pixels placed the dot for the focus `focus`, as the controller
    /// shows it, so later reads can hide it when something covers that
    /// point. Nil forgets it.
    func noteShown(_ caret: CGRect?, focus: Int) {
        shownCaret.withLock { $0 = (caret.map { (focus, $0) }, $0.serial &+ 1) }
    }

    private func selectedRange(of focused: AXElement, facts: ElementFacts) -> Result<FieldRange, AXFailure> {
        facts.document ? focused.markerSelection() : focused.range(kAXSelectedTextRangeAttribute)
    }

    private func resolve(_ focused: AXElement, at location: Int, facts: ElementFacts) -> CGRect? {
        guard facts.isWeb else {
            var mode = collapsedModes[facts.pid]
            let caret = CaretBounds.nativeInsertionPoint(in: focused, at: location, field: facts.field, mode: &mode)
            if let mode { collapsedModes[facts.pid] = mode }
            return caret
        }
        // A control a point wide and a line tall, or one with no height, holds
        // no text geometry of its own, and a caret pixels find near it is the
        // editor's, not a text start of this control: its frame, read afresh,
        // is the estimate in `caret()`, and pixels stay visual evidence. A
        // field whose frame could not be read, or has no size, is such a one.
        // The cached frame lags a control that has just gained a size, as
        // Gmail's body does with its first letter, by up to half a second,
        // so the current frame decides and the cache is read again.
        func degenerate(_ frame: CGRect) -> Bool { CaretBounds.caretFromControlFrame(frame) != nil || CaretBounds.flatControlLine(frame) != nil }
        if facts.field.map(degenerate) ?? true {
            guard case let .success(frame) = focused.frame(), frame.width > 2, frame.height > 2, !degenerate(frame) else { return nil }
            element?.readAt = .now - Self.framesLifetime
        }
        if webStart.map({ !$0.element.sameElement(as: focused) || $0.field != facts.field }) == true { webStart = nil }
        if let pending = pendingStart.withLock({ value -> (target: VisualCaretTarget, caret: CGRect)? in defer { value = nil }; return value }),
           pending.target.element.sameElement(as: focused), pending.target.windowFrame == facts.windowFrame {
            webStart = (focused, facts.field, pending.caret)
        }
        if location <= 1, let start = CaretBounds.webTextStart(in: focused, field: facts.field) {
            webStart = (focused, facts.field, start)
        }
        let generated = generatedPlaceholder(focused, at: location)
        if !generated, let caret = CaretBounds.webInsertionPoint(in: focused, at: location, field: facts.field) {
            return caret
        }
        // An emptied control keeps the caret where its text started.
        if location == 0 || generated || emptyText(focused), let start = webStart?.caret { return start }
        return nil
    }

    /// Chromium counts a CSS placeholder as the control's text, so an empty
    /// rich editor reports characters and a selection after them. Text the
    /// person can edit lists an editable ancestor; generated text does not.
    private func generatedPlaceholder(_ focused: AXElement, at location: Int) -> Bool {
        guard case let .success(count) = focused.int(kAXNumberOfCharactersAttribute) else { return false }
        if location > count { return true }
        guard count > 0, count <= 500 else { return false }
        if let cached = generatedCache, cached.count == count, cached.element.sameElement(as: focused) { return cached.generated }
        var generated = false
        // The value is read only when its length already equals the
        // placeholder's, and is compared and dropped at once.
        if case let .success(placeholder) = focused.string(kAXPlaceholderValueAttribute), !placeholder.isEmpty,
           placeholder.utf16.count == count,
           case let .success(value) = focused.string(kAXValueAttribute), value == placeholder {
            generated = true
        } else if let text = Self.firstStaticText(in: focused) {
            var names: CFArray?
            generated = AXUIElementCopyAttributeNames(text.ref, &names) == .success
                && !((names as? [String]) ?? []).contains("AXEditableAncestor")
        }
        generatedCache = (focused, count, generated)
        return generated
    }

    /// No text of the person's own: rich editors keep an empty paragraph,
    /// which counts as a line break.
    private func emptyText(_ focused: AXElement) -> Bool {
        guard case let .success(count) = focused.int(kAXNumberOfCharactersAttribute) else { return false }
        if count == 0 { return true }
        // At most two characters are read, and dropped at once.
        guard count <= 2, case let .success(value) = focused.string(for: FieldRange(location: 0, length: count)) else { return false }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The first static text within a few levels of a rich editor.
    private static func firstStaticText(in element: AXElement) -> AXElement? {
        var level = [element]
        for _ in 0..<3 {
            var next: [AXElement] = []
            for node in level {
                guard case let .success(value) = node.value(kAXChildrenAttribute), let children = value as? [AXUIElement] else { continue }
                for child in children.prefix(4).map(AXElement.init(ref:)) {
                    if (try? child.string(kAXRoleAttribute).get()) == kAXStaticTextRole { return child }
                    next.append(child)
                }
            }
            level = Array(next.prefix(8))
        }
        return nil
    }

    /// Input from the person: apps draw the caret solid for a moment after
    /// it, including those that post no change notification.
    func noteInput() {
        let now = ProcessInfo.processInfo.systemUptime
        changedAt.withLock { $0 = now }
    }

    /// Blinking confirmed the caret of an empty web control: that is where
    /// its text starts, which Chromium's rich editors never report. A
    /// single-frame guess is never remembered. The next read adopts it if
    /// the same element is still focused in the same window frame.
    func rememberTextStart(_ caret: CGRect, of target: VisualCaretTarget) {
        guard target.empty else { return }
        pendingStart.withLock { $0 = (target, caret) }
    }

    /// The capture boundary for visual confirmation, read only when
    /// Accessibility could not place the caret.
    private func visualCandidate(_ focused: AXElement, pid: pid_t, facts: ElementFacts) -> VisualCaretTarget? {
        // Capture needs the target frontmost, which a panel owner is not.
        guard panelOwner == nil else { return nil }
        guard var candidate = VisualCaretTarget.read(focused, pid: pid, admitted: facts.usable),
              let window = facts.window, candidate.window.sameElement(as: window),
              candidate.windowFrame == facts.windowFrame,
              allowedWindow(candidate.window, pid: pid, frame: candidate.windowFrame) else { return nil }
        let location = candidate.selection?.location ?? 0
        candidate.empty = emptyText(focused) || (facts.isWeb && generatedPlaceholder(focused, at: location))
        candidate.focusedAt = max(focusedAt, changedAt.withLock { $0 })
        #if DEBUG
        if requiredPID != nil {
            let anchors = candidate.anchors
            let location = candidate.selection?.location
            let readAt = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async {
                MainActor.assumeIsolated { CaretFixtureMode.anchorObservation(anchors, selection: location, readAt: readAt) }
            }
        }
        #endif
        return candidate
    }

    /// The element with keyboard focus and its process. The system-wide
    /// element answers for panels that take focus without activating their
    /// app, such as Spotlight and launchers; such a process is the owner
    /// only while the focused element's own window is one of its on-screen
    /// floating windows, so a late reply naming a field of an app that was
    /// just left is refused even when that app shows a menu-bar extra or a
    /// palette. The system-wide query fails at once while Chrome is
    /// frontmost; the frontmost app's own focused element covers that.
    private func keyboardFocus(front: pid_t) -> (element: AXElement, pid: pid_t)? {
        guard front != ownPID else { return nil }
        let system = AXElement(ref: AXUIElementCreateSystemWide())
        if case let .success(focused) = system.element(kAXFocusedUIElementAttribute) {
            var pid: pid_t = 0
            guard AXUIElementGetPid(focused.ref, &pid) == .success, pid != ownPID else { focusMiss = ".own"; return nil }
            if pid == front {
                guard frontmost.withLock({ $0.pid }) == front else { focusMiss = ".stale"; return nil }
                acceptedPanel = nil
                return (focused, pid)
            }
            // Under the caret lab, another app's panel is never a target,
            // and the app underneath is not marked while it has the keyboard.
            guard requiredPID == nil || requiredPID == pid else {
                focusMiss = ".panel.refused"
                return nil
            }
            let window = try? focused.element(kAXWindowAttribute).get()
            let sameWindow = acceptedPanel.map { accepted in accepted.pid == pid && window.map { $0.sameElement(as: accepted.window) } == true } ?? false
            // The first acceptance needs the whole frame to match. A panel
            // can resize faster than its frame and window server bounds agree,
            // as Spotlight's single window switches between the bar and a
            // full-screen frame when results appear, so the accepted window
            // then needs only to overlap one of its process's panel windows.
            if let miss = Self.floatingWindowMiss(focused, pid: pid, overlapping: sameWindow) {
                // The accepted window between frames of a change: hold the
                // last position rather than hide it; nothing is read.
                focusMiss = sameWindow && Self.showsFloatingWindow(pid) ? ".panel.changing" : ".panel." + miss
                return nil
            }
            acceptedPanel = window.map { (pid, $0) }
            return (focused, pid)
        }
        guard frontmost.withLock({ $0.pid }) == front else { focusMiss = ".app"; return nil }
        switch AXElement.application(front).element(kAXFocusedUIElementAttribute) {
        case let .success(focused):
            return (focused, front)
        case let .failure(error):
            // Only an app that answers that nothing has focus can be an
            // opaque one; an error or timeout says nothing about its window.
            focusMiss = error.code == .noValue ? ".app.none" : ".app"
            return nil
        }
    }

    /// The focused window of an app that answers no keyboard focus and
    /// exposes no text control or web area anywhere in it. Apps build their
    /// trees a moment after being asked, so only a window still bare a
    /// second after the app came forward counts; a Chromium browser, which
    /// answers its own bootstrap, never does. Window metadata and roles only.
    private func opaqueTarget(_ pid: pid_t) -> VisualCaretTarget? {
        guard opaquePIDs.contains(pid) || ProcessInfo.processInfo.systemUptime - preparedAt >= 1,
              !WritingSurfacePolicy.isChromiumBrowser(bundleIdentifier: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier),
              let window = try? AXElement.application(pid).element(kAXFocusedWindowAttribute).get(),
              let frame = try? window.frame().get(), frame.width > 40, frame.height > 40,
              frame.minX.isFinite, frame.minY.isFinite,
              allowedWindow(window, pid: pid, frame: frame), opaque(window) else { return nil }
        // An app found bare once skips the wait when it comes forward again;
        // its tree is still checked every time.
        opaquePIDs.insert(pid)
        if focusIdentity?.sameElement(as: window) != true {
            focusIdentity = window
            focusSerial &+= 1
            focusedAt = ProcessInfo.processInfo.systemUptime
        }
        return .opaque(window: window, pid: pid, frame: frame, focusedAt: max(focusedAt, changedAt.withLock { $0 }))
    }

    /// `AXWritingSurface.bare`, cached for two seconds per window.
    private func opaque(_ window: AXElement) -> Bool {
        if let cache = opaqueCache, cache.window.sameElement(as: window), ContinuousClock.now - cache.at < .seconds(2) {
            return cache.opaque
        }
        let bare = AXWritingSurface.bare(window)
        opaqueCache = (window, bare, .now)
        return bare
    }

    /// Why the element is not in an on-screen floating window of its
    /// process, or nil when it is. Window metadata only: the element's
    /// window frame and the process's window levels and frames.
    private static func floatingWindowMiss(_ focused: AXElement, pid: pid_t, overlapping: Bool) -> String? {
        guard let window = try? focused.element(kAXWindowAttribute).get() else { return "noWindow" }
        guard let frame = try? window.frame().get(), frame.width > 0, frame.height > 0 else { return "noFrame" }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return "noList" }
        let matched = windows.contains {
            guard isPanelWindow($0, of: pid),
                  let bounds = ($0[kCGWindowBounds as String] as? [String: NSNumber]).flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) })
            else { return false }
            if overlapping { return !bounds.intersection(frame).isEmpty }
            return abs(bounds.minX - frame.minX) <= 1 && abs(bounds.minY - frame.minY) <= 1
                && abs(bounds.width - frame.width) <= 1 && abs(bounds.height - frame.height) <= 1
        }
        return matched ? nil : "unmatched"
    }

    private static func showsFloatingWindow(_ pid: pid_t) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        return windows.contains { isPanelWindow($0, of: pid) }
    }

    /// A visible window of the process at floating level or above and below
    /// status level, where menu-bar extras sit.
    private static func isPanelWindow(_ info: [String: Any], of pid: pid_t) -> Bool {
        let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        return (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
            && layer >= Int(CGWindowLevelForKey(.floatingWindow)) && layer < Int(CGWindowLevelForKey(.statusWindow))
            && ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0
    }

    /// Admission is fixed for an element; its window and frames are read
    /// again after `framesLifetime` or a focus or window notification.
    private func facts(for focused: AXElement, pid: pid_t) -> ElementFacts? {
        var cached = element.flatMap { $0.element.sameElement(as: focused) && $0.pid == pid ? $0 : nil }
        // A secure refusal is never retried: one generic failure from a
        // wrapper during a retry must not admit a password field.
        let retryRefusal = cached.map {
            !$0.usable && $0.refusal != "secure" && ProcessInfo.processInfo.systemUptime - focusedAt < Self.refusalRetry
                && ContinuousClock.now - $0.admittedAt >= Self.refusalInterval
        } ?? false
        if let cached, !retryRefusal, ContinuousClock.now - cached.readAt < Self.framesLifetime {
            return cached
        }
        if retryRefusal { cached = nil }
        if focusIdentity?.sameElement(as: focused) != true {
            focusIdentity = focused
            focusSerial &+= 1
            focusedAt = ProcessInfo.processInfo.systemUptime
            menuOpen = false
        }
        // Window metadata precedes any field selection, character, marker
        // or anchor read, including capture's independent validation.
        guard let metadata = windowMetadata(for: focused, pid: pid) else {
            element = nil
            focusIdentity = nil
            return nil
        }
        let usable: Bool
        let isWeb: Bool
        let document: Bool
        var refusal: String?
        var admittedAt = ContinuousClock.now
        if let cached {
            usable = cached.usable
            isWeb = cached.isWeb
            document = cached.document
            refusal = cached.refusal
            admittedAt = cached.admittedAt
        } else {
            // Secure fields are refused before their editability or range
            // is read, and code editors by their metadata.
            let secure = (try? focused.string(kAXSubroleAttribute).get()) == kAXSecureTextFieldSubrole
            let role = try? focused.string(kAXRoleAttribute).get()
            // Keyboard focus on a web area is a caret only when the whole
            // document is editable, which WebKit reports as a settable
            // value, and it can be followed only where its selection
            // markers have offsets.
            let webArea = role == "AXWebArea"
            let textRole = webArea || [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role ?? "")
            let surface = !secure && textRole
                ? AXWritingSurface.surface(focused, pid: pid, editableDocument: webArea) : (admission: .unsupported, web: false)
            // Read only once the surface is admitted.
            func editable() -> Bool {
                if webArea {
                    return focused.isSettable(kAXValueAttribute) && focused.parameterizedAttributes().contains("AXIndexForTextMarker")
                }
                return focused.isSettable(kAXValueAttribute) || focused.isSettable(kAXSelectedTextAttribute)
                    || (WritingSurfacePolicy.admitsTypingWithoutSettableText(
                            bundleIdentifier: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, role: role ?? "")
                        && focused.isSettable(kAXSelectedTextRangeAttribute))
            }
            usable = surface.admission == .allowed && editable()
            isWeb = usable && surface.web
            document = usable && webArea
            if !usable {
                if secure || surface.admission == .secure { refusal = "secure" }
                else if !textRole { refusal = "role" }
                else if surface.admission != .allowed { refusal = "surface" }
                else { refusal = "notSettable" }
            }
        }
        var frames: [CGRect] = []
        var field: CGRect?
        if usable {
            if case let .success(frame) = focused.frame(), frame.width > 0, frame.height > 0 {
                frames.append(frame)
                field = frame
            }
            frames.append(metadata.frame)
        }
        let facts = ElementFacts(element: focused, usable: usable, refusal: refusal, admittedAt: admittedAt, isWeb: isWeb, document: document, pid: pid,
                                 window: metadata.window, windowFrame: metadata.frame,
                                 frames: frames, field: field, ink: cached?.ink, readAt: .now)
        element = facts
        return facts
    }

    // MARK: - Notifications

    /// Chrome and Electron build their accessibility trees only once a
    /// client asks, so the frontmost app is asked before its focused element
    /// is read: once per activation, never on every read.
    private func prepare(_ pid: pid_t) {
        if preparedPID != pid {
            preparedPID = pid
            preparedAt = ProcessInfo.processInfo.systemUptime
            chromeBootstrapAttempts = 0
            chromeBootstrapNextAttempt = .now
            _ = AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        enableChromeAccessibility(pid: pid)
    }

    /// Observes the process that has keyboard focus, and only that one.
    private func follow(_ pid: pid_t?) {
        guard pid != observedPID else { return }
        menuOpen = false
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedElement = nil
        observedPID = pid
        guard let pid else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, Self.callback, &created) == .success, let created else { return }
        let app = AXUIElementCreateApplication(pid)
        // Electron apps build their accessibility tree, and with it caret
        // bounds, only once a client asks. Other apps refuse the attribute.
        // `prepare` has already asked the frontmost app.
        if pid != preparedPID { _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) }
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.notifications {
            // Apps that do not post a notification refuse it; the interval
            // refresh covers them.
            _ = AXObserverAddNotification(created, app, name as CFString, context)
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
    }

    /// At most five metadata probes per followed app activation, spaced by
    /// 200 ms. Once a window is available, request a Chromium browser's
    /// accessibility once.
    /// A refused setter cannot cause perpetual writes on polling refreshes.
    private func enableChromeAccessibility(pid: pid_t) {
        guard chromeBootstrapAttempts < 5, ContinuousClock.now >= chromeBootstrapNextAttempt else { return }
        chromeBootstrapAttempts += 1
        chromeBootstrapNextAttempt = .now + .milliseconds(200)
        guard requiredPID == nil || requiredPID == pid,
              frontmost.withLock({ $0.pid }) == pid,
              WritingSurfacePolicy.isChromiumBrowser(bundleIdentifier: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier) else {
            chromeBootstrapAttempts = 5
            return
        }
        func permitsWindow(_ window: AXElement) -> Bool {
            guard requiredWindowTitle == nil || (try? window.string(kAXTitleAttribute).get()) == requiredWindowTitle else { return false }
            guard let requiredWindowID else { return true }
            guard let frame = try? window.frame().get(),
                  let infos = CGWindowListCopyWindowInfo(.optionIncludingWindow, requiredWindowID) as? [[String: Any]],
                  infos.count == 1, let info = infos.first,
                  (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value == requiredWindowID,
                  let bounds = info[kCGWindowBounds as String] as? [String: NSNumber],
                  CGRect(dictionaryRepresentation: bounds as CFDictionary) == frame else { return false }
            return true
        }
        let app = AXUIElementCreateApplication(pid)
        guard case let .success(window) = AXElement(ref: app).element(kAXFocusedWindowAttribute),
              permitsWindow(window) else { return }
        chromeBootstrapAttempts = 5
        guard frontmost.withLock({ $0.pid }) == pid else { return }
        _ = AXUIElementSetAttributeValue(window.ref, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        if frontmost.withLock({ $0.pid }) == pid,
           case let .success(current) = AXElement(ref: app).element(kAXFocusedWindowAttribute), current.sameElement(as: window),
           permitsWindow(current) {
            _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    /// Selection notifications belong to the text control. Registering only
    /// on the application misses updates from AppKit field editors.
    private func observeElement(_ focused: AXElement) {
        guard let observer, observedElement?.sameElement(as: focused) != true else { return }
        let names = [kAXSelectedTextChangedNotification, kAXValueChangedNotification,
                     kAXMovedNotification, kAXResizedNotification, kAXLayoutChangedNotification]
        if let previous = observedElement {
            for name in names { AXObserverRemoveNotification(observer, previous.ref, name as CFString) }
        }
        observedElement = focused
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in names { AXObserverAddNotification(observer, focused.ref, name as CFString, context) }
    }

    /// A menu or window opening or closing can cover or uncover the caret,
    /// so those read at once too; anything else that comes over it, such
    /// as a page's own popover, is found by the next interval refresh.
    private static let notifications = [
        kAXFocusedUIElementChangedNotification,
        kAXFocusedWindowChangedNotification,
        kAXSelectedTextChangedNotification,
        kAXValueChangedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXMenuOpenedNotification,
        kAXMenuClosedNotification,
        kAXWindowCreatedNotification,
    ]

    /// Runs on the executor thread, whose run loop holds the observer's
    /// source.
    private static let callback: AXObserverCallback = { _, element, notification, context in
        guard let context else { return }
        let tracker = Unmanaged<CaretTracker>.fromOpaque(context).takeUnretainedValue()
        let name = notification as String
        // A page's own menu, such as a list that opens as the person types
        // a slash, leaves the keyboard in the field; only a native menu
        // takes it. A page's menu over the caret is found by `covered`.
        if name == kAXMenuOpenedNotification {
            tracker.menuOpen = !CaretTracker.inWebArea(AXElement(ref: element))
            tracker.menuOpenedAt = ProcessInfo.processInfo.systemUptime
        }
        // The field's text or selection changing means typing reached it,
        // so no menu holds the keyboard.
        if [kAXMenuClosedNotification, kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification,
            kAXValueChangedNotification, kAXSelectedTextChangedNotification].contains(name) {
            tracker.menuOpen = false
        }
        if [kAXValueChangedNotification, kAXSelectedTextChangedNotification].contains(name) {
            let now = ProcessInfo.processInfo.systemUptime
            tracker.changedAt.withLock { $0 = now }
        }
        if FieldEditNotice.isEdit(name, from: element, watched: tracker.observedElement?.ref) {
            tracker.editSerial.withLock { $0 &+= 1 }
        }
        if [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification,
            kAXWindowMovedNotification, kAXWindowResizedNotification,
            kAXMovedNotification, kAXResizedNotification, kAXLayoutChangedNotification].contains(name) {
            tracker.element = nil
            tracker.visualTarget = nil
            // Revoke old geometry before scheduling any slow AX read. The
            // controller advances its generation, rejecting already queued
            // observations from before this boundary change.
            tracker.onInvalidation()
        }
        tracker.scheduleRead()
    }
}
