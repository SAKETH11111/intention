/// Whether Intention opens at login, as setup's last page reads and answers
/// it. A value of closures, so the setup flow can be tested without
/// registering anything with macOS.
struct SetupLoginItem {
    /// Whether Intention opens at login already, or will once it is opened
    /// from Applications. The page is not shown then.
    var isOn: @MainActor () -> Bool
    /// The person's answer. Only yes registers anything.
    var answer: @MainActor (Bool) -> Void
}
