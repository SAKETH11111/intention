import Foundation
@testable import Dictation
import Testing

/// A reply proposal's stages and outcome, marked on a made-up clock.
struct ProposalTimingTests {
    @Test func aClientDeadlineRetainsTheLastFailedHTTPClass() {
        let trace = ProposalTrace(opened: nil, requested: nil, arrived: nil, shown: nil, ended: .now,
                                  failure: .timedOut, diagnostics: .init(failureKind: .createTimedOut, retried: true, lastHTTPStatusClass: "5xx"))
        let timing = ProposalTiming(.failed, trace: trace)
        #expect(timing.failure == .timedOut)
        #expect(timing.diagnostics.failureKind == .createTimedOut)
        #expect(timing.diagnostics.retried)
        #expect(timing.httpStatusClass == "5xx")
    }

    @Test func aFailedProposalRetainsItsTypedProblemInTiming() {
        let opened = ContinuousClock.now
        let trace = ProposalTrace(opened: opened, requested: opened, arrived: nil, shown: nil,
                                  ended: opened + .milliseconds(300), failure: .request(.server(503)))
        let report = ProposalTiming(.failed, trace: trace)
        #expect(report.failure == .request(.server(503)))
        #expect(report.failure?.telemetryName == "request.server")
        #expect(report.failure?.httpStatusClass == "5xx")
    }

    private let start = ContinuousClock.now

    private func at(_ milliseconds: Int) -> ContinuousClock.Instant {
        start + .milliseconds(milliseconds)
    }

    private func timing(endingAt marks: [Int]) -> ProposalTiming {
        var timing = ProposalTiming(startDate: Date(timeIntervalSince1970: 1000), at: start)
        for mark in marks { timing.endStage(at: at(mark)) }
        return timing
    }

    private func close(_ value: Double?, _ expected: Double) -> Bool {
        guard let value else { return false }
        return abs(value - expected) < 1e-9
    }

    @Test func stagesRunFromTheReplyOpeningToTheCardShowing() {
        var timing = timing(endingAt: [300, 3300, 3350])
        #expect(timing.currentStage == nil)
        #expect(timing.outcome == nil)
        let expected: [(ProposalTiming.Stage, Double, Double)] = [(.open, 0, 0.3), (.write, 0.3, 3), (.show, 3.3, 0.05)]
        #expect(timing.intervals.count == expected.count)
        for (interval, (stage, offset, duration)) in zip(timing.intervals, expected) {
            #expect(interval.stage == stage)
            #expect(close(interval.start, offset))
            #expect(close(interval.duration, duration))
        }
        #expect(close(timing.untilArrival, 3.3))
        #expect(close(timing.untilShown, 3.35))
        // Accepted a while later: the outcome's time is its own.
        timing.finish(.inserted, at: at(9000))
        #expect(timing.outcome == .inserted)
        #expect(close(timing.elapsed, 9))
        #expect(close(timing.untilShown, 3.35))
    }

    @Test func aLateProposalCountsItsArrivalAndHasNoShow() {
        var timing = timing(endingAt: [250])
        #expect(timing.currentStage == .write)
        timing.finish(.late, at: at(11_000))
        #expect(timing.outcome == .late)
        #expect(timing.intervals.map(\.stage) == [.open, .write])
        #expect(close(timing.untilArrival, 11))
        #expect(timing.untilShown == nil)
        #expect(close(timing.elapsed, 11))
    }

    @Test func aCancelledProposalRecordsTheTimeUntilTheCancelAndNoArrival() {
        var timing = timing(endingAt: [250])
        timing.finish(.cancelled, at: at(1800))
        #expect(timing.outcome == .cancelled)
        #expect(timing.intervals.map(\.stage) == [.open])
        #expect(timing.untilArrival == nil)
        #expect(timing.untilShown == nil)
        #expect(close(timing.elapsed, 1.8))
    }

