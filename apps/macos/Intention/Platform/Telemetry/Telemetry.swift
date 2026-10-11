import Foundation

/// The demo records no remote telemetry.
enum Telemetry {
    static func accepts(startedAt: Date) -> Bool { false }
    @discardableResult
    static func start(bundle: Bundle = .main, dsn: String? = nil,
                      deliveryObserver: (@Sendable (Int) -> Void)? = nil) -> Bool { false }
    static func identify(accountID: UUID?) {}
    static func flushCheck() -> String? { nil }
    static func dsn(in bundle: Bundle) -> String? { nil }
    static func record(_ timing: DictationTiming, recordDiagnostics: Bool = true) {}
    static func record(_ timing: ProposalTiming, recordDiagnostics: Bool = true) {}
    static func record(_ timing: FirstRunTiming) {}
    enum FailureLevel { case warning, error }

    /// Refusals caused by the target or the person's input have a Copy popup.
    /// Unknown writes and technical failures still need an error alert.
    static func insertionFailureLevel(_ result: InsertionResult?) -> FailureLevel {
        guard case let .notInserted(reason) = result else { return .error }
        switch reason {
        case .permissionMissing, .noTextField, .ownApp, .secureField, .focusChanged,
             .fieldChanged, .clipboardBusy, .composeChanged, .appEnded: return .warning
        default: return .error
        }
    }

}
