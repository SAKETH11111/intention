import Foundation
import os

/// A process-local counter shared by writer stages and their transport
/// callbacks. Cancellation stays with the attempt after a newer one starts.
/// No request identifier, account, URL or content is retained here.
final class DraftAttempt: Sendable {
    @TaskLocal static var current: DraftAttempt?
    private static let counter = OSAllocatedUnfairLock(initialState: 0)
    private let cancellation = OSAllocatedUnfairLock(initialState: false)
    private let report: @Sendable (String, Int) -> Void
    let number: Int

    /// The writer supplies logging so standalone transport and release
    /// address checks compile without the app's logging module.
    init(log: @escaping @Sendable (String, Int) -> Void = { _, _ in }) {
        report = log
        number = Self.counter.withLock { value in
            value += 1
            return value
        }
    }

    var isCancelled: Bool { cancellation.withLock { $0 } }
    func cancel() { cancellation.withLock { $0 = true } }

    func log(_ stage: String, returned: Bool = false) {
        let suffix = returned && isCancelled ? ".cancelled" : ""
        report("\(stage)\(suffix)", number)
    }
}

/// The alpha transport accepts only HTTPS. It never logs an invite or device key.
/// Onboarding owns the UI, and `DeviceKeyStore` keeps the returned key.
struct AlphaClient: Sendable {
    struct Registration: Decodable, Sendable {
        let accountID: UUID
        let deviceID: UUID
        let deviceKey: String

        enum CodingKeys: String, CodingKey {
            case accountID = "account_id"
            case deviceID = "device_id"
            case deviceKey = "device_key"
        }
    }

    struct Identity: Decodable, Sendable {
        let accountID: UUID
        let deviceID: UUID

        enum CodingKeys: String, CodingKey {
            case accountID = "account_id"
            case deviceID = "device_id"
        }
    }

    enum Failure: Error {
        case insecureEndpoint
        case invalidResponse
        case rejected(Int)
        /// 429, with the seconds the server asked the caller to wait.
        case tooManyRequests(retryAfter: Int?)
    }

    /// Fixed route names only. Transport diagnostics never inspect a URL,
    /// header, body, response data or an error's description.
    enum DraftStage: String, Sendable { case create, poll, accept, cancel, shown }

    private static let successObserver = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

    static func observeSuccessfulResponses(_ observer: (@Sendable () -> Void)?) {
        successObserver.withLock { $0 = observer }
    }

    private static let transportLog = Logger(subsystem: "co.intention.mac", category: "native")

    let endpoint: URL
    private let session: URLSession

    init(endpoint: URL, session: URLSession? = nil) throws {
        guard BackendAddress.isAlpha(endpoint) else { throw Failure.insecureEndpoint }
        self.endpoint = endpoint
        self.session = session ?? URLSession(
            configuration: .ephemeral, delegate: RefuseRedirects(), delegateQueue: nil
        )
    }

    func signIn(inviteCode: String) async throws -> Registration {
        var request = URLRequest(url: endpoint.appending(path: "v1/invites/redeem"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["invite_code": inviteCode])
        return try await send(request)
    }

    func identity(deviceKey: String) async throws -> Identity {
        var request = URLRequest(url: endpoint.appending(path: "v1/me"))
        request.setValue("Bearer \(deviceKey)", forHTTPHeaderField: "Authorization")
        return try await send(request)
    }

    /// Permission for this device's account to dictate, which the speech
    /// endpoint checks. It needs no mailbox.
    struct SpeechGrant: Decodable, Sendable {
        let grant: String
        /// Seconds the grant lasts from when the backend signed it.
        let expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case grant
            case expiresIn = "expires_in"
        }
    }

