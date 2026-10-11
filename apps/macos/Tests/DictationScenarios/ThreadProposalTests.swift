import AppKit
@testable import Dictation
import Testing

// Reply proposals asked for when a Gmail thread opens: the controller told
// of the thread as the thread watch reads it, the scripted field as the
// reply body in that thread, a draft route answered inside the process
// and a card that records what it is told. The reply's reads are wrapped,
// as in the reply proposal scenarios, to say the body sits in the thread
// with this id, these messages, this subject and this recipient. Expected
// values are written out by hand.
extension DictationScenarioTests {
    @Test func failedReplyAndThreadProposalsCarryTheWriterProblemToTelemetry() async throws {
        for fromThread in [false, true] {
            let route = ScriptedRoute(text: proposalDraft)
            route.onCreate = .fail(.invalidInput)
            let (p, ended, view) = await threadProposals(route)
            if fromThread { p.controller.threadOpened(view) }
            else { p.controller.observe(p.observation()) }
            await until { !ended.outcomes.isEmpty }
            #expect(ended.outcomes.last == .failed)
            let trace = try #require(ended.traces.last)
            #expect(trace.failure == .request(.invalidInput))
            #expect(trace.diagnostics.failureKind == .createFailed)
            #expect(!trace.diagnostics.retried)
            let timing = ProposalTiming(.failed, trace: trace)
            #expect(timing.failure?.telemetryName == "request.invalidInput")
            #expect(timing.failure?.httpStatusClass == "4xx")
        }
    }

