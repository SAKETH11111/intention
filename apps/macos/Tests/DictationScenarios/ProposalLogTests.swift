import Foundation
@testable import Dictation
import Testing

/// The Debug build's `--proposal-log` lines, built from proposals marked on
/// a made-up clock and compared with lines written out by hand.
struct ProposalLogTests {
    private let start = ContinuousClock.now
    /// When each proposal ends, so the line's start is a literal.
    private let now = Date(timeIntervalSince1970: 1_700_000_009)

    private func at(_ milliseconds: Int) -> ContinuousClock.Instant {
        start + .milliseconds(milliseconds)
    }

    /// Shown 3.3 seconds after the reply opened and put in at 9 seconds.
    private var inserted: ProposalTrace {
        ProposalTrace(opened: at(0), requested: at(250), arrived: at(3250), shown: at(3300), ended: at(9000))
    }

    /// Typed over 1.4 seconds after the reply opened, before it arrived.
    private var overtaken: ProposalTrace {
        ProposalTrace(opened: at(0), requested: at(250), arrived: nil, shown: nil, ended: at(1400))
    }

    /// Cancelled before its request was sent.
    private var cancelled: ProposalTrace {
        ProposalTrace(opened: at(0), requested: nil, arrived: nil, shown: nil, ended: at(180))
    }

    private let insertedLine = #"{"sequence":1,"outcome":"inserted","started_at":1700000000.000,"open_ms":250,"write_ms":3000,"show_ms":50,"until_arrival_ms":3250,"until_shown_ms":3300,"elapsed_ms":9000,"trigger":"reply"}"#
    private let overtakenLine = #"{"sequence":2,"outcome":"overtaken","started_at":1700000007.600,"open_ms":250,"elapsed_ms":1400,"trigger":"reply"}"#
    private let cancelledLine = #"{"sequence":3,"outcome":"cancelled","started_at":1700000008.820,"elapsed_ms":180,"trigger":"reply"}"#

    private func temporaryPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("proposal-log-\(UUID().uuidString).jsonl").path
    }

    /// Asked for when its Gmail thread opened, its reply focused 6 seconds
    /// later, shown 0.4 seconds after that, and put in at 9 seconds.
    private var fromThread: ProposalTrace {
        ProposalTrace(opened: at(0), requested: at(300), arrived: at(3300), shown: at(6400), ended: at(9000), trigger: .thread,
                      replyFocused: at(6000))
    }

    @Test func aProposalAskedForWhenItsThreadOpenedCarriesBothWaitsAndItsTrigger() {
        #expect(ProposalLog.line(.inserted, trace: fromThread, sequence: 4, now: now)
            == #"{"sequence":4,"outcome":"inserted","started_at":1700000000.000,"open_ms":300,"write_ms":3000,"show_ms":3100,"until_arrival_ms":3300,"until_shown_ms":6400,"reply_to_shown_ms":400,"reply_focus_ms":6000,"elapsed_ms":9000,"trigger":"thread"}"#)
    }

    @Test(arguments: [ProposalOutcome.limited, .unreported, .dropped])
    func aHiddenReplyCarriesItsFocusWithoutAShowing(outcome: ProposalOutcome) {
        let trace = ProposalTrace(opened: at(0), requested: at(300), arrived: at(3300), shown: nil,
                                  ended: at(9000), trigger: .thread, replyFocused: at(6000))
        let expected = "{\"sequence\":5,\"outcome\":\"\(outcome.rawValue)\",\"started_at\":1700000000.000,\"open_ms\":300,\"write_ms\":3000,\"until_arrival_ms\":3300,\"reply_focus_ms\":6000,\"elapsed_ms\":9000,\"trigger\":\"thread\"}"
        #expect(ProposalLog.line(outcome, trace: trace, sequence: 5, now: now) == expected)
    }

    @Test func aShownAndInsertedProposalCarriesEveryStageAndBothWaits() {
        #expect(ProposalLog.line(.inserted, trace: inserted, sequence: 1, now: now) == insertedLine)
    }

    @Test func anOvertakenProposalCarriesOnlyTheStagesItCompleted() {
        #expect(ProposalLog.line(.overtaken, trace: overtaken, sequence: 2, now: now) == overtakenLine)
    }

    @Test func aProposalCancelledBeforeItsRequestCarriesOnlyItsElapsedTime() {
        #expect(ProposalLog.line(.cancelled, trace: cancelled, sequence: 3, now: now) == cancelledLine)
    }

    @Test func theStartIsPlacedBackFromTheEndToTheMillisecond() {
        let line = ProposalLog.line(.cancelled, trace: cancelled, sequence: 1, now: Date(timeIntervalSince1970: 1_700_000_000.1234))
        #expect(line == #"{"sequence":1,"outcome":"cancelled","started_at":1699999999.943,"elapsed_ms":180,"trigger":"reply"}"#)
    }

    @Test func aNoteCarriesItsNameAndWhenItWasLogged() throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let log = ProposalLog(arguments: ["Intention", "--proposal-log", path])
        log.note("proposal.off.setting", now: Date(timeIntervalSince1970: 1_700_000_000.5))
        log.record(.cancelled, trace: cancelled, now: now)
        log.note("proposal.shown", now: Date(timeIntervalSince1970: 1_700_000_012))
        let written = try String(contentsOfFile: path, encoding: .utf8)
        #expect(written == [#"{"sequence":1,"note":"proposal.off.setting","at":1700000000.500}"#,
                            #"{"sequence":2,"outcome":"cancelled","started_at":1700000008.820,"elapsed_ms":180,"trigger":"reply"}"#,
                            #"{"sequence":3,"note":"proposal.shown","at":1700000012.000}"#].joined(separator: "\n") + "\n")
    }

    @Test func theArgumentAppendsOneNumberedLinePerProposal() throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let log = ProposalLog(arguments: ["Intention", "--proposal-log", path])
        log.record(.inserted, trace: inserted, now: now)
        log.record(.overtaken, trace: overtaken, now: now)
        log.record(.cancelled, trace: cancelled, now: now)
        let written = try String(contentsOfFile: path, encoding: .utf8)
        #expect(written == [insertedLine, overtakenLine, cancelledLine].joined(separator: "\n") + "\n")
        for line in written.split(separator: "\n") {
            #expect((try? JSONSerialization.jsonObject(with: Data(line.utf8))) is [String: Any])
        }
    }

    @Test func nothingIsWrittenWithoutTheArgument() {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        ProposalLog(arguments: ["Intention", path]).record(.inserted, trace: inserted)
        ProposalLog(arguments: ["Intention", "--dot-log", path]).record(.inserted, trace: inserted)
        ProposalLog(arguments: ["Intention", "--proposal-log"]).record(.inserted, trace: inserted)
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
