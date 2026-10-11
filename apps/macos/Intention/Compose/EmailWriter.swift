import Foundation

/// A proposal a dictation may change: the parent of a regeneration, as
/// the writer needs it.
struct ProposalParent: Equatable, Sendable {
    let requestID: UUID
    let revision: Int
    let text: String
}

/// Writes one email at a time through the alpha backend's draft route, for
/// dictation or a reply proposal to put into the email body it was made
/// for. Every request carries the body as `ComposeAccess` read it and what
/// the window shows around it: the recipients and subject shown, the
/// thread's messages shown and, for a Gmail reply in the thread view, the
/// thread's id.
///
/// It answers three ways. `write` takes the person's finished words as
/// the cue, sends the request, polls it to its end, records acceptance and
/// answers with the accepted text or with why there is none. `propose`
/// asks for a reply proposal with the fixed cue and answers with the
/// complete draft unaccepted; `accept` records the person's acceptance of
/// it later and only then answers with its text. `revise` writes the
/// person's spoken change to a proposal as a regeneration from it and
/// answers with the accepted text, as `write` does. It never inserts:
/// dictation and the reply proposals do, with the guard from the body read
/// attached. Intention never sends mail.
///
/// Every answer of the route is a receipt; only `complete` carries text,
/// and only an accepted complete receipt's text goes into a field. No
/// email is asked for again by itself, whatever the reason: a failure, an
/// abstention or a timeout ends the attempt, and dictation then types the
/// person's words instead and says so. Only a poll, an acceptance or a
/// cancel the server could not answer this once
/// (`DraftRequestFailure.isTransient`) is sent again, for the same request
/// and within the limit, since the draft may still finish. Writing the
/// server reports as disabled or not configured is remembered, so later
/// dictations do not wait on a request that cannot succeed.
@MainActor
@Observable
final class EmailWriter {
    /// Why there is no email, in fixed names safe to log.
    enum Problem: Error, Equatable, Sendable {
        /// This build names no backend.
        case notConfigured
        case signedOut
        /// The server reports writing off or not configured: permanent
        /// until it is deployed differently.
        case unavailable(DraftRequestFailure)
        /// A request failed before the server finished it.
        case request(DraftRequestFailure)
        /// The server took the request and ended it without text.
        case abstained(DraftReason)
        /// The server took the draft back before it was accepted.
        case cancelled(DraftReason)
        /// The words or the body cannot make a request.
        case input(ComposeInputProblem)
        /// The server did not finish within Intention's own wait.
        case timedOut
        /// The person cancelled, or the Mac signed out, while the server
        /// was still answering.
        case withdrawn

        var isMailImportPending: Bool {
            if case .abstained(.mailImportPending) = self { return true }
            return false
        }
    }

    struct ProposalDiagnostics: Equatable, Sendable {
        enum FailureKind: String, CaseIterable, Sendable {
            case preflightFailed, accountFailed, createFailed, createTimedOut
            case pollFailed, pollTimedOut, serverAbstained, serverCancelled, serverInvalidResponse, acceptanceFailed, withdrawn
        }
        var failureKind: FailureKind?
        var retried = false
        /// Last failed HTTP response, including one preceding a client deadline.
        var lastHTTPStatusClass: String?
    }

    /// Owned by one call. Concurrent or superseded requests never share diagnostics.
    @MainActor private final class ProposalAttempt {
        var diagnostics = ProposalDiagnostics(failureKind: .preflightFailed) {
            didSet { diagnosed?(diagnostics) }
        }
        let diagnosed: ((ProposalDiagnostics) -> Void)?

        init(diagnosed: ((ProposalDiagnostics) -> Void)?) {
            self.diagnosed = diagnosed
        }
    }

    /// How long one email may take before the words are typed instead: the
    /// server's own deadline for a draft is 60 seconds, and its transport
    /// is given five more to stop. The limit bounds every wait on the way:
    /// each call (create, each poll, acceptance) races the time left, as
    /// does each sleep between polls, so a call stalled under the
    /// transport's own 30 second timeout (`AlphaClient`) ends the attempt
    /// at the limit. An answer later than this is dropped, never released
    /// or accepted, and the request is cancelled by its id without waiting
    /// for that cancel.
    static let requestLimit: Duration = .seconds(65)

    /// The longest wait before a call is made again after a transient
    /// failure, whatever `Retry-After` asks, so one long ask does not spend
    /// the time the draft has left.
    static let retryPauseLimit: Duration = .seconds(5)

    /// How many times a cancel is sent while each attempt fails for a
    /// transient reason. The words never wait on any of them.
    static let cancelTries = 3

    /// The Settings switch, "Write emails for me". Off, every dictation
    /// types the person's words, in an email body as anywhere else, and a
    /// request on its way is cancelled by its id, so nothing it answers is
    /// released.
    var isEnabled = true {
        didSet { if !isEnabled { cancel() } }
    }

