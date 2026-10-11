import Foundation

/// The alpha backend's draft route (the proxy draft contract):
/// create and regenerate, poll, cancel, accept and admit a proposal's card
/// before it shows. Every request carries the device key and nothing else
/// about the account. Errors come back as `{"detail":"code"}` and are
/// mapped to `DraftRequestFailure` here, so the compose flow never sees a
/// status code. No request here sends mail.
extension AlphaClient {
    func createDraft(_ input: WritingInput, deviceKey: String) async throws -> DraftReceipt {
        var request = draftRequest("v1/writing/drafts", deviceKey: deviceKey)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The input's own encoder keeps the bytes the schema bounds.
        request.httpBody = try input.encoded()
        return try await sendDraft(request, stage: .create)
    }

    func draft(_ requestID: UUID, deviceKey: String) async throws -> DraftReceipt {
        try await sendDraft(draftRequest("v1/writing/drafts/\(requestID.uuidString.lowercased())", deviceKey: deviceKey), stage: .poll)
    }

    func cancelDraft(_ requestID: UUID, deviceKey: String) async throws -> DraftReceipt {
        var request = draftRequest("v1/writing/drafts/\(requestID.uuidString.lowercased())", deviceKey: deviceKey)
        request.httpMethod = "DELETE"
        return try await sendDraft(request, stage: .cancel)
    }

    func acceptDraft(_ requestID: UUID, revision: Int, deviceKey: String) async throws -> DraftReceipt {
        var request = draftRequest("v1/writing/drafts/\(requestID.uuidString.lowercased())/accept", deviceKey: deviceKey)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["revision": revision])
        return try await sendDraft(request, stage: .accept)
    }

    /// Asks the server to admit a proposal's card before it first shows.
    /// Only 204 with no body admits it; another 2xx is `invalidResponse`,
    /// so nothing the route did not promise shows a card, and a failure is
    /// mapped as every draft call's is.
    func markDraftShown(_ requestID: UUID, revision: Int, recipients: [WritingRecipient], deviceKey: String) async throws {
        var request = draftRequest("v1/writing/drafts/\(requestID.uuidString.lowercased())/shown", deviceKey: deviceKey)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Admission: Encodable {
            let revision: Int
            let recipients: [WritingRecipient]?
        }
        request.httpBody = try JSONEncoder().encode(Admission(revision: revision, recipients: recipients.isEmpty ? nil : recipients))
        let response: HTTPURLResponse, data: Data
        do {
            (data, response) = try await perform(request, draftStage: .shown)
        } catch Failure.invalidResponse {
            throw DraftRequestFailure.invalidResponse
        } catch {
            throw DraftRequestFailure.unreachable
        }
        guard (200..<300).contains(response.statusCode) else {
            throw Self.draftFailure(status: response.statusCode, body: data,
                                    retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
        }
        guard response.statusCode == 204 else { throw DraftRequestFailure.invalidResponse }
    }

    private func draftRequest(_ path: String, deviceKey: String) -> URLRequest {
        var request = URLRequest(url: endpoint.appending(path: path))
        request.setValue("Bearer \(deviceKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func sendDraft(_ request: URLRequest, stage: DraftStage) async throws -> DraftReceipt {
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await perform(request, draftStage: stage)
        } catch Failure.invalidResponse {
            throw DraftRequestFailure.invalidResponse
        } catch {
            throw DraftRequestFailure.unreachable
        }
        guard (200..<300).contains(response.statusCode) else {
            throw Self.draftFailure(status: response.statusCode, body: data,
                                    retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
        }
        do {
            return try JSONDecoder().decode(DraftReceipt.self, from: data)
        } catch {
            throw DraftRequestFailure.invalidResponse
        }
    }

    /// The route's error codes, by status and the `detail` field. A code the
    /// client does not know falls back to the status alone.
    static func draftFailure(status: Int, body: Data, retryAfter: Int?) -> DraftRequestFailure {
        struct Detail: Decodable { let detail: String }
        let code = (try? JSONDecoder().decode(Detail.self, from: body))?.detail
        switch (status, code) {
        case (401, _): return .unauthorized
        case (404, _): return .missing
        case (409, "proposal_limit"): return .proposalLimit
        case (409, "recipients_outside_thread"): return .recipientsOutsideThread
        case (409, _): return .conflict
        case (413, _): return .tooLarge
        case (422, "writing_excluded"): return .excluded
        case (422, _): return .invalidInput
        case (429, _): return .busy(retryAfter: max(1, retryAfter ?? 1))
        case (503, "writing_disabled"): return .disabled
        case (503, "writing_not_configured"): return .notConfigured
        case (503, "mail_policy_unconfigured"): return .mailPolicyUnconfigured
        case (503, "storage_unavailable"): return .storageUnavailable
        default: return .server(status)
        }
    }
}

/// The draft route for the signed-in device. Each call reads the key as it
/// is now, so a Mac that signed out mid-request sends nothing more; held
/// to a request's account (`forThisAccount`), a call other than the cancel
/// is sent only while that key is still this Mac's, and the cancel always
/// goes with the key that made the request, the one place an earlier
/// account's key is sent. A key the server refuses comes back as
/// `RefusedKey`, whose report signs the Mac out the way the other backend
/// clients do; the writer reports it only while the request it belongs to
/// still counts, and never for a cancel.
struct AlphaDraftService: DraftService {
    private let client: AlphaClient
    private let key: @Sendable @MainActor () -> String?
    private let keyRefused: @Sendable @MainActor (String) -> Void
    /// The key the request was made with, once held to its account.
    private var requestKey: String?

    init(client: AlphaClient, key: @escaping @Sendable @MainActor () -> String?,
         keyRefused: @escaping @Sendable @MainActor (String) -> Void) {
        self.client = client
        self.key = key
        self.keyRefused = keyRefused
    }

    func forThisAccount() async throws -> any DraftService {
        guard let key = await key() else { throw DraftRequestFailure.signedOut }
        var held = self
        held.requestKey = key
        return held
    }

    func create(_ input: WritingInput) async throws -> DraftReceipt {
        try await send { try await client.createDraft(input, deviceKey: $0) }
    }

    func read(_ requestID: UUID) async throws -> DraftReceipt {
        try await send { try await client.draft(requestID, deviceKey: $0) }
    }

    func cancel(_ requestID: UUID) async throws -> DraftReceipt {
        try await send(cancelling: true) { try await client.cancelDraft(requestID, deviceKey: $0) }
    }

    func accept(_ requestID: UUID, revision: Int) async throws -> DraftReceipt {
        try await send { try await client.acceptDraft(requestID, revision: revision, deviceKey: $0) }
    }

    func shown(_ requestID: UUID, revision: Int, recipients: [WritingRecipient]) async throws {
        try await send { try await client.markDraftShown(requestID, revision: revision, recipients: recipients, deviceKey: $0) }
    }

    private func send<Answer>(cancelling: Bool = false, _ call: (String) async throws -> Answer) async throws -> Answer {
        let sent: String
        if let requestKey, cancelling {
            sent = requestKey
        } else {
            guard let current = await key(), requestKey == nil || current == requestKey else {
                throw DraftRequestFailure.signedOut
            }
            sent = current
        }
        do {
            return try await call(sent)
        } catch DraftRequestFailure.unauthorized {
            throw RefusedKey { [keyRefused] in keyRefused(sent) }
        }
    }
}
