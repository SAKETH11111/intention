import CryptoKit
import Foundation

/// A finished attempt, independent of the history row that a later Retry replaces.
struct RetainedDictation: Sendable, Encodable {
    var id: UUID
    var historyID: UUID
    var retryOf: UUID? = nil
    var startedAt: Date
    var finishedAt: Date
    var transcript: String
    var formatted: String
    var text: String
    var outcome: String
    var reason: String? = nil
    var targetBundleID: String? = nil
    var targetKind: String? = nil
    var microphone: String? = nil
    var languages: [String] = []
    var timings: [String: Double] = [:]
    var speech: Data? = nil
    var imported = false
    var appVersion = AppBuildMetadata.version
    var appBuild = AppBuildMetadata.build

    private enum CodingKeys: String, CodingKey {
        case version, historyID = "history_id", retryOf = "retry_of", startedAt = "started_at", finishedAt = "finished_at"
        case transcript, formatted, text, outcome, reason, targetBundleID = "target_bundle_id", targetKind = "target_kind"
        case microphone, languages, timings, speech, imported
        case appVersion = "app_version", appBuild = "app_build"
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(1, forKey: .version)
        try values.encode(historyID, forKey: .historyID)
        try values.encodeIfPresent(retryOf, forKey: .retryOf)
        try values.encode(startedAt, forKey: .startedAt)
        try values.encode(finishedAt, forKey: .finishedAt)
        try values.encode(transcript, forKey: .transcript)
        try values.encode(formatted, forKey: .formatted)
        try values.encode(text, forKey: .text)
        try values.encode(outcome, forKey: .outcome)
        try values.encodeIfPresent(reason, forKey: .reason)
        try values.encodeIfPresent(targetBundleID, forKey: .targetBundleID)
        try values.encodeIfPresent(targetKind, forKey: .targetKind)
        try values.encodeIfPresent(microphone, forKey: .microphone)
        try values.encode(languages, forKey: .languages)
        try values.encode(timings, forKey: .timings)
        try values.encode(imported, forKey: .imported)
        try values.encode(appVersion, forKey: .appVersion)
        try values.encode(appBuild, forKey: .appBuild)
        try values.encode(speech.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .object([:]), forKey: .speech)
    }
}