    /// Read for each new input so Settings changes also reach proposals and revisions.
    @ObservationIgnored private let addSentWithIntention: () -> Bool
    @ObservationIgnored private let drafts: (any DraftService)?
    /// Observed, with `unavailable`, so the Settings row and the menu that
    /// show `availability` redraw when either changes.
    private var signedIn: Bool
    /// The wait between two polls of a dictated email. Transient retries
    /// also respect this interval, with a one-second floor (`retryPause`).
    @ObservationIgnored private let pollInterval: Duration
    /// The wait between two polls of a reply proposal. Shorter than a
    /// dictated email's to reduce the wait from completion to arrival.
    /// Transient failures still use the slower `retryPause`.
    @ObservationIgnored private let proposalPollInterval: Duration
    @ObservationIgnored private let requestLimit: Duration
    @ObservationIgnored private let clock: any WriterClock
    /// A server state that will not change by asking again. Forgotten
    /// when the account changes, or on relaunch.
    private var unavailable: DraftRequestFailure?
    /// The request on its way, named before it is sent with the route held
    /// to the account it is made under, so cancelling or signing out while
    /// the server is still answering can cancel it under that account.
    @ObservationIgnored private(set) var lastAcceptedRequestID: UUID?
    @ObservationIgnored var retentionScope: (() -> String?)?
    @ObservationIgnored var recordReceipt: ((UUID, Int, Date, String?) -> Void)?
    @ObservationIgnored var recordInsertion: ((UUID, String, String?) -> Void)?
    @ObservationIgnored private var pending: Pending?
    /// Changes with every request and cancel. Work started under an
    /// earlier value releases nothing.
    @ObservationIgnored private var session = 0
    @ObservationIgnored private var accountGeneration = 0
    @ObservationIgnored private var tracing: DraftAttempt?

    /// `drafts` nil is a build without a backend; tests script it.
    /// `clock` is the continuous clock outside the scenarios, which step
    /// their own.
    init(drafts: (any DraftService)?, signedIn: Bool, pollInterval: Duration = .seconds(1),
         proposalPollInterval: Duration = .milliseconds(250),
         requestLimit: Duration = EmailWriter.requestLimit, clock: any WriterClock = ContinuousWriterClock(),
         addSentWithIntention: @escaping () -> Bool = { false }) {
        self.drafts = drafts
        self.addSentWithIntention = addSentWithIntention
        self.signedIn = signedIn
        self.pollInterval = pollInterval
        self.proposalPollInterval = proposalPollInterval
        self.requestLimit = requestLimit
        self.clock = clock
    }

    private func beginTrace() -> DraftAttempt {
        tracing?.cancel()
        let trace = DraftAttempt { AppLog.compose($0, attempt: $1) }
        tracing = trace
        return trace
    }

    /// Whether an email could be written now, and if not why.
    var availability: Problem? {
        if drafts == nil { return .notConfigured }
        if !signedIn { return .signedOut }
        if let unavailable { return .unavailable(unavailable) }
        return nil
    }

    /// Whether dictation into an email body should ask for an email at
    /// all: the switch is on and this Mac has a backend and an account.
    /// Writing the server has reported unavailable still counts, so the
    /// person is told their words were typed instead of an email; dictation
    /// reads `availability` as well, and leaves the body's text unread
    /// when nothing could be written from it.
    var isWanted: Bool { isEnabled && drafts != nil && signedIn }

    /// This Mac signed in, signed out or had its key refused. A request on
    /// its way for the earlier account is dropped, and a server state
    /// remembered under it is forgotten.
    func accountChanged(signedIn: Bool) {
        self.signedIn = signedIn
        accountGeneration += 1
        unavailable = nil
        proposalRoute = nil
        proposalTrace = nil
        cancel()
    }

    /// Drops the request on its way, if there is one, and cancels it with
    /// the server by its id, so its text is never released.
    func cancel() {
        session += 1
        tracing?.cancel()
        guard let pending else { return }
        self.pending = nil
        withdraw(pending.id, through: pending.route, until: pending.deadline, trace: pending.trace)
    }

    /// Asks for the email from the body and the person's words, and waits
    /// for it within `requestLimit`. The text comes back only from a
    /// complete receipt the server has recorded as accepted. A second ask
    /// while one is on its way ends the first and cancels it with the
    /// server by its id, so no draft runs on for nobody: setup's reply
    /// page and a dictation into Gmail share this writer.
    func write(cue: String, body observation: EmailBody) async -> Result<String, Problem> {
        guard isEnabled else { return .failure(.withdrawn) }
        if let availability { return .failure(availability) }
        guard let drafts else { return .failure(.notConfigured) }
        if pending != nil { cancel() }
        let input: WritingInput
        do {
            input = try ComposeInput.make(observation, cue: cue, requestID: UUID(), addSentWithIntention: addSentWithIntention())
        } catch let reason as ComposeInputProblem {
            return .failure(.input(reason))
        } catch {
            return .failure(.input(.tooLarge))
        }
        session += 1
        let session = session
        let trace = beginTrace()
        defer { if tracing === trace { tracing = nil } }
        let outcome = await attempt(input, drafts, session: session, trace: trace)
        // Cancelled, or another account since: whatever came is not released.
        guard self.session == session else { return .failure(.withdrawn) }
        switch outcome {
        case let .success(text):
            trace.log("written")
            return .success(text)
        case let .failure(problem):
            trace.log("failed.\(Self.name(problem))")
            return .failure(problem)
        }
    }

