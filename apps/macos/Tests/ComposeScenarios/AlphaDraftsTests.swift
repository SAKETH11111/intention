import AppKit
@testable import Compose
import Testing

/// The draft route's HTTP as `AlphaClient` speaks it, against a transport
/// answered inside the process: the requests it sends, the receipts it
/// reads and the failure each error code becomes.
@MainActor
@Suite(.serialized)
struct AlphaDraftsTests {
    private let key = "synthetic-device-key"

    private func service(key: String? = "synthetic-device-key", refused: @escaping @Sendable @MainActor (String) -> Void = { _ in }) -> AlphaDraftService {
        AlphaDraftService(client: DraftStub.client(), key: { key }, keyRefused: refused)
    }

    private func input() throws -> WritingInput {
        try ComposeInput.make(EmailBody(bundleIdentifier: nil, body: "Hi"), cue: "Say yes", requestID: UUID())
    }

    @Test func transportBoundariesCarryTheWritersAttemptCounterWithoutContent() async {
        let capture = LoggedLines()
        DraftStub.reset([.init(status: 503, json: #"{"detail":"writing_disabled"}"#),
                         .init(status: 404, json: #"{"detail":"draft_missing"}"#)])
        let writer = EmailWriter(drafts: service(), signedIn: true)
        await AppLog.$composeLines.withValue(capture) {
            #expect(await writer.write(cue: "Say yes", body: EmailBody(bundleIdentifier: nil, body: "Hi")) == .failure(.unavailable(.disabled)))
            for _ in 0..<1000 {
                if capture.all.contains(where: { $0.hasPrefix("request.cancel.failed") }) { break }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        let lines = capture.all
        let attempt = lines.first?.split(separator: " ").last.map(String.init) ?? "missing"
        #expect(attempt.hasPrefix("attempt="))
        #expect(lines.contains("transport.create.started \(attempt)"))
        #expect(lines.contains("transport.create.returned \(attempt)"))
        #expect(lines.contains("transport.cancel.started \(attempt)"))
        #expect(lines.contains("request.cancel.failed \(attempt)"))
        #expect(lines.allSatisfy { $0.hasSuffix(attempt) })
        #expect(lines.allSatisfy { !$0.contains("Say yes") && !$0.contains("Hi") && !$0.contains(key) && !$0.contains("service.invalid") })
    }

    @Test func createSendsTheInputBytesWithTheKeyAndReadsAPendingReceipt() async throws {
        let input = try input()
        DraftStub.reset([.init(status: 202, json: Receipt.json(input.requestID, status: "pending"))])
        let receipt = try await service().create(input)
        #expect(receipt.status == .pending)
        #expect(receipt.requestID == input.requestID)
        #expect(receipt.text == nil)
        #expect(!receipt.isTerminal)
        let seen = try #require(DraftStub.seen.first)
        #expect(seen.method == "POST")
        #expect(seen.path == "/v1/writing/drafts")
        #expect(seen.authorization == "Bearer \(key)")
        #expect(seen.body == (try input.encoded()))
    }

    @Test func readCancelAndAcceptUseTheRoutesPaths() async throws {
        let id = UUID()
        DraftStub.reset([
            .init(json: Receipt.json(id, status: "complete", text: "Hi.")),
            .init(json: Receipt.json(id, status: "cancelled", reason: "cancelled")),
            .init(json: Receipt.json(id, status: "complete", text: "Hi.", accepted: true)),
        ])
        let service = service()
        let read = try await service.read(id)
        #expect(read.status == .complete)
        #expect(read.text == "Hi.")
        #expect(read.identity.candidate == "retrieval-examples-v1")
        let cancelled = try await service.cancel(id)
        #expect(cancelled.status == .cancelled)
        #expect(cancelled.reason == .cancelled)
        let accepted = try await service.accept(id, revision: 1)
        #expect(accepted.accepted)
        let path = "/v1/writing/drafts/\(id.uuidString.lowercased())"
        #expect(DraftStub.seen.map(\.method) == ["GET", "DELETE", "POST"])
        #expect(DraftStub.seen.map(\.path) == [path, path, path + "/accept"])
        #expect(String(decoding: DraftStub.seen[2].body, as: UTF8.self) == #"{"revision":1}"#)
    }

    @Test func aShowingPostsItsRevisionAndTakesNoContent() async throws {
        let id = UUID()
        DraftStub.reset([
            .init(status: 204, json: ""),
            .init(status: 409, json: #"{"detail":"proposal_limit"}"#),
            .init(status: 409, json: #"{"detail":"draft_conflict"}"#),
        ])
        let service = service()
        try await service.shown(id, revision: 1)
        await #expect(throws: DraftRequestFailure.proposalLimit) { try await service.shown(id, revision: 1) }
        await #expect(throws: DraftRequestFailure.conflict) { try await service.shown(id, revision: 2) }
        let path = "/v1/writing/drafts/\(id.uuidString.lowercased())/shown"
        #expect(DraftStub.seen.map(\.method) == ["POST", "POST", "POST"])
        #expect(DraftStub.seen.map(\.path) == [path, path, path])
        #expect(DraftStub.seen.map(\.authorization) == ["Bearer \(key)", "Bearer \(key)", "Bearer \(key)"])
        #expect(String(decoding: DraftStub.seen[0].body, as: UTF8.self) == #"{"revision":1}"#)
        #expect(String(decoding: DraftStub.seen[2].body, as: UTF8.self) == #"{"revision":2}"#)
    }

    @Test func participantAdmissionSendsToAndCcAndMapsARefusal() async throws {
        let id = UUID()
        DraftStub.reset([.init(status: 409, json: #"{"detail":"recipients_outside_thread"}"#)])
        let recipients = [WritingRecipient(address: "priya@example.com", role: .to),
                          WritingRecipient(address: "tomas@example.com", role: .cc)]
        await #expect(throws: DraftRequestFailure.recipientsOutsideThread) {
            try await service().shown(id, revision: 1, recipients: recipients)
        }
        let request = try #require(DraftStub.seen.first)
        struct Body: Decodable { let revision: Int; let recipients: [WritingRecipient] }
        let body = try JSONDecoder().decode(Body.self, from: request.body)
        #expect(body.revision == 1)
        #expect(body.recipients == recipients)
        #expect(DraftStub.seen.count == 1)
    }

    @Test func receiptsDecodeVoiceEvidenceAndLegacyAbsence() throws {
        let old = Receipt.json(UUID(), status: "complete", text: "Synthetic draft.")
        #expect(try JSONDecoder().decode(DraftReceipt.self, from: Data(old.utf8)).voiceExamples == 0)
        for count in [0, 4, 20] {
            let json = old.replacingOccurrences(of: "\"request_id\":", with: "\"voice_examples\":\(count),\"request_id\":")
            #expect(try JSONDecoder().decode(DraftReceipt.self, from: Data(json.utf8)).voiceExamples == count)
        }
        for count in ["-1", "21", "4.5", "true", "\"4\""] {
            let json = old.replacingOccurrences(of: "\"request_id\":", with: "\"voice_examples\":\(count),\"request_id\":")
            #expect(throws: (any Error).self) { try JSONDecoder().decode(DraftReceipt.self, from: Data(json.utf8)) }
        }
    }

    @Test func receiptsDecodeTheParticipantCapabilityAndItsAbsence() async throws {
        let id = UUID()
        let old = Receipt.json(id, status: "complete", text: "Hi.")
        let capable = old.replacingOccurrences(of: "\"request_id\":", with: "\"shown_recipient_check\":\"thread_participants_v1\",\"request_id\":")
        DraftStub.reset([.init(json: old), .init(json: capable)])
        let route = service()
        #expect(try await route.read(id).shownRecipientCheck == nil)
        #expect(try await route.read(id).shownRecipientCheck == "thread_participants_v1")
    }

    /// Only 204 admits a card: a 200 or a 202, with a body or none, is a
    /// response the route never promised and shows nothing.
    @Test(arguments: [(200, "{}"), (202, ""), (200, "")])
    func aShowingTakesOnlyNoContent(status: Int, json: String) async throws {
        DraftStub.reset([.init(status: status, json: json)])
        await #expect(throws: DraftRequestFailure.invalidResponse) { try await service().shown(UUID(), revision: 1) }
        #expect(DraftStub.seen.count == 1)
    }

    @Test(arguments: [
        (404, "draft_missing", DraftRequestFailure.missing),
        (409, "draft_conflict", .conflict),
        (413, "body_too_large", .tooLarge),
        (422, "invalid_writing_input", .invalidInput),
        (422, "invalid_request", .invalidInput),
        (422, "writing_excluded", .excluded),
        (503, "writing_disabled", .disabled),
        (503, "writing_not_configured", .notConfigured),
        (503, "mail_policy_unconfigured", .mailPolicyUnconfigured),
        (503, "storage_unavailable", .storageUnavailable),
        (500, "whatever", .server(500)),
    ])
    func eachErrorCodeBecomesItsFailure(status: Int, code: String, failure: DraftRequestFailure) async throws {
        DraftStub.reset([.init(status: status, json: "{\"detail\":\"\(code)\"}")])
        await #expect(throws: failure) { try await service().read(UUID()) }
    }

    @Test func busyCarriesItsRetryAfter() async throws {
        DraftStub.reset([.init(status: 429, json: #"{"detail":"writing_busy"}"#, headers: ["Retry-After": "1"])])
        await #expect(throws: DraftRequestFailure.busy(retryAfter: 1)) { try await service().create(try input()) }
    }

    @Test func permanentStatesAreTheThreeServerOnes() {
        #expect(DraftRequestFailure.disabled.isPermanent)
        #expect(DraftRequestFailure.notConfigured.isPermanent)
        #expect(DraftRequestFailure.mailPolicyUnconfigured.isPermanent)
        #expect(!DraftRequestFailure.storageUnavailable.isPermanent)
        #expect(!DraftRequestFailure.invalidInput.isRetryable)
        #expect(!DraftRequestFailure.conflict.isRetryable)
        #expect(DraftRequestFailure.unreachable.isRetryable)
    }

    @Test func aRefusedKeyIsReportedOnlyWhenTheCallerSaysSo() async throws {
        #expect(AlphaClient.draftFailure(status: 401, body: Data(#"{"detail":"unauthorized"}"#.utf8), retryAfter: nil) == .unauthorized)
        DraftStub.reset([.init(status: 401, json: #"{"detail":"unauthorized"}"#)])
        let refused = Refused()
        let error = await #expect(throws: RefusedKey.self) {
            try await service(refused: { refused.keys.append($0) }).read(UUID())
        }
        // The route itself signs nothing out; the report does, with the key
        // the server refused.
        #expect(refused.keys.isEmpty)
        error?.report()
        #expect(refused.keys == [key])
    }

    // A refused key through the writer, by the production route's own
    // callback: it signs the Mac out only for the attempt still running,
    // under the account it was made for.

    @Test func aKeyRefusedDuringTheAttemptSignsTheMacOut() async throws {
        DraftStub.reset([.init(status: 401, json: #"{"detail":"unauthorized"}"#)])
        let refused = Refused()
        let writer = EmailWriter(drafts: service(refused: { refused.keys.append($0) }), signedIn: true,
                                 pollInterval: .milliseconds(5), requestLimit: .seconds(5))
        #expect(await writer.write(cue: "Say yes", body: EmailBody(bundleIdentifier: nil, body: "Hi")) == .failure(.signedOut))
        // The request is cancelled after, and that cancel's own refusal
        // reports nothing more. Waited for, so it reaches this test's stub.
        await spin { DraftStub.seen.count == 2 }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(refused.keys == [key])
        #expect(writer.availability == .signedOut)
    }

    @Test func aKeyRefusedAfterTheLimitLeavesTheMacSignedIn() async throws {
        // The 401 comes back after the limit passed, and the timer marking
        // it runs late.
        DraftStub.reset([.init(status: 401, json: #"{"detail":"unauthorized"}"#, delay: .milliseconds(80)),
                         .init(status: 401, json: #"{"detail":"unauthorized"}"#)])
        let refused = Refused()
        let clock = SteppedClock()
        let writer = EmailWriter(drafts: service(refused: { refused.keys.append($0) }), signedIn: true,
                                 pollInterval: .milliseconds(5), requestLimit: .milliseconds(60), clock: clock)
        let writing = Task { await writer.write(cue: "Say yes", body: EmailBody(bundleIdentifier: nil, body: "Hi")) }
        await spin { !DraftStub.seen.isEmpty }
        clock.jump(to: .milliseconds(60))
        #expect(await writing.value == .failure(.timedOut))
        // The cancel that withdrew it is refused too; neither signs out.
        await spin { DraftStub.seen.count == 2 }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(refused.keys.isEmpty)
        #expect(writer.availability == nil)
    }

    @Test func aKeyRefusedAfterTheAccountChangedLeavesTheNewAccountAlone() async throws {
        DraftStub.reset([.init(status: 401, json: #"{"detail":"unauthorized"}"#, delay: .milliseconds(80)),
                         .init(json: Receipt.json(UUID(), status: "cancelled", reason: "cancelled"))])
        let refused = Refused()
        let writer = EmailWriter(drafts: service(refused: { refused.keys.append($0) }), signedIn: true,
                                 pollInterval: .milliseconds(5), requestLimit: .seconds(5))
        let writing = Task { await writer.write(cue: "Say yes", body: EmailBody(bundleIdentifier: nil, body: "Hi")) }
        await spin { !DraftStub.seen.isEmpty }
        writer.accountChanged(signedIn: true)
        #expect(await writing.value == .failure(.withdrawn))
        await spin { DraftStub.seen.count == 2 }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(refused.keys.isEmpty)
        #expect(writer.availability == nil)
    }

    // A request is cancelled with the key that made it, whatever account
    // this Mac is under by the time the cancel goes out.

    @Test func aCancelAfterTheAccountChangedGoesWithTheKeyThatMadeTheRequest() async throws {
        DraftStub.reset([.init(status: 202, json: Receipt.json(UUID(), status: "pending"), delay: .milliseconds(80)),
                         .init(json: Receipt.json(UUID(), status: "cancelled", reason: "cancelled"))])
        let account = Account(key)
        let writer = EmailWriter(drafts: AlphaDraftService(client: DraftStub.client(), key: { account.key }, keyRefused: { _ in }),
                                 signedIn: true, pollInterval: .milliseconds(5), requestLimit: .seconds(5))
        let writing = Task { await writer.write(cue: "Say yes", body: EmailBody(bundleIdentifier: nil, body: "Hi")) }
        await spin { !DraftStub.seen.isEmpty }
        account.key = "another-device-key"
        writer.accountChanged(signedIn: true)
        #expect(await writing.value == .failure(.withdrawn))
        await spin { DraftStub.seen.count == 2 }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(DraftStub.seen.map(\.method) == ["POST", "DELETE"])
        #expect(DraftStub.seen.map(\.authorization) == ["Bearer \(key)", "Bearer \(key)"])
    }

    @Test func aRouteHeldToAnAccountSendsItsKeyAfterTheChangeOnlyToCancel() async throws {
        let id = UUID()
        DraftStub.reset([.init(json: Receipt.json(id, status: "cancelled", reason: "cancelled"))])
        let account = Account(key)
        let held = try await AlphaDraftService(client: DraftStub.client(), key: { account.key }, keyRefused: { _ in })
            .forThisAccount()
        account.key = "another-device-key"
        await #expect(throws: DraftRequestFailure.signedOut) { try await held.read(id) }
        await #expect(throws: DraftRequestFailure.signedOut) { try await held.accept(id, revision: 1) }
        #expect(DraftStub.seen.isEmpty)
        _ = try await held.cancel(id)
        #expect(DraftStub.seen.map(\.method) == ["DELETE"])
        #expect(DraftStub.seen.map(\.authorization) == ["Bearer \(key)"])
    }

    @Test(arguments: ["another-device-key", nil] as [String?])
    func aFailedRequestIsCancelledWithItsOwnKeyAfterTheAccountChanged(next: String?) async throws {
        // The account changes between the failure and its cancel: once the
        // request has gone out, the key this Mac holds is the next account's.
        DraftStub.reset([.init(status: 500, json: #"{"detail":"whatever"}"#),
                         .init(status: 401, json: #"{"detail":"unauthorized"}"#)])
        let key = key
        let refused = Refused()
        let writer = EmailWriter(drafts: AlphaDraftService(client: DraftStub.client(), key: { DraftStub.seen.isEmpty ? key : next },
                                                           keyRefused: { refused.keys.append($0) }),
                                 signedIn: true, pollInterval: .milliseconds(5), requestLimit: .seconds(5))
        #expect(await writer.write(cue: "Say yes", body: EmailBody(bundleIdentifier: nil, body: "Hi"))
                == .failure(.request(.server(500))))
        await spin { DraftStub.seen.count == 2 }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(DraftStub.seen.map(\.method) == ["POST", "DELETE"])
        #expect(DraftStub.seen.map(\.authorization) == ["Bearer \(key)", "Bearer \(key)"])
        // The old key's refusal of its own cancel signs nobody out.
        #expect(refused.keys.isEmpty)
        #expect(writer.availability == nil)
    }

    private func spin(_ condition: @escaping () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(condition())
    }

    @Test func withoutAKeyNothingIsSent() async throws {
        DraftStub.reset([])
        await #expect(throws: DraftRequestFailure.signedOut) { try await service(key: nil).read(UUID()) }
        #expect(DraftStub.seen.isEmpty)
    }

    @Test func aLostConnectionIsUnreachable() async throws {
        DraftStub.reset([.init(failure: .networkConnectionLost)])
        await #expect(throws: DraftRequestFailure.unreachable) { try await service().read(UUID()) }
    }

    @Test func anAnswerThatIsNotAReceiptIsInvalid() async throws {
        DraftStub.reset([.init(json: #"{"ok":true}"#)])
        await #expect(throws: DraftRequestFailure.invalidResponse) { try await service().read(UUID()) }
        // Text on anything but a complete receipt is not a receipt either.
        DraftStub.reset([.init(json: Receipt.json(UUID(), status: "pending", text: "early"))])
        await #expect(throws: DraftRequestFailure.invalidResponse) { try await service().read(UUID()) }
    }

    /// The key this Mac holds, which a scenario changes as an account
    /// change would.
    @MainActor
    private final class Account {
        var key: String?

        init(_ key: String?) {
            self.key = key
        }
    }

    @MainActor
    private final class Refused {
        var keys: [String] = []
    }
}
