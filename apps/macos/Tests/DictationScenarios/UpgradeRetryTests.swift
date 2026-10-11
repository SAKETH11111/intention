import Foundation
import Network
import Testing
@testable import Dictation

struct UpgradeRetryTests {
    @Test func rejectedUpgradeRetriesOnceWithExactBufferedAudioAndOneEvidenceTransfer() async throws {
        let server = try await ScriptedEndpoint([.backgroundRetention(text: "Hello.", data: Data("evidence".utf8), delay: 0.01)])
        defer { server.stop() }
        let gate = try await UpgradeGate(target: server.endpoint.url, rejections: 1)
        defer { gate.stop() }
        let evidence = Collected()
        let stream = DictationStream(url: gate.url, grant: ScriptedEndpoint.grant,
            start: DictationStart(register: "work"), evidence: { event in
                switch event {
                case .started: evidence.add(Data("started".utf8))
                case let .chunk(_, _, data): evidence.add(Data(data.utf8))
                case .finished: evidence.add(Data("finished".utf8))
                }
            })
        let audio = [Data([1, 0, 2, 0]), Data([3, 0, 4, 0])]
        for frame in audio { stream.send(frame) }
        let began = ContinuousClock.now
        #expect(await stream.finish())
        var text: String?
        var failure: DictationStreamError?
        do {
            for try await reply in stream.replies {
                if case let .text(value, _, _) = reply { text = value }
            }
        } catch { failure = error as? DictationStreamError }
        #expect(failure == nil)
        #expect(text == "Hello.")
        #expect(gate.attempts == 2)
        #expect(ContinuousClock.now - began < .seconds(3))
        #expect(server.connections.count == 1)
        #expect(server.connections.first?.audio == audio.reduce(into: Data()) { $0.append($1) })
        #expect(server.connections.first?.stopFrames == 2)
        let deadline = ContinuousClock.now + .seconds(2)
        while evidence.chunks.count < 3, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(evidence.chunks.count == 3)
    }

    @Test func secondRejectedUpgradeEndsWithoutThirdAttempt() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let gate = try await UpgradeGate(target: server.endpoint.url, rejections: 10)
        defer { gate.stop() }
        let stream = DictationStream(url: gate.url, grant: ScriptedEndpoint.grant, start: DictationStart(register: "work"))
        #expect(await stream.finish() == false)
        var failure: DictationStreamError?
        do { for try await _ in stream.replies {} } catch { failure = error as? DictationStreamError }
        #expect(failure == .limited)
        #expect(gate.attempts == 2)
        #expect(server.connections.isEmpty)
    }

    @Test(arguments: [false, true])
    func cancellationOrOriginalDeadlineDuringRetryNeverReopens(expires: Bool) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let gate = try await UpgradeGate(target: server.endpoint.url, rejections: 1)
        defer { gate.stop() }
        let stream = DictationStream(url: gate.url, grant: ScriptedEndpoint.grant,
            start: DictationStart(register: "work"), evidence: { _ in })
        stream.send(Data([1, 0]))
        let stop = Task { await stream.finish() }
        let deadline = ContinuousClock.now + .seconds(2)
        while gate.attempts == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        if expires { stream.expire() } else { stream.cancel() }
        #expect(await stop.value == false)
        var failure: DictationStreamError?
        do { for try await _ in stream.replies {} } catch { failure = error as? DictationStreamError }
        #expect(failure == (expires ? .timedOut : nil))
        try await Task.sleep(for: .milliseconds(400))
        #expect(gate.attempts == 1)
        #expect(server.connections.isEmpty)
    }
}

/// A loopback TCP gate rejects the upgrade itself, before a websocket or
/// model request exists. Successful upgrades pass through byte for byte.
private final class UpgradeGate: @unchecked Sendable {
    private let listener: NWListener
    private let target: NWEndpoint.Port
    private let queue = DispatchQueue(label: "upgrade-gate")
    private let lock = NSLock()
    private var count = 0
    private var sockets: [NWConnection] = []
    private let rejections: Int
    var attempts: Int { lock.withLock { count } }
    var url: URL { URL(string: "ws://127.0.0.1:\(listener.port!.rawValue)/v1/dictation")! }

    init(target: URL, rejections: Int) async throws {
        self.target = NWEndpoint.Port(rawValue: UInt16(target.port!))!
        self.rejections = rejections
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] socket in
            guard let self else { return }
            self.lock.withLock { self.sockets.append(socket) }
            socket.start(queue: self.queue)
            self.header(socket, bytes: Data())
        }
        await withCheckedContinuation { ready in
            let once = Once()
            listener.stateUpdateHandler = { state in
                if case .ready = state, once.first() { ready.resume() }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        lock.withLock { sockets.forEach { $0.cancel() } }
    }

    private func header(_ socket: NWConnection, bytes: Data) {
        socket.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, done, error in
            guard let data, error == nil, !done else { return }
            var bytes = bytes
            bytes.append(data)
            guard bytes.range(of: Data("\r\n\r\n".utf8)) != nil else { header(socket, bytes: bytes); return }
            let number = lock.withLock { count += 1; return count }
            if number <= rejections {
                let response = Data("HTTP/1.1 429 Too Many Requests\r\nRetry-After: 86400\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                socket.send(content: response, completion: .contentProcessed { _ in socket.cancel() })
            } else {
                let upstream = NWConnection(host: "127.0.0.1", port: target, using: .tcp)
                lock.withLock { sockets.append(upstream) }
                let header = bytes
                upstream.stateUpdateHandler = { [self] state in
                    guard case .ready = state else { return }
                    upstream.send(content: header, completion: .contentProcessed { [self] _ in
                        pipe(socket, to: upstream)
                        pipe(upstream, to: socket)
                    })
                }
                upstream.start(queue: queue)
            }
        }
    }

    private func pipe(_ source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, done, error in
            guard error == nil, !done, let data else { destination.cancel(); return }
            destination.send(content: data, completion: .contentProcessed { [self] error in
                if error == nil { pipe(source, to: destination) }
            })
        }
    }
}