    /// A proposal the server completed and has not accepted: its id,
    /// revision and text, kept by `ReplyProposalController` until the person
    /// accepts it, changes it by speaking, or lets it go.
    struct Proposal: Equatable, Sendable {
        let id: UUID
        let revision: Int
        let text: String
        /// The persisted request controls receipt decoration, even after Settings changes.
        var addSentWithIntention = false
        var checksThreadParticipants = false
        /// Preserve the request's recipients even when a reply later binds
        /// this proposal to its own To/Cc addresses and holds it again.
        var requestedWithoutRecipients = false
        var retentionScope: String? = nil
        var diagnostics = ProposalDiagnostics()
    }

    /// The fixed cue of a proposal; the server's prompt says it is a
    /// placeholder, not the person's words.
    static let proposalCue = "Reply to this thread"

    /// The route a proposal was made through, held to the account it was
    /// made under, so its accept reaches the same account.
    @ObservationIgnored private var proposalRoute: (any DraftService)?
    @ObservationIgnored private var proposalTrace: DraftAttempt?

    /// Asks for a reply proposal from the body and what the window shows
    /// around it, with the fixed cue, and waits for it to complete within
    /// `requestLimit`, polling `proposalPollInterval` apart. The text comes
    /// back unaccepted: the server records acceptance only when the person
    /// takes it (`accept`). A second ask while one is on its way ends the
    /// first.
    func propose(body observation: EmailBody, diagnosed: ((ProposalDiagnostics) -> Void)? = nil,
                 requested: ((UUID, String?) -> Void)? = nil) async -> Result<Proposal, Problem> {
        let diagnosis = ProposalAttempt(diagnosed: diagnosed)
        defer { diagnosed?(diagnosis.diagnostics) }
        func failed(_ problem: Problem) -> Result<Proposal, Problem> {
            if problem == .withdrawn { diagnosis.diagnostics.failureKind = .withdrawn }
            if let status = problem.httpStatusClass { diagnosis.diagnostics.lastHTTPStatusClass = status }
            return .failure(problem)
        }
        guard isEnabled else { return failed(.withdrawn) }
        if let availability { return failed(availability) }
        guard let drafts else { return failed(.notConfigured) }
        let input: WritingInput
        do {
            input = try ComposeInput.make(observation, cue: Self.proposalCue, requestID: UUID(), proposal: true, addSentWithIntention: addSentWithIntention())
        } catch let reason as ComposeInputProblem {
            return failed(.input(reason))
        } catch {
            return failed(.input(.tooLarge))
        }
        session += 1
        let session = session
        let trace = beginTrace()
        defer { if tracing === trace { tracing = nil } }
        let scope = retentionScope?()
        requested?(input.requestID, scope)
        let outcome = await complete(input, drafts, session: session, trace: trace, polling: proposalPollInterval, diagnosis: diagnosis)
        guard self.session == session else { return failed(.withdrawn) }
        switch outcome {
        case let .success(completed):
            forget(input.requestID)
            guard let text = completed.receipt.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                diagnosis.diagnostics.failureKind = .serverInvalidResponse
                return failed(.request(.invalidResponse))
            }
            proposalRoute = completed.route
            proposalTrace = trace
            trace.log("proposed")
            return .success(Proposal(id: input.requestID, revision: completed.receipt.revision, text: text,
                                     addSentWithIntention: input.compose.addSentWithIntention,
                                     checksThreadParticipants: completed.receipt.shownRecipientCheck == "thread_participants_v1",
                                     requestedWithoutRecipients: input.compose.recipients.isEmpty, retentionScope: scope,
                                     diagnostics: diagnosis.diagnostics))
        case let .failure(problem):
            trace.log("proposal.failed.\(Self.name(problem))")
            return failed(problem)
        }
    }

    /// Records the person's acceptance of a proposal with the server, which
    /// revalidates the device and the draft's sources and releases the text
    /// only then, within `limit` from now and never longer than
    /// `requestLimit`: the reply proposal passes what is left of the
    /// deadline it set when the person accepted. An accept the server could
    /// not answer this once is sent again, as a dictated email's is.
    func accept(_ proposal: Proposal, within limit: Duration = EmailWriter.requestLimit) async -> Result<String, Problem> {
        guard isEnabled else { return .failure(.withdrawn) }
        if let availability { return .failure(availability) }
        guard let route = proposalRoute else { return .failure(.notConfigured) }
        session += 1
        let session = session
        let trace = beginTrace()
        defer { if tracing === trace { tracing = nil } }
        let scope = retentionScope?()
        let deadline = clock.now + min(limit, requestLimit)
        pending = Pending(id: proposal.id, route: route, deadline: deadline, trace: trace)
        do {
            let accepted = try await persisting(deadline, session: session, trace: trace) { try await Self.traced("accept", trace: trace) { try await route.accept(proposal.id, revision: proposal.revision) } }
            forget(proposal.id)
            guard self.session == session else { return .failure(.withdrawn) }
            guard accepted.requestID == proposal.id else { throw DraftRequestFailure.invalidResponse }
            guard accepted.status == .complete, accepted.accepted, let text = accepted.text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(accepted.reason.map(Problem.cancelled) ?? .request(.conflict))
            }
            recordReceipt?(accepted.requestID, accepted.voiceExamples, Date(), scope)
            trace.log("proposal.accepted")
            lastAcceptedRequestID = proposal.id
            return .success(text)
        } catch {
            guard self.session == session else { return .failure(.withdrawn) }
            forget(proposal.id)
            if error is PastDeadline {
                trace.log("timedOut")
                return .failure(.timedOut)
            }
            return .failure(describe(error))
        }
    }

    /// An acceptance record has its own lifetime. Later proposals and
    /// dictations cannot cancel its retries or redirect it to another account.
    /// The observer receives retry snapshots and, at completion, any terminal
    /// problem, including an answer later than the caller's bounded wait.
    func recordAcceptance(_ proposal: Proposal, diagnosed: ((ProposalDiagnostics, Problem?) -> Void)? = nil) -> Task<Result<String, Problem>, Never> {
        let route = proposalRoute, generation = accountGeneration
        let scope = retentionScope?()
        return Task {
            var diagnostics = proposal.diagnostics
            var terminalFailure: Problem?
            defer { diagnosed?(diagnostics, terminalFailure) }
            func failed(_ problem: Problem) -> Result<String, Problem> {
                terminalFailure = problem
                diagnostics.failureKind = .acceptanceFailed
                return .failure(problem)
            }
            guard let route, self.isWanted else { return failed(.withdrawn) }
            let deadline = self.clock.now + self.requestLimit
            var attempted = false
            while self.accountGeneration == generation {
                do {
                    if attempted, self.clock.now < deadline {
                        diagnostics.retried = true
                        diagnosed?(diagnostics, nil)
                    }
                    attempted = true
                    let receipt = try await self.beforeDeadline(deadline) {
                        try await route.accept(proposal.id, revision: proposal.revision)
                    }
                    guard self.accountGeneration == generation else { return failed(.withdrawn) }
                    guard receipt.requestID == proposal.id, receipt.revision == proposal.revision,
                          receipt.status == .complete, receipt.accepted,
                          let text = receipt.text, Self.acceptedText(text, matches: proposal) else {
                        AppLog.compose("proposal.accept.recordRefused")
                        return failed(receipt.reason.map(Problem.cancelled) ?? .request(.conflict))
                    }
                    self.recordReceipt?(receipt.requestID, receipt.voiceExamples, Date(), scope)
                    AppLog.compose("proposal.accepted")
                    return .success(text)
                } catch let failure as DraftRequestFailure where failure.isTransient {
                    if let status = failure.httpStatusClass { diagnostics.lastHTTPStatusClass = status }
                    guard self.accountGeneration == generation else { return failed(.withdrawn) }
                    diagnosed?(diagnostics, nil)
                    AppLog.compose("proposal.accept.retrying")
                    guard self.clock.now < deadline else { break }
                    try? await self.clock.sleep(until: min(self.clock.now + self.retryPause(after: failure), deadline))
                } catch {
                    guard self.accountGeneration == generation else { return failed(.withdrawn) }
                    AppLog.compose("proposal.accept.recordFailed")
                    return failed(error is PastDeadline ? .timedOut : self.describe(error))
                }
            }
            return failed(.withdrawn)
        }
    }

    /// Acceptance may append the server's terminal machine footer. Compare the
    /// original body bytes, never the footer renderer's normalized display text.
    private static func acceptedText(_ text: String, matches proposal: Proposal) -> Bool {
        if text.utf8.elementsEqual(proposal.text.utf8) { return true }
        guard proposal.addSentWithIntention, EmailFooter(text) != nil,
              let separator = text.utf8.lastIndex(of: 0x0A) else { return false }

        // The server removes machine-footer lines, even quoted ones, before
        // appending. That is outside this append-only exception; refuse it.
        let hasShownFooter = proposal.text.components(separatedBy: "\n").contains { line in
            let unquoted = line.drop { $0 == " " || $0 == "\t" || $0 == ">" }
            return EmailFooter(String(unquoted).trimmingCharacters(in: CharacterSet(charactersIn: " \t\r"))) != nil
        }
        guard !hasShownFooter else { return false }

        // Deliberately support only ASCII space and U+0009...U+000D from
        // Python rstrip(). Other trailing whitespace is outside this exception.
        var body = Array(proposal.text.utf8)
        while let last = body.last, last == 0x20 || (0x09...0x0D).contains(last) {
            body.removeLast()
        }
        if let last = String(decoding: body, as: UTF8.self).unicodeScalars.last,
           last.properties.isWhitespace || (0x1C...0x1F).contains(last.value) { return false }
        body.append(contentsOf: [0x0A, 0x0A])
        return text.utf8[...separator].elementsEqual(body)
    }

    /// A timeout ends only this wait; the same acceptance keeps recording.
    func acceptanceAnswer(_ recording: Task<Result<String, Problem>, Never>, within limit: Duration) async -> Result<String, Problem>? {
        let result = await race({ await recording.value }, until: clock.now + limit, on: clock)
        if case let .success(answer) = result { return answer }
        return nil
    }

    /// Writes the person's spoken change to a proposal: a regeneration from
    /// the proposal as its parent, with the words as the instruction and
    /// the cue, polled and accepted as a dictated email is, so the text goes
    /// in directly.
    func revise(_ parent: ProposalParent, words: String, body observation: EmailBody) async -> Result<String, Problem> {
        guard isEnabled else { return .failure(.withdrawn) }
        if let availability { return .failure(availability) }
        guard let drafts else { return .failure(.notConfigured) }
        let input: WritingInput
        do {
            let regeneration = WritingRegeneration(parentRequestID: parent.requestID, parentRevision: parent.revision,
                                                   editedDraft: parent.text, instruction: words, origin: .generated)
            input = try ComposeInput.make(observation, cue: words, requestID: UUID(), revision: parent.revision + 1,
                                          regeneration: regeneration, addSentWithIntention: addSentWithIntention())
        } catch let reason as ComposeInputProblem {
            return .failure(.input(reason))
        } catch {
            return .failure(.input(.tooLarge))
        }
        session += 1
        let session = session
        let trace = beginTrace()
        defer { if tracing === trace { tracing = nil } }
        let outcome = await attempt(input, drafts, session: session, trace: trace)
        guard self.session == session else { return .failure(.withdrawn) }
        switch outcome {
        case let .success(text):
            trace.log("revised")
            return .success(text)
        case let .failure(problem):
            trace.log("failed.\(Self.name(problem))")
            return .failure(problem)
        }
    }

    /// Read through the proposal's account without changing the active writing session.
    /// A transient failure says nothing about whether a held card is still valid.
    func proposalRetired(_ proposal: Proposal) async -> Bool {
        guard let route = proposalRoute else { return false }
        let generation = accountGeneration
        do {
            let receipt = try await beforeDeadline(clock.now + .seconds(5)) { try await route.read(proposal.id) }
            guard accountGeneration == generation, receipt.requestID == proposal.id else { return false }
            return receipt.status == .cancelled || receipt.status == .abstained || receipt.accepted
        } catch DraftRequestFailure.missing {
            return accountGeneration == generation
        } catch {
            return false
        }
    }

    /// Drops the proposal request on its way, if there is one, and cancels
    /// it with the server by its id.
    func cancelProposal() { cancel() }

    /// Whether the server admits a proposal's card to the screen.
    enum Admission: Equatable, Sendable {
        case admitted
        /// The account has been shown its day's count of proposals.
        case limit
        /// It could not be recorded, even once more after a pause.
        case unreported
    }

    /// Both admission tries and their pause share six seconds. Admission
    /// should be quick once the draft is ready; a slower answer would make
    /// the card arrive long after the person started their reply.
    static let admissionPause: Duration = .milliseconds(300)
    static let admissionLimit: Duration = .seconds(6)

    /// Asks the server to admit `proposal`'s card, through the route it
    /// was made through: `POST /shown` with its revision, which answers 204
    /// when it may show and 409 `proposal_limit` past the account's day's
    /// count. Other failures are tried once more after `admissionPause`,
    /// within one `admissionLimit` deadline. Expiry returns unreported and
    /// keeps the card hidden, even if a stalled call later succeeds. It
    /// changes no session or pending request and never signs out. A participant
    /// refusal calls `recipientsRefused` once; the controller decides whether
    /// to request from the reply.
    func admit(_ proposal: Proposal, recipients: [WritingRecipient] = [],
               recipientsRefused: @MainActor @Sendable () -> Void = {}) async -> Admission {
        guard let route = proposalRoute, let trace = proposalTrace else { return .unreported }
        let deadline = clock.now + Self.admissionLimit
        for tried in 1...2 {
            do {
                try await beforeDeadline(deadline) { try await Self.traced("shown", trace: trace) { try await route.shown(proposal.id, revision: proposal.revision, recipients: recipients) } }
                return .admitted
            } catch DraftRequestFailure.recipientsOutsideThread {
                recipientsRefused()
                return .unreported
            } catch DraftRequestFailure.proposalLimit {
                return .limit
            } catch {
                guard tried == 1, !Task.isCancelled, clock.now < deadline else { break }
                try? await clock.sleep(until: min(clock.now + Self.admissionPause, deadline))
            }
        }
        return .unreported
    }

    /// A request the server has finished, with the route it went through
    /// and the limit it had.
    private struct Completed {
        let receipt: DraftReceipt
        let route: any DraftService
        let deadline: Duration
    }

    /// Sends one request and polls it to its end, `pollInterval` apart; then
    /// records acceptance, since the server revalidates the device and the
    /// draft's sources there and releases text only to an accepted draft.
    /// A poll or the acceptance that fails for a transient reason is made
    /// again (`persisting`). Every call and every sleep between polls ends
    /// by `requestLimit` (`beforeDeadline`): past it the request is withdrawn without waiting
    /// on the server's answer to the cancel, and whatever the stalled call
    /// answers later is dropped. The request is named in `pending` before
    /// it is sent, so cancelling or signing out while the server is still
    /// answering can cancel it, after which the polling stops; a request
    /// that fails on the way is cancelled too, since the server may hold it.
    /// Every call goes through the route held to the account signed in when
    /// the attempt began, so each cancel, on any path, reaches the request
    /// under the account that made it.
    private func attempt(_ input: WritingInput, _ route: any DraftService, session: Int, trace: DraftAttempt) async -> Result<String, Problem> {
        lastAcceptedRequestID = nil
        let scope = retentionScope?()
        let completed: Completed
        switch await complete(input, route, session: session, trace: trace, polling: pollInterval) {
        case let .success(done): completed = done
        case let .failure(problem): return .failure(problem)
        }
        let id = input.requestID
        let drafts = completed.route
        let deadline = completed.deadline
        do {
            let revision = completed.receipt.revision
            // Accepting the same revision again only records it again, so
            // an acceptance the server could not answer is sent again too.
            let accepted = try await persisting(deadline, session: session, trace: trace) { try await Self.traced("accept", trace: trace) { try await drafts.accept(id, revision: revision) } }
            forget(id)
            guard self.session == session else { return .failure(.withdrawn) }
            guard accepted.requestID == id else { throw DraftRequestFailure.invalidResponse }
            guard accepted.status == .complete, accepted.accepted, let text = accepted.text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // Taken back between the answer and the acceptance.
                return .failure(accepted.reason.map(Problem.cancelled) ?? .request(.conflict))
            }
            recordReceipt?(accepted.requestID, accepted.voiceExamples, Date(), scope)
            lastAcceptedRequestID = id
            return .success(text)
        } catch {
            guard self.session == session else { return .failure(.withdrawn) }
            forget(id)
            withdraw(id, through: drafts, until: deadline, trace: trace)
            if error is PastDeadline {
                trace.log("timedOut")
                return .failure(.timedOut)
            }
            return .failure(describe(error))
        }
    }

    /// The first part of an attempt: the request sent and polled to a
    /// terminal receipt within the limit, `interval` between polls, with
    /// the complete receipt left unaccepted and still named in `pending`,
    /// so the caller's accept or cancel reaches it. A poll that fails for a
    /// transient reason waits `retryPause`, whatever `interval` is.
    private func complete(_ input: WritingInput, _ route: any DraftService, session: Int, trace: DraftAttempt,
                          polling interval: Duration, diagnosis: ProposalAttempt? = nil) async -> Result<Completed, Problem> {
        let deadline = clock.now + requestLimit
        let id = input.requestID
        let drafts: any DraftService
        diagnosis?.diagnostics.failureKind = .accountFailed
        do {
            trace.log("request.account.started")
            drafts = try await route.forThisAccount()
            trace.log("request.account.returned", returned: true)
        } catch {
            guard self.session == session else { return .failure(.withdrawn) }
            return .failure(describe(error))
        }
        guard self.session == session else { return .failure(.withdrawn) }
        pending = Pending(id: id, route: drafts, deadline: deadline, trace: trace)
        diagnosis?.diagnostics.failureKind = .createFailed
        do {
            let create: @Sendable () async throws -> DraftReceipt = {
                try await Self.traced("create", trace: trace) { try await drafts.create(input) }
            }
            // Proposal creation is idempotent for this exact input and request ID.
            // A lost response may already have started the writer on the server.
            var receipt = if input.compose.proposal {
                try await persisting(deadline, session: session, trace: trace, diagnosis: diagnosis, create)
            } else {
                try await beforeDeadline(deadline, create)
            }
            guard self.session == session else { return .failure(.withdrawn) }
            trace.log("request.create.received")
            // Every receipt must be for this request; one for another is
            // no answer at all.
            guard receipt.requestID == id else { throw DraftRequestFailure.invalidResponse }
            while !receipt.isTerminal {
                diagnosis?.diagnostics.failureKind = .pollFailed
                trace.log("request.poll.scheduled")
                try await clock.sleep(until: min(clock.now + interval, deadline))
                trace.log("request.poll.due")
                guard self.session == session else { return .failure(.withdrawn) }
                receipt = try await persisting(deadline, session: session, trace: trace, diagnosis: diagnosis) { try await Self.traced("poll", trace: trace) { try await drafts.read(id) } }
                guard self.session == session else { return .failure(.withdrawn) }
                trace.log("request.poll.received")
                guard receipt.requestID == id else { throw DraftRequestFailure.invalidResponse }
            }
            switch receipt.status {
            case .complete:
                diagnosis?.diagnostics.failureKind = nil
                return .success(Completed(receipt: receipt, route: drafts, deadline: deadline))
            case .abstained:
                diagnosis?.diagnostics.failureKind = .serverAbstained
                forget(id)
                return .failure(.abstained(receipt.reason ?? .unrecognized))
            case .cancelled:
                diagnosis?.diagnostics.failureKind = .serverCancelled
                forget(id)
                return .failure(.cancelled(receipt.reason ?? .unrecognized))
            case .pending:
                forget(id)
                return .failure(.timedOut)
            }
        } catch {
            // Cancelled or another account meanwhile: that cancel already
            // withdrew the request, and this failure says nothing about the
            // account now.
            guard self.session == session else { return .failure(.withdrawn) }
            // Past the limit, or failed on the way: the server may still
            // hold the request, so it is cancelled by its id, without the
            // words waiting on that cancel's own answer.
            forget(id)
            withdraw(id, through: drafts, until: deadline, trace: trace)
            if error is PastDeadline {
                diagnosis?.diagnostics.failureKind = diagnosis?.diagnostics.failureKind == .createFailed ? .createTimedOut : .pollTimedOut
                trace.log("timedOut")
                return .failure(.timedOut)
            }
            return .failure(describe(error))
        }
    }

    /// These fixed stage names and the unified log's timestamps separate
    /// transport waits from poll sleeps and main-actor delivery. The call's
    /// return is logged off the main actor; `received` is logged on it.
    private nonisolated static func traced<T: Sendable>(_ stage: String, trace: DraftAttempt,
                                                       _ call: @Sendable () async throws -> T) async throws -> T {
        trace.log("request.\(stage).started")
        do {
            let answer = try await DraftAttempt.$current.withValue(trace) { try await call() }
            trace.log("request.\(stage).returned", returned: true)
            return answer
        } catch {
            trace.log("request.\(stage).failed", returned: true)
            throw error
        }
    }

    /// Answers with `call`'s result, or throws `PastDeadline` once
    /// `deadline` passes, whichever comes first. The time is checked when
    /// the call would start and again here on the main actor when its
    /// answer is taken, so an answer or a failure taken at or past the
    /// deadline is dropped even when the timer racing it ran late.
    /// Cancelling the caller ends the wait with `CancellationError`.
    private func beforeDeadline<T: Sendable>(_ deadline: Duration,
                                             _ call: @escaping @Sendable () async throws -> T) async throws -> T {
        guard clock.now < deadline else { throw PastDeadline() }
        let outcome = await race(call, until: deadline, on: clock)
        if case let .failure(error) = outcome, error is CancellationError { throw error }
        guard clock.now < deadline else { throw PastDeadline() }
        return try outcome.get()
    }

    /// Answers with `call`'s result within `deadline`, making the call again
    /// after each failure that says nothing about the request
    /// (`DraftRequestFailure.isTransient`), as when a lock held elsewhere
    /// makes a poll or an acceptance 503 while the draft is unchanged, after
    /// `retryPause`. Any other failure, the limit passing, or a cancel or
    /// account change since the attempt began, ends it with that failure.
    private func persisting<T: Sendable>(_ deadline: Duration, session: Int, trace: DraftAttempt,
                                         diagnosis: ProposalAttempt? = nil,
                                         _ call: @escaping @Sendable () async throws -> T) async throws -> T {
        var attempted = false
        while true {
            do {
                if attempted, clock.now < deadline { diagnosis?.diagnostics.retried = true }
                attempted = true
                return try await beforeDeadline(deadline, call)
            } catch let failure as DraftRequestFailure where failure.isTransient && self.session == session {
                if let status = failure.httpStatusClass { diagnosis?.diagnostics.lastHTTPStatusClass = status }
                trace.log("retrying.\(failure.name)")
                try await clock.sleep(until: min(clock.now + retryPause(after: failure), deadline))
                guard self.session == session else { throw failure }
            }
        }
    }

    /// Clears `pending` only while it still names this attempt, so an
    /// older attempt ending late never forgets a newer request, which a
    /// cancel must still reach.
    private func forget(_ requestID: UUID) {
        if pending?.id == requestID { pending = nil }
    }

    /// Cancels `requestID` with the server through the route held to the
    /// account that made it, as far as it can be reached; nothing is
    /// released after a cancel, whatever it answers, and its refusal signs
    /// nobody out. A cancel that fails for a transient reason is sent again
    /// after the same pause as a poll, up to `cancelTries` in all and only
    /// while the next try would go out before the email's `deadline`. The
    /// first cancel goes out whenever it is called, a timeout's after the
    /// limit included; no cancel is sent again after it.
    /// The cancels run in a task of their own that nothing waits on.
    private func withdraw(_ requestID: UUID, through drafts: any DraftService, until deadline: Duration, trace: DraftAttempt) {
        let clock = clock
        Task {
            for tried in 1...Self.cancelTries {
                do {
                    _ = try await Self.traced("cancel", trace: trace) { try await drafts.cancel(requestID) }
                    return
                } catch let failure as DraftRequestFailure where failure.isTransient && tried < Self.cancelTries {
                    let next = clock.now + retryPause(after: failure)
                    guard next < deadline else { return }
                    try? await clock.sleep(until: next)
                } catch {
                    return
                }
            }
        }
        trace.log("cancelled")
    }

    /// How long to wait before a call is made again after a transient
    /// failure: at least one second, a dictated email's poll interval, or
    /// the server's `Retry-After`, whichever is longest, capped by
    /// `retryPauseLimit`. Faster proposal polling must not increase the
    /// request rate when the server is busy or unreachable.
    private func retryPause(after failure: DraftRequestFailure) -> Duration {
        min(max(.seconds(1), pollInterval, .seconds(failure.retryAfter ?? 0)), Self.retryPauseLimit)
    }

    /// A failed call of the attempt still running as the problem it is; a
    /// refused key signs the Mac out here as well, and a permanent server
    /// state is remembered.
    private func describe(_ error: Error) -> Problem {
        if let refused = error as? RefusedKey {
            refused.report()
            signedIn = false
            return .signedOut
        }
        guard let failure = error as? DraftRequestFailure else { return .request(.unreachable) }
        switch failure {
        case .signedOut, .unauthorized:
            signedIn = false
            return .signedOut
        case _ where failure.isPermanent:
            unavailable = failure
            return .unavailable(failure)
        default:
            return .request(failure)
        }
    }

    /// A problem as a fixed name, for the log.
    static func name(_ problem: Problem) -> String {
        switch problem {
        case .notConfigured: "notConfigured"
        case .signedOut: "signedOut"
        case let .unavailable(failure): "unavailable.\(failure.name)"
        case let .request(failure): "request.\(failure.name)"
        case let .abstained(reason): "abstained.\(reason.rawValue)"
        case let .cancelled(reason): "cancelled.\(reason.rawValue)"
        case let .input(reason): "input.\(reason)"
        case .timedOut: "timedOut"
        case .withdrawn: "withdrawn"
        }
    }
}