    func speechGrant(deviceKey: String) async throws -> SpeechGrant {
        var request = URLRequest(url: endpoint.appending(path: "v1/speech/grants"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(deviceKey)", forHTTPHeaderField: "Authorization")
        let issued: SpeechGrant = try await send(request)
        guard (1...900).contains(issued.expiresIn), (1...2048).contains(issued.grant.utf8.count),
              issued.grant.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else {
            throw Failure.invalidResponse
        }
        return issued
    }

    struct VocabularyReply: Decodable, Sendable {
        let version: Int
        let names: [String]
        let terms: [String]
        let expiresIn: Int
        enum CodingKeys: String, CodingKey {
            case version, names, terms
            case expiresIn = "expires_in"
        }

        var isValid: Bool {
            guard version == 1, expiresIn == 1, names.count <= 32, terms.count <= 32,
                  (names + terms).reduce(0, { $0 + $1.utf8.count }) <= 2048 else { return false }
            guard Set(names.map { $0.lowercased() }).count == names.count,
                  Set(terms.map { $0.lowercased() }).count == terms.count else { return false }
            return (names + terms).allSatisfy { value in
                value == value.precomposedStringWithCompatibilityMapping &&
                value == value.split(separator: " ").joined(separator: " ") &&
                value.count >= 1 && value.count <= 64 && value.split(separator: " ").count <= 3 &&
                value.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) &&
                !value.lowercased().split(whereSeparator: { " -'’".contains($0) }).contains(where: {
                    ["ignore", "instructions", "system", "assistant", "developer", "execute", "prompt", "password", "secret", "override"].contains(String($0))
                }) &&
                value.unicodeScalars.allSatisfy {
                    CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0) ||
                    " '-’".unicodeScalars.contains($0)
                }
            }
        }
    }

