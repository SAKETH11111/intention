import Foundation
import XCTest
@testable import Dictation

final class DiagnosticAccountTests: XCTestCase {
    func testRelaunchQuarantinesOldAccountAndClearsConfirmedReplacementOrRemoval() throws {
        for account in [UUID?.some(UUID()), nil] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("events.json")
            let original = DiagnosticEvents(file: file, requiresAccount: true)
            original.bind(accountID: UUID())
            original.note(.dictationAttempt)
            original.flush()
            let restored = DiagnosticEvents(file: file, requiresAccount: true)
            XCTAssertTrue(restored.snapshot().events.isEmpty)
            XCTAssertTrue(restored.snapshot().truncated)
            restored.bind(accountID: account)
            XCTAssertTrue(restored.snapshot().events.isEmpty)
            restored.flush()
            let saved = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(saved.contains("dictation_attempt"))
            if let account { XCTAssertFalse(saved.contains(account.uuidString.lowercased())) }
        }
    }

    func testConfirmedSameAccountKeepsHistoryAndPendingLaunchEvent() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("events.json")
        let account = UUID()
        let original = DiagnosticEvents(file: file)
        original.bind(accountID: account)
        original.note(.dictationAttempt)
        original.flush()
        let restored = DiagnosticEvents(file: file, requiresAccount: true)
        restored.note(.appLaunched)
        XCTAssertTrue(restored.snapshot().events.isEmpty)
        restored.bind(accountID: account)
        XCTAssertEqual(restored.snapshot().events.map(\.name), [.dictationAttempt, .appLaunched])
    }

    func testAttemptStartedDuringLookupKeepsItsCompletionAfterBinding() {
        let journal = DiagnosticEvents(requiresAccount: true)
        journal.beginAccountCheck()
        let started = Date()
        journal.note(.dictationAttempt, at: started)
        journal.bind(accountID: UUID())
        journal.note(.dictationFinished, outcome: .inserted, startedAt: started)
        journal.note(.dictationFinished, outcome: .cancelled, startedAt: started.addingTimeInterval(-10))
        XCTAssertEqual(journal.snapshot().events.map(\.name), [.dictationAttempt, .dictationFinished])
        XCTAssertEqual(journal.snapshot().events.last?.outcome, .inserted)
    }

    @MainActor
    func testFailedKeyReadPreservesDiskAndWithholdsEventsUntilIdentityMatches() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("events.json")
        let account = UUID()
        let original = DiagnosticEvents(file: file)
        original.bind(accountID: account)
        original.note(.dictationAttempt)
        original.flush()
        let saved = try Data(contentsOf: file)
        let restored = DiagnosticEvents(file: file, requiresAccount: true)
        let credential = DiagnosticCredential(.unreadable)
        let binding = DiagnosticAccount(journal: restored, read: { credential.value },
            identify: { _ in account }, refused: { _ in XCTFail("Unexpected refusal") })
        binding.refresh()
        restored.flush()
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: saved) as? NSDictionary)
        XCTAssertTrue(restored.snapshot().events.isEmpty)
        credential.value = .key("synthetic-key")
        binding.refresh()
        await until { restored.accountVerified }
        XCTAssertEqual(restored.snapshot().events.map(\.name), [.dictationAttempt])
    }

    @MainActor
    func testFailedIdentityRequestKeepsTheOldFileQuarantined() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("events.json")
        let original = DiagnosticEvents(file: file)
        original.bind(accountID: UUID())
        original.note(.dictationAttempt)
        original.flush()
        let saved = try Data(contentsOf: file)
        let restored = DiagnosticEvents(file: file, requiresAccount: true)
        let attempted = IdentityAttempt()
        let binding = DiagnosticAccount(journal: restored, read: { .key("synthetic-key") }, identify: { _ in
            await attempted.called()
            throw URLError(.notConnectedToInternet)
        }, refused: { _ in XCTFail("Transport failure is not a rejected key") })
        binding.refresh()
        await untilAsync { await attempted.didCall }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertFalse(restored.accountVerified)
        XCTAssertTrue(restored.snapshot().events.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), saved)
    }

    @MainActor
    func testLateIdentityCannotReleaseOldHistoryForReplacementKey() async throws {
        let journal = DiagnosticEvents(requiresAccount: true)
        let oldAccount = UUID(), newAccount = UUID()
        journal.bind(accountID: oldAccount)
        journal.note(.dictationAttempt)
        let credential = DiagnosticCredential(.key("old-key"))
        let replies = IdentityReplies()
        let binding = DiagnosticAccount(journal: journal, read: { credential.value },
            identify: { try await replies.identity($0) }, refused: { _ in XCTFail("Unexpected refusal") })
        let observed = DiagnosticIdentities()
        binding.identityChanged = { observed.values.append($0) }
        binding.refresh()
        await untilAsync { await replies.has("old-key") }
        credential.value = .key("new-key")
        binding.refresh()
        await untilAsync { await replies.has("new-key") }
        await replies.answer("old-key", oldAccount)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertFalse(journal.accountVerified)
        XCTAssertTrue(journal.snapshot().events.isEmpty)
        await replies.answer("new-key", newAccount)
        await until { journal.accountVerified }
        XCTAssertTrue(journal.snapshot().events.isEmpty)
        XCTAssertEqual(observed.values.compactMap { $0 }, [newAccount])
        XCTAssertEqual(binding.accountID, newAccount)
        credential.value = .unreadable
        binding.refresh()
        XCTAssertNil(binding.accountID)
        XCTAssertNil(observed.values.last!)
    }

    @MainActor
    func testFirstSignInKeepsOnlyThisLaunchsSignedOutSetupEvents() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("events.json")
        let previousLaunch = DiagnosticEvents(file: file)
        previousLaunch.note(.dictationAttempt)
        previousLaunch.flush()
        let journal = DiagnosticEvents(file: file, requiresAccount: true)
        journal.note(.setupOpened)
        let credential = DiagnosticCredential(.signedOut)
        let account = UUID()
        let binding = DiagnosticAccount(journal: journal, read: { credential.value },
            identify: { _ in account }, refused: { _ in XCTFail("Unexpected refusal") })
        binding.refresh()
        journal.note(.permissionsGranted)
        credential.value = .key("synthetic-key")
        binding.refresh()
        journal.note(.signedIn)
        await until { journal.accountVerified }
        XCTAssertEqual(journal.snapshot().events.map(\.name), [.setupOpened, .permissionsGranted, .signedIn])
    }

    @MainActor
    func testIdentityFailureRetriesWithBackoffUntilItRecovers() async {
        let journal = DiagnosticEvents(requiresAccount: true)
        let attempts = IdentityRetry()
        let binding = DiagnosticAccount(journal: journal, read: { .key("synthetic-key") },
            identify: { _ in try await attempts.identify() }, refused: { _ in XCTFail("Unexpected refusal") },
            retryPause: { failures in
                await attempts.pause(failures)
                try await Task.sleep(for: .milliseconds(5))
            })
        binding.refresh()
        journal.note(.appLaunched)
        await until { journal.accountVerified }
        let pauses = await attempts.pauses
        XCTAssertEqual(pauses, [1, 2])
        XCTAssertEqual(journal.snapshot().events.map(\.name), [.appLaunched])
    }

    @MainActor
    func testSuccessfulRequestFromBackgroundQueueWakesIdentityBackoff() async {
        let journal = DiagnosticEvents(requiresAccount: true)
        let attempts = IdentityRetry(failures: 1)
        let binding = DiagnosticAccount(journal: journal, read: { .key("synthetic-key") },
            identify: { _ in try await attempts.identify() }, refused: { _ in XCTFail("Unexpected refusal") },
            retryPause: { failures in
                await attempts.pause(failures)
                try await Task.sleep(for: .seconds(3600))
            })
        binding.refresh()
        await untilAsync { await !attempts.pauses.isEmpty }
        let callback = DiagnosticAccount.serverResponded(binding)
        await withCheckedContinuation { done in
            DispatchQueue.global().async { callback(); done.resume() }
        }
        await until { journal.accountVerified }
        let calls = await attempts.calls
        XCTAssertEqual(calls, 2)
    }

    @MainActor
    private func until(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    @MainActor
    private func untilAsync(_ condition: () async -> Bool) async {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition did not arrive")
    }
}

private actor IdentityReplies {
    var pending: [String: CheckedContinuation<UUID, any Error>] = [:]
    func identity(_ key: String) async throws -> UUID {
        try await withCheckedThrowingContinuation { pending[key] = $0 }
    }
    func has(_ key: String) -> Bool { pending[key] != nil }
    func answer(_ key: String, _ account: UUID) { pending.removeValue(forKey: key)?.resume(returning: account) }
}

@MainActor
private final class DiagnosticCredential {
    var value: DiagnosticAccount.Credential
    init(_ value: DiagnosticAccount.Credential) { self.value = value }
}

private actor IdentityAttempt {
    var didCall = false
    func called() { didCall = true }
}

@MainActor
private final class DiagnosticIdentities {
    var values: [UUID?] = []
}

private actor IdentityRetry {
    var calls = 0
    var pauses: [Int] = []
    let failures: Int
    let account = UUID()
    init(failures: Int = 2) { self.failures = failures }
    func identify() throws -> UUID {
        calls += 1
        if calls <= failures { throw URLError(.notConnectedToInternet) }
        return account
    }
    func pause(_ failure: Int) { pauses.append(failure) }
}
