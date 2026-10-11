import CryptoKit
import Foundation
import Testing
@testable import Dictation

struct InteractionArchiveTests {
    @Test func legacyAcceptanceWithLostAckSettlesAfterServerUpgrade() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let initial = ArchiveDeliveries()
        let archive = InteractionArchive(directory: folder) { key, path, bytes in
            await initial.add(key: key, path: path, bytes: bytes)
            if await initial.count == 1 { return 422 }
            // The old server committed the legacy body before its reply was lost.
            throw URLError(.networkConnectionLost)
        }
        archive.bind(key: "compatibility-key")
        let id = UUID()
        archive.dictation(.init(id: id, historyID: id, startedAt: Date(), finishedAt: Date(),
                               transcript: "Keep me", formatted: "Keep me", text: "Keep me", outcome: "inserted"),
                         audio: [Data([1, 0])], scope: archive.scope)
        #expect(await archive.flush())
        #expect(await initial.waitForCount(2))
        archive.bind(key: nil)
        #expect(await archive.flush())
        let sent = await initial.all
        let accepted = try #require(sent.last?.bytes)
        let replayed = ArchiveDeliveries()
        let upgraded = InteractionArchive(directory: folder) { key, path, bytes in
            await replayed.add(key: key, path: path, bytes: bytes)
            // The new server accepts an exact retry of its existing metadata only.
            return bytes == accepted ? 204 : 409
        }
        upgraded.bind(key: "compatibility-key")
        #expect(await replayed.waitForCount(2))
        let attempts = await replayed.all
        #expect(attempts.first?.bytes == sent.first?.bytes)
        #expect(attempts.last?.bytes == accepted)
        for _ in 0..<200 {
            if !FileManager.default.fileExists(atPath: folder.appendingPathComponent(id.uuidString + ".json").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(id.uuidString + ".json").path))
    }

    @Test func olderServerReceivesIdenticalDictationWithoutNewMetadata() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let deliveries = ArchiveDeliveries()
        let archive = InteractionArchive(directory: folder) { key, path, bytes in
            await deliveries.add(key: key, path: path, bytes: bytes)
            return await deliveries.count == 1 ? 422 : 204
        }
        archive.bind(key: "compatibility-key")
        let id = UUID()
        let text = "Preserve é and 漢字 exactly.\n"
        let audio = Data([1, 0, 2, 0, 3, 0])
        archive.dictation(.init(id: id, historyID: id, startedAt: Date(), finishedAt: Date(),
                               transcript: text, formatted: text, text: text, outcome: "inserted"),
                         audio: [audio], scope: archive.scope)
        #expect(await archive.flush())
        #expect(await deliveries.waitForCount(2))
        let items = await deliveries.all
        #expect(items.count == 2)
        #expect(items[0].key == items[1].key)
        #expect(items[0].path == items[1].path)
        var original = try metadata(items[0].bytes)
        #expect(original.removeValue(forKey: "app_version") != nil)
        #expect(original.removeValue(forKey: "app_build") != nil)
        let legacy = try metadata(items[1].bytes)
        #expect(NSDictionary(dictionary: original).isEqual(to: legacy))
        for item in items {
            let length = item.bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            #expect(item.bytes.suffix(from: 4 + length) == audio)
        }
        for _ in 0..<200 {
            if !FileManager.default.fileExists(atPath: folder.appendingPathComponent(id.uuidString + ".json").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(id.uuidString + ".json").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("rejected").path))
    }

    @Test func failedCompatibilityRetryKeepsOriginalDictationForRestart() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let deliveries = ArchiveDeliveries()
        let archive = InteractionArchive(directory: folder) { key, path, bytes in
            await deliveries.add(key: key, path: path, bytes: bytes)
            return await deliveries.count == 1 ? 422 : 503
        }
        archive.bind(key: "compatibility-key")
        let id = UUID()
        archive.dictation(.init(id: id, historyID: id, startedAt: Date(), finishedAt: Date(),
                               transcript: "Keep me", formatted: "Keep me", text: "Keep me", outcome: "inserted"),
                         audio: [Data([1, 0])], scope: archive.scope)
        #expect(await archive.flush())
        #expect(await deliveries.waitForCount(2))
        archive.bind(key: nil)
        #expect(await archive.flush())
        let original = try Data(contentsOf: folder.appendingPathComponent(id.uuidString + ".body"))
        #expect(await original == deliveries.first?.bytes)
        #expect(try metadata(original)["app_version"] != nil)
        let retried = ArchiveDeliveries()
        let restarted = InteractionArchive(directory: folder) { key, path, bytes in
            await retried.add(key: key, path: path, bytes: bytes)
            return 204
        }
        restarted.bind(key: "compatibility-key")
        #expect(await retried.waitForCount(1))
        #expect(await retried.first?.bytes == original)
    }

    private func metadata(_ body: Data) throws -> [String: Any] {
        let length = body.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        return try #require(JSONSerialization.jsonObject(with: body.subdata(in: 4..<(4 + length))) as? [String: Any])
    }

    @Test(arguments: ["dictation_inserted", "draft_inserted", "proposal_client"])
    func largeEventsKeepExactUnicodeAndAuthority(kind: String) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let delivered = ArchiveDeliveries()
        let archive = InteractionArchive(directory: folder) { key, path, bytes in
            await delivered.add(key: key, path: path, bytes: bytes)
            return 204
        }
        archive.bind(key: "original-key")
        let scope = archive.scope
        archive.bind(key: "other-key")
        let id = UUID()
        let text = String(repeating: "🌍é漢字\"\n", count: 16_000)
        #expect(text.utf8.count > 200_000)
        archive.event(id, kind: kind, payload: ["text": .string(text), "outcome": .string("inserted")], scope: scope)
        #expect(await archive.flush())
        #expect(await delivered.count == 0)
        archive.bind(key: "original-key")
        #expect(await delivered.waitForCount(1))
        // Wait for all independently bounded requests, without assuming their UUID order.
        for _ in 0..<200 {
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            if !files.contains(where: { $0.pathExtension == "json" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let items = await delivered.all
        #expect(items.count > 1)
        #expect(items.allSatisfy { $0.bytes.count < 65_536 && $0.key == "original-key" && $0.path == "v1/retention/events" })
        var parts: [Int: Data] = [:]
        var rootID: String?
        var checksum: String?
        var expectedBytes = 0
        for item in items {
            let event = try #require(JSONSerialization.jsonObject(with: item.bytes) as? [String: Any])
            #expect(event["kind"] as? String == kind)
            #expect(event["interaction_id"] as? String == id.uuidString)
            let payload = try #require(event["payload"] as? [String: Any])
            #expect(payload["text"] == nil)
            let part = try #require(payload["chunked_event"] as? [String: Any])
            let identifier = try #require(part["event_id"] as? String)
            if let rootID { #expect(identifier == rootID) } else { rootID = identifier }
            #expect(part["total"] as? Int == items.count)
            #expect(part["encoding"] as? String == "base64-json")
            checksum = part["sha256"] as? String
            expectedBytes = try #require(part["bytes"] as? Int)
            parts[try #require(part["index"] as? Int)] = try #require(Data(base64Encoded: try #require(part["data"] as? String)))
        }
        let bytes = (0..<items.count).reduce(into: Data()) { $0.append(parts[$1] ?? Data()) }
        #expect(bytes.count == expectedBytes)
        #expect(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == checksum)
        let event = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(event["id"] as? String == rootID)
        #expect(event["kind"] as? String == kind)
        #expect(event["interaction_id"] as? String == id.uuidString)
        let payload = try #require(event["payload"] as? [String: Any])
        let restored = try #require(payload["text"] as? String)
        #expect(Data(restored.utf8) == Data(text.utf8))
        #expect(payload["outcome"] as? String == "inserted")
    }

    /// A body too large or that fails validation never succeeds as sent.
    @Test(arguments: [0, 2], [413, 422])
    func permanentFailureHasBoundedAttemptsAndDurableRejection(previousAttempts: Int, status: Int) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let deliveries = ArchiveDeliveries()
        let archive = InteractionArchive(directory: folder) { key, path, bytes in
            await deliveries.add(key: key, path: path, bytes: bytes)
            return bytes == Data("poison".utf8) ? status : 204
        }
        archive.bind(key: "seed-key")
        let scope = try #require(archive.scope)
        archive.bind(key: nil)
        #expect(await archive.flush())
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        try seedQueue(folder, id: id, scope: scope, body: Data("poison".utf8), attempts: previousAttempts)
        try seedQueue(folder, id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!, scope: scope, body: Data("good".utf8))
        archive.bind(key: "seed-key")
        #expect(await deliveries.waitForCount(4 - previousAttempts))
        let rejection = folder.appendingPathComponent("rejected/" + id.uuidString + ".json")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: rejection.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await deliveries.count == 4 - previousAttempts)
        let saved = try #require(try? Data(contentsOf: rejection))
        let record = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        #expect(record["reason"] as? String == "http_permanent")
        #expect(record["status"] as? Int == status)
        let item = try #require(record["item"] as? [String: Any])
        #expect(Data(base64Encoded: try #require(item["body"] as? String)) == Data("poison".utf8))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(id.uuidString + ".json").path))
        archive.bind(key: nil)
        #expect(await archive.flush())
        // Simulate a crash after the rejection journal committed but before
        // its active envelope was removed. Restart must finish, never resend.
        try seedQueue(folder, id: id, scope: scope, body: Data("poison".utf8), attempts: 2)
        let restarted = InteractionArchive(directory: folder) { key, path, bytes in
            await deliveries.add(key: key, path: path, bytes: bytes)
            return 204
        }
        restarted.bind(key: "seed-key")
        #expect(await restarted.flush())
        #expect(await deliveries.waitForCount(5 - previousAttempts, attempts: 10) == false)
        #expect(try Data(contentsOf: rejection) == saved)
    }

    @Test func oversizedLegacyEventIsKeptLocallyAndDoesNotBlockNextItem() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let deliveries = ArchiveDeliveries()
        let archive = InteractionArchive(directory: folder) { key, path, bytes in
            await deliveries.add(key: key, path: path, bytes: bytes)
            return 204
        }
        archive.bind(key: "seed-key")
        let scope = try #require(archive.scope)
        archive.bind(key: nil)
        #expect(await archive.flush())
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let original = Data(repeating: 42, count: 200_000)
        try seedQueue(folder, id: id, scope: scope, body: original)
        try seedQueue(folder, id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!, scope: scope, body: Data("good".utf8))
        archive.bind(key: "seed-key")
        #expect(await deliveries.waitForCount(1))
        #expect(await deliveries.largestBody < 65_536)
        let saved = try Data(contentsOf: folder.appendingPathComponent("rejected/" + id.uuidString + ".json"))
        let record = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        #expect(record["reason"] as? String == "event_oversized")
        let item = try #require(record["item"] as? [String: Any])
        #expect(Data(base64Encoded: try #require(item["body"] as? String)) == original)
    }

    /// The current server says an upload lock is busy with 503. An older one
    /// said it with 409, so 409 is retried too, never counted as permanent.
    @Test(arguments: [408, 409, 422, 425, 429, 503])
    func transientHTTPFailuresRemainRetryableAcrossRestart(status: Int) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let attempts = ArchiveDeliveries()
        let first = InteractionArchive(directory: folder) { key, path, bytes in
            await attempts.add(key: key, path: path, bytes: bytes)
            return status
        }
        first.bind(key: "transient-key")
        let kind = status == 422 ? "client_event" : "dictation_inserted"
        let payload: [String: JSONValue] = status == 422
            ? ["version": .number(1), "name": .string("app_launched"), "occurred_at": .string("2026-10-09T12:00:00Z")]
            : ["text": .string("Keep all these words")]
        first.event(UUID(), kind: kind, payload: payload, scope: first.scope)
        #expect(await first.flush())
        #expect(await attempts.waitForCount(1))
        first.bind(key: nil)
        #expect(await first.flush())
        // The queued item counted no permanent failure toward its cap.
        let envelopes = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        #expect(envelopes.count == 1)
        for file in envelopes {
            let envelope = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            #expect((envelope["permanentAttempts"] as? Int ?? 0) == 0)
        }
        let deliveries = ArchiveDeliveries()
        let restarted = InteractionArchive(directory: folder) { key, path, bytes in
            await deliveries.add(key: key, path: path, bytes: bytes)
            return 204
        }
        restarted.bind(key: "transient-key")
        #expect(await deliveries.waitForCount(1))
        #expect(await deliveries.first?.bytes == attempts.first?.bytes)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("rejected").path))
    }

    @Test func interruptedEventBatchResumesEveryPartAfterRestart() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let key = "batch-key"
        let scope = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let first = UUID(), second = UUID(), batchID = UUID()
        let bodies = [Data("first exact part".utf8), Data("second exact part".utf8)]
        let batch = zip([first, second], bodies).map { id, body -> [String: Any] in
            ["envelope": ["id": id.uuidString, "scope": scope, "path": "v1/retention/events"],
             "body": body.base64EncodedString()]
        }
        let journal = folder.appendingPathComponent(batchID.uuidString + ".batch")
        try JSONSerialization.data(withJSONObject: batch).write(to: journal)
        try seedQueue(folder, id: first, scope: scope, body: bodies[0])
        let blocker = folder.appendingPathComponent(second.uuidString + ".body")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        var archive: InteractionArchive? = InteractionArchive(directory: folder) { _, _, _ in 204 }
        #expect(await archive?.flush() == false)
        archive = nil
        try FileManager.default.removeItem(at: blocker)
        let deliveries = ArchiveDeliveries()
        let restarted = InteractionArchive(directory: folder) { key, path, bytes in
            await deliveries.add(key: key, path: path, bytes: bytes)
            return 204
        }
        restarted.bind(key: key)
        #expect(await restarted.flush())
        #expect(await deliveries.waitForCount(2))
        let items = await deliveries.all
        #expect(Set(items.map(\.bytes)) == Set(bodies))
        #expect(!FileManager.default.fileExists(atPath: journal.path))
    }

    /// The process dies at one write while a single recording is saved: its
    /// body or its envelope. Nothing is written after that write, as after a
    /// crash. The next launch uploads the exact recording under its own account.
    @Test(arguments: ["body", "json"])
    func aRecordingSurvivesACrashWhileItsFilesAreWritten(dying: String) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = "crash-device-key"
        let scope = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let id = UUID()
        let crash = CrashingDisk(dying: id.uuidString + "." + dying)
        var first: InteractionArchive? = InteractionArchive(directory: folder, write: crash.write) { _, _, _ in 204 }
        first?.dictation(.init(id: id, historyID: id, startedAt: Date(), finishedAt: Date(),
                               transcript: "raw words", formatted: "Raw words.", text: "Raw words.", outcome: "inserted"),
                         audio: [Data([1, 0, 2, 0]), Data([3, 0])], scope: scope)
        #expect(await first?.flush() == false)
        first = nil
        // The crash came at the chosen write: the envelope never committed.
        #expect(crash.died)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(id.uuidString + ".json").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(id.uuidString + ".body").path) == (dying == "json"))
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
            #expect(mode == 0o600)
        }
        #expect(try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int == 0o700)
        let deliveries = ArchiveDeliveries()
        let restarted = InteractionArchive(directory: folder) { key, path, bytes in
            await deliveries.add(key: key, path: path, bytes: bytes)
            return 204
        }
        restarted.bind(key: "another-device-key")
        #expect(await restarted.flush())
        #expect(await deliveries.count == 0)
        restarted.bind(key: key)
        #expect(await restarted.flush())
        #expect(await deliveries.waitForCount(1))
        let item = try #require(await deliveries.first)
        #expect(item.key == key)
        #expect(item.path == "v1/retention/dictations/" + id.uuidString.lowercased())
        let length = item.bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        let metadata = try #require(try JSONSerialization.jsonObject(with: item.bytes.subdata(in: 4..<(4 + length))) as? [String: Any])
        #expect(metadata["transcript"] as? String == "raw words")
        #expect(item.bytes.suffix(from: 4 + length) == Data([1, 0, 2, 0, 3, 0]))
        #expect(await restarted.flush())
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(left.filter { $0 != "history-imported" }.isEmpty)
    }

    private func seedQueue(_ folder: URL, id: UUID, scope: String, body: Data, attempts: Int = 0) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try body.write(to: folder.appendingPathComponent(id.uuidString + ".body"))
        let envelope: [String: Any] = ["id": id.uuidString, "scope": scope,
                                      "path": "v1/retention/events", "permanentAttempts": attempts]
        try JSONSerialization.data(withJSONObject: envelope).write(to: folder.appendingPathComponent(id.uuidString + ".json"))
    }

    @Test func queuedAudioSurvivesRestartAndUsesOnlyItsRecordingKey() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let delivered = ArchiveDeliveries()
        let first = InteractionArchive(directory: folder, send: { _, _, _ in throw URLError(.notConnectedToInternet) })
        first.bind(key: "first-device-key")
        let scope = try #require(first.scope)
        let id = UUID()
        first.dictation(.init(id: id, historyID: id, startedAt: Date(), finishedAt: Date(),
                             transcript: "raw words", formatted: "Raw words.", text: "Raw words.",
                             outcome: "inserted"), audio: [Data([1, 0, 2, 0])], scope: scope)
        #expect(await first.flush())
        first.bind(key: nil)
        let restarted = InteractionArchive(directory: folder, send: { key, path, bytes in
            await delivered.add(key: key, path: path, bytes: bytes)
            return 204
        })
        restarted.bind(key: "another-device-key")
        #expect(await restarted.flush())
        #expect(await delivered.count == 0)
        restarted.bind(key: "first-device-key")
        #expect(await delivered.waitForCount(1))
        let item = try #require(await delivered.first)
        #expect(item.key == "first-device-key")
        #expect(item.path == "v1/retention/dictations/" + id.uuidString.lowercased())
        #expect(item.bytes.suffix(4) == Data([1, 0, 2, 0]))
    }

    @MainActor @Test func retentionRetriesTheEntireHistoryBatchAfterDiskFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("queue")
        try Data([1]).write(to: folder)
        let deliveries = ArchiveDeliveries()
        let reported = Collected()
        let archive = InteractionArchive(directory: folder, report: { reported.add(Data($0.utf8)) }) { key, path, bytes in
            await deliveries.add(key: key, path: path, bytes: bytes)
            return 204
        }
        archive.bind(key: "history-key")
        archive.importHistory([
            .init(id: UUID(), date: Date(), text: "First", outcome: .inserted),
            .init(id: UUID(), date: Date(), text: "Second", outcome: .failed)
        ])
        #expect(await archive.flush() == false)
        #expect(reported.chunks.map { String(decoding: $0, as: UTF8.self) } == ["retention.disk_failed"])
        try FileManager.default.removeItem(at: folder)
        #expect(await deliveries.waitForCount(2, attempts: 800))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("history-imported").path))
        #expect(reported.chunks.map { String(decoding: $0, as: UTF8.self) } == ["retention.disk_failed", "retention.disk_recovered"])
    }

    @MainActor @Test func legacyHistoryFromASignedOutLaunchNeverMovesToANewAccount() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let deliveries = ArchiveDeliveries()
        let entries: [DictationHistory.Entry] = [.init(id: UUID(), date: Date(), text: "Previous account", outcome: .inserted)]
        let archive = InteractionArchive(directory: folder) { key, path, bytes in
            await deliveries.add(key: key, path: path, bytes: bytes)
            return 204
        }
        archive.bind(key: nil)
        archive.importHistory(entries)
        #expect(await archive.flush())
        archive.bind(key: "new-account")
        archive.importHistory(entries)
        #expect(await archive.flush())
        #expect(await deliveries.waitForCount(1, attempts: 10) == false)
        let restarted = InteractionArchive(directory: folder) { key, path, bytes in
            await deliveries.add(key: key, path: path, bytes: bytes)
            return 204
        }
        restarted.bind(key: "new-account")
        restarted.importHistory(entries)
        #expect(await restarted.flush())
        #expect(await deliveries.waitForCount(1, attempts: 10) == false)
    }

    @MainActor @Test func interruptedHistoryImportKeepsItsOriginalAccount() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let firstID = UUID(), secondID = UUID()
        let blocked = folder.appendingPathComponent(secondID.uuidString + ".body")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let entries: [DictationHistory.Entry] = [
            .init(id: firstID, date: Date(), text: "First account history", outcome: .inserted),
            .init(id: secondID, date: Date(), text: "Second history row", outcome: .inserted)
        ]
        var first: InteractionArchive? = InteractionArchive(directory: folder) { _, _, _ in
            throw URLError(.notConnectedToInternet)
        }
        first?.bind(key: "original-account-key")
        first?.importHistory(entries)
        #expect(await first?.flush() == false)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(firstID.uuidString + ".json").path))
        first?.bind(key: nil)
        #expect(await first?.flush() == false)
        first = nil
        try FileManager.default.removeItem(at: blocked)
        let delivered = ArchiveDeliveries()
        let restarted = InteractionArchive(directory: folder) { key, path, bytes in
            await delivered.add(key: key, path: path, bytes: bytes)
            return 204
        }
        restarted.bind(key: "different-account-key")
        restarted.importHistory(entries)
        #expect(await restarted.flush())
        #expect(await delivered.waitForCount(1, attempts: 10) == false)
        let id = UUID()
        restarted.dictation(.init(id: id, historyID: id, startedAt: Date(), finishedAt: Date(),
                                  transcript: "New account words", formatted: "New account words", text: "New account words",
                                  outcome: "inserted"), audio: [], scope: restarted.scope)
        #expect(await restarted.flush())
        #expect(await delivered.waitForCount(1))
        #expect(await delivered.first?.key == "different-account-key")
        restarted.bind(key: "original-account-key")
        #expect(await delivered.waitForCount(3))
    }

    @Test func signedOutFlushRetriesAPreviousDiskFailure() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data([1]).write(to: folder)
        let archive = InteractionArchive(directory: folder) { _, _, _ in throw URLError(.notConnectedToInternet) }
        archive.bind(key: "original-account-key")
        let id = UUID()
        archive.dictation(.init(id: id, historyID: id, startedAt: Date(), finishedAt: Date(),
                               transcript: "Kept", formatted: "Kept", text: "Kept", outcome: "inserted"),
                          audio: [], scope: archive.scope)
        #expect(await archive.flush() == false)
        archive.bind(key: nil)
        #expect(await archive.flush() == false)
        try FileManager.default.removeItem(at: folder)
        #expect(await archive.flush())
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(id.uuidString + ".json").path))
    }

    @Test func backgroundSpeechKeepsItsOriginalAccountAndBlocksQuitUntilFinished() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let delivered = ArchiveDeliveries()
        let archive = InteractionArchive(directory: folder) { key, path, bytes in
            await delivered.add(key: key, path: path, bytes: bytes)
            return 204
        }
        archive.bind(key: "original-key")
        let sink = try #require(archive.speech(UUID(), scope: archive.scope))
        archive.bind(key: "new-key")
        sink(.started)
        sink(.chunk(index: 0, total: 1, data: String(repeating: "/", count: 32_768)))
        #expect(await archive.flush() == false)
        sink(.finished(reason: nil))
        #expect(await archive.flush())
        #expect(await delivered.waitForCount(1, attempts: 10) == false)
        archive.bind(key: "original-key")
        #expect(await delivered.waitForCount(3))
        #expect(await delivered.first?.key == "original-key")
        #expect(await delivered.largestBody < 65_536)
    }

    @Test func enqueueDoesNotWaitForDiskOrNetwork() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let barrier = ArchiveBarrier()
        let archive = InteractionArchive(directory: folder, send: { _, _, _ in
            await barrier.wait()
            return 204
        })
        archive.bind(key: "synthetic-key")
        let clock = ContinuousClock()
        let start = clock.now
        let id = UUID()
        archive.dictation(.init(id: id, historyID: id, startedAt: Date(), finishedAt: Date(),
                               transcript: "", formatted: "", text: "", outcome: "failed"),
                          audio: [Data(count: 1_000_000)], scope: archive.scope)
        #expect(clock.now - start < .milliseconds(20))
        #expect(await archive.flush())
        await barrier.release()
    }
}

