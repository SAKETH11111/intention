import Foundation
import Testing
@testable import Dictation

@MainActor @Suite(.serialized)
struct RetentionTransportTests {
    @Test(arguments: [false, true])
    func cancellationReturnsBeforeEvidenceAndKeepsTheCapturedExchange(timesOut: Bool) async throws {
        let data = Data(#"{"raw_response":"synthetic partial provider answer"}"#.utf8)
        let server = try await ScriptedEndpoint([.cancelledRetention(data: data, delay: 0.4)])
        defer { server.stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sent = Collected()
        let archive = InteractionArchive(directory: folder) { _, _, body in sent.add(body); return 204 }
        archive.bind(key: "synthetic-device-key")
        let stream = DictationStream(url: server.endpoint.url, grant: ScriptedEndpoint.grant,
            start: DictationStart(register: "work"), evidence: archive.speech(UUID(), scope: archive.scope))
        stream.send(Data([1, 0]))
        let connected = ContinuousClock.now + .seconds(3)
        while server.connections.first?.frames != 1, ContinuousClock.now < connected {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(server.connections.first?.frames == 1)
        let started = ContinuousClock.now
        if timesOut { stream.expire() } else { stream.cancel() }
        var replies = 0
        var failure: DictationStreamError?
        do { for try await _ in stream.replies { replies += 1 } }
        catch { failure = error as? DictationStreamError }
        #expect(failure == (timesOut ? .timedOut : nil))
        #expect(replies == 0)
        #expect(ContinuousClock.now - started < .milliseconds(300))
        #expect(!(await archive.flush()))
        stream.send(Data([2, 0]))
        #expect(!(await stream.finish()))
        let deadline = ContinuousClock.now + .seconds(3)
        while sent.chunks.count < 3, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await archive.flush())
        #expect(server.connections.first?.cancelled == true)
        #expect(server.connections.first?.frames == 1)
        let payloads = try sent.chunks.map { try #require(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
            .compactMap { $0["payload"] as? [String: Any] }
        let chunk = try #require(payloads.first { $0["phase"] as? String == "chunk" })
        #expect(Data(base64Encoded: try #require(chunk["data"] as? String)) == data)
        #expect(payloads.contains { $0["phase"] as? String == "complete" })
    }

    @Test func largeProviderEvidenceReachesTheArchiveAndTextStillReturns() async throws {
        let evidence = String(repeating: "synthetic", count: 140_000)
        let server = try await ScriptedEndpoint([
            .answer(transcript: "hello", text: "Hello.", retention: evidence)
        ])
        defer { server.stop() }
        let stream = DictationStream(url: server.endpoint.url, grant: ScriptedEndpoint.grant,
                                     start: DictationStart(register: "work"))
        defer { stream.cancel() }
        #expect(await stream.finish())
        var retained: String?
        var returned: String?
        for try await reply in stream.replies {
            switch reply {
            case let .retention(data):
                let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                retained = value?["raw_response"] as? String
            case let .text(text, _, _): returned = text
            case .transcript: break
            }
        }
        #expect(retained == evidence)
        #expect(returned == "Hello.")
    }
    @Test func textReturnsBeforeBackgroundEvidenceAndTheArchiveKeepsEveryChunk() async throws {
        let data = Data(String(repeating: "synthetic provider evidence", count: 50_000).utf8)
        let server = try await ScriptedEndpoint([.backgroundRetention(text: "Hello.", data: data, delay: 0.4)])
        defer { server.stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sent = Collected()
        let archive = InteractionArchive(directory: folder) { _, _, body in sent.add(body); return 204 }
        archive.bind(key: "synthetic-device-key")
        let id = UUID()
        let stream = DictationStream(url: server.endpoint.url, grant: ScriptedEndpoint.grant,
            start: DictationStart(register: "work"), evidence: archive.speech(id, scope: archive.scope))
        defer { stream.cancel() }
        let started = ContinuousClock.now
        #expect(await stream.finish())
        var returned: String?
        for try await reply in stream.replies {
            if case let .text(text, _, _) = reply { returned = text }
        }
        #expect(returned == "Hello.")
        stream.cancel() // Ending insertion must leave its background evidence alive.
        #expect(ContinuousClock.now - started < .milliseconds(300))
        #expect(!(await archive.flush()))
        let deadline = ContinuousClock.now + .seconds(3)
        let expected = (data.count + 24_575) / 24_576 + 2
        while sent.chunks.count < expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await archive.flush())
        let payloads = try sent.chunks.map { try #require(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
            .compactMap { $0["payload"] as? [String: Any] }
        let parts = payloads.filter { $0["phase"] as? String == "chunk" }
            .sorted { ($0["index"] as? Int ?? -1) < ($1["index"] as? Int ?? -1) }
        let restored = parts.reduce(into: Data()) { result, item in
            if let encoded = item["data"] as? String, let chunk = Data(base64Encoded: encoded) { result.append(chunk) }
        }
        #expect(restored == data)
        #expect(payloads.contains { $0["phase"] as? String == "complete" })
    }

    @Test func anInterruptedEvidenceTransferKeepsItsPartialChunksAndFailure() async throws {
        let data = Data(repeating: 65, count: 50_000)
        let server = try await ScriptedEndpoint([.backgroundRetention(text: "Hello.", data: data, delay: 0.1, omitLast: true)])
        defer { server.stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sent = Collected()
        let archive = InteractionArchive(directory: folder) { _, _, body in sent.add(body); return 204 }
        archive.bind(key: "synthetic-key")
        let stream = DictationStream(url: server.endpoint.url, grant: ScriptedEndpoint.grant,
            start: DictationStart(register: "work"), evidence: archive.speech(UUID(), scope: archive.scope))
        #expect(await stream.finish())
        for try await _ in stream.replies {}
        let deadline = ContinuousClock.now + .seconds(3)
        while sent.chunks.count < 4, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await archive.flush())
        let payloads = try sent.chunks.map { try #require(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
            .compactMap { $0["payload"] as? [String: Any] }
        #expect(payloads.filter { $0["phase"] as? String == "chunk" }.count == 2)
        #expect(payloads.contains { $0["phase"] as? String == "failed" && $0["reason"] as? String == "unreachable" })
        #expect(!payloads.contains { $0["phase"] as? String == "complete" })
    }

    /// The deadline runs out while chunk `index` of three is decoded or handed
    /// on. Every chunk received by then goes on, then one final event.
    @Test(arguments: [(1, false), (1, true), (0, true), (2, false)])
    func aDeadlineWhileAReceivedChunkIsHandledEndsEvidenceOnlyAfterHandingItOn(index: Int, inHandoff: Bool) async throws {
        let data = Data((0..<60_000).map { UInt8($0 % 251) })
        let server = try await ScriptedEndpoint([.backgroundRetention(text: "Hello.", data: data, delay: 0.05)])
        defer { server.stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sent = Collected()
        let archive = InteractionArchive(directory: folder) { _, _, body in sent.add(body); return 204 }
        archive.bind(key: "synthetic-device-key")
        let archived = try #require(archive.speech(UUID(), scope: archive.scope))
        let events = Collected()
        let deadline = HeldDeadline()
        let stream = DictationStream(url: server.endpoint.url, grant: ScriptedEndpoint.grant,
            start: DictationStart(register: "work"),
            evidence: { event in
                switch event {
                case .started: events.add(Data("started".utf8))
                case let .chunk(part, _, encoded):
                    events.add(Data("chunk \(part) \(encoded)".utf8))
                    // Reenters the stream's lock from inside the handoff.
                    if inHandoff, part == index { deadline.fire() }
                case let .finished(reason): events.add(Data("finished \(reason ?? "")".utf8))
                }
                archived(event)
            },
            evidenceDeadline: { deadline.arm($0) },
            decode: { text in
                let value = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                // The 30 seconds run out after the chunk was received and before it is handed on.
                if !inHandoff, let message = value as? [String: Any], message["type"] as? String == "retention",
                   message["index"] as? Int == index { deadline.fire() }
                return value
            })
        #expect(await stream.finish())
        for try await _ in stream.replies {}
        let finished = ContinuousClock.now + .seconds(3)
        while !events.chunks.contains(where: { $0.starts(with: Data("finished".utf8)) }), ContinuousClock.now < finished {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(200)) // Later chunks are on the wire and must never follow.
        let complete = index == 2
        let parts = (0...index).map { data.subdata(in: $0 * 24_576..<min(($0 + 1) * 24_576, data.count)) }
        #expect(events.chunks.map { String(decoding: $0, as: UTF8.self) }
            == ["started"] + parts.indices.map { "chunk \($0) \(parts[$0].base64EncodedString())" }
            + [complete ? "finished " : "finished timedOut"])
        let uploaded = ContinuousClock.now + .seconds(3)
        while sent.chunks.count < parts.count + 2, ContinuousClock.now < uploaded {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await archive.flush())
        let payloads = try sent.chunks.map { try #require(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
            .compactMap { $0["payload"] as? [String: Any] }
        let restored = payloads.filter { $0["phase"] as? String == "chunk" }
            .sorted { ($0["index"] as? Int ?? -1) < ($1["index"] as? Int ?? -1) }
            .reduce(into: Data()) { result, item in
                if let encoded = item["data"] as? String, let chunk = Data(base64Encoded: encoded) { result.append(chunk) }
            }
        #expect(restored == parts.reduce(into: Data()) { $0.append($1) })
        #expect(payloads.count == parts.count + 2)
        // The archive uploads queued files in name order, which is random, so
        // the final event can go first. `events` above already checks the order.
        let ends = { (item: [String: Any]) in ["complete", "failed"].contains(item["phase"] as? String) }
        for order in [payloads, payloads.filter(ends) + payloads.filter { !ends($0) }] {
            Self.expectOneEnding(order, complete: complete)
        }
    }

    /// Exactly one final event, of the expected kind, wherever it was uploaded.
    private static func expectOneEnding(_ payloads: [[String: Any]], complete: Bool) {
        let endings = payloads.filter { ["complete", "failed"].contains($0["phase"] as? String) }
        #expect(endings.count == 1)
        if complete { #expect(endings.first?["phase"] as? String == "complete") }
        else { #expect(endings.first?["phase"] as? String == "failed" && endings.first?["reason"] as? String == "timedOut") }
    }
}

/// The evidence deadline, run when the test says rather than after 30 seconds.
private final class HeldDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?

    func arm(_ action: @escaping @Sendable () -> Void) { lock.withLock { self.action = action } }

    func fire() { lock.withLock { action }?() }
}
