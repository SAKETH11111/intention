// AppKit rather than Foundation: the Command Line Tools cannot load the
// overlay that importing Foundation beside Testing asks for.
import AppKit
@testable import Onboarding
import Testing

/// The first-run reports telemetry receives, built from the record's marks,
/// and the record handing each new mark on once.
struct FirstRunTimingTests {
    private typealias Event = FirstRunRecord.Event
    private let opened = Date(timeIntervalSince1970: 1_000_000)

    /// Marks at these seconds after setup opened.
    private func marks(_ seconds: [Event: Double]) -> [Event: Date] {
        var marks = seconds.mapValues { opened.addingTimeInterval($0) }
        marks[.setupOpened] = opened
        return marks
    }

    private var everyMark: [Event: Date] {
        marks([.signedIn: 20, .permissionsGranted: 50, .firstSetupDictation: 80, .mailboxConnected: 140,
               .firstSetupEmail: 170, .setupFinished: 190, .firstDictation: 400, .firstEmail: 900])
    }

    @Test func setupFinishedReportsEveryStepAndTheSetupMeasures() throws {
        let timing = try #require(FirstRunTiming(marks: everyMark, after: .setupFinished))
        #expect(timing.kind == .setup)
        #expect(timing.start == opened)
        #expect(timing.end == opened + 190)
        let expected: [(Event, Double, Double)] = [
            (.signedIn, 0, 20), (.permissionsGranted, 20, 50), (.firstSetupDictation, 50, 80),
            (.mailboxConnected, 80, 140), (.firstSetupEmail, 140, 170), (.setupFinished, 170, 190),
        ]
        #expect(timing.steps == expected.map { .init(event: $0.0, start: opened + $0.1, end: opened + $0.2) })
        #expect(timing.measures == [.timeToFirstDictation: 80, .timeToFirstEmail: 170, .setupLength: 190])
        #expect(timing.tags == ["mailbox": "true", "setup_email": "true"])
    }

    @Test func skippedMarksAreSkippedSteps() throws {
        // No mailbox, so no email on the page, and nothing used yet.
        let partial = marks([.signedIn: 20, .permissionsGranted: 50, .firstSetupDictation: 80, .setupFinished: 110])
        let timing = try #require(FirstRunTiming(marks: partial, after: .setupFinished))
        #expect(timing.steps.map(\.event) == [.signedIn, .permissionsGranted, .firstSetupDictation, .setupFinished])
        #expect(timing.steps.last == .init(event: .setupFinished, start: opened + 80, end: opened + 110))
        #expect(timing.measures == [.timeToFirstDictation: 80, .setupLength: 110])
        #expect(timing.tags == ["mailbox": "false", "setup_email": "false"])
    }

