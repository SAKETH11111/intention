import Foundation

/// Why a draft request ended without text, or why a finished one was taken
/// back. The closed list from the draft receipt contract;
/// a value the server adds later decodes as `unrecognized`, which the
/// app treats as final and says so.
enum DraftReason: String, Codable, Sendable, CaseIterable {
    case productionDisabled = "production_disabled"
    case invalidInput = "invalid_input"
    case inputTooLarge = "input_too_large"
    case bindingMismatch = "binding_mismatch"
    case ineligibleExample = "ineligible_example"
    case qualificationUnavailable = "qualification_unavailable"
    case eligibilityChanged = "eligibility_changed"
    case cancelled
    case excluded
    case transportUnknown = "transport_unknown"
    case invalidResponse = "invalid_response"
    case contextPreparing = "context_preparing"
    case mailImportPending = "mail_import_pending"
    case contextInvalidated = "context_invalidated"
    case timeout
    case costLimit = "cost_limit"
    case superseded
    /// A regeneration whose parent was accepted while it was on its way:
    /// the accepted text stands, and nothing new is shown.
    case parentAccepted = "parent_accepted"
    /// The parent is gone: cancelled, expired or purged before the child
    /// could bind to it.
    case parentUnavailable = "parent_unavailable"
    case configurationRetired = "configuration_retired"
    case expired
    case mailPolicyUnconfigured = "mail_policy_unconfigured"
    /// The words did not say what the email should say, and the writer
    /// returned nothing twice. They go in as they were.
    case intentionUnresolved = "intention_unresolved"
    /// A reply proposal the server did not write: the thread's newest
    /// message is the person's own or came from an automated sender.
    case nothingToAnswer = "nothing_to_answer"
    /// A reply proposal past the account's daily count of proposals.
    case proposalLimit = "proposal_limit"
    /// Not in the contract. Kept so a receipt with a new reason still
    /// decodes and is shown as a final failure, never retried.
    case unrecognized

    /// Worth one more attempt with a fresh request_id, which the person
    /// asks for; Intention never sends one by itself. The server was still
    /// importing mail or preparing context, had no qualification at hand,
    /// saw eligibility change under the request, ran out of time, lost
    /// track of its transport or could not read the answer. Everything
    /// else is final; another attempt with the same input would end the
    /// same way, so the app shows the reason and does not loop.
    var isRetryable: Bool {
        switch self {
        case .contextPreparing, .mailImportPending, .qualificationUnavailable, .eligibilityChanged, .timeout, .transportUnknown, .invalidResponse: true
        default: false
        }
    }
}

/// One draft request as the server reports it. Every successful answer of
/// the route has this shape, pending or finished. Only `complete` carries
/// text, and only an accepted complete receipt may be inserted.
struct DraftReceipt: Equatable, Sendable {
    enum Status: String, Codable, Sendable { case pending, complete, abstained, cancelled }

    struct Identity: Equatable, Sendable {
        let candidate: String
        let provider: String
        let model: String
        let modelRevision: String
        let adapter: String
        let configurationID: UUID
    }

    struct Cost: Equatable, Sendable {
        enum Status: String, Codable, Sendable { case notStarted = "not_started", reported, unknown }
        let status: Status
        let inputTokens: Int?
        let outputTokens: Int?
        let usd: String?
        let limitUSD: String
    }

    let requestID: UUID
    let revision: Int
    let status: Status
    let reason: DraftReason?
    let text: String?
    let accepted: Bool
    let identity: Identity
    let sources: [WritingSourceReference]
    let cost: Cost
    var voiceExamples: Int = 0
    var shownRecipientCheck: String? = nil

    var isTerminal: Bool { status != .pending }
}

extension DraftReceipt: Decodable {
    private enum CodingKeys: String, CodingKey {
        case requestID = "request_id", revision, status, reason, text, accepted, identity, sources, cost
        case voiceExamples = "voice_examples"
        case shownRecipientCheck = "shown_recipient_check"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try values.decode(UUID.self, forKey: .requestID)
        revision = try values.decode(Int.self, forKey: .revision)
        status = try values.decode(Status.self, forKey: .status)
        reason = try values.decodeIfPresent(String.self, forKey: .reason).map { DraftReason(rawValue: $0) ?? .unrecognized }
        text = try values.decodeIfPresent(String.self, forKey: .text)
        accepted = try values.decode(Bool.self, forKey: .accepted)
        identity = try values.decode(Identity.self, forKey: .identity)
        sources = try values.decode([WritingSourceReference].self, forKey: .sources)
        cost = try values.decode(Cost.self, forKey: .cost)
        voiceExamples = try values.decodeIfPresent(Int.self, forKey: .voiceExamples) ?? 0
        guard (0...20).contains(voiceExamples) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "invalid_voice_examples"))
        }
        shownRecipientCheck = try values.decodeIfPresent(String.self, forKey: .shownRecipientCheck)
        // The contract gives text with `complete` and nothing else.
        guard (status == .complete) == (text != nil) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "invalid_draft_receipt"))
        }
    }
}

extension DraftReceipt.Identity: Decodable {
    private enum CodingKeys: String, CodingKey {
        case candidate, provider, model, adapter
        case modelRevision = "model_revision"
        case configurationID = "configuration_id"
    }
}

extension DraftReceipt.Cost: Decodable {
    private enum CodingKeys: String, CodingKey {
        case status, usd
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case limitUSD = "limit_usd"
    }
}

