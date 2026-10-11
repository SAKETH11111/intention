// AppKit rather than Foundation: the Command Line Tools cannot load the
// overlay that importing Foundation beside Testing asks for.
import AppKit
@testable import Compose

/// A stand-in for the draft route, answering inside the process with the
/// receipts a scenario scripts, and recording every call. Each list of
/// answers is consumed in order and its last answer repeats.
final class ScriptedDrafts: DraftService, @unchecked Sendable {
    enum Answer {
        case receipt(DraftReceipt)
        case failure(DraftRequestFailure)
        case refusedKey(RefusedKey)
        /// Answers for the request's own id and revision, as the route
        /// would.
        case from(@Sendable (UUID, Int) -> DraftReceipt)
        /// The answer after `delay`, deaf to cancellation as a stalled
        /// connection is, for the scenarios about the wait's limit.
        indirect case late(Duration, Answer)
    }

    private let lock = NSLock()
    var creates: [Answer]
    var reads: [Answer]
    var cancels: [Answer]
    var accepts: [Answer]
    private(set) var created: [WritingInput] = []
    private(set) var read: [UUID] = []
    private(set) var cancelled: [UUID] = []
    private(set) var accepted: [(id: UUID, revision: Int)] = []
    /// Runs on each read, with how many there have been, for a scenario
    /// that changes something while the draft is pending.
    var onRead: (@Sendable (Int) -> Void)?

    init(creates: [Answer] = [], reads: [Answer] = [], cancels: [Answer] = [], accepts: [Answer] = []) {
        self.creates = creates
        self.reads = reads
        self.cancels = cancels
        self.accepts = accepts
    }

    /// A stand-in has no accounts: every request goes to it.
    func forThisAccount() async throws -> any DraftService { self }

    func create(_ input: WritingInput) async throws -> DraftReceipt {
        let answer: Answer? = lock.withLock {
            created.append(input)
            return Self.next(&creates)
        }
        return try await Self.resolve(answer ?? .from { Receipt.pending($0, $1) }, input.requestID, input.revision)
    }

    func read(_ requestID: UUID) async throws -> DraftReceipt {
        let (answer, count): (Answer?, Int) = lock.withLock {
            read.append(requestID)
            return (Self.next(&reads), read.count)
        }
        onRead?(count)
        return try await Self.resolve(answer ?? .from { Receipt.complete($0, revision: $1) }, requestID, revision(of: requestID))
    }

    func cancel(_ requestID: UUID) async throws -> DraftReceipt {
        let answer: Answer? = lock.withLock {
            cancelled.append(requestID)
            return Self.next(&cancels)
        }
        return try await Self.resolve(answer ?? .from { Receipt.make($0, revision: $1, status: .cancelled, reason: .cancelled) },
                                requestID, revision(of: requestID))
    }

    /// Every admission asked, and what each answers in turn, nil for 204;
    /// the last repeats.
    private(set) var shownCalls: [(id: UUID, revision: Int)] = []
    var shownAnswers: [DraftRequestFailure?] = [nil]
    /// A controllable wait before admission answers, with its call number.
    var beforeShown: (@Sendable (Int) async throws -> Void)?
    /// Holds an acceptance until the scenario releases its old account's answer.
    var beforeAccept: (@Sendable () async throws -> Void)?

    func shown(_ requestID: UUID, revision: Int, recipients: [WritingRecipient]) async throws {
        let (failure, count) = lock.withLock {
            shownCalls.append((requestID, revision))
            let failure = shownAnswers.count > 1 ? shownAnswers.removeFirst() : shownAnswers.first ?? nil
            return (failure, shownCalls.count)
        }
        try await beforeShown?(count)
        if let failure { throw failure }
    }

    func accept(_ requestID: UUID, revision: Int) async throws -> DraftReceipt {
        let answer: Answer? = lock.withLock {
            accepted.append((requestID, revision))
            return Self.next(&accepts)
        }
        try await beforeAccept?()
        return try await Self.resolve(answer ?? .from { Receipt.complete($0, revision: $1, accepted: true) }, requestID, revision)
    }

    /// The revision the request with this id was made with; 1 for one the
    /// scenario never created.
    private func revision(of requestID: UUID) -> Int {
        lock.withLock { created.last { $0.requestID == requestID }?.revision ?? 1 }
    }

    private static func next(_ answers: inout [Answer]) -> Answer? {
        guard let first = answers.first else { return nil }
        if answers.count > 1 { answers.removeFirst() }
        return first
    }