/// Typed JSON at the transport boundary; no accessibility objects or credentials enter it.
indirect enum JSONValue: Codable, Sendable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let item = try? value.decode(Bool.self) { self = .bool(item) }
        else if let item = try? value.decode(String.self) { self = .string(item) }
        else if let item = try? value.decode(Double.self) { self = .number(item) }
        else if let item = try? value.decode([String: JSONValue].self) { self = .object(item) }
        else { self = .array(try value.decode([JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case let .string(item): try value.encode(item)
        case let .number(item): try value.encode(item)
        case let .bool(item): try value.encode(item)
        case let .array(item): try value.encode(item)
        case let .object(item): try value.encode(item)
        case .null: try value.encodeNil()
        }
    }
}

/// Enqueue returns after an in-memory handoff. One actor does all encoding, disk I/O
/// and uploads. A stalled disk or server cannot hold dictation or the main actor.
final class InteractionArchive: @unchecked Sendable {
    typealias Sender = @Sendable (String, String, Data) async throws -> Int
    /// Replaces one queue file whole. Tests stop it at a chosen file to leave
    /// the queue exactly as a crash at that write would.
    typealias Writer = @Sendable (Data, URL) throws -> Void
    private enum Command: Sendable {
        case bind(String?)
        case dictation(String, RetainedDictation, [Data])
        case event(String, UUID, String, [String: JSONValue], Bool)
        case history(String?, [DictationHistory.Entry])
        case speechStart(String, UUID, UUID)
        case speech(String, UUID, UUID, SpeechEvidence)
        case flush(CheckedContinuation<Bool, Never>)
    }
    private let lock = NSLock()
    private var currentScope: String?
    private let commands: AsyncStream<Command>.Continuation

    static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "co.intention.mac", isDirectory: true)
            .appendingPathComponent("InteractionUploads", isDirectory: true)
    }

    init(directory: URL, report: @escaping @Sendable (String) -> Void = { AppLog.dictation($0) },
         write: @escaping Writer = InteractionArchive.writePrivately, send: @escaping Sender) {
        let (stream, continuation) = AsyncStream<Command>.makeStream()
        commands = continuation
        let worker = Worker(directory: directory, send: send, write: write, report: report)
        Task.detached { await worker.run(stream) }
    }
    deinit { commands.finish() }

    var scope: String? { lock.withLock { currentScope } }

    func bind(key: String?) {
        lock.withLock { currentScope = key.map(Self.fingerprint) }
        commands.yield(.bind(key))
    }

    /// Atomic, then readable only by the person's account, inside the queue's 0700 folder.
    static let writePrivately: Writer = { data, url in
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func fingerprint(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func dictation(_ record: RetainedDictation, audio: [Data], scope: String?) {
        guard let scope else { return }
        commands.yield(.dictation(scope, record, audio))
    }

    func event(_ id: UUID, kind: String, payload: [String: JSONValue], scope: String?, once: Bool = false) {
        guard let scope else { return }
        // Mirror fixed lifecycle names for local reports. Content stays in the
        // retained archive, and events from a replaced scope cannot enter its ring.
        if scope == self.scope, let name = ClientEventName(rawValue: kind),
           [.draftShown, .draftInserted, .draftDismissed, .draftOutcome, .proposalGate].contains(name) {
            let outcome: ClientEventOutcome? = if case let .string(value) = payload["outcome"] {
                ClientEventOutcome(rawValue: value)
            } else { nil }
            DiagnosticEvents.shared.note(name, outcome: outcome, interactionID: id)
        }
        commands.yield(.event(scope, id, kind, payload, once))
    }

    /// Each stream keeps its attempt and account even after text returns. Received
    /// chunks join the same durable queue without holding up insertion.
    func speech(_ id: UUID, scope: String?) -> (@Sendable (SpeechEvidence) -> Void)? {
        guard let scope else { return nil }
        let token = UUID()
        commands.yield(.speechStart(scope, id, token))
        let commands = commands
        return { event in commands.yield(.speech(scope, id, token, event)) }
    }

    /// Called once at launch. Without a launch account, legacy rows have no
    /// trustworthy owner; mark the import considered without assigning them.
    @MainActor func importHistory(_ entries: [DictationHistory.Entry]) {
        commands.yield(.history(scope, entries))
    }

    /// A persistence barrier for tests and orderly shutdown. Dictation never calls it.
    func flush() async -> Bool {
        await withCheckedContinuation { commands.yield(.flush($0)) }
    }

    private actor Worker {
        struct Envelope: Codable {
            let id: UUID
            let scope: String
            let path: String
            var permanentAttempts: Int? = nil
        }
        struct Pending: Codable {
            let envelope: Envelope
            let body: Data
        }
        let directory: URL
        let send: Sender
        let write: Writer
        let report: @Sendable (String) -> Void
        var uploadFailed = false
        var key: String?
        var pending: [Pending] = []
        var receivingSpeech: Set<UUID> = []
        var startedSpeech: Set<UUID> = []
        var drainer: Task<Void, Never>?
        var persisted = true
        var afterFile: String?
        var historyBatch: [Pending]?
        var historyJournalSaved = false
        var eventBatches: [UUID: [Pending]] = [:]
        var savedEventBatches: Set<UUID> = []
        var loadedEventBatches = false
        var loadedMilestones = false
        var pendingMilestones: [String: Pending] = [:]

        init(directory: URL, send: @escaping Sender, write: @escaping Writer, report: @escaping @Sendable (String) -> Void) {
            self.directory = directory; self.send = send; self.write = write; self.report = report
        }

        func persistence(_ succeeded: Bool) {
            if persisted != succeeded { report(succeeded ? "retention.disk_recovered" : "retention.disk_failed") }
            persisted = succeeded
        }

        func upload(_ succeeded: Bool) {
            let failed = !succeeded
            if uploadFailed != failed { report(succeeded ? "retention.upload_recovered" : "retention.upload_failed") }
            uploadFailed = failed
        }

        func run(_ stream: AsyncStream<Command>) async {
            for await command in stream {
                switch command {
                case let .bind(value): key = value
                case let .dictation(scope, record, audio):
                    do { try queue(scope, record, audio) } catch { persistence(false) }
                case let .event(scope, id, kind, payload, once):
                    do { try queueEvent(scope, id, kind, payload, once: once) } catch { persistence(false) }
                case let .speechStart(_, _, token):
                    receivingSpeech.insert(token)
                case let .speech(scope, id, token, event):
                    guard receivingSpeech.contains(token) else { break }
                    if case .finished = event, !startedSpeech.contains(token) {
                        receivingSpeech.remove(token)
                        continue
                    }
                    var payload: [String: JSONValue] = ["stream_id": .string(token.uuidString)]
                    switch event {
                    case .started:
                        startedSpeech.insert(token)
                        payload["phase"] = .string("started")
                    case let .chunk(index, total, data):
                        payload.merge(["phase": .string("chunk"), "index": .number(Double(index)),
                                       "total": .number(Double(total)), "data": .string(data)]) { _, new in new }
                    case let .finished(reason):
                        receivingSpeech.remove(token)
                        startedSpeech.remove(token)
                        payload["phase"] = .string(reason == nil ? "complete" : "failed")
                        if let reason { payload["reason"] = .string(reason) }
                    }
                    do { try queueEvent(scope, id, "dictation_speech", payload) } catch { persistence(false) }
                case let .history(scope, entries):
                    do { try beginHistory(scope, entries) } catch { persistence(false) }
                case let .flush(done):
                    do { try persistPending() } catch { persistence(false) }
                    done.resume(returning: persisted && receivingSpeech.isEmpty)
                }
                if drainer == nil, key != nil {
                    drainer = Task { await drain() }
                }
            }
            drainer?.cancel()
        }

        func queueEvent(_ scope: String, _ id: UUID, _ kind: String, _ payload: [String: JSONValue], once: Bool = false) throws {
            struct Event: Encodable { let id: UUID; let interaction_id: UUID; let kind: String; let payload: [String: JSONValue] }
            var tagged = payload
            tagged["app_version"] = .string(AppBuildMetadata.version)
            tagged["app_build"] = .string(AppBuildMetadata.build)
            let event = Event(id: UUID(), interaction_id: id, kind: kind, payload: tagged)
            let encoder = Self.encoder()
            encoder.outputFormatting.insert(.withoutEscapingSlashes)
            let body = try encoder.encode(event)
            if once, kind == "client_event", case let .string(name) = payload["name"],
               ["first_dictation", "first_email"].contains(name) {
                let marker = scope + "-" + name + ".milestone"
                if pendingMilestones[marker] == nil,
                   !FileManager.default.fileExists(atPath: directory.appendingPathComponent(marker).path) {
                    pendingMilestones[marker] = .init(envelope: .init(id: event.id, scope: scope,
                        path: "v1/retention/events"), body: body)
                }
                try persistPending()
                return
            }
            if body.count < 65_536 {
                try save(.init(envelope: .init(id: event.id, scope: scope, path: "v1/retention/events"), body: body))
                return
            }
            // The original event is reconstructed from all parts, never from a
            // text prefix. Keep the kind so the server applies its draft owner check.
            let size = 24 * 1024
            let total = (body.count + size - 1) / size
            let checksum = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
            let parts = try (0..<total).map { index -> Pending in
                let bytes = body.subdata(in: index * size..<min((index + 1) * size, body.count))
                let part = Event(id: UUID(), interaction_id: id, kind: kind, payload: ["chunked_event": .object([
                    "version": .number(1), "event_id": .string(event.id.uuidString),
                    "encoding": .string("base64-json"), "index": .number(Double(index)),
                    "total": .number(Double(total)), "bytes": .number(Double(body.count)),
                    "sha256": .string(checksum), "data": .string(bytes.base64EncodedString())
                ])])
                return .init(envelope: .init(id: part.id, scope: scope, path: "v1/retention/events"),
                             body: try encoder.encode(part))
            }
            // Journal the whole batch before any part can be uploaded, so a
            // crash partway through persistence can recover every remaining part.
            eventBatches[event.id] = parts
            try persistPending()
        }

        func beginHistory(_ scope: String?, _ entries: [DictationHistory.Entry]) throws {
            if historyBatch == nil {
                let marker = directory.appendingPathComponent("history-imported")
                if FileManager.default.fileExists(atPath: marker.path) {
                    let saved = try Data(contentsOf: marker)
                    guard !saved.isEmpty else { return }
                    historyBatch = try JSONDecoder().decode([Pending].self, from: saved)
                } else {
                    historyBatch = try entries.filter { $0.retentionID == nil }.compactMap { entry -> Pending? in
                        guard let scope else { return nil }
                        let record = RetainedDictation(id: entry.id, historyID: entry.id, startedAt: entry.date, finishedAt: entry.date,
                            transcript: entry.spoken ?? entry.text, formatted: entry.text, text: entry.text,
                            outcome: entry.outcome.rawValue, reason: entry.reason, microphone: entry.device, imported: true)
                        return try encoded(scope, record, [])
                    }
                }
            }
            try persistPending()
        }

        static func encoder() -> JSONEncoder {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            return encoder
        }

        func queue(_ scope: String, _ record: RetainedDictation, _ audio: [Data]) throws {
            try save(encoded(scope, record, audio))
        }

        func encoded(_ scope: String, _ record: RetainedDictation, _ audio: [Data]) throws -> Pending {
            let metadata = try Self.encoder().encode(record)
            var length = UInt32(metadata.count).bigEndian
            var body = withUnsafeBytes(of: &length) { Data($0) }
            body.append(metadata)
            for chunk in audio { body.append(chunk) }
            return .init(envelope: .init(id: record.id, scope: scope,
                path: "v1/retention/dictations/" + record.id.uuidString.lowercased()), body: body)
        }

        /// A single item is journaled whole, like a batch of one, before its
        /// body and envelope are written.
        func save(_ item: Pending) throws {
            eventBatches[item.envelope.id] = [item]
            try persistPending()
        }

        func persistPending() throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            // Keep the exact first-use envelope as its durable claim. On restart
            // replaying it is idempotent, even if a crash hid the server's ACK.
            if !loadedMilestones {
                let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "milestone" }
                for file in files where pendingMilestones[file.lastPathComponent] == nil {
                    pending.append(try JSONDecoder().decode(Pending.self, from: Data(contentsOf: file)))
                }
                loadedMilestones = true
            }
            for (marker, item) in pendingMilestones {
                try write(Self.encoder().encode(item), directory.appendingPathComponent(marker))
                pending.append(item)
                pendingMilestones[marker] = nil
            }
            if !loadedEventBatches {
                let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "batch" }
                for file in files {
                    guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                          !savedEventBatches.contains(id) else { continue }
                    let batch = try JSONDecoder().decode([Pending].self, from: Data(contentsOf: file))
                    eventBatches[id] = batch
                    savedEventBatches.insert(id)
                    pending.append(contentsOf: batch)
                }
                loadedEventBatches = true
            }
            for (id, batch) in eventBatches where !savedEventBatches.contains(id) {
                let journal = directory.appendingPathComponent(id.uuidString + ".batch")
                try write(Self.encoder().encode(batch), journal)
                savedEventBatches.insert(id)
                pending.append(contentsOf: batch)
            }
            if let batch = historyBatch, !historyJournalSaved {
                // Commit the exact batch and its original device scope before any row.
                // An empty marker means complete; a nonempty one resumes after restart.
                let marker = directory.appendingPathComponent("history-imported")
                try write(Self.encoder().encode(batch), marker)
                historyJournalSaved = true
                pending.append(contentsOf: batch)
            }
            while let item = pending.first {
                let stem = item.envelope.id.uuidString
                let body = directory.appendingPathComponent(stem + ".body")
                let envelope = directory.appendingPathComponent(stem + ".json")
                if FileManager.default.fileExists(atPath: envelope.path) {
                    let existing = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: envelope))
                    guard existing.scope == item.envelope.scope, existing.path == item.envelope.path,
                          try Data(contentsOf: body) == item.body else { throw URLError(.cannotWriteToFile) }
                    pending.removeFirst()
                    continue
                }
                // The envelope commits last, after the item's journal. A crash
                // between the two is recovered from that journal at the next
                // launch, which writes the body again; an envelope never names
                // a partly written body.
                try write(item.body, body)
                try write(Self.encoder().encode(item.envelope), envelope)
                pending.removeFirst()
            }
            for id in savedEventBatches {
                try FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString + ".batch"))
                eventBatches[id] = nil
                savedEventBatches.remove(id)
            }
            if historyBatch != nil {
                try write(Data(), directory.appendingPathComponent("history-imported"))
                historyBatch = nil
                historyJournalSaved = false
            }
            persistence(true)
        }

        struct Rejection: Codable {
            let item: Pending
            let reason: String
            let status: Int?
        }

        func rejectionURL(_ id: UUID) -> URL {
            directory.appendingPathComponent("rejected", isDirectory: true)
                .appendingPathComponent(id.uuidString + ".json")
        }

        func removeActive(_ item: Pending, file: URL) throws {
            try FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(item.envelope.id.uuidString + ".body"))
        }

        func reject(_ item: Pending, file: URL, reason: String, status: Int? = nil) throws {
            let destination = rejectionURL(item.envelope.id)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                   withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Commit the complete local copy before taking it out of active retries.
            try write(Self.encoder().encode(Rejection(item: item, reason: reason, status: status)), destination)
            try removeActive(item, file: file)
            report("retention.upload_rejected")
        }

        func finishRejection(_ item: Pending, file: URL) throws -> Bool {
            let destination = rejectionURL(item.envelope.id)
            guard FileManager.default.fileExists(atPath: destination.path) else { return false }
            let saved = try JSONDecoder().decode(Rejection.self, from: Data(contentsOf: destination)).item
            guard saved.envelope.id == item.envelope.id, saved.envelope.scope == item.envelope.scope,
                  saved.envelope.path == item.envelope.path, saved.body == item.body else {
                throw URLError(.cannotWriteToFile)
            }
            // A restart between the rejection commit and active-file removal
            // finishes that removal without another network attempt.
            try removeActive(item, file: file)
            return true
        }

        /// Older servers forbid the two new metadata keys. Keep the original
        /// queue bytes for a failed retry, and change only this wire copy.
        func legacyDictation(_ body: Data) throws -> Data? {
            guard body.count >= 4 else { return nil }
            let length = body.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= body.count - 4,
                  var metadata = try JSONSerialization.jsonObject(with: body.subdata(in: 4..<(4 + length))) as? [String: Any],
                  metadata["app_version"] != nil || metadata["app_build"] != nil else { return nil }
            metadata.removeValue(forKey: "app_version")
            metadata.removeValue(forKey: "app_build")
            let encoded = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
            var count = UInt32(encoded.count).bigEndian
            var result = withUnsafeBytes(of: &count) { Data($0) }
            result.append(encoded)
            result.append(body.suffix(from: 4 + length))
            return result
        }

        func isClientEvent(_ body: Data) -> Bool {
            struct Kind: Decodable { let kind: String }
            return (try? JSONDecoder().decode(Kind.self, from: body).kind) == "client_event"
        }

        func drain() async {
            defer { drainer = nil }
            while !Task.isCancelled, let key {
                do { try persistPending() }
                catch {
                    persistence(false)
                    try? await Task.sleep(for: .seconds(5))
                    continue
                }
                do {
                    let scope = InteractionArchive.fingerprint(key)
                    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                        .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                    let ordered = files.filter { $0.lastPathComponent > (afterFile ?? "") } + files.filter { $0.lastPathComponent <= (afterFile ?? "") }
                    var found = false
                    for file in ordered {
                        afterFile = file.lastPathComponent
                        var envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: file))
                        guard envelope.scope == scope else { continue }
                        found = true
                        let bodyURL = directory.appendingPathComponent(envelope.id.uuidString + ".body")
                        let body = try Data(contentsOf: bodyURL)
                        let item = Pending(envelope: envelope, body: body)
                        if try finishRejection(item, file: file) { break }
                        if envelope.path == "v1/retention/events", body.count >= 65_536 {
                            try reject(item, file: file, reason: "event_oversized")
                            break
                        }
                        var status = try await send(key, envelope.path, body)
                        if [409, 422].contains(status), envelope.path.hasPrefix("v1/retention/dictations/"),
                           let legacy = try legacyDictation(body) {
                            status = try await send(key, envelope.path, legacy)
                        }
                        // A server awaiting the tracking update does not know
                        // this kind yet. Preserve it for replay after the update.
                        if status == 422, envelope.path == "v1/retention/events", isClientEvent(body) {
                            throw URLError(.badServerResponse)
                        }
                        // A body the server will never take as sent, such as 413 or a
                        // validation 422, gets three attempts, then is preserved
                        // locally. A busy upload lock is 503 now and was 409 on
                        // older servers, so both retry like throttling.
                        if (400..<500).contains(status), ![408, 409, 425, 429].contains(status) {
                            let attempts = (envelope.permanentAttempts ?? 0) + 1
                            envelope.permanentAttempts = attempts
                            if attempts >= 3 {
                                try reject(.init(envelope: envelope, body: body), file: file,
                                           reason: "http_permanent", status: status)
                            } else {
                                try write(Self.encoder().encode(envelope), file)
                            }
                            upload(false)
                            break
                        }
                        guard status == 204 else { throw URLError(.badServerResponse) }
                        try removeActive(item, file: file)
                        upload(true)
                        break
                    }
                    if !found { return }
                } catch {
                    // Preserve both the immutable bytes and any unwritten in-memory item.
                    // Never log the error, path, body, key or microphone name.
                    upload(false)
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
    }
}

/// The inserter reports only app identity and field kind from its existing target.
final class RetainedDestination: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (bundleID: String?, kind: String)?
    func record(_ bundleID: String?, _ kind: String) { lock.withLock { stored = (bundleID, kind) } }
    var value: (bundleID: String?, kind: String)? { lock.withLock { stored } }
}

/// Numeric bundle metadata only, never a user-selected app or field identity.
private enum AppBuildMetadata {
    static let version: String = {
        let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
        return value.range(of: "^[0-9]{1,5}(\\.[0-9]{1,5}){1,3}$", options: .regularExpression) != nil ? value : "0.0"
    }()
    static let build: String = {
        let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return value.range(of: "^[0-9]{1,10}$", options: .regularExpression) != nil ? value : "0"
    }()
}
