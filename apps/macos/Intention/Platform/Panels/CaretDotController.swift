import AppKit

/// Tracks the caret in other apps for captions and popups. The Own Hand
/// dot rests above email bodies and carries active dictation elsewhere
/// when the foot cannot display it.
///
/// The window never takes focus and lets every click through. The dot moves
/// with the caret at once, because a trailing dot would lag behind typing,
/// and appears without a fade when an email body gains focus. A small
/// window under the dot alone takes a click on it, for dictation, without
/// activating Intention or moving focus out of the field.
@MainActor
final class CaretDotController {
    /// How often the caret is read again between notifications, to follow
    /// scrolling, which moves the caret without one.
    static let refreshInterval: TimeInterval = 1.0 / 30
    /// The dot window's side before it first covers a screen.
    static let side: CGFloat = 32

    var visualFallbackEnabled = false {
        didSet { enabledChanged() }
    }
    /// Whether the dot is the chosen indicator. Off, as when the person
    /// chose the foot mark alone, the dot is never shown: the caret is not
    /// read, the tracker stops observing the focused app, input prompts
    /// nothing and nothing is captured.
    var shown = true {
        didSet { if shown != oldValue { enabledChanged() } }
    }
    /// Turns the dot red while dictation records and pulses it while the
    /// text is on its way.
    ///
    /// While dictation runs the dot stays where it last was even if the
    /// caret cannot be read for a moment, so it can be clicked to stop and
    /// still marks where the text will go; it hides again by the usual rules
    /// once dictation ends. A locked screen or sleeping display still hides it.
    var dictationPhase: DictationController.Phase = .idle {
        didSet {
            applyLook()
            if dictationPhase != .recording { level = 0 }
            if oldValue == .idle { pinnedPID = observation?.pid }
            // Words beside the dot that no longer apply go at once, even while
            // the dot stays pinned: "Writing your email…" when the email fails
            // and the words are typed instead.
            if captionWords == nil { caption.hide() }
            // The words beside the dot follow the phase at once, pinned or
            // not, rather than waiting for the next reading.
            updateCapture()
            update()
        }
    }
    /// What the reply proposal shows: the dot pulses while a proposal is on
    /// its way and is at full ink while its card shows, unless a dictation's
    /// own look applies (`DictationIndicators.dotLook`).
    var proposalPresentation: ProposalPresentation = .idle {
        didSet {
            guard proposalPresentation != oldValue else { return }
            applyLook()
            update()
        }
    }
    /// Intention's click-through proposal sheet, without transparent shadow room.
    var proposalCardFrame: CGRect? {
        didSet { if proposalCardFrame != oldValue { update() } }
    }
    /// Whether the foot mark's sun can be seen to carry a recording's red
    /// (`FootMark.carriesRed`): while it can, the dot stays ink, so one red
    /// mark shows.
    var footCarriesRed = false {
        didSet { if footCarriesRed != oldValue { applyLook(); update() } }
    }
    var footPaints = false {
        didSet { if footPaints != oldValue { update() } }
    }
    var wordsAtFoot = false {
        didSet { if wordsAtFoot != oldValue { update() } }
    }
    /// Classification comes from metadata only, delivered on the main actor.
    var emailBodyChanged: @MainActor (Bool) -> Void = { _ in }
    private(set) var isEmailBody = false {
        didSet { if isEmailBody != oldValue { emailBodyChanged(isEmailBody) } }
    }

    private var presentation: CaretPresentation {
        DictationIndicators.caretPresentation(isEmailBody: isEmailBody, phase: dictationPhase,
            proposal: proposalPresentation, footCarriesRed: footCarriesRed,
            footPaints: footPaints, captionDue: captionWords != nil, wordsAtFoot: wordsAtFoot)
    }

