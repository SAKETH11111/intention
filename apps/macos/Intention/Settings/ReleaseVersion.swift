/// What a person sees of the version: the marketing version alone, such as
/// "Intention 0.0.1". The build number still rises with every release for
/// disabled updater, telemetry, reports and the server; it is not shown.
enum ReleaseVersion {
    static func label(version: String) -> String {
        "Intention \(version)"
    }
}
