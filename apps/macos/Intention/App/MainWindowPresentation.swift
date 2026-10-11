import AppKit

/// Activation belongs to an explicit window request, never to Dock policy
/// reconciliation or the nonactivating panels that can make the request.
@MainActor
final class MainWindowPresentation {
    private let dock: DockActivationController
    private let activate: @MainActor () -> Void
    private let frontmost: @MainActor () -> pid_t?
    private let nextTurn: (@escaping @Sendable () -> Void) -> Void
    /// The window asked for while the app is being promoted, presented once
    /// the promotion has landed. Further requests in that time replace it
    /// rather than activating early.
    private var pending: NSWindow?
    /// The app in front when the request was made, so a person who moves to
    /// another app before the promotion lands keeps it.
    private var frontmostAtRequest: pid_t?

    init(dock: DockActivationController = .shared,
         activate: @escaping @MainActor () -> Void = {
             // activate() is cooperative and may be declined. A click in our
             // nonactivating panel cannot make the foreground app yield, and
             // NSRunningApplication's ignoringOtherApps flag has no effect
             // since macOS 14. Use AppKit's unconditional request only here,
             // when the person explicitly asks for the main window.
             NSApp.activate(ignoringOtherApps: true)
         },
         frontmost: @escaping @MainActor () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
         nextTurn: @escaping (@escaping @Sendable () -> Void) -> Void = {
             DispatchQueue.main.async(execute: $0)
         }) {
        self.dock = dock
        self.activate = activate
        self.frontmost = frontmost
        self.nextTurn = nextTurn
    }

    func show(_ window: NSWindow) {
        let scheduled = pending != nil
        let promoting = scheduled || dock.policy != .regular
        dock.willOpen(window)
        guard promoting else {
            finish(window)
            return
        }
        // Keep this window counted while AppKit processes the policy
        // change. Activation in the promotion's stack can arrive before the
        // Dock and menu bar transition has been processed, so it waits a
        // turn, and requests made meanwhile join it.
        window.orderFrontRegardless()
        pending = window
        if !scheduled {
            frontmostAtRequest = frontmost()
            nextTurn(Self.completion(self))
        }
    }

    func cancel() {
        pending = nil
    }

    private func finish(_ window: NSWindow) {
        activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func completePending() {
        guard let window = pending else { return }
        pending = nil
        // Moving to another app while the policy changed is a newer choice
        // than the request; it stands.
        let now = frontmost()
        guard window.isVisible, now == frontmostAtRequest || now == ProcessInfo.processInfo.processIdentifier else { return }
        finish(window)
    }

    /// A scheduler can invoke the callback off-main; no actor-isolated
    /// closure crosses that framework boundary.
    nonisolated static func completion(_ presentation: MainWindowPresentation) -> @Sendable () -> Void {
        { [weak presentation] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { presentation?.completePending() }
            } else {
                DispatchQueue.main.async { presentation?.completePending() }
            }
        }
    }
}
