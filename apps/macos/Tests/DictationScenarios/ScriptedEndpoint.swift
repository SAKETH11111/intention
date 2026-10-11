import Foundation
import Network
@testable import Dictation

/// A local stand-in for the dictation endpoint, speaking its websocket
/// protocol on a loopback port. Each connection follows the next scripted
/// behaviour (the last one repeats) and is recorded: its start message, the
/// audio frames it received, the stop's count and whether it was cancelled,
/// by a cancel message or by closing before an answer, as the endpoint takes it.
final class ScriptedEndpoint: @unchecked Sendable {
    enum Behavior {
        /// Answers the stop with this transcript and finished text.
        case answer(transcript: String, text: String, droppedLanguages: [String]? = nil, retention: String? = nil)
        case backgroundRetention(text: String, data: Data, delay: TimeInterval, omitLast: Bool = false)
        case cancelledRetention(data: Data, delay: TimeInterval)
        /// Answers the stop the same way `after` seconds later, as an
        /// endpoint still recognizing and cleaning a dictation.
        case answerLate(after: TimeInterval, transcript: String, text: String)
        /// Fails the dictation with one of the endpoint's reasons.
        case refuse(String)
        /// Fails it the same way `after` seconds after the stop.
        case refuseLate(after: TimeInterval, reason: String)
        /// Closes the connection after this many audio frames, as a network
        /// that drops mid-dictation.
        case drop(afterFrames: Int)
        /// Takes the audio and never answers.
        case silent
    }

    struct Connection {
        var start: [String: Any] = [:]
        var frames = 0
        var bytes = 0
        var audio = Data()
        var stopFrames: Int?
        var cancelled = false
        var answered = false
    }

    /// The grant the scripted credentials give unless told otherwise.
    static let grant = "v1.synthetic-grant"

    var behaviors: [Behavior]
    /// What each dictation's connection is given, `ScriptedGrants` by default.
    let credentials: ScriptedGrants
    private let lock = NSLock()
    private var recorded: [Connection] = []
    private let shown: Presented
    private let listener: NWListener
    private let queue = DispatchQueue(label: "scripted-endpoint")

    var connections: [Connection] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// The Authorization grants presented, in order, accepted or not.
    var presented: [String] { shown.all }

    var endpoint: DictationEndpoint {
        DictationEndpoint(url: URL(string: "ws://127.0.0.1:\(listener.port!.rawValue)/v1/dictation")!, credentials: credentials)
    }