    private static func resolve(_ answer: Answer, _ requestID: UUID, _ revision: Int) async throws -> DraftReceipt {
        switch answer {
        case let .receipt(receipt): return receipt
        case let .failure(failure): throw failure
        case let .refusedKey(refused): throw refused
        case let .from(make): return make(requestID, revision)
        case let .late(delay, answer):
            // Detached, so cancelling the caller does not cut the wait short.
            await Task.detached { try? await Task.sleep(for: delay) }.value
            return try await resolve(answer, requestID, revision)
        }
    }
}

/// Receipts as the route shapes them, with a made-up identity.
enum Receipt {
    static let text = "Hi Jane,\n\nThanks for this. Thursday works; I will bring the agenda.\n\nBest,"

    static let identity = DraftReceipt.Identity(candidate: "retrieval-examples-v1", provider: "synthetic", model: "synthetic-model",
                                                modelRevision: "0", adapter: "synthetic-adapter",
                                                configurationID: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!)

    static func make(_ id: UUID, revision: Int = 1, status: DraftReceipt.Status, reason: DraftReason? = nil,
                     text: String? = nil, accepted: Bool = false) -> DraftReceipt {
        DraftReceipt(requestID: id, revision: revision, status: status, reason: reason, text: text, accepted: accepted,
                     identity: identity, sources: [],
                     cost: .init(status: status == .complete ? .reported : .notStarted, inputTokens: nil, outputTokens: nil,
                                 usd: nil, limitUSD: "0.05"))
    }

    static func pending(_ id: UUID, _ revision: Int = 1) -> DraftReceipt {
        make(id, revision: revision, status: .pending)
    }

    static func complete(_ id: UUID, revision: Int = 1, text: String = Receipt.text, accepted: Bool = false) -> DraftReceipt {
        make(id, revision: revision, status: .complete, text: text, accepted: accepted)
    }

    static func abstained(_ id: UUID, _ revision: Int, _ reason: DraftReason) -> DraftReceipt {
        make(id, revision: revision, status: .abstained, reason: reason)
    }

    /// The route's JSON for a receipt, for the HTTP client tests.
    static func json(_ id: UUID, revision: Int = 1, status: String, reason: String? = nil, text: String? = nil,
                     accepted: Bool = false) -> String {
        """
        {"request_id":"\(id.uuidString.lowercased())","revision":\(revision),"status":"\(status)",\
        "reason":\(reason.map { "\"\($0)\"" } ?? "null"),"text":\(text.map { "\"\($0)\"" } ?? "null"),\
        "origin":"generated","personalized":false,"accepted":\(accepted),\
        "identity":{"candidate":"retrieval-examples-v1","provider":"synthetic","model":"synthetic-model",\
        "model_revision":"0","adapter":"synthetic-adapter","configuration_id":"00000000-0000-4000-8000-000000000002"},\
        "sources":[],"cost":{"status":"not_started","input_tokens":null,"output_tokens":null,"usd":null,"limit_usd":"0.05"}}
        """
    }
}

/// The alpha transport answered inside the process, for the draft client
/// tests. Each request's method, path, headers and body are recorded.
final class DraftStub: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var json = "{}"
        var headers: [String: String] = [:]
        var failure: URLError.Code?
        /// How long the transport takes to answer.
        var delay: Duration = .zero
    }

    struct Seen {
        let method: String
        let path: String
        let authorization: String?
        let body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [Reply] = []
    nonisolated(unsafe) private(set) static var seen: [Seen] = []

    static func reset(_ replies: [Reply]) {
        lock.withLock {
            self.replies = replies
            seen = []
        }
    }

    static func client() -> AlphaClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DraftStub.self]
        return try! AlphaClient(endpoint: URL(string: "https://service.invalid")!, session: URLSession(configuration: configuration))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
            stream.close()
        } else if let direct = request.httpBody {
            body = direct
        }
        let reply: Reply = Self.lock.withLock {
            Self.seen.append(Seen(method: request.httpMethod ?? "GET", path: request.url?.path ?? "",
                                  authorization: request.value(forHTTPHeaderField: "Authorization"), body: body))
            guard let first = Self.replies.first else { return Reply(status: 404, json: #"{"detail":"draft_missing"}"#) }
            if Self.replies.count > 1 { Self.replies.removeFirst() }
            return first
        }
        guard reply.delay == .zero else {
            let delay = Double(reply.delay.components.attoseconds) / 1e18 + Double(reply.delay.components.seconds)
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { self.answer(reply) }
            return
        }
        answer(reply)
    }

    private func answer(_ reply: Reply) {
        if let failure = reply.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: reply.headers.merging(["Content-Type": "application/json"]) { $1 })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
