import AppKit
import os

/// Classifies each focus identity off the placement executor. Only
/// metadata used by voice compose is read; a slow Mail walk cannot delay a
/// caret reading. Requests coalesce to the newest focus while a walk runs.
final class CaretEmailBody: @unchecked Sendable {
    struct Focus: Equatable, Sendable {
        var serial: Int
        var pid: pid_t
    }
    private struct Request {
        var focus: Focus
        var element: AXElement
    }
    static let retryDelays: [Duration] = [.milliseconds(100), .milliseconds(250)]

    private struct State {
        var focus: Focus?
        var pending: Request?
        var running = false
        var result: Bool?
        var attempts = 0
        var retryAfter: ContinuousClock.Instant?
        var inFlight: Focus?
        var revision = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    // An exiting worker can still occupy one slot when the next focus arrives.
    private let executor = AccessibilityExecutor(capacity: 2)
    private let changed: @Sendable (Focus, Bool) -> Void
    private let now: @Sendable () -> ContinuousClock.Instant

    convenience init(changed: @escaping @Sendable (Focus, Bool) -> Void = { _, _ in }) {
        self.init(now: { .now }, changed: changed)
    }

    init(now: @escaping @Sendable () -> ContinuousClock.Instant, changed: @escaping @Sendable (Focus, Bool) -> Void) {
        self.changed = changed
        self.now = now
    }

    /// The classifier reports from its executor; consumers of AppKit state
    /// always receive the answer on the main actor.
    static func reporter(_ receive: @escaping @MainActor @Sendable (Focus, Bool) -> Void) -> @Sendable (Focus, Bool) -> Void {
        { @Sendable focus, body in
            DispatchQueue.main.async { receive(focus, body) }
        }
    }

    func result(for focus: Focus) -> Bool {
        state.withLock { $0.focus == focus && $0.result == true }
    }

    /// Called from the tracker executor, which already owns this element.
    /// AX handles are sent to the classification executor, never to a view;
    /// all identity checks and metadata reads happen on that executor.
    func observe(_ focus: Focus?, element: AXElement?) {
        let start = state.withLock { state in
            if state.focus != focus {
                state.focus = focus
                state.revision &+= 1
                state.result = nil
                state.attempts = 0
                state.retryAfter = nil
                state.pending = nil
            }
            guard let focus, let element, state.result == nil,
                  state.attempts <= Self.retryDelays.count,
                  state.inFlight != focus, state.pending == nil,
                  state.retryAfter.map({ now() >= $0 }) ?? true else { return false }
            state.pending = Request(focus: focus, element: element)
            guard !state.running else { return false }
            state.running = true
            return true
        }
        if start { executor.submit { @Sendable _ in self.drain() } }
    }

    private func drain() {
        precondition(executor.isCurrent)
        while let (request, revision) = state.withLock({ state -> (Request, Int)? in
            guard let request = state.pending else { state.running = false; state.inFlight = nil; return nil }
            state.pending = nil
            state.inFlight = request.focus
            state.attempts += 1
            return (request, state.revision)
        }) {
            let body = Self.classify(request)
            let accepted = state.withLock { state in
                guard state.revision == revision, state.focus == request.focus else { return false }
                state.result = body
                if body == nil, state.attempts <= Self.retryDelays.count {
                    state.retryAfter = now() + Self.retryDelays[state.attempts - 1]
                }
                return true
            }
            if accepted { changed(request.focus, body == true) }
        }
    }

    private static func classify(_ request: Request) -> Bool? {
        guard request.focus.pid != ProcessInfo.processInfo.processIdentifier else { return false }
        guard let focused = stillFocused(request.element, pid: request.focus.pid) else { return nil }
        guard focused else { return false }
        let body = isEmailBody(request.element, pid: request.focus.pid)
        guard let stillFocused = stillFocused(request.element, pid: request.focus.pid) else { return nil }
        return stillFocused ? body : false
    }

    // Voice compose also admits Gmail's paste-only bodies, so this has no
    // generic settable-field gate before the provider's own decision.
    private static func isEmailBody(_ element: AXElement, pid: pid_t) -> Bool? {
        guard case let .success(window) = element.element(kAXWindowAttribute),
              let secure = AXWritingSurface.secureAncestry(element, window: window) else { return nil }
        guard !secure else { return false }
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        let description: String
        if bundle == ComposeAccess.mailBundleIdentifier {
            description = ""
        } else {
            guard case let .success(value) = element.string(kAXDescriptionAttribute) else { return nil }
            description = value
        }
        func markers() -> Bool? {
            guard let names = element.parameterizedNames() else { return nil }
            guard names.isSuperset(of: AXElement.markerEditing) else { return false }
            // The AX adapter collapses an unanswered settable read to false.
            guard element.isSettable(kAXValueAttribute) else { return nil }
            return true
        }
        return ComposeAccess.emailBodyClassification(element, window: window, labels: description,
                                                      markers: markers(), bundleIdentifier: bundle)
    }

    private static func stillFocused(_ element: AXElement, pid: pid_t) -> Bool? {
        guard AXIsProcessTrusted() else { return false }
        let now: AXElement
        switch AXElement(ref: AXUIElementCreateSystemWide()).element(kAXFocusedUIElementAttribute) {
        case let .success(value): now = value
        case let .failure(error) where error.code == .noValue: return false
        case .failure: return nil
        }
        guard now.sameElement(as: element) else { return false }
        var owner: pid_t = 0
        guard AXUIElementGetPid(now.ref, &owner) == .success else { return nil }
        return owner == pid
    }
}