    @Test func theStepsFollowTheMarksOwnTimesAsAResumedSetupReachesThem() {
        // Dictation skipped, mail connected, then a lost grant sent setup
        // back through the permissions to the first dictation.
        let steps = FirstRunTiming.steps(marks([.signedIn: 20, .permissionsGranted: 50, .mailboxConnected: 140,
                                                .firstSetupDictation: 300, .setupFinished: 330]))
        #expect(steps == [.init(event: .signedIn, start: opened, end: opened + 20),
                          .init(event: .permissionsGranted, start: opened + 20, end: opened + 50),
                          .init(event: .mailboxConnected, start: opened + 50, end: opened + 140),
                          .init(event: .firstSetupDictation, start: opened + 140, end: opened + 300),
                          .init(event: .setupFinished, start: opened + 300, end: opened + 330)])
        // Two marks at one time keep setup's usual order.
        let tied = FirstRunTiming.steps(marks([.signedIn: 20, .permissionsGranted: 20, .setupFinished: 20]))
        #expect(tied.map(\.event) == [.signedIn, .permissionsGranted, .setupFinished])
    }

    @Test func aMarkTheClockPutBeforeSetupOpenedOrAfterItFinishedIsLeftOut() {
        let steps = FirstRunTiming.steps(marks([.signedIn: -5, .permissionsGranted: 10, .firstSetupDictation: 40,
                                                .setupFinished: 30]))
        #expect(steps == [.init(event: .permissionsGranted, start: opened, end: opened + 10),
                          .init(event: .setupFinished, start: opened + 10, end: opened + 30)])
    }

    @Test func aSetupThatFinishedNoLaterThanItOpenedReportsNothing() {
        #expect(FirstRunTiming(marks: marks([.signedIn: 20, .setupFinished: 0]), after: .setupFinished) == nil)
        #expect(FirstRunTiming(marks: marks([.signedIn: 20, .setupFinished: -10]), after: .setupFinished) == nil)
        // And a first use the clock put before setup finished reports nothing.
        #expect(FirstRunTiming(marks: marks([.setupFinished: 30, .firstDictation: 20]), after: .firstDictation) == nil)
    }

    @Test func aMeasureTheClockMadeNegativeIsLeftOut() throws {
        // The first words on the page landed, by the clock, before setup opened.
        let timing = try #require(FirstRunTiming(marks: marks([.signedIn: 20, .firstSetupDictation: -5, .setupFinished: 30]),
                                                 after: .setupFinished))
        #expect(timing.measures == [.setupLength: 30])
        #expect(timing.steps == [.init(event: .signedIn, start: opened, end: opened + 20),
                                 .init(event: .setupFinished, start: opened + 20, end: opened + 30)])
    }

    @Test func theFirstEmailIsThePagesWhenThereWasOne() {
        #expect(FirstRunTiming.seconds(.timeToFirstEmail, in: everyMark) == 170)
        var outside = everyMark
        outside[.firstSetupEmail] = nil
        #expect(FirstRunTiming.seconds(.timeToFirstEmail, in: outside) == 900)
        outside[.firstEmail] = nil
        #expect(FirstRunTiming.seconds(.timeToFirstEmail, in: outside) == nil)
    }

    @Test func realUseWaitsForTheFirstDictationOutsideSetup() {
        var marks = everyMark
        #expect(FirstRunTiming.seconds(.timeToRealUse, in: marks) == 210)
        marks[.firstDictation] = nil
        #expect(FirstRunTiming.seconds(.timeToRealUse, in: marks) == nil)
        marks[.setupFinished] = nil
        #expect(FirstRunTiming.seconds(.setupLength, in: marks) == nil)
    }

    @Test func theFirstDictationAfterSetupReportsTheTimeToRealUse() throws {
        let timing = try #require(FirstRunTiming(marks: everyMark, after: .firstDictation))
        #expect(timing.kind == .firstUse)
        #expect(timing.start == opened + 190)
        #expect(timing.end == opened + 400)
        #expect(timing.steps.isEmpty)
        #expect(timing.measures == [.timeToRealUse: 210])
        #expect(timing.tags == ["kind": "dictation"])
    }

    @Test func theFirstEmailAfterSetupCarriesTheTimeToFirstEmailOnlyWhenThePageHadNone() throws {
        let afterPage = try #require(FirstRunTiming(marks: everyMark, after: .firstEmail))
        #expect(afterPage.kind == .firstUse)
        #expect(afterPage.start == opened + 190)
        #expect(afterPage.end == opened + 900)
        #expect(afterPage.measures.isEmpty)
        #expect(afterPage.tags == ["kind": "email"])

        var noPageEmail = everyMark
        noPageEmail[.firstSetupEmail] = nil
        let first = try #require(FirstRunTiming(marks: noPageEmail, after: .firstEmail))
        #expect(first.measures == [.timeToFirstEmail: 900])
        // Setup itself, finished before that email, had no email to measure.
        noPageEmail[.firstEmail] = nil
        let setup = try #require(FirstRunTiming(marks: noPageEmail, after: .setupFinished))
        #expect(setup.measures[.timeToFirstEmail] == nil)
        #expect(setup.tags["setup_email"] == "false")
    }

    @Test func onlySetupFinishedAndTheFirstUsesReport() {
        let reporting = Event.allCases.filter { FirstRunTiming(marks: everyMark, after: $0) != nil }
        #expect(reporting == [.setupFinished, .firstDictation, .firstEmail])
    }

    @Test func aUseBeforeSetupFinishedReportsNothing() {
        let unfinished = marks([.signedIn: 20, .permissionsGranted: 50, .firstDictation: 60, .firstEmail: 60])
        #expect(FirstRunTiming(marks: unfinished, after: .firstDictation) == nil)
        #expect(FirstRunTiming(marks: unfinished, after: .firstEmail) == nil)
        #expect(FirstRunTiming(marks: [.setupFinished: opened], after: .setupFinished) == nil)
    }
}