extension EmailWriter.Problem {
    static func permitsTelemetryName(_ value: String) -> Bool {
        let requestNames = ["signedOut", "unauthorized", "missing", "conflict", "proposalLimit", "recipientsOutsideThread",
                            "invalidInput", "excluded", "tooLarge", "busy", "disabled", "notConfigured",
                            "mailPolicyUnconfigured", "storageUnavailable", "unreachable", "invalidResponse", "server"]
        let names = ["notConfigured", "signedOut", "timedOut", "withdrawn", "input.cueBlank", "input.cueTooLong", "input.tooLarge"]
            + requestNames.flatMap { ["request.\($0)", "unavailable.\($0)"] }
            + DraftReason.allCases.flatMap { ["abstained.\($0.rawValue)", "cancelled.\($0.rawValue)"] }
        return names.contains(value)
    }

    /// Closed names only. An HTTP response contributes its class, never its body.
    var telemetryName: String {
        switch self {
        case .notConfigured: "notConfigured"
        case .signedOut: "signedOut"
        case .unavailable(let failure): "unavailable.\(failure.telemetryName)"
        case .request(let failure): "request.\(failure.telemetryName)"
        case .abstained(let reason): "abstained.\(reason.rawValue)"
        case .cancelled(let reason): "cancelled.\(reason.rawValue)"
        case .input(let reason): "input.\(reason)"
        case .timedOut: "timedOut"
        case .withdrawn: "withdrawn"
        }
    }

