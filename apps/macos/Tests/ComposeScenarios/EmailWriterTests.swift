import AppKit
@testable import Compose
import Testing

/// One email from the person's words and the body, against the scripted
/// draft route: every receipt status and reason, each failure, the wait's
/// limit, acceptance, cancelling and signing out, and that nothing is ever
/// asked for twice by Intention itself.
@MainActor
@Suite(.serialized)
struct EmailWriterTests {
    private let body = EmailBody(bundleIdentifier: "com.apple.mail", body: "Hi,\n\nCould you make Thursday at 10?\n\nJane")
    private let words = "Say yes and ask for the agenda."

    private func writer(_ drafts: (any DraftService)?, signedIn: Bool = true, limit: Duration = .seconds(5)) -> EmailWriter {
        EmailWriter(drafts: drafts, signedIn: signedIn, pollInterval: .milliseconds(5), requestLimit: limit)
    }

    // The server decorates an accepted receipt after the undecorated proposal
    // was shown. This uses the real writer with only the HTTP answer scripted.
    @Test(arguments: ["", "\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-"])
    func anAcceptedProposalKeepsTheShownBodyAndItsServerFooter(suffix: String) async throws {
        let accepted = Receipt.text + suffix
        let drafts = ScriptedDrafts(accepts: [.from { id, revision in
            Receipt.complete(id, revision: revision, text: accepted, accepted: true)
        }])
        let writer = EmailWriter(drafts: drafts, signedIn: true, pollInterval: .milliseconds(5),
                                 addSentWithIntention: { true })
        let proposal = try #require(try? await writer.propose(body: body).get())
        #expect(proposal.text == Receipt.text)
        #expect(drafts.created.first?.compose.addSentWithIntention == true)
        #expect(await writer.recordAcceptance(proposal).value == .success(accepted))
    }

    @Test(arguments: [
        "Changed proposal body.",
        Receipt.text + "\n\nAnother sentence.",
        Receipt.text + "\n\nsent with intention https://elsewhere.example/?ref=AbCdEf0123_-",
        Receipt.text + "\n\nsent with intention https://intention.example/?ref=short",
        Receipt.text + "\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-\nMore text.",
    ])
    func anAcceptedProposalStillRefusesOtherTextChanges(accepted: String) async throws {
        let drafts = ScriptedDrafts(accepts: [.from { id, revision in
            Receipt.complete(id, revision: revision, text: accepted, accepted: true)
        }])
        let writer = EmailWriter(drafts: drafts, signedIn: true, pollInterval: .milliseconds(5),
                                 addSentWithIntention: { true })
        let proposal = try #require(try? await writer.propose(body: body).get())
        #expect(await writer.recordAcceptance(proposal).value == .failure(.request(.conflict)))
    }

    // Every accepted string is a literal oracle independent of the matcher.
    @Test(arguments: [
        ("Friday works.", "Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-"),
        ("Friday works.", "Friday works.\n\nSent with Intention https://intention.example/?ref=AbCdEf0123_-"),
        ("Friday works. ", "Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-"),
        ("Friday works.\t", "Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-"),
        ("Friday works.\n", "Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-"),
        ("Friday works.\r", "Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-"),
        ("Friday works.\u{000B}", "Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-"),
        ("Friday works.\u{000C}", "Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-"),
        ("Friday works. \t\r\n", "Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-"),
        ("Caf\u{00E9} and cafe\u{0301}.", "Caf\u{00E9} and cafe\u{0301}.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-"),
        (" Friday  works.\nNext line.", " Friday  works.\nNext line.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-"),
        ("Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-", "Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-"),
    ])
    func onlyTheTerminalServerDecorationMayDiffer(_ texts: (String, String)) async throws {
        let (shown, accepted) = texts
        let drafts = ScriptedDrafts(creates: [.from { Receipt.complete($0, revision: $1, text: shown) }],
                                    accepts: [.from { Receipt.complete($0, revision: $1, text: accepted, accepted: true) }])
        let writer = EmailWriter(drafts: drafts, signedIn: true, addSentWithIntention: { true })
        let proposal = try #require(try? await writer.propose(body: body).get())
        var recorded = 0
        writer.recordReceipt = { _, _, _, _ in recorded += 1 }
        let result = try #require(try? await writer.recordAcceptance(proposal).value.get())
        #expect(result.utf8.elementsEqual(accepted.utf8))
        #expect(proposal.text.utf8.elementsEqual(shown.utf8))
        #expect(recorded == 1)
    }

    @Test(arguments: [
        ("Friday works.", "Thursday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-"),
        ("Friday works.", "Friday works. Another sentence.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-"),
        ("Friday works.", "Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-\nAnother sentence."),
        ("Friday works.", "Friday works.\n\nsent with intention https://elsewhere.example/?ref=AbCdEf0123_-"),
        ("Friday works.", "Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_"),
        ("Friday works.", "Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-X"),
        ("Friday works.", "Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_."),
        ("Friday works.", "Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-&extra=1"),
        ("Friday works.", "Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-#fragment"),
        ("Friday works.", "Friday works.\n\nsent with intention http://intention.example/?ref=AbCdEf0123_-"),
        ("Friday works.", "Friday works.\n\nsent with intention https://intention.example/other?ref=AbCdEf0123_-"),
        ("Friday works.", "Friday works.\n\nsent with intention https://Intention.co/?ref=AbCdEf0123_-"),
        ("Friday works.", "Friday works.\n\nSent with intention https://intention.example/?ref=AbCdEf0123_-"),
        ("Friday works.", "Friday works.\n\nsent with intention  https://intention.example/?ref=AbCdEf0123_-"),
        ("Friday works.", "Friday works. sent with intention https://intention.example/?ref=AbCdEf0123_-"),
        ("Friday works.", "Friday works.\n\n> sent with intention https://intention.example/?ref=AbCdEf0123_-"),
        ("Friday works.", "Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-"),
        ("Friday works.", "Friday works.\nsent with intention https://intention.example/?ref=AbCdEf0123_-"),
        ("Friday works.", "Friday works.\n\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-"),
        ("Friday works.", "Friday works.\r\n\r\nsent with intention https://intention.example/?ref=AbCdEf0123_-"),
        ("Friday works.", "Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-\n"),
        ("Friday works.", "Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_- "),
        ("Friday works.", " Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-"),
        ("Friday works.", "Friday  works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-"),
        ("Friday works.", "Friday works. \n\nsent with intention https://intention.example/?ref=AbCdEf0123_-"),
        ("Caf\u{00E9} works.", "Cafe\u{0301} works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-"),
        ("Caf\u{00E9} works.", "Cafe\u{0301} works."),
        ("Friday works.", "Friday\u{200B} works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-"),
        ("Friday works.\u{00A0}", "Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-"),
        ("Friday works.\u{00A0}", "Friday works.\u{00A0}\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-"),
        ("Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-", "Friday works.\n\nsent with intention https://intention.example/?ref=ZYXwvut987_-"),
        ("Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-", "Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-\n\nsent with intention https://intention.example/?ref=ZYXwvut987_-"),
        ("Friday works.\n \t> > Sent with Intention https://intention.example/?ref=AbCdEf0123_- \t\r\nNext line.", "Friday works.\nNext line.\n\nsent with intention https://intention.example/?ref=ZYXwvut987_-"),
        ("Friday works.\n \t> > Sent with Intention https://intention.example/?ref=AbCdEf0123_- \t\r\nNext line.", "Friday works.\n \t> > Sent with Intention https://intention.example/?ref=AbCdEf0123_- \t\r\nNext line.\n\nsent with intention https://intention.example/?ref=ZYXwvut987_-"),
    ])
    func decorationCannotAuthorizeUnshownText(_ texts: (String, String)) async throws {
        let (shown, accepted) = texts
        let drafts = ScriptedDrafts(creates: [.from { Receipt.complete($0, revision: $1, text: shown) }],
                                    accepts: [.from { Receipt.complete($0, revision: $1, text: accepted, accepted: true) }])
        let writer = EmailWriter(drafts: drafts, signedIn: true, addSentWithIntention: { true })
        let proposal = try #require(try? await writer.propose(body: body).get())
        var recorded = false
        var failure: EmailWriter.ProposalDiagnostics.FailureKind?
        writer.recordReceipt = { _, _, _, _ in recorded = true }
        let recording = writer.recordAcceptance(proposal) { diagnosis, _ in failure = diagnosis.failureKind }
        #expect(await recording.value == .failure(.request(.conflict)))
        #expect(failure == .acceptanceFailed)
        #expect(!recorded)
        #expect(drafts.accepted.count == 1)
    }

    @Test(arguments: [(false, false), (false, true), (true, false), (true, true)])
    func decorationUsesTheSettingCapturedAtGeneration(_ settings: (Bool, Bool)) async throws {
        var enabled = settings.0
        let accepted = "Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-"
        let drafts = ScriptedDrafts(creates: [.from { Receipt.complete($0, revision: $1, text: "Friday works.") }],
                                    accepts: [.from { Receipt.complete($0, revision: $1, text: accepted, accepted: true) }])
        let writer = EmailWriter(drafts: drafts, signedIn: true, addSentWithIntention: { enabled })
        let proposal = try #require(try? await writer.propose(body: body).get())
        #expect(drafts.created.first?.compose.addSentWithIntention == settings.0)
        enabled = settings.1
        let expected: Result<String, EmailWriter.Problem> = settings.0 ? .success(accepted) : .failure(.request(.conflict))
        #expect(await writer.recordAcceptance(proposal).value == expected)
    }

