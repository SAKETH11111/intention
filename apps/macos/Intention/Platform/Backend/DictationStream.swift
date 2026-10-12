import Foundation

/// Where the dictation endpoint is and how a connection proves the person's
/// account. The address comes from Info.plist's `IntentionProxyURL`, set by the
/// build setting `INTENTION_PROXY_URL`; the build holds no secret. Each
/// connection presents a speech grant from `credentials`, which the
/// backend signs for a signed-in device and which lasts five minutes.
struct DictationEndpoint: Sendable {
    let url: URL
    let credentials: any SpeechCredentials

    /// The address this build names, or nil when it is unset or not a
    /// websocket URL, which leaves dictation off.
    static func address(in bundle: Bundle = .main) -> URL? {
        guard let client = AlphaClient.configured(in: bundle),
              var components = URLComponents(url: client.endpoint, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = client.endpoint.scheme == "http" ? "ws" : "wss"
        components.path = "/speech"
        return components.url
    }
}

/// Gives each dictation connection a grant for the account signed in now.
protocol SpeechCredentials: Sendable {
    /// A grant with at least a minute left. Throws a `DictationStreamError`:
    /// `signedOut` when this Mac has no account or the backend refused its
    /// key, `limited` when the backend asks it to wait, `unreachable`
    /// otherwise.
    func grant() async throws -> String
    /// The endpoint refused `grant`, so it is not offered again.
    func refused(_ grant: String) async
    /// The account changed or signed out: nothing fetched before is used.
    func reset() async
}

/// What the endpoint is told when a dictation starts.
struct DictationStart: Sendable, Equatable {
    /// personal, work, email or other, which sets the cleanup's register.
    var register: String
    /// Text just before the caret, so the finished text continues it.
    var before: String?
    /// The person's names and frequent terms, which the endpoint uses to
    /// fix ones the recognizer misheard. Each connection refreshes these from
    /// currently permitted cloud sources.
    var names: [String] = []
    var terms: [String] = []
    /// A monotonic deadline, never serialized or retained in retry history.
    var vocabularyExpiresAt: ContinuousClock.Instant?
    /// The languages the person dictates in, as two-letter codes. Empty
    /// means English; the endpoint sends each language to the recognizers
    /// measured best for it.
    var languages: [String] = []
    var retention = false

