import AppKit

/// Who opens System Settings after Intention asks macOS for Accessibility or
/// Screen Recording.
///
/// macOS answers a request with an alert of its own, whose button opens the
/// right list. When Intention opened that list as well, the Settings window
/// came in front of the alert a moment later and covered it whole, and a
/// Screen Recording request leaves Intention out of its list until the alert
/// is answered, so the person had a list with no line to switch on. So
/// after asking, Intention looks for the alert for `watch`. When the alert
/// comes up in front, Intention opens nothing and the alert's button opens the
/// list. When none does, as when macOS has shown it once before and shows
/// nothing more, Intention opens the list.
///
/// The alert is seen in the window server's list, which needs no
/// permission. That list names the process that owns each window and not
/// the app an alert is about, since titles need Screen Recording, so two
/// things keep a wrong guess harmless. Only an alert that is the frontmost
/// ordinary window counts: one behind another window, on a Space that is
/// not showing, or not there at all is not in front of the person, and the
/// list then opens as it did before this rule. And an alert that was in
/// front before Intention asked is somebody else's, so only a different one
/// counts as the answer to this request, unless it is the very alert an
/// earlier request of Intention's was answered by.
enum PermissionAlert {
    /// The process that shows both alerts on macOS 27.2. Its bundle gives
    /// the name no translation, so it reads the same in every language.
    static let owner = "universalAccessAuthWarn"

    /// How long to look for the alert. Timed on macOS 27.2, it was the
    /// frontmost ordinary window 20 to 61 ms after the request with its
    /// process already running, and 179 to 201 ms with it not running.
    static let watch = Duration.milliseconds(1500)

    /// One window on screen, as the window server lists it.
    struct Window {
        var owner: String?
        var layer: Int
        var number: CGWindowID?
    }

    /// The alert's window number when the alert is the frontmost ordinary
    /// window in `windows`, which run front to back. Menus, the menu bar
    /// and Intention's own dot sit on higher layers and are passed over.
    static func inFront(_ windows: [Window]) -> CGWindowID? {
        guard let front = windows.first(where: { $0.layer == 0 }), front.owner == owner else { return nil }
        return front.number
    }

    enum Step: Equatable {
        case keepWatching
        /// The alert for this request is in front. Its button opens the
        /// list, so Intention opens nothing.
        case leaveToAlert
        /// No alert came up in front, so Intention opens the list.
        case openSettings
    }

    /// What to do after one look at the screen. `inFrontBefore` is what
    /// `inFront` gave just before Intention asked, `inFrontNow` what it gives
    /// `waited` after.
    static func step(inFrontBefore: CGWindowID?, inFrontNow: CGWindowID?, waited: Duration) -> Step {
        if let inFrontNow, inFrontNow != inFrontBefore { return .leaveToAlert }
        return waited < watch ? .keepWatching : .openSettings
    }

    /// How a request ended. Only `noAlert` opened anything.
    enum Outcome: Equatable {
        /// An alert is in front and its button opens the list.
        case alertInFront
        /// No alert came up in front, and `open` was called. It may have
        /// declined to open anything.
        case noAlert
        /// The request's task was cancelled, as when setup's window closes.
        /// Whoever asked has left, so nothing more should be done for it.
        /// One cancelled before its turn did not ask macOS either.
        case cancelled
    }

    /// Makes a request of macOS with `ask`, watches the screen for the
    /// alert, and calls `open` when none came up in front. `open` answers
    /// whether it opened System Settings.
    @MainActor
    @discardableResult
    static func request(_ ask: @MainActor () -> Void, open: @MainActor () -> Bool) async -> Outcome {
        await Requests.shared.request(ask, clock: ContinuousClock(), look: { inFront(windowsOnScreen()) }, open: open,
                                      arrived: { settingsInFront() })
    }

    /// How long a list Intention opened is given to come forward before the
    /// next request may ask. It took 0.7 seconds the one time it was
    /// timed, with System Settings not yet running.
    static let arrival = Duration.seconds(3)

    /// The least time a list Intention opened is given, even with System
    /// Settings in front. It may have been in front already on another
    /// page, and the open then brings it forward again a moment later.
    static let settle = Duration.seconds(1)

    /// The requests Intention makes, one at a time. The app has one, `shared`;
    /// tests make their own and script the clock and the looks at the
    /// screen.
    ///
    /// Alerts cannot be told apart, so two requests watched at once could
    /// each take the other's alert for its own, or for somebody else's,
    /// and one could open its list over the other's alert or over the
    /// other's list. A request made during another's watch therefore waits
    /// until that one has finished, its list opened if it opens one, and
    /// only then asks macOS and is watched itself. Lists open in the order
    /// the requests were made. A list Intention opens takes a moment to come
    /// forward, and an alert that came up in that moment would end up
    /// under it, so after a request has opened one the turn is kept until
    /// System Settings is in front and `settle` has passed, or for
    /// `arrival` if it never is. The
    /// request itself has ended by then, and cancelling it does not give
    /// the turn up early, since an opened list cannot be taken back. The
    /// cost is that the second of two requests made close together asks
    /// late, by up to `watch` and the time the list takes.
    @MainActor
    final class Requests {
        static let shared = Requests()

