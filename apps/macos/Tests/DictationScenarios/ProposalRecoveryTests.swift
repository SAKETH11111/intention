import AppKit
@testable import Dictation
import Testing

extension DictationScenarioTests {
    @Test(arguments: [false, true])
    func aLateAcceptanceFailureRetainsItsTerminalDiagnostics(retried: Bool) async throws {
        let (p, outcomes) = await shownProposal()
        var traces: [ProposalTrace] = []
        p.controller.ended = { outcome, trace in
            outcomes.list.append(outcome)
            traces.append(trace)
        }
        p.route.onAccept = .fail(.server(403))
        if retried { p.route.firstAccepts = [.fail(.server(503))] }
        else { p.route.hold(.accept) }
        var delayed = false
        p.reader.beforeAnswer = { _ in
            if !delayed, p.route.accepted.count >= 1 {
                delayed = true
                try? await Task.sleep(for: .milliseconds(1400))
            }
        }
        p.controller.tabTaken(generation: try #require(p.tab))
        if !retried { await p.route.whileHeld(pause: .milliseconds(400)) {} }
        await until { outcomes.list == [.inserted] }
        let trace = try #require(traces.last)
        #expect(p.route.accepted.count == (retried ? 2 : 1))
        #expect(trace.failure == .request(.server(403)))
        #expect(trace.diagnostics.failureKind == .acceptanceFailed)
        #expect(ProposalTiming(.inserted, trace: trace).httpStatusClass == "4xx")
        #expect(trace.diagnostics.retried == retried)
    }

    @Test func anAcceptanceRetryBeforeInsertionEndsReachesItsTiming() async throws {
        let (p, outcomes) = await shownProposal()
        var traces: [ProposalTrace] = []
        p.controller.ended = { outcome, trace in
            outcomes.list.append(outcome)
            traces.append(trace)
        }
        p.route.firstAccepts = [.fail(.server(503)), .complete]
        var delayed = false
        p.reader.beforeAnswer = { _ in
            if !delayed, p.route.accepted.count == 1 {
                delayed = true
                try? await Task.sleep(for: .milliseconds(1100))
            }
        }
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { outcomes.list == [.inserted] }
        #expect(p.route.accepted.count == 2)
        #expect(try #require(traces.last).diagnostics.retried)
        #expect(ProposalTiming(.inserted, trace: try #require(traces.last)).httpStatusClass == "5xx")
    }

    @Test(arguments: [DraftRequestFailure.invalidInput, .server(403)])
    func aQuickAcceptanceFailureRetainsItsWriterProblem(failure: DraftRequestFailure) async throws {
        let (p, outcomes) = await shownProposal()
        var traces: [ProposalTrace] = []
        p.controller.ended = { outcome, trace in
            outcomes.list.append(outcome)
            traces.append(trace)
        }
        p.route.onAccept = .fail(failure)
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { outcomes.list == [.insertRefused] }
        let trace = try #require(traces.last)
        #expect(trace.failure == .request(failure))
        #expect(ProposalTiming(.insertRefused, trace: trace).failure?.httpStatusClass == "4xx")
        #expect(MockField.shared.text == "\n")
    }

    @Test(arguments: [false, true])
    func aNewAcceptanceAfterConfirmationFailureClearsTheOldProblem(expires: Bool) async throws {
        let (p, outcomes) = await shownProposal(acceptLimit: .milliseconds(500))
        var traces: [ProposalTrace] = []
        p.controller.ended = { outcome, trace in
            outcomes.list.append(outcome)
            traces.append(trace)
        }
        MockField.shared.text = "My reply\n"
        MockField.shared.selection = FieldRange(location: 3, length: 0)
        p.controller.observe(p.observation(edit: 1))
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { p.card.confirmingReplacement }
        p.route.onAccept = .fail(.invalidInput)
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { !outcomes.refused.isEmpty && p.card.isShown }
        #expect(outcomes.list.isEmpty)
        p.route.onAccept = .complete
        if expires {
            let nextRead = p.reader.bodyReads + 1
            p.reader.beforeAnswer = { number in
                if number == nextRead { try? await Task.sleep(for: .milliseconds(650)) }
            }
        }
        p.controller.tabTaken(generation: try #require(p.tab))
        if expires {
            await until { outcomes.list == [.insertRefused] }
            #expect(p.route.accepted.count == 1)
            #expect(MockField.shared.text == "My reply\n")
        } else {
            await until { p.card.confirmingReplacement }
            p.controller.tabTaken(generation: try #require(p.tab))
            await until { outcomes.list == [.inserted] }
            #expect(MockField.shared.text == proposalDraft)
        }
        #expect(try #require(traces.last).failure == nil)
    }

    @Test func slowAcceptanceInsertsWithinTheBoundAndRecordsTheSameRequestLater() async throws {
        let (p, outcomes) = await shownProposal()
        var presentations: [ProposalPresentation] = []
        p.controller.presentationChanged = { presentations.append($0) }
        p.route.hold(.accept)
        let started = ContinuousClock.now
        p.controller.tabTaken(generation: try #require(p.tab))
        await p.route.whileHeld(pause: .seconds(4)) {
            await self.until({ outcomes.list == [.inserted] }, within: .seconds(1))
            #expect(ContinuousClock.now - started < .seconds(1))
            #expect(MockField.shared.text == "Hey Priya, Harbor Hall fits what we need. Can you ask what they'd charge?\n")
            #expect(p.route.recordedAcceptances.isEmpty)
            #expect(presentations == [.pending, .idle])
            // A new request cannot cancel this acceptance's accounting.
            _ = await p.writer.propose(body: EmailBody(bundleIdentifier: "com.google.Chrome", body: "\n", recipients: [], subject: "", thread: "A synthetic message", threadID: "18c2f4a9d0e1b3a2", inThread: true))
        }
        await until { p.route.recordedAcceptances.count == 1 }
        #expect(p.route.recordedAcceptances == [p.route.created[0].requestID])
        #expect(outcomes.refused.isEmpty)
    }

    @Test func aQuickServerRefusalShowsImmediatelyAndInsertsNothing() async throws {
        let (p, outcomes) = await shownProposal()
        p.route.onAccept = .takeBack
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { outcomes.list == [.insertRefused] }
        #expect(MockField.shared.text == "\n")
        #expect(outcomes.refused.count == 1)
        #expect(!p.card.isShown)
    }

    @Test func aLateServerRefusalDoesNotUndoOrRaiseAStaleInsertionPopup() async throws {
        let (p, outcomes) = await shownProposal()
        p.route.hold(.accept)
        p.route.onAccept = .takeBack
        p.controller.tabTaken(generation: try #require(p.tab))
        await p.route.whileHeld(pause: .milliseconds(350)) {
            await self.until({ outcomes.list == [.inserted] }, within: .seconds(1))
        }
        #expect(MockField.shared.text == "Hey Priya, Harbor Hall fits what we need. Can you ask what they'd charge?\n")
        #expect(outcomes.refused.isEmpty)
    }

    @Test func acceptanceRetriesStayOnTheOriginalRequestAfterInsertion() async throws {
        let (p, outcomes) = await shownProposal()
        p.route.firstAccepts = [.fail(.server(503)), .complete]
        p.controller.tabTaken(generation: try #require(p.tab))
        await until({ outcomes.list == [.inserted] }, within: .seconds(1))
        await until { p.route.recordedAcceptances.count == 1 }
        #expect(p.route.accepted == [p.route.created[0].requestID, p.route.created[0].requestID])
    }

    @Test(arguments: ["recipients", "subject", "both"])
    func gmailCompletingAnEmptyHeaderRebindsWithoutAnotherRequest(completion: String) async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let p = await proposals(nil, route: route)
        p.reader.subject = ""
        p.reader.recipients = []
        route.hold(.create)
        p.controller.observe(p.observation())
        await route.whileHeld {
            if completion != "subject" { p.reader.recipients = [WritingRecipient(address: "priya@example.test", role: .to)] }
            if completion != "recipients" { p.reader.subject = "Re: Venue" }
        }
        await until { p.card.isShown }
        #expect(route.created.count == 1)
        #expect(MockField.shared.text == "\n")
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { MockField.shared.text != "\n" }
    }

    @Test func aChangedThreadAsksAgainOnceAndShowsTheFreshProposal() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let p = await proposals(nil, route: route)
        route.hold(.create)
        p.controller.observe(p.observation())
        await route.whileHeld { p.reader.thread = "Priya\nA newer synthetic question" }
        await until { p.card.isShown }
        #expect(route.created.count == 2)
        #expect(route.created.last?.compose.observedThread.contains("A newer synthetic question") == true)
    }

    @Test func aSecondDisplayMismatchEndsVisiblyWithoutAThirdRequest() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let p = await proposals(nil, route: route)
        let outcomes = Outcomes()
        var visibleEnds = 0
        p.controller.unavailable = { visibleEnds += 1 }
        p.controller.ended = { outcome, _ in outcomes.list.append(outcome) }
        route.hold(.create)
        p.controller.observe(p.observation())
        await route.whileHeld {
            p.reader.thread = "Priya\nFirst new question"
            let read = p.reader.bodyReads
            p.reader.beforeAnswer = { number in
                if number == read + 1 { p.reader.thread = "Priya\nSecond new question" }
            }
        }
        await until { !outcomes.list.isEmpty }
        #expect(outcomes.list == [.abstained])
        #expect(visibleEnds == 1)
        #expect(route.created.count == 2)
        #expect(!p.card.isShown)
    }

    @Test func replyDiagnosticsUseTheSpecifiedReasonNames() async throws {
        let (p, _) = await shownProposal()
        guard case let .success(.emailBody(original)) = await p.reader.readFocusedEmailDraft(text: true, expecting: nil, visibility: false).value
            else { Issue.record("Fixture must read as a reply"); return }
        #expect(ReplyProposalController.untouchedReplyFailures(original).isEmpty)
        var changed = original
        changed.field.before = "x"
        changed.selection = FieldRange(location: 1, length: 1)
        changed.bodyComplete = false
        changed.observation.body = "x"
        changed.observation.inThread = false
        changed.observation.threadID = nil
        changed.observation.subject = "Fwd: Venue"
        let other = ExpectedFocus(pid: original.field.pid + 1, started: original.field.started, element: original.field.element)
        #expect(ReplyProposalController.untouchedReplyFailures(changed, expecting: other)
            == ["before", "selection", "bodyIncomplete", "bodyNotEmpty", "notInThread", "noThreadID", "notReplyMode", "wrongElement"])
        let binding = ReplyProposalController.Binding(account: 1, focus: 1, capture: original)
        changed.observation.recipients = [WritingRecipient(address: "new@example.test", role: .to)]
        changed.observation.subject = "Re: New subject"
        changed.observation.thread = "Different thread"
        changed.field = FocusedField(pid: original.field.pid + 1, started: original.field.started, element: original.field.element, window: original.field.window, frame: original.field.frame, before: "x", bundleIdentifier: original.field.bundleIdentifier, labels: original.field.labels)
        #expect(binding.differences(changed, account: 2) == ["recipients", "subject", "thread", "threadID", "body", "account", "element"])
    }

    @Test func hintPlacementKeepsThePulseAndFullInkAcrossProposalStates() throws {
        let now = ContinuousClock.now
        var evidence = NativeCaretContinuity<CGRect>()
        let hint = CGRect(x: 100, y: 200, width: 1, height: 17)
        evidence.record(.unresolved, reading: nil, hint: hint, focus: 1, at: now)
        #expect(evidence.source(at: now) == "hint")
        #expect(evidence.shown(at: now) == hint)
        let view = DotMarkView(frame: CGRect(x: 0, y: 0, width: 200, height: 240))
        view.place(diameter: 12, ink: .black, center: CGPoint(x: 100, y: 190))
        let pending = DictationIndicators.dotLook(phase: .idle, proposal: .pending)
        #expect(pending == .working)
        view.look = .working
        let dot = try #require(view.layer?.sublayers?.last)
        #expect(dot.animation(forKey: "processing") != nil || dot.opacity == 0.4)
        #expect(!dot.isHidden)
        #expect(DictationIndicators.dotLook(phase: .idle, proposal: .shown) == .proposed)
        view.look = .proposed
        #expect(dot.animationKeys()?.isEmpty ?? true)
        #expect(dot.opacity == 1)
        #expect(view.currentFill.flatMap { NSColor(cgColor: $0) }?.alphaComponent == 1)
    }
    @Test(arguments: [ComposeAccess.ThreadReadReason.accessibility, .focus, .ownApp, .browser, .webArea, .address, .notGmail, .noThreadID, .messages, .pageChanged])
    func threadWatchLogsTheReasonItDidNotOpenAThread(reason: ComposeAccess.ThreadReadReason) async {
        let wanted = Proposals.Box(true)
        let before = AppLog.unscopedComposeLines.all.count
        let watch = GmailThreadWatch(activationCenter: NotificationCenter(), readThread: { .unavailable(reason) }, browserPID: { 41 },
                                    createObserver: { _, _ in nil }, opened: { _ in Issue.record("No thread should open") })
        watch.start(while: { wanted.value })
        await until { AppLog.unscopedComposeLines.all.dropFirst(before).contains("proposal.thread.noOpened." + reason.rawValue) }
        wanted.value = false
        watch.refresh()
    }

    @Test(arguments: [false, true])
    func aFailedSecondRequestEndsVisibly(withdrawn: Bool) async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let p = await proposals(nil, route: route)
        let outcomes = Outcomes()
        var visibleEnds = 0
        p.controller.unavailable = { visibleEnds += 1 }
        p.controller.ended = { outcome, _ in outcomes.list.append(outcome) }
        route.hold(.create)
        p.controller.observe(p.observation())
        await route.whileHeld {
            p.reader.thread = "Priya\nA new question"
            let read = p.reader.bodyReads
            p.reader.beforeAnswer = { number in
                if number == read + 1 { route.onCreate = withdrawn ? .takeBack : .fail(.invalidResponse) }
            }
        }
        await until { !outcomes.list.isEmpty }
        #expect(outcomes.list == [withdrawn ? .cancelled : .failed])
        #expect(visibleEnds == 1)
        #expect(route.created.count == 2)
        #expect(!p.card.isShown)
    }

}