    func message() -> String {
        let fresh = vocabularyExpiresAt.map { ContinuousClock.now < $0 } ?? true
        var start: [String: Any] = ["type": "start", "app": register, "names": fresh ? names : [], "terms": fresh ? terms : []]
        if let before { start["before"] = before }
        if !languages.isEmpty { start["languages"] = languages }
        if retention { start["retention"] = true }
        let data = (try? JSONSerialization.data(withJSONObject: start)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

enum DictationReply: Sendable, Equatable {
    /// What was said, word for word. Arrives first.
    case transcript(String)
    /// Private diagnostics returned by the endpoint, never logged.
    case retention(Data)
    /// What the person meant. `cleaned` is false when cleanup failed and the
    /// text is the transcript.
    case text(String, cleaned: Bool, droppedLanguages: [String] = [])
}

enum SpeechEvidence: Sendable {
    case started
    case chunk(index: Int, total: Int, data: String)
    case finished(reason: String?)
}

enum DictationStreamError: Error, Equatable {
    /// The endpoint refused the grant.
    case unauthorized
    /// This Mac is not signed in, or the backend no longer accepts its key.
    case signedOut
    /// The backend or the endpoint asked this account to wait.
    case limited
    /// The connection could not be made or broke before the answer.
    case unreachable
    /// The endpoint failed the dictation, with one of its fixed reasons.
    case refused(String)
    /// A message the protocol does not define.
    case malformed
    /// No answer arrived in time.
    case timedOut

    /// Fixed text, safe to log and store.
    var name: String {
        switch self {
        case .unauthorized: "unauthorized"
        case .signedOut: "signedOut"
        case .limited: "limited"
        case .unreachable: "unreachable"
        case let .refused(reason): "refused." + (DictationStream.reasons.contains(reason) ? reason : "other")
        case .malformed: "malformed"
        case .timedOut: "timedOut"
        }
    }
}

/// One dictation over the endpoint's websocket, as specified in
/// the proxy speech protocol: a start message, binary
/// frames of 16 kHz mono 16-bit PCM as they are recorded, then a stop that
/// counts the frames. The endpoint answers with the transcript and then the
/// finished text, or an error, and the connection closes.
///
/// `send` and `finish` may be called from any thread; frames go out in the
/// order they were given. Replies arrive on `replies`, which ends after the
/// finished text or throws a `DictationStreamError`. When requested, evidence
/// continues on the same connection through its separate callback after that.
final class DictationStream: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    /// The endpoint's failure reasons (`REASONS` in server.py).
    static let reasons: Set<String> = [
        "bad_start", "bad_message", "audio_incomplete", "too_long", "timeout",
        "recognizer_failed", "recognizer_stalled", "internal", "language_unsupported",
    ]
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }()

    /// Transport instants survive a bounded upload wait and delayed reply consumption.
    /// The stream owns these first observations; reading them never advances stages.
    struct TimingSnapshot: Sendable, Equatable {
        var stopSent: ContinuousClock.Instant?
        var transcriptReceived: ContinuousClock.Instant?
        var cleanedTextReceived: ContinuousClock.Instant?
    }

    private var timing = TimingSnapshot()
    var timingSnapshot: TimingSnapshot { lock.withLock { timing } }

    let replies: AsyncThrowingStream<DictationReply, Error>
    private let continuation: AsyncThrowingStream<DictationReply, Error>.Continuation
    private var task: URLSessionWebSocketTask
    private let request: URLRequest
    private let openingDeadline: ContinuousClock.Instant
    private var retriedUpgrade = false
    private var retryPending = false
    // Evidence callbacks are ordered with state changes. A callback may reenter
    // cancellation; the recursive lock lets it observe the already committed state.
    private let lock = NSRecursiveLock()
    private var frames = 0
    private var ended = false
    private var opened = false
    private let start: DictationStart
    private let evidence: (@Sendable (SpeechEvidence) -> Void)?
    private var pendingEvidence = false
    private var cancelled = false
    private var evidenceParts = 0
    private var expectedEvidenceParts: Int?
    // A received evidence chunk is decoded outside the lock. From the moment
    // its receive is accepted until its handoff, the deadline or a failed send
    // is held here, and `receive` ends the stream with it after the handoff.
    private var receivingEvidence = false
    private var heldEnd: DictationStreamError?
    private var waiting: [(URLSessionWebSocketTask.Message, @Sendable (Bool) -> Void)] = []
    private let evidenceDeadline: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let decode: @Sendable (String) -> Any?
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sendMessage: @Sendable (URLSessionWebSocketTask, URLSessionWebSocketTask.Message,
                                       @escaping @Sendable (Error?) -> Void) -> Void

    /// `evidenceDeadline` runs its action when evidence has waited long
    /// enough, and `decode` parses each received message; tests replace them
    /// to place the deadline inside a message's handling. The clock and send
    /// adapter let tests hold a transport callback past the upload wait.
    init(url: URL, grant: String, start: DictationStart,
         evidence: (@Sendable (SpeechEvidence) -> Void)? = nil,
         evidenceDeadline: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = {
             DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: $0)
         },
         decode: @escaping @Sendable (String) -> Any? = { try? JSONSerialization.jsonObject(with: Data($0.utf8)) },
         now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
         sendMessage: @escaping @Sendable (URLSessionWebSocketTask, URLSessionWebSocketTask.Message,
                                          @escaping @Sendable (Error?) -> Void) -> Void = {
             $0.send($1, completionHandler: $2)
         }) {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer \(grant)", forHTTPHeaderField: "Authorization")
        self.request = request
        openingDeadline = .now + .seconds(10)
        task = Self.session.webSocketTask(with: request)
        // The private formatter evidence can exceed URLSession's 1 MiB default.
        // New servers send bounded chunks after text; this also reads older replies.
        task.maximumMessageSize = 128 * 1024 * 1024
        (replies, continuation) = AsyncThrowingStream.makeStream()
        var requested = start
        requested.retention = evidence != nil
        self.start = requested
        self.evidence = evidence
        self.evidenceDeadline = evidenceDeadline
        self.decode = decode
        self.now = now
        self.sendMessage = sendMessage
        super.init()
        task.delegate = self
        guard BackendAddress.isSpeech(url) else { end(.unreachable); return }
        task.resume()
        receive()
    }

    /// Sends one chunk of audio.
    func send(_ pcm: Data) {
        lock.lock()
        guard !cancelled, !ended else { lock.unlock(); return }
        frames += 1
        lock.unlock()
        transmit(.data(pcm))
    }