    var httpStatusClass: String? {
        switch self {
        case .unavailable(let failure), .request(let failure): failure.httpStatusClass
        default: nil
        }
    }
}

private extension DraftRequestFailure {
    var telemetryName: String {
        if case .server = self { return "server" }
        return name
    }

    var httpStatusClass: String? {
        switch self {
        case .unauthorized, .missing, .conflict, .proposalLimit, .recipientsOutsideThread, .invalidInput, .excluded, .tooLarge, .busy: "4xx"
        case .disabled, .notConfigured, .mailPolicyUnconfigured, .storageUnavailable: "5xx"
        case .server(let code): (100..<600).contains(code) ? "\(code / 100)xx" : nil
        case .signedOut, .unreachable, .invalidResponse: nil
        }
    }
}

/// The time the writer's limit is measured in, as the time since the
/// clock's own start.
protocol WriterClock: Sendable {
    var now: Duration { get }
    /// Throws `CancellationError` when the sleeping task is cancelled.
    func sleep(until: Duration) async throws
}

struct ContinuousWriterClock: WriterClock {
    private let start = ContinuousClock.now

    var now: Duration { ContinuousClock.now - start }

    func sleep(until: Duration) async throws {
        try await Task.sleep(until: start + until, clock: .continuous)
    }
}

