import CoreGraphics

/// Asks for Screen Recording once on the person's behalf, for finding the
/// caret on screen, which is on by default. Chromium answers no caret
/// geometry for an empty input, textarea or editor without a line element,
/// as on first focus, so without the grant those show no dot until
/// something is typed.
///
/// Setup asks only for the microphone and Accessibility, so the request
/// comes as setup ends, which follows the person's own press and so asks
/// the way a button does, through `PermissionAlert`. A Mac set up before
/// that is asked at launch, by macOS's request alone, which opens nothing.
/// Launch never asks while setup is unfinished.
///
/// Every closure here runs on the main actor and says so in its type: none
/// is handed to a framework that could call it on another queue, and the
/// compiler refuses any that would be, rather than the runtime trapping.
@MainActor
final class ScreenRecordingRequest {
    let preferences: Preferences
    let isGranted: @MainActor () -> Bool
    /// macOS's request alone.
    let request: @MainActor () -> Void
    /// Makes `ask` the way a press does: the alert's button opens the list,
    /// or Intention opens it when no alert comes up in front. It may run
    /// `ask` later, or never if its task is cancelled first. `ask` says
    /// whether it asked macOS; when it did not, nothing opens.
    let requestFromPress: @MainActor (_ ask: @escaping @MainActor () -> Bool) -> Void
    /// A press-style request is waiting its turn. Setup can end again
    /// before it runs, after an account change, and must not queue another.
    private var queued = false
    private var observedGrant: Bool
    private var monitor: Task<Void, Never>?
    var reported: (@MainActor (Bool) -> Void)?

    init(preferences: Preferences, isGranted: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() },
         request: @escaping @MainActor () -> Void = { _ = CGRequestScreenCaptureAccess() },
         requestFromPress: @escaping @MainActor (_ ask: @escaping @MainActor () -> Bool) -> Void) {
        self.preferences = preferences
        self.isGranted = isGranted
        self.request = request
        self.requestFromPress = requestFromPress
        observedGrant = isGranted()
    }

    deinit { monitor?.cancel() }

    /// A permission can change in System Settings long after the request.
    /// Preflight reads the grant only; it captures no screen contents.
    func startMonitoring() {
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self else { return }
                self.refresh()
            }
        }
    }

    func refresh() {
        let granted = isGranted()
        guard granted != observedGrant else { return }
        observedGrant = granted
        reported?(granted)
    }

    func atLaunch() {
        guard !preferences.screenRecordingLaunchDeferred, due else { return }
        ask()
    }

    func afterSetup() {
        guard due, !queued else { return }
        queued = true
        requestFromPress { [self] in
            queued = false
            // The person may have hidden the caret dot or turned the option off
            // while the request waited its turn.
            guard due else { return false }
            ask()
            return true
        }
    }

    /// Once only, with the dot and the option on, and never once granted.
    /// Setup's last page reads it to show the switch before the alert.
    var due: Bool {
        preferences.asksForScreenRecordingAtLaunch && !isGranted()
    }

    /// Remembered only as macOS is asked, so a request that never ran, as
    /// when Intention quits just after setup, is made at the next launch.
    private func ask() {
        preferences.screenRecordingRequested = true
        request()
        observedGrant = isGranted()
        reported?(observedGrant)
    }
}