    /// Only the bounded vocabulary for a fresh speech connection, never mailbox text.
    func vocabulary(deviceKey: String, register: String, before: String?) async throws -> VocabularyReply {
        struct Query: Encodable { let register: String; let before: String? }
        var request = URLRequest(url: endpoint.appending(path: "v1/speech/vocabulary"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(deviceKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // AX apps can return more text than the requested range. Bound the
        // actual request, keeping complete scalars at the UTF-16 suffix edge.
        let boundedBefore = before.map { value in
            var units = 0, kept: [Unicode.Scalar] = []
            for scalar in value.unicodeScalars.reversed() {
                let width = scalar.value > 0xFFFF ? 2 : 1
                guard units + width <= 64 else { break }
                kept.append(scalar)
                units += width
            }
            return String(String.UnicodeScalarView(kept.reversed()))
        }
        request.httpBody = try JSONEncoder().encode(Query(register: register, before: boundedBefore))
        let reply: VocabularyReply = try await send(request)
        guard reply.isValid else { throw Failure.invalidResponse }
        return reply
    }

    /// Only demo functions may leave the app. Archive, diagnostics and mailbox
    /// mutation stay blocked even if an older caller constructs a request.
    static func isDemoRequest(_ request: URLRequest, endpoint: URL) -> Bool {
        guard let url = request.url, url.scheme == endpoint.scheme, url.host == endpoint.host,
              url.port == endpoint.port, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return false }
        let method = request.httpMethod ?? "GET"
        switch (method, url.path) {
        case ("POST", "/v1/invites/redeem"), ("GET", "/v1/me"),
             ("POST", "/v1/speech/grants"), ("POST", "/v1/speech/vocabulary"),
             ("GET", "/v1/mail/connections"), ("GET", "/v1/setup/reply-thread"),
             ("POST", "/v1/writing/drafts"):
            return true
        default:
            let pieces = url.path.split(separator: "/")
            guard pieces.count == 4 || pieces.count == 5,
                  pieces[0] == "v1", pieces[1] == "writing", pieces[2] == "drafts",
                  UUID(uuidString: String(pieces[3])) != nil else { return false }
            if pieces.count == 4 { return method == "GET" || method == "DELETE" }
            return method == "POST" && ["accept", "shown"].contains(pieces[4])
        }
    }

    func send<Value: Decodable>(_ request: URLRequest) async throws -> Value {
        let (data, response) = try await perform(request)
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 429 {
                throw Failure.tooManyRequests(retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
            }
            throw Failure.rejected(response.statusCode)
        }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    /// One request over the alpha transport with the client's rules: no
    /// cache, a 30-second limit and no redirect, whatever session the
    /// caller supplied. Routes whose error bodies carry a code read them
    /// from here.
    func perform(_ request: URLRequest, draftStage: DraftStage? = nil, timeout: TimeInterval = 30) async throws -> (Data, HTTPURLResponse) {
        guard Self.isDemoRequest(request, endpoint: endpoint) else { throw Failure.insecureEndpoint }
        let trace = DraftAttempt.current
        let attempt = trace?.number ?? 0
        var request = request
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = timeout
        do {
            if let draftStage { trace?.log("transport.\(draftStage.rawValue).started") }
            let (data, response) = try await session.data(for: request, delegate: RefuseRedirects(draftStage: draftStage, trace: trace))
            if let draftStage { trace?.log("transport.\(draftStage.rawValue).returned", returned: true) }
            guard let response = response as? HTTPURLResponse else { throw Failure.invalidResponse }
            // Identity cannot wake its own retry when a 200 response fails decoding.
            if (200..<300).contains(response.statusCode), request.url?.path != endpoint.appending(path: "v1/me").path {
                Self.successObserver.withLock { $0 }?()
            }
            return (data, response)
        } catch {
            if let draftStage {
                let stage = draftStage.rawValue
                // Zero means a non-URL error. Never log descriptions or userInfo,
                // which may hold the credential-bearing request or its contents.
                let code = (error as? URLError)?.errorCode ?? 0
                let cancelled = trace?.isCancelled ?? false
                trace?.log("transport.\(stage).failed", returned: true)
                Self.transportLog.notice("compose transport.\(stage, privacy: .public) attempt=\(attempt, privacy: .public) cancelled=\(cancelled, privacy: .public) url_error=\(code, privacy: .public)")
            }
            throw error
        }
    }
}

extension AlphaClient {
    /// The backend this build names in `INTENTION_PROXY_URL`, or nil when that
    /// is unset or not HTTPS, which leaves sign-in off.
    static func configured(in bundle: Bundle = .main) -> AlphaClient? {
        guard let address = bundle.object(forInfoDictionaryKey: "IntentionProxyURL") as? String,
              let endpoint = URL(string: address) else { return nil }
        return try? AlphaClient(endpoint: endpoint)
    }
}

/// Redirects cannot carry a device credential to a changed host or an insecure URL.
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    private let draftStage: AlphaClient.DraftStage?
    private let trace: DraftAttempt?
    private static let log = Logger(subsystem: "co.intention.mac", category: "native")

    init(draftStage: AlphaClient.DraftStage? = nil, trace: DraftAttempt? = nil) {
        self.draftStage = draftStage
        self.trace = trace
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let draftStage else { return }
        let stage = draftStage.rawValue
        let attempt = trace?.number ?? 0
        let cancelled = trace?.isCancelled ?? false
        let total = metrics.taskInterval.duration * 1000
        let transactions = metrics.transactionMetrics.count
        Self.log.notice("compose transport.\(stage, privacy: .public) attempt=\(attempt, privacy: .public) cancelled=\(cancelled, privacy: .public) total_ms=\(total, privacy: .public) transactions=\(transactions, privacy: .public)")
        for transaction in metrics.transactionMetrics {
            func ms(_ start: Date?, _ end: Date?) -> Double {
                guard let start, let end else { return -1 }
                return end.timeIntervalSince(start) * 1000
            }
            let queue = ms(metrics.taskInterval.start, transaction.fetchStartDate)
            let dns = ms(transaction.domainLookupStartDate, transaction.domainLookupEndDate)
            let connect = ms(transaction.connectStartDate, transaction.connectEndDate)
            let tls = ms(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate)
            let request = ms(transaction.requestStartDate, transaction.requestEndDate)
            let firstByte = ms(transaction.requestEndDate, transaction.responseStartDate)
            let body = ms(transaction.responseStartDate, transaction.responseEndDate)
            let reused = transaction.isReusedConnection
            Self.log.notice("compose transport.\(stage, privacy: .public) attempt=\(attempt, privacy: .public) cancelled=\(cancelled, privacy: .public) queue_ms=\(queue, privacy: .public) dns_ms=\(dns, privacy: .public) connect_ms=\(connect, privacy: .public) tls_ms=\(tls, privacy: .public) request_ms=\(request, privacy: .public) first_byte_ms=\(firstByte, privacy: .public) body_ms=\(body, privacy: .public) reused=\(reused, privacy: .public)")
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// The addresses a build may name for its backends. `scripts/mac-build.sh`
/// runs this file too, so a release is refused for exactly the addresses the
/// app would not use. It lives here so the client still compiles on its own,
/// as CI and the acceptance probes compile it.
enum BackendAddress {
    private static func isLoopback(_ url: URL) -> Bool {
        ["localhost", "127.0.0.1"].contains(url.host?.lowercased() ?? "")
            && url.port.map { (1...65535).contains($0) } == true
    }

    static func isAlpha(_ url: URL) -> Bool {
        guard url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { return false }
        return url.scheme == "https" || (url.scheme == "http" && isLoopback(url))
    }

    static func isSpeech(_ url: URL) -> Bool {
        guard url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path == "/speech" else { return false }
        return url.scheme == "wss" || (url.scheme == "ws" && isLoopback(url))
    }

    static func isReleasedSpeech(_ url: URL) -> Bool { isSpeech(url) }
}