/// How a request to the draft route failed, from the route's error codes.
/// Fixed names, safe to log.
enum DraftRequestFailure: Error, Equatable, Sendable {
    /// This Mac holds no device key.
    case signedOut
    /// 401: the server no longer accepts this Mac's key.
    case unauthorized
    /// 404: no such draft for this device, or it is gone.
    case missing
    /// 409: a reused request_id, a stale parent or revision, or acceptance
    /// of a draft that is not complete.
    case conflict
    /// 409 `proposal_limit` from the record of a proposal's first showing:
    /// the account has been shown its day's count of proposals.
    case proposalLimit
    /// The reply names someone outside the proposal thread. Ask from the reply instead.
    case recipientsOutsideThread
    /// 422 `invalid_writing_input` or `invalid_request`: Intention sent
    /// something the server does not accept. A bug in Intention, never retried.
    case invalidInput
    /// 422 `writing_excluded`: the input matched the server's exclusion policy.
    case excluded
    /// 413.
    case tooLarge
    /// 429 `writing_busy`, with the seconds to wait.
    case busy(retryAfter: Int)
    /// 503 `writing_disabled`.
    case disabled
    /// 503 `writing_not_configured`: no model adapter is installed.
    case notConfigured
    /// 503 `mail_policy_unconfigured`.
    case mailPolicyUnconfigured
    /// 503 `storage_unavailable`.
    case storageUnavailable
    /// The connection failed or timed out.
    case unreachable
    /// An answer Intention could not read.
    case invalidResponse
    /// Any other status.
    case server(Int)

    /// Writing is off until the server is configured differently. Nothing
    /// the person does from here changes it, so the app says so and does
    /// not ask again by itself.
    var isPermanent: Bool {
        switch self {
        case .disabled, .notConfigured, .mailPolicyUnconfigured: true
        default: false
        }
    }

    /// Worth asking again, by the person, with a fresh request_id.
    var isRetryable: Bool {
        switch self {
        case .unreachable, .storageUnavailable, .server, .invalidResponse: true
        case .busy: true
        default: false
        }
    }

    /// A failure that says nothing about the request, only that the server
    /// or the connection could not answer this once: a 503 other than the
    /// permanent ones, another 5xx, a 429 or a dropped connection. The
    /// writer makes the same poll, acceptance or cancel again after it,
    /// within the email's limit; it never makes a new request for one.
    var isTransient: Bool {
        switch self {
        case .storageUnavailable, .busy, .unreachable: true
        case let .server(status): (500..<600).contains(status)
        default: false
        }
    }

    /// The seconds the server asked to wait before the next call, when it
    /// said (`Retry-After`, on a 429).
    var retryAfter: Int? {
        if case let .busy(seconds) = self { seconds } else { nil }
    }

    var name: String {
        switch self {
        case .signedOut: "signedOut"
        case .unauthorized: "unauthorized"
        case .missing: "missing"
        case .conflict: "conflict"
        case .proposalLimit: "proposalLimit"
        case .recipientsOutsideThread: "recipientsOutsideThread"
        case .invalidInput: "invalidInput"
        case .excluded: "excluded"
        case .tooLarge: "tooLarge"
        case .busy: "busy"
        case .disabled: "disabled"
        case .notConfigured: "notConfigured"
        case .mailPolicyUnconfigured: "mailPolicyUnconfigured"
        case .storageUnavailable: "storageUnavailable"
        case .unreachable: "unreachable"
        case .invalidResponse: "invalidResponse"
        case let .server(status): "server.\(status)"
        }
    }
}

/// A 401 from the draft route, holding how to sign the Mac out for it. The
/// route does not sign out by itself: whether the refusal still says
/// anything about the account is the writer's to decide, and it reports
/// one only for the attempt still running, before its limit and under the
/// account it was made for.
struct RefusedKey: Error, Sendable {
    let report: @Sendable @MainActor () -> Void
}

/// The draft route as the compose flow uses it. The alpha backend adapter
/// speaks HTTP for it; tests script the answers. Every call fails with a
/// `DraftRequestFailure`, or with `RefusedKey` for a key the server
/// refused.
protocol DraftService: Sendable {
    /// The route held to the account signed in now, for one request's whole
    /// life: made, read and accepted under that account only while it is
    /// still this Mac's, and cancelled under it always, so a cancel after
    /// the account changed reaches the request it names instead of looking
    /// for it under the new account. Fails with `signedOut` when no account
    /// is signed in.
    func forThisAccount() async throws -> any DraftService
    /// `POST /v1/writing/drafts`. The receipt is pending, or terminal when
    /// the same request was already made.
    func create(_ input: WritingInput) async throws -> DraftReceipt
    /// `GET /v1/writing/drafts/{id}`.
    func read(_ requestID: UUID) async throws -> DraftReceipt
    /// `DELETE /v1/writing/drafts/{id}`. A finished or accepted draft comes
    /// back unchanged.
    func cancel(_ requestID: UUID) async throws -> DraftReceipt
    /// `POST /v1/writing/drafts/{id}/accept` with the revision.
    func accept(_ requestID: UUID, revision: Int) async throws -> DraftReceipt
    /// `POST /v1/writing/drafts/{id}/shown` with the revision and, when the
    /// receipt advertises it, the reply's To/Cc recipients, asked
    /// before the proposal's card first shows: the card may show only once
    /// the server answers 204 with no body. Past the account's day's count
    /// it throws `proposalLimit`; another 2xx throws `invalidResponse`.
    func shown(_ requestID: UUID, revision: Int, recipients: [WritingRecipient]) async throws
}

// Older call sites have no recipient claim to make.
extension DraftService {
    func shown(_ requestID: UUID, revision: Int) async throws {
        try await shown(requestID, revision: revision, recipients: [])
    }
}