    @Test func replyAndThreadTelemetryDistinguishPollingFromServerFailure() async throws {
        for fromThread in [false, true] {
            for serverAnswered in [false, true] {
                for retried in [false, true] {
                    let route = ScriptedRoute(text: proposalDraft)
                    route.firstReads = retried ? [.fail(.server(503))] : []
                    route.onRead = serverAnswered ? .abstain(.timeout) : .fail(.invalidInput)
                    let (p, ended, view) = await threadProposals(route)
                    if fromThread { p.controller.threadOpened(view) }
                    else { p.controller.observe(p.observation()) }
                    await until { !ended.outcomes.isEmpty }
                    let trace = try #require(ended.traces.last)
                    let timing = ProposalTiming(try #require(ended.outcomes.last), trace: trace)
                    #expect(timing.diagnostics.failureKind == (serverAnswered ? .serverAbstained : .pollFailed))
                    #expect(timing.failure == (serverAnswered ? .abstained(.timeout) : .request(.invalidInput)))
                    #expect(timing.diagnostics.retried == retried)
                }
            }
        }
    }

    @Test func cancellingARetriedReplyOrThreadKeepsItsDiagnostics() async throws {
        for source in ["reply", "thread", "adoptedThread"] {
            let route = ScriptedRoute(text: proposalDraft)
            route.firstReads = [.fail(.server(503))]
            route.onRead = .pending
            let (p, ended, view) = await threadProposals(route)
            if source != "reply" { p.controller.threadOpened(view) }
            else { p.controller.observe(p.observation()) }
            await until { route.read.count >= 2 }
            if source == "adoptedThread" {
                p.controller.observe(p.observation())
                await until { p.controller.isPending && p.controller.heldThreads.isEmpty }
            }
            p.controller.reset()
            await until { !ended.outcomes.isEmpty }
            #expect(ended.outcomes == [.cancelled])
            let trace = try #require(ended.traces.last)
            #expect(trace.failure == .withdrawn)
            #expect(trace.diagnostics.failureKind == .withdrawn)
            #expect(trace.diagnostics.retried)
            #expect(ProposalTiming(.cancelled, trace: trace).httpStatusClass == "5xx")
            try? await Task.sleep(for: .milliseconds(50))
            #expect(ended.outcomes == [.cancelled])
        }
    }

    static let threadSubject = "Venue options for the October offsite"
    static let threadSender = "priya@northwind.example"
    static let threadAccount = "sam@fabrikam.example"

    /// What the controller hands telemetry, in order.
    @MainActor
    final class Ended {
        var outcomes: [ProposalOutcome] = []
        var traces: [ProposalTrace] = []
    }

    /// Proposals whose reply reads as the reply in `view`'s thread, and
    /// that thread as the watch reads it open.
    private func threadProposals(_ route: ScriptedRoute, keep: Duration = .seconds(5 * 60), settle: Duration = .milliseconds(30),
                                 clock: any WriterClock = ContinuousWriterClock(), configure: (MockField) -> Void = { _ in }) async
        -> (Proposals, Ended, GmailThreadView) {
        let p = await proposals(nil, route: route, settle: settle, keep: keep, clock: clock, configure: configure)
        p.reader.subject = "Re: \(Self.threadSubject)"
        p.reader.recipients = [WritingRecipient(address: Self.threadSender, role: .to)]
        let ended = Ended()
        p.controller.ended = { outcome, trace in
            ended.outcomes.append(outcome)
            ended.traces.append(trace)
        }
        let started = try? await p.reader.inserter.readFocusedField().value.field.get().started
        let view = GmailThreadView(pid: p.pid, started: started, threadID: "18c2f4a9d0e1b3a2", subject: Self.threadSubject,
                                   thread: p.reader.thread, newestSender: Self.threadSender, account: Self.threadAccount)
        return (p, ended, view)
    }

    /// The same thread view with another id and messages, as another thread.
    private func otherThread(_ view: GmailThreadView, _ threadID: String) -> GmailThreadView {
        var other = view
        other.threadID = threadID
        other.thread = "Tomás Ortega\nCan you send the deck before Friday?"
        other.newestSender = "tomas@fabrikam.example"
        return other
    }

    /// Opens `view` and waits until its proposal has come and is held.
    private func openAndWait(_ p: Proposals, _ view: GmailThreadView) async {
        p.controller.threadOpened(view)
        await until { p.controller.heldThreads.contains { $0.key.threadID == view.threadID && !$0.pending } }
    }

    // MARK: Asking when the thread opens

    @Test func aThreadOpeningAsksOnceFromWhatItShowsAndAReopeningReusesIt() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, ended, view) = await threadProposals(route)
        await openAndWait(p, view)
        #expect(route.created.count == 1)
        let input = try #require(route.created.first)
        #expect(input.cue == "Reply to this thread")
        #expect(input.mode == .reply)
        #expect(input.compose.proposal)
        #expect(input.compose.threadID == "18c2f4a9d0e1b3a2")
        #expect(input.compose.subject == "Re: Venue options for the October offsite")
        #expect(input.compose.recipients.map(\.address) == ["priya@northwind.example"])
        #expect(input.compose.observedThread == "Priya Raman\nHi Sam, which venue do you prefer?")
        // Nothing of any field was read, nothing is on screen and nothing
        // was recorded as shown.
        #expect(p.reader.candidateReads == 0)
        #expect(p.reader.bodyReads == 0)
        #expect(!p.card.isShown)
        #expect(route.shownCalls.isEmpty)
        // Opened again within its keep time: no second request.
        p.controller.threadOpened(view)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(route.created.count == 1)
        #expect(ended.outcomes.isEmpty)
    }

    @Test func aReplyFocusedAfterTheAnswerCameShowsItWithNoRequest() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, ended, view) = await threadProposals(route)
        await openAndWait(p, view)
        p.controller.observe(p.observation())
        await until { p.card.isShown }
        #expect(route.created.count == 1)
        #expect(p.card.shown.first?.text == proposalDraft)
        // The reply's own read after its settle, then the check before the
        // card showed, after the server admitted it.
        #expect(p.reader.bodyReads == 2)
        #expect(route.shownCalls.count == 1)
        let id = try #require(route.created.first?.requestID)
        #expect(route.shownCalls.first?.id == id)
        #expect(route.shownCalls.first?.revision == 1)
        // Tab puts in the thread's proposal, accepted under its own id.
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { ended.outcomes.last == .inserted }
        #expect(route.accepted == [id])
        #expect(MockField.shared.text.hasPrefix(proposalDraft))
        let trace = try #require(ended.traces.last)
        #expect(trace.trigger == .thread)
        let replyFocused = try #require(trace.replyFocused)
        let opened = try #require(trace.opened)
        let shown = try #require(trace.shown)
        #expect(opened < replyFocused && replyFocused <= shown)
        #expect(route.shownCalls.count == 1)
    }

    @Test func aReplyFocusedBeforeTheAnswerCameShowsItOnArrival() async throws {
        let clock = SteppedClock()
        let route = ScriptedRoute(text: proposalDraft)
        let (p, _, view) = await threadProposals(route, clock: clock)
        route.hold(.create)
        p.controller.threadOpened(view)
        await route.whileHeld {
            p.controller.observe(p.observation())
            // Starting the read does not mean its answer has been adopted.
            await until { p.controller.isPending }
            #expect(p.reader.bodyReads == 1)
            #expect(!p.card.isShown)
        }
        await until { clock.waits.contains(.milliseconds(20)) }
        #expect(p.controller.isPending)
        clock.advance(to: .milliseconds(20))
        await until { p.card.isShown }
        #expect(route.created.count == 1)
        #expect(p.reader.bodyReads == 2)
        #expect(p.controller.heldThreads.isEmpty)
    }

    @Test func aHeldThreadProposalIsAdoptedWhenTheReplyRecipientMatchesItsSenderIgnoringCase() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, ended, original) = await threadProposals(route)
        var view = original
        view.newestSender = "PRIYA@Northwind.example"
        await openAndWait(p, view)
        let id = try #require(route.created.first?.requestID)
        #expect(route.created.first?.compose.recipients.map(\.address) == ["PRIYA@Northwind.example"])
        #expect(p.reader.recipients?.map(\.address) == ["priya@northwind.example"])
        p.controller.observe(p.observation())
        await until { p.card.isShown }
        #expect(route.created.count == 1)
        #expect(route.shownCalls.map(\.id) == [id])
        #expect(p.card.shown.first?.text == proposalDraft)
        #expect(p.controller.heldThreads.isEmpty)
        #expect(ended.outcomes.isEmpty)
    }

    @Test func aReplyAllWithAnAdditionalRecipientRefusesTheHeldThreadProposal() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, _, view) = await threadProposals(route)
        await openAndWait(p, view)
        p.reader.recipients = [WritingRecipient(address: Self.threadSender, role: .to),
                               WritingRecipient(address: "tomas@fabrikam.example", role: .to)]
        p.controller.observe(p.observation())
        await until { p.card.isShown }
        #expect(route.created.count == 2)
        #expect(route.created.last?.compose.recipients.map(\.address) == ["priya@northwind.example", "tomas@fabrikam.example"])
    }

    @Test func aShortcutOpeningReplyBeforeTheAnswerDoesNotOvertakeItsDraft() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, ended, view) = await threadProposals(route)
        route.hold(.create)
        p.controller.threadOpened(view)
        await route.whileHeld {
            // Gmail's R shortcut opens Reply before that body is bound.
            p.hold.received(HoldKey.Monitored(kind: .keyDown, keyCode: 15))
            p.controller.observe(p.observation())
            await until { p.controller.isPending }
            p.controller.observe(p.observation(edit: 1))
            #expect(p.controller.isPending)
            #expect(ended.outcomes.isEmpty)
        }
        await until { p.card.isShown }
        #expect(route.created.count == 1)
        #expect(route.cancelled.isEmpty)
        // A key after binding keeps the proposal when its snapshot is unchanged.
        await p.pressKey()
        p.controller.observe(p.observation(edit: 2))
        #expect(p.card.isShown)
        #expect(ended.outcomes.isEmpty)
    }

    @Test(arguments: [false, true])
    func aShortcutOpeningAHeldReplyDoesNotDiscardItsUntouchedDraft(reused: Bool) async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, ended, view) = await threadProposals(route)
        await openAndWait(p, view)
        if reused {
            p.controller.observe(p.observation())
            await until { p.card.isShown }
            // Another reply body binds the same held proposal on return.
            p.focusSearch(focus: 2)
        }
        p.hold.received(HoldKey.Monitored(kind: .keyDown, keyCode: 15))
        let focus = reused ? 3 : 1
        p.focusReply(focus: focus, element: reused ? 2 : 1)
        await until { p.card.isShown }
        let reads = p.reader.bodyReads
        // Gmail's notice changes the edit mark without changing the body.
        p.controller.observe(p.observation(focus: focus, edit: 1))
        #expect(p.reader.bodyReads == reads)
        #expect(p.card.isShown)
        #expect(ended.outcomes.isEmpty)
        #expect(route.created.count == 1)
        #expect(route.shownCalls.count == 1)
        await p.pressKey()
        p.controller.observe(p.observation(focus: focus, edit: 2))
        #expect(p.card.isShown)
        #expect(ended.outcomes.isEmpty)
    }

    @Test func aShortcutReturningToTheSameReplyDoesNotDiscardItsUntouchedDraft() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, ended, view) = await threadProposals(route)
        await openAndWait(p, view)
        p.controller.observe(p.observation())
        await until { p.card.isShown }
        p.focusSearch(focus: 2)
        p.hold.received(HoldKey.Monitored(kind: .keyDown, keyCode: 15))
        p.focusReply(focus: 3)
        await until { p.card.isShown }
        let reads = p.reader.bodyReads
        p.controller.observe(p.observation(focus: 3, edit: 1))
        #expect(p.reader.bodyReads == reads)
        #expect(p.card.isShown)
        #expect(ended.outcomes.isEmpty)
        #expect(route.created.count == 1)
        #expect(route.shownCalls.count == 1)
        await p.pressKey()
        p.controller.observe(p.observation(focus: 3, edit: 2))
        #expect(p.card.isShown)
        #expect(ended.outcomes.isEmpty)
    }

    @Test func anotherThreadCancelsTheRequestOnItsWayAndKeepsWhatCame() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, ended, view) = await threadProposals(route)
        await openAndWait(p, view)
        route.hold(.create)
        p.controller.threadOpened(otherThread(view, "18c2f4a9d0e1b3b7"))
        await route.whileHeld {
            p.controller.threadOpened(otherThread(view, "18c2f4a9d0e1b3c9"))
        }
        await until { route.cancelled.count == 1 }
        #expect(route.created.count == 3)
        #expect(route.cancelled == [route.created[1].requestID])
        #expect(ended.outcomes == [.cancelled])
        await until { p.controller.heldThreads.count == 2 && p.controller.heldThreads.allSatisfy { !$0.pending } }
        #expect(p.controller.heldThreads.map(\.key.threadID) == ["18c2f4a9d0e1b3a2", "18c2f4a9d0e1b3c9"])
        // The first thread's answer stands: back to it asks nothing.
        p.controller.threadOpened(view)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(route.created.count == 3)
    }

    @Test func aHeldAnswerIsLetGoOnceItsKeepTimePasses() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, ended, view) = await threadProposals(route, keep: .milliseconds(200))
        await openAndWait(p, view)
        try? await Task.sleep(for: .milliseconds(300))
        p.controller.threadOpened(view)
        await until { route.created.count == 2 }
        #expect(ended.outcomes == [.left])
        #expect(ended.traces.first?.trigger == .thread)
        #expect(ended.traces.first?.shown == nil)
        // A thread's answer no reply took is not kept in history.
        #expect(p.history.entries.isEmpty)
    }

    // MARK: Refusing at the reply

    @Test func aReplyWhoseThreadChangedAsksAfresh() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, ended, view) = await threadProposals(route)
        await openAndWait(p, view)
        p.reader.thread = "Priya Raman\nLakeside is free that week too.\n\nPriya Raman\nHi Sam, which venue do you prefer?"
        p.controller.observe(p.observation())
        await until { p.card.isShown }
        #expect(route.created.count == 2)
        #expect(route.created[1].compose.observedThread
            == "Priya Raman\nLakeside is free that week too.\n\nPriya Raman\nHi Sam, which venue do you prefer?")
        #expect(ended.outcomes == [.left])
        // The fresh request's read, and the check before the card showed.
        #expect(p.reader.bodyReads == 2)
    }

    @Test func aReplyToAnotherRecipientAsksAfresh() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, _, view) = await threadProposals(route)
        await openAndWait(p, view)
        p.reader.recipients = [WritingRecipient(address: "tomas@fabrikam.example", role: .to)]
        p.controller.observe(p.observation())
        await until { p.card.isShown }
        #expect(route.created.count == 2)
        #expect(route.created[1].compose.recipients.map(\.address) == ["tomas@fabrikam.example"])
    }

    @Test func aReplyWithTextInItsBodyTakesNothing() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, _, view) = await threadProposals(route)
        await openAndWait(p, view)
        MockField.shared.text = "Thanks,\n"
        MockField.shared.selection = FieldRange(location: 7, length: 0)
        p.controller.observe(p.observation())
        try? await Task.sleep(for: .milliseconds(250))
        #expect(!p.card.isShown)
        #expect(route.created.count == 1)
        #expect(route.shownCalls.isEmpty)
        // Still held for an untouched reply in the thread.
        #expect(p.controller.heldThreads.count == 1)
    }

    @Test func anUncertainSenderAsksTheServerWithoutGuessingARecipient() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, _, view) = await threadProposals(route)
        var uncertain = view
        uncertain.newestSender = nil
        uncertain.thread = "Priya Raman\nSend the details to sam@fabrikam.example"
        await openAndWait(p, uncertain)
        #expect(route.created.count == 1)
        #expect(route.created.first?.compose.recipients == [])
        #expect(route.created.first?.compose.observedThread == "Priya Raman\nSend the details to sam@fabrikam.example")
        #expect(p.controller.heldThreads.map(\.pending) == [false])
    }

    @Test(arguments: [false, true])
    func anUnknownSenderUsesTheHeldProposalOnlyWithParticipantAdmission(pending: Bool) async throws {
        let route = ScriptedRoute(text: proposalDraft)
        route.shownRecipientCheck = "thread_participants_v1"
        let (p, _, original) = await threadProposals(route)
        var view = original
        view.newestSender = nil
        if pending {
            route.hold(.create)
            p.controller.threadOpened(view)
            await route.whileHeld {
                p.controller.observe(p.observation())
                await until { p.controller.isPending }
            }
        } else {
            await openAndWait(p, view)
            p.controller.observe(p.observation())
        }
        await until { p.card.isShown }
        #expect(route.created.count == 1)
        #expect(route.created[0].compose.recipients.isEmpty)
        #expect(route.shownCalls.map(\.id) == [route.created[0].requestID])
        #expect(route.shownRecipients == [[WritingRecipient(address: "priya@northwind.example", role: .to)]])
    }

    @Test(arguments: [false, true])
    func anUnknownSenderOnAnOldServerAsksAfresh(pending: Bool) async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, _, original) = await threadProposals(route)
        var view = original
        view.newestSender = nil
        if pending {
            route.hold(.create)
            p.controller.threadOpened(view)
            await route.whileHeld {
                p.controller.observe(p.observation())
                await until { p.controller.isPending }
            }
        } else {
            await openAndWait(p, view)
            p.controller.observe(p.observation())
        }
        await until { p.card.isShown }
        #expect(route.created.count == 2)
        #expect(route.shownCalls.map(\.id) == [route.created[1].requestID])
        #expect(route.shownRecipients == [[]])
    }

    @Test(arguments: ["threadID", "messages", "subject"])
    func unknownRecipientsStillRequireTheSameThread(binding: String) async throws {
        let route = ScriptedRoute(text: proposalDraft)
        route.shownRecipientCheck = "thread_participants_v1"
        let (p, _, original) = await threadProposals(route)
        var view = original
        view.newestSender = nil
        await openAndWait(p, view)
        switch binding {
        case "threadID": p.reader.threadID = "18c2f4a9d0e1b3b7"
        case "messages": p.reader.thread = "Priya Raman\nThe venue is booked."
        case "subject": p.reader.subject = "Re: A different question"
        default: Issue.record("unexpected binding")
        }
        p.controller.observe(p.observation())
        await until { p.card.isShown }
        #expect(route.created.count == 2)
        #expect(route.shownCalls.map(\.id) == [route.created[1].requestID])
    }

    @Test(arguments: [false, true])
    func aCcChangeBeforeAdmissionSendsCurrentRecipientsAndRefusalUsesNoSlot(outsider: Bool) async throws {
        let route = ScriptedRoute(text: proposalDraft)
        route.shownRecipientCheck = "thread_participants_v1"
        route.onShown = outsider ? [.recipientsOutsideThread, nil] : [nil]
        let (p, _, original) = await threadProposals(route)
        var view = original
        view.newestSender = nil
        route.hold(.create)
        p.controller.threadOpened(view)
        await route.whileHeld {
            p.controller.observe(p.observation())
            await until { p.controller.isPending }
            p.reader.recipients = [WritingRecipient(address: Self.threadSender, role: .to),
                                   WritingRecipient(address: outsider ? "outsider@example.com" : "tomas@contoso.example", role: .cc)]
        }
        await until { p.card.isShown }
        #expect(route.shownRecipients.first == p.reader.recipients)
        #expect(route.created.count == (outsider ? 2 : 1))
        #expect(route.admittedCards == [route.created.last!.requestID])
        #expect(p.card.shown.count == 1)
        if outsider {
            #expect(route.created.last?.compose.recipients == p.reader.recipients)
            #expect(!route.admittedCards.contains(route.created[0].requestID))
        }
    }

    @Test(arguments: [false, true])
    func returningAfterAnInterruptedAdmissionReadKeepsTheProposal(heldAgain: Bool) async throws {
        let route = ScriptedRoute(text: proposalDraft)
        route.shownRecipientCheck = "thread_participants_v1"
        let (p, ended, original) = await threadProposals(route)
        var view = original
        view.newestSender = nil
        await openAndWait(p, view)
        var interrupted = false
        p.reader.beforeAnswer = { number in
            if number == 2 {
                p.focusSearch(focus: 2)
                interrupted = true
            }
        }
        p.controller.observe(p.observation())
        await until { interrupted }
        // Let the interrupted read finish before taking the proposal again.
        try await Task.sleep(for: .milliseconds(100))
        #expect(route.shownCalls.isEmpty)
        #expect(!p.card.isShown)
        if heldAgain {
            p.reader.inThread = false
            p.focusReply(focus: 3, element: 2)
            await until { p.controller.heldThreads.count == 1 }
            p.reader.inThread = true
        }
        p.focusReply(focus: 4)
        await until { p.card.isShown || !ended.outcomes.isEmpty }
        #expect(p.card.isShown)
        #expect(route.created.count == 1)
        #expect(route.shownCalls.map(\.id) == [route.created[0].requestID])
        #expect(route.shownRecipients == [[WritingRecipient(address: Self.threadSender, role: .to)]])
        #expect(ended.outcomes.isEmpty)
        p.controller.reset()
    }

    @Test(arguments: [false, true])
    func returningBeforeTheInterruptedAdmissionReadFinishesKeepsTheProposal(heldAgain: Bool) async throws {
        let route = ScriptedRoute(text: proposalDraft)
        route.shownRecipientCheck = "thread_participants_v1"
        let (p, ended, original) = await threadProposals(route)
        var view = original
        view.newestSender = nil
        await openAndWait(p, view)
        p.reader.beforeAnswer = { number in
            if number == 2 {
                p.focusSearch(focus: 2)
                if heldAgain {
                    p.reader.inThread = false
                    p.focusReply(focus: 3, element: 2)
                    await until { p.controller.heldThreads.count == 1 }
                    p.reader.inThread = true
                }
                p.focusReply(focus: 4)
                // The returning display check waits on the original read.
                if heldAgain {
                    await until { p.controller.isHidden && p.controller.heldThreads.isEmpty }
                } else {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
        p.controller.observe(p.observation())
        await until { p.card.isShown || !ended.outcomes.isEmpty }
        #expect(p.card.isShown)
        #expect(route.created.count == 1)
        #expect(route.shownCalls.map(\.id) == [route.created[0].requestID])
        #expect(ended.outcomes.isEmpty)
        p.controller.reset()
    }

    @Test(arguments: ["element", "threadID", "messages", "subject", "body"])
    func aBindingChangeBeforeAdmissionSkipsAdmissionAndReadsTheReplyAfresh(change: String) async throws {
        let route = ScriptedRoute(text: proposalDraft)
        route.shownRecipientCheck = "thread_participants_v1"
        let (p, ended, original) = await threadProposals(route)
        var view = original
        view.newestSender = nil
        route.hold(.create)
        p.controller.threadOpened(view)
        await route.whileHeld {
            p.controller.observe(p.observation())
            await until { p.controller.isPending }
            switch change {
            case "element": MockField.shared.focusedElement = 2
            case "threadID": p.reader.threadID = "18c2f4a9d0e1b3b7"
            case "messages": p.reader.thread = "Priya Raman\nThe venue is booked."
            case "subject": p.reader.subject = "Re: A different question"
            case "body": MockField.shared.text = "My own reply"
            default: Issue.record("unexpected binding")
            }
        }
        if change == "body" || change == "element" {
            await until { ended.outcomes == [.abstained] }
            #expect(route.created.count == 1)
            #expect(route.shownCalls.isEmpty)
            #expect(p.card.shown.isEmpty)
        } else {
            await until { p.card.isShown }
            #expect(route.created.count == 2)
            #expect(route.shownCalls.map(\.id) == [route.created[1].requestID])
            #expect(route.created.last?.compose.threadID == p.reader.threadID)
            #expect(ended.outcomes.isEmpty)
        }
        #expect(!route.admittedCards.contains(route.created[0].requestID))
        p.controller.reset()
    }

    @Test func aSecondBindingChangeAfterAdmissionEndsAfterOneFreshRequest() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, ended, view) = await threadProposals(route)
        await openAndWait(p, view)
        p.reader.beforeAnswer = { number in
            if number == 1 || number == 2 {
                p.reader.subject = number == 1 ? "Re: Updated offsite" : "Re: Another update"
            }
        }
        p.controller.observe(p.observation())
        await until { ended.outcomes == [.abstained] }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(route.created.count == 2)
        #expect(route.shownCalls.count == 2)
        #expect(p.card.shown.isEmpty)
    }

    @Test func unknownRecipientsSendBothToAndCcForAdmission() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        route.shownRecipientCheck = "thread_participants_v1"
        let (p, _, original) = await threadProposals(route)
        var view = original
        view.newestSender = nil
        await openAndWait(p, view)
        p.reader.recipients = [WritingRecipient(address: Self.threadSender, role: .to),
                               WritingRecipient(address: "tomas@contoso.example", role: .cc)]
        p.controller.observe(p.observation())
        await until { p.card.isShown }
        #expect(route.created.count == 1)
        #expect(route.shownRecipients == [[WritingRecipient(address: "priya@northwind.example", role: .to),
                                         WritingRecipient(address: "tomas@contoso.example", role: .cc)]])
    }

    @Test(arguments: [false, true])
    func aParticipantRefusalAsksAfreshWithoutShowingTheHeldProposal(outsiderInCc: Bool) async throws {
        let route = ScriptedRoute(text: proposalDraft)
        route.shownRecipientCheck = "thread_participants_v1"
        route.onShown = [.recipientsOutsideThread, nil]
        let (p, _, original) = await threadProposals(route)
        var view = original
        view.newestSender = nil
        await openAndWait(p, view)
        if outsiderInCc {
            p.reader.recipients = [WritingRecipient(address: "priya@northwind.example", role: .to),
                                   WritingRecipient(address: "outsider@example.com", role: .cc)]
        }
        route.hold(.shown)
        p.controller.observe(p.observation())
        await route.whileHeld { #expect(p.card.shown.isEmpty) }
        await until { p.card.isShown }
        #expect(route.created.count == 2)
        #expect(route.shownCalls.map(\.id) == route.created.map(\.requestID))
        #expect(route.created[1].compose.recipients == p.reader.recipients)
        #expect(route.shownRecipients[0] == p.reader.recipients)
        #expect(p.card.shown.count == 1)
        #expect(route.accepted.isEmpty)
    }

    @Test func aReplyWhoseRecipientsStayUnknownDoesNotLoopAfterARefusal() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        route.shownRecipientCheck = "thread_participants_v1"
        route.onShown = [.recipientsOutsideThread]
        let (p, ended, original) = await threadProposals(route)
        var view = original
        view.newestSender = nil
        p.reader.recipients = []
        await openAndWait(p, view)
        p.controller.observe(p.observation())
        await until { ended.outcomes == [.abstained] }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(route.created.count == 2)
        #expect(route.shownCalls.count == 2)
        #expect(p.card.shown.isEmpty)
    }

    @Test(arguments: ["recipients", "subject", "both"])
    func participantAdmissionRebindsACompletedGmailHeader(header: String) async throws {
        let route = ScriptedRoute(text: proposalDraft)
        route.shownRecipientCheck = "thread_participants_v1"
        let (p, ended, original) = await threadProposals(route)
        var view = original
        view.newestSender = nil
        if header != "recipients" { view.subject = ""; p.reader.subject = "" }
        if header != "subject" { p.reader.recipients = [] }
        await openAndWait(p, view)
        p.reader.beforeAnswer = { number in
            if number == 1 {
                p.reader.subject = "Re: \(Self.threadSubject)"
                p.reader.recipients = [WritingRecipient(address: Self.threadSender, role: .to)]
            }
        }
        p.controller.observe(p.observation())
        await until { p.card.isShown }
        #expect(route.created.count == 1)
        #expect(route.shownCalls.map(\.id) == [route.created[0].requestID])
        #expect(route.shownRecipients == [[WritingRecipient(address: Self.threadSender, role: .to)]])
        #expect(ended.outcomes.isEmpty)
        p.controller.reset()
    }

    @Test(arguments: [false, true])
    func admissionAndDisplayShareOneRetryAndOneVisibleEnding(admissionFirst: Bool) async throws {
        let route = ScriptedRoute(text: proposalDraft)
        route.shownRecipientCheck = "thread_participants_v1"
        let (p, ended, original) = await threadProposals(route)
        var view = original
        view.newestSender = nil
        await openAndWait(p, view)
        var notices = 0
        p.controller.unavailable = { notices += 1 }
        p.reader.beforeAnswer = { number in
            if number == (admissionFirst ? 1 : 2) { p.reader.subject = "Re: Updated offsite" }
            if number == 3 { p.reader.thread = "Priya Raman\nThe venue is booked." }
        }
        p.controller.observe(p.observation())
        await until { !ended.outcomes.isEmpty }
        #expect(ended.outcomes == [.abstained])
        #expect(notices == 1)
        #expect(route.created.count == 2)
        #expect(route.shownCalls.count == 1)
        #expect(p.card.shown.isEmpty)
        p.controller.reset()
    }

    @Test func participantAdmissionKeepsAReplyTypedWhileTheProposalArrives() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        route.shownRecipientCheck = "thread_participants_v1"
        let (p, ended, view) = await threadProposals(route)
        await openAndWait(p, view)
        p.reader.beforeAnswer = { number in
            if number == 1 {
                MockField.shared.text = "My own reply"
                MockField.shared.selection = FieldRange(location: 12, length: 0)
            }
        }
        p.controller.observe(p.observation())
        await until { p.card.isShown }
        #expect(route.created.count == 1)
        #expect(route.shownCalls.count == 1)
        #expect(MockField.shared.text == "My own reply")
        #expect(ended.outcomes.isEmpty)
        p.controller.reset()
    }

    @Test func aRetriedProposalKeepsItsRetryAllowanceWhenHeldAgain() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        route.shownRecipientCheck = "thread_participants_v1"
        let (p, ended, original) = await threadProposals(route)
        var view = original
        view.newestSender = nil
        await openAndWait(p, view)
        p.reader.beforeAnswer = { number in
            if number == 1 { p.reader.subject = "Re: Updated offsite" }
        }
        p.controller.observe(p.observation())
        await until { p.card.isShown }
        #expect(route.created.count == 2)
        p.reader.inThread = false
        p.focusReply(focus: 2, element: 2)
        await until { p.controller.heldThreads.count == 1 }
        p.reader.inThread = true
        let returningRead = p.reader.bodyReads + 1
        p.reader.beforeAnswer = { number in
            if number == returningRead { p.reader.subject = "Re: Another update" }
        }
        var notices = 0
        p.controller.unavailable = { notices += 1 }
        p.focusReply(focus: 3)
        await until { ended.outcomes == [.abstained] }
        #expect(notices == 1)
        #expect(route.created.count == 2)
        #expect(p.card.shown.count == 1)
        #expect(!p.card.isShown)
        p.controller.reset()
    }

    @Test func aRecipientRefusalWhileSearchHasFocusRequestsAfreshOnReturn() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        route.shownRecipientCheck = "thread_participants_v1"
        route.onShown = [.recipientsOutsideThread, nil]
        let (p, ended, original) = await threadProposals(route)
        var view = original
        view.newestSender = nil
        await openAndWait(p, view)
        route.hold(.shown)
        p.controller.observe(p.observation())
        await route.whileHeld {
            p.focusSearch(focus: 2)
            #expect(p.card.shown.isEmpty)
        }
        await until { !ended.outcomes.isEmpty }
        #expect(p.card.shown.isEmpty)
        p.focusReply(focus: 3)
        await until { p.card.isShown }
        #expect(route.created.count == 2)
        #expect(route.shownCalls.map(\.id) == route.created.map(\.requestID))
        #expect(route.admittedCards == [route.created.last!.requestID])
        #expect(p.card.shown.count == 1)
        p.controller.reset()
    }

    @Test func aRecipientRefusalWhileHeldAgainRequestsAfreshOnReturn() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        route.shownRecipientCheck = "thread_participants_v1"
        route.onShown = [.recipientsOutsideThread, nil]
        let (p, _, original) = await threadProposals(route)
        var view = original
        view.newestSender = nil
        await openAndWait(p, view)
        route.hold(.shown)
        p.controller.observe(p.observation())
        await route.whileHeld {
            p.reader.inThread = false
            p.focusReply(focus: 2, element: 2)
            await until { p.controller.heldThreads.count == 1 }
        }
        await until { p.controller.heldThreads.isEmpty }
        #expect(p.card.shown.isEmpty)
        p.reader.inThread = true
        p.focusReply(focus: 3)
        await until { p.card.isShown }
        #expect(route.created.count == 2)
        #expect(p.card.shown.count == 1)
        #expect(route.shownCalls.map(\.id) == route.created.map(\.requestID))
    }

    @Test(arguments: [false, true])
    func anUnknownSenderFinishingAwayStillNeedsTheCapabilityWhenHeldAgain(capable: Bool) async throws {
        let route = ScriptedRoute(text: proposalDraft)
        route.shownRecipientCheck = capable ? "thread_participants_v1" : nil
        let (p, _, original) = await threadProposals(route)
        var view = original
        view.newestSender = nil
        route.hold(.create)
        p.controller.threadOpened(view)
        await route.whileHeld {
            p.controller.observe(p.observation())
            await until { p.controller.isPending }
            p.focusSearch(focus: 2)
        }
        await until { p.controller.isHidden }
        #expect(route.shownCalls.isEmpty)
        // Another reply candidate holds the completed first proposal again,
        // with the first reply's known recipients, before any admission.
        p.reader.inThread = false
        p.focusReply(focus: 3, element: 2)
        await until { p.controller.heldThreads.count == 1 }
        p.reader.inThread = true
        p.focusReply(focus: 4, element: 1)
        await until { p.card.isShown }
        #expect(route.created.count == (capable ? 1 : 2))
        let admitted = capable ? route.created[0].requestID : route.created[1].requestID
        #expect(route.shownCalls.map(\.id) == [admitted])
        #expect(route.shownRecipients == [capable ? [WritingRecipient(address: Self.threadSender, role: .to)] : []])
        #expect(p.card.shown.count == 1)
    }

    /// The sender parser and controller together, without a browser or AX reads.
    private final class SenderPageNode: PageNode {
        let role: String
        let subrole: String?
        let title: String?
        let children: [SenderPageNode]

        init(_ role: String, subrole: String? = nil, title: String? = nil, _ children: [SenderPageNode] = []) {
            self.role = role
            self.subrole = subrole
            self.title = title
            self.children = children
        }

        func pageRole() -> PageRole? { PageRole(role: role, subrole: subrole) }
        func pageLabels() -> PageLabels? { PageLabels(description: nil, title: title) }
        func pageChildren() -> [SenderPageNode]? { children }
        func pageValue() -> String? { nil }
        func pageParent() -> SenderPageNode? { nil }
        func isNode(_ other: SenderPageNode) -> Bool { self === other }
    }

    @Test func anEmptyHeaderAndAccountAddressInABodyHeadingStillAllowAReplyProposal() async throws {
        let page = SenderPageNode("AXWebArea", title: "Venue - sam@fabrikam.example - Gmail", [
            SenderPageNode(kAXGroupRole, subrole: "AXLandmarkMain", [
                SenderPageNode("AXHeading", title: "Venue"),
                SenderPageNode(kAXListRole, [SenderPageNode(kAXGroupRole, [
                    SenderPageNode(kAXGroupRole, [SenderPageNode("AXHeading", title: "")]),
                    SenderPageNode(kAXGroupRole, [SenderPageNode("AXHeading", title: "sam@fabrikam.example", [
                        SenderPageNode(kAXStaticTextRole, title: "Can you confirm?"),
                    ])]),
                ])]),
            ]),
        ])
        let parsed = try #require(ComposePage.threadView(page: page))
        #expect(parsed.newestSender == nil)
        let route = ScriptedRoute(text: proposalDraft)
        let (p, _, initial) = await threadProposals(route)
        var view = initial
        view.newestSender = parsed.newestSender
        view.account = parsed.account
        view.thread = parsed.thread
        p.reader.thread = parsed.thread
        await openAndWait(p, view)
        #expect(route.created.count == 1)
        #expect(route.created.first?.compose.recipients == [])
        p.controller.observe(p.observation())
        await until { p.card.isShown }
        #expect(route.created.count == 2)
        #expect(route.created.last?.compose.recipients.map(\.address) == [Self.threadSender])
        #expect(p.card.isShown)
    }

    @Test func aThreadWhoseNewestMessageIsThePersonsOwnAsksForNothing() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, _, view) = await threadProposals(route)
        var mine = view
        mine.newestSender = "Sam@Fabrikam.example"
        p.controller.threadOpened(mine)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(route.created.isEmpty)
        // Nor does its reply, which goes to whoever the person wrote to.
        p.controller.observe(p.observation())
        try? await Task.sleep(for: .milliseconds(250))
        #expect(p.reader.bodyReads == 1)
        #expect(route.created.isEmpty)
        #expect(!p.card.isShown)
    }

    // MARK: Nothing to reply to

    @Test func anImportFailureWaitsForItsReplyThenNoticesOnce() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        route.onRead = .abstain(.mailImportPending)
        let (p, ended, view) = await threadProposals(route)
        var notices = 0
        p.controller.mailImportPending = { notices += 1 }
        let body = MockField.shared.text
        await openAndWait(p, view)
        #expect(ended.outcomes == [.abstained])
        #expect(notices == 0)
        p.controller.observe(p.observation())
        await until { notices == 1 }
        p.focusReply(focus: 2)
        await until { p.reader.bodyReads == 2 }
        #expect(notices == 1)
        #expect(route.created.count == 1)
        #expect(!p.card.isShown)
        #expect(MockField.shared.text == body)
    }

    @Test func aThreadWithNothingToAnswerHintsOnceWhenItsReplyOpens() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        route.onRead = .abstain(.nothingToAnswer)
        let (p, ended, view) = await threadProposals(route)
        var hints = 0, notices = 0
        p.controller.nothingToAnswer = { hints += 1 }
        p.controller.unavailable = { notices += 1 }
        let body = MockField.shared.text
        await openAndWait(p, view)
        #expect(ended.outcomes == [.abstained])
        // Nothing is said while no reply has focus.
        #expect(hints == 0)
        p.controller.observe(p.observation())
        await until { hints == 1 }
        // Focus back in the reply, and in another reply of the thread: no
        // request, and the hint is not said again.
        p.focusReply(focus: 2)
        await until { p.reader.bodyReads == 2 }
        p.focusReply(focus: 3, element: 2)
        await until { p.reader.bodyReads == 3 }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(hints == 1)
        #expect(notices == 0)
        #expect(route.created.count == 1)
        #expect(!p.card.isShown)
        #expect(MockField.shared.text == body)
    }

    @Test func aThreadWhoseNewestMessageIsThePersonsOwnHintsOnce() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, _, view) = await threadProposals(route)
        var hints = 0
        p.controller.nothingToAnswer = { hints += 1 }
        var mine = view
        mine.newestSender = Self.threadAccount
        p.controller.threadOpened(mine)
        p.controller.observe(p.observation())
        await until { hints == 1 }
        p.focusReply(focus: 2)
        await until { p.reader.bodyReads == 2 }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(hints == 1)
        #expect(route.created.isEmpty)
    }

    @Test(arguments: ["context_preparing", "proposal_limit", "excluded"])
    func anotherAbstentionGivesNoHint(reason: String) async throws {
        let route = ScriptedRoute(text: proposalDraft)
        route.onRead = .abstain(try #require(DraftReason(rawValue: reason)))
        let (p, _, view) = await threadProposals(route)
        var hints = 0
        p.controller.nothingToAnswer = { hints += 1 }
        await openAndWait(p, view)
        p.controller.observe(p.observation())
        await until { p.reader.bodyReads == 1 }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(hints == 0)
    }

    @Test func aReplyWithTextGetsNoHint() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        route.onRead = .abstain(.nothingToAnswer)
        let (p, _, view) = await threadProposals(route)
        var hints = 0
        p.controller.nothingToAnswer = { hints += 1 }
        await openAndWait(p, view)
        MockField.shared.text = "Thanks"
        MockField.shared.selection = FieldRange(location: 6, length: 0)
        p.controller.observe(p.observation())
        await until { p.reader.bodyReads == 1 }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(hints == 0)
    }

    @Test func aReplysOwnRequestWithNothingToAnswerHintsOnceAndIsNotAskedAgain() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        route.onRead = .abstain(.nothingToAnswer)
        let (p, ended, _) = await threadProposals(route)
        var hints = 0, notices = 0
        p.controller.nothingToAnswer = { hints += 1 }
        p.controller.unavailable = { notices += 1 }
        p.controller.observe(p.observation())
        await until { ended.outcomes == [.abstained] }
        // The hint waits on its own blank read, after the proposal ended.
        await until { hints == 1 }
        #expect(notices == 0)
        p.focusReply(focus: 2)
        await until { p.reader.bodyReads == 2 }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(hints == 1)
        #expect(route.created.count == 1)
        #expect(!p.card.isShown)
    }

    @Test func aReplysOwnRequestThatAnswersAfterFocusLeftHintsWhenTheReplyReturns() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        route.onRead = .abstain(.nothingToAnswer)
        let (p, ended, _) = await threadProposals(route)
        var hints = 0
        p.controller.nothingToAnswer = { hints += 1 }
        route.hold(.create)
        p.controller.observe(p.observation())
        await route.whileHeld {
            await until { p.controller.isPending }
            p.controller.observe(p.observation(focus: 2, placed: false))
        }
        await until { !ended.outcomes.isEmpty }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(hints == 0)
        // Back in the untouched reply: said once, and nothing asked again.
        p.focusReply(focus: 3)
        await until { hints == 1 }
        p.focusReply(focus: 4)
        await until { p.reader.bodyReads == 3 }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(hints == 1)
        #expect(route.created.count == 1)
    }

    @Test func aRecordingStartedBeforeTheHintsReadAnswersLeavesTheHintDue() async throws {
        let server = try await ScriptedEndpoint([.silent])
        defer { server.stop() }
        let route = ScriptedRoute(text: proposalDraft)
        route.onRead = .abstain(.nothingToAnswer)
        let p = await proposals(server.endpoint, route: route)
        var hints = 0
        p.controller.nothingToAnswer = { hints += 1 }
        route.hold(.create)
        p.controller.observe(p.observation())
        await route.whileHeld {
            await until { p.controller.isPending }
            p.reader.holdingCandidates = true
        }
        // The blank read before the hint waits while a recording starts.
        await until { p.reader.heldCandidateCount == 1 }
        p.dictation.toggle()
        #expect(p.dictation.phase == .recording)
        p.reader.releaseCandidates()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(hints == 0)
        p.dictation.cancel()
        await until { p.dictation.phase == .idle }
        // Still due: the untouched reply says it once when it next takes focus.
        p.focusReply(focus: 2)
        await until { hints == 1 }
        #expect(route.created.count == 1)
    }

    @Test func aReplyTypedIntoWhileItsRequestWasOnItsWayGetsNoHint() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        route.onRead = .abstain(.nothingToAnswer)
        let (p, ended, _) = await threadProposals(route)
        var hints = 0
        p.controller.nothingToAnswer = { hints += 1 }
        route.hold(.create)
        p.controller.observe(p.observation())
        await route.whileHeld {
            await until { p.controller.isPending }
            MockField.shared.text = "Thanks"
            MockField.shared.selection = FieldRange(location: 6, length: 0)
            p.controller.observe(p.observation(edit: 1))
        }
        await until { !ended.outcomes.isEmpty }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(hints == 0)
        #expect(MockField.shared.text == "Thanks")
    }

    @Test func reopeningTheThreadAfterAReplysOwnRequestHintedSaysNothingAgain() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        route.onRead = .abstain(.nothingToAnswer)
        let (p, ended, original) = await threadProposals(route)
        var hints = 0
        p.controller.nothingToAnswer = { hints += 1 }
        p.controller.observe(p.observation())
        await until { ended.outcomes == [.abstained] }
        await until { hints == 1 }
        // A reply to the person's own message goes to someone other than the
        // newest sender the thread view reads.
        var view = original
        view.newestSender = "tomas@contoso.example"
        p.controller.threadOpened(view)
        p.focusReply(focus: 2)
        await until { p.reader.bodyReads == 2 }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(hints == 1)
        #expect(route.created.count == 1)
    }

    @Test func nothingIsAskedWithTheSettingOff() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, _, view) = await threadProposals(route)
        p.enabled.value = false
        p.controller.threadOpened(view)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(route.created.isEmpty)
        #expect(p.controller.heldThreads.isEmpty)
        #expect(!p.controller.watchesThreads)
    }

    @Test func turningTheSettingOffCancelsARequestOnItsWay() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, ended, view) = await threadProposals(route)
        route.hold(.create)
        p.controller.threadOpened(view)
        await route.whileHeld {
            p.enabled.value = false
            p.controller.reset()
        }
        await until { route.cancelled.count == 1 }
        #expect(ended.outcomes == [.cancelled])
        #expect(p.controller.heldThreads.isEmpty)
    }

    @Test func aReplyAdoptsAThreadBeforeItsQueuedRequestStarts() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, ended, view) = await threadProposals(route)
        var resume: CheckedContinuation<Void, Never>?
        p.controller.beforeThreadRequest = {
            await withCheckedContinuation { resume = $0 }
        }
        p.controller.threadOpened(view)
        await until { resume != nil }
        p.controller.observe(p.observation())
        await until { p.controller.isPending && p.controller.heldThreads.isEmpty }
        #expect(route.created.count == 0)
        #expect(p.controller.isPending)
        #expect(p.controller.heldThreads.isEmpty)
        resume?.resume()
        await until { p.card.isShown }
        #expect(route.created.count == 1)
        #expect(route.created.first?.compose.threadID == "18c2f4a9d0e1b3a2")
        #expect(!p.controller.isPending)
        #expect(ended.outcomes.isEmpty)
    }

    @Test func aCancelledQueuedThreadRequestNeverStarts() async {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, ended, view) = await threadProposals(route)
        var resume: CheckedContinuation<Void, Never>?
        p.controller.beforeThreadRequest = { await withCheckedContinuation { resume = $0 } }
        p.controller.threadOpened(view)
        await until { resume != nil }
        p.controller.reset()
        resume?.resume()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(route.created.count == 0)
        #expect(ended.outcomes == [.cancelled])
        #expect(!p.controller.isPending)
    }

    @Test func anOldAdmissionCannotReadOrDropANewReplyBody() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, ended, view) = await threadProposals(route)
        await openAndWait(p, view)
        route.hold(.shown)
        p.controller.observe(p.observation())
        await route.whileHeld {
            await until { p.reader.bodyReads == 1 }
            p.focusReply(focus: 2, element: 2)
            await until { p.reader.bodyReads == 2 && p.controller.isHidden }
        }
        await until { p.card.isShown }
        #expect(ended.outcomes.isEmpty)
        #expect(p.reader.bodyReads == 3)
        #expect(route.created.count == 1)
        #expect(route.shownCalls.count == 1)
        #expect(p.card.shown.count == 1)
    }

    @Test func anOldDisplayReadCannotChangeANewReplyWhileItsCheckWaits() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, ended, view) = await threadProposals(route)
        await openAndWait(p, view)
        var old: CheckedContinuation<Void, Never>?
        var latest: CheckedContinuation<Void, Never>?
        p.reader.beforeAnswer = { number in
            if number == 2 { await withCheckedContinuation { old = $0 } }
            if number == 4 { await withCheckedContinuation { latest = $0 } }
        }
        p.controller.observe(p.observation())
        await until { old != nil }
        p.focusReply(focus: 2, element: 2)
        await until { latest != nil }
        old?.resume()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(ended.outcomes.isEmpty)
        #expect(p.controller.isHidden)
        #expect(p.card.shown.isEmpty)
        latest?.resume()
        await until { p.card.isShown }
        #expect(ended.outcomes.isEmpty)
        #expect(p.card.shown.count == 1)
        #expect(route.created.count == 1)
        #expect(route.shownCalls.count == 1)
    }

    @Test func twoRepliesReuseOneProposalAndEachRecordsItsOwnShowing() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, lifetime, view) = await threadProposals(route)
        let replies = Ended()
        p.controller.replyEnded = { outcome, trace in
            replies.outcomes.append(outcome)
            replies.traces.append(trace)
        }
        await openAndWait(p, view)
        let first = p.observation()
        p.controller.observe(first)
        await until { p.card.isShown }
        MockField.shared.focusedElement = 2
        let second = p.observation(focus: 2)
        p.controller.observe(second)
        await until { p.card.shown.count == 2 }
        p.pressEscape()
        #expect(replies.outcomes == [.left, .dismissed])
        #expect(replies.traces.map(\.replyFocused) == [first.startedAt, second.startedAt])
        #expect(replies.traces.allSatisfy { $0.shown != nil })
        #expect(replies.traces[0].shown! < second.startedAt)
        #expect(replies.traces[1].shown! >= second.startedAt)
        #expect(lifetime.outcomes == [.dismissed])
        #expect(route.created.count == 1)
        #expect(route.shownCalls.count == 1)
        // The proposal's later expiry cannot add another sample for either reply.
        p.controller.reset()
        #expect(replies.outcomes == [.left, .dismissed])
    }

    @Test(arguments: [ProposalOutcome.limited, .unreported, .abstained])
    func eachHiddenReplyRecordsItsOwnFocusAndOutcome(outcome: ProposalOutcome) async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, _, view) = await threadProposals(route)
        let replies = Ended()
        p.controller.replyEnded = { outcome, trace in
            replies.outcomes.append(outcome)
            replies.traces.append(trace)
        }
        if outcome == .limited { route.onShown = [.proposalLimit] }
        if outcome == .unreported { route.onShown = [.invalidResponse, .invalidResponse] }
        if outcome == .abstained {
            p.reader.beforeAnswer = { number in
                if number == 2 { p.accountShift.value = 1 }
            }
        }
        await openAndWait(p, view)
        let observation = p.observation()
        p.controller.observe(observation)
        await until { !replies.outcomes.isEmpty }
        #expect(replies.outcomes == [outcome])
        #expect(replies.traces.count == 1)
        #expect(replies.traces.first?.replyFocused == observation.startedAt)
        #expect(replies.traces.first?.shown == nil)
        #expect(p.card.shown.isEmpty)
    }

    // MARK: The server's admission

    @Test func aDelayedAdmissionHoldsTheCardUntilTheServerAnswers() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, _, view) = await threadProposals(route)
        await openAndWait(p, view)
        route.hold(.shown)
        p.controller.observe(p.observation())
        await route.whileHeld(pause: .milliseconds(300)) {
            // Only the reply's first read ran; admission holds the display read.
            await until { p.reader.bodyReads == 1 }
            try? await Task.sleep(for: .milliseconds(200))
            #expect(!p.card.isShown)
            #expect(p.tab == nil)
            #expect(route.shownCalls.count == 1)
        }
        await until { p.card.isShown }
        #expect(route.shownCalls.count == 1)
    }

    @Test func theDaysLimitKeepsTheCardHidden() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        route.onShown = [.proposalLimit]
        let (p, ended, view) = await threadProposals(route)
        await openAndWait(p, view)
        p.controller.observe(p.observation())
        await until { ended.outcomes == [.limited] }
        #expect(p.card.shown.isEmpty)
        #expect(!p.controller.isShown)
        #expect(p.tab == nil)
        #expect(route.shownCalls.count == 1)
        #expect(route.accepted.isEmpty)
        // The same reply does not get it again, and nothing is asked again.
        p.focusSearch(focus: 2)
        p.focusReply(focus: 3)
        try? await Task.sleep(for: .milliseconds(250))
        #expect(p.card.shown.isEmpty)
        #expect(route.created.count == 1)
        #expect(route.shownCalls.count == 1)
    }

    @Test func anAdmissionThatFailsOnceIsAskedAgainAndTheCardShows() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        route.onShown = [.unreachable, nil]
        let (p, ended, view) = await threadProposals(route)
        await openAndWait(p, view)
        p.controller.observe(p.observation())
        await until { p.card.isShown }
        #expect(route.shownCalls.count == 2)
        #expect(ended.outcomes.isEmpty)
    }

    @Test func anAdmissionThatFailsTwiceNeverShows() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        route.onShown = [.server(500), .unreachable]
        let (p, ended, view) = await threadProposals(route)
        await openAndWait(p, view)
        p.controller.observe(p.observation())
        await until { ended.outcomes == [.unreported] }
        #expect(p.card.shown.isEmpty)
        #expect(route.shownCalls.count == 2)
        // Not asked a third time on the reply's return.
        p.focusSearch(focus: 2)
        p.focusReply(focus: 3)
        try? await Task.sleep(for: .milliseconds(250))
        #expect(route.shownCalls.count == 2)
        #expect(p.card.shown.isEmpty)
    }

    @Test func aCardShownAgainIsNotAdmittedAgain() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, _, view) = await threadProposals(route)
        await openAndWait(p, view)
        p.controller.observe(p.observation())
        await until { p.card.isShown }
        p.focusSearch(focus: 2)
        #expect(!p.card.isShown)
        p.focusReply(focus: 3)
        await until { p.card.isShown }
        #expect(p.card.shown.count == 2)
        #expect(route.shownCalls.count == 1)
    }

    @Test func anAdmissionThatAnswersAfterTheProposalEndedShowsNothing() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, ended, view) = await threadProposals(route)
        await openAndWait(p, view)
        route.hold(.shown)
        p.controller.observe(p.observation())
        await route.whileHeld {
            await until { p.reader.bodyReads == 1 }
            // Reset ends the proposal while admission is still pending.
            p.controller.reset()
        }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(p.card.shown.isEmpty)
        #expect(ended.outcomes == [.left])
    }

    @Test func anAdmissionThatAnswersAfterTheGateShutShowsNothing() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, _, view) = await threadProposals(route)
        await openAndWait(p, view)
        route.hold(.shown)
        p.controller.observe(p.observation())
        await route.whileHeld {
            await until { p.reader.bodyReads == 1 }
            p.enabled.value = false
        }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(p.card.shown.isEmpty)
    }

    @Test func anAdmissionAnsweredWithAnUnpromisedSuccessTwiceNeverShows() async throws {
        // A 200 or 202 where the route promises 204 reaches the writer as
        // an invalid response: asked once more, then the card stays hidden.
        let route = ScriptedRoute(text: proposalDraft)
        route.onShown = [.invalidResponse, .invalidResponse]
        let (p, ended, view) = await threadProposals(route)
        await openAndWait(p, view)
        p.controller.observe(p.observation())
        await until { ended.outcomes == [.unreported] }
        #expect(p.card.shown.isEmpty)
        #expect(route.shownCalls.count == 2)
    }

    @Test func aPasteDuringAdmissionStillShowsTheCard() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, ended, view) = await threadProposals(route)
        await openAndWait(p, view)
        route.hold(.shown)
        p.controller.observe(p.observation())
        await route.whileHeld {
            // The initial reply read found an empty body. The mouse
            // pastes while admission holds the display read.
            await until { p.reader.bodyReads == 1 }
            MockField.shared.text = "Harbor Hall it is, thanks Priya."
            MockField.shared.selection = FieldRange(location: 32, length: 0)
            p.controller.observe(p.observation(edit: 1))
        }
        await until { p.card.isShown }
        #expect(ended.outcomes.isEmpty)
        #expect(p.card.isShown)
        #expect(p.tab != nil)
        // The body was read again under the one admission.
        #expect(p.reader.bodyReads == 2)
        #expect(route.shownCalls.count == 1)
        #expect(route.accepted.isEmpty)
        #expect(MockField.shared.text == "Harbor Hall it is, thanks Priya.")
    }

    @Test func anUnattributedNoticeDuringAdmissionKeepsTheCard() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, ended, view) = await threadProposals(route)
        await openAndWait(p, view)
        route.hold(.shown)
        p.controller.observe(p.observation())
        await route.whileHeld {
            await until { p.reader.bodyReads == 1 }
            // Gmail's own notice, the body unchanged.
            p.controller.observe(p.observation(edit: 1))
        }
        await until { p.card.isShown }
        #expect(p.reader.bodyReads == 2)
        #expect(route.shownCalls.count == 1)
        #expect(ended.outcomes.isEmpty)
        #expect(p.card.isShown)
    }

    @Test func aReplyProposalAsksForAdmissionToo() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let p = await proposals(nil, route: route)
        p.controller.observe(p.observation())
        await until { p.card.isShown }
        #expect(route.shownCalls.count == 1)
        #expect(route.shownCalls.first?.id == route.created.first?.requestID)
    }

    @Test(arguments: ["thread", "threadID", "recipients", "subject", "account"])
    func aBindingChangedDuringAdmissionRetriesOnceOrEndsTheAccount(_ change: String) async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, ended, view) = await threadProposals(route)
        await openAndWait(p, view)
        route.hold(.shown)
        p.controller.observe(p.observation())
        await route.whileHeld {
            #expect(p.reader.bodyReads == 1)
            switch change {
            case "thread": p.reader.thread = "Priya Raman\nThe offsite is cancelled."
            case "threadID": p.reader.threadID = "18c2f4a9d0e1b3b7"
            case "recipients": p.reader.recipients = [WritingRecipient(address: "tomas@fabrikam.example", role: .to)]
            case "subject": p.reader.subject = "Re: Cancelled offsite"
            case "account": p.accountShift.value += 1
            default: Issue.record("Unexpected binding scenario")
            }
            // No focused-body notice or key arrives for a new message
            // elsewhere on the page. The original edit serial remains.
        }
        if change == "account" {
            await until { ended.outcomes == [.abstained] }
            #expect(p.card.shown.isEmpty)
            #expect(p.tab == nil)
            #expect(route.created.count == 1)
        } else {
            await until { p.card.isShown }
            #expect(ended.outcomes.isEmpty)
            #expect(route.created.count == 2)
            #expect(route.shownCalls.count == 2)
            #expect(p.reader.bodyReads == 3)
        }
        #expect(route.accepted.isEmpty)
    }

    @Test func aChangedFocusedElementDuringAdmissionNeverShowsOnTheOtherBody() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, ended, view) = await threadProposals(route)
        await openAndWait(p, view)
        route.hold(.shown)
        p.controller.observe(p.observation())
        await route.whileHeld {
            MockField.shared.focusedElement = 2
            // The tracker has not reported a new focus or edit serial yet.
        }
        await until { p.reader.bodyReads == 2 }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(p.card.shown.isEmpty)
        #expect(p.tab == nil)
        #expect(ended.outcomes.isEmpty)
        #expect(p.controller.isHidden)
        #expect(route.accepted.isEmpty)
    }

    @Test func aThreadRejectedDuringDictationIsRereadOnceWhenIdle() async throws {
        let server = try await ScriptedEndpoint([.silent])
        defer { server.stop() }
        let p = await proposals(server.endpoint, route: ScriptedRoute(text: proposalDraft))
        let view = GmailThreadView(pid: p.pid, started: nil, threadID: "18c2f4a9d0e1b3a2", subject: Self.threadSubject,
                                   thread: p.reader.thread, newestSender: Self.threadSender, account: Self.threadAccount)
        var retries = 0
        p.controller.retryThreadOpen = {
            retries += 1
            p.controller.threadOpened(view)
        }
        p.dictation.toggle()
        #expect(p.dictation.phase == .recording)
        p.controller.threadOpened(view)
        #expect(p.route.created.isEmpty)
        p.dictation.cancel()
        await until { p.dictation.phase == .idle && p.route.created.count == 1 }
        #expect(retries == 1)
        #expect(p.route.created.first?.compose.threadID == "18c2f4a9d0e1b3a2")
        p.controller.dictationEnded()
        #expect(retries == 1)
        #expect(p.route.created.count == 1)
    }

    @Test func aResetForgetsTheThreadOpenDeferredDuringDictation() async throws {
        let server = try await ScriptedEndpoint([.silent])
        defer { server.stop() }
        let p = await proposals(server.endpoint, route: ScriptedRoute(text: proposalDraft))
        let view = GmailThreadView(pid: p.pid, started: nil, threadID: "18c2f4a9d0e1b3a2", subject: Self.threadSubject,
                                   thread: p.reader.thread, newestSender: Self.threadSender, account: Self.threadAccount)
        var retries = 0
        p.controller.retryThreadOpen = { retries += 1 }
        p.dictation.toggle()
        p.controller.threadOpened(view)
        p.controller.reset()
        p.dictation.cancel()
        await until { p.dictation.phase == .idle }
        p.controller.dictationEnded()
        #expect(retries == 0)
        #expect(p.route.created.isEmpty)
    }

    // MARK: Leaving and returning

    @Test func reopeningAHeldThreadCancelsAnotherThreadsRequest() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, ended, view) = await threadProposals(route)
        await openAndWait(p, view)
        route.hold(.create)
        p.controller.threadOpened(otherThread(view, "18c2f4a9d0e1b3b7"))
        await route.whileHeld { p.controller.threadOpened(view) }
        await until { route.cancelled.count == 1 }
        #expect(route.cancelled == [route.created[1].requestID])
        #expect(route.created.count == 2)
        #expect(ended.outcomes == [.cancelled])
        #expect(p.controller.heldThreads.map(\.key.threadID) == ["18c2f4a9d0e1b3a2"])
    }

    /// The scripted reader as the reply in the other thread.
    private func readAsOtherThread(_ p: Proposals) {
        p.reader.threadID = "18c2f4a9d0e1b3b7"
        p.reader.thread = "Tomás Ortega\nCan you send the deck before Friday?"
        p.reader.subject = "Re: Deck for Friday"
        p.reader.recipients = [WritingRecipient(address: "tomas@fabrikam.example", role: .to)]
    }

    private func readAsFirstThread(_ p: Proposals, _ view: GmailThreadView) {
        p.reader.threadID = view.threadID
        p.reader.thread = view.thread
        p.reader.subject = "Re: \(Self.threadSubject)"
        p.reader.recipients = [WritingRecipient(address: Self.threadSender, role: .to)]
    }

    @Test func aShownProposalLeftForAnotherReplyIsHeldAndShownOnReturn() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, ended, view) = await threadProposals(route)
        await openAndWait(p, view)
        p.controller.observe(p.observation())
        await until { p.card.isShown }
        // A reply in another thread: its own request, and the first held.
        readAsOtherThread(p)
        p.focusReply(focus: 2, element: 2)
        await until { route.created.count == 2 && p.card.shown.count == 2 }
        #expect(p.controller.heldThreads.map(\.key.threadID) == ["18c2f4a9d0e1b3a2"])
        #expect(ended.outcomes.isEmpty)
        // Back to the first reply: shown again with no request and no
        // second admission.
        readAsFirstThread(p, view)
        p.focusReply(focus: 3, element: 1)
        await until { p.card.shown.count == 3 }
        #expect(p.card.shown.last?.text == proposalDraft)
        #expect(route.created.count == 2)
        #expect(route.shownCalls.map(\.id) == [route.created[0].requestID, route.created[1].requestID])
        // The second reply's proposal is held in its turn.
        #expect(p.controller.heldThreads.map(\.key.threadID) == ["18c2f4a9d0e1b3b7"])
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { ended.outcomes == [.inserted] }
        #expect(route.accepted == [route.created[0].requestID])
    }

    @Test func aDismissedProposalIsNotHeldAgain() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, ended, view) = await threadProposals(route)
        await openAndWait(p, view)
        p.controller.observe(p.observation())
        await until { p.card.isShown }
        p.pressEscape()
        #expect(ended.outcomes == [.dismissed])
        readAsOtherThread(p)
        p.focusReply(focus: 2, element: 2)
        await until { route.created.count == 2 && p.card.shown.count == 2 }
        #expect(p.controller.heldThreads.isEmpty)
        readAsFirstThread(p, view)
        p.focusReply(focus: 3, element: 1)
        try? await Task.sleep(for: .milliseconds(250))
        #expect(p.card.shown.count == 2)
        #expect(route.created.count == 2)
    }

    @Test func aHeldAnswerGoesWhenItsTimePassesWithNothingElseHappening() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, ended, view) = await threadProposals(route, keep: .milliseconds(200))
        await openAndWait(p, view)
        await until { p.controller.heldThreads.isEmpty }
        #expect(ended.outcomes == [.left])
        #expect(route.created.count == 1)
    }

    // MARK: Callbacks from other queues

    @Test func theWatchsReportReachesTheControllerFromABackgroundQueue() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, _, view) = await threadProposals(route)
        let report = ReplyProposalController.threadReporter(to: p.controller)
        await Self.offMain { report(view) }
        await until { route.created.count == 1 }
        #expect(route.created.first?.compose.threadID == "18c2f4a9d0e1b3a2")
    }

    @Test func theWatchsNotificationsReachTheMainActorFromABackgroundQueue() async throws {
        let watch = GmailThreadWatch(activationCenter: NotificationCenter(), opened: { _ in })
        watch.start(while: { false })
        await Self.offMain { watch.notified() }
        await until { watch.notices == 1 }
        // The activation handler hops the same way, and with proposals not
        // wanted follows nothing and reads nothing.
        let refreshes = watch.refreshes
        let handler = GmailThreadWatch.activationHandler(watch)
        await Self.offMain { handler(Notification(name: NSWorkspace.didActivateApplicationNotification)) }
        await until { watch.refreshes == refreshes + 1 }
        await Self.offMain { watch.notified() }
        await until { watch.notices == 2 }
    }

    // MARK: The watch's own state

    @Test func theWatchForgetsTheOpenThreadWhenProposalsStopOrTheAccountChangesAndKeepsItOtherwise() async throws {
        let wanted = Proposals.Box(true)
        // Exercise remembered state without observing the real frontmost app.
        let watch = GmailThreadWatch(activationCenter: NotificationCenter(), browserPID: { nil }, opened: { _ in })
        watch.start(while: { wanted.value })
        await watch.remember(pid: 41, threadID: "18c2f4a9d0e1b3a2")
        // Another app came to the front, or a setting that keeps proposals
        // wanted changed: the browser coming back finds the thread read.
        watch.refresh()
        #expect(await watch.rememberedThread() == "18c2f4a9d0e1b3a2")
        // A setting went off: the same thread is asked for once it is on.
        wanted.value = false
        watch.refresh()
        #expect(await watch.rememberedThread() == nil)
        // Another account, with proposals wanted throughout.
        wanted.value = true
        await watch.remember(pid: 41, threadID: "18c2f4a9d0e1b3a2")
        watch.refresh(accountChanged: true)
        #expect(await watch.rememberedThread() == nil)
    }

    @Test func anAccountChangeDuringAPageWalkDropsTheOldThreadBeforeRequesting() async throws {
        // Keep scheduling delays from expiring the writer while this
        // scenario checks the watch's account fence.
        let clock = SteppedClock()
        let route = ScriptedRoute(text: proposalDraft)
        let (p, _, view) = await threadProposals(route, clock: clock)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let wanted = Proposals.Box(false)
        let watch = GmailThreadWatch(activationCenter: NotificationCenter(), readThread: {
            entered.signal()
            release.wait()
            return .opened(view)
        }, browserPID: { nil }, opened: ReplyProposalController.threadReporter(to: p.controller))
        watch.start(while: { wanted.value })
        wanted.value = true
        watch.notified()
        await Self.offMain { entered.wait() }
        p.accountShift.value += 1
        p.controller.reset()
        watch.refresh(accountChanged: true)
        release.signal()
        // Cleanup runs after the read and any reporting it queued.
        _ = await watch.rememberedThread()
        #expect(route.created.isEmpty)
        #expect(p.controller.heldThreads.isEmpty)
        #expect(await watch.rememberedThread() == nil)
        // A new read under the replacement account remains usable.
        release.signal()
        watch.notified()
        await until { route.created.count == 1 }
        await until { clock.waits.contains(.milliseconds(20)) }
        clock.advance(to: .milliseconds(20))
        await until { p.controller.heldThreads.first?.pending == false }
        #expect(p.controller.heldThreads.first?.key.account == p.dictation.account + 1)
        wanted.value = false
        watch.refresh()
    }

    @Test func anAccountChangeBeforeMainActorDeliveryDropsACompletedPageRead() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, _, view) = await threadProposals(route)
        let executor = AccessibilityExecutor(capacity: 2)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let wanted = Proposals.Box(false)
        let watch = GmailThreadWatch(activationCenter: NotificationCenter(), executor: executor, readThread: {
            entered.signal()
            release.wait()
            return .opened(view)
        }, browserPID: { nil }, opened: ReplyProposalController.threadReporter(to: p.controller))
        watch.start(while: { wanted.value })
        wanted.value = true
        watch.notified()
        await Self.offMain { entered.wait() }
        // Hold only this synthetic main-actor turn until the executor has
        // queued delivery. No AX call or app is involved in this barrier.
        executor.submitCleanup { finished.signal() }
        release.signal()
        #expect(waitForSyntheticJob(finished))
        p.accountShift.value += 1
        p.controller.reset()
        watch.refresh(accountChanged: true)
        _ = await watch.rememberedThread()
        #expect(route.created.isEmpty)
        #expect(p.controller.heldThreads.isEmpty)
        wanted.value = false
        watch.refresh()
    }

    @Test func aFullExecutorEventuallyFollowsOnlyTheLatestBrowser() async throws {
        let executor = AccessibilityExecutor(capacity: 2)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let wanted = Proposals.Box(false)
        let pid = Proposals.Box<pid_t?>(41)
        let attempts = ObserverAttempts()
        let watch = GmailThreadWatch(activationCenter: NotificationCenter(), executor: executor, browserPID: { pid.value }, createObserver: { pid, _ in
            _ = attempts.record(pid)
            return nil
        }, opened: { _ in })
        watch.start(while: { wanted.value })
        _ = await watch.rememberedThread()
        let blocked = executor.submit { @Sendable _ in entered.signal(); release.wait() }
        #expect(blocked)
        await Self.offMain { entered.wait() }
        let queued = executor.submit { @Sendable _ in }
        #expect(queued)
        wanted.value = true
        watch.refresh()
        pid.value = 42
        watch.refresh()
        pid.value = 43
        watch.refresh()
        #expect(attempts.pids.isEmpty)
        release.signal()
        await until { attempts.pids == [43] }
        #expect(attempts.pids == [43])
        wanted.value = false
        watch.refresh()
        _ = await watch.rememberedThread()
    }

    @Test func executorDelaysCoalescePageReadsAndSpacingUsesTheirActualStart() async throws {
        let executor = AccessibilityExecutor(capacity: 2)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let reads = ReadStarts()
        let wanted = Proposals.Box(false)
        let watch = GmailThreadWatch(activationCenter: NotificationCenter(), executor: executor, readPage: { _ in
            reads.record()
            Thread.sleep(forTimeInterval: 0.2)
            return false
        }, opened: { _ in })
        watch.start(while: { wanted.value })
        executor.submit { _ in
            entered.signal()
            release.wait()
        }
        await Self.offMain { entered.wait() }
        wanted.value = true
        watch.notified()
        try? await Task.sleep(for: .milliseconds(450))
        watch.notified()
        try? await Task.sleep(for: .milliseconds(450))
        watch.notified()
        let newestNotice = ContinuousClock.now
        release.signal()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(reads.starts.isEmpty)
        await until { reads.starts.count == 1 }
        let first = try #require(reads.starts.first)
        #expect(first - newestNotice >= .milliseconds(300))
        // Submission times were long ago. The next read must still wait
        // a full second from the first actual execution.
        watch.notified()
        try? await Task.sleep(for: .milliseconds(450))
        #expect(reads.starts.count == 1)
        await until { reads.starts.count == 2 }
        #expect(reads.starts[1] - first >= .milliseconds(1200))
        wanted.value = false
        watch.refresh()
    }

    @Test func retryingAnOpenForgetsItsIdAndReadsTheCurrentPageOnce() async {
        let reads = ReadStarts()
        let wanted = Proposals.Box(false)
        let watch = GmailThreadWatch(activationCenter: NotificationCenter(), readPage: { _ in
            reads.record()
            return false // The current page is elsewhere, so no open is reported.
        }, opened: { _ in Issue.record("No thread is shown") })
        watch.start(while: { wanted.value })
        await watch.remember(pid: 41, threadID: "18c2f4a9d0e1b3a2")
        wanted.value = true
        watch.retryOpen()
        await until { reads.starts.count == 1 }
        #expect(await watch.rememberedThread() == nil)
        try? await Task.sleep(for: .milliseconds(450))
        #expect(reads.starts.count == 1)
        wanted.value = false
        watch.refresh()
    }

    @Test func retryingAnOpenReadsAgainAfterAnAlreadyQueuedRead() async {
        let executor = AccessibilityExecutor(capacity: 2)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let reads = ReadStarts()
        let wanted = Proposals.Box(false)
        let watch = GmailThreadWatch(activationCenter: NotificationCenter(), executor: executor, readPage: { remembered in
            reads.record(threadID: remembered)
            return false
        }, browserPID: { 41 }, createObserver: { _, _ in nil }, opened: { _ in })
        watch.start(while: { wanted.value })
        await watch.remember(pid: 41, threadID: "18c2f4a9d0e1b3a2")
        executor.submit { _ in
            entered.signal()
            release.wait()
        }
        await Self.offMain { entered.wait() }
        wanted.value = true
        watch.notified()
        // Queue a page job behind the blocked Accessibility call, then
        // request the dictation retry while another notice replaces the read.
        await until { watch.readSubmitted }
        watch.retryOpen()
        watch.notified()
        try? await Task.sleep(for: .milliseconds(450))
        release.signal()
        await until { reads.starts.count == 2 }
        #expect(reads.threadIDs == ["18c2f4a9d0e1b3a2", nil])
        #expect(await watch.rememberedThread() == nil)
        try? await Task.sleep(for: .milliseconds(450))
        #expect(reads.starts.count == 2)
        wanted.value = false
        watch.refresh()
    }

    /// A synchronous barrier only for an in-process job with no AX calls.
    private func waitForSyntheticJob(_ signal: DispatchSemaphore) -> Bool {
        signal.wait(timeout: .now() + 5) == .success
    }

    private final class ReadStarts: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [ContinuousClock.Instant] = []
        private var remembered: [String?] = []
        var starts: [ContinuousClock.Instant] { lock.withLock { recorded } }
        var threadIDs: [String?] { lock.withLock { remembered } }
        func record(threadID: String? = nil) {
            lock.withLock {
                recorded.append(.now)
                remembered.append(threadID)
            }
        }
    }

    @Test func observerCreationFailureRetriesTheSameProcessUntilItSucceeds() async throws {
        let attempts = ObserverAttempts()
        let watch = GmailThreadWatch(activationCenter: NotificationCenter(), createObserver: { pid, callback in
            let count = attempts.record(pid)
            guard count > 1 else { return nil }
            var observer: AXObserver?
            guard ApplicationServices.AXObserverCreate(pid, callback, &observer) == .success else { return nil }
            return observer
        }, opened: { _ in })
        let pid = getpid()
        #expect(await watch.followForCheck(pid) == nil)
        #expect(await watch.followForCheck(pid) == pid)
        #expect(await watch.followForCheck(pid) == pid)
        #expect(attempts.pids == [pid, pid])
        #expect(await watch.followForCheck(nil) == nil)
    }

    private final class ObserverAttempts: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [pid_t] = []
        var pids: [pid_t] { lock.withLock { recorded } }
        func record(_ pid: pid_t) -> Int {
            lock.withLock { recorded.append(pid); return recorded.count }
        }
    }

    @Test func theTitleIsHeardFromTheFocusedWindowAndFocusFromTheApp() {
        #expect(GmailThreadWatch.windowNotifications == [kAXTitleChangedNotification])
        #expect(GmailThreadWatch.appNotifications == [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification])
    }
    // MARK: A reply typed into before it settled

    /// The person types `text` into the reply: a key, the field changed,
    /// the change reported.
    private func typeInThreadReply(_ text: String, _ p: Proposals, edit: Int) async {
        await p.pressKey()
        MockField.shared.text = text
        MockField.shared.selection = FieldRange(location: text.utf16.count - 1, length: 0)
        p.controller.observe(p.observation(edit: edit))
    }

    @Test func aHeldDraftShowsInAReplyTypedIntoBeforeItSettledAndTabReplacesTheTyping() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, ended, view) = await threadProposals(route, settle: .milliseconds(300))
        await openAndWait(p, view)
        p.controller.observe(p.observation())
        // The focus read found the body blank before the first key.
        await until { p.reader.candidateReads == 1 }
        try await Task.sleep(for: .milliseconds(50))
        await typeInThreadReply("Hi\n", p, edit: 1)
        await typeInThreadReply("Hi P\n", p, edit: 2)
        await until { p.card.isShown }
        #expect(p.card.shown.first?.text == proposalDraft)
        // No second request: the reply took the thread's.
        #expect(route.created.count == 1)
        #expect(ended.outcomes.isEmpty)
        #expect(MockField.shared.text == "Hi P\n")
        // Typing on keeps it.
        await typeInThreadReply("Hi Priya\n", p, edit: 3)
        #expect(p.card.isShown)
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { p.card.confirmingReplacement }
        #expect(MockField.shared.text == "Hi Priya\n")
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { !ended.outcomes.isEmpty }
        #expect(ended.outcomes == [.inserted])
        #expect(MockField.shared.text == "Hey Priya, Harbor Hall fits what we need. Can you ask what they'd charge?")
    }

    @Test(arguments: [false, true], [false, true])
    func anotherThreadsHeldDraftLetsABlankReplyRequestAfterANotice(duringRead: Bool, typedBody: Bool) async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, ended, view) = await threadProposals(route, settle: .milliseconds(100))
        await openAndWait(p, view)
        p.reader.threadID = "18c2f4a9d0e1b3b7"
        p.reader.thread = "Priya Raman\nWhat time should we meet?"
        if duringRead {
            p.reader.beforeAnswer = { number in
                guard number == 1 else { return }
                if typedBody { await self.typeInThreadReply("Hi\n", p, edit: 1) }
                else { p.controller.observe(p.observation(edit: 1)) }
            }
        }
        let opened = p.observation()
        p.controller.observe(opened)
        await until { p.reader.candidateReads == 1 }
        if !duringRead {
            try await Task.sleep(for: .milliseconds(25))
            if typedBody { await typeInThreadReply("Hi\n", p, edit: 1) }
            else { p.controller.observe(p.observation(edit: 1)) }
        }
        if typedBody {
            try await Task.sleep(for: .milliseconds(400))
            #expect(route.created.count == 1)
            #expect(!p.card.isShown)
            #expect(MockField.shared.text == "Hi\n")
        } else {
            await until { p.card.isShown }
            #expect(route.created.count == 2)
            #expect(route.created.last?.compose.threadID == "18c2f4a9d0e1b3b7")
            #expect(route.created.last?.compose.observedThread == "Priya Raman\nWhat time should we meet?")
            #expect(p.card.shown.last?.text == proposalDraft)
            #expect(MockField.shared.text == "\n")
        }
        #expect(p.controller.heldThreads.map(\.key.threadID) == ["18c2f4a9d0e1b3a2"])
        #expect(ended.outcomes.isEmpty)
        if !typedBody {
            p.controller.reset()
            let trace = try #require(ended.traces.last)
            #expect(trace.opened == opened.startedAt)
            #expect(trace.replyFocused == opened.startedAt)
            let shown = try #require(trace.shown)
            #expect(trace.openToShownMilliseconds == Int((shown - opened.startedAt) / .milliseconds(1)))
        }
    }

    @Test func aReplyTypedIntoBeforeItSettledWithNothingHeldAsksForNothing() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, _, _) = await threadProposals(route, settle: .milliseconds(300))
        p.controller.observe(p.observation())
        await until { p.reader.candidateReads == 1 }
        try await Task.sleep(for: .milliseconds(50))
        await typeInThreadReply("Hi\n", p, edit: 1)
        try await Task.sleep(for: .milliseconds(600))
        #expect(route.created.isEmpty)
        #expect(p.reader.bodyReads == 0)
        #expect(!p.card.isShown)
    }

    @Test func aReplyThatHeldTextWhenFocusLandedTakesNoHeldDraftWhenTypedInto() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        // A draft Gmail reopened, with the person's earlier words in it.
        let (p, ended, view) = await threadProposals(route, settle: .milliseconds(300)) {
            $0.text = "Earlier words\n"
            $0.selection = FieldRange(location: 13, length: 0)
        }
        await openAndWait(p, view)
        p.controller.observe(p.observation())
        await until { p.reader.candidateReads == 1 }
        try await Task.sleep(for: .milliseconds(50))
        await typeInThreadReply("Earlier words, more\n", p, edit: 1)
        try await Task.sleep(for: .milliseconds(600))
        #expect(!p.card.isShown)
        #expect(p.card.shown.isEmpty)
        #expect(ended.outcomes.isEmpty)
        #expect(route.created.count == 1)
        #expect(MockField.shared.text == "Earlier words, more\n")
    }

    @Test func gmailsOwnChangeBeforeTheFirstKeyStillLetsTheHeldDraftShowOverTheTyping() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let (p, ended, view) = await threadProposals(route, settle: .milliseconds(300))
        await openAndWait(p, view)
        p.controller.observe(p.observation())
        await until { p.reader.candidateReads == 1 }
        try await Task.sleep(for: .milliseconds(50))
        // Gmail places the caret while the reply settles: a change with no
        // key, the body still blank, which the body is asked again for.
        p.controller.observe(p.observation(edit: 1))
        #expect(p.reader.candidateReads == 1)
        try await Task.sleep(for: .milliseconds(50))
        await typeInThreadReply("Hi\n", p, edit: 2)
        await until { p.card.isShown }
        #expect(ended.outcomes.isEmpty)
        #expect(route.created.count == 1)
        #expect(MockField.shared.text == "Hi\n")
    }

}




extension DictationScenarioTests {
    @Test func aSyntheticWatchReceivesOnlyItsOwnActivationNotifications() async {
        let source = NotificationCenter()
        let other = NotificationCenter()
        let watch = GmailThreadWatch(activationCenter: source, browserPID: { nil }, opened: { _ in })
        watch.start(while: { false })
        let before = watch.refreshes
        other.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        #expect(watch.refreshes == before)
        await Self.offMain { source.post(name: NSWorkspace.didActivateApplicationNotification, object: nil) }
        await until { watch.refreshes == before + 1 }
    }
}