    init(_ behaviors: [Behavior], credentials: ScriptedGrants = ScriptedGrants(), handshakeDelay: TimeInterval = 0) async throws {
        self.behaviors = behaviors
        self.credentials = credentials
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        let shown = Presented()
        self.shown = shown
        websocket.setClientRequestHandler(queue) { _, headers in
            let value = headers.first { $0.name.lowercased() == "authorization" }?.value ?? ""
            let grant = value.hasPrefix("Bearer ") ? String(value.dropFirst(7)) : ""
            shown.add(grant)
            if handshakeDelay > 0 { Thread.sleep(forTimeInterval: handshakeDelay) }
            return NWProtocolWebSocket.Response(status: grant == Self.grant ? .accept : .reject, subprotocol: nil)
        }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
            let once = Once()
            listener.stateUpdateHandler = { state in
                if case .ready = state, once.first() { ready.resume() }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        let index = recorded.count
        recorded.append(Connection())
        let behavior = behaviors[min(index, behaviors.count - 1)]
        lock.unlock()
        connection.start(queue: queue)
        receive(connection, index: index, behavior: behavior)
    }

    private func receive(_ connection: NWConnection, index: Int, behavior: Behavior) {
        connection.receiveMessage { [self] content, context, _, error in
            guard error == nil, let content,
                  let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
                  metadata.opcode != .close
            else {
                update(index) { if !$0.answered { $0.cancelled = true } }
                return
            }
            switch metadata.opcode {
            case .binary:
                let frames = update(index) {
                    $0.frames += 1
                    $0.bytes += content.count
                    $0.audio.append(content)
                    return $0.frames
                }
                if case let .drop(after) = behavior, frames >= after {
                    connection.cancel()
                    return
                }
            case .text:
                let message = (try? JSONSerialization.jsonObject(with: content)) as? [String: Any] ?? [:]
                switch message["type"] as? String {
                case "start":
                    update(index) { $0.start = message }
                case "stop":
                    let frames = update(index) {
                        $0.stopFrames = message["frames"] as? Int
                        return $0.frames
                    }
                    answer(connection, index: index, behavior: behavior, countMatches: message["frames"] as? Int == frames)
                case "cancel":
                    let retains = update(index) { item in
                        item.cancelled = true
                        return item.start["retention"] as? Bool == true
                    }
                    if case let .cancelledRetention(data, delay) = behavior {
                        send(["type": "error", "reason": "cancelled", "retention_follows": true], on: connection)
                        queue.asyncAfter(deadline: .now() + delay) { [self] in
                            send(["type": "retention", "index": 0, "total": 1,
                                  "data": data.base64EncodedString()], on: connection)
                        }
                    } else if retains {
                        send(["type": "error", "reason": "cancelled", "retention_follows": true], on: connection)
                        send(["type": "retention", "index": 0, "total": 1,
                              "data": Data("{}".utf8).base64EncodedString()], on: connection)
                    }
                default:
                    break
                }
            default:
                break
            }
            receive(connection, index: index, behavior: behavior)
        }
    }

    private func answer(_ connection: NWConnection, index: Int, behavior: Behavior, countMatches: Bool) {
        if case .silent = behavior, countMatches { return }
        if case let .answerLate(delay, transcript, text) = behavior, countMatches {
            queue.asyncAfter(deadline: .now() + delay) { [self] in
                update(index) { $0.answered = true }
                answer(connection, index: index, behavior: .answer(transcript: transcript, text: text), countMatches: true)
            }
            return
        }
        if case let .refuseLate(delay, reason) = behavior, countMatches {
            queue.asyncAfter(deadline: .now() + delay) { [self] in
                answer(connection, index: index, behavior: .refuse(reason), countMatches: true)
            }
            return
        }
        update(index) { $0.answered = true }
        guard countMatches else {
            send(["type": "error", "reason": "audio_incomplete"], on: connection)
            return
        }
        switch behavior {
        case let .answer(transcript, text, dropped, retention):
            send(["type": "transcript", "text": transcript, "after": 0.1], on: connection)
            var reply: [String: Any] = ["type": "text", "text": text, "cleaned": true, "after": 0.2]
            if let dropped { reply["dropped_languages"] = dropped }
            if let retention { reply["retention"] = ["raw_response": retention] }
            send(reply, on: connection)
        case let .backgroundRetention(text, data, delay, omitLast):
            send(["type": "text", "text": text, "cleaned": true, "retention_follows": true], on: connection)
            queue.asyncAfter(deadline: .now() + delay) { [self] in
                let total = max(1, (data.count + 24_575) / 24_576)
                for index in 0..<(total - (omitLast ? 1 : 0)) {
                    let start = index * 24_576
                    let part = data.subdata(in: start..<min(start + 24_576, data.count))
                    send(["type": "retention", "index": index, "total": total,
                          "data": part.base64EncodedString()], on: connection)
                }
                if omitLast { queue.asyncAfter(deadline: .now() + 0.1) { connection.cancel() } }
            }
        case let .refuse(reason):
            send(["type": "error", "reason": reason], on: connection)
        case .drop, .silent, .answerLate, .refuseLate, .cancelledRetention:
            break
        }
    }

    private func send(_ message: [String: Any], on connection: NWConnection) {
        let data = try! JSONSerialization.data(withJSONObject: message)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    @discardableResult
    private func update<T>(_ index: Int, _ change: (inout Connection) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return change(&recorded[index])
    }
}

/// A server that refuses every request with 401, as the endpoint does for a
/// grant it does not accept.
final class RefusingServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "refusing-server")
    let credentials: ScriptedGrants
    private let shown = Presented()

    /// The grants presented, in order.
    var presented: [String] { shown.all }

    var endpoint: DictationEndpoint {
        DictationEndpoint(url: URL(string: "ws://127.0.0.1:\(listener.port!.rawValue)/v1/dictation")!, credentials: credentials)
    }

    init(credentials: ScriptedGrants = ScriptedGrants()) async throws {
        self.credentials = credentials
        listener = try NWListener(using: .tcp, on: .any)
        let queue = queue
        let shown = shown
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                if let line = request.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("authorization: bearer ") }) {
                    shown.add(String(line.dropFirst("authorization: bearer ".count)))
                }
                let response = "HTTP/1.1 401 Unauthorized\r\nContent-Length: 13\r\nConnection: close\r\n\r\nunauthorized\n"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
            let once = Once()
            listener.stateUpdateHandler = { state in
                if case .ready = state, once.first() { ready.resume() }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func first() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let first = !done
        done = true
        return first
    }
}

/// Scripted speech grants: each call takes the next result, the last one
/// repeating, after `delay`. Records what it gave, what the endpoint refused
/// and every reset.
actor ScriptedGrants: SpeechCredentials {
    private var results: [Result<String, DictationStreamError>]
    private let delay: Duration
    private(set) var given: [String] = []
    private(set) var refusals: [String] = []
    private(set) var resets = 0

    init(_ results: [Result<String, DictationStreamError>] = [.success(ScriptedEndpoint.grant)], delay: Duration = .zero) {
        self.results = results
        self.delay = delay
    }

    func grant() async throws -> String {
        if delay > .zero { try? await Task.sleep(for: delay) }
        let result = results.count > 1 ? results.removeFirst() : results[0]
        let grant = try result.get()
        given.append(grant)
        return grant
    }

    func refused(_ grant: String) {
        refusals.append(grant)
    }

    func reset() {
        resets += 1
    }
}

/// The grants presented to a stand-in, from its listener's queue.
final class Presented: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    var all: [String] { lock.withLock { values } }

    func add(_ grant: String) {
        lock.withLock { values.append(grant) }
    }
}
