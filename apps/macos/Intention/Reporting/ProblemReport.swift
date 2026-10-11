import Foundation

/// A report contains the person's note only for the private alpha database.
/// Event names have their own closed contract; arbitrary log lines never enter it.
struct ProblemReport: Codable, Sendable, Equatable {
    var report_id: UUID
    var text: String?
    let app_version: String
    let app_build: String
    let macos_version: String
    let frontmost_bundle_id: String?
    let captured_at: String
    let window_started_at: String
    let events: [DiagnosticEvents.Event]
    let events_truncated: Bool
    let setup: Setup
    let mail_import: MailImport

    struct Setup: Codable, Sendable, Equatable {
        let finished: Bool
        let signed_in: Bool
        let microphone: Bool
        let accessibility: Bool
        let screen_recording: Bool
    }

    struct MailImport: Codable, Sendable, Equatable {
        let known: Bool
        let read_failed: Bool
        let connections: Int
        let importing: Int
        let ready: Int
        let reconnect: Int
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// One open prompt owns one snapshot and one credential. Retries of an
/// unchanged note use exactly the same report, including its identifier.
@MainActor
final class ProblemReportSubmission {
    static let maxTextLength = 4000
    enum Failure: Error, Equatable {
        case signedOut, unavailable, tooLong, sendFailed
        case rateLimited(until: Date)
        var userFacingMessage: String {
            switch self {
            case .signedOut: "Sign in to send a report."
            case .unavailable: "Reporting isn't available in this build."
            case .tooLong: "Keep your note under 4,000 characters."
            case .sendFailed: "Couldn't send. Try again."
            case .rateLimited: "Too many reports. Please wait before trying again."
            }
        }
    }

    private var report: ProblemReport
    private let upload: @Sendable (ProblemReport) async throws -> Void
    private let now: @Sendable () -> Date
    private var retryAt: Date?
    private var attempted = false
    private var sending = false
    private var sent = false

    init(report: ProblemReport, now: @escaping @Sendable () -> Date = Date.init, upload: @escaping @Sendable (ProblemReport) async throws -> Void) {
        self.report = report
        self.now = now
        self.upload = upload
    }

    func send(text: String) async throws {
        guard text.unicodeScalars.count <= Self.maxTextLength else { throw Failure.tooLong }
        if let retryAt, now() < retryAt { throw Failure.rateLimited(until: retryAt) }
        guard !sending else { throw Failure.sendFailed }
        guard !sent else { return }
        let note = text.isEmpty ? nil : text
        if attempted, report.text != note { report.report_id = UUID() }
        report.text = note
        attempted = true
        sending = true
        defer { sending = false }
        do {
            try await upload(report)
            sent = true
        } catch let Failure.rateLimited(until) {
            retryAt = until
            throw Failure.rateLimited(until: until)
        }
    }
}