    /// Tells the endpoint the person stopped, counting every chunk sent.
    /// Returns once the stop, and every frame queued before it, has gone
    /// out to the network, or the connection failed, so a wait for the
    /// answer can start then rather than while audio is still uploading.
    @discardableResult
    func finish() async -> Bool {
        let count = lock.withLock { frames }
        return await withCheckedContinuation { sent in
            transmit(.string(#"{"type":"stop","frames":\#(count)}"#)) { [self] success in
                let instant = now()
                if success {
                    lock.withLock {
                        if timing.stopSent == nil { timing.stopSent = instant }
                    }
                }
                sent.resume(returning: success)
            }
        }
    }

    /// Ends the answer immediately. An archived attempt sends cancellation and
    /// drains the endpoint's already captured evidence independently.
    func cancel() {
        abandon(nil)
    }

    /// Gives up waiting: `replies` throws `timedOut`.
    func expire() {
        abandon(.timedOut)
    }

    private func abandon(_ error: DictationStreamError?) {
        guard evidence != nil, lock.withLock({ opened }) else {
            if end(error, evidenceReason: "cancelled") { task.cancel(with: .normalClosure, reason: nil) }
            return
        }
        lock.lock()
        guard !ended, !pendingEvidence else { lock.unlock(); return }
        cancelled = true
        pendingEvidence = true
        let queued = waiting
        waiting = []
        evidence?(.started)
        lock.unlock()
        for (_, completion) in queued { completion(false) }
        if let error { continuation.finish(throwing: error) }
        else { continuation.finish() }
        transmit(.string(#"{"type":"cancel"}"#), whileCancelled: true)
        timeOutEvidence()
    }

    /// Refuse every redirect before any speech or context is sent.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    static func isSameEndpoint(_ actual: URL?, as expected: URL?) -> Bool {
        guard let actual, let expected else { return false }
        let scheme = actual.scheme == "https" ? "wss" : actual.scheme == "http" ? "ws" : actual.scheme
        return scheme == expected.scheme && actual.host == expected.host && actual.port == expected.port
            && actual.path == expected.path && actual.query == nil && actual.fragment == nil
            && actual.user == nil && actual.password == nil
    }

    // Frames wait for the handshake, so the start's freshness is checked at
    // the actual connection opening and the start always precedes audio/stop.
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        lock.lock()
        guard !ended, !cancelled, webSocketTask === task else { lock.unlock(); return }
        guard Self.isSameEndpoint(webSocketTask.currentRequest?.url, as: request.url) else {
            end(.unreachable)
            lock.unlock()
            return
        }
        opened = true
        write(.string(start.message()), completion: { _ in })
        let queued = waiting
        waiting = []
        for (message, completion) in queued { write(message, completion: completion) }
        lock.unlock()
    }

    private func transmit(_ message: URLSessionWebSocketTask.Message,
                          whileCancelled: Bool = false,
                          completion: @escaping @Sendable (Bool) -> Void = { _ in }) {
        lock.lock()
        guard !ended, !cancelled || whileCancelled else { lock.unlock(); completion(false); return }
        if opened { write(message, completion: completion) }
        else { waiting.append((message, completion)) }
        lock.unlock()
    }

    private func write(_ message: URLSessionWebSocketTask.Message,
                       completion: @escaping @Sendable (Bool) -> Void) {
        let source = task
        sendMessage(source, message) { [weak self] error in
            completion(error == nil)
            if error != nil { self?.fail(source) }
        }
    }

    private func receive() {
        lock.lock()
        receivingEvidence = false
        let held = heldEnd
        lock.unlock()
        if let held {
            end(held)
            return
        }
        let source = task
        source.receive { [self] result in
            let receivedAt = now()
            let accepted = lock.withLock { () -> Bool in
                guard source === task, !ended else { return false }
                if pendingEvidence, case .success(.string) = result { receivingEvidence = true }
                return true
            }
            guard accepted else { return }
            // Parsing provider evidence can be large. Keep it outside the state
            // lock so sending audio and cancelling never wait on JSON decoding.
            switch result {
            case let .success(.string(text)):
                handle(text, receivedAt: receivedAt)
            case .success:
                end(.malformed)
            case .failure:
                fail(source)
            }
        }
    }

    private func handle(_ text: String, receivedAt: ContinuousClock.Instant) {
        guard let message = decode(text) as? [String: Any],
              let type = message["type"] as? String else {
            end(.malformed)
            return
        }
        if type == "retention" {
            guard let index = message["index"] as? Int, let total = message["total"] as? Int,
                  let encoded = message["data"] as? String, encoded.utf8.count <= 32_768,
                  let bytes = Data(base64Encoded: encoded), bytes.count <= 24_576 else {
                end(.malformed)
                return
            }
            // Counting and handing on the chunk is one step with the stream's
            // state, so a deadline or failure ends evidence only after it.
            lock.lock()
            guard pendingEvidence, total > 0, index == evidenceParts, index < total,
                  expectedEvidenceParts == nil || expectedEvidenceParts == total else {
                lock.unlock()
                end(.malformed)
                return
            }
            expectedEvidenceParts = total
            evidenceParts += 1
            let last = evidenceParts == total
            evidence?(.chunk(index: index, total: total, data: encoded))
            lock.unlock()
            if last {
                if end(nil) { task.cancel(with: .normalClosure, reason: nil) }
            } else { receive() }
            return
        }
        if var retained = message["retention"] as? [String: Any] {
            if let after = message["after"] { retained["after"] = after }
            if let data = try? JSONSerialization.data(withJSONObject: retained) {
                continuation.yield(.retention(data))
            }
        }
        switch (type, message["text"] as? String) {
        case let ("transcript", text?):
            lock.withLock {
                if !ended, !cancelled, timing.transcriptReceived == nil { timing.transcriptReceived = receivedAt }
            }
            continuation.yield(.transcript(text))
            receive()
        case let ("text", text?):
            lock.withLock {
                if !ended, !cancelled, timing.cleanedTextReceived == nil { timing.cleanedTextReceived = receivedAt }
            }
            let dropped = (message["dropped_languages"] as? [String] ?? []).filter { start.languages.contains($0) }
            let follows = keepReceivingEvidence(message)
            continuation.yield(.text(text, cleaned: message["cleaned"] as? Bool ?? false, droppedLanguages: dropped))
            if follows {
                continuation.finish()
                receive()
            } else if end(nil) { task.cancel(with: .normalClosure, reason: nil) }
        case ("error", _):
            let error = DictationStreamError.refused(message["reason"] as? String ?? "")
            if keepReceivingEvidence(message) {
                continuation.finish(throwing: error)
                receive()
            } else { end(error) }
        default:
            end(.malformed)
        }
    }

    private func keepReceivingEvidence(_ message: [String: Any]) -> Bool {
        guard evidence != nil, message["retention_follows"] as? Bool == true else { return false }
        lock.lock()
        guard !ended else { lock.unlock(); return false }
        let first = !pendingEvidence
        pendingEvidence = true
        if first { evidence?(.started) }
        lock.unlock()
        if first { timeOutEvidence() }
        return true
    }

    private func timeOutEvidence() {
        evidenceDeadline { [weak self] in
            guard let self else { return }
            // Deciding and ending under one lock, so no receive is accepted between them.
            lock.lock()
            defer { lock.unlock() }
            guard pendingEvidence else { return }
            if receivingEvidence { heldEnd = heldEnd ?? .timedOut }
            else { end(.timedOut) }
        }
    }

    /// A send or receive failed: the grant was refused at the handshake, the
    /// account is over its limit, or the connection could not be made or
    /// broke.
    private func fail(_ source: URLSessionWebSocketTask) {
        lock.lock()
        defer { lock.unlock() }
        guard source === task, !ended, !retryPending else { return }
        // Evidence follows an opened connection, so this failure is unreachable.
        if receivingEvidence {
            heldEnd = heldEnd ?? .unreachable
            return
        }
        switch (source.response as? HTTPURLResponse)?.statusCode {
        case 401: end(.unauthorized)
        case 429:
            // No start, audio or model request went out before a rejected
            // upgrade. The same queued frames and stop can safely go once.
            guard !opened, !cancelled, !retriedUpgrade else { end(.limited); return }
            retriedUpgrade = true
            retryPending = true
            source.cancel(with: .normalClosure, reason: nil)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { [self] in
                lock.lock()
                defer { lock.unlock() }
                guard !ended, !cancelled, retryPending else { return }
                let remaining = ContinuousClock.now.duration(to: openingDeadline)
                guard remaining > .zero else { end(.timedOut); return }
                var retry = request
                let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
                retry.timeoutInterval = seconds
                task = Self.session.webSocketTask(with: retry)
                task.maximumMessageSize = 128 * 1024 * 1024
                task.delegate = self
                retryPending = false
                task.resume()
                receive()
            }
        default: end(.unreachable)
        }
    }

    /// Closes transport and evidence once. Replies may already have ended
    /// when text returned; later transfer errors are evidence outcomes only.
    @discardableResult
    private func end(_ error: DictationStreamError?, evidenceReason: String? = nil) -> Bool {
        lock.lock()
        let first = !ended
        ended = true
        pendingEvidence = false
        receivingEvidence = false
        let queued = waiting
        waiting = []
        if first { evidence?(.finished(reason: evidenceReason ?? error?.name)) }
        lock.unlock()
        for (_, completion) in queued { completion(false) }
        guard first else { return false }
        if let error {
            continuation.finish(throwing: error)
            task.cancel(with: .normalClosure, reason: nil)
        } else {
            continuation.finish()
        }
        return true
    }
}