    /// Runs when the focused field's frame changes, in AppKit screen
    /// coordinates, or nil when no field is known, so the foot mark keeps
    /// clear of it.
    var focusedFieldChanged: (CGRect?) -> Void = { _ in }
    private var focusedField: CGRect? {
        didSet { if focusedField != oldValue { focusedFieldChanged(focusedField) } }
    }

    private func applyLook() {
        host.look = DotMarkView.Look(DictationIndicators.dotLook(phase: dictationPhase, proposal: proposalPresentation, footCarriesRed: footCarriesRed))
    }
    /// The app the dot stays over during dictation. Once another app comes
    /// forward the dot follows the usual rules again, so it never covers
    /// unrelated content; the menu bar item still offers Stop.
    private var pinnedPID: pid_t?
    /// Where the dot was last placed, so words that come or change while
    /// dictation keeps it there without a reading go beside it.
    private var placedDot: DotPlacement.Dot? {
        didSet {
            if (placedDot == nil) != (oldValue == nil) { caretAnchorChanged() }
        }
    }
    /// Word routing changes only when an anchor becomes available or is lost.
    var caretAnchorChanged: @MainActor () -> Void = {}
    private var placedInk: NSColor?
    private var placedCaret: CGRect?
    /// How loud the latest chunk of a dictation was, from 0 to 1, for the
    /// halo that grows round the red dot while it records.
    var level = 0.0 {
        didSet { host.level = level }
    }
    /// A word beside the dot after a dictation, for an outcome the field
    /// alone does not show, such as the words typed in place of an email
    /// Intention could not write. Shown while set and a caret anchor is known.
    var notice: String? {
        didSet {
            guard notice != oldValue else { return }
            // A cleared notice's caption goes whatever happens to the dot: a
            // new recording keeps the dot pinned where it was, and the
            // placement below would otherwise leave the old words beside it.
            if notice == nil { caption.hide() }
            updateCapture()
            update()
        }
    }
    /// Words that teach, beside the dot while no dictation runs and no
    /// notice shows: the email hint (`EmailHints`) when the caret has
    /// landed in an email body. Shown while set and a caret anchor is known.
    var hint: String? {
        didSet {
            guard hint != oldValue else { return }
            if hint == nil { caption.hide() }
            updateCapture()
            update()
        }
    }
    /// The pending email's wait, supplied by dictation rather than timed
    /// independently by the dot.
    var emailFeedback = DictationController.EmailFeedback() {
        didSet { if emailFeedback != oldValue { update() } }
    }

    /// What the caption beside the dot says now: the phase's words, then a
    /// notice, then a hint, which only an idle dot shows.
    private var captionWords: String? {
        dictationPhase.caption(email: emailFeedback) ?? notice ?? (dictationPhase == .idle ? hint : nil)
    }
    /// A notice whose caption went away with the dot while it was still
    /// due, so the app can say it somewhere else. Called once, as the dot
    /// hides; the notice stays set until the app clears it.
    var noticeLost: (String) -> Void = { _ in }
    /// A click on the dot.
    var onClick: () -> Void = {}
    /// The dot's click target in AppKit screen coordinates while the dot is
    /// shown. Captions and popups use `caretAnchor` instead.
    var markFrame: CGRect? { target.isVisible ? target.frame : nil }
    /// Where words and popups belong, whether or not the mark is drawn.
    var caretAnchor: CGRect? { placedDot.map { DotPlacement.anchor(for: $0) } }
    /// Runs with every observation the dot accepts, for what follows the
    /// caret besides the dot, such as a reply proposal's card.
    var observationChanged: ((CaretTracker.Observation) -> Void)?
    var geometryChanged: (() -> Void)?
    #if DEBUG
    /// The centre of the dot's click target in AppKit screen coordinates,
    /// while it is shown, for the dictation checks.
    var targetCenter: CGPoint? {
        target.isVisible ? CGPoint(x: target.frame.midX, y: target.frame.midY) : nil
    }
    #endif
    private let requiredWindowTitle: String?
    private let requiredPID: pid_t?
    private let requiredWindowID: CGWindowID?
    private let visual = VisualCaretCapture()
    private var observation: CaretTracker.Observation?
    private var inputMonitor: Any?
    private var evidence = NativeCaretContinuity<CaretTracker.Reading>()
    private var locked = false
    private let panel = DotWindow()
    private let target = DotTargetWindow()
    /// The few words beside the dot while an email is written and for the
    /// notice after; nothing for the rest of a dictation.
    private let caption = DotCaption()
    private let host: DotMarkView
    private var tracker: CaretTracker?
    private var timer: Timer?
    private var reading: CaretTracker.Reading? { evidence.shown(at: .now) }
    private var showing = false
    private var observers: [NSObjectProtocol] = []
    private var screensAsleep = false

