import Foundation

// The reply timing run's arithmetic and its files, apart from anything that
// touches a window, so `./dev mac-dictation-test` checks them: the Debug
// build's `--proposal-log` lines read back, each proposal matched to the
// run whose Reply press opened it and each note to the run whose window
// was open, and the p50 and p90 of the shown runs' waits. See
// apps/macos/scripts/reply-timing.sh.

/// One line of the Debug build's `--proposal-log`: a proposal that ended,
/// with the milliseconds of the stages it completed (`ProposalLog.line`).
struct ProposalLogLine: Equatable, Sendable {
    let sequence: Int
    let outcome: String
    /// When the reply opened, in seconds since 1970, as the Debug build
    /// placed it back from the proposal's end.
    let startedAt: Double
    var openMs: Int?
    var writeMs: Int?
    var showMs: Int?
    var untilArrivalMs: Int?
    var untilShownMs: Int?
    /// From the reply's body taking focus to the card showing.
    var replyToShownMs: Int?
    /// From the proposal opening to this reply taking focus, including hidden outcomes.
    var replyFocusMs: Int?
    let elapsedMs: Int
    /// What asked for the proposal, "reply" or "thread"; nil on a line from
    /// a build before thread proposals.
    var trigger: String?

    /// The line's keys, in the order the log writes them.
    static let keys = ["sequence", "outcome", "started_at", "open_ms", "write_ms", "show_ms", "until_arrival_ms", "until_shown_ms",
                       "reply_to_shown_ms", "reply_focus_ms", "elapsed_ms", "trigger"]

    init(sequence: Int, outcome: String, startedAt: Double, openMs: Int? = nil, writeMs: Int? = nil, showMs: Int? = nil,
         untilArrivalMs: Int? = nil, untilShownMs: Int? = nil, replyToShownMs: Int? = nil, replyFocusMs: Int? = nil, elapsedMs: Int, trigger: String? = nil) {
        self.sequence = sequence
        self.outcome = outcome
        self.startedAt = startedAt
        self.openMs = openMs
        self.writeMs = writeMs
        self.showMs = showMs
        self.untilArrivalMs = untilArrivalMs
        self.untilShownMs = untilShownMs
        self.replyToShownMs = replyToShownMs
        self.replyFocusMs = replyFocusMs
        self.elapsedMs = elapsedMs
        self.trigger = trigger
    }

    /// Nil for a line that is not one of the log's: not a JSON object, or
    /// without its sequence, outcome, start or elapsed time.
    init?(_ text: some StringProtocol) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let sequence = object["sequence"] as? Int, let outcome = object["outcome"] as? String,
              let started = object["started_at"] as? Double, let elapsed = object["elapsed_ms"] as? Int else { return nil }
        self.init(sequence: sequence, outcome: outcome, startedAt: started, openMs: object["open_ms"] as? Int, writeMs: object["write_ms"] as? Int,
                  showMs: object["show_ms"] as? Int, untilArrivalMs: object["until_arrival_ms"] as? Int,
                  untilShownMs: object["until_shown_ms"] as? Int, replyToShownMs: object["reply_to_shown_ms"] as? Int, replyFocusMs: object["reply_focus_ms"] as? Int, elapsedMs: elapsed,
                  trigger: object["trigger"] as? String)
    }

    /// When the reply this line's proposal served began, in seconds since
    /// 1970, from the independent focus mark, even when it never showed.
    /// Older logs fall back to the two showing waits or the proposal start.
    var replyStartedAt: Double {
        if let replyFocusMs { return startedAt + Double(replyFocusMs) / 1000 }
        guard trigger == "thread", let untilShownMs, let replyToShownMs else { return startedAt }
        return startedAt + Double(untilShownMs - replyToShownMs) / 1000
    }

    /// The card showed: the run counts toward the percentiles.
    var shown: Bool { untilShownMs != nil }

    /// The line's values by its own keys, those it has.
    var fields: [(key: String, value: Any)] {
        let values: [Any?] = [sequence, outcome, startedAt, openMs, writeMs, showMs, untilArrivalMs, untilShownMs, replyToShownMs, replyFocusMs, elapsedMs,
                              trigger]
        return zip(Self.keys, values).compactMap { key, value in value.map { (key, $0) } }
    }
}

