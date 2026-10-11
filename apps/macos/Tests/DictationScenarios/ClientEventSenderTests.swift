import Foundation
import XCTest
@testable import Dictation

final class ClientEventSenderTests: XCTestCase {
    func testFirstSignInClaimsOnlySetupEventsAndReplacementGetsNoEarlierEvents() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = InteractionArchive(directory: directory, report: { _ in }) { _, _, _ in 500 }
        let sender = ClientEventSender(archive: archive)
        let setup = UUID(), oldAttempt = UUID(), signedOutAttempt = UUID(), newAttempt = UUID()
        sender.record(.setupOpened, at: Date(timeIntervalSince1970: 1791547200), interactionID: setup)
        archive.bind(key: nil)
        sender.beginAccountCheck(buffer: false)
        sender.bind(scope: nil)
        archive.bind(key: "synthetic-first-key")
        let firstScope = try XCTUnwrap(archive.scope)
        sender.bind(scope: firstScope)
        sender.record(.dictationAttempt, interactionID: oldAttempt)
        archive.bind(key: nil)
        sender.bind(scope: nil)
        sender.record(.dictationAttempt, interactionID: signedOutAttempt)
        archive.bind(key: "synthetic-second-key")
        let secondScope = try XCTUnwrap(archive.scope)
        sender.bind(scope: secondScope)
        sender.record(.reportProblem, outcome: .failed, interactionID: newAttempt)
        let saved = await archive.flush()
        XCTAssertTrue(saved)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let events = try files.filter { $0.pathExtension == "body" }.map { url -> [String: Any] in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        }
        XCTAssertEqual(events.count, 3)
        let ids = Set(events.compactMap { $0["interaction_id"] as? String })
        XCTAssertEqual(ids, Set([setup.uuidString, oldAttempt.uuidString, newAttempt.uuidString]))
        XCTAssertFalse(ids.contains(signedOutAttempt.uuidString))
        for event in events {
            XCTAssertEqual(event["kind"] as? String, "client_event")
            let payload = try XCTUnwrap(event["payload"] as? [String: Any])
            XCTAssertEqual(Set(payload.keys).subtracting(["outcome"]),
                           Set(["version", "name", "occurred_at", "app_version", "app_build"]))
            XCTAssertNotNil(ClientEventName(rawValue: try XCTUnwrap(payload["name"] as? String)))
            let envelopeURL = directory.appendingPathComponent(try XCTUnwrap(event["id"] as? String) + ".json")
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: envelopeURL)) as? [String: Any])
            XCTAssertEqual(envelope["scope"] as? String,
                           event["interaction_id"] as? String == newAttempt.uuidString ? secondScope : firstScope)
        }
    }
}