        private let settle: Duration

        /// Tests pass their own `settle`.
        init(settle: Duration = PermissionAlert.settle) {
            self.settle = settle
        }

        /// Whether a request has the turn, and the ones waiting for it in
        /// the order they were made.
        private var isBusy = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        /// How many requests wait their turn. Tests read it.
        var queued: Int { waiting.count }
        /// Whether the turn is being kept for a list on its way to the
        /// front. Tests read it.
        private(set) var isHolding = false
        /// The alert the latest watch left System Settings to. While this
        /// same window is in front it answers the next request too: the
        /// person has not answered it yet, and a list opened over it would
        /// hide it again. Any other alert already in front is somebody
        /// else's. There is no way back for another app's alert taken for
        /// Intention's by mistake, and none is needed: an alert that is the
        /// frontmost ordinary window is in front of the person, answering
        /// it removes it, and the next press then opens the list.
        private var leftTo: CGWindowID?

        /// Waits its turn, asks, and watches for `watch` from the asking.
        /// `arrived` is whether System Settings is in front.
        func request<C: Clock>(_ ask: @MainActor () -> Void, clock: C, look: @MainActor () -> CGWindowID?,
                               open: @MainActor () -> Bool, arrived: @escaping @MainActor () -> Bool) async -> Outcome
            where C.Duration == Duration {
            guard !Task.isCancelled else { return .cancelled }
            if isBusy {
                await withCheckedContinuation { waiting.append($0) }
            } else {
                isBusy = true
            }
            defer {
                if !isHolding { passTurn() }
            }
            // A request cancelled before its turn asks nothing of macOS.
            guard !Task.isCancelled else { return .cancelled }
            var before = look()
            if before != leftTo { leftTo = nil }
            // The alert the last watch left the list to counts as an
            // answer to this request for as long as it stays in front. If
            // it goes while macOS is asked and nothing takes its place,
            // the watch runs on and the list opens.
            if leftTo != nil { before = nil }
            let asked = clock.now
            ask()
            while true {
                // Checked after every wait, and so right before the list
                // could be opened.
                guard !Task.isCancelled else { return .cancelled }
                let inFront = look()
                switch step(inFrontBefore: before, inFrontNow: inFront, waited: asked.duration(to: clock.now)) {
                case .leaveToAlert:
                    leftTo = inFront
                    AppLog.event("Permission alert in front; System Settings left to it")
                    return .alertInFront
                case .openSettings:
                    AppLog.event("No permission alert in front")
                    guard open() else { return .noAlert }
                    // The turn is kept until the list is in front, so the
                    // next request's alert comes up over it and not under.
                    // That wait is the queue's and not this request's, so
                    // this request's cancellation cannot end it.
                    isHolding = true
                    Task {
                        let opened = clock.now
                        while true {
                            let waited = opened.duration(to: clock.now)
                            if waited >= arrival || (waited >= self.settle && arrived()) { break }
                            try? await clock.sleep(for: .milliseconds(100))
                        }
                        self.isHolding = false
                        self.passTurn()
                    }
                    return .noAlert
                case .keepWatching:
                    try? await clock.sleep(for: .milliseconds(100))
                }
            }
        }

        /// The turn passes straight to the request that has waited
        /// longest.
        private func passTurn() {
            if waiting.isEmpty { isBusy = false } else { waiting.removeFirst().resume() }
        }
    }

    /// Whether System Settings owns the frontmost ordinary window.
    @MainActor private static func settingsInFront() -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]]
        guard let front = windows?.first(where: { $0[kCGWindowLayer] as? Int ?? 0 == 0 }),
              let owner = front[kCGWindowOwnerPID] as? pid_t else { return false }
        return NSRunningApplication(processIdentifier: owner)?.bundleIdentifier == "com.apple.systempreferences"
    }

    /// Every window on the Spaces now showing, front to back. A window
    /// whose layer cannot be read counts as an ordinary one, so an alert
    /// behind it is never taken for the frontmost.
    private static func windowsOnScreen() -> [Window] {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]]
        return (windows ?? []).map { window in
            Window(owner: window[kCGWindowOwnerName] as? String, layer: window[kCGWindowLayer] as? Int ?? 0,
                   number: window[kCGWindowNumber] as? CGWindowID)
        }
    }
}
