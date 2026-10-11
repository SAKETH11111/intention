import Foundation

/// Updates are unavailable in the standalone demo.
@MainActor
final class AppUpdater {
    var isBusy: () -> Bool = { false }
    var isActive: Bool { false }
    init(bundle: Bundle = .main) {}
    func installIfWaiting() {}
    func checkForUpdates() {}
    static func isConfigured(_ bundle: Bundle) -> Bool { false }
}

final class UpdateWindowPresentation: NSObject, Sendable {
    private let beforeShow: @MainActor @Sendable () -> Void

    init(beforeShow: @escaping @MainActor @Sendable () -> Void = { DockActivationController.shared.willPresentUpdate() }) {
        self.beforeShow = beforeShow
    }

    nonisolated func willShow() {
        let beforeShow = beforeShow
        if Thread.isMainThread {
            MainActor.assumeIsolated { beforeShow() }
        } else {
            DispatchQueue.main.async { beforeShow() }
        }
    }

    // The installer probe completes asynchronously before the update adapter asks
    // whether a manual check may begin. Promotion belongs at that seam.
    nonisolated func updateCheckMayBegin(userInitiated: Bool) {
        if userInitiated { willShow() }
    }

}