    init(requiredWindowTitle: String? = nil) {
        #if DEBUG
        self.requiredWindowTitle = CaretFixtureMode.scope?.title ?? requiredWindowTitle
        self.requiredPID = CaretFixtureMode.scope?.pid
        self.requiredWindowID = CaretFixtureMode.scope?.windowID
        #else
        self.requiredWindowTitle = requiredWindowTitle
        self.requiredPID = nil
        self.requiredWindowID = nil
        #endif
        host = DotMarkView()
        host.frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        panel.contentView = host
        // Installing the content view adopts the panel's initial zero size.
        // Use the declared size, not the view's frame after attachment.
        panel.setContentSize(CGSize(width: Self.side, height: Self.side))
        // Above floating launcher panels such as Spotlight (level 23), whose
        // fields the dot also marks; below menus.
        panel.level = .statusBar
        panel.alphaValue = 0
        #if DEBUG
        // Constant, so updates never change window properties; test
        // runners find the surface by this prefix.
        panel.title = "dot surface"
        #endif
        // Allocate and paint the backing store before the first caret. The
        // transparent, click-through window never takes focus.
        panel.orderFrontRegardless()
        host.displayIfNeeded()
        target.onClick = { [weak self] in self?.onClick() }

        visual.onReading = { [weak self] reading, confirmed in
            guard let self, let observation = self.observation, let target = observation.visualTarget else { return }
            self.evidence.confirmVisual(reading, at: .now)
            // So the tracker can hide it when something comes over that point.
            if let reading { self.tracker?.noteShown(reading.caret, focus: observation.focus) }
            if let reading, confirmed { self.tracker?.rememberTextStart(reading.caret, of: target) }
            self.update()
        }
        // Observe input metadata, never its characters. Input only prompts a
        // fresh read: the dot keeps its position until that read moves it,
        // so typing never blanks it. Blink evidence restarts after input.
        inputMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                // Typing and clicks draw the caret solid for a moment;
                // scrolling moves it without that.
                if [.keyDown, .leftMouseDown].contains(event.type) { self.tracker?.noteInput() }
                if [.leftMouseDown, .rightMouseDown].contains(event.type) { self.tracker?.noteClick() }
                // Scrolling moves a caret pixels found, so where they found
                // it is not put back after a cover.
                if event.type == .scrollWheel, let focus = self.observation?.focus { self.tracker?.noteShown(nil, focus: focus) }
                if event.type == .keyDown {
                    // The kind of key only: delete, printable or other.
                    let kind: VisualCaretCapture.KeyKind = event.keyCode == 51 ? .delete
                        : !event.modifierFlags.intersection([.command, .control, .function]).isEmpty || (123...126).contains(event.keyCode)
                            ? .other : .printable
                    self.visual.noteInput(click: nil, key: kind)
                }
                if event.type == .leftMouseDown, let primary = NSScreen.screens.first {
                    // Global points with a top-left origin, as Accessibility uses.
                    let location = NSEvent.mouseLocation
                    self.visual.noteInput(click: CGPoint(x: location.x, y: primary.frame.maxY - location.y))
                }
                if event.type != .keyUp { self.visual.restart() }
                self.refresh()
            }
        }
        let distributed = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            observers.append(distributed.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.locked = locked
                    self?.enabledChanged()
                }
            })
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.visual.discardPrefetch()
                self?.targetBoundaryChanged()
            }
        })
        observers += [
            workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setScreensAsleep(true) }
            },
            workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setScreensAsleep(false) }
            },
            workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if self?.running == true, self?.visualFallbackEnabled == true, self?.captureNeeded == true { self?.visual.prefetch() }
                    self?.targetBoundaryChanged()
                }
            },
        ]
    }

    func start() {
        guard tracker == nil else { return }
        tracker = CaretTracker(requiredWindowTitle: requiredWindowTitle, requiredPID: requiredPID, requiredWindowID: requiredWindowID,
                               onInvalidation: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.targetBoundaryChanged() }
            }
        }, onEmailBody: CaretEmailBody.reporter { [weak self] focus, body in
            guard let self, self.running,
                  self.observation?.focus == focus.serial,
                  self.observation?.pid == focus.pid,
                  self.observation?.fieldFocused == true else { return }
            self.isEmailBody = body
            self.updateCapture()
            self.update()
        }) { [weak self] reading in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.readingChanged(reading) }
            }
        }
        enabledChanged()
    }

    /// The dot keeps its place only until the next read moves or clears
    /// it, so moving between fields never blanks it in between.
    private func targetBoundaryChanged() {
        guard running else { return }
        geometryChanged?()
        evidence.boundary(at: .now)
        visual.invalidate()
        settleUntil = .now + .milliseconds(250)
        refresh()
        update()
    }

    /// After a focus, window or app change, apps can take a few frames to
    /// move focus into the new field. Until a read places the caret, read
    /// again every 8 ms instead of waiting for the next interval tick.
    private var settleUntil = ContinuousClock.now
    private var settleScheduled = false

    private func settleIfNeeded(_ status: CaretTracker.Observation.Status) {
        guard status != .placed, ContinuousClock.now < settleUntil, !settleScheduled else { return }
        settleScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(8)) { [weak self] in
            MainActor.assumeIsolated {
                self?.settleScheduled = false
                self?.refresh()
            }
        }
    }

    /// Reading the caret stops while the displays sleep.
    private func setScreensAsleep(_ asleep: Bool) {
        screensAsleep = asleep
        enabledChanged()
    }

    /// Whether the caret is read: the dot is the chosen indicator, it has
    /// started, and the screen is unlocked and awake.
    private var running: Bool { shown && !screensAsleep && !locked && tracker != nil }

    private func enabledChanged() {
        evidence.advance()
        let running = self.running
        let captureEnabled = running && visualFallbackEnabled && captureNeeded
        visual.enabled = captureEnabled
        // A flat control's estimate is shown only while pixels can confirm it.
        tracker?.setPixelsCanConfirm(captureEnabled && CGPreflightScreenCaptureAccess())
        if running {
            evidence.resume()
            tracker?.resume()
        } else {
            // No read starts, and none already on its way can place the dot.
            observation = nil
            isEmailBody = false
            focusedField = nil
            evidence.pause()
            tracker?.pause()
            visual.stop()
        }
        if running, timer == nil {
            let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            // Allowed to drift a little so the system can batch wakeups.
            timer.tolerance = Self.refreshInterval / 4
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            refresh()
        } else if !running {
            timer?.invalidate()
            timer = nil
        }
        update()
    }

    private func refresh() {
        guard running else { return }
        // Expire evidence that no read has renewed, such as while an app
        // is slow to answer.
        if placedDot != nil, reading == nil { update() }
        tracker?.refresh(frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier, generation: evidence.generation)
    }

    private func readingChanged(_ observation: CaretTracker.Observation) {
        // Late replies cannot replace newer evidence; a boundary change
        // rejects every observation queued before it.
        guard evidence.accepts(observation.generation),
              ContinuousClock.now - observation.startedAt <= .milliseconds(250) else { return }
        guard !screensAsleep, !locked,
              observation.panel || observation.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            evidence.clear()
            visual.stop()
            isEmailBody = false
            focusedField = nil
            hide()
            return
        }
        self.observation = observation
        isEmailBody = observation.isEmailBody
        focusedField = NSScreen.screens.first.flatMap { Self.fieldFrame(of: observation, primaryHeight: $0.frame.height) }
        observationChanged?(observation)
        settleIfNeeded(observation.status)
        evidence.record(observation.status, reading: observation.reading, hint: observation.hint, focus: observation.focus, at: observation.startedAt)
        updateCapture()
        update()
    }

    /// Resting non-email fields need no pixel search. Keep AX placement
    /// alive for foot clearance and proposals; captions or active dictation
    /// may still need a pixel anchor where Accessibility has none.
    private var captureNeeded: Bool {
        isEmailBody || dictationPhase != .idle || captionWords != nil
    }

    private func updateCapture() {
        let enabled = running && visualFallbackEnabled && captureNeeded
        let changed = visual.enabled != enabled
        if changed {
            visual.enabled = enabled
            tracker?.setPixelsCanConfirm(enabled && CGPreflightScreenCaptureAccess())
        }
        if let tracker {
            visual.update(enabled ? observation?.visualTarget : nil, tracker: tracker)
        }
        // Classification needs no geometry. Once a flat Gmail body is
        // admitted, ask at once for its estimate instead of waiting a tick.
        if changed, enabled { refresh() }
    }

    private var loggedSource: String?

    private func update() {
        let source = evidence.source(at: .now)
        if source != loggedSource {
            loggedSource = source
            AppLog.caret("dot " + source)
        }
        let reading = self.reading
        let pinned = dictationPhase != .idle && NSWorkspace.shared.frontmostApplication?.processIdentifier == pinnedPID
            ? placedDot : nil
        guard shown, !screensAsleep, !locked, let dot = reading.flatMap({ self.dot(for: $0) }) ?? pinned else {
            hide()
            return
        }
        let ink = reading.map { $0.ink.map { NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: 1) } } ?? placedInk
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(dot.center) }) else {
            hide()
            return
        }
        let frame = screen.frame
        let caret = reading.flatMap { reading in
            NSScreen.screens.first.map {
                DotPlacement.appKitRect(fromAccessibility: reading.caret, primaryScreenHeight: $0.frame.maxY)
            }
        } ?? placedCaret
        let coveredByCard = caret.map { DotPlacement.caretCovered($0, by: proposalCardFrame) } ?? false
        let drawsDot = presentation.dot && !coveredByCard
        let center = CGPoint(x: dot.center.x - frame.minX, y: frame.maxY - dot.center.y)
        // Keep the transparent surface stationary while typing. Moving a
        // window and repainting it are separate WindowServer operations;
        // drawing only the old/new mark regions avoids that extra handoff.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            if panel.frame != frame {
                panel.alphaValue = 0
                showing = false
                host.clearMark()
                panel.setFrame(frame, display: false)
                host.frame = CGRect(origin: .zero, size: frame.size)
                host.needsDisplay = true
            }
            placedDot = dot
            placedInk = ink
            placedCaret = caret
            if drawsDot {
                applyLook()
                host.place(diameter: dot.diameter, ink: ink, center: center)
                host.displayIfNeeded()
                show()
                target.cover(dot, held: dictationPhase == .recording)
            } else {
                #if DEBUG
                if coveredByCard, showing {
                    CaretFixtureMode.dotObservation()
                    DotLog.dot(source: "hidden")
                }
                #endif
                hideDrawing()
            }
            if presentation.dot {
                caption.show(presentation.caption ? captionWords : nil, beside: dot, on: screen)
            } else {
                caption.show(presentation.caption ? captionWords : nil, alignedWith: dot, on: screen.visibleFrame)
            }
        } completionHandler: { }
        // Hand the new frame to the window server now rather than when this
        // run-loop turn ends, so the dot reaches the screen with the caret.
        CATransaction.flush()
        #if DEBUG
        if drawsDot, let reading, let primary = NSScreen.screens.first?.frame.height {
            let placed = CGPoint(x: dot.center.x, y: primary - dot.center.y)
            CaretFixtureMode.dotObservation(caret: reading.caret, center: placed, diameter: dot.diameter, ink: reading.ink)
            DotLog.dot(source: source, caret: reading.caret, center: placed, diameter: dot.diameter, ink: reading.ink)
        }
        #endif
    }

    /// The focused field's frame in AppKit coordinates, from the reading,
    /// the estimate or the field the tracker read, or nil when no field has
    /// focus. An editor that keeps focus in a control a point wide at the
    /// caret, as Monaco in Visual Studio Code and Cursor does, says nothing
    /// of where the editor reaches, so its window's frame stands in for it.
    nonisolated static func fieldFrame(of observation: CaretTracker.Observation, primaryHeight: CGFloat) -> CGRect? {
        guard var field = observation.reading?.field ?? observation.hint?.field ?? observation.fieldFrame else { return nil }
        if field.width < 8, let window = observation.visualTarget?.windowFrame { field = window }
        return DotPlacement.appKitRect(fromAccessibility: field, primaryScreenHeight: primaryHeight)
    }

    /// The dot over the caret in AppKit coordinates, or nil when the caret
    /// is on no display.
    private func dot(for reading: CaretTracker.Reading) -> DotPlacement.Dot? {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        let line = DotPlacement.appKitRect(fromAccessibility: reading.caret, primaryScreenHeight: primaryHeight)
        guard NSScreen.screens.contains(where: { $0.frame.contains(CGPoint(x: line.midX, y: line.midY)) }) else { return nil }
        let field = reading.field.map { DotPlacement.appKitRect(fromAccessibility: $0, primaryScreenHeight: primaryHeight) }
        return DotPlacement.dot(aboveCaret: line, in: field)
    }

    private func show() {
        guard !showing else { return }
        showing = true
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        host.displayIfNeeded()
    }

    private func hideDrawing() {
        // Hidden marks need neither a repeating pulse nor microphone animation.
        host.look = .resting
        showing = false
        panel.alphaValue = 0
        host.clearMark()
        target.orderOut(nil)
    }

    private func hide() {
        // Evidence loss must remove the old position immediately.
        #if DEBUG
        if showing {
            CaretFixtureMode.dotObservation()
            DotLog.dot(source: "hidden")
        }
        #endif
        // A notice is set just before the dictation's phase turns idle, so
        // one due beside a dot that goes in that moment, such as on an app
        // switch, is passed on too.
        let lost = placedDot != nil ? notice : nil
        placedDot = nil
        placedInk = nil
        placedCaret = nil
        hideDrawing()
        caption.hide()
        if let lost { noticeLost(lost) }
    }
}

extension DotMarkView.Look {
    init(_ look: DotLook) {
        switch look {
        case .resting: self = .resting
        case .recording: self = .recording
        case .heard: self = .heard
        case .working: self = .working
        case .proposed: self = .proposed
        }
    }
}

extension ProposalObservation {
    /// The parts of a tracker observation a reply proposal follows: the
    /// estimate stands in for the reading on a flat Gmail body, and a field
    /// counts as focused whenever the tracker saw one, placed or not.
    init(_ observation: CaretTracker.Observation) {
        let reading = observation.reading ?? observation.hint
        self.init(pid: observation.pid, focus: observation.focus, edit: observation.edit, startedAt: observation.startedAt,
                  focused: observation.fieldFocused, caret: reading?.caret, field: reading?.field ?? observation.fieldFrame, selection: observation.selection)
    }
}