/// Writes as the archive does until the named file, then fails that write
/// and every later one, so the folder holds exactly what a crash there leaves.
final class CrashingDisk: @unchecked Sendable {
    private let lock = NSLock()
    private let dying: String
    private var dead = false
    init(dying: String) { self.dying = dying }
    var died: Bool { lock.withLock { dead } }
    var write: InteractionArchive.Writer {
        { data, url in
            try self.lock.withLock {
                if url.lastPathComponent == self.dying { self.dead = true }
                if self.dead { throw CocoaError(.fileWriteUnknown) }
            }
            try InteractionArchive.writePrivately(data, url)
        }
    }
}

actor ArchiveBarrier {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

actor ArchiveDeliveries {
    struct Item: Sendable { let key: String; let path: String; let bytes: Data }
    private var items: [Item] = []
    var count: Int { items.count }
    var all: [Item] { items }
    var first: Item? { items.first }
    var firstDictation: Item? { items.first { $0.path.hasPrefix("v1/retention/dictations/") } }
    var largestBody: Int { items.map { $0.bytes.count }.max() ?? 0 }
    func add(key: String, path: String, bytes: Data) { items.append(.init(key: key, path: path, bytes: bytes)) }
    func waitForCount(_ count: Int, attempts: Int = 200) async -> Bool {
        for _ in 0..<attempts {
            if items.count >= count { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}
