import AppKit
import ApplicationServices
import Foundation

/// Tells, for the email hint (`EmailHints`), when keyboard focus moves to a
/// new element and whether that element is the body of an email being
/// written, decided as dictation decides it (`ComposeAccess.isEmailBody`).
///
/// It reads only while the hint is wanted: twice a second it asks the
/// frontmost app which element has keyboard focus, and only for an element
/// it has not seen just before does it read more: the element's window, the
/// subrole of it and its ancestors up to that window, so a secure field is
/// refused before anything else, whether its value or selected text can be
/// set, so only a text box counts, and then what dictation reads to tell an
/// email body: the field's own description and its page's address, or in
/// Mail whether it is a web area edited through text markers and whether
/// its window holds Mail's To field. No text is ever read. Intention's own
/// windows are never email bodies. While the hint is not wanted, as before
/// setup signs in, nothing is read, and once it has retired for good the
/// watch stops. It works the same whichever indicator the person chose,
/// since the dot's tracker stops when the caret dot is hidden.
///
/// Its own Accessibility thread keeps a slow app, or the walk of a Mail
/// window, from delaying the dot or an insertion.
final class EmailBodyWatch: @unchecked Sendable {
    /// How often focus is asked for while the hint is wanted.
    static let interval: TimeInterval = 0.5

    private let executor = AccessibilityExecutor(capacity: 1)
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    /// Called on the watch's thread with each new focused element's answer.
    private let changed: @Sendable (_ emailBody: Bool) -> Void
    /// The element last reported, on the executor only.
    private var focused: AXElement?
    @MainActor private var timer: Timer?
    /// Whether the last tick asked for focus.
    @MainActor private var checking = false

    init(changed: @escaping @Sendable (_ emailBody: Bool) -> Void) {
        self.changed = changed
    }

    /// Asks focus twice a second while `wanted` holds, and stops for good
    /// once `retired` does, since a retired hint never comes back.
    @MainActor
    func start(while wanted: @escaping @MainActor () -> Bool, until retired: @escaping @MainActor () -> Bool) {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(wanted: wanted, retired: retired) }
        }
        timer.tolerance = Self.interval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @MainActor
    private func tick(wanted: @MainActor () -> Bool, retired: @MainActor () -> Bool) {
        if retired() {
            timer?.invalidate()
            timer = nil
        }
        guard timer != nil, wanted() else {
            // The element focused when the hint is wanted again is new to it.
            if checking { forget() }
            checking = false
            return
        }
        checking = true
        check(frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    /// Reads which element of `pid`'s app has keyboard focus and, for a new
    /// one, whether it is an email body. Skipped while a check still runs.
    func check(frontmost pid: pid_t?) {
        executor.submit(deadline: .now + .seconds(1)) { expired in
            guard !expired else { return }
            self.read(pid)
        }
    }

    /// Forgets the last element, so the one focused when the watch asks
    /// again is reported.
    private func forget() {
        executor.submitCleanup { self.focused = nil }
    }

    private func read(_ pid: pid_t?) {
        precondition(executor.isCurrent)
        guard AXIsProcessTrusted(), let pid, pid != ownPID,
              case let .success(element) = AXElement.application(pid).element(kAXFocusedUIElementAttribute) else {
            // Nothing has focus, or it is Intention's own: not an email body.
            if focused != nil {
                focused = nil
                changed(false)
            }
            return
        }
        if let focused, focused.sameElement(as: element) { return }
        focused = element
        let isBody = Self.isEmailBody(element, pid: pid)
        // The walk of a Mail window can outlast the focus it was about. An
        // element that no longer has keyboard focus, anywhere, is not
        // reported, so the hint never shows beside another field and the
        // element focused now is read at the next tick.
        guard Self.stillFocused(element) else {
            // Said as a field that is not a body, so a hint waiting on the
            // element that was focused ends with it.
            focused = nil
            changed(false)
            return
        }
        changed(isBody)
    }

    /// Whether `element` still has keyboard focus system-wide, read after
    /// a classification so a late answer is dropped.
    private static func stillFocused(_ element: AXElement) -> Bool {
        guard case let .success(now) = AXElement(ref: AXUIElementCreateSystemWide()).element(kAXFocusedUIElementAttribute) else {
            return false
        }
        return now.sameElement(as: element)
    }

    /// Whether `element` is the body of an email being written, reading no
    /// text. Its window and secure ancestry come first, then whether it
    /// takes text, then `ComposeAccess`'s own decision.
    private static func isEmailBody(_ element: AXElement, pid: pid_t) -> Bool {
        guard case let .success(window) = element.element(kAXWindowAttribute),
              AXWritingSurface.secureAncestry(element, window: window) == false,
              element.isSettable(kAXValueAttribute) || element.isSettable(kAXSelectedTextAttribute) else { return false }
        let bundleIdentifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        // Any field in Mail could be one, so its description is not read there.
        let description = bundleIdentifier == ComposeAccess.mailBundleIdentifier
            ? "" : (try? element.string(kAXDescriptionAttribute).get()) ?? ""
        return ComposeAccess.isEmailBody(element, window: window, labels: description,
                                         markers: (try? element.string(kAXRoleAttribute).get()) == "AXWebArea"
                                             && element.isSettable(kAXValueAttribute)
                                             && element.parameterizedNames()?.isSuperset(of: AXElement.markerEditing) == true,
                                         bundleIdentifier: bundleIdentifier)
    }
}
