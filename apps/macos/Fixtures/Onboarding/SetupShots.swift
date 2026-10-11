import AppKit

// The entry point of the small bundle scripts/onboarding-shots.sh builds:
// the setup window's sources without the rest of the app. It draws the
// pages to PNGs, or with `--onboarding-demo <seconds>` plays setup by
// itself in a window behind the desktop, for scripts/onboarding-video.sh
// to record.
@main
struct SetupShots: GuardedRender {
    @MainActor
    static func render() {
        let app = NSApplication.shared
        OnboardingSnapshots.renderIfRequested(arguments: CommandLine.arguments)
        guard OnboardingFixture.isDemo else { exit(2) }
        app.setActivationPolicy(.prohibited)
        let seconds = CommandLine.arguments.last.flatMap(Double.init) ?? 40
        let model = OnboardingFixture.model(permissions: SetupPermissions(isGranted: { _ in false }, request: { _ in }))
        let window = OnboardingWindow(model: model)
        window.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
        withExtendedLifetime(window) { app.run() }
    }
}
