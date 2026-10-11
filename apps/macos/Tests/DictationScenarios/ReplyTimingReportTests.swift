import Foundation
@testable import Dictation
import Testing

/// The reply timing run's report (`apps/macos/Fixtures/ReplyTimingReport.swift`):
/// the percentiles, which run each proposal-log line belongs to, and
/// results.json and results.md, over lines written out by hand as the
/// Debug build writes them.
struct ReplyTimingReportTests {
    private func line(_ text: String) -> ProposalLogLine {
        guard let line = ProposalLogLine(text) else {
            Issue.record("not a proposal-log line: \(text)")
            return ProposalLogLine(sequence: 0, outcome: "", startedAt: 0, elapsedMs: 0)
        }
        return line
    }

    /// Seven runs: three shown, then hidden with their replies and ended
    /// as the next reply opened, one failed, one abstained, one whose card
    /// showed but whose line never came, and one never pressed. The first
    /// carries the names Intention logged while its window was open.
    private var runs: [ReplyTimingRun] {
        [
            ReplyTimingRun(number: 1, pressedAt: 1000, cardShown: true,
                           line: line(#"{"sequence":1,"outcome":"left","started_at":1000.050,"open_ms":250,"write_ms":3000,"show_ms":50,"until_arrival_ms":3250,"until_shown_ms":3300,"elapsed_ms":14000}"#),
                           notes: ["proposal.requested", "proposal.shown"]),
            ReplyTimingRun(number: 2, pressedAt: 1030, cardShown: true,
                           line: line(#"{"sequence":2,"outcome":"left","started_at":1029.980,"open_ms":300,"write_ms":2500,"show_ms":100,"until_arrival_ms":2800,"until_shown_ms":2900,"elapsed_ms":13000}"#)),
            ReplyTimingRun(number: 3, pressedAt: 1060, line: line(#"{"sequence":3,"outcome":"failed","started_at":1060.100,"open_ms":260,"elapsed_ms":2100}"#)),
            ReplyTimingRun(number: 4, pressedAt: 1090, cardShown: true,
                           line: line(#"{"sequence":4,"outcome":"ignored","started_at":1090.030,"open_ms":240,"write_ms":4400,"show_ms":60,"until_arrival_ms":4640,"until_shown_ms":4700,"elapsed_ms":12500}"#)),
            ReplyTimingRun(number: 5, pressedAt: 1120, line: line(#"{"sequence":5,"outcome":"abstained","started_at":1120.070,"open_ms":250,"elapsed_ms":3900}"#)),
            ReplyTimingRun(number: 6, pressedAt: 1150, cardShown: true),
            ReplyTimingRun(number: 7, note: "an earlier run left a window or draft"),
        ]
    }

    @Test func percentilesAreNearestRankOverWhatWasMeasured() {
        let ten = [3300, 2900, 4100, 3600, 5200, 3100, 2800, 4700, 3900, 3400]
        #expect(ReplyTimingReport.percentile(50, of: ten) == 3400)
        #expect(ReplyTimingReport.percentile(90, of: ten) == 4700)
        #expect(ReplyTimingReport.percentile(50, of: [5000, 1000, 3000]) == 3000)
        #expect(ReplyTimingReport.percentile(90, of: [5000, 1000, 3000]) == 5000)
        #expect(ReplyTimingReport.percentile(50, of: [700]) == 700)
        #expect(ReplyTimingReport.percentile(90, of: [700]) == 700)
        #expect(ReplyTimingReport.percentile(50, of: []) == nil)
    }

    @Test func onlyShownRunsCountAndTheOthersAreCountedApartByReason() {
        let report = ReplyTimingReport(runs: runs, unmatched: [])
        #expect(report.shown.map(\.sequence) == [1, 2, 4])
        #expect(report.statistics.map(\.key) == ["until_shown_ms", "until_arrival_ms", "open_ms", "write_ms", "show_ms"])
        #expect(report.statistics.map(\.p50) == [3300, 3250, 250, 3000, 60])
        #expect(report.statistics.map(\.p90) == [4700, 4640, 300, 4400, 100])
        #expect(report.otherwise.map(\.reason) == ["abstained", "card shown but no line", "failed", "not run"])
        #expect(report.otherwise.map(\.count) == [1, 1, 1, 1])
    }

    @Test func reasonsAreCountedMostFirst() {
        var list = runs
        list[2].line = line(#"{"sequence":3,"outcome":"abstained","started_at":1060.100,"open_ms":260,"elapsed_ms":2100}"#)
        let report = ReplyTimingReport(runs: list, unmatched: [])
        #expect(report.otherwise.map(\.reason) == ["abstained", "card shown but no line", "not run"])
        #expect(report.otherwise.map(\.count) == [2, 1, 1])
    }

    @Test func noShownRunGivesNoPercentiles() {
        let report = ReplyTimingReport(runs: [runs[2], runs[4]], unmatched: [])
        #expect(report.statistics.isEmpty)
        #expect(report.markdown().contains("No run showed the card, so there are no percentiles.\n"))
    }

    @Test func aLineAskedForWhenTheThreadOpenedGoesToTheRunWhoseReplyShowedIt() {
        var list = (1...2).map { ReplyTimingRun(number: $0, pressedAt: 1000 + Double($0 - 1) * 30) }
        // Run 2's thread opened 2.5 seconds before its press, and its reply
        // took focus 100 milliseconds after it: the line starts at the
        // thread's opening, before the press, and its reply at 1030.100.
        let thread = line(#"{"sequence":1,"outcome":"left","started_at":1027.500,"open_ms":300,"write_ms":2000,"show_ms":400,"until_arrival_ms":2300,"until_shown_ms":2700,"reply_to_shown_ms":100,"elapsed_ms":9000,"trigger":"thread"}"#)
        #expect(abs(thread.replyStartedAt - 1030.1) < 0.000_001)
        let unmatched = ReplyTimingReport.match([thread], to: &list)
        #expect(unmatched.isEmpty)
        #expect(list.map { $0.line?.sequence } == [nil, 1])
        let report = ReplyTimingReport(runs: list, unmatched: [])
        #expect(report.statistics.map(\.key) == ["until_shown_ms", "reply_to_shown_ms", "until_arrival_ms", "open_ms", "write_ms", "show_ms"])
        #expect(report.statistics.map(\.p50) == [2700, 100, 2300, 300, 2000, 400])
    }

    @Test func eachLineGoesToTheRunThatOpenedItByTheStartItCarries() {
        var list = (1...3).map { ReplyTimingRun(number: $0, pressedAt: 1000 + Double($0 - 1) * 30) }
        let lines = [
            // Before the first press: a reply the person opened.
            line(#"{"sequence":1,"outcome":"cancelled","started_at":998.900,"elapsed_ms":100}"#),
            // Run 1's card, hidden with its reply and ended as run 2's
            // opened: Intention's read that found the reply began 50
            // milliseconds before the press.
            line(#"{"sequence":2,"outcome":"left","started_at":999.950,"open_ms":250,"write_ms":3000,"show_ms":50,"until_arrival_ms":3250,"until_shown_ms":3300,"elapsed_ms":30500}"#),
            // Run 2's failed at once.
            line(#"{"sequence":3,"outcome":"failed","started_at":1030.400,"open_ms":260,"elapsed_ms":2100}"#),
            // Run 3's, after its five minutes.
            line(#"{"sequence":4,"outcome":"left","started_at":1060.200,"open_ms":250,"write_ms":2000,"show_ms":50,"until_arrival_ms":2250,"until_shown_ms":2300,"elapsed_ms":305000}"#),
            // Another begun after run 3's, which already has its line.
            line(#"{"sequence":5,"outcome":"cancelled","started_at":1400.000,"elapsed_ms":1000}"#),
        ]
        let unmatched = ReplyTimingReport.match(lines, to: &list)
        #expect(list.map { $0.line?.sequence } == [2, 3, 4])
        #expect(unmatched.map(\.sequence) == [1, 5])
    }

    @Test func aLineReadLateStillGoesToItsRunAndOneBegunTooEarlyToNone() {
        // The runner reads the file whenever it looks, so the order lines
        // come in and when they are read place nothing; only the start.
        var list = (1...2).map { ReplyTimingRun(number: $0, pressedAt: 1000 + Double($0 - 1) * 30) }
        let late = line(#"{"sequence":2,"outcome":"left","started_at":1000.020,"open_ms":250,"write_ms":3000,"show_ms":50,"until_arrival_ms":3250,"until_shown_ms":3300,"elapsed_ms":30500}"#)
        let second = line(#"{"sequence":3,"outcome":"failed","started_at":1030.010,"open_ms":260,"elapsed_ms":2100}"#)
        #expect(ReplyTimingReport.match([second, late], to: &list).isEmpty)
        #expect(list.map { $0.line?.sequence } == [2, 3])
        // A proposal begun after the run's window closed is a reply the
        // person opened, not the run's, even when the run has no line.
        var closed = [ReplyTimingRun(number: 1, pressedAt: 1000, endedAt: 1024), ReplyTimingRun(number: 2, pressedAt: 1030, endedAt: 1054)]
        let afterwards = line(#"{"sequence":9,"outcome":"left","started_at":1026.000,"open_ms":250,"write_ms":2000,"show_ms":50,"until_arrival_ms":2250,"until_shown_ms":2300,"elapsed_ms":305000}"#)
        let within = line(#"{"sequence":8,"outcome":"failed","started_at":1023.900,"elapsed_ms":100}"#)
        #expect(ReplyTimingReport.match([afterwards, within], to: &closed).map(\.sequence) == [9])
        #expect(closed.map { $0.line?.sequence } == [8, nil])
        // A second before the press is still the press's; more is not.
        var again = [ReplyTimingRun(number: 1, pressedAt: 1000)]
        #expect(ReplyTimingReport.match([line(#"{"sequence":1,"outcome":"failed","started_at":999.000,"elapsed_ms":100}"#)], to: &again).isEmpty)
        again = [ReplyTimingRun(number: 1, pressedAt: 1000)]
        #expect(ReplyTimingReport.match([line(#"{"sequence":1,"outcome":"failed","started_at":998.999,"elapsed_ms":100}"#)], to: &again).count == 1)
    }

    @Test func reusedAndHiddenRepliesMatchByTheirOwnFocus() {
        var runs = [ReplyTimingRun(number: 1, pressedAt: 1006, endedAt: 1010),
                    ReplyTimingRun(number: 2, pressedAt: 1036, endedAt: 1040),
                    ReplyTimingRun(number: 3, pressedAt: 1066, endedAt: 1070),
                    ReplyTimingRun(number: 4, pressedAt: 1096, endedAt: 1100)]
        let lines = [
            line(#"{"sequence":1,"outcome":"left","started_at":1000.000,"until_shown_ms":6400,"reply_to_shown_ms":400,"reply_focus_ms":6000,"elapsed_ms":10000,"trigger":"thread"}"#),
            line(#"{"sequence":2,"outcome":"limited","started_at":1000.000,"reply_focus_ms":36000,"elapsed_ms":40000,"trigger":"thread"}"#),
            line(#"{"sequence":3,"outcome":"unreported","started_at":1000.000,"reply_focus_ms":66000,"elapsed_ms":70000,"trigger":"thread"}"#),
            line(#"{"sequence":4,"outcome":"dropped","started_at":1000.000,"reply_focus_ms":96000,"elapsed_ms":100000,"trigger":"thread"}"#),
        ]
        #expect(lines.map(\.replyStartedAt) == [1006, 1036, 1066, 1096])
        #expect(ReplyTimingReport.match(lines, to: &runs).isEmpty)
        #expect(runs.map { $0.line?.sequence } == [1, 2, 3, 4])
        #expect(runs.map(\.reason) == [nil, "limited", "unreported", "dropped"])
    }

    @Test func eachNoteGoesToTheRunWhoseWindowWasOpen() {
        var list = [ReplyTimingRun(number: 1, pressedAt: 1000, endedAt: 1025), ReplyTimingRun(number: 2, pressedAt: 1030),
                    ReplyTimingRun(number: 3)]
        let notes = [
            // At startup, before any run.
            ProposalLogNote(sequence: 1, name: "proposal.on", at: 990),
            // Intention's read that found run 1's reply began just before the press.
            ProposalLogNote(sequence: 2, name: "proposal.requested", at: 999.950),
            ProposalLogNote(sequence: 3, name: "proposal.shown", at: 1003.300),
            // Between run 1's window closing and run 2's press.
            ProposalLogNote(sequence: 4, name: "proposal.focus.unchanged", at: 1027),
            // Run 2, still open.
            ProposalLogNote(sequence: 5, name: "proposal.candidate.none", at: 1031),
            ProposalLogNote(sequence: 7, name: "proposal.off.setting", at: 1400),
        ]
        let outside = ReplyTimingReport.attach(notes, to: &list)
        #expect(list[0].notes == ["proposal.requested", "proposal.shown"])
        #expect(list[0].cardShown)
        #expect(list[1].notes == ["proposal.candidate.none", "proposal.off.setting"])
        #expect(!list[1].cardShown)
        #expect(list[2].notes.isEmpty)
        #expect(outside.map(\.sequence) == [1, 4])
    }

    @Test func theDebugBuildsOwnNoteReadsBack() {
        #expect(ProposalLogNote(#"{"sequence":4,"note":"proposal.off.setting","at":1700000000.500}"#)
            == ProposalLogNote(sequence: 4, name: "proposal.off.setting", at: 1_700_000_000.5))
        // A proposal line is not a note, and a note is not a proposal line.
        let proposal = #"{"sequence":1,"outcome":"left","started_at":1000.000,"elapsed_ms":9000}"#
        #expect(ProposalLogNote(proposal) == nil)
        #expect(ProposalLogLine(#"{"sequence":4,"note":"proposal.off.setting","at":1700000000.500}"#) == nil)
        #expect(ProposalLogNote(#"{"sequence":4,"note":"proposal.off.setting"}"#) == nil)
    }

    @Test func theDebugBuildsOwnLineReadsBack() {
        let start = ContinuousClock.now
        let trace = ProposalTrace(opened: start, requested: start + .milliseconds(250), arrived: start + .milliseconds(3250),
                                  shown: start + .milliseconds(3300), ended: start + .milliseconds(9000))
        #expect(ProposalLogLine(ProposalLog.line(.left, trace: trace, sequence: 1, now: Date(timeIntervalSince1970: 1009)))
            == ProposalLogLine(sequence: 1, outcome: "left", startedAt: 1000, openMs: 250, writeMs: 3000, showMs: 50, untilArrivalMs: 3250, untilShownMs: 3300, elapsedMs: 9000, trigger: "reply"))
        #expect(ProposalLogLine("not json") == nil)
        #expect(ProposalLogLine(#"{"outcome":"left","started_at":1000.000,"elapsed_ms":9000}"#) == nil)
        #expect(ProposalLogLine(#"{"sequence":1,"outcome":"left","elapsed_ms":9000}"#) == nil)
    }

    @Test func resultsMarkdownListsTheSummaryThenEveryRun() {
        let unmatched = [line(#"{"sequence":8,"outcome":"cancelled","started_at":990.000,"elapsed_ms":100}"#)]
        let outside = ["proposal.on", "proposal.focus.unchanged"]
        let expected = """
        # Reply timing

        Runs 7, shown 3, ended otherwise 4 (abstained 1, card shown but no line 1, failed 1, not run 1).

        Over the 3 shown runs, nearest-rank percentiles in milliseconds:

        - until_shown_ms: p50 3300, p90 4700
        - until_arrival_ms: p50 3250, p90 4640
        - open_ms: p50 250, p90 300
        - write_ms: p50 3000, p90 4400
        - show_ms: p50 60, p90 100

        ## Runs

        - run 1: shown, ended left; card shown; open_ms 250, write_ms 3000, show_ms 50, until_arrival_ms 3250, until_shown_ms 3300, elapsed_ms 14000; logged proposal.requested, proposal.shown
        - run 2: shown, ended left; card shown; open_ms 300, write_ms 2500, show_ms 100, until_arrival_ms 2800, until_shown_ms 2900, elapsed_ms 13000
        - run 3: failed; open_ms 260, elapsed_ms 2100
        - run 4: shown, ended ignored; card shown; open_ms 240, write_ms 4400, show_ms 60, until_arrival_ms 4640, until_shown_ms 4700, elapsed_ms 12500
        - run 5: abstained; open_ms 250, elapsed_ms 3900
        - run 6: card shown but no line
        - run 7: not run; an earlier run left a window or draft

        ## Lines no run opened

        - line 8: cancelled; elapsed_ms 100

        ## Logged outside the runs

        - proposal.on
        - proposal.focus.unchanged

        """
        #expect(ReplyTimingReport(runs: runs, unmatched: unmatched, outside: outside).markdown() == expected)
    }

    @Test func resultsJSONHoldsEveryRunTheCountsAndThePercentiles() throws {
        let data = ReplyTimingReport(runs: runs, unmatched: [], outside: ["proposal.on"]).json()
        let text = try #require(String(data: data, encoding: .utf8))
        // Keys sorted, so two runs' files compare line by line.
        #expect(text.hasPrefix("{\n  \"notes_outside_runs\" : [\n    \"proposal.on\"\n  ],\n  \"otherwise\" : {"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["notes_outside_runs", "otherwise", "runs", "shown", "statistics", "unmatched"])
        #expect(object["notes_outside_runs"] as? [String] == ["proposal.on"])
        #expect(object["shown"] as? Int == 3)
        #expect(object["otherwise"] as? [String: Int] == ["abstained": 1, "card shown but no line": 1, "failed": 1, "not run": 1])
        let statistics = try #require(object["statistics"] as? [String: [String: Int]])
        #expect(statistics == [
            "until_shown_ms": ["p50": 3300, "p90": 4700], "until_arrival_ms": ["p50": 3250, "p90": 4640],
            "open_ms": ["p50": 250, "p90": 300], "write_ms": ["p50": 3000, "p90": 4400], "show_ms": ["p50": 60, "p90": 100],
        ])
        let list = try #require(object["runs"] as? [[String: Any]])
        #expect(list.count == 7)
        #expect(list[0]["run"] as? Int == 1)
        #expect(list[0]["card_shown"] as? Bool == true)
        #expect(list[0]["notes"] as? [String] == ["proposal.requested", "proposal.shown"])
        #expect(list[2]["notes"] as? [String] == [])
        #expect(list[0]["shown"] as? Bool == true)
        #expect(list[0]["reason"] is NSNull)
        #expect(list[0]["line"] as? [String: AnyHashable] == [
            "sequence": 1, "outcome": "left", "started_at": 1000.05, "open_ms": 250, "write_ms": 3000, "show_ms": 50,
            "until_arrival_ms": 3250, "until_shown_ms": 3300, "elapsed_ms": 14000,
        ])
        #expect(list[2]["shown"] as? Bool == false)
        #expect(list[2]["reason"] as? String == "failed")
        #expect(list[2]["line"] as? [String: AnyHashable] == ["sequence": 3, "outcome": "failed", "started_at": 1060.1, "open_ms": 260, "elapsed_ms": 2100])
        #expect(list[5]["reason"] as? String == "card shown but no line")
        #expect(list[5]["line"] is NSNull)
        #expect(list[6]["note"] as? String == "an earlier run left a window or draft")
        #expect((object["unmatched"] as? [Any])?.isEmpty == true)
    }
}
