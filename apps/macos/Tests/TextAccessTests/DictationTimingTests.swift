import Foundation
@testable import Intention
import Testing

struct DictationTimingTests {
    private let start = ContinuousClock.now

    private func at(_ milliseconds: Int) -> ContinuousClock.Instant {
        start + .milliseconds(milliseconds)
    }

    private func timing(endingAt marks: [Int]) -> DictationTiming {
        var timing = DictationTiming(startDate: Date(timeIntervalSince1970: 1000), at: start)
        for mark in marks { timing.endStage(at: at(mark)) }
        return timing
    }

    @Test func stagesAreTheIntervalsBetweenMarks() {
        let timing = timing(endingAt: [4000, 4600, 4900, 4950])
        #expect(timing.outcome == .inserted)
        #expect(timing.currentStage == nil)
        let expected: [(DictationTiming.Stage, Double, Double)] = [
            (.record, 0, 4), (.transcribe, 4, 0.6), (.clean, 4.6, 0.3), (.insert, 4.9, 0.05),
        ]
        #expect(timing.intervals.count == expected.count)
        for (interval, (stage, offset, duration)) in zip(timing.intervals, expected) {
            #expect(interval.stage == stage)
            #expect(abs(interval.start - offset) < 1e-9)
            #expect(abs(interval.duration - duration) < 1e-9)
        }
        #expect(abs((timing.afterStop ?? 0) - 0.95) < 1e-9)
        #expect(abs((timing.elapsed ?? 0) - 4.95) < 1e-9)
    }

    @Test func aFailureNamesTheRunningStageAndKeepsOnlyCompletedOnes() {
        var timing = timing(endingAt: [3000])
        #expect(timing.currentStage == .transcribe)
        timing.fail(at: at(9000))
        #expect(timing.outcome == .failed(.transcribe))
        #expect(timing.intervals.map(\.stage) == [.record])
        #expect(timing.afterStop == nil)
        // The six seconds spent failing to transcribe still count.
        #expect(abs((timing.elapsed ?? 0) - 9) < 1e-9)
    }

    @Test func silenceFromTheMicrophoneEndsTheTimingAtTheStop() {
        var timing = timing(endingAt: [2000])
        timing.silent(.heardNothing, at: at(2010))
        #expect(timing.outcome == .heardNothing)
        #expect(timing.intervals.map(\.stage) == [.record])
        #expect(timing.afterStop == nil)
        #expect(abs((timing.elapsed ?? 0) - 2.01) < 1e-9)
        timing.endStage(at: at(3000))
        #expect(timing.outcome == .heardNothing)
    }

    @Test func marksAfterTheOutcomeAreIgnored() {
        var timing = timing(endingAt: [1000])
        timing.cancel(at: at(1500))
        timing.endStage(at: at(1200))
        timing.fail(at: at(8000))
        #expect(timing.outcome == .cancelled)
        #expect(abs((timing.elapsed ?? 0) - 1.5) < 1e-9)
        #expect(timing.intervals.map(\.stage) == [.record])

        var finished = self.timing(endingAt: [1000, 1100, 1200, 1300])
        finished.endStage(at: at(9000))
        finished.cancel()
        #expect(finished.outcome == .inserted)
        #expect(finished.intervals.count == 4)
    }

    @Test func aWaitForAnEmailIsItsOwnStageBeforeTheInsertion() {
        var timing = timing(endingAt: [4000, 4600, 4900])
        #expect(timing.currentStage == .insert)
        timing.waitForEmail()
        #expect(timing.currentStage == .email)
        timing.endStage(at: at(9900))
        #expect(timing.currentStage == .insert)
        timing.endStage(at: at(9950))
        #expect(timing.outcome == .inserted)
        let expected: [(DictationTiming.Stage, Double, Double)] = [
            (.record, 0, 4), (.transcribe, 4, 0.6), (.clean, 4.6, 0.3), (.email, 4.9, 5), (.insert, 9.9, 0.05),
        ]
        #expect(timing.intervals.count == expected.count)
        for (interval, (stage, offset, duration)) in zip(timing.intervals, expected) {
            #expect(interval.stage == stage)
            #expect(abs(interval.start - offset) < 1e-9)
            #expect(abs(interval.duration - duration) < 1e-9)
        }
        // The person waited for the email as well.
        #expect(abs((timing.afterStop ?? 0) - 5.95) < 1e-9)
    }

    @Test func theEmailStageCannotBeAddedBeforeTheWordsOrOnceTheInsertionHasEnded() {
        var early = timing(endingAt: [4000])
        early.waitForEmail()
        #expect(early.currentStage == .transcribe)
        #expect(!early.waitsForEmail)
        var done = timing(endingAt: [4000, 4600, 4900, 4950])
        done.waitForEmail()
        #expect(!done.waitsForEmail)
        #expect(done.intervals.map(\.stage) == [.record, .transcribe, .clean, .insert])
    }

    @Test func aMarkBeforeThePreviousOneCountsAsZero() {
        let timing = timing(endingAt: [1000, 900])
        #expect(timing.intervals.last?.duration == 0)
    }

    @Test func unfinishedDictationHasNoOutcome() {
        let timing = timing(endingAt: [])
        #expect(timing.outcome == nil)
        #expect(timing.currentStage == .record)
        #expect(timing.intervals.isEmpty)
        #expect(timing.elapsed == nil)
    }
}