/// One of the log's note lines: a fixed name the controller logged, such
/// as "proposal.off.setting" or "proposal.shown", and when, in seconds
/// since 1970 (`ProposalLog.note`).
struct ProposalLogNote: Equatable, Sendable {
    let sequence: Int
    let name: String
    let at: Double

    init(sequence: Int, name: String, at: Double) {
        self.sequence = sequence
        self.name = name
        self.at = at
    }

    /// Nil for a line that is not a note: not a JSON object, or without
    /// its sequence, note or time.
    init?(_ text: some StringProtocol) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let sequence = object["sequence"] as? Int, let name = object["note"] as? String,
              let at = object["at"] as? Double else { return nil }
        self.init(sequence: sequence, name: name, at: at)
    }
}

/// One run: a new window at the thread, its Reply pressed, and what came of it.
struct ReplyTimingRun: Equatable, Sendable {
    let number: Int
    /// When Reply was pressed, in seconds since 1970; nil when it was not.
    var pressedAt: Double?
    /// When the run's window was closed or left, in seconds since 1970;
    /// nil while it is open.
    var endedAt: Double?
    /// Intention logged its card showing while the run's window was open.
    var cardShown = false
    var line: ProposalLogLine?
    /// The fixed names Intention logged while the run's window was open, in
    /// order: the gates, the reasons a candidate was skipped, the card
    /// showing.
    var notes: [String] = []
    /// What the runner noticed, such as a control it did not find.
    var note = ""

    /// Why a run that did not show counts apart: the line's outcome, or
    /// what kept a line from coming. Nil for a shown run.
    var reason: String? {
        if let line { return line.shown ? nil : line.outcome }
        if pressedAt == nil { return "not run" }
        return cardShown ? "card shown but no line" : "no line"
    }
}

struct ReplyTimingReport: Sendable {
    let runs: [ReplyTimingRun]
    /// Lines no run opened, such as a reply the person opened meanwhile.
    let unmatched: [ProposalLogLine]
    /// Names logged while no run's window was open, such as the gate at
    /// startup.
    var outside: [String] = []

    /// The waits summarised over the shown runs, by the log's own keys.
    static let measures: [(key: String, value: @Sendable (ProposalLogLine) -> Int?)] = [
        ("until_shown_ms", { $0.untilShownMs }), ("reply_to_shown_ms", { $0.replyToShownMs }), ("until_arrival_ms", { $0.untilArrivalMs }),
        ("open_ms", { $0.openMs }), ("write_ms", { $0.writeMs }), ("show_ms", { $0.showMs }),
    ]