    @Test func theOutcomeIsFinalAndLaterMarksAreIgnored() {
        var timing = timing(endingAt: [100, 2000])
        timing.finish(.dropped, at: at(2100))
        timing.endStage(at: at(2200))
        timing.finish(.inserted, at: at(5000))
        #expect(timing.outcome == .dropped)
        #expect(timing.intervals.map(\.stage) == [.open, .write])
        #expect(close(timing.elapsed, 2.1))
        // A late outcome after the arrival was marked does not mark it twice.
        var arrived = self.timing(endingAt: [100, 2000])
        arrived.finish(.late, at: at(2500))
        #expect(arrived.intervals.map(\.stage) == [.open, .write])
        #expect(close(arrived.untilArrival, 2))
    }

    @Test func aMarkBeforeThePreviousOneCountsAsZero() {
        let timing = timing(endingAt: [1000, 900])
        #expect(timing.intervals.last?.duration == 0)
    }

    @Test func theOutcomesHaveTheirFixedNames() {
        #expect(ProposalTiming.Outcome.allCases.map(\.rawValue) == [
            "shown", "late", "overtaken", "dropped", "cancelled", "failed", "abstained", "accepted", "inserted", "changed",
            "changeInserted", "ignored", "dismissed", "left", "expired", "insertRefused", "unconfirmed", "limited", "unreported",
        ])
        #expect(ProposalTiming.Stage.allCases.map(\.rawValue) == ["open", "write", "show"])
    }

    /// The controller's marks for one proposal, in milliseconds from the
    /// reply opening, as `ReplyProposalController` hands them to telemetry.
    private func trace(requested: Int?, arrived: Int?, shown: Int?, ended: Int) -> ProposalTrace {
        ProposalTrace(opened: at(0), requested: requested.map(at), arrived: arrived.map(at), shown: shown.map(at), ended: at(ended))
    }

    @Test func aShownTraceCountsEveryStage() {
        let timing = ProposalTiming(.shown, trace: trace(requested: 300, arrived: 2300, shown: 2350, ended: 2350))
        #expect(timing.outcome == .shown)
        #expect(timing.intervals.map(\.stage) == [.open, .write, .show])
        #expect(close(timing.intervals.first?.duration, 0.3))
        #expect(close(timing.untilArrival, 2.3))
        #expect(close(timing.untilShown, 2.35))
        #expect(close(timing.elapsed, 2.35))
    }

    @Test func anOvertakenTraceRecordsNoArrival() {
        // Typed over a second in: the request had been on its way 0.9 s.
        let timing = ProposalTiming(.overtaken, trace: trace(requested: 300, arrived: nil, shown: nil, ended: 1200))
        #expect(timing.outcome == .overtaken)
        #expect(timing.intervals.map(\.stage) == [.open])
        #expect(timing.untilArrival == nil)
        #expect(timing.untilShown == nil)
        #expect(close(timing.elapsed, 1.2))
    }

    @Test func aLateTraceCountsItsActualArrival() {
        // Arrived at four seconds with focus elsewhere, and let go at nine.
        let timing = ProposalTiming(.late, trace: trace(requested: 300, arrived: 4000, shown: nil, ended: 9000))
        #expect(timing.outcome == .late)
        #expect(timing.intervals.map(\.stage) == [.open, .write])
        #expect(close(timing.untilArrival, 4))
        #expect(timing.untilShown == nil)
        #expect(close(timing.elapsed, 9))
    }

    @Test func aCancelledTraceEndsAtTheCancel() {
        let timing = ProposalTiming(.cancelled, trace: trace(requested: 300, arrived: nil, shown: nil, ended: 800))
        #expect(timing.outcome == .cancelled)
        #expect(timing.intervals.map(\.stage) == [.open])
        #expect(timing.untilArrival == nil)
        #expect(close(timing.elapsed, 0.8))
    }

    @Test func anUnfinishedProposalHasNoOutcome() {
        let timing = timing(endingAt: [])
        #expect(timing.outcome == nil)
        #expect(timing.currentStage == .open)
        #expect(timing.intervals.isEmpty)
        #expect(timing.elapsed == nil)
        #expect(timing.untilArrival == nil)
    }
}
