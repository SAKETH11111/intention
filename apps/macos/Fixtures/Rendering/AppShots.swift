import AppKit

/// All full-source snapshots enter here before any model or view exists.
@main
struct AppShots: GuardedRender {
    static func render() {
        let arguments = CommandLine.arguments
        OnboardingSnapshots.renderIfRequested(arguments: arguments)
        HomeSnapshot.renderIfRequested(arguments: arguments)
        ControlsSnapshot.renderIfRequested(arguments: arguments)
        guard SettingsSnapshot.isRequested, OnboardingFixture.isRequested else { exit(2) }
        // If AppModel or a controller orders a panel, the guard terminates
        // here, before AppKit's implementation. It must never be bypassed.
        let model = AppModel()
        SettingsSnapshot.renderIfRequested(arguments: arguments, model: model)
        FootMenuSnapshot.renderIfRequested(arguments: arguments, model: model)
    }
}