extension ClientEventSenderTests {
    func testFirstUseKeepsTheSameEnvelopeAfterAcknowledgmentAndRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let delivered = ArchiveDeliveries()
        let archive = InteractionArchive(directory: directory, report: { _ in }) { key, path, bytes in
            await delivered.add(key: key, path: path, bytes: bytes)
            return 204
        }
        archive.bind(key: "synthetic-key")
        let sender = ClientEventSender(archive: archive)
        sender.bind(scope: archive.scope)
        sender.record(.firstDictation)
        let saved = await archive.flush()
        XCTAssertTrue(saved)
        let arrived = await delivered.waitForCount(1)
        XCTAssertTrue(arrived)
        for _ in 0..<200 {
            if try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .allSatisfy({ $0.pathExtension != "body" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        archive.bind(key: nil)
        let unbound = await archive.flush()
        XCTAssertTrue(unbound)
        let replayed = ArchiveDeliveries()
        let restarted = InteractionArchive(directory: directory, report: { _ in }) { key, path, bytes in
            await replayed.add(key: key, path: path, bytes: bytes)
            return 204
        }
        restarted.bind(key: "synthetic-key")
        let next = ClientEventSender(archive: restarted)
        next.bind(scope: restarted.scope)
        next.record(.firstDictation, at: .distantFuture)
        let resaved = await restarted.flush()
        XCTAssertTrue(resaved)
        let reappeared = await replayed.waitForCount(1)
        XCTAssertTrue(reappeared)
        let first = await delivered.first?.bytes, second = await replayed.first?.bytes
        XCTAssertEqual(first, second)
    }

    func testFirstUseClaimRecoversWhenEnvelopeWriteFails() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = InteractionArchive(directory: directory, report: { _ in }, write: { data, url in
            if url.pathExtension == "json" { throw CocoaError(.fileWriteUnknown) }
            try InteractionArchive.writePrivately(data, url)
        }) { _, _, _ in 500 }
        archive.bind(key: "synthetic-key")
        let sender = ClientEventSender(archive: archive)
        sender.bind(scope: archive.scope)
        let id = UUID()
        sender.record(.firstEmail, interactionID: id)
        let saved = await archive.flush()
        XCTAssertFalse(saved)
        archive.bind(key: nil)
        let replayed = ArchiveDeliveries()
        let restarted = InteractionArchive(directory: directory, report: { _ in }) { key, path, bytes in
            await replayed.add(key: key, path: path, bytes: bytes)
            return 204
        }
        restarted.bind(key: "synthetic-key")
        let arrived = await replayed.waitForCount(1)
        XCTAssertTrue(arrived)
        let item = await replayed.first
        let bytes = try XCTUnwrap(item?.bytes)
        let event = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(event["interaction_id"] as? String, id.uuidString)
    }

    func testRepeatedFirstUseIsOneMilestonePerBoundScope() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = InteractionArchive(directory: directory, report: { _ in }) { _, _, _ in 500 }
        let sender = ClientEventSender(archive: archive)
        archive.bind(key: "synthetic-first-key")
        sender.bind(scope: archive.scope)
        sender.record(.firstDictation)
        sender.record(.firstDictation)
        sender.record(.firstEmail)
        sender.record(.firstEmail)
        archive.bind(key: "synthetic-second-key")
        sender.bind(scope: archive.scope)
        sender.record(.firstDictation)
        let saved = await archive.flush()
        XCTAssertTrue(saved)
        let events = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "body" }
        XCTAssertEqual(events.count, 3)
    }
}

extension ClientEventSenderTests {
    func testTerminalJournalEntriesDoNotDuplicateTheRetainedArchive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = InteractionArchive(directory: directory, report: { _ in }) { _, _, _ in 500 }
        let sender = ClientEventSender(archive: archive)
        archive.bind(key: "synthetic-key")
        sender.bind(scope: archive.scope)
        let attempt = UUID()
        sender.record(.dictationAttempt, interactionID: attempt)
        sender.record(.dictationFinished, outcome: .inserted, interactionID: attempt)
        sender.record(.proposalClient, outcome: .accepted, interactionID: UUID())
        let saved = await archive.flush()
        XCTAssertTrue(saved)
        let events = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "body" }
        XCTAssertEqual(events.count, 1)
    }
}


extension ClientEventSenderTests {
    func testIdentityRecheckBuffersFreshEventsAndDropsPreviousLookupEvents() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = InteractionArchive(directory: directory, report: { _ in }) { _, _, _ in 500 }
        let sender = ClientEventSender(archive: archive)
        archive.bind(key: "synthetic-first-key")
        sender.bind(scope: archive.scope)
        sender.beginAccountCheck(scope: "first-check", buffer: true)
        let previous = UUID(), fresh = UUID()
        sender.record(.dictationAttempt, interactionID: previous)
        sender.beginAccountCheck(scope: "second-check", buffer: true)
        sender.record(.dictationAttempt, interactionID: fresh)
        archive.bind(key: "synthetic-second-key")
        sender.bind(scope: archive.scope)
        let saved = await archive.flush()
        XCTAssertTrue(saved)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let events = try files.filter { $0.pathExtension == "body" }.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as? [String: Any])
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["interaction_id"] as? String, fresh.uuidString)
    }
    func testRepeatedUnconfirmedIdentityNotificationKeepsSetupEvents() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = InteractionArchive(directory: directory, report: { _ in }) { _, _, _ in 500 }
        let sender = ClientEventSender(archive: archive)
        sender.record(.setupOpened)
        sender.beginAccountCheck(scope: nil, buffer: false)
        sender.beginAccountCheck(scope: nil, buffer: false)
        archive.bind(key: "synthetic-key")
        sender.beginAccountCheck(scope: archive.scope, buffer: true)
        sender.beginAccountCheck(scope: archive.scope, buffer: true)
        sender.bind(scope: archive.scope)
        let saved = await archive.flush()
        XCTAssertTrue(saved)
        let events = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "body" }
        XCTAssertEqual(events.count, 1)
    }

}