    /// The nearest-rank percentile: the smallest value with at least `p`
    /// percent of the values at or below it, so always one that was
    /// measured. Nil for no values.
    static func percentile(_ p: Int, of values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((Double(p) / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    var shown: [ProposalLogLine] { runs.compactMap(\.line).filter(\.shown) }

    /// The p50 and p90 of each measure over the shown runs, in `measures`'
    /// order; a measure no shown line carries is left out.
    var statistics: [(key: String, p50: Int, p90: Int)] {
        Self.measures.compactMap { key, value in
            let values = shown.compactMap(value)
            guard let p50 = Self.percentile(50, of: values), let p90 = Self.percentile(90, of: values) else { return nil }
            return (key, p50, p90)
        }
    }

    /// How many runs ended otherwise, by reason, most first and then by name.
    var otherwise: [(reason: String, count: Int)] {
        Dictionary(grouping: runs.compactMap(\.reason), by: { $0 }).map { ($0.key, $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.reason < $1.reason }
    }

    /// How long before a Reply press a proposal's start may lie and still
    /// be that press's: Intention marks the start when its tracker begins the
    /// read that finds the new reply, which can begin just before the
    /// press and find the reply after it. The run before has closed its
    /// window seconds earlier, so nothing of its can start this late.
    static let allowance = 1.0

    /// Gives each line to the run whose Reply press opened its proposal:
    /// the last run pressed at or before the line's own start, with the
    /// allowance, and not yet ended at that start, by the start the line
    /// itself carries. A proposal ends long after its run when its card
    /// hid with the reply, at the next reply's opening or when its keep
    /// time passes, and its line is read whenever the runner looks, so
    /// neither its end nor its reading places it; one that began after
    /// the run's window closed, a reply the person opened, is nobody's. A
    /// proposal asked for when the run's thread opened starts before the
    /// press, so it is placed by when its reply began (`replyStartedAt`).
    /// A line with no such run, or for a run that has one, is returned
    /// unmatched.
    static func match(_ lines: [ProposalLogLine], to runs: inout [ReplyTimingRun]) -> [ProposalLogLine] {
        var unmatched: [ProposalLogLine] = []
        for line in lines {
            let start = line.replyStartedAt
            let index = runs.lastIndex { run in run.pressedAt.map { $0 <= start + allowance } ?? false }
            if let index, runs[index].line == nil, runs[index].endedAt.map({ start <= $0 }) ?? true {
                runs[index].line = line
            } else {
                unmatched.append(line)
            }
        }
        return unmatched
    }

    /// Gives each note to the run whose window was open when it was
    /// logged: pressed, with the allowance, at or before the note and not
    /// yet ended. Returns the notes logged outside every run, in order.
    static func attach(_ notes: [ProposalLogNote], to runs: inout [ReplyTimingRun]) -> [ProposalLogNote] {
        var outside: [ProposalLogNote] = []
        for note in notes {
            let index = runs.lastIndex { run in run.pressedAt.map { $0 - allowance <= note.at } ?? false }
            if let index, runs[index].endedAt.map({ note.at <= $0 }) ?? true {
                runs[index].notes.append(note.name)
                if note.name == "proposal.shown" { runs[index].cardShown = true }
            } else {
                outside.append(note)
            }
        }
        return outside
    }

    /// results.json: every run with its line and notes, the unmatched
    /// lines, the notes outside the runs, the count of shown runs, the
    /// others by reason and each measure's p50 and p90, keys sorted.
    func json() -> Data {
        func object(_ line: ProposalLogLine) -> [String: Any] { Dictionary(uniqueKeysWithValues: line.fields.map { ($0.key, $0.value) }) }
        let report: [String: Any] = [
            "runs": runs.map { run -> [String: Any] in
                ["run": run.number, "card_shown": run.cardShown, "shown": run.line?.shown ?? false, "reason": run.reason ?? NSNull(),
                 "notes": run.notes, "note": run.note, "line": run.line.map(object) ?? NSNull()]
            },
            "unmatched": unmatched.map(object),
            "notes_outside_runs": outside,
            "shown": shown.count,
            "otherwise": Dictionary(uniqueKeysWithValues: otherwise.map { ($0.reason, $0.count) }),
            "statistics": Dictionary(uniqueKeysWithValues: statistics.map { ($0.key, ["p50": $0.p50, "p90": $0.p90]) }),
        ]
        return (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// results.md: the summary first, then every run and unmatched line.
    func markdown() -> String {
        var text = "# Reply timing\n\n"
        let others = otherwise.map { "\($0.reason) \($0.count)" }.joined(separator: ", ")
        text += "Runs \(runs.count), shown \(shown.count), ended otherwise \(runs.count - shown.count)" + (others.isEmpty ? "" : " (\(others))") + ".\n\n"
        if statistics.isEmpty {
            text += "No run showed the card, so there are no percentiles.\n"
        } else {
            text += "Over the \(shown.count) shown runs, nearest-rank percentiles in milliseconds:\n\n"
            for s in statistics { text += "- \(s.key): p50 \(s.p50), p90 \(s.p90)\n" }
        }
        text += "\n## Runs\n\n"
        for run in runs {
            var parts = [run.line.map { $0.shown ? "shown, ended \($0.outcome)" : $0.outcome } ?? (run.reason ?? "")]
            if run.cardShown, run.line != nil { parts.append("card shown") }
            if let line = run.line { parts.append(Self.stages(line)) }
            if !run.notes.isEmpty { parts.append("logged " + run.notes.joined(separator: ", ")) }
            if !run.note.isEmpty { parts.append(run.note) }
            text += "- run \(run.number): " + parts.joined(separator: "; ") + "\n"
        }
        if !unmatched.isEmpty {
            text += "\n## Lines no run opened\n\n"
            for line in unmatched { text += "- line \(line.sequence): \(line.outcome); \(Self.stages(line))\n" }
        }
        if !outside.isEmpty {
            text += "\n## Logged outside the runs\n\n" + outside.map { "- \($0)\n" }.joined()
        }
        return text
    }

    private static func stages(_ line: ProposalLogLine) -> String {
        line.fields.filter { $0.key.hasSuffix("_ms") }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }
}
