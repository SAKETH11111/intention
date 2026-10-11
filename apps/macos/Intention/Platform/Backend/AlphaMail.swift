import Foundation

extension AlphaClient {
    enum MailProvider: String, Sendable, Decodable, CaseIterable {
        case gmail, outlook

        fileprivate var authorizationHost: String {
            self == .gmail ? "accounts.google.com" : "login.microsoftonline.com"
        }

        fileprivate var authorizationPath: String {
            self == .gmail ? "/o/oauth2/v2/auth" : "/common/oauth2/v2.0/authorize"
        }
    }

    enum MailFailure: Error {
        case invalidConsent, denied, cancelled, couldNotOpen, timedOut, busy
    }

    struct MailConnection: Decodable, Sendable, Equatable, Identifiable {
        let id: UUID
        let provider: String
        let address: String
        let state: String
        let backfillDone: Bool
        let storedMessages: Int
        let blockedMessages: Int
        let reconciling: Bool
        let lastSyncedAt: String?
        let errorCode: String?
        let connectedAt: String
        /// Whether the server holds enough of the person's sent mail to
        /// write in their voice. It can turn true while the import runs and
        /// back to false while a reconnect or a guard holds the mail; an
        /// older server leaves it out, which means not known.
        var voiceReady: Bool? = nil
        var voiceExamples: Int? = nil
        var sentRead: Int? = nil
        var sentTotal: Int? = nil

        enum CodingKeys: String, CodingKey {
            case id, provider, address, state, reconciling
            case voiceReady = "voice_ready"
            case voiceExamples = "voice_examples"
            case sentRead = "sent_read"
            case sentTotal = "sent_total"
            case backfillDone = "backfill_done"
            case storedMessages = "stored_messages"
            case blockedMessages = "blocked_messages"
            case lastSyncedAt = "last_synced_at"
            case errorCode = "error_code"
            case connectedAt = "connected_at"
        }
    }

    /// Created only by an authenticated Connect request. Keep it in memory for one
    /// local authentication session; callbacks from ordinary URL handlers are refused.
    struct MailFlow: Sendable {
        let provider: MailProvider
        let authorizationURL: URL
        private let state: String

        fileprivate init(provider: MailProvider, authorizationURL: URL) throws {
            guard let parts = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false),
                  parts.scheme == "https", parts.host == provider.authorizationHost,
                  parts.path == provider.authorizationPath,
                  parts.port == nil || parts.port == 443,
                  parts.user == nil, parts.password == nil, parts.fragment == nil,
                  let items = parts.queryItems,
                  items.filter({ $0.name == "state" }).count == 1,
                  let state = items.first(where: { $0.name == "state" })?.value,
                  (20...128).contains(state.count) else { throw MailFailure.invalidConsent }
            self.provider = provider
            self.authorizationURL = authorizationURL
            self.state = state
        }

        func completionCode(from callback: URL) throws -> String {
            guard let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false),
                  parts.scheme == "intention-mail", parts.host == "oauth",
                  parts.path == "/\(provider.rawValue)", parts.port == nil,
                  parts.user == nil, parts.password == nil, parts.fragment == nil,
                  let items = parts.queryItems,
                  items.count == 2,
                  items.filter({ $0.name == "state" }).count == 1,
                  items.first(where: { $0.name == "state" })?.value == state else {
                throw MailFailure.invalidConsent
            }
            if items.filter({ $0.name == "error" && $0.value == "denied" }).count == 1 {
                throw MailFailure.denied
            }
            guard items.filter({ $0.name == "code" }).count == 1,
                  let code = items.first(where: { $0.name == "code" })?.value,
                  (1...8192).contains(code.count) else { throw MailFailure.invalidConsent }
            return code
        }

        fileprivate func payload(callback: URL) throws -> [String: String] {
            ["state": state, "code": try completionCode(from: callback)]
        }
    }

    func beginMail(provider: MailProvider, deviceKey: String) async throws -> MailFlow {
        throw MailFailure.couldNotOpen
    }

    /// Called exclusively with the active authentication session's returned URL.
    func completeMail(flow: MailFlow, callback: URL, deviceKey: String) async throws -> UUID {
        throw MailFailure.couldNotOpen
    }

    struct MailLearning: Decodable, Sendable, Equatable {
        enum Stage: String, Codable, Sendable { case reading, learning, ready }
        let stage: Stage
        let percent: Int?
        var sentRead: Int? = nil
        var sentTotal: Int? = nil
        var connectionID: UUID? = nil

        enum CodingKeys: String, CodingKey {
            case stage, percent
            case sentRead = "sent_read", sentTotal = "sent_total", connectionID = "connection_id"
        }
    }

    struct MailProgress: Decodable, Sendable {
        let connections: [MailConnection]
        let availableProviders: [MailProvider]
        let learning: MailLearning?
        let gmailConnectOpen: Bool

        enum CodingKeys: String, CodingKey {
            case connections, learning
            case availableProviders = "available_providers"
            case gmailConnectOpen = "gmail_connect_open"
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            connections = try fields.decode([MailConnection].self, forKey: .connections)
            learning = try fields.decodeIfPresent(MailLearning.self, forKey: .learning)
            gmailConnectOpen = try fields.decodeIfPresent(Bool.self, forKey: .gmailConnectOpen) ?? true
            // Older servers offered both rows even when only Gmail was configured.
            // Ignore future provider names and keep the known rows in their usual order.
            let names = try fields.decodeIfPresent([String].self, forKey: .availableProviders) ?? ["gmail"]
            availableProviders = MailProvider.allCases.filter { names.contains($0.rawValue) }
        }
    }

    func mailConnections(deviceKey: String) async throws -> MailProgress {
        var request = URLRequest(url: endpoint.appending(path: "v1/mail/connections"))
        request.setValue("Bearer \(deviceKey)", forHTTPHeaderField: "Authorization")
        return try await send(request)
    }

    func disconnectMail(connectionID: UUID, deviceKey: String) async throws {
        throw MailFailure.couldNotOpen
    }

    private func mailRequest(provider: MailProvider, operation: String, deviceKey: String) -> URLRequest {
        var request = URLRequest(url: endpoint.appending(path: "v1/mail/\(provider.rawValue)/\(operation)"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(deviceKey)", forHTTPHeaderField: "Authorization")
        return request
    }
}
