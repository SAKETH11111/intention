import Foundation
import os

/// Content-free logging. Values are fixed outcome names and numeric counters.
/// Text from fields, window titles and app identities never reach this type.
///
/// Lines are written at the notice level, which macOS keeps in its log store
/// (info lines live only in memory and are gone by the time anyone looks),
/// so a dictation or a mailbox connection that went wrong can be read about
/// afterwards with `log show`, as apps/macos/README.md describes. Each is
/// logged when its outcome happens or changes, a few per dictation.
enum AppLog {
    static let subsystem = "co.intention.mac"
    private static let native = Logger(subsystem: subsystem, category: "native")
    private static let app = Logger(subsystem: subsystem, category: "app")

    /// The caret tracker's outcome, logged when it changes. Reasons are
    /// fixed names such as "absent.selection"; no field content or app.
    static func caret(_ reason: String) {
        native.notice("caret \(reason, privacy: .public)")
    }

    /// An insertion outcome, a fixed name such as
    /// "insert.inserted.paste.clipboardRestored", and how long it took.
    static func edit(_ outcome: String, since start: ContinuousClock.Instant) {
        let milliseconds = (ContinuousClock.now - start) / .milliseconds(1)
        native.notice("edit \(outcome, privacy: .public) \(milliseconds, format: .fixed(precision: 1), privacy: .public) ms")
    }

    /// A dictation's progress or outcome, a fixed name such as "recording"
    /// or "insert.inserted.replaceRange". Never what was said. Kept in the
    /// system's log store, unlike info lines, so a dictation that went wrong
    /// can still be read about afterwards; there are a few per dictation.
    static func dictation(_ outcome: String) {
        native.notice("dictation \(outcome, privacy: .public)")
    }

    /// Fixed press/audio stages in the existing log. Uptime keeps native
    /// event timestamps and delivery times on one monotonic clock. A dot
    /// request is not proof that a display frame has presented it.
    static func pressStage(_ stage: String, at time: TimeInterval, since start: TimeInterval) {
        let milliseconds = max(0, time - start) * 1_000
        native.notice("press \(stage, privacy: .public) uptime=\(time, format: .fixed(precision: 6), privacy: .public) elapsedMs=\(milliseconds, format: .fixed(precision: 1), privacy: .public)")
    }

    /// A mailbox connection's progress or outcome, a fixed name such as
    /// "gmail.consent.returned" or "gmail.failed.rejected.400". Never an
    /// address, a code or the consent page's address.
    static func mail(_ outcome: String) {
        app.notice("mail \(outcome, privacy: .public)")
    }

    /// A draft request's progress or outcome, a fixed name such as
    /// "complete" or "failed.abstained.timeout". Never the cue or the text.
    static func compose(_ outcome: String, attempt: Int? = nil) {
        if let attempt {
            native.notice("compose \(outcome, privacy: .public) attempt=\(attempt, privacy: .public)")
        } else {
            native.notice("compose \(outcome, privacy: .public)")
        }
        #if DEBUG
        if outcome.hasPrefix("proposal."), let mirror = proposalMirror.withLock({ $0 }) { mirror(outcome) }
        #endif
    }

    #if DEBUG
    /// Where a Debug build's compose names starting with "proposal." go
    /// as well as the unified log, which cannot be read from a shell on the
    /// Mac the timing run uses: the proposal log, which the app installs
    /// at startup when it was given one. Nothing, elsewhere.
    private static let proposalMirror = OSAllocatedUnfairLock<(@Sendable (String) -> Void)?>(initialState: nil)

    static func mirrorProposals(to sink: (@Sendable (String) -> Void)?) {
        proposalMirror.withLock { $0 = sink }
    }
    #endif

    static func event(_ message: StaticString) {
        app.notice("\(message, privacy: .public)")
    }
}
