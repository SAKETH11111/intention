import AppKit

/// Exercise the real setup cues and the full snapshot flow without demo mode.
@main
struct OnboardingSoundProbe: GuardedRender {
    static func render() {
        precondition(CommandLine.arguments.count == 2)
        precondition(ProcessSafety.isSilent)
        precondition(!OnboardingFixture.isDemo)
        precondition(!SetupSound.accepted.play())
        precondition(!SetupSound.landed.play())
        print("PASS SetupAccepted and SetupLanded are suppressed outside demo mode")
        OnboardingSnapshots.renderIfRequested(arguments: [
            CommandLine.arguments[0], "--onboarding-snapshots", CommandLine.arguments[1],
        ])
        preconditionFailure("The full onboarding snapshot flow did not run")
    }
}
