/// The shipping app refuses render modes, but filenames are ordinary data.
enum RenderArguments {
    static func requiresRenderWorker(_ arguments: [String], renderGuard: String?) -> Bool {
        if renderGuard == "1" { return true }
        let modes: Set<String> = [
            "--card-snapshots", "--caret-snapshots", "--controls-snapshot",
            "--dot-snapshots", "--fn-reliability-snapshots", "--foot-snapshots",
            "--foot-menu-snapshot", "--home-snapshot", "--onboarding-snapshots",
            "--report-snapshots", "--settings-snapshot", "--update-snapshots",
            "--onboarding-demo", "--dot-demo", "--foot-demo", "--sun-landing",
            "--foot-menu-mock", "--placement-frames", "--placement-stills",
        ]
        return arguments.dropFirst().contains { modes.contains($0) }
    }
}
