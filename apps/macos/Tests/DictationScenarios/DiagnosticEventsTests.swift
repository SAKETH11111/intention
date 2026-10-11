import Foundation
import XCTest
import os
@testable import Dictation

final class DiagnosticEventsTests: XCTestCase {
    @MainActor
    func testRepeatedSetupIsRecordedWhileFirstRunReportingStaysOnceOnly() {
        let journal = DiagnosticEvents()
        var reports = 0
        let record = journal.observing(FirstRunRecord.stored(at: nil, reported: { _, _ in reports += 1 }))
        for _ in 0..<2 {
            record.mark(.setupOpened)
            for _ in 0..<5 {
                record.mark(.signedIn)
                record.mark(.firstSetupDictation)
                record.mark(.mailboxConnected)
            }
        }
        XCTAssertEqual(reports, 4)
        XCTAssertEqual(journal.snapshot().events.map(\.name), [
            .setupOpened, .signedIn, .firstSetupDictation, .mailboxConnected,
            .setupOpened, .signedIn, .firstSetupDictation, .mailboxConnected,
        ])
    }

    @MainActor
    func testAccountClearingResetsMilestonesWithoutAnotherWindowOpen() {
        let journal = DiagnosticEvents()
        let record = journal.observing(FirstRunRecord.stored(at: nil))
        record.mark(.setupOpened)
        record.mark(.signedIn)
        record.mark(.mailboxConnected)
        journal.clear()
        record.mark(.signedIn)
        record.mark(.mailboxConnected)
        XCTAssertEqual(journal.snapshot().events.map(\.name), [.signedIn, .mailboxConnected])
    }

    func testSinkRunsOutsideLockWithReportIdentity() async {
        let journal = DiagnosticEvents()
        let observed = OSAllocatedUnfairLock(initialState: [UUID]())
        let id = UUID()
        journal.setSink { _, _, _, interaction in
            _ = journal.snapshot()
            if let interaction { observed.withLock { $0.append(interaction) } }
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                journal.note(.reportProblem, interactionID: id)
                continuation.resume()
            }
        }
        XCTAssertEqual(observed.withLock { $0 }, [id])
    }

    func testPersistedRingSurvivesRelaunchAndClear() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("events.json")
        let journal = DiagnosticEvents(file: file)
        journal.note(.dictationFinished, outcome: .failedInsert)
        journal.flush()
        let restored = DiagnosticEvents(file: file)
        XCTAssertEqual(restored.snapshot().events.first?.outcome, .failedInsert)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        restored.clear()
        restored.flush()
        XCTAssertTrue(DiagnosticEvents(file: file).snapshot().events.isEmpty)
    }

    func testShutdownRetriesFailedFinalWriteAndPersistsGap() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("journal")
        let backup = root.appendingPathComponent("saved")
        let file = folder.appendingPathComponent("events.json")
        let journal = DiagnosticEvents(file: file)
        journal.note(.appLaunched)
        journal.flush()
        // A regular file where the directory belongs forces a real write
        // failure without permission assumptions or a mocked persistence path.
        try FileManager.default.moveItem(at: folder, to: backup)
        try Data().write(to: folder)
        journal.note(.dictationFinished, outcome: .failedInsert)
        journal.flush()
        XCTAssertTrue(journal.snapshot().truncated)
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: backup, to: folder)
        journal.flush()
        let restored = DiagnosticEvents(file: file).snapshot()
        XCTAssertEqual(restored.events.map(\.name), [.appLaunched, .dictationFinished])
        XCTAssertTrue(restored.truncated)
    }

    func testExpiredEventsAreNotPersisted() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("events.json")
        let journal = DiagnosticEvents(file: file)
        journal.note(.setupOpened, at: Date().addingTimeInterval(-3600))
        journal.note(.appLaunched)
        journal.flush()
        let saved = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(saved.contains("setup_opened"))
        XCTAssertEqual(DiagnosticEvents(file: file).snapshot().events.map(\.name), [.appLaunched])
    }

    func testClearRejectsOutcomesFromEarlierSessions() {
        let journal = DiagnosticEvents()
        let old = Date().addingTimeInterval(-10)
        journal.clear()
        let instant = ContinuousClock.now
        var timing = DictationTiming(startDate: old, at: instant.advanced(by: .seconds(-10)))
        timing.cancel(at: instant)
        journal.dictation(timing)
        var proposal = ProposalTiming(startDate: old, at: instant.advanced(by: .seconds(-10)))
        proposal.finish(.cancelled, at: instant)
        journal.proposal(proposal)
        journal.note(.setupOpened, at: old)
        journal.note(.signedIn)
        XCTAssertEqual(journal.snapshot().events.map(\.name), [.signedIn])
    }

    func testUnknownPersistedNamesAreRejected() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("events.json")
        try Data(#"{"entries":[{"event":{"name":"private text","at":"2026-10-09T00:00:00Z"},"date":0}]}"#.utf8).write(to: file)
        XCTAssertTrue(DiagnosticEvents(file: file).snapshot().events.isEmpty)
    }

    func testWindowExcludesOldAndFutureEvents() {
        let journal = DiagnosticEvents()
        // Keep the snapshot boundary ahead of wall-clock pruning during this test.
        let now = Date().addingTimeInterval(60)
        journal.firstRun(.setupOpened, at: now.addingTimeInterval(-1801))
        journal.firstRun(.signedIn, at: now.addingTimeInterval(-1800))
        journal.firstRun(.setupFinished, at: now.addingTimeInterval(1))
        XCTAssertEqual(journal.snapshot(at: now).events.map(\.name.rawValue), ["signed_in"])
    }

    func testOutOfOrderDatesKeepTheNewestLossMarker() {
        let journal = DiagnosticEvents()
        let now = Date()
        journal.note(.appLaunched, at: now)
        journal.note(.setupOpened, at: now.addingTimeInterval(-900))
        for _ in 0..<DiagnosticEvents.limit { journal.note(.dictationAttempt, at: now) }
        XCTAssertTrue(journal.snapshot(at: now).truncated)
    }

    func testBoundIsReported() {
        let journal = DiagnosticEvents()
        let now = Date()
        for _ in 0...DiagnosticEvents.limit { journal.firstRun(.signedIn, at: now) }
        XCTAssertEqual(journal.snapshot(at: now).events.count, 4096)
        XCTAssertTrue(journal.snapshot(at: now).truncated)
        XCTAssertFalse(journal.snapshot(at: now.addingTimeInterval(1801)).truncated)
    }

    func testJournalFromBackgroundQueue() async {
        let journal = DiagnosticEvents()
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                journal.firstRun(.permissionsGranted, at: Date())
                continuation.resume()
            }
        }
        XCTAssertEqual(journal.snapshot().events.first?.name.rawValue, "permissions_granted")
    }

}
