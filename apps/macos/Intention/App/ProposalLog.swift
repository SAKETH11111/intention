import Foundation
import os

#if DEBUG
/// `--proposal-log <file>` on a Debug build appends one JSON line for each
/// reply that ends or leaves its held proposal: a sequence number counting from 1, the
/// outcome's fixed name, when the reply opened in seconds since 1970, the
/// milliseconds of each stage it completed (open, write, show), the
/// milliseconds from the reply opening to the proposal arriving and to the
/// card showing when they happened, from the reply's body taking focus to
/// the card showing, and to the outcome, and what asked for it, the reply
/// or its Gmail thread opening, which then is what "opening" means.
/// The timing run reads reply-open-to-card times from it, since the unified
/// log cannot be read from a shell there. Names and numbers only, as
/// telemetry gets; never a proposal's text, an address, a window's title or
/// an app's identity. Nothing is written without the argument.
final class ProposalLog: Sendable {
    static let shared = ProposalLog(arguments: CommandLine.arguments)

    private let url: URL?
    /// The file is opened at the first line and kept open; each line is
    /// numbered and appended whole under the lock.
    private let state = OSAllocatedUnfairLock(uncheckedState: (file: FileHandle?.none, sequence: 0))

    init(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--proposal-log"), arguments.indices.contains(index + 1) else {
            url = nil
            return
        }
        url = URL(fileURLWithPath: arguments[index + 1])
    }

    /// Appends the line for a reply that ended with `outcome`, now.
    func record(_ outcome: ProposalOutcome, trace: ProposalTrace, now: Date = Date()) {
        append { sequence in Self.line(outcome, trace: trace, sequence: sequence, now: now) }
    }

    /// Appends one of the controller's fixed log names, such as
    /// "proposal.notReply", with when it was logged in seconds since 1970,
    /// so a run that produced no proposal still shows why and which run
    /// it was. The name is one of the controller's own constants; nothing
    /// read from a field ever reaches it.
    func note(_ name: String, now: Date = Date()) {
        append { sequence in "{\"sequence\":\(sequence),\"note\":\"\(name)\",\"at\":" + String(format: "%.3f", now.timeIntervalSince1970) + "}" }
    }

    private func append(_ line: (Int) -> String) {
        guard let url else { return }
        state.withLockUnchecked { state in
            guard state.sequence < 200_000 else { return }
            if state.file == nil {
                if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
                state.file = try? FileHandle(forWritingTo: url)
            }
            guard let file = state.file else { return }
            state.sequence += 1
            _ = try? file.seekToEnd()
            try? file.write(contentsOf: Data((line(state.sequence) + "\n").utf8))
        }
    }

    /// The line for one ended proposal, with its keys always in the same
    /// order and a stage, arrival or showing that never happened left out.
    /// The reply's opening is placed back from `now`, the proposal's end,
    /// by its whole span, to the millisecond. It is built by hand because
    /// `JSONSerialization` keeps no key order.
    static func line(_ outcome: ProposalOutcome, trace: ProposalTrace, sequence: Int, now: Date = Date()) -> String {
        let timing = ProposalTiming(outcome, trace: trace, now: now)
        var fields = ["\"sequence\":\(sequence)", "\"outcome\":\"\(outcome.rawValue)\"",
                      "\"started_at\":" + String(format: "%.3f", timing.startDate.timeIntervalSince1970)]
        for interval in timing.intervals {
            fields.append("\"\(interval.stage.rawValue)_ms\":\(milliseconds(interval.duration))")
        }
        if let arrival = timing.untilArrival { fields.append("\"until_arrival_ms\":\(milliseconds(arrival))") }
        if let shown = timing.untilShown { fields.append("\"until_shown_ms\":\(milliseconds(shown))") }
        if let shown = timing.untilShownFromReply { fields.append("\"reply_to_shown_ms\":\(milliseconds(shown))") }
        if let focus = timing.untilReplyFocus { fields.append("\"reply_focus_ms\":\(milliseconds(focus))") }
        fields.append("\"elapsed_ms\":\(milliseconds(timing.elapsed ?? 0))")
        fields.append("\"trigger\":\"\(timing.trigger.rawValue)\"")
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// Rounded to the millisecond, as telemetry reports them.
    private static func milliseconds(_ seconds: Double) -> Int {
        Int((seconds * 1000).rounded())
    }
}
#endif