/// A request on its way, the route held to the account it was made under,
/// and the end of its limit.
private struct Pending {
    let id: UUID
    let route: any DraftService
    let deadline: Duration
    let trace: DraftAttempt
}

/// A call that was still unanswered when the email's limit passed.
private struct PastDeadline: Error {}

/// The first of `call`'s result, the deadline on `clock` and a cancel of
/// the caller. The call runs in a task of its own and is cancelled when the
/// race ends, but is not waited for, since a stalled connection need not
/// stop when asked; its answer after that is dropped here, and it holds
/// nothing of the writer's, so it changes no state.
private func race<T: Sendable>(_ call: @escaping @Sendable () async throws -> T, until deadline: Duration,
                               on clock: any WriterClock) async -> Result<T, Error> {
    let race = Race<T>()
    do {
        return .success(try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.wait(continuation)
                race.run(Task {
                    do { race.finish(.success(try await call())) } catch { race.finish(.failure(error)) }
                })
                race.run(Task {
                    try? await clock.sleep(until: deadline)
                    race.finish(.failure(PastDeadline()))
                })
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        })
    } catch {
        return .failure(error)
    }
}

/// The first of a call, the deadline and a cancel to finish, delivered
/// once; the others are dropped. Its tasks are cancelled when it finishes.
private final class Race<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?
    private var tasks: [Task<Void, Never>] = []

    func wait(_ continuation: CheckedContinuation<T, Error>) {
        let early: Result<T, Error>? = lock.withLock {
            if result == nil { self.continuation = continuation }
            return result
        }
        if let early { continuation.resume(with: early) }
    }

    func run(_ task: Task<Void, Never>) {
        let finished = lock.withLock {
            if result == nil { tasks.append(task) }
            return result != nil
        }
        if finished { task.cancel() }
    }

    func finish(_ outcome: Result<T, Error>) {
        let (waiting, running): (CheckedContinuation<T, Error>?, [Task<Void, Never>]) = lock.withLock {
            guard result == nil else { return (nil, []) }
            result = outcome
            defer { continuation = nil; tasks = [] }
            return (continuation, tasks)
        }
        waiting?.resume(with: outcome)
        running.forEach { $0.cancel() }
    }
}