    @Test(arguments: ["requestID", "revision", "pending", "abstained", "notAccepted", "missingText", "emptyText",
                       "cancelled", "superseded", "expired", "contextInvalidated"])
    func aFooterNeverOverridesReceiptAuthority(_ mutation: String) async throws {
        let drafts = ScriptedDrafts(creates: [.from { Receipt.complete($0, revision: $1, text: "Friday works.") }],
                                    accepts: [.from { id, revision in
            let reason = DraftReason(rawValue: mutation == "contextInvalidated" ? "context_invalidated" : mutation)
            let status: DraftReceipt.Status = reason != nil ? .cancelled : mutation == "pending" ? .pending : mutation == "abstained" ? .abstained : .complete
            return Receipt.make(mutation == "requestID" ? UUID() : id,
                                revision: mutation == "revision" ? revision + 1 : revision, status: status, reason: reason,
                                text: mutation == "missingText" ? nil : mutation == "emptyText" ? "" : "Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-",
                                accepted: mutation != "notAccepted")
        }])
        let writer = EmailWriter(drafts: drafts, signedIn: true, addSentWithIntention: { true })
        let proposal = try #require(try? await writer.propose(body: body).get())
        var recorded = false
        writer.recordReceipt = { _, _, _, _ in recorded = true }
        let reason = DraftReason(rawValue: mutation == "contextInvalidated" ? "context_invalidated" : mutation)
        let expected: EmailWriter.Problem = reason.map { .cancelled($0) } ?? .request(.conflict)
        #expect(await writer.recordAcceptance(proposal).value == .failure(expected))
        #expect(!recorded)
        #expect(drafts.accepted.count == 1)
    }

    @Test(arguments: [false, true])
    func anOldAccountCannotReleaseADecoratedReceipt(_ signedIn: Bool) async throws {
        let clock = SteppedClock()
        let drafts = ScriptedDrafts(creates: [.from { Receipt.complete($0, revision: $1, text: "Friday works.") }],
                                    accepts: [.from { Receipt.complete($0, revision: $1, text: "Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-", accepted: true) }])
        let writer = EmailWriter(drafts: drafts, signedIn: true, clock: clock, addSentWithIntention: { true })
        let proposal = try #require(try? await writer.propose(body: body).get())
        drafts.beforeAccept = { try await clock.sleep(until: .seconds(1)) }
        var recorded = false
        writer.recordReceipt = { _, _, _, _ in recorded = true }
        let recording = writer.recordAcceptance(proposal)
        await spin { drafts.accepted.count == 1 && clock.waits.contains(.seconds(1)) }
        writer.accountChanged(signedIn: signedIn)
        clock.advance(to: .seconds(1))
        #expect(await recording.value == .failure(.withdrawn))
        #expect(!recorded)
    }

    @Test(arguments: [
        " Caf\u{00E9}  works. \t\r\n\u{00A0}",
        "Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-",
        "Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-",
    ])
    func identicalReceiptBytesNeedNoDecorationPermission(_ text: String) async throws {
        let drafts = ScriptedDrafts(creates: [.from { Receipt.complete($0, revision: $1, text: text) }],
                                    accepts: [.from { Receipt.complete($0, revision: $1, text: text, accepted: true) }])
        let writer = EmailWriter(drafts: drafts, signedIn: true, addSentWithIntention: { false })
        let proposal = try #require(try? await writer.propose(body: body).get())
        let accepted = try #require(try? await writer.recordAcceptance(proposal).value.get())
        #expect(accepted.utf8.elementsEqual(text.utf8))
    }

    @Test func aDecoratedReceiptCanRetryOnlyTheOriginalRequest() async throws {
        let clock = SteppedClock()
        let accepted = "Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-"
        let drafts = ScriptedDrafts(creates: [.from { Receipt.complete($0, revision: $1, text: "Friday works.") }],
                                    accepts: [.failure(.unreachable), .from { Receipt.complete($0, revision: $1, text: accepted, accepted: true) }])
        let writer = EmailWriter(drafts: drafts, signedIn: true, pollInterval: .milliseconds(5), clock: clock,
                                 addSentWithIntention: { true })
        let proposal = try #require(try? await writer.propose(body: body).get())
        var retried = false
        let recording = writer.recordAcceptance(proposal) { diagnosis, _ in retried = diagnosis.retried }
        await spin { drafts.accepted.count == 1 && clock.waits.contains(.seconds(1)) }
        clock.advance(to: .seconds(1))
        #expect(await recording.value == .success(accepted))
        #expect(retried)
        #expect(drafts.accepted.map(\.id) == [proposal.id, proposal.id])
        #expect(drafts.accepted.map(\.revision) == [proposal.revision, proposal.revision])
        #expect(drafts.created.count == 1)
    }

    @Test func aDecoratedReceiptStillExpiresAtTheAcceptanceDeadline() async throws {
        let clock = SteppedClock()
        let drafts = ScriptedDrafts(creates: [.from { Receipt.complete($0, revision: $1, text: "Friday works.") }],
                                    accepts: [.from { Receipt.complete($0, revision: $1, text: "Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-", accepted: true) }])
        let writer = EmailWriter(drafts: drafts, signedIn: true, requestLimit: .seconds(5), clock: clock,
                                 addSentWithIntention: { true })
        let proposal = try #require(try? await writer.propose(body: body).get())
        drafts.beforeAccept = { try await clock.sleep(until: .seconds(10)) }
        var recorded = false
        writer.recordReceipt = { _, _, _, _ in recorded = true }
        let recording = writer.recordAcceptance(proposal)
        await spin { clock.waits.contains(.seconds(5)) && clock.waits.contains(.seconds(10)) }
        clock.advance(to: .seconds(5))
        #expect(await recording.value == .failure(.timedOut))
        #expect(!recorded)
        #expect(drafts.accepted.count == 1)
    }

    @Test(arguments: [false, true])
    func aWithdrawnWriterCannotBeginDecoratedAcceptance(_ signOut: Bool) async throws {
        let drafts = ScriptedDrafts(creates: [.from { Receipt.complete($0, revision: $1, text: "Friday works.") }],
                                    accepts: [.from { Receipt.complete($0, revision: $1, text: "Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-", accepted: true) }])
        let writer = EmailWriter(drafts: drafts, signedIn: true, addSentWithIntention: { true })
        let proposal = try #require(try? await writer.propose(body: body).get())
        if signOut { writer.accountChanged(signedIn: false) }
        else { writer.isEnabled = false }
        #expect(await writer.recordAcceptance(proposal).value == .failure(.withdrawn))
        #expect(drafts.accepted.isEmpty)
    }

    @Test(arguments: ["dictation", "proposal", "regeneration"])
    func sentWithIntentionIsAbsentWhenOffAndABooleanWhenOn(kind: String) async throws {
        var enabled = false
        let drafts = ScriptedDrafts(creates: [.from { Receipt.complete($0, revision: $1) }])
        let writer = EmailWriter(drafts: drafts, signedIn: true, addSentWithIntention: { enabled })
        for choice in [false, true, false] {
            enabled = choice
            switch kind {
            case "proposal": _ = await writer.propose(body: body)
            case "regeneration":
                _ = await writer.revise(.init(requestID: UUID(), revision: 1, text: "Synthetic parent."), words: words, body: body)
            default: _ = await writer.write(cue: words, body: body)
            }
            let input = try #require(drafts.created.last)
            let object = try #require(JSONSerialization.jsonObject(with: input.encoded()) as? [String: Any])
            let compose = try #require(object["compose"] as? [String: Any])
            if choice {
                let value = try #require(compose["add_sent_with_intention"] as? NSNumber)
                #expect(CFGetTypeID(value) == CFBooleanGetTypeID())
                #expect(value.boolValue)
            } else {
                #expect(compose["add_sent_with_intention"] == nil)
            }
        }
    }