@MainActor
struct FirstRunRecordReportTests {
    private typealias Event = FirstRunRecord.Event

    /// What the record handed on: the marks so far and the event just made.
    private final class Reports {
        var calls: [([Event: Date], Event)] = []
    }

    @Test func eachNewMarkIsReportedOnceWithTheMarksSoFar() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let reports = Reports()
        let record = FirstRunRecord.stored(at: nil, now: { now }, reported: { reports.calls.append(($0, $1)) })
        record.mark(.setupOpened)
        now += 5
        record.mark(.signedIn)
        record.mark(.setupOpened)
        now += 5
        record.mark(.signedIn)
        #expect(reports.calls.map(\.1) == [.setupOpened, .signedIn])
        #expect(reports.calls[0].0 == [.setupOpened: Date(timeIntervalSince1970: 1_000_000)])
        #expect(reports.calls[1].0 == [.setupOpened: Date(timeIntervalSince1970: 1_000_000),
                                       .signedIn: Date(timeIntervalSince1970: 1_000_005)])
    }

    @Test func aRecordReadBackReportsNothingUntilANewMark() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("first-run-" + UUID().uuidString)
        let file = folder.appendingPathComponent("first-run.json")
        let start = Date(timeIntervalSince1970: 1_000_000)
        let first = FirstRunRecord.stored(at: file, now: { start })
        for event in [Event.setupOpened, .signedIn, .permissionsGranted, .setupFinished] { first.mark(event) }

        // The next launch reads the same file.
        let reports = Reports()
        let later = FirstRunRecord.stored(at: file, now: { start + 60 }, reported: { reports.calls.append(($0, $1)) })
        for event in [Event.setupOpened, .signedIn, .permissionsGranted, .setupFinished] { later.mark(event) }
        #expect(reports.calls.isEmpty)
        later.mark(.firstDictation)
        #expect(reports.calls.map(\.1) == [.firstDictation])
        let marks = try #require(reports.calls.first?.0)
        #expect(marks[.setupFinished] == start)
        #expect(marks[.firstDictation] == start + 60)
        // Built the way the app builds it: one first-use report, once.
        #expect(FirstRunTiming(marks: marks, after: .firstDictation)?.measures == [.timeToRealUse: 60])
        later.mark(.firstDictation)
        #expect(reports.calls.count == 1)
        try FileManager.default.removeItem(at: folder)
    }

    @Test func aMarkWhoseSaveFailsIsReportedWithTheNextOneThatSavesAndNeverAgain() throws {
        // The record's folder cannot be made while a file stands in its place.
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("first-run-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let blocker = parent.appendingPathComponent("record")
        try Data().write(to: blocker)
        let file = blocker.appendingPathComponent("first-run.json")
        var now = Date(timeIntervalSince1970: 1_000_000)
        let reports = Reports()
        let record = FirstRunRecord.stored(at: file, now: { now }, reported: { reports.calls.append(($0, $1)) })
        record.mark(.setupOpened)
        now += 5
        record.mark(.signedIn)
        // Nothing saved, so nothing reported, and nothing is in the file.
        #expect(reports.calls.isEmpty)
        #expect(FirstRunRecord.read(file).isEmpty)
        // The folder can be made now: the next mark saves all three and
        // reports them in order, each with its own time.
        try FileManager.default.removeItem(at: blocker)
        now += 5
        record.mark(.permissionsGranted)
        #expect(reports.calls.map(\.1) == [.setupOpened, .signedIn, .permissionsGranted])
        let marks = try #require(reports.calls.last?.0)
        #expect(marks[.setupOpened] == Date(timeIntervalSince1970: 1_000_000))
        #expect(marks[.signedIn] == Date(timeIntervalSince1970: 1_000_005))
        #expect(marks[.permissionsGranted] == Date(timeIntervalSince1970: 1_000_010))
        #expect(FirstRunRecord.read(file) == marks)
        // A relaunch reads them back and reports none of them again.
        let again = Reports()
        let later = FirstRunRecord.stored(at: file, now: { now + 60 }, reported: { again.calls.append(($0, $1)) })
        for event in [Event.setupOpened, .signedIn, .permissionsGranted] { later.mark(event) }
        #expect(again.calls.isEmpty)
        try FileManager.default.removeItem(at: parent)
    }
}
