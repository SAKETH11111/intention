/// The grants setup asks for, in the order it asks: the microphone first,
/// because macOS answers it with one click, then Accessibility, which takes
/// a trip to System Settings. Screen Recording is left for later; it only
/// adds the dot in apps that hide their caret, and granting it can force a
/// quit and reopen. The clipboard is not asked for in setup: Intention asks at
/// the first paste that replaced what the person had copied, from the
/// menu bar item, which is the moment it matters.
enum SetupPermission: CaseIterable, Sendable {
    case microphone, accessibility

    /// What setup needs before it moves on, in the order it asks.
    static let required: [SetupPermission] = [.microphone, .accessibility]
}

/// How setup reads and asks for those grants. A value of closures, so the
/// setup flow can be tested without touching the system's privacy database.
struct SetupPermissions: Sendable {
    var isGranted: @MainActor @Sendable (SetupPermission) -> Bool
    /// Asks macOS for the grant: its own prompt the first time, and the
    /// matching Privacy & Security pane when the prompt cannot appear again.
    var request: @MainActor @Sendable (SetupPermission) async -> Void
}