    @Test(arguments: ["dictation", "proposal", "backgroundProposal", "regeneration"])
    func acceptedArrivalRecordsRequestCountTimeAndOriginalScope(kind: String) async throws {
        let drafts = ScriptedDrafts(accepts: [.failure(.unreachable), .from { id, revision in
            var receipt = Receipt.complete(id, revision: revision, accepted: true)
            receipt.voiceExamples = 4
            return receipt
        }])
        let writer = writer(drafts)
        writer.retentionScope = { "synthetic-account-scope" }
        var events: [(UUID, Int, Date, String?)] = []
        writer.recordReceipt = { events.append(($0, $1, $2, $3)) }
        let started = Date()
        let result: Result<String, EmailWriter.Problem>
        switch kind {
        case "proposal", "backgroundProposal":
            let proposal = try #require(try? await writer.propose(body: body).get())
            #expect(events.isEmpty)
            if kind == "backgroundProposal" {
                result = await writer.recordAcceptance(proposal).value
            } else { result = await writer.accept(proposal) }
        case "regeneration":
            result = await writer.revise(.init(requestID: UUID(), revision: 1, text: "Synthetic parent."), words: words, body: body)
        default: result = await writer.write(cue: words, body: body)
        }
        #expect(result == .success(Receipt.text))
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.0 == drafts.accepted.last?.id)
        #expect(event.1 == 4)
        #expect(event.2 >= started && event.2 <= Date())
        #expect(event.3 == "synthetic-account-scope")
        #expect(drafts.accepted.count == 2)
    }

    @Test func refusedAcceptanceNeverRecordsReceipt() async {
        let drafts = ScriptedDrafts(accepts: [.from { id, revision in
            Receipt.make(id, revision: revision, status: .cancelled, reason: .excluded)
        }])
        let writer = writer(drafts)
        var recorded = false
        writer.recordReceipt = { _, _, _, _ in recorded = true }
        _ = await writer.write(cue: words, body: body)
        #expect(!recorded)
    }

    private func spin(_ condition: @escaping () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(condition())
    }

    // A server ready at four seconds should reach the writer by five,
    // with the production poll interval, rather than the fast test interval.
    @Test func aDraftReadyAtFourSecondsIsPickedUpWithinOneSecond() async {
        let clock = SteppedClock()
        let drafts = ScriptedDrafts(reads: [.from { id, revision in
            clock.now >= .seconds(4) ? Receipt.complete(id, revision: revision) : Receipt.pending(id, revision)
        }])
        let writer = EmailWriter(drafts: drafts, signedIn: true, clock: clock)
        let task = Task { await writer.write(cue: words, body: body) }
        for second in 1...4 {
            await spin { clock.waits.contains(.seconds(second)) }
            clock.advance(to: .seconds(second))
            await spin { drafts.read.count == second }
        }
        await spin { drafts.accepted.count == 1 }
        #expect(await task.value == .success(Receipt.text))
        #expect(clock.now <= .seconds(5))
    }

    // The log must separate a delayed create answer from the first poll's
    // scheduled pause and call. It never carries the cue, body or draft.
    @Test func writerLogsTheCreateAndFirstPollBoundariesWithoutContent() async {
        let capture = LoggedLines()
        let drafts = ScriptedDrafts()
        let result = await AppLog.$composeLines.withValue(capture) {
            await writer(drafts).write(cue: words, body: body)
        }
        #expect(result == .success(Receipt.text))
        let lines = capture.all
        let attempt = lines.first?.split(separator: " ").last.map(String.init)
        #expect(attempt?.hasPrefix("attempt=") == true)
        #expect(lines.allSatisfy { $0.split(separator: " ").last.map(String.init) == attempt })
        #expect(lines.map { String($0.prefix { $0 != " " }) } == ["request.account.started", "request.account.returned",
                          "request.create.started", "request.create.returned", "request.create.received",
                          "request.poll.scheduled", "request.poll.due",
                          "request.poll.started", "request.poll.returned", "request.poll.received",
                          "request.accept.started", "request.accept.returned", "written"])
    }

    // Admission has one deadline across both calls and the retry pause.
    @Test func aRecipientRefusalIsReportedOnceWithoutRetryingAdmission() async throws {
        let drafts = ScriptedDrafts()
        drafts.shownAnswers = [.recipientsOutsideThread]
        let writer = writer(drafts)
        guard case let .success(proposal) = await writer.propose(body: body) else {
            Issue.record("Expected a completed proposal")
            return
        }
        var refusals = 0
        let admission = await writer.admit(proposal) { refusals += 1 }
        #expect(admission == .unreported)
        #expect(refusals == 1)
        #expect(drafts.shownCalls.count == 1)
    }

    @Test(arguments: [4800, 5900])
    func admissionRetriesUseOnlyTheTimeLeftOfSixSeconds(_ firstMilliseconds: Int) async throws {
        let clock = SteppedClock()
        let drafts = ScriptedDrafts(creates: [.from { Receipt.complete($0, revision: $1) }])
        drafts.shownAnswers = [.unreachable, nil]
        drafts.beforeShown = { count in
            try await clock.sleep(until: count == 1 ? .milliseconds(firstMilliseconds) : .seconds(20))
        }
        let writer = stepped(drafts, clock)
        guard case let .success(proposal) = await writer.propose(body: body) else {
            Issue.record("Expected a completed proposal")
            return
        }
        let admission = Task { await writer.admit(proposal) }
        await spin { drafts.shownCalls.count == 1 && clock.waits.contains(.milliseconds(firstMilliseconds)) }
        clock.advance(to: .milliseconds(firstMilliseconds))
        let pauseEnd: Duration = firstMilliseconds == 4800 ? .milliseconds(5100) : .seconds(6)
        await spin { clock.waits == [pauseEnd] }
        clock.advance(to: pauseEnd)
        if firstMilliseconds == 4800 {
            await spin { drafts.shownCalls.count == 2 && clock.waits.contains(.seconds(6)) }
            clock.advance(to: .seconds(6))
        }
        #expect(await admission.value == .unreported)
        #expect(drafts.shownCalls.count == (firstMilliseconds == 4800 ? 2 : 1))
        #expect(clock.now == .seconds(6))
        #expect(EmailWriter.admissionLimit == .seconds(6))
    }

    @Test func anAdmissionStalledOnTheFirstCallExpiresWithoutARetry() async throws {
        let clock = SteppedClock()
        let drafts = ScriptedDrafts(creates: [.from { Receipt.complete($0, revision: $1) }])
        drafts.beforeShown = { _ in try await clock.sleep(until: .seconds(20)) }
        let writer = stepped(drafts, clock)
        guard case let .success(proposal) = await writer.propose(body: body) else {
            Issue.record("Expected a completed proposal")
            return
        }
        let admission = Task { await writer.admit(proposal) }
        await spin { drafts.shownCalls.count == 1 && clock.waits.contains(.seconds(6)) }
        clock.advance(to: .seconds(6))
        #expect(await admission.value == .unreported)
        #expect(drafts.shownCalls.count == 1)
    }

    @Test func aSuccessfulAdmissionAtTheDeadlineIsDroppedEvenIfItsTimerRunsLate() async throws {
        let clock = SteppedClock()
        let drafts = ScriptedDrafts(creates: [.from { Receipt.complete($0, revision: $1) }])
        drafts.beforeShown = { _ in clock.jump(to: .seconds(6)) }
        let writer = stepped(drafts, clock)
        guard case let .success(proposal) = await writer.propose(body: body) else {
            Issue.record("Expected a completed proposal")
            return
        }
        #expect(await writer.admit(proposal) == .unreported)
        #expect(drafts.shownCalls.count == 1)
    }

    // MARK: - The whole way

    @Test func anEmailIsWrittenFromTheWordsAndTheBodyAndAccepted() async throws {
        let drafts = ScriptedDrafts()
        let writer = writer(drafts)
        #expect(writer.availability == nil)
        #expect(writer.isWanted)
        let outcome = await writer.write(cue: words, body: body)
        #expect(outcome == .success(Receipt.text))
        let input = try #require(drafts.created.first)
        #expect(drafts.created.count == 1)
        #expect(input.revision == 1)
        #expect(input.mode == .reply)
        #expect(input.cue == words)
        #expect(input.compose.recipients.isEmpty)
        #expect(input.compose.subject == "")
        #expect(input.compose.observedThread == body.body)
        #expect(input.compose.observedOrigin == .unknown)
        #expect(input.compose.threadSources.isEmpty)
        #expect(input.regeneration == nil)
        // Pending once, then complete, then accepted at its revision.
        #expect(drafts.read == [input.requestID])
        #expect(drafts.accepted.map(\.id) == [input.requestID])
        #expect(drafts.accepted.map(\.revision) == [1])
        #expect(drafts.cancelled.isEmpty)
    }

    @Test func anEmptyBodyIsANewMessage() async throws {
        let drafts = ScriptedDrafts()
        _ = await writer(drafts).write(cue: words, body: EmailBody(bundleIdentifier: nil, body: ""))
        #expect(drafts.created.first?.mode == .new)
    }

    @Test func aDraftCompleteAtOnceNeedsNoPoll() async throws {
        let drafts = ScriptedDrafts(creates: [.from { Receipt.complete($0, revision: $1) }])
        let outcome = await writer(drafts).write(cue: words, body: body)
        #expect(outcome == .success(Receipt.text))
        #expect(drafts.read.isEmpty)
        #expect(drafts.accepted.count == 1)
    }

    // MARK: - Every receipt without text ends the attempt

    @Test(arguments: DraftReason.allCases)
    func anAbstentionEndsTheAttemptWithoutAnotherRequest(reason: DraftReason) async {
        let drafts = ScriptedDrafts(creates: [.from { Receipt.abstained($0, $1, reason) }])
        let outcome = await writer(drafts).write(cue: words, body: body)
        #expect(outcome == .failure(.abstained(reason)))
        try? await Task.sleep(for: .milliseconds(30))
        // Retryable or final, Intention itself never asks again.
        #expect(drafts.created.count == 1)
        #expect(drafts.accepted.isEmpty)
    }

    @Test(arguments: [DraftReason.superseded, .expired, .cancelled, .contextInvalidated])
    func aDraftTheServerTookBackIsNoEmail(reason: DraftReason) async {
        let drafts = ScriptedDrafts(reads: [.from { Receipt.make($0, revision: $1, status: .cancelled, reason: reason) }])
        let outcome = await writer(drafts).write(cue: words, body: body)
        #expect(outcome == .failure(.cancelled(reason)))
        #expect(drafts.accepted.isEmpty)
    }

    @Test func aReasonTheClientDoesNotKnowIsFinal() {
        let json = Receipt.json(UUID(), status: "abstained", reason: "a_reason_added_later")
        let receipt = try? JSONDecoder().decode(DraftReceipt.self, from: Data(json.utf8))
        #expect(receipt?.reason == .unrecognized)
        #expect(receipt?.reason?.isRetryable == false)
    }

    @Test func theReasonListAndRetryabilityMatchTheContract() {
        let contract: Set<String> = [
            "production_disabled", "invalid_input", "input_too_large", "binding_mismatch", "ineligible_example",
            "qualification_unavailable", "eligibility_changed", "cancelled", "excluded", "transport_unknown", "invalid_response",
            "context_preparing", "mail_import_pending", "context_invalidated", "timeout", "cost_limit", "superseded", "parent_accepted",
            "parent_unavailable", "configuration_retired", "expired", "mail_policy_unconfigured", "intention_unresolved",
            "nothing_to_answer", "proposal_limit",
        ]
        #expect(Set(DraftReason.allCases.map(\.rawValue)).subtracting(["unrecognized"]) == contract)
        let retryable: Set<DraftReason> = [.contextPreparing, .mailImportPending, .qualificationUnavailable, .eligibilityChanged, .timeout, .transportUnknown, .invalidResponse]
        #expect(Set(DraftReason.allCases.filter(\.isRetryable)) == retryable)
        let permanent = [DraftRequestFailure.disabled, .notConfigured, .mailPolicyUnconfigured].map { $0.isPermanent }
        #expect(permanent == [true, true, true])
        let passing = [DraftRequestFailure.unreachable, .busy(retryAfter: 1), .server(500), .storageUnavailable, .conflict].map { $0.isPermanent }
        #expect(passing == [false, false, false, false, false])
        // What a poll or a cancel sends again: the server or the connection
        // could not answer once. Nothing that says something about the
        // request or the account.
        let all: [DraftRequestFailure] = [.signedOut, .unauthorized, .missing, .conflict, .invalidInput, .excluded, .tooLarge,
                                          .busy(retryAfter: 1), .disabled, .notConfigured, .mailPolicyUnconfigured,
                                          .storageUnavailable, .unreachable, .invalidResponse, .server(500), .server(502),
                                          .server(503), .server(599), .server(404), .server(418), .server(600)]
        let transient: [DraftRequestFailure] = [.busy(retryAfter: 1), .storageUnavailable, .unreachable,
                                                .server(500), .server(502), .server(503), .server(599)]
        #expect(all.filter(\.isTransient) == transient)
    }

    @Test func textOnAReceiptThatIsNotCompleteIsNotAReceipt() {
        let json = Receipt.json(UUID(), status: "pending", text: "Hello")
        #expect((try? JSONDecoder().decode(DraftReceipt.self, from: Data(json.utf8))) == nil)
    }

    // MARK: - Failures on the way

    @Test func anOldAcceptanceRefusedKeyDoesNotSignOutTheNewAccount() async throws {
        var reported = false
        let refused = RefusedKey { reported = true }
        try await oldAcceptanceFailure(.refusedKey(refused))
        #expect(!reported)
    }

    @Test(arguments: [DraftRequestFailure.disabled, .notConfigured, .mailPolicyUnconfigured])
    func anOldAcceptancePermanentFailureDoesNotDisableTheNewAccount(failure: DraftRequestFailure) async throws {
        try await oldAcceptanceFailure(.failure(failure))
    }

    private func oldAcceptanceFailure(_ answer: ScriptedDrafts.Answer) async throws {
        let clock = SteppedClock()
        let drafts = ScriptedDrafts(accepts: [answer])
        let writer = writer(drafts)
        let proposal = try #require(try? await writer.propose(body: body).get())
        drafts.beforeAccept = { try await clock.sleep(until: .seconds(1)) }
        let recording = writer.recordAcceptance(proposal)
        await spin { drafts.accepted.count == 1 && clock.waits == [.seconds(1)] }
        writer.accountChanged(signedIn: true)
        clock.advance(to: .seconds(1))
        #expect(await recording.value == .failure(.withdrawn))
        #expect(writer.availability == nil)
        #expect(writer.isWanted)
        drafts.beforeAccept = nil
        drafts.accepts = []
        #expect(await writer.write(cue: words, body: body) == .success(Receipt.text))
    }

    @Test(arguments: [DraftRequestFailure.disabled, .notConfigured, .mailPolicyUnconfigured])
    func writingThatIsNotAvailableIsRememberedAndNotAskedAgain(failure: DraftRequestFailure) async {
        let drafts = ScriptedDrafts(creates: [.failure(failure)])
        let writer = writer(drafts)
        #expect(await writer.write(cue: words, body: body) == .failure(.unavailable(failure)))
        #expect(writer.availability == .unavailable(failure))
        // Still wanted, so the person is told their words were typed.
        #expect(writer.isWanted)
        #expect(await writer.write(cue: words, body: body) == .failure(.unavailable(failure)))
        #expect(drafts.created.count == 1)
        // A fresh sign-in forgets the state; the server is asked once more.
        writer.accountChanged(signedIn: true)
        #expect(writer.availability == nil)
        _ = await writer.write(cue: words, body: body)
        #expect(drafts.created.count == 2)
    }

    @Test func aBusyServerIsNotGivenASecondTry() async {
        let drafts = ScriptedDrafts(creates: [.failure(.busy(retryAfter: 1))])
        let outcome = await writer(drafts).write(cue: words, body: body)
        #expect(outcome == .failure(.request(.busy(retryAfter: 1))))
        #expect(drafts.created.count == 1)
    }

    @Test(arguments: [DraftRequestFailure.unreachable, .invalidResponse, .server(500), .storageUnavailable, .invalidInput, .excluded, .tooLarge])
    func aFailedCreateIsReportedAndTheRequestCancelledByName(failure: DraftRequestFailure) async throws {
        let drafts = ScriptedDrafts(creates: [.failure(failure)])
        let outcome = await writer(drafts).write(cue: words, body: body)
        #expect(outcome == .failure(.request(failure)))
        let id = try #require(drafts.created.first?.requestID)
        // The cancel goes out without the answer waiting on it.
        await spin { drafts.cancelled == [id] }
        #expect(drafts.created.count == 1)
    }

    @Test(arguments: [DraftRequestFailure.unreachable, .server(503), .storageUnavailable, .busy(retryAfter: 1)])
    func aTransientProposalCreateRetriesTheSameRequest(failure: DraftRequestFailure) async throws {
        let drafts = ScriptedDrafts(creates: [.failure(failure), .from { Receipt.complete($0, revision: $1) }])
        var diagnostics: EmailWriter.ProposalDiagnostics?
        let result = await writer(drafts).propose(body: body, diagnosed: { diagnostics = $0 })
        let proposal = try #require(try? result.get())
        #expect(drafts.created.count == 2)
        #expect(Set(drafts.created.map(\.requestID)) == [proposal.id])
        #expect(drafts.cancelled.isEmpty)
        #expect(diagnostics?.retried == true)
        #expect(diagnostics?.failureKind == nil)
        #expect(proposal.diagnostics == diagnostics)
    }

    @Test(arguments: ["create", "poll", "server", "cancelled"])
    func proposalDiagnosticsDistinguishTransportAndServerOutcomes(stage: String) async throws {
        let drafts: ScriptedDrafts
        let expected: EmailWriter.ProposalDiagnostics.FailureKind
        if stage == "create" {
            drafts = ScriptedDrafts(creates: [.failure(.server(403))])
            expected = .createFailed
        } else if stage == "poll" {
            drafts = ScriptedDrafts(reads: [.failure(.server(403))])
            expected = .pollFailed
        } else if stage == "server" {
            drafts = ScriptedDrafts(reads: [.from { Receipt.abstained($0, $1, .timeout) }])
            expected = .serverAbstained
        } else {
            drafts = ScriptedDrafts(reads: [.from { Receipt.make($0, revision: $1, status: .cancelled, reason: .cancelled) }])
            expected = .serverCancelled
        }
        var diagnostics: EmailWriter.ProposalDiagnostics?
        let result = await writer(drafts).propose(body: body, diagnosed: { diagnostics = $0 })
        #expect(diagnostics?.failureKind == expected)
        #expect(diagnostics?.retried == false)
        if stage == "server" { #expect(result == .failure(.abstained(.timeout))) }
        else if stage == "cancelled" { #expect(result == .failure(.cancelled(.cancelled))) }
        else { #expect(result == .failure(.request(.server(403)))) }
    }

    @Test(arguments: [false, true])
    func proposalDeadlinesRetainTheStageThatWasWaiting(polling: Bool) async throws {
        let clock = SteppedClock()
        let pendingReceipt: ScriptedDrafts.Answer = .from { Receipt.pending($0, $1) }
        let drafts = ScriptedDrafts(creates: polling ? [pendingReceipt] : [.late(.milliseconds(500), pendingReceipt)],
                                   reads: [pendingReceipt])
        let writer = stepped(drafts, clock)
        var diagnostics: EmailWriter.ProposalDiagnostics?
        let task = Task { await writer.propose(body: body, diagnosed: { diagnostics = $0 }) }
        await spin { drafts.created.count == 1 && !clock.waits.isEmpty }
        if polling { await spin { clock.waits == [.milliseconds(60)] } }
        clock.advance(to: .milliseconds(60))
        #expect(await task.value == .failure(.timedOut))
        #expect(diagnostics?.failureKind == (polling ? .pollTimedOut : .createTimedOut))
        #expect(diagnostics?.retried == false)
    }

    @Test(arguments: [false, true])
    func aPollFailureReportsAnActualRetry(creationRetried: Bool) async throws {
        let pending: ScriptedDrafts.Answer = .from { Receipt.pending($0, $1) }
        let drafts = ScriptedDrafts(creates: creationRetried ? [.failure(.server(503)), pending] : [pending],
                                   reads: creationRetried ? [.failure(.invalidInput)] : [.failure(.server(503)), .failure(.invalidInput)])
        var diagnostics: EmailWriter.ProposalDiagnostics?
        _ = await writer(drafts).propose(body: body, diagnosed: { diagnostics = $0 })
        #expect(drafts.read.count == (creationRetried ? 1 : 2))
        #expect(diagnostics?.failureKind == .pollFailed)
        #expect(diagnostics?.retried == true)
    }

    @Test func supersededProposalDiagnosticsCannotOverwriteTheNextAttempt() async throws {
        let drafts = ScriptedDrafts(creates: [.late(.milliseconds(100), .from { Receipt.complete($0, revision: $1) }),
                                             .failure(.invalidInput)])
        let writer = writer(drafts)
        var first: EmailWriter.ProposalDiagnostics?, second: EmailWriter.ProposalDiagnostics?
        let old = Task { await writer.propose(body: body, diagnosed: { first = $0 }) }
        await spin { drafts.created.count == 1 }
        #expect(await writer.propose(body: body, diagnosed: { second = $0 }) == .failure(.request(.invalidInput)))
        #expect(await old.value == .failure(.withdrawn))
        #expect(first?.failureKind == .withdrawn)
        #expect(second?.failureKind == .createFailed)
        #expect(first?.retried == false && second?.retried == false)
    }

    @Test func proposalFailureNamesAndHTTPClassesContainNoResponseText() {
        #expect(EmailWriter.Problem.request(.server(503)).telemetryName == "request.server")
        #expect(EmailWriter.Problem.request(.server(503)).httpStatusClass == "5xx")
        #expect(EmailWriter.Problem.request(.unreachable).telemetryName == "request.unreachable")
        #expect(EmailWriter.Problem.request(.unreachable).httpStatusClass == nil)
        #expect(EmailWriter.Problem.request(.invalidInput).httpStatusClass == "4xx")
        #expect(EmailWriter.Problem.timedOut.telemetryName == "timedOut")
        #expect(!EmailWriter.Problem.permitsTelemetryName("request.server.503 private text"))
        #expect(EmailWriter.Problem.permitsTelemetryName("request.server"))
    }

    @Test func aProposalRetryStopsAtItsOriginalDeadline() async throws {
        let clock = SteppedClock()
        let drafts = ScriptedDrafts(creates: [.failure(.server(503))])
        let writer = stepped(drafts, clock)
        var diagnostics: EmailWriter.ProposalDiagnostics?
        let pending = Task { await writer.propose(body: body, diagnosed: { diagnostics = $0 }) }
        await spin { drafts.created.count == 1 && clock.waits == [.milliseconds(60)] }
        clock.advance(to: .milliseconds(60))
        #expect(await pending.value == .failure(.timedOut))
        #expect(drafts.created.count == 1)
        #expect(diagnostics?.failureKind == .createTimedOut)
        #expect(diagnostics?.retried == false)
        #expect(diagnostics?.lastHTTPStatusClass == "5xx")
        await spin { drafts.cancelled.count == 1 }
    }

    @Test func accountChangeDuringProposalRetryMakesNoFurtherRequest() async throws {
        let clock = SteppedClock()
        let drafts = ScriptedDrafts(creates: [.failure(.unreachable), .from { Receipt.complete($0, revision: $1) }])
        let writer = EmailWriter(drafts: drafts, signedIn: true, requestLimit: .seconds(65), clock: clock)
        let pending = Task { await writer.propose(body: body) }
        await spin { drafts.created.count == 1 && clock.waits == [.seconds(1)] }
        writer.accountChanged(signedIn: false)
        clock.advance(to: .seconds(1))
        #expect(await pending.value == .failure(.withdrawn))
        #expect(drafts.created.count == 1)
    }

    @Test(arguments: [DraftRequestFailure.invalidInput, .excluded, .server(403), .disabled])
    func aPermanentProposalCreateFailureIsNotRetried(failure: DraftRequestFailure) async {
        let drafts = ScriptedDrafts(creates: [.failure(failure)])
        _ = await writer(drafts).propose(body: body)
        #expect(drafts.created.count == 1)
    }

    @Test(arguments: [DraftRequestFailure.missing, .conflict, .invalidResponse, .server(404)])
    func aPollThatFailsForGoodCancelsTheRequest(failure: DraftRequestFailure) async throws {
        let drafts = ScriptedDrafts(reads: [.failure(failure)])
        let outcome = await writer(drafts).write(cue: words, body: body)
        #expect(outcome == .failure(.request(failure)))
        let id = try #require(drafts.created.first?.requestID)
        #expect(drafts.read == [id])
        await spin { drafts.cancelled == [id] }
    }

    @Test(arguments: [DraftRequestFailure.storageUnavailable, .server(503), .server(500), .unreachable])
    func aPollTheServerCouldNotAnswerIsReadAgain(failure: DraftRequestFailure) async throws {
        // The first polls fail while the server still writes the draft, as a
        // lock held for the thread's context made them 503 in build 5.
        let drafts = ScriptedDrafts(reads: [.failure(failure), .failure(failure), .from { Receipt.complete($0, revision: $1) }])
        let outcome = await writer(drafts).write(cue: words, body: body)
        #expect(outcome == .success(Receipt.text))
        let id = try #require(drafts.created.first?.requestID)
        #expect(drafts.created.count == 1)
        #expect(drafts.read == [id, id, id])
        #expect(drafts.accepted.map(\.id) == [id])
        try? await Task.sleep(for: .milliseconds(30))
        #expect(drafts.cancelled.isEmpty)
    }

    @Test func pollsTheServerCannotAnswerUntilTheLimitTimeOut() async throws {
        let clock = SteppedClock()
        let drafts = ScriptedDrafts(reads: [.failure(.storageUnavailable)])
        let writer = stepped(drafts, clock)
        let writing = Task { await writer.write(cue: words, body: body) }
        await spin { clock.waits == [.milliseconds(5)] }
        clock.advance(to: .milliseconds(5))
        // The one-second retry pause is cut short by the 60 ms deadline.
        await spin { drafts.read.count == 1 && clock.waits == [.milliseconds(60)] }
        clock.advance(to: .milliseconds(60))
        #expect(await writing.value == .failure(.timedOut))
        let id = try #require(drafts.created.first?.requestID)
        // No poll at the limit, and never a second request.
        #expect(drafts.read == [id])
        #expect(drafts.created.count == 1)
        #expect(drafts.accepted.isEmpty)
        await spin { drafts.cancelled == [id] }
    }

    @Test func aSecondAskWhileOneWaitsCancelsTheFirstWithTheServer() async throws {
        // Setup's reply page and a dictation into Gmail share the writer:
        // the later ask ends the earlier one and cancels it by id, so no
        // draft runs on for nobody.
        let clock = SteppedClock()
        let drafts = ScriptedDrafts(reads: [.failure(.storageUnavailable), .from { Receipt.complete($0, revision: $1) }])
        let writer = stepped(drafts, clock)
        let first = Task { await writer.write(cue: words, body: body) }
        await spin { clock.waits == [.milliseconds(5)] }
        clock.advance(to: .milliseconds(5))
        await spin { drafts.read.count == 1 && clock.waits == [.milliseconds(60)] }
        let second = Task { await writer.write(cue: "say yes", body: body) }
        await spin { drafts.created.count == 2 }
        let firstID = try #require(drafts.created.first?.requestID)
        await spin { drafts.cancelled == [firstID] }
        // The newer request can finish while the older retry still sleeps.
        await spin { clock.waits == [.milliseconds(10), .milliseconds(60)] }
        clock.advance(to: .milliseconds(10))
        #expect(await second.value == .success(Receipt.text))
        clock.advance(to: .milliseconds(60))
        #expect(await first.value == .failure(.withdrawn))
        let secondID = try #require(drafts.created.last?.requestID)
        #expect(drafts.accepted.map(\.id) == [secondID])
        #expect(drafts.cancelled == [firstID])
    }

    @Test func cancellingWhileAPollWaitsToBeReadAgainWithdrawsTheRequest() async throws {
        let clock = SteppedClock()
        let drafts = ScriptedDrafts(reads: [.failure(.storageUnavailable), .from { Receipt.complete($0, revision: $1) }])
        let writer = stepped(drafts, clock)
        let writing = Task { await writer.write(cue: words, body: body) }
        await spin { clock.waits == [.milliseconds(5)] }
        clock.advance(to: .milliseconds(5))
        await spin { drafts.read.count == 1 && clock.waits == [.milliseconds(60)] }
        writer.cancel()
        let id = try #require(drafts.created.first?.requestID)
        await spin { drafts.cancelled == [id] }
        clock.advance(to: .milliseconds(60))
        #expect(await writing.value == .failure(.withdrawn))
        // The poll that would have found it complete is never sent.
        #expect(drafts.read == [id])
        #expect(drafts.accepted.isEmpty)
    }

    @Test(arguments: [DraftRequestFailure.storageUnavailable, .server(502), .unreachable])
    func anAcceptanceTheServerCouldNotAnswerIsSentAgain(failure: DraftRequestFailure) async throws {
        // The draft is complete; acceptance waits on the same lock and
        // fails once. Accepting the same revision again only records it.
        let drafts = ScriptedDrafts(accepts: [.failure(failure), .from { Receipt.complete($0, revision: $1, accepted: true) }])
        let outcome = await writer(drafts).write(cue: words, body: body)
        #expect(outcome == .success(Receipt.text))
        let id = try #require(drafts.created.first?.requestID)
        #expect(drafts.accepted.map(\.id) == [id, id])
        #expect(drafts.accepted.map(\.revision) == [1, 1])
        #expect(drafts.created.count == 1)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(drafts.cancelled.isEmpty)
    }

    @Test func anAcceptanceThatFailsForGoodIsNotSentAgain() async throws {
        let drafts = ScriptedDrafts(accepts: [.failure(.missing)])
        #expect(await writer(drafts).write(cue: words, body: body) == .failure(.request(.missing)))
        let id = try #require(drafts.created.first?.requestID)
        #expect(drafts.accepted.map(\.id) == [id])
        await spin { drafts.cancelled == [id] }
    }

    @Test func aBusyPollWaitsAsTheServerAsksWithinItsCap() async throws {
        let clock = SteppedClock()
        let drafts = ScriptedDrafts(reads: [.failure(.busy(retryAfter: 1)), .failure(.busy(retryAfter: 30)),
                                            .from { Receipt.complete($0, revision: $1) }])
        let writer = EmailWriter(drafts: drafts, signedIn: true, pollInterval: .milliseconds(5), requestLimit: .seconds(65), clock: clock)
        let writing = Task { await writer.write(cue: words, body: body) }
        await spin { clock.waits == [.milliseconds(5)] }
        clock.advance(to: .milliseconds(5))
        // A 429 asking for a second is given it before the next poll.
        await spin { drafts.read.count == 1 && clock.waits == [.milliseconds(1005)] }
        clock.advance(to: .milliseconds(1005))
        // One asking for 30 is given no more than five seconds.
        await spin { drafts.read.count == 2 && clock.waits == [.milliseconds(6005)] }
        clock.advance(to: .milliseconds(6005))
        #expect(await writing.value == .success(Receipt.text))
        #expect(drafts.read.count == 3)
    }

    @Test func aPollThatFailsAfterTheLimitIsNotReadAgain() async throws {
        let clock = SteppedClock()
        let drafts = ScriptedDrafts(reads: [.late(.milliseconds(50), .failure(.storageUnavailable))])
        let writer = stepped(drafts, clock)
        let writing = Task { await writer.write(cue: words, body: body) }
        await spin { clock.waits == [.milliseconds(5)] }
        clock.advance(to: .milliseconds(5))
        await spin { drafts.read.count == 1 }
        clock.jump(to: .milliseconds(60))
        #expect(await writing.value == .failure(.timedOut))
        let id = try #require(drafts.created.first?.requestID)
        await spin { drafts.cancelled == [id] }
        #expect(drafts.read == [id])
    }

    @Test func aCancelTheServerCouldNotAnswerIsSentAgain() async throws {
        let drafts = ScriptedDrafts(creates: [.failure(.missing)],
                                    cancels: [.failure(.storageUnavailable), .from { Receipt.make($0, revision: $1, status: .cancelled, reason: .cancelled) }])
        #expect(await writer(drafts).write(cue: words, body: body) == .failure(.request(.missing)))
        let id = try #require(drafts.created.first?.requestID)
        await spin { drafts.cancelled == [id, id] }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(drafts.cancelled == [id, id])
    }

    @Test func aCancelIsNotSentAgainAfterTheLimit() async throws {
        // The draft is still pending at the limit; the cancel that follows
        // fails with a 503 and is not sent again, since the limit has passed.
        let drafts = ScriptedDrafts(reads: [.from { Receipt.pending($0, $1) }], cancels: [.failure(.storageUnavailable)])
        #expect(await writer(drafts, limit: .milliseconds(60)).write(cue: words, body: body) == .failure(.timedOut))
        let id = try #require(drafts.created.first?.requestID)
        await spin { drafts.cancelled == [id] }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(drafts.cancelled == [id])
    }

    @Test func aCancelIsNotRetriedPastTheLimit() async throws {
        // Cancelled by the person 40 ms into a 60 ms limit, with polls 30 ms
        // apart: a retry of the failed cancel would go out at 1040 ms, after
        // the limit, so it is not sent.
        let clock = SteppedClock()
        let drafts = ScriptedDrafts(cancels: [.failure(.unreachable)])
        let writer = EmailWriter(drafts: drafts, signedIn: true, pollInterval: .milliseconds(30), requestLimit: .milliseconds(60), clock: clock)
        let writing = Task { await writer.write(cue: words, body: body) }
        await spin { clock.waits == [.milliseconds(30)] }
        clock.jump(to: .milliseconds(40))
        writer.cancel()
        clock.advance(to: .milliseconds(40))
        #expect(await writing.value == .failure(.withdrawn))
        let id = try #require(drafts.created.first?.requestID)
        await spin { drafts.cancelled == [id] }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(drafts.cancelled == [id])
        #expect(clock.waits.isEmpty)
    }

    @Test func aCancelIsSentAFewTimesAtMost() async throws {
        let drafts = ScriptedDrafts(creates: [.failure(.missing)], cancels: [.failure(.unreachable)])
        #expect(await writer(drafts).write(cue: words, body: body) == .failure(.request(.missing)))
        let id = try #require(drafts.created.first?.requestID)
        await spin { drafts.cancelled.count == 3 }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(drafts.cancelled == [id, id, id])
    }

    @Test func aRefusedKeySignsTheMacOut() async {
        let drafts = ScriptedDrafts(creates: [.failure(.unauthorized)])
        let writer = writer(drafts)
        #expect(await writer.write(cue: words, body: body) == .failure(.signedOut))
        #expect(writer.availability == .signedOut)
        #expect(!writer.isWanted)
    }

    @Test func aReceiptForAnotherRequestIsNoAnswer() async {
        let drafts = ScriptedDrafts(creates: [.receipt(Receipt.pending(UUID()))])
        let outcome = await writer(drafts).write(cue: words, body: body)
        #expect(outcome == .failure(.request(.invalidResponse)))
    }

    @Test func acceptanceRefusedOrTakenBackReleasesNoText() async {
        var drafts = ScriptedDrafts(accepts: [.failure(.conflict)])
        #expect(await writer(drafts).write(cue: words, body: body) == .failure(.request(.conflict)))
        drafts = ScriptedDrafts(accepts: [.from { Receipt.make($0, revision: $1, status: .cancelled, reason: .cancelled) }])
        #expect(await writer(drafts).write(cue: words, body: body) == .failure(.cancelled(.cancelled)))
        // Complete but not marked accepted is not accepted.
        drafts = ScriptedDrafts(accepts: [.from { Receipt.complete($0, revision: $1) }])
        #expect(await writer(drafts).write(cue: words, body: body) == .failure(.request(.conflict)))
    }

    // MARK: - The wait's limit

    @Test func aDraftStillPendingAtTheLimitIsCancelledAndTimedOut() async throws {
        let drafts = ScriptedDrafts(reads: [.from { Receipt.pending($0, $1) }])
        let outcome = await writer(drafts, limit: .milliseconds(60)).write(cue: words, body: body)
        #expect(outcome == .failure(.timedOut))
        let id = try #require(drafts.created.first?.requestID)
        // The cancel goes out without the answer waiting on it.
        await spin { drafts.cancelled == [id] }
        #expect(drafts.accepted.isEmpty)
    }

    @Test func anAnswerAfterTheLimitIsNotReleased() async {
        let drafts = SlowDrafts()
        drafts.createDelay = .milliseconds(100)
        drafts.completeCreate = true
        let outcome = await writer(drafts, limit: .milliseconds(20)).write(cue: words, body: body)
        #expect(outcome == .failure(.timedOut))
        await spin { drafts.cancelled == [drafts.created].compactMap { $0 } }
        #expect(drafts.accepted.isEmpty)
    }

    // A call that never answers stands as one the transport would give up
    // on after its own 30 seconds; the attempt must end at the limit.
    private static let never: Duration = .seconds(30)
    /// Well past a 60 ms limit and its scheduling, and far short of the
    /// transport's 30 seconds.
    private static let promptly: Duration = .seconds(1)

    @Test func aCreateThatNeverAnswersIsTimedOutAtTheLimit() async throws {
        let drafts = ScriptedDrafts(creates: [.late(Self.never, .from { Receipt.pending($0, $1) })])
        let started = ContinuousClock.now
        let outcome = await writer(drafts, limit: .milliseconds(60)).write(cue: words, body: body)
        #expect(outcome == .failure(.timedOut))
        #expect(ContinuousClock.now - started < Self.promptly)
        let id = try #require(drafts.created.first?.requestID)
        await spin { drafts.cancelled == [id] }
        #expect(drafts.read.isEmpty)
        #expect(drafts.accepted.isEmpty)
    }

    /// A writer on a clock the scenario steps, with a 60 ms limit and polls
    /// 5 ms apart, so which stage the limit passes in does not depend on
    /// how promptly tasks run.
    private func stepped(_ drafts: any DraftService, _ clock: SteppedClock) -> EmailWriter {
        EmailWriter(drafts: drafts, signedIn: true, pollInterval: .milliseconds(5), requestLimit: .milliseconds(60), clock: clock)
    }

    @Test func aPollThatNeverAnswersIsTimedOutAtTheLimit() async throws {
        let clock = SteppedClock()
        let drafts = ScriptedDrafts(reads: [.late(Self.never, .from { Receipt.complete($0, revision: $1) })])
        let writer = stepped(drafts, clock)
        let writing = Task { await writer.write(cue: words, body: body) }
        // Created, and asleep until the first poll.
        await spin { clock.waits == [.milliseconds(5)] }
        clock.advance(to: .milliseconds(5))
        // Polled once, and that poll waits on the limit.
        await spin { drafts.read.count == 1 && clock.waits == [.milliseconds(60)] }
        clock.advance(to: .milliseconds(60))
        #expect(await writing.value == .failure(.timedOut))
        let id = try #require(drafts.created.first?.requestID)
        await spin { drafts.cancelled == [id] }
        #expect(drafts.read == [id])
        #expect(drafts.accepted.isEmpty)
    }

    @Test func anAcceptanceThatNeverAnswersIsTimedOutAtTheLimit() async throws {
        let clock = SteppedClock()
        let drafts = ScriptedDrafts(accepts: [.late(Self.never, .from { Receipt.complete($0, revision: $1, accepted: true) })])
        let writer = stepped(drafts, clock)
        let writing = Task { await writer.write(cue: words, body: body) }
        await spin { clock.waits == [.milliseconds(5)] }
        clock.advance(to: .milliseconds(5))
        // The poll found it complete; acceptance was asked for and waits.
        await spin { drafts.accepted.count == 1 && clock.waits == [.milliseconds(60)] }
        clock.advance(to: .milliseconds(60))
        #expect(await writing.value == .failure(.timedOut))
        let id = try #require(drafts.created.first?.requestID)
        await spin { drafts.cancelled == [id] }
        #expect(drafts.read == [id])
        #expect(drafts.accepted.map(\.id) == [id])
    }

    // The limit passes while a call is answering, and the timer that marks
    // it runs late: the answer is taken after the limit and must be
    // dropped, whatever it says.

    @Test func aCreateAnsweredAfterTheLimitIsDropped() async throws {
        let clock = SteppedClock()
        let drafts = ScriptedDrafts(creates: [.late(.milliseconds(50), .from { Receipt.complete($0, revision: $1) })])
        let writer = stepped(drafts, clock)
        let writing = Task { await writer.write(cue: words, body: body) }
        await spin { drafts.created.count == 1 }
        clock.jump(to: .milliseconds(60))
        #expect(await writing.value == .failure(.timedOut))
        let id = try #require(drafts.created.first?.requestID)
        await spin { drafts.cancelled == [id] }
        #expect(drafts.read.isEmpty)
        #expect(drafts.accepted.isEmpty)
    }

    @Test func aPollAnsweredAfterTheLimitIsNotAccepted() async throws {
        let clock = SteppedClock()
        let drafts = ScriptedDrafts(reads: [.late(.milliseconds(50), .from { Receipt.complete($0, revision: $1) })])
        let writer = stepped(drafts, clock)
        let writing = Task { await writer.write(cue: words, body: body) }
        await spin { clock.waits == [.milliseconds(5)] }
        clock.advance(to: .milliseconds(5))
        await spin { drafts.read.count == 1 }
        clock.jump(to: .milliseconds(60))
        #expect(await writing.value == .failure(.timedOut))
        let id = try #require(drafts.created.first?.requestID)
        await spin { drafts.cancelled == [id] }
        #expect(drafts.accepted.isEmpty)
    }

    @Test func anAcceptanceAnsweredAfterTheLimitIsNotReleased() async throws {
        let clock = SteppedClock()
        let drafts = ScriptedDrafts(accepts: [.late(.milliseconds(50), .from { Receipt.complete($0, revision: $1, accepted: true) })])
        let writer = stepped(drafts, clock)
        let writing = Task { await writer.write(cue: words, body: body) }
        await spin { clock.waits == [.milliseconds(5)] }
        clock.advance(to: .milliseconds(5))
        await spin { drafts.accepted.count == 1 }
        clock.jump(to: .milliseconds(60))
        #expect(await writing.value == .failure(.timedOut))
        let id = try #require(drafts.created.first?.requestID)
        await spin { drafts.cancelled == [id] }
    }

    @Test func aFailureAnsweredAfterTheLimitSaysNothingAboutTheAccount() async throws {
        let clock = SteppedClock()
        let drafts = ScriptedDrafts(creates: [.late(.milliseconds(50), .failure(.unauthorized))])
        let writer = stepped(drafts, clock)
        let writing = Task { await writer.write(cue: words, body: body) }
        await spin { drafts.created.count == 1 }
        clock.jump(to: .milliseconds(60))
        #expect(await writing.value == .failure(.timedOut))
        #expect(writer.availability == nil)
        #expect(writer.isWanted)
    }

    @Test func aPollIntervalLongerThanTheLimitDoesNotOutwaitIt() async throws {
        let drafts = ScriptedDrafts(reads: [.from { Receipt.pending($0, $1) }])
        let writer = EmailWriter(drafts: drafts, signedIn: true, pollInterval: .seconds(30), requestLimit: .milliseconds(60))
        let started = ContinuousClock.now
        let outcome = await writer.write(cue: words, body: body)
        #expect(outcome == .failure(.timedOut))
        #expect(ContinuousClock.now - started < Self.promptly)
        let id = try #require(drafts.created.first?.requestID)
        await spin { drafts.cancelled == [id] }
        // Asleep until the limit, then no poll is sent past it.
        #expect(drafts.read.isEmpty)
    }

    @Test func anAcceptanceAnsweringJustAfterTheLimitIsNotReleased() async throws {
        let drafts = ScriptedDrafts(accepts: [.late(.milliseconds(150), .from { Receipt.complete($0, revision: $1, accepted: true) })])
        let writer = writer(drafts, limit: .milliseconds(100))
        let outcome = await writer.write(cue: words, body: body)
        #expect(outcome == .failure(.timedOut))
        let id = try #require(drafts.created.first?.requestID)
        await spin { drafts.cancelled == [id] }
        // The late answer has come and gone; it set nothing off.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(drafts.cancelled == [id])
        #expect(writer.availability == nil)
        writer.cancel()
        #expect(drafts.cancelled == [id])
    }

    @Test func aRefusalArrivingAfterTheLimitSaysNothingAboutTheAccount() async throws {
        // A late 401 or a late "writing is off" belongs to an attempt that
        // has already ended: it neither signs the Mac out nor marks writing
        // unavailable.
        let drafts = ScriptedDrafts(creates: [.late(.milliseconds(150), .failure(.unauthorized))],
                                    reads: [.late(.milliseconds(150), .failure(.disabled))])
        let writer = writer(drafts, limit: .milliseconds(60))
        #expect(await writer.write(cue: words, body: body) == .failure(.timedOut))
        try? await Task.sleep(for: .milliseconds(200))
        #expect(writer.availability == nil)
        #expect(writer.isWanted)
    }

    @Test func aQuickDraftIsWrittenInsideTheLimitAsBefore() async throws {
        let drafts = ScriptedDrafts(reads: [.from { Receipt.pending($0, $1) }, .from { Receipt.pending($0, $1) },
                                            .from { Receipt.complete($0, revision: $1) }])
        let started = ContinuousClock.now
        let outcome = await writer(drafts, limit: .seconds(2)).write(cue: words, body: body)
        #expect(outcome == .success(Receipt.text))
        #expect(ContinuousClock.now - started < Self.promptly)
        let id = try #require(drafts.created.first?.requestID)
        #expect(drafts.read == [id, id, id])
        #expect(drafts.accepted.map(\.id) == [id])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(drafts.cancelled.isEmpty)
    }

    // MARK: - Cancelling and signing out

    @Test func cancellingWhileTheServerAnswersWithdrawsTheRequestAndReleasesNothing() async {
        let drafts = SlowDrafts()
        drafts.createDelay = .zero
        let writer = writer(drafts)
        let writing = Task { await writer.write(cue: words, body: body) }
        await spin { drafts.reads > 0 }
        writer.cancel()
        #expect(await writing.value == .failure(.withdrawn))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(drafts.cancelled == [drafts.created].compactMap { $0 })
        #expect(drafts.accepted.isEmpty)
    }

    @Test func cancellingDuringTheCreateCancelsTheRequestItNamed() async {
        let drafts = SlowDrafts()
        let writer = writer(drafts)
        let writing = Task { await writer.write(cue: words, body: body) }
        await spin { drafts.created != nil }
        writer.cancel()
        #expect(await writing.value == .failure(.withdrawn))
        try? await Task.sleep(for: .milliseconds(350))
        #expect(drafts.cancelled.contains(drafts.created!))
    }

    @Test func signingOutWhileTheServerAnswersWithdrawsTheRequest() async {
        let drafts = SlowDrafts()
        drafts.createDelay = .zero
        let writer = writer(drafts)
        let writing = Task { await writer.write(cue: words, body: body) }
        await spin { drafts.reads > 0 }
        writer.accountChanged(signedIn: false)
        #expect(await writing.value == .failure(.withdrawn))
        #expect(writer.availability == .signedOut)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(drafts.cancelled == [drafts.created].compactMap { $0 })
    }

    @Test func turningTheSwitchOffWhileTheServerAnswersWithdrawsTheRequest() async {
        let drafts = SlowDrafts()
        drafts.createDelay = .zero
        let writer = writer(drafts)
        let writing = Task { await writer.write(cue: words, body: body) }
        await spin { drafts.reads > 0 }
        writer.isEnabled = false
        #expect(await writing.value == .failure(.withdrawn))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(drafts.cancelled == [drafts.created].compactMap { $0 })
        // Off, nothing more is asked for.
        #expect(await writer.write(cue: words, body: body) == .failure(.withdrawn))
        #expect(drafts.cancelled.count == 1)
    }

    @Test func anOldAttemptEndingLateNeverForgetsTheNewRequest() async {
        let drafts = HeldDrafts()
        let writer = writer(drafts)
        let first = Task { await writer.write(cue: words, body: body) }
        await spin { drafts.created.count == 1 }
        writer.cancel()
        let second = Task { await writer.write(cue: words, body: body) }
        await spin { drafts.created.count == 2 }
        // The first attempt's create answers late, complete; it releases
        // nothing and forgets nothing of the second.
        drafts.finishFirst()
        #expect(await first.value == .failure(.withdrawn))
        writer.cancel()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(drafts.cancelled.contains(drafts.created[1]))
        drafts.finishSecond()
        #expect(await second.value == .failure(.withdrawn))
    }

    @Test func aCancelledCreatesLateReturnIsLoggedUnderItsOwnAttempt() async {
        let capture = LoggedLines()
        await AppLog.$composeLines.withValue(capture) {
            let drafts = HeldDrafts()
            let writer = writer(drafts)
            let first = Task { await writer.write(cue: words, body: body) }
            await spin { drafts.created.count == 1 }
            let firstStart = capture.all.first { $0.hasPrefix("request.create.started") }
            writer.cancel()
            let second = Task { await writer.write(cue: words, body: body) }
            await spin { drafts.created.count == 2 }
            let starts = capture.all.filter { $0.hasPrefix("request.create.started") }
            #expect(starts.count == 2)
            #expect(firstStart != starts.last)
            let firstAttempt = firstStart?.split(separator: " ").last.map(String.init) ?? "missing"
            let secondAttempt = starts.last?.split(separator: " ").last.map(String.init) ?? "missing"
            #expect(firstAttempt.hasPrefix("attempt="))
            #expect(secondAttempt.hasPrefix("attempt="))
            drafts.finishFirst()
            #expect(await first.value == .failure(.withdrawn))
            #expect(capture.all.contains("request.create.returned.cancelled \(firstAttempt)"))
            #expect(!capture.all.contains("request.create.received \(firstAttempt)"))
            drafts.finishSecond()
            #expect(await second.value == .success(Receipt.text))
            #expect(capture.all.contains("request.create.returned \(secondAttempt)"))
            #expect(capture.all.contains("request.create.received \(secondAttempt)"))
            #expect(capture.all.allSatisfy { !$0.contains(words) && !$0.contains(body.body) && !$0.contains(Receipt.text) })
        }
    }

    @Test(arguments: [(DraftRequestFailure.unauthorized, EmailWriter.Problem.signedOut),
                      (.disabled, .unavailable(.disabled)), (.unreachable, .request(.unreachable))])
    func aFailureEndsTheAttemptWithoutWaitingOnItsCancel(failure: DraftRequestFailure, problem: EmailWriter.Problem) async throws {
        // The cancel goes out and never answers; the words must not wait on
        // it, since near the limit its own transport timeout would come on
        // top of the 65 seconds.
        let drafts = CancelHeldDrafts(failure: failure)
        let writer = writer(drafts)
        let ended = Ended()
        let writing = Task {
            ended.outcome = await writer.write(cue: words, body: body)
        }
        await spin { drafts.cancelHeld && ended.outcome != nil }
        #expect(ended.outcome == .failure(problem))
        drafts.finishCancel()
        await writing.value
    }

    @Test func aFailedCancelKeepsTheOriginalFailure() async {
        let drafts = ScriptedDrafts(creates: [.failure(.disabled)], cancels: [.failure(.missing)])
        let writer = writer(drafts)
        #expect(await writer.write(cue: words, body: body) == .failure(.unavailable(.disabled)))
        // A cancel that fails for good is not sent again.
        await spin { drafts.cancelled.count == 1 }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(drafts.cancelled.count == 1)
    }

    // MARK: - What stands in the way before anything is sent

    @Test func aBuildWithoutABackendSaysSo() async {
        let writer = writer(nil)
        #expect(writer.availability == .notConfigured)
        #expect(!writer.isWanted)
        #expect(await writer.write(cue: words, body: body) == .failure(.notConfigured))
    }

    @Test func aSignedOutMacSaysSoUntilItSignsIn() async {
        let drafts = ScriptedDrafts()
        let writer = writer(drafts, signedIn: false)
        #expect(writer.availability == .signedOut)
        #expect(!writer.isWanted)
        #expect(await writer.write(cue: words, body: body) == .failure(.signedOut))
        #expect(drafts.created.isEmpty)
        writer.accountChanged(signedIn: true)
        #expect(writer.isWanted)
        #expect(await writer.write(cue: words, body: body) == .success(Receipt.text))
    }

    @Test func theSwitchOffIsNotWanted() {
        let writer = writer(ScriptedDrafts())
        writer.isEnabled = false
        #expect(!writer.isWanted)
        #expect(writer.availability == nil)
    }

    @Test func wordsOverTheBoundAreRefusedBeforeAnythingIsSent() async {
        let drafts = ScriptedDrafts()
        let outcome = await writer(drafts).write(cue: String(repeating: "a", count: WritingInputBounds.cue + 1), body: body)
        #expect(outcome == .failure(.input(.cueTooLong)))
        #expect(drafts.created.isEmpty)
    }

    @Test func theBodyIsBoundedBeforeItLeaves() async throws {
        let drafts = ScriptedDrafts()
        let long = EmailBody(bundleIdentifier: nil, body: String(repeating: "x", count: WritingInputBounds.observedThread + 100))
        _ = await writer(drafts).write(cue: words, body: long)
        #expect(try #require(drafts.created.first).compose.observedThread.unicodeScalars.count == WritingInputBounds.observedThread)
    }
}

@MainActor
private final class Ended {
    var outcome: Result<String, EmailWriter.Problem>?
}

/// A route whose create takes a while, for the scenarios about cancelling
/// and signing out before it answers.
@MainActor
final class SlowDrafts: DraftService {
    var created: UUID?
    var cancelled: [UUID] = []
    var accepted: [UUID] = []
    var reads = 0
    var createDelay: Duration = .milliseconds(200)
    var completeCreate = false

    nonisolated init() {}

    /// A stand-in has no accounts: every request goes to it.
    func forThisAccount() async throws -> any DraftService { self }
    func shown(_ requestID: UUID, revision: Int, recipients: [WritingRecipient]) async throws {}

    func create(_ input: WritingInput) async throws -> DraftReceipt {
        created = input.requestID
        try? await Task.sleep(for: createDelay)
        return completeCreate ? Receipt.complete(input.requestID, revision: input.revision) : Receipt.pending(input.requestID, input.revision)
    }

    func read(_ requestID: UUID) async throws -> DraftReceipt {
        reads += 1
        return Receipt.pending(requestID)
    }

    func cancel(_ requestID: UUID) async throws -> DraftReceipt {
        cancelled.append(requestID)
        return Receipt.make(requestID, status: .cancelled, reason: .cancelled)
    }

    func accept(_ requestID: UUID, revision: Int) async throws -> DraftReceipt {
        accepted.append(requestID)
        return Receipt.complete(requestID, revision: revision, accepted: true)
    }
}

/// A route whose create waits until the scenario finishes it, for two
/// requests in flight at once.
@MainActor
final class HeldDrafts: DraftService {
    var created: [UUID] = []
    var cancelled: [UUID] = []
    private var continuations: [CheckedContinuation<DraftReceipt, Never>] = []

    nonisolated init() {}

    /// A stand-in has no accounts: every request goes to it.
    func forThisAccount() async throws -> any DraftService { self }
    func shown(_ requestID: UUID, revision: Int, recipients: [WritingRecipient]) async throws {}

    func create(_ input: WritingInput) async throws -> DraftReceipt {
        created.append(input.requestID)
        return await withCheckedContinuation { continuations.append($0) }
    }

    func finishFirst() { continuations[0].resume(returning: Receipt.complete(created[0])) }
    func finishSecond() { continuations[1].resume(returning: Receipt.complete(created[1])) }
    func read(_ requestID: UUID) async throws -> DraftReceipt { Receipt.pending(requestID) }

    func cancel(_ requestID: UUID) async throws -> DraftReceipt {
        cancelled.append(requestID)
        return Receipt.make(requestID, status: .cancelled, reason: .cancelled)
    }

    func accept(_ requestID: UUID, revision: Int) async throws -> DraftReceipt {
        Receipt.complete(requestID, revision: revision, accepted: true)
    }
}

/// A route whose create fails, and whose first cancel waits until the
/// scenario finishes it, for what happens while that cancel is on its way.
@MainActor
final class CancelHeldDrafts: DraftService {
    private let failure: DraftRequestFailure
    private(set) var cancelHeld = false
    private var continuation: CheckedContinuation<Void, Never>?

    nonisolated init(failure: DraftRequestFailure) {
        self.failure = failure
    }

    /// A stand-in has no accounts: every request goes to it.
    func forThisAccount() async throws -> any DraftService { self }
    func shown(_ requestID: UUID, revision: Int, recipients: [WritingRecipient]) async throws {}

    func create(_ input: WritingInput) async throws -> DraftReceipt {
        throw failure
    }

    func read(_ requestID: UUID) async throws -> DraftReceipt { Receipt.pending(requestID) }

    func cancel(_ requestID: UUID) async throws -> DraftReceipt {
        if !cancelHeld {
            cancelHeld = true
            await withCheckedContinuation { continuation = $0 }
        }
        return Receipt.make(requestID, status: .cancelled, reason: .cancelled)
    }

    func finishCancel() {
        continuation?.resume()
        continuation = nil
    }

    func accept(_ requestID: UUID, revision: Int) async throws -> DraftReceipt {
        Receipt.complete(requestID, revision: revision, accepted: true)
    }
}
