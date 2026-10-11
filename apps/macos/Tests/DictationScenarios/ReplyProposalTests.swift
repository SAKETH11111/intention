import AppKit
@testable import Dictation
import os
import Testing

// Reply proposals from the caret to the field: the controller against the
// scripted field as Gmail's reply body in Chrome, a draft route answered
// inside the process, a card that records what it is told, the dictation
// key's monitors wired as the app wires them, and the dot's observations
// made up. The scripted field has no thread list, so the body reads, the
// controller's and dictation's alike, are wrapped to say the body sits in
// the thread with an id, which is what the page reader finds on a real
// inline reply. The scenarios extend the dictation suite so that everything
// touching the scripted field runs in one serialized line.
extension DictationScenarioTests {
    /// A card that takes no screen and records what it is shown. As the
    /// real card does, one that fits nowhere hides itself.
    @MainActor
    final class ScriptedCard: ProposalCardPresenting {
        var shown: [(text: String, key: String, anchor: ProposalCardAnchor)] = []
        var hides = 0
        /// False makes the card fit nowhere, as a draft taller than the screen.
        var fits = true
        var isShown = false
        var acceptsInput = true
        var confirmingReplacement = false
        var keepClear: ProposalCard.KeepClear?
        var accepted: () -> Void = {}
        var screenLockedOrAsleep: () -> Void = {}
        /// Runs as the card hides, so a check can see the field then.
        var hiding: () -> Void = {}

        func beginConfirmation(keeping clear: ProposalCard.KeepClear?) -> Bool {
            keepClear = clear
            confirmingReplacement = true
            return true
        }

        func show(text: String, dictationKeyName: String, at anchor: ProposalCardAnchor) -> Bool {
            guard fits else {
                hide()
                return false
            }
            shown.append((text, dictationKeyName, anchor))
            isShown = true
            return true
        }

        func hide() {
            if isShown { hiding() }
            isShown = false
            hides += 1
        }
    }

    /// The inserter's own reads, with the page's part scripted: the body
    /// is told to sit in the thread's list with this id and these shown
    /// messages, as the page reader finds on a real inline reply.
    @MainActor
    final class ScriptedReader: ProposalReading {
        let inserter: TextInserter
        var inThread = true
        var threadID: String? = "18c2f4a9d0e1b3a2"
        var thread = "Priya Raman\nHi Sam, which venue do you prefer?"
        /// Set, the subject and recipients the page shows around the body,
        /// in place of the scripted field's none.
        var subject: String?
        var recipients: [WritingRecipient]?
        private(set) var candidateReads = 0
        var candidateAnswered: (@MainActor () async -> Void)?
        private(set) var bodyReads = 0
        private(set) var snapshotsCompleted = 0
        /// Runs once a body read has answered from the field and before the
        /// answer is handed on, with the read's number counted from one, as
        /// something that happens while the read is on its way.
        var beforeAnswer: (@MainActor (Int) async -> Void)?
        /// While true, candidate reads wait for `releaseCandidates` before
        /// they reach the inserter, as reads queued on its executor behind
        /// a slow one.
        var holdingCandidates = false
        private var heldCandidates: [@MainActor () -> Void] = []
        /// The `expecting` of every candidate read, in order.
        private(set) var candidateExpectations: [ExpectedFocus?] = []

        init(_ inserter: TextInserter) { self.inserter = inserter }

        func readProposalCandidate(expecting: ExpectedFocus?, blank: Bool) -> ProposalCandidateRead {
            candidateReads += 1
            candidateExpectations.append(expecting)
            guard holdingCandidates else {
                let inner = inserter.readProposalCandidate(expecting: expecting, blank: blank)
                guard let hook = candidateAnswered else { return inner }
                let read = ProposalCandidateRead()
                Task { @MainActor in
                    let value = await inner.value
                    if let reason = inner.rejection { read.reject(reason) }
                    if let focus = inner.focus { read.identify(focus) }
                    read.finish(value)
                    await hook()
                }
                return read
            }
            let read = ProposalCandidateRead()
            let inserter = inserter
            heldCandidates.append {
                let inner = inserter.readProposalCandidate(expecting: expecting, blank: blank)
                Task { read.finish(await inner.value) }
            }
            return read
        }

        /// Lets the held candidate reads go to the inserter.
        func releaseCandidates() {
            holdingCandidates = false
            let held = heldCandidates
            heldCandidates = []
            for start in held { start() }
        }

        var heldCandidateCount: Int { heldCandidates.count }

        func readProposalSnapshot(expecting: ExpectedFocus, visibility: Bool) -> ComposeRead {
            patch(inserter.readProposalSnapshot(expecting: expecting, visibility: visibility), snapshot: true)
        }

        func readFocusedEmailDraft(text: Bool, expecting: ExpectedFocus?, visibility: Bool) -> ComposeRead {
            patch(inserter.readFocusedEmailDraft(text: text, expecting: expecting, visibility: visibility))
        }

        private func patch(_ inner: ComposeRead, snapshot: Bool = false) -> ComposeRead {
            bodyReads += 1
            let number = bodyReads
            let read = ComposeRead()
            let inThread = inThread, threadID = threadID, thread = thread, hook = beforeAnswer
            let subject = subject, recipients = recipients
            Task { @MainActor in
                var result = await inner.value
                if case let .success(.emailBody(capture)) = result {
                    var patched = capture
                    patched.observation.inThread = inThread
                    patched.observation.threadID = threadID
                    patched.observation.thread = thread
                    if let subject { patched.observation.subject = subject }
                    if let recipients { patched.observation.recipients = recipients }
                    result = .success(.emailBody(patched))
                }
                await hook?(number)
                if snapshot { self.snapshotsCompleted += 1 }
                read.finish(result)
            }
            return read
        }
    }

    /// Everything a proposal scenario holds.
    @MainActor
    struct Proposals {
        let controller: ReplyProposalController
        let card: ScriptedCard
        let reader: ScriptedReader
        let writer: EmailWriter
        let route: ScriptedRoute
        let history: DictationHistory
        let dictation: DictationController
        let source: ScriptedSource
        let hold: HoldKey
        let pid: pid_t
        let taken: Box<[UInt64?]>
        let enabled: Box<Bool>
        /// Added to dictation's account counter, as another account would.
        let accountShift: Box<Int>

        final class Box<Value>: @unchecked Sendable {
            var value: Value
            init(_ value: Value) { self.value = value }
        }

        /// The dot's observation of the reply body with its caret placed,
        /// or with no field at all once the caret is gone.
        func observation(focus: Int = 1, edit: Int = 0, placed: Bool = true, caretX: CGFloat = 120) -> ProposalObservation {
            ProposalObservation(pid: pid, focus: focus, edit: edit, startedAt: .now, focused: placed,
                                caret: placed ? CGRect(x: caretX, y: 300, width: 1, height: 17) : nil,
                                field: placed ? CGRect(x: 100, y: 280, width: 640, height: 180) : nil, selection: MockField.shared.selection)
        }

        /// The tracker found the body and has neither a caret nor an
        /// estimate, as Gmail's zero-height empty body without Screen
        /// Recording; or, with `estimated`, an estimate with no field frame.
        func unplaced(focus: Int = 1, edit: Int = 0, estimated: Bool = false) -> ProposalObservation {
            ProposalObservation(pid: pid, focus: focus, edit: edit, startedAt: .now, focused: true,
                                caret: estimated ? CGRect(x: 120, y: 300, width: 1, height: 17) : nil, field: nil, selection: MockField.shared.selection)
        }

        /// The latest generation Tab was taken for.
        var tab: UInt64? { taken.value.last ?? nil }

        /// A key press as the dictation key's ordinary monitors see it, such
        /// as a character typed or Command-V.
        func pressKey(_ code: UInt16 = 0, flags: NSEvent.ModifierFlags = [], isRepeat: Bool = false) async {
            hold.received(HoldKey.Monitored(kind: .keyDown, keyCode: code, flags: flags.rawValue, isRepeat: isRepeat))
        }

        /// Escape as the dictation key's ordinary monitors see it.
        func pressEscape() {
            hold.received(HoldKey.Monitored(kind: .keyDown, keyCode: 53))
        }

        /// Focus moves to Gmail's search field, which is not a reply body.
        func focusSearch(focus: Int) {
            MockField.shared.focusedElement = 9
            MockField.shared.label = "Search mail"
            controller.observe(observation(focus: focus))
        }

        /// Focus comes back to the first reply body.
        func focusReply(focus: Int, element: Int = 1) {
            MockField.shared.focusedElement = element
            MockField.shared.label = "Message Body"
            controller.observe(observation(focus: focus))
        }
    }

    var proposalDraft: String { "Hey Priya, Harbor Hall fits what we need. Can you ask what they'd charge?" }

    /// The scripted field as Gmail's untouched reply body in Chrome, a
    /// writer over `route`, the controller with a scripted card and made-up
    /// screens, connected to the dictation key's monitors and to dictation
    /// over `endpoint` sharing the writer, as the app connects them.
    /// `presenter` puts a real card in place of the scripted one, which
    /// then shows nothing.
    func proposals(_ endpoint: DictationEndpoint?, route: ScriptedRoute, settle: Duration = .milliseconds(30),
                           keep: Duration = .seconds(5 * 60), validityInterval: Duration = .seconds(5), acceptLimit: Duration = ReplyProposalController.acceptLimit,
                           clipboardReadable: Bool = true, addSentWithIntention: Bool = false, presenter: (any ProposalCardPresenting)? = nil,
                           clock: any WriterClock = ContinuousWriterClock(),
                           configure: (MockField) -> Void = { _ in }) async -> Proposals {
        MockField.reset()
        let field = MockField.shared
        field.pasteboard = NSPasteboard(name: NSPasteboard.Name("co.intention.tests.\(UUID().uuidString)"))
        field.bundleIdentifier = "com.google.Chrome"
        field.web = true
        field.label = "Message Body"
        field.pageURL = "https://mail.google.com/mail/u/0/#inbox/FMfcgzQcqxTVrKbFnhGLlqnMJpVdwXkT"
        field.text = "\n"
        field.selection = FieldRange(location: 0, length: 0)
        // The page's view and the window, in Accessibility coordinates,
        // hold the body's top-left at (100, 100), so a card placed from
        // the body's frame shows.
        field.scrollArea = CGRect(x: 0, y: 80, width: 1440, height: 780)
        field.windowFrame = CGRect(x: 0, y: 25, width: 1440, height: 875)
        configure(field)
        let inserter = TextInserter(pasteboard: PasteboardOwner(pasteboard: field.pasteboard!, mayRead: { clipboardReadable }))
        let writer = EmailWriter(drafts: route, signedIn: true, pollInterval: .milliseconds(20),
                                 proposalPollInterval: .milliseconds(20), requestLimit: .seconds(5), clock: clock,
                                 addSentWithIntention: { addSentWithIntention })
        let history = DictationHistory(file: nil)
        let source = ScriptedSource()
        let dictation = DictationController(inserter: inserter, history: history, endpoint: endpoint,
                                            source: source, signedIn: true, writer: writer)
        dictation.noticePause = { try? await Task.sleep(for: .seconds(30)) }
        let card = ScriptedCard()
        let reader = ScriptedReader(inserter)
        dictation.emailBodies = reader
        let hold = HoldKey(handsFreeEnabled: true, key: .function, holdDelay: 0)
        let taken = Proposals.Box<[UInt64?]>([])
        let enabled = Proposals.Box(true)
        let shift = Proposals.Box(0)
        let controller = ReplyProposalController(
            inserter: inserter, reader: reader, writer: writer, card: presenter ?? card, history: history,
            takeTab: {
                taken.value.append($0)
                hold.takeTab(generation: $0)
            }, dictationKeyName: { "fn" },
            gate: { enabled.value ? nil : .setting },
            // A completed scenario releases its controller and its receipt polling.
            account: { [weak dictation] in (dictation?.account ?? -1) + shift.value },
            dictationIdle: { [weak dictation] in dictation?.phase == .idle },
            screens: { [ProposalScreen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visible: CGRect(x: 0, y: 0, width: 1440, height: 860))] },
            settle: settle, keep: keep, acceptLimit: acceptLimit, validityInterval: validityInterval)
        controller.connect(to: hold, dictation: dictation)
        let pid = (try? await inserter.readFocusedField().value.field.get())?.pid ?? 0
        return Proposals(controller: controller, card: card, reader: reader, writer: writer, route: route, history: history,
                         dictation: dictation, source: source, hold: hold, pid: pid, taken: taken, enabled: enabled, accountShift: shift)
    }

    /// Runs `body` on a background queue and waits for it, as macOS
    /// delivers a notification there.
    static func offMain(_ body: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                body()
                done.resume()
            }
        }
    }

    func until(_ condition: @escaping @MainActor () -> Bool, within limit: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now + limit
        while !(await condition()), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition())
    }

    /// A shown card for the reply, with its outcomes collected.
    func shownProposal(_ endpoint: DictationEndpoint? = nil, route: ScriptedRoute? = nil, keep: Duration = .seconds(5 * 60),
                       acceptLimit: Duration = ReplyProposalController.acceptLimit,
                       clipboardReadable: Bool = true, addSentWithIntention: Bool = false,
                       clock: any WriterClock = ContinuousWriterClock(),
                       configure: (MockField) -> Void = { _ in }) async -> (Proposals, Outcomes) {
        let p = await proposals(endpoint, route: route ?? ScriptedRoute(text: proposalDraft), keep: keep, acceptLimit: acceptLimit,
                                clipboardReadable: clipboardReadable, addSentWithIntention: addSentWithIntention, clock: clock, configure: configure)
        let outcomes = Outcomes()
        p.controller.ended = { outcome, trace in
            outcomes.list.append(outcome)
            outcomes.timings.append(ProposalTiming(outcome, trace: trace))
        }
        p.controller.notInserted = { outcomes.refused.append(($0, $1)) }
        p.controller.observe(p.observation())
        await until { p.card.isShown }
        return (p, outcomes)
    }

    @MainActor
    final class Outcomes {
        var list: [ProposalOutcome] = []
        var refused: [(EditReason, String)] = []
        var timings: [ProposalTiming] = []
    }

    // MARK: Proposing

    @Test func aProposalShowsAtTheCaretForAnUntouchedGmailReply() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let p = await proposals(nil, route: route)
        var presented: [ProposalPresentation] = []
        p.controller.presentationChanged = { presented.append($0) }
        p.controller.observe(p.observation())
        await until { p.card.isShown }
        let shown = try #require(p.card.shown.first)
        #expect(shown.text == proposalDraft)
        #expect(shown.key == "fn")
        // The first line starts where the caret is, in AppKit coordinates.
        #expect(shown.anchor.textOrigin == CGPoint(x: 120, y: 900 - 300))
        #expect(shown.anchor.bodyWidth == 620)
        let input = try #require(route.created.first)
        #expect(input.cue == "Reply to this thread")
        #expect(input.mode == .reply)
        #expect(input.compose.threadID == "18c2f4a9d0e1b3a2")
        #expect(input.compose.proposal)
        #expect(input.regeneration == nil)
        // Nothing was accepted or written: the card waits for the person.
        #expect(route.accepted.isEmpty)
        #expect(MockField.shared.text == "\n")
        #expect(p.tab != nil)
        #expect(p.controller.isShown)
        // The reply was read twice: for the request, and again before the card showed.
        #expect(p.reader.bodyReads == 2)
        // The dot pulsed while the request was on its way and is at full ink now.
        #expect(presented == [.pending, .shown])
    }

    @Test func anOrdinaryBrowserFieldCostsOneReadAndNoRequest() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let p = await proposals(nil, route: route) { $0.label = "Search mail" }
        let textReads = MockField.shared.textReads
        p.controller.observe(p.observation())
        try? await Task.sleep(for: .milliseconds(150))
        #expect(p.reader.candidateReads == 1)
        #expect(p.reader.bodyReads == 0)
        #expect(MockField.shared.textReads == textReads)
        #expect(route.created.isEmpty)
        #expect(!p.card.isShown)
    }

    @Test func aReplyWithTextBeforeTheCaretGetsNoProposal() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let p = await proposals(nil, route: route) {
            $0.text = "Thanks,\n"
            $0.selection = FieldRange(location: 7, length: 0)
        }
        p.controller.observe(p.observation())
        try? await Task.sleep(for: .milliseconds(200))
        #expect(p.reader.bodyReads == 1)
        #expect(route.created.isEmpty)
        #expect(!p.card.isShown)
    }

    @Test func aSelectionOfOneLineBreakGetsNoProposal() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let p = await proposals(nil, route: route) { $0.selection = FieldRange(location: 0, length: 1) }
        p.controller.observe(p.observation())
        try? await Task.sleep(for: .milliseconds(200))
        #expect(p.reader.bodyReads == 1)
        #expect(route.created.isEmpty)
    }

    /// 32,000 line breaks fit the body's limit whole; one more is cut, and
    /// a body read only in part cannot be known untouched.
    @Test(arguments: [(32_000, 1), (32_001, 0)])
    func aBodyCutToItsLimitGetsNoProposal(breaks: Int, requests: Int) async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let p = await proposals(nil, route: route) { $0.text = String(repeating: "\n", count: breaks) }
        p.controller.observe(p.observation())
        await until { p.reader.bodyReads >= 1 }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(route.created.count == requests)
    }

    @Test func aComposeOutsideTheThreadViewGetsNoProposal() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let p = await proposals(nil, route: route)
        p.reader.inThread = false
        p.controller.observe(p.observation())
        try? await Task.sleep(for: .milliseconds(200))
        #expect(route.created.isEmpty)
        #expect(!p.card.isShown)
    }

    @Test func aTypedEditWhileTheBodyIsReadEndsTheCandidate() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let p = await proposals(nil, route: route)
        // The settle ended with no edit; the person types while the body is read.
        p.reader.beforeAnswer = { number in
            if number == 1 {
                await p.pressKey()
                p.controller.observe(p.observation(edit: 1))
            }
        }
        p.controller.observe(p.observation())
        await until { p.reader.bodyReads == 1 }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(p.reader.bodyReads == 1)
        #expect(route.created.isEmpty)
        #expect(!p.controller.isPending)
    }

    @Test func gmailChangingTheBodyAsTheReplyOpensStartsTheSettleAgain() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let p = await proposals(nil, route: route, settle: .milliseconds(200))
        p.controller.observe(p.observation())
        try? await Task.sleep(for: .milliseconds(120))
        // Gmail places the caret in the body: no key went down.
        p.controller.observe(p.observation(edit: 1))
        try? await Task.sleep(for: .milliseconds(140))
        // Without the change the body would have been read by now.
        #expect(p.reader.bodyReads == 0)
        await until { p.card.isShown }
        #expect(route.created.count == 1)
        // And while the body is read: the settle starts again and reads it once more.
        let q = await proposals(nil, route: ScriptedRoute(text: proposalDraft))
        q.reader.beforeAnswer = { number in if number == 1 { q.controller.observe(q.observation(edit: 1)) } }
        q.controller.observe(q.observation())
        await until { q.card.isShown }
        #expect(q.route.created.count == 1)
        // The read the change interrupted, the read after the new settle, and the check before showing.
        #expect(q.reader.bodyReads == 3)
    }

    @Test func aTypedEditDuringTheSettleEndsTheCandidate() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let p = await proposals(nil, route: route, settle: .milliseconds(200))
        p.controller.observe(p.observation())
        try? await Task.sleep(for: .milliseconds(150))
        await p.pressKey()
        // The first wait ends with the key and starts again; the character's
        // notification arrives in the second, still after a key since the
        // settle began.
        try? await Task.sleep(for: .milliseconds(100))
        p.controller.observe(p.observation(edit: 1))
        try? await Task.sleep(for: .milliseconds(500))
        #expect(p.reader.bodyReads == 0)
        #expect(route.created.isEmpty)
    }

    @Test func aKeyPressDuringTheSettleStartsItAgain() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let p = await proposals(nil, route: route, settle: .milliseconds(200))
        p.controller.observe(p.observation())
        try? await Task.sleep(for: .milliseconds(120))
        // A key that changes nothing in the field, such as a shortcut.
        p.hold.received(HoldKey.Monitored(kind: .keyDown, keyCode: 0))
        try? await Task.sleep(for: .milliseconds(140))
        // Without the press the body would have been read by now.
        #expect(p.reader.bodyReads == 0)
        await until { p.card.isShown }
        #expect(route.created.count == 1)
    }

    @Test func typingWhileTheProposalIsOnItsWayKeepsItAndItShowsWhenItArrives() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let p = await proposals(nil, route: route)
        let outcomes = Outcomes()
        p.controller.ended = { outcome, _ in outcomes.list.append(outcome) }
        route.hold(.create)
        p.controller.observe(p.observation())
        await route.whileHeld {
            // Two characters typed: a key goes down and the field changes, each time.
            await p.pressKey()
            MockField.shared.text = "H\n"
            MockField.shared.selection = FieldRange(location: 1, length: 0)
            p.controller.observe(p.observation(edit: 1))
            await p.pressKey()
            MockField.shared.text = "Hi\n"
            MockField.shared.selection = FieldRange(location: 2, length: 0)
            p.controller.observe(p.observation(edit: 2))
            #expect(p.controller.isPending)
        }
        await until { p.card.isShown }
        #expect(p.card.shown.first?.text == proposalDraft)
        #expect(outcomes.list.isEmpty)
        #expect(route.cancelled.isEmpty)
        // Nothing went in: the person's two characters are all the body holds.
        #expect(MockField.shared.text == "Hi\n")
        #expect(route.accepted.isEmpty)
    }

    @Test func anEditorNoticeWhilePendingKeepsTheCard() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let p = await proposals(nil, route: route)
        let outcomes = Outcomes()
        p.controller.ended = { outcome, _ in outcomes.list.append(outcome) }
        route.hold(.create)
        p.controller.observe(p.observation())
        await route.whileHeld {
            // Gmail moves the caret in its own body as the reply opens.
            p.controller.observe(p.observation(edit: 1))
            #expect(p.controller.isPending)
        }
        await until { p.card.isShown }
        #expect(outcomes.list.isEmpty)
        #expect(p.card.shown.count == 1)
        #expect(route.cancelled.isEmpty)
    }

    @Test func aBodyGmailChangedWhilePendingKeepsTheCard() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let p = await proposals(nil, route: route)
        let outcomes = Outcomes()
        p.controller.ended = { outcome, _ in outcomes.list.append(outcome) }
        route.hold(.create)
        p.controller.observe(p.observation())
        await route.whileHeld {
            // Gmail puts a signature in the body: no key went down.
            MockField.shared.text = "\n\n-- \nSam\n"
            p.controller.observe(p.observation(edit: 1))
            #expect(p.controller.isPending)
        }
        await until { p.card.isShown }
        #expect(outcomes.list.isEmpty)
        #expect(p.card.shown.count == 1)
        #expect(p.card.isShown)
    }

    // MARK: Accepting

    @Test func concurrentAccessibilityReadsKeepEveryRecordedAttribute() async {
        let field = MockField()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await Task.detached {
                        for _ in 0..<1000 { field.recordRead(of: 1, "AXRole") }
                    }.value
                }
            }
        }
        #expect(field.fieldReads[1]?.count == 8000)
        #expect(field.fieldReads[1]?.allSatisfy { $0 == "AXRole" } == true)
    }

    @Test func tabPutsTheProposalInWithVisibleAcceptance() async throws {
        let (p, outcomes) = await shownProposal()
        var presented: [ProposalPresentation] = []
        p.controller.presentationChanged = { presented.append($0) }
        // The card stays, taking no input, until the text is in the field,
        // so Gmail's empty-body hint under it never shows in between.
        var fieldAtHide: [String] = []
        p.card.hiding = { fieldAtHide.append(MockField.shared.text) }
        let generation = try #require(p.tab)
        p.route.hold(.accept)
        p.controller.tabTaken(generation: generation)
        await p.route.whileHeld {
            #expect(p.controller.isAccepting)
            #expect(p.card.isShown)
            #expect(!p.card.acceptsInput)
        }
        #expect(p.taken.value.last == .some(nil))
        await until { outcomes.list.last == .inserted }
        #expect(!p.card.isShown)
        #expect(fieldAtHide.count == 1)
        #expect(fieldAtHide.first?.hasPrefix(proposalDraft) == true)
        #expect(p.route.accepted == [p.route.created.first?.requestID].compactMap { $0 })
        #expect(MockField.shared.text.hasPrefix(proposalDraft))
        let entry = try #require(p.history.entries.first)
        #expect(entry.text == proposalDraft)
        #expect(entry.outcome == .inserted)
        #expect(entry.proposal == .accepted)
        #expect(presented == [.pending, .idle])
        // A Tab from an earlier card does nothing now.
        p.controller.tabTaken(generation: generation)
        #expect(outcomes.list == [.inserted])
    }

    @Test func aTabWithAnotherGenerationDoesNothing() async throws {
        let (p, _) = await shownProposal()
        p.controller.tabTaken(generation: 999)
        #expect(p.card.isShown)
        #expect(p.route.accepted.isEmpty)
    }

    @Test func escapeThroughTheMonitorsAfterTabLatchesTheAccept() async throws {
        let (p, outcomes) = await shownProposal()
        p.route.hold(.accept)
        p.controller.tabTaken(generation: try #require(p.tab))
        await p.route.whileHeld { p.pressEscape() }
        await until { !outcomes.list.isEmpty }
        #expect(outcomes.list == [.dismissed])
        // A refusal after the person's own accept opens the popup with the
        // text and Copy, even one the person caused.
        #expect(outcomes.refused.count == 1)
        #expect(outcomes.refused.first?.0 == .composeChanged)
        #expect(outcomes.refused.first?.1 == proposalDraft)
        #expect(MockField.shared.text == "\n")
        // The server recorded the accept; nothing went in.
        #expect(p.route.accepted.count == 1)
        let entry = try #require(p.history.entries.first)
        #expect(entry.proposal == .unused)
        #expect(entry.reason == "dismissed")
        #expect(entry.text == proposalDraft)
    }

    @Test func anEditAfterTabLatchesTheAccept() async throws {
        let (p, outcomes) = await shownProposal()
        p.route.hold(.accept)
        p.controller.tabTaken(generation: try #require(p.tab))
        // Typed and erased: the field reads as it did, but it was edited.
        await p.route.whileHeld { p.controller.observe(p.observation(edit: 1)) }
        await until { !outcomes.list.isEmpty }
        #expect(outcomes.list == [.ignored])
        #expect(MockField.shared.text == "\n")
        #expect(outcomes.refused.count == 1)
        #expect(outcomes.refused.first?.0 == .fieldChanged)
        #expect(outcomes.refused.first?.1 == proposalDraft)
        #expect(p.history.entries.count == 1)
    }

    @Test func focusLeavingAfterTabLatchesTheAccept() async throws {
        let (p, outcomes) = await shownProposal()
        p.route.hold(.accept)
        p.controller.tabTaken(generation: try #require(p.tab))
        // Away and straight back: the latch holds.
        await p.route.whileHeld {
            p.controller.observe(p.observation(focus: 2))
            // The card held for the insertion goes with the focus.
            #expect(!p.card.isShown)
            p.controller.observe(p.observation(focus: 3))
        }
        await until { !outcomes.list.isEmpty }
        #expect(outcomes.list == [.left])
        #expect(MockField.shared.text == "\n")
        #expect(outcomes.refused.first?.0 == .focusChanged)
        #expect(outcomes.refused.first?.1 == proposalDraft)
    }

    @Test func aResetAfterTabLatchesTheAccept() async throws {
        let (p, outcomes) = await shownProposal()
        p.route.hold(.accept)
        p.controller.tabTaken(generation: try #require(p.tab))
        await p.route.whileHeld { p.controller.reset() }
        await until { !outcomes.list.isEmpty }
        #expect(outcomes.list == [.left])
        #expect(MockField.shared.text == "\n")
        #expect(outcomes.refused.first?.0 == .focusChanged)
        #expect(outcomes.refused.first?.1 == proposalDraft)
    }

    @Test func escapeWhileTheInserterRunsRefusesTheWriteAtItsGuard() async throws {
        let (p, outcomes) = await shownProposal()
        let controller = p.controller
        let fired = OSAllocatedUnfairLock(initialState: false)
        // Once the read before inserting has answered, the first read of the
        // field's text inside the insertion presses Escape, so the accept is
        // latched only after every check on the main actor has passed.
        p.reader.beforeAnswer = { number in
            guard number == 3 else { return }
            MockField.shared.onTextRead = {
                guard fired.withLock({ let first = !$0; $0 = true; return first }) else { return }
                DispatchQueue.main.sync { MainActor.assumeIsolated { controller.escapePressed() } }
            }
        }
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { !outcomes.list.isEmpty }
        MockField.shared.onTextRead = nil
        #expect(fired.withLock { $0 })
        #expect(outcomes.list == [.dismissed])
        #expect(MockField.shared.text == "\n")
        #expect(outcomes.refused.count == 1)
        #expect(outcomes.refused.first?.0 == .composeChanged)
        #expect(outcomes.refused.first?.1 == proposalDraft)
        #expect(p.history.entries.count == 1)
        #expect(p.history.entries.first?.proposal == .unused)
    }

    @Test func anAcceptPastItsDeadlineIsRefusedWithTheText() async throws {
        let (p, outcomes) = await shownProposal(acceptLimit: .milliseconds(300))
        // The read before inserting takes longer than the accept may.
        p.reader.beforeAnswer = { number in if number == 3 { try? await Task.sleep(for: .milliseconds(400)) } }
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { !outcomes.list.isEmpty }
        #expect(outcomes.list == [.insertRefused])
        #expect(outcomes.refused.first?.0 == .busy)
        #expect(outcomes.refused.first?.1 == proposalDraft)
        #expect(MockField.shared.text == "\n")
        #expect(p.history.entries.first?.proposal == .accepted)
        #expect(p.history.entries.first?.outcome == .notInserted)
    }

    @Test func anAcceptTheServerRefusesSaysSoAndOffersTheText() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        route.onAccept = .takeBack
        let (p, outcomes) = await shownProposal(route: route)
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { !outcomes.list.isEmpty }
        #expect(outcomes.list == [.insertRefused])
        #expect(outcomes.refused.first?.1 == proposalDraft)
        #expect(MockField.shared.text == "\n")
        #expect(p.history.entries.first?.outcome == .notInserted)
    }

    @Test(arguments: [DraftRequestFailure.invalidInput, .server(403)])
    func aQuickWriterRejectionKeepsItsReasonInsteadOfAnInsertReason(_ failure: DraftRequestFailure) async throws {
        let (p, outcomes) = await shownProposal()
        p.route.onAccept = .fail(failure)
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { outcomes.list == [.insertRefused] }
        let timing = try #require(outcomes.timings.last)
        #expect(timing.failure == .request(failure))
        #expect(timing.insertionResult == nil)
        #expect(timing.diagnostics.failureKind == .acceptanceFailed)
        #expect(timing.httpStatusClass == "4xx")
        #expect(MockField.shared.text == "\n")
    }

    @Test func anInsertionTheFieldRefusesOpensThePopup() async throws {
        let (p, outcomes) = await shownProposal()
        // Focus goes to another app after the read before inserting.
        p.reader.beforeAnswer = { number in if number == 4 { MockField.shared.focusedElsewhere = true } }
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { !outcomes.list.isEmpty }
        #expect(outcomes.list == [.insertRefused])
        #expect(outcomes.timings.last?.insertionResult == .notInserted(.focusChanged))
        #expect(outcomes.refused.first?.0 == .focusChanged)
        #expect(outcomes.refused.first?.1 == proposalDraft)
        #expect(MockField.shared.text == "\n")
        let entry = try #require(p.history.entries.first)
        #expect(entry.outcome == .notInserted)
        #expect(entry.reason == "focusChanged")
        #expect(entry.proposal == .accepted)
    }

    @Test func aPasteThatCannotPutTheClipboardBackSaysSoAsADictationDoes() async throws {
        let (p, outcomes) = await shownProposal(clipboardReadable: false) { $0.writes = .refuse }
        let pasteboard = try #require(MockField.shared.pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("the person's clipboard", forType: .string)
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { !outcomes.list.isEmpty }
        #expect(outcomes.list == [.inserted])
        #expect(MockField.shared.text.hasPrefix(proposalDraft))
        #expect(p.dictation.notice == .clipboardReplaced)
        #expect(p.dictation.pasteReplacedClipboard)
        #expect(p.history.entries.first?.proposal == .accepted)
    }

    @Test func aBoundReadReadsNothingOfAnotherFocusedField() async throws {
        let p = await proposals(nil, route: ScriptedRoute(text: proposalDraft))
        let found = await p.reader.inserter.readProposalCandidate().value
        let candidate = try #require(try found.get())
        // The candidate read gives the body's frame, for a card with no caret.
        #expect(candidate.frame == CGRect(x: 100, y: 100, width: 300, height: 40))
        let field = MockField.shared
        field.focusedElement = 2
        let textReads = field.textReads, measures = field.measures, lengths = field.lengthReads, beyond = field.readsBeyondField
        let refused = await p.reader.inserter.readFocusedEmailDraft(text: true, expecting: candidate.expectation).value
        guard case .failure(.focusChanged) = refused else {
            Issue.record("a read bound to the reply read another field")
            return
        }
        #expect(field.textReads == textReads)
        #expect(field.measures == measures)
        #expect(field.lengthReads == lengths)
        #expect(field.readsBeyondField == beyond)
        // The same read finds the reply once it has focus again.
        field.focusedElement = 1
        let read = await p.reader.inserter.readFocusedEmailDraft(text: true, expecting: candidate.expectation).value
        guard case let .success(.emailBody(capture)) = read else {
            Issue.record("the reply was not read")
            return
        }
        #expect(capture.observation.body == "\n")
        #expect(capture.selection == FieldRange(location: 0, length: 0))
        #expect(capture.bodyComplete)
    }

    // MARK: Ending

    @Test func escapeDismissesTheProposalAndHistoryKeepsItUnused() async throws {
        let (p, outcomes) = await shownProposal()
        p.pressEscape()
        #expect(!p.card.isShown)
        #expect(outcomes.list == [.dismissed])
        #expect(p.route.accepted.isEmpty)
        #expect(MockField.shared.text == "\n")
        let entry = try #require(p.history.entries.first)
        #expect(entry.outcome == .notInserted)
        #expect(entry.reason == "dismissed")
        #expect(entry.proposal == .unused)
        // Nothing comes back for the same body.
        p.controller.observe(p.observation(edit: 0))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!p.card.isShown)
        #expect(p.route.created.count == 1)
    }

    @Test func anEndedReplyLeftAndReturnedToGetsNoNewProposal() async throws {
        let (p, outcomes) = await shownProposal()
        p.pressEscape()
        p.focusSearch(focus: 2)
        p.focusReply(focus: 3)
        await until { p.reader.candidateReads == 3 }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(outcomes.list == [.dismissed])
        #expect(p.route.created.count == 1)
        #expect(p.reader.bodyReads == 2)
        #expect(!p.card.isShown)
    }

    @Test func typingKeepsAShownCard() async throws {
        let (p, outcomes) = await shownProposal()
        let reads = p.reader.bodyReads
        await p.pressKey()
        MockField.shared.text = "Sure\n"
        MockField.shared.selection = FieldRange(location: 4, length: 0)
        p.controller.observe(p.observation(edit: 1, caretX: 150))
        #expect(p.card.isShown)
        #expect(p.controller.isShown)
        // The card follows the caret as the person types.
        #expect(p.card.shown.last?.anchor.textOrigin == CGPoint(x: 150, y: 900 - 300))
        try await Task.sleep(for: .milliseconds(100))
        #expect(outcomes.list.isEmpty)
        // Editing requires no body read to attribute the change.
        #expect(p.reader.bodyReads == reads)
        #expect(p.route.accepted.isEmpty)
        #expect(MockField.shared.text == "Sure\n")
    }

    @Test func aKeyBeforeTheCardShowedDoesNotEndItOnAGmailChange() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let p = await proposals(nil, route: route)
        let outcomes = Outcomes()
        p.controller.ended = { outcome, _ in outcomes.list.append(outcome) }
        route.hold(.create)
        p.controller.observe(p.observation())
        // A shortcut while the request is on its way changes nothing in the field.
        await route.whileHeld { await p.pressKey() }
        await until { p.card.isShown }
        p.controller.observe(p.observation(edit: 1))
        #expect(p.card.isShown)
        #expect(outcomes.list.isEmpty)
    }

    @Test func focusLeavingHidesTheCardAndReturningShowsItAgainWithoutAnotherRequest() async throws {
        let (p, _) = await shownProposal()
        p.focusSearch(focus: 2)
        #expect(!p.card.isShown)
        #expect(p.controller.isHidden)
        #expect(p.taken.value.last == .some(nil))
        p.focusReply(focus: 3)
        await until { p.card.isShown }
        #expect(p.route.created.count == 1)
        #expect(p.card.shown.count == 2)
        // The reply was read again before it showed.
        #expect(p.reader.bodyReads == 3)
    }

    @Test func aHiddenCardWhoseThreadChangedAsksAgainAndShowsTheFreshReply() async throws {
        let (p, outcomes) = await shownProposal()
        p.focusSearch(focus: 2)
        p.reader.thread = "Sam Lee\nActually, let's do Thursday.\n\nPriya Raman\nHi Sam, which venue do you prefer?"
        p.focusReply(focus: 3)
        await until { p.card.shown.count == 2 }
        #expect(outcomes.list.isEmpty)
        #expect(p.route.created.count == 2)
        #expect(p.route.created.last?.compose.observedThread.contains("Thursday") == true)
        #expect(p.card.isShown)
    }

    @Test func aDisplayCheckFinishingAfterFocusMovedShowsNothing() async throws {
        let (p, outcomes) = await shownProposal()
        p.focusSearch(focus: 2)
        // The check for the reply's return reads it as bound, and focus
        // moves away again before its answer is taken.
        p.reader.beforeAnswer = { number in if number == 3 { p.focusSearch(focus: 4) } }
        p.focusReply(focus: 3)
        await until { p.reader.bodyReads == 3 }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(!p.card.isShown)
        #expect(p.controller.isHidden)
        #expect(p.card.shown.count == 1)
        #expect(outcomes.list.isEmpty)
        // A Tab for the earlier card does nothing.
        p.controller.tabTaken(generation: try #require(p.taken.value.compactMap { $0 }.last))
        #expect(p.route.accepted.isEmpty)
    }

    @Test func theCaretGoingHidesTheCardAndComingBackShowsItAfterAFreshCheck() async throws {
        let (p, _) = await shownProposal()
        let first = try #require(p.tab)
        p.controller.observe(p.observation(placed: false))
        #expect(!p.card.isShown)
        p.controller.observe(p.observation())
        await until { p.card.isShown }
        #expect(p.card.shown.count == 2)
        #expect(p.reader.bodyReads == 3)
        // Each showing takes Tab with a generation of its own.
        #expect(p.tab != first)
        p.controller.tabTaken(generation: first)
        #expect(p.card.isShown)
    }

    @Test func aScreenLockHidesTheCardAndItComesBackAfterAFreshCheck() async throws {
        let (p, _) = await shownProposal()
        p.card.isShown = false
        p.card.screenLockedOrAsleep()
        #expect(p.controller.isHidden)
        #expect(p.taken.value.last == .some(nil))
        p.controller.observe(p.observation(caretX: 121))
        await until { p.card.isShown }
        #expect(p.reader.bodyReads == 3)
    }

    @Test func anEditorInsertionBeforeTheCardShowsKeepsTheProposal() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        route.beforeRead = { MockField.shared.text = "\n\nOn Monday, Priya wrote:\n> which venue?" }
        let p = await proposals(nil, route: route)
        var outcomes: [ProposalOutcome] = []
        p.controller.ended = { outcome, _ in outcomes.append(outcome) }
        p.controller.observe(p.observation())
        await until { p.card.isShown }
        #expect(outcomes.isEmpty)
        #expect(route.accepted.isEmpty)
        #expect(MockField.shared.text == "\n\nOn Monday, Priya wrote:\n> which venue?")
    }

    @Test func aCardThatFitsNowhereWaitsHidden() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let p = await proposals(nil, route: route)
        p.card.fits = false
        p.controller.observe(p.observation())
        await until { p.controller.isHidden }
        #expect(!p.card.isShown)
        #expect(p.tab == nil)
        p.card.fits = true
        // The same place is not checked again; a caret that moved is.
        p.controller.observe(p.observation(caretX: 130))
        await until { p.card.isShown }
    }

    @Test func aShownCardThatStopsFittingLetsTabGoAtOnce() async throws {
        let (p, outcomes) = await shownProposal()
        let generation = try #require(p.tab)
        p.card.fits = false
        p.controller.observe(p.observation(caretX: 1400))
        #expect(!p.card.isShown)
        #expect(p.controller.isHidden)
        #expect(p.taken.value.last == .some(nil))
        p.controller.tabTaken(generation: generation)
        #expect(p.route.accepted.isEmpty)
        #expect(outcomes.list.isEmpty)
    }

    @Test func anImportAbstentionShowsANoticeWithoutACard() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        route.onRead = .abstain(.mailImportPending)
        let p = await proposals(nil, route: route)
        var notices = 0
        p.controller.mailImportPending = { notices += 1 }
        var outcomes: [ProposalOutcome] = []
        p.controller.ended = { outcome, _ in outcomes.append(outcome) }
        p.controller.observe(p.observation())
        await until { !outcomes.isEmpty }
        #expect(outcomes == [.abstained])
        #expect(notices == 1)
        #expect(!p.card.isShown)
        #expect(p.history.entries.isEmpty)
    }

    @Test func theProposalExpiresAfterItsKeepTime() async throws {
        let (p, outcomes) = await shownProposal(keep: .milliseconds(150))
        await until { outcomes.list == [.expired] }
        #expect(!p.card.isShown)
        #expect(p.history.entries.first?.proposal == .unused)
    }

    @Test func turningTheSettingOffEndsTheProposal() async throws {
        let (p, outcomes) = await shownProposal()
        p.enabled.value = false
        p.controller.reset()
        #expect(!p.card.isShown)
        #expect(outcomes.list == [.left])
        // Nothing runs while it is off.
        p.controller.observe(p.observation(focus: 5))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(p.route.created.count == 1)
    }

    // MARK: Two replies

    /// One live proposal at a time: the first reply's, unused, is held for
    /// its thread when a reply in another thread becomes a candidate, and
    /// returning to the first shows it again with no request and no second
    /// admission, while the second is held in its turn.
    @Test func aSecondReplyHoldsTheFirstProposalAndReturningToTheFirstShowsIt() async throws {
        let (p, outcomes) = await shownProposal()
        let first = try #require(p.route.created.first?.requestID)
        let thread = p.reader.thread
        // Another reply, a distinct body element in another thread.
        p.reader.threadID = "18c2f4a9d0e1b3b7"
        p.reader.thread = "Tomás Ortega\nCan you send the deck before Friday?"
        p.focusReply(focus: 2, element: 2)
        await until { p.route.created.count == 2 && p.card.shown.count == 2 }
        #expect(outcomes.list.isEmpty)
        #expect(p.route.created.last?.requestID != first)
        #expect(p.history.entries.isEmpty)
        // Back to the first reply: its proposal shows again.
        p.reader.threadID = "18c2f4a9d0e1b3a2"
        p.reader.thread = thread
        p.focusReply(focus: 3, element: 1)
        await until { p.card.shown.count == 3 }
        #expect(p.card.shown.last?.text == proposalDraft)
        #expect(p.route.created.count == 2)
        #expect(p.route.shownCalls.count == 2)
        #expect(outcomes.list.isEmpty)
        #expect(p.controller.isShown)
    }

    // MARK: The body's frame

    @Test func withNoCaretOrEstimateTheCardStartsAtTheBodysTopLeft() async throws {
        let p = await proposals(nil, route: ScriptedRoute(text: proposalDraft))
        p.controller.observe(p.unplaced())
        await until { p.card.isShown }
        let anchor = try #require(p.card.shown.first?.anchor)
        // The body is at (100, 100), 300 by 40, in Accessibility coordinates.
        #expect(anchor.textOrigin == CGPoint(x: 100, y: 900 - 100))
        #expect(anchor.bodyWidth == 300)
    }

    @Test func anEstimateWithNoFieldIsNoWiderThanTheBody() async throws {
        let p = await proposals(nil, route: ScriptedRoute(text: proposalDraft))
        p.controller.observe(p.unplaced(estimated: true))
        await until { p.card.isShown }
        let anchor = try #require(p.card.shown.first?.anchor)
        #expect(anchor.textOrigin == CGPoint(x: 120, y: 900 - 300))
        // The body's right edge is at 400; the caret's left edge at 120.
        #expect(abs(anchor.bodyWidth - 280) < 0.001)
    }

    @Test func aNarrowBodyGivesANarrowAnchor() async throws {
        let p = await proposals(nil, route: ScriptedRoute(text: proposalDraft)) { $0.frameWidth = 150 }
        p.controller.observe(p.unplaced())
        await until { p.card.isShown }
        #expect(p.card.shown.first?.anchor.bodyWidth == 150)
    }

    // MARK: Dictation

    @Test func aDictationStartingCancelsAPendingProposal() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        route.onRead = .pending
        let p = await proposals(nil, route: route)
        var outcomes: [ProposalOutcome] = []
        p.controller.ended = { outcome, _ in outcomes.append(outcome) }
        p.controller.observe(p.observation())
        await until { p.controller.isPending }
        p.controller.dictationStarted()
        #expect(outcomes == [.cancelled])
        let id = try #require(route.created.first?.requestID)
        await until { route.cancelled.contains(id) }
    }

    @Test func noCandidateStartsWhileDictationRecords() async throws {
        let server = try await ScriptedEndpoint([.silent])
        defer { server.stop() }
        let p = await proposals(server.endpoint, route: ScriptedRoute(text: proposalDraft))
        p.dictation.toggle()
        #expect(p.dictation.phase == .recording)
        p.controller.observe(p.observation())
        try? await Task.sleep(for: .milliseconds(150))
        #expect(p.reader.candidateReads == 0)
        #expect(p.route.created.isEmpty)
        p.dictation.cancel()
    }

    @Test func aReplyFocusedDuringARecordingIsProposedIntoOnceItEnds() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "", text: "")])
        defer { server.stop() }
        let p = await proposals(server.endpoint, route: ScriptedRoute(text: proposalDraft), settle: .milliseconds(250)) {
            $0.label = "Search mail"
        }
        p.dictation.toggle()
        #expect(p.dictation.phase == .recording)
        // The reply opens while the person speaks: the only focus change
        // is dropped, and the caret's later observations keep its focus.
        MockField.shared.label = "Message Body"
        p.controller.observe(p.observation(focus: 2))
        p.controller.observe(p.observation(focus: 2, caretX: 121))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(p.reader.candidateReads == 0)
        // The recording ends without words; dictation reports it just
        // before it turns idle.
        var ended: ContinuousClock.Instant?
        p.dictation.onOutcome = { _, _, _ in ended = .now }
        p.dictation.toggle()
        await until({ p.dictation.phase == .idle }, within: .seconds(10))
        await until { !p.route.created.isEmpty }
        // The settle ran from the retry.
        #expect(ContinuousClock.now - (try #require(ended)) >= .milliseconds(250))
        #expect(p.route.created.first?.compose.proposal == true)
        await until { p.card.isShown }
        #expect(MockField.shared.text == "\n")
    }

    @Test func aReplyFocusedAsWordsGoElsewhereIsProposedIntoOnceTheyAreIn() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "which venue", text: "which venue")])
        defer { server.stop() }
        let p = await proposals(server.endpoint, route: ScriptedRoute(text: proposalDraft), settle: .milliseconds(250)) {
            $0.label = "Search mail"
            $0.focusedElement = 9
            $0.text = ""
        }
        var searched: String?
        var ended: ContinuousClock.Instant?
        // The words go into the search field; focus lands in the reply
        // while dictation is still finishing, before it turns idle.
        p.dictation.onOutcome = { result, _, _ in
            guard case .inserted? = result else { return }
            ended = .now
            searched = MockField.shared.text
            MockField.shared.focusedElement = 1
            MockField.shared.label = "Message Body"
            MockField.shared.text = "\n"
            MockField.shared.selection = FieldRange(location: 0, length: 0)
            #expect(p.dictation.phase != .idle)
            p.controller.observe(p.observation(focus: 2))
        }
        p.dictation.toggle()
        try? await Task.sleep(for: .milliseconds(150))
        p.dictation.toggle()
        await until({ p.dictation.phase == .idle }, within: .seconds(10))
        #expect(searched?.contains("which venue") == true)
        await until { !p.route.created.isEmpty }
        #expect(ContinuousClock.now - (try #require(ended)) >= .milliseconds(250))
        #expect(p.route.created.count == 1)
        await until { p.card.isShown }
    }

    @Test func aReplyFirstFoundAbsentAndThenReadableUnderTheSameFocusIsProposedInto() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let p = await proposals(nil, route: route)
        // Focus lands in the reply before the browser has built its
        // accessibility tree: the tracker counts the new focus and finds
        // no field yet.
        p.controller.observe(p.observation(focus: 2, placed: false))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(p.reader.candidateReads == 0)
        // Its next read finds the body, under the same focus.
        p.controller.observe(p.observation(focus: 2))
        await until { p.card.isShown }
        #expect(p.reader.candidateReads == 1)
        #expect(route.created.count == 1)
        #expect(route.created.first?.compose.proposal == true)
        // Later observations of the same focus scan nothing more; what
        // they read is bound to the body, as a shown card's rereads are.
        p.controller.observe(p.observation(focus: 2, placed: false))
        p.controller.observe(p.observation(focus: 2))
        try? await Task.sleep(for: .milliseconds(100))
        let expectations = p.reader.candidateExpectations
        #expect(expectations.count - expectations.compactMap { $0 }.count == 1)
    }

    @Test func aFieldFoundAbsentAndThenReadableIsReadOnceUnderItsFocus() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let p = await proposals(nil, route: route) { $0.label = "Search mail" }
        p.controller.observe(p.observation(focus: 2, placed: false))
        p.controller.observe(p.observation(focus: 2))
        p.controller.observe(p.observation(focus: 2, placed: false))
        p.controller.observe(p.observation(focus: 2))
        try? await Task.sleep(for: .milliseconds(150))
        #expect(p.reader.candidateReads == 1)
        #expect(p.reader.bodyReads == 0)
        #expect(route.created.isEmpty)
    }

    /// A press while an accept is on its way records at once, as one made
    /// while a dictation's text is on its way does, so nothing the person
    /// says is refused. Its words wait for the proposal's text: the body is
    /// read and an email asked for only once the proposal is in, and the
    /// email goes in after it.
    @Test func aPressWhileAnAcceptIsOnItsWayRecordsAtOnceAndItsTextGoesInAfterTheProposal() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "and thank them", text: "And thank them.")])
        defer { server.stop() }
        let (p, outcomes) = await shownProposal(server.endpoint)
        let proposalID = try #require(p.route.created.first?.requestID)
        p.route.hold(.accept)
        p.controller.tabTaken(generation: try #require(p.tab))
        await p.route.whileHeld {
            #expect(p.controller.isAccepting)
            p.dictation.toggle()
            #expect(p.dictation.phase == .recording)
            #expect(p.source.running)
            try? await Task.sleep(for: .milliseconds(150))
            p.dictation.toggle()
            // Insertion can finish while the acceptance response still waits.
            // The spoken reply follows that local insertion.
            await until { server.connections.first?.answered == true }
            try? await Task.sleep(for: .milliseconds(150))
            await until { outcomes.list == [.inserted] }
            #expect(MockField.shared.text.hasPrefix(proposalDraft))
        }
        await until({ p.dictation.phase == .idle }, within: .seconds(10))
        #expect(outcomes.list == [.inserted])
        #expect(p.route.accepted.first == proposalID)
        // The words were the cue for an email written from the body with
        // the proposal in it, which went in after the proposal.
        #expect(p.route.created.count == 2)
        #expect(p.route.created.last?.compose.observedThread.contains(proposalDraft) == true)
        #expect(MockField.shared.text.hasPrefix(proposalDraft))
        #expect(MockField.shared.text.components(separatedBy: proposalDraft).count == 3)
        #expect(p.history.entries.map(\.proposal) == [nil, .accepted])
        #expect(p.history.entries.first?.spoken == "And thank them.")
        #expect(p.history.entries.allSatisfy { $0.outcome == .inserted })
    }

    /// A refused accept shows its popup while a later dictation records.
    @Test func aRefusedAcceptShowsWhileARecordingIsStillRunning() async throws {
        let server = try await ScriptedEndpoint([.silent])
        defer { server.stop() }
        let route = ScriptedRoute(text: proposalDraft)
        route.onAccept = .takeBack
        let (p, outcomes) = await shownProposal(server.endpoint, route: route)
        // Connected as the app connects them.
        let dictation = p.dictation
        p.controller.notInserted = { dictation.proposalNotInserted($0, $1) }
        p.dictation.notInserted = { outcomes.refused.append(($0, $1)) }
        p.route.hold(.accept)
        p.controller.tabTaken(generation: try #require(p.tab))
        await p.route.whileHeld {
            p.dictation.toggle()
            #expect(p.dictation.phase == .recording)
        }
        await until { outcomes.list == [.insertRefused] }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(p.dictation.phase == .recording)
        #expect(outcomes.refused.count == 1)
        p.dictation.cancel()
        #expect(outcomes.refused.count == 1)
        #expect(outcomes.refused.first?.1 == proposalDraft)
        #expect(MockField.shared.text == "\n")
    }

    /// A refused accept shows immediately while a silence notice is present.
    @Test func aRefusedAcceptShowsImmediatelyDuringAnEarlierNotice() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "", text: "")])
        defer { server.stop() }
        let route = ScriptedRoute(text: proposalDraft)
        route.onAccept = .takeBack
        let (p, outcomes) = await shownProposal(server.endpoint, route: route)
        let dictation = p.dictation
        let timer = NoticeTimer()
        dictation.noticePause = { try? await timer.wait(DictationController.noticeDuration) }
        // Connected as the app connects them.
        p.controller.notInserted = { dictation.proposalNotInserted($0, $1) }
        dictation.notInserted = { outcomes.refused.append(($0, $1)) }
        var silences = 0
        dictation.silent = { _ in silences += 1 }
        dictation.toggle()
        try? await Task.sleep(for: .milliseconds(150))
        dictation.toggle()
        await until({ dictation.phase == .idle }, within: .seconds(10))
        #expect(silences == 1)
        #expect(p.card.isShown)
        #expect(p.card.acceptsInput)
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { outcomes.list == [.insertRefused] }
        #expect(outcomes.refused.count == 1)
        #expect(dictation.hasMoreToSay)
        await until { timer.asked.count == 1 }
        timer.end()
        await until { outcomes.refused.count == 1 }
        #expect(outcomes.refused.first?.1 == proposalDraft)
        #expect(MockField.shared.text == "\n")
        await until { !dictation.hasMoreToSay }
    }

    /// The proposals hear that dictation ended only once no dictation is
    /// open: a recording over the card dropped while an earlier one's
    /// words are still on their way leaves the card taking no accept, and
    /// it takes them again once those words have come.
    @Test func theCardTakesAcceptsAgainOnlyOnceNoDictationIsOpen() async throws {
        let server = try await ScriptedEndpoint([.answerLate(after: 1, transcript: "", text: ""), .silent])
        defer { server.stop() }
        let (p, outcomes) = await shownProposal(server.endpoint)
        // A recording over the card, stopped: its words are on their way.
        p.dictation.toggle()
        try? await Task.sleep(for: .milliseconds(150))
        p.dictation.toggle()
        #expect(p.dictation.phase == .processing)
        // A second one over the card, dropped with the pill's cancel.
        p.dictation.toggle()
        #expect(p.dictation.phase == .recording)
        p.dictation.cancel()
        #expect(p.dictation.phase == .processing)
        #expect(p.controller.recordingIntention != nil)
        #expect(p.card.isShown)
        #expect(!p.card.acceptsInput)
        p.controller.tabTaken(generation: try #require(p.tab))
        try? await Task.sleep(for: .milliseconds(150))
        #expect(p.route.accepted.isEmpty)
        // The first heard no words: dictation is idle, and the card takes
        // accepts again.
        await until({ p.dictation.phase == .idle }, within: .seconds(10))
        #expect(p.controller.recordingIntention == nil)
        #expect(p.card.isShown)
        #expect(p.card.acceptsInput)
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { outcomes.list == [.inserted] }
        #expect(MockField.shared.text.hasPrefix(proposalDraft))
    }

    @Test func aSpokenChangeRegeneratesFromTheShownProposalAndGoesIn() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "make it shorter", text: "Make it shorter.")])
        defer { server.stop() }
        let (p, outcomes) = await shownProposal(server.endpoint)
        let parentID = try #require(p.route.created.first?.requestID)
        // Recording starts: the card stays, takes no accept, and Tab does nothing.
        p.dictation.toggle()
        #expect(p.card.isShown)
        #expect(!p.card.acceptsInput)
        p.controller.tabTaken(generation: try #require(p.tab))
        #expect(p.route.accepted.isEmpty)
        try? await Task.sleep(for: .milliseconds(150))
        p.dictation.toggle()
        await until({ p.dictation.phase == .idle }, within: .seconds(10))
        // The words came back for the body the proposal was made for: a
        // regeneration from it, with the words as the instruction and the
        // cue, accepted and put in.
        #expect(p.route.created.count == 2)
        let change = try #require(p.route.created.last)
        #expect(change.regeneration?.parentRequestID == parentID)
        #expect(change.regeneration?.parentRevision == 1)
        #expect(change.regeneration?.editedDraft == proposalDraft)
        #expect(change.regeneration?.instruction == "Make it shorter.")
        #expect(change.cue == "Make it shorter.")
        #expect(change.revision == 2)
        #expect(!change.compose.proposal)
        #expect(p.route.accepted == [change.requestID])
        #expect(MockField.shared.text.hasPrefix(proposalDraft))
        #expect(!p.card.isShown)
        #expect(outcomes.list == [.changeInserted])
        let entry = try #require(p.history.entries.first)
        #expect(entry.text == proposalDraft)
        #expect(entry.spoken == "Make it shorter.")
        #expect(entry.proposal == .changed)
    }

    @Test(arguments: [false, true])
    func typingThenASpokenChangeUsesTheRecordingSnapshot(bodyChangesDuringRecording: Bool) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "make it shorter", text: "Make it shorter.")])
        defer { server.stop() }
        let (p, outcomes) = await shownProposal(server.endpoint)
        let parentID = try #require(p.route.created.first?.requestID)
        await p.pressKey()
        MockField.shared.text = "My reply\n"
        MockField.shared.selection = FieldRange(location: 8, length: 0)
        p.controller.observe(p.observation(edit: 1))
        #expect(p.card.isShown)
        let snapshots = p.reader.snapshotsCompleted
        p.dictation.toggle()
        await until { p.reader.snapshotsCompleted > snapshots }
        if bodyChangesDuringRecording {
            // Change the body away from the caret without a tracker notice.
            MockField.shared.text = "No reply\n"
        }
        try? await Task.sleep(for: .milliseconds(150))
        p.dictation.toggle()
        await until({ p.dictation.phase == .idle }, within: .seconds(10))
        if bodyChangesDuringRecording {
            #expect(p.route.created.count == 1)
            #expect(p.route.accepted.isEmpty)
            #expect(outcomes.list == [.changed])
            #expect(!MockField.shared.text.contains(proposalDraft))
        } else {
            let change = try #require(p.route.created.last)
            #expect(p.route.created.count == 2)
            #expect(change.regeneration?.parentRequestID == parentID)
            #expect(change.regeneration?.instruction == "Make it shorter.")
            #expect(change.compose.observedThread.contains("My reply"))
            #expect(p.route.accepted == [change.requestID])
            #expect(outcomes.list == [.changeInserted])
            #expect(MockField.shared.text.contains(proposalDraft))
            #expect(!MockField.shared.text.contains("Make it shorter."))
        }
    }

    @Test func theRecordingSnapshotStartsBeforeMicrophoneStartup() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "make it shorter", text: "Make it shorter.")])
        defer { server.stop() }
        let (p, outcomes) = await shownProposal(server.endpoint)
        let original = String(repeating: "Original reply. ", count: 8) + "\n"
        let changed = "Changed!" + String(original.dropFirst(8))
        MockField.shared.text = original
        MockField.shared.selection = FieldRange(location: original.utf16.count - 1, length: 0)
        p.controller.observe(p.observation(edit: 1))
        var boundAtStartup = false
        p.source.whileStarting = {
            boundAtStartup = p.controller.recordingIntention != nil
            // Gmail changes text outside the field read's 64-unit caret context
            // while opening audio blocks the main actor.
            MockField.shared.text = changed
            p.controller.observe(p.observation(edit: 2))
        }
        p.dictation.toggle()
        #expect(boundAtStartup)
        try? await Task.sleep(for: .milliseconds(150))
        p.dictation.toggle()
        await until({ p.dictation.phase == .idle }, within: .seconds(10))
        #expect(p.route.created.count == 1)
        #expect(p.route.accepted.isEmpty)
        #expect(outcomes.list == [.changed])
        #expect(MockField.shared.text.hasPrefix("Changed!"))
    }

    @Test func anEditWhileTheRecordingSnapshotIsPendingRefusesRegeneration() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "make it shorter", text: "Make it shorter.")])
        defer { server.stop() }
        let (p, outcomes) = await shownProposal(server.endpoint)
        let reads = p.reader.bodyReads
        var release: CheckedContinuation<Void, Never>?
        p.reader.beforeAnswer = { number in
            if number == reads + 1 { await withCheckedContinuation { release = $0 } }
        }
        p.dictation.toggle()
        await until { release != nil }
        // The body returns to its old value while the snapshot is in flight.
        // Its edit notices still make the snapshot unsuitable for a rewrite.
        p.controller.observe(p.observation(edit: 1))
        p.controller.observe(p.observation(edit: 2))
        release?.resume()
        try? await Task.sleep(for: .milliseconds(150))
        p.dictation.toggle()
        await until({ p.dictation.phase == .idle }, within: .seconds(10))
        #expect(p.route.created.count == 1)
        #expect(p.route.accepted.isEmpty)
        #expect(outcomes.list == [.changed])
    }

    @Test func cancellingWhileTheRecordingSnapshotReturnsKeepsTheProposal() async throws {
        let server = try await ScriptedEndpoint([.silent])
        defer { server.stop() }
        let (p, outcomes) = await shownProposal(server.endpoint)
        let reads = p.reader.bodyReads
        var release: CheckedContinuation<Void, Never>?
        p.reader.beforeAnswer = { number in
            if number == reads + 1 {
                await withCheckedContinuation { release = $0 }
            }
        }
        p.dictation.toggle()
        await until { release != nil }
        let intention = try #require(p.controller.recordingIntention)
        let read = await p.reader.readFocusedEmailDraft(text: true, expecting: nil, visibility: false).value
        guard case let .success(.emailBody(capture)) = read else {
            Issue.record("Expected the same reply body")
            release?.resume()
            return
        }
        let answer = Task {
            await p.controller.parentForWords(capture, intention: intention, isCurrent: { p.dictation.phase != .idle })
        }
        p.dictation.cancel()
        release?.resume()
        #expect(await answer.value == .lost)
        #expect(p.card.isShown)
        #expect(p.card.acceptsInput)
        #expect(outcomes.list.isEmpty)
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { outcomes.list == [.inserted] }
    }

    @Test func aRefusedChangeEndsAsChangedAndHistoryMarksIt() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "make it shorter", text: "Make it shorter.")])
        defer { server.stop() }
        let (p, outcomes) = await shownProposal(server.endpoint)
        // Focus goes to another app while the change is written.
        p.route.beforeRead = { MockField.shared.focusedElsewhere = true }
        p.dictation.toggle()
        try? await Task.sleep(for: .milliseconds(150))
        p.dictation.toggle()
        await until({ p.dictation.phase == .idle }, within: .seconds(10))
        #expect(outcomes.list == [.changed])
        #expect(MockField.shared.text == "\n")
        let entry = try #require(p.history.entries.first)
        #expect(entry.outcome == .notInserted)
        #expect(entry.proposal == .changed)
    }

    @Test func wordsForAReplyWhoseThreadChangedAreTypedWithTheNotice() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "make it shorter", text: "Make it shorter.")])
        defer { server.stop() }
        let (p, outcomes) = await shownProposal(server.endpoint)
        p.dictation.toggle()
        // A message arrives in the thread while the person speaks.
        p.reader.thread = "Sam Lee\nActually, let's do Thursday."
        try? await Task.sleep(for: .milliseconds(150))
        p.dictation.toggle()
        await until({ p.dictation.phase == .idle }, within: .seconds(10))
        // No email was asked for; the words went in with the notice.
        #expect(p.route.created.count == 1)
        #expect(MockField.shared.text.hasPrefix("Make it shorter."))
        #expect(p.dictation.notice == .typedTranscript(nil))
        #expect(outcomes.list == [.changed])
        let entry = try #require(p.history.entries.first)
        #expect(entry.text == "Make it shorter.")
        #expect(entry.proposal == .changed)
    }

    @Test func wordsAfterTheCardEndedDuringTheRecordingAreTypedWithTheNotice() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "make it shorter", text: "Make it shorter.")])
        defer { server.stop() }
        let (p, outcomes) = await shownProposal(server.endpoint)
        p.dictation.toggle()
        // "Draft replies for me" went off while they spoke.
        p.enabled.value = false
        p.controller.observe(p.observation())
        #expect(outcomes.list == [.left])
        try? await Task.sleep(for: .milliseconds(150))
        p.dictation.toggle()
        await until({ p.dictation.phase == .idle }, within: .seconds(10))
        #expect(p.route.created.count == 1)
        #expect(MockField.shared.text.hasPrefix("Make it shorter."))
        #expect(p.dictation.notice == .typedTranscript(nil))
        #expect(p.history.entries.first?.proposal == .changed)
    }

    enum Mutation: CaseIterable, Sendable {
        case unchanged, process, launch, element, selection, account, threadID, recipients, subject, thread, body
    }

    /// The parent is the shown proposal only while every binding reads as
    /// it was made; any one of them changed loses it.
    @Test(arguments: Mutation.allCases)
    func aSpokenChangesParentNeedsEveryBinding(_ mutation: Mutation) async throws {
        let server = try await ScriptedEndpoint([.silent])
        defer { server.stop() }
        let (p, outcomes) = await shownProposal(server.endpoint)
        let parentID = try #require(p.route.created.first?.requestID)
        p.dictation.toggle()
        #expect(!p.card.acceptsInput)
        let read = await p.reader.readFocusedEmailDraft(text: true, expecting: nil, visibility: false).value
        guard case var .success(.emailBody(capture)) = read else {
            Issue.record("the reply was not read")
            return
        }
        let field = capture.field
        func moved(pid: pid_t? = nil, started: UInt64?? = nil, element: AXElement? = nil) -> FocusedField {
            FocusedField(pid: pid ?? field.pid, started: started ?? field.started, element: element ?? field.element, window: field.window,
                         frame: field.frame, before: field.before, bundleIdentifier: field.bundleIdentifier, labels: field.labels)
        }
        switch mutation {
        case .unchanged: break
        case .process: capture.field = moved(pid: field.pid + 1)
        case .launch: capture.field = moved(started: .some((field.started ?? 0) + 1))
        case .element: capture.field = moved(element: AXElement(ref: field.element.ref, id: 2))
        case .selection: capture.selection = FieldRange(location: 1, length: 0)
        case .account: p.accountShift.value = 1
        case .threadID: capture.observation.threadID = "18c2f4a9d0e1b3a3"
        case .recipients: capture.observation.recipients = [WritingRecipient(address: "someone.else@example.com", role: .to)]
        case .subject: capture.observation.subject = "Re: Another venue"
        case .thread: capture.observation.thread = "Sam Lee\nActually, let's do Thursday."
        case .body: capture.observation.body = "\n\n"
        }
        let answer = await p.controller.parentForWords(capture, intention: p.controller.recordingIntention)
        if mutation == .unchanged {
            #expect(answer == .parent(ProposalParent(requestID: parentID, revision: 1, text: proposalDraft)))
            #expect(!p.card.isShown)
        } else {
            #expect(answer == .lost)
            #expect(outcomes.list == [.changed])
            #expect(!p.card.isShown)
        }
        p.dictation.cancel()
    }

    @Test func aDictationThatHearsNothingLeavesTheCardAsItWas() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "", text: "")])
        defer { server.stop() }
        let (p, _) = await shownProposal(server.endpoint)
        p.dictation.toggle()
        #expect(!p.card.acceptsInput)
        try? await Task.sleep(for: .milliseconds(150))
        p.dictation.toggle()
        await until({ p.dictation.phase == .idle }, within: .seconds(10))
        #expect(p.card.isShown)
        #expect(p.card.acceptsInput)
        #expect(p.route.created.count == 1)
    }

    @Test func aSpeechFailureOverAShownCardLetsItBeAcceptedAgain() async throws {
        let server = try await ScriptedEndpoint([.refuse("language_unsupported")])
        defer { server.stop() }
        let (p, outcomes) = await shownProposal(server.endpoint)
        p.dictation.toggle()
        #expect(!p.card.acceptsInput)
        try? await Task.sleep(for: .milliseconds(150))
        p.dictation.toggle()
        await until({ p.dictation.phase == .idle }, within: .seconds(10))
        #expect(p.history.entries.first?.outcome == .failed)
        #expect(p.card.isShown)
        #expect(p.card.acceptsInput)
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { outcomes.list == [.inserted] }
        #expect(MockField.shared.text.hasPrefix(proposalDraft))
    }

    @Test func theKeepTimeWaitsForARecordingOverTheCard() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "", text: "")])
        defer { server.stop() }
        let (p, outcomes) = await shownProposal(server.endpoint, keep: .milliseconds(200))
        p.dictation.toggle()
        try? await Task.sleep(for: .milliseconds(400))
        // Its five minutes, here 200 ms, passed while the person spoke.
        #expect(p.card.isShown)
        #expect(outcomes.list.isEmpty)
        p.dictation.toggle()
        await until({ p.dictation.phase == .idle }, within: .seconds(10))
        // The dictation ended without words for it: now it expires.
        await until { outcomes.list == [.expired] }
        #expect(!p.card.isShown)
    }

    @Test func aTapOfTheDictationKeyLeavesTheCardAndBodyAlone() async throws {
        let server = try await ScriptedEndpoint([.silent])
        defer { server.stop() }
        let (p, outcomes) = await shownProposal(server.endpoint)
        // Pressed and let go well within the shortest hold.
        p.dictation.holdBegan()
        #expect(p.dictation.phase == .recording)
        p.dictation.holdEnded()
        #expect(p.route.accepted.isEmpty)
        #expect(outcomes.list.isEmpty)
        #expect(MockField.shared.text == "\n")
        #expect(p.card.isShown)
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { outcomes.list == [.inserted] }
        #expect(p.dictation.phase == .idle)
        #expect(p.route.accepted == [p.route.created.first?.requestID].compactMap { $0 })
        #expect(p.route.created.count == 1)
        #expect(MockField.shared.text.hasPrefix(proposalDraft))
        #expect(p.history.entries.first?.proposal == .accepted)
    }

    /// A tap of the dictation key over the card while an earlier
    /// dictation's words are on their way: the recording it began is
    /// dropped, as every tap's is, and it puts nothing in, since the
    /// proposal's text could go in ahead of the earlier words or be refused
    /// by them. Once no dictation is open, Tab accepts the card.
    @Test func aTapOverTheCardWhileAnEarlierDictationsWordsAreOnTheirWayPutsNothingIn() async throws {
        let server = try await ScriptedEndpoint([.answerLate(after: 1, transcript: "", text: ""), .silent, .silent])
        defer { server.stop() }
        let (p, outcomes) = await shownProposal(server.endpoint)
        p.dictation.toggle()
        try? await Task.sleep(for: .milliseconds(150))
        p.dictation.toggle()
        #expect(p.dictation.phase == .processing)
        // Pressed and let go well within the shortest hold.
        p.dictation.holdBegan()
        #expect(p.dictation.phase == .recording)
        p.dictation.holdEnded()
        #expect(p.dictation.phase == .processing)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(p.route.accepted.isEmpty)
        #expect(outcomes.list.isEmpty)
        #expect(MockField.shared.text == "\n")
        #expect(p.card.isShown)
        #expect(!p.card.acceptsInput)
        // The tap's recording was dropped, never sent to finish: only the
        // first dictation's connection was.
        #expect(server.connections.filter { $0.stopFrames != nil }.count == 1)
        await until({ p.dictation.phase == .idle }, within: .seconds(10))
        #expect(p.card.acceptsInput)
        p.dictation.holdBegan()
        p.dictation.holdEnded()
        #expect(p.route.accepted.isEmpty)
        #expect(outcomes.list.isEmpty)
        #expect(MockField.shared.text == "\n")
        #expect(p.card.isShown)
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { outcomes.list == [.inserted] }
        #expect(p.route.accepted == [p.route.created.first?.requestID].compactMap { $0 })
        #expect(MockField.shared.text.hasPrefix(proposalDraft))
        #expect(p.history.entries.first?.proposal == .accepted)
    }

    @Test func aShortPressAndReleaseAfterTheRecordingRanAcceptsNothing() async throws {
        let server = try await ScriptedEndpoint([.silent])
        defer { server.stop() }
        let (p, outcomes) = await shownProposal(server.endpoint)
        p.dictation.holdBegan()
        try? await Task.sleep(for: .milliseconds(120))
        #expect(p.dictation.phase == .recording)
        p.dictation.holdEnded()
        #expect(p.route.accepted.isEmpty)
        #expect(outcomes.list.isEmpty)
        #expect(MockField.shared.text == "\n")
        #expect(p.card.isShown)
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { outcomes.list == [.inserted] }
        #expect(p.route.accepted.count == 1)
        #expect(MockField.shared.text.hasPrefix(proposalDraft))
        // The recording the press began was dropped, never sent to finish.
        #expect(server.connections.allSatisfy { $0.stopFrames == nil })
    }

    @Test func aMicrophoneThatGivesOutWhileTheKeyIsHeldOverTheCardAcceptsNothing() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "", text: "")])
        defer { server.stop() }
        let (p, outcomes) = await shownProposal(server.endpoint)
        // The person holds the key to change the draft, and the microphone
        // gives out well within the shortest hold.
        p.dictation.holdBegan(confirmed: true)
        #expect(p.dictation.phase == .recording)
        p.source.interrupt()
        #expect(p.dictation.phase == .recording)
        // The key comes up, still within the shortest hold: the recording
        // is no longer the key's, so this is no tap.
        p.dictation.holdEnded()
        await until({ p.dictation.phase == .idle }, within: .seconds(10))
        try? await Task.sleep(for: .milliseconds(150))
        #expect(p.route.accepted.isEmpty)
        #expect(outcomes.list.isEmpty)
        #expect(MockField.shared.text == "\n")
        // The card stays and takes accepts again.
        #expect(p.card.isShown)
        #expect(p.card.acceptsInput)
        #expect(p.history.entries.allSatisfy { $0.proposal != .accepted })
        // The recording was finished as any stopped one is, not dropped.
        #expect(server.connections.contains { $0.stopFrames != nil })
    }

    // MARK: The last moment before the write

    /// What happens inside the paste, at the inserter's last read of the
    /// field before the paste key: once the clipboard holds the draft, the
    /// check that the field is not secure that follows the read of its
    /// labels. Every check of the field and the accept's guard have passed
    /// by then, and the field answers unchanged.
    enum AtTheLastRead: CaseIterable, Sendable {
        case escape, settingOff, deadline
    }

    @Test(arguments: AtTheLastRead.allCases)
    func somethingAtTheLastReadBeforeThePasteKeyStopsIt(_ event: AtTheLastRead) async throws {
        let (p, outcomes) = await shownProposal(acceptLimit: event == .deadline ? .seconds(1) : ReplyProposalController.acceptLimit)
        let pasteboard = try #require(MockField.shared.pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("the person's clipboard", forType: .string)
        let controller = p.controller, hold = p.hold, enabled = p.enabled, draft = proposalDraft
        struct Stage {
            var labelsRead = false
            var acted = false
            var readsAfter = 0
        }
        let stage = OSAllocatedUnfairLock(initialState: Stage())
        let readAfter: @Sendable () -> Void = { stage.withLock { if $0.acted { $0.readsAfter += 1 } } }
        // Read on the executor, as the inserter's own scenarios read it.
        nonisolated(unsafe) let clipboard = pasteboard
        MockField.shared.onPlaceholderRead = {
            guard clipboard.string(forType: .string) == draft else { return }
            stage.withLock { $0.labelsRead = true }
        }
        MockField.shared.onOtherRead = readAfter
        MockField.shared.onTextRead = readAfter
        MockField.shared.onFocusRead = readAfter
        MockField.shared.onSecureCheck = {
            let act = stage.withLock { stage -> Bool in
                if stage.acted {
                    stage.readsAfter += 1
                    return false
                }
                guard stage.labelsRead else { return false }
                stage.acted = true
                return true
            }
            guard act else { return }
            switch event {
            case .escape:
                // Escape as the dictation key's monitors hand it over, on the
                // main thread, where it acts at once.
                DispatchQueue.main.sync { hold.received(HoldKey.Monitored(kind: .keyDown, keyCode: 53)) }
            case .settingOff:
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        enabled.value = false
                        controller.reset()
                    }
                }
            case .deadline:
                Thread.sleep(forTimeInterval: 1.1)
            }
        }
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { !outcomes.list.isEmpty }
        MockField.shared.onSecureCheck = nil
        // It was the last read: nothing of the field was read after it.
        #expect(stage.withLock { $0.acted })
        #expect(stage.withLock { $0.readsAfter } == 0)
        #expect(MockField.shared.keys.isEmpty)
        #expect(MockField.shared.text == "\n")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
        switch event {
        case .escape:
            #expect(outcomes.list == [.dismissed])
            #expect(outcomes.refused.first?.0 == .composeChanged)
        case .settingOff:
            #expect(outcomes.list == [.left])
            #expect(outcomes.refused.first?.0 == .focusChanged)
        case .deadline:
            #expect(outcomes.list == [.insertRefused])
            #expect(outcomes.refused.first?.0 == .busy)
        }
        #expect(outcomes.refused.count == 1)
        #expect(outcomes.refused.first?.1 == proposalDraft)
    }

    /// The real card, its lock and sleep notifications posted from a
    /// background queue as macOS posts them, while the server holds the
    /// accept: the card, held for the insertion, goes, and the accept
    /// still stops.
    @Test(arguments: [false, true])
    func aScreenLockOrDisplaySleepDuringAnAcceptStopsIt(sleep: Bool) async throws {
        let screen = NotificationCenter(), workspace = NotificationCenter()
        let card = ProposalCard(screenEvents: screen, workspaceEvents: workspace)
        card.showsWindow = false
        card.reduceMotion = { true }
        let p = await proposals(nil, route: ScriptedRoute(text: proposalDraft), presenter: card)
        let outcomes = Outcomes()
        p.controller.ended = { outcome, _ in outcomes.list.append(outcome) }
        p.controller.notInserted = { outcomes.refused.append(($0, $1)) }
        p.controller.observe(p.observation())
        await until { card.isShown }
        p.route.hold(.accept)
        // The card's own button.
        #expect(card.press())
        await until { p.controller.isAccepting }
        #expect(card.isShown)
        #expect(!card.acceptsInput)
        await p.route.whileHeld {
            await Self.offMain {
                if sleep {
                    workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
                } else {
                    screen.post(name: .init("com.apple.screenIsLocked"), object: nil)
                }
            }
            #expect(!card.isShown)
        }
        await until { !outcomes.list.isEmpty }
        #expect(outcomes.list == [.left])
        #expect(outcomes.refused.first?.0 == .focusChanged)
        #expect(outcomes.refused.first?.1 == proposalDraft)
        #expect(MockField.shared.text == "\n")
        #expect(p.route.accepted.count == 1)
        #expect(p.history.entries.first?.proposal == .unused)
    }

    // MARK: The selection

    @Test func aSelectionMovedBeforeTheCardShowsAgainKeepsTheProposal() async throws {
        let (p, outcomes) = await shownProposal()
        p.focusSearch(focus: 2)
        MockField.shared.selection = FieldRange(location: 1, length: 0)
        p.focusReply(focus: 3)
        await until { p.card.isShown }
        #expect(outcomes.list.isEmpty)
        #expect(p.card.shown.count == 2)
    }

    @Test func aSelectionMadeAfterTabRefusesTheAccept() async throws {
        let (p, outcomes) = await shownProposal()
        p.route.hold(.accept)
        p.controller.tabTaken(generation: try #require(p.tab))
        // The line break selected, and the tracker has not said so.
        await p.route.whileHeld { MockField.shared.selection = FieldRange(location: 0, length: 1) }
        await until { !outcomes.list.isEmpty }
        #expect(outcomes.list == [.insertRefused])
        #expect(outcomes.refused.first?.0 == .composeChanged)
        #expect(outcomes.refused.first?.1 == proposalDraft)
        #expect(MockField.shared.text == "\n")
        #expect(MockField.shared.keys.isEmpty)
    }

    @Test func wordsForAReplyWhoseSelectionChangedAreTypedWithTheNotice() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "make it shorter", text: "Make it shorter.")])
        defer { server.stop() }
        let (p, outcomes) = await shownProposal(server.endpoint)
        p.dictation.toggle()
        // The line break is selected while the person speaks, unreported;
        // the text before the caret stays empty, so the words can still go
        // where the person is.
        MockField.shared.selection = FieldRange(location: 0, length: 1)
        try? await Task.sleep(for: .milliseconds(150))
        p.dictation.toggle()
        await until({ p.dictation.phase == .idle }, within: .seconds(10))
        // No regeneration from a parent whose reply no longer reads as bound.
        #expect(p.route.created.count == 1)
        #expect(MockField.shared.text.hasPrefix("Make it shorter."))
        #expect(p.dictation.notice == .typedTranscript(nil))
        #expect(outcomes.list == [.changed])
        #expect(p.history.entries.first?.proposal == .changed)
    }

    // MARK: The parent's five minutes

    @Test func wordsThatComeBackAfterTheFiveMinutesAreTypedWithTheNotice() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "make it shorter", text: "Make it shorter.")])
        defer { server.stop() }
        let (p, outcomes) = await shownProposal(server.endpoint, keep: .milliseconds(300))
        p.dictation.toggle()
        try? await Task.sleep(for: .milliseconds(450))
        // Its five minutes, here 300 ms, passed while the person spoke; the
        // card stays so they see what they are changing.
        #expect(p.card.isShown)
        #expect(outcomes.list.isEmpty)
        p.dictation.toggle()
        await until({ p.dictation.phase == .idle }, within: .seconds(10))
        // The parent is gone: no regeneration, the words typed with the notice.
        #expect(p.route.created.count == 1)
        #expect(MockField.shared.text.hasPrefix("Make it shorter."))
        #expect(p.dictation.notice == .typedTranscript(nil))
        #expect(outcomes.list == [.changed])
        let entry = try #require(p.history.entries.first)
        #expect(entry.text == "Make it shorter.")
        #expect(entry.proposal == .changed)
        #expect(!p.card.isShown)
    }

    // MARK: Words that cannot become a change

    enum ChangeFallback: CaseIterable, Sendable {
        /// "Write emails for me" goes off while the person speaks.
        case writingOff
        /// The body cannot be read when the words come back.
        case unreadableBody
        /// Focus is in another reply's body when the words come back.
        case anotherBody
    }

    @Test(arguments: ChangeFallback.allCases)
    func wordsOverACardThatCannotBecomeAChangeAreTypedAsOne(_ fallback: ChangeFallback) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "make it shorter", text: "Make it shorter.")])
        defer { server.stop() }
        let (p, outcomes) = await shownProposal(server.endpoint)
        p.dictation.toggle()
        switch fallback {
        case .writingOff:
            // As the app turns the setting off: the proposals, then dictation.
            p.enabled.value = false
            p.controller.reset()
            p.dictation.writesEmailsChanged(false)
        case .unreadableBody:
            MockField.shared.unreadable = true
        case .anotherBody:
            MockField.shared.focusedElement = 2
        }
        try? await Task.sleep(for: .milliseconds(150))
        p.dictation.toggle()
        await until({ p.dictation.phase == .idle }, within: .seconds(10))
        #expect(p.route.created.count == 1)
        #expect(p.dictation.notice == (fallback == .unreadableBody ? .insertionUncertain : .typedTranscript(nil)))
        let words = try #require(p.history.entries.first)
        #expect(words.text == "Make it shorter.")
        #expect(words.proposal == .changed)
        switch fallback {
        case .writingOff:
            // The setting ended the proposal; it went to history unused.
            #expect(outcomes.list == [.left])
            #expect(p.history.entries.last?.proposal == .unused)
            #expect(MockField.shared.text.hasPrefix("Make it shorter."))
        case .unreadableBody, .anotherBody:
            #expect(outcomes.list == [.changed])
        }
        #expect(!p.card.isShown)
    }

    enum DuringTheChange: CaseIterable, Sendable {
        case accountChanged, writingOff
    }

    @Test(arguments: DuringTheChange.allCases)
    func anAccountOrSettingChangeDuringARegenerationTypesTheWordsAsAChange(_ change: DuringTheChange) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "make it shorter", text: "Make it shorter.")])
        defer { server.stop() }
        let (p, outcomes) = await shownProposal(server.endpoint)
        p.route.hold(.create)
        p.dictation.toggle()
        try? await Task.sleep(for: .milliseconds(150))
        p.dictation.toggle()
        await p.route.whileHeld {
            #expect(p.dictation.phase == .writingEmail)
            switch change {
            case .accountChanged:
                p.dictation.accountChanged(signedIn: true)
            case .writingOff:
                p.enabled.value = false
                p.controller.reset()
                p.dictation.writesEmailsChanged(false)
            }
        }
        await until({ p.dictation.phase == .idle && !outcomes.list.isEmpty }, within: .seconds(10))
        #expect(MockField.shared.text.hasPrefix("Make it shorter."))
        #expect(p.dictation.notice == .typedTranscript(nil))
        #expect(outcomes.list == [.changed])
        let words = try #require(p.history.entries.first)
        #expect(words.text == "Make it shorter.")
        #expect(words.proposal == .changed)
    }

    enum RegenerationEnd: CaseIterable, Sendable {
        case failed, abstained
    }

    @Test(arguments: RegenerationEnd.allCases)
    func aRegenerationWithoutTextTypesTheWordsAsAChange(_ end: RegenerationEnd) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "make it shorter", text: "Make it shorter.")])
        defer { server.stop() }
        let (p, outcomes) = await shownProposal(server.endpoint)
        switch end {
        case .failed: p.route.onCreate = .fail(.excluded)
        case .abstained: p.route.onRead = .abstain(.parentUnavailable)
        }
        p.dictation.toggle()
        try? await Task.sleep(for: .milliseconds(150))
        p.dictation.toggle()
        await until({ p.dictation.phase == .idle }, within: .seconds(10))
        // The regeneration was asked for, and nothing came of it.
        #expect(p.route.created.count == 2)
        #expect(p.route.created.last?.regeneration?.instruction == "Make it shorter.")
        #expect(MockField.shared.text.hasPrefix("Make it shorter."))
        #expect(p.dictation.notice == .typedTranscript(end == .abstained ? .parentUnavailable : nil))
        #expect(outcomes.list == [.changed])
        let words = try #require(p.history.entries.first)
        #expect(words.text == "Make it shorter.")
        #expect(words.proposal == .changed)
    }

    // MARK: Pastes the field does not show

    @Test func anAcceptedProposalTheFieldDoesNotShowIsUnconfirmed() async throws {
        let (p, outcomes) = await shownProposal { $0.pastesLand = false }
        var uncertaintyNotices = 0
        p.controller.insertionUncertain = { uncertaintyNotices += 1 }
        p.controller.tabTaken(generation: try #require(p.tab))
        await until({ !outcomes.list.isEmpty }, within: .seconds(10))
        #expect(outcomes.list == [.unconfirmed])
        #expect(outcomes.timings.last?.insertionResult == .unknown(.writeUnconfirmed))
        #expect(outcomes.refused.isEmpty)
        #expect(MockField.shared.keys.count == 1)
        let entry = try #require(p.history.entries.first)
        #expect(entry.text == proposalDraft)
        #expect(entry.outcome == .uncertain)
        #expect(entry.proposal == .accepted)
        #expect(uncertaintyNotices == 1)
    }

    @Test func aChangeTheFieldDoesNotShowIsUnconfirmed() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "make it shorter", text: "Make it shorter.")])
        defer { server.stop() }
        let (p, outcomes) = await shownProposal(server.endpoint) { $0.pastesLand = false }
        p.dictation.toggle()
        try? await Task.sleep(for: .milliseconds(150))
        p.dictation.toggle()
        await until({ p.dictation.phase == .idle }, within: .seconds(10))
        #expect(p.route.created.count == 2)
        #expect(outcomes.list == [.unconfirmed])
        #expect(outcomes.timings.last?.insertionResult == .unknown(.writeUnconfirmed))
        let entry = try #require(p.history.entries.first)
        #expect(entry.text == proposalDraft)
        #expect(entry.spoken == "Make it shorter.")
        #expect(entry.outcome == .uncertain)
        #expect(entry.proposal == .changed)
    }

    // MARK: Abstentions by name

    @Test func theDailyProposalLimitShowsNothingAndSaysNothing() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        route.onRead = .abstain(try #require(DraftReason(rawValue: "proposal_limit")))
        let p = await proposals(nil, route: route)
        var outcomes: [ProposalOutcome] = []
        p.controller.ended = { outcome, _ in outcomes.append(outcome) }
        p.controller.observe(p.observation())
        await until { !outcomes.isEmpty }
        #expect(outcomes == [.abstained])
        #expect(p.card.shown.isEmpty)
        #expect(p.history.entries.isEmpty)
        #expect(p.dictation.notice == nil)
    }

    // MARK: The body's frame and what shows it

    @Test func aZeroHeightBodyInViewGetsItsCardAtItsTopLeft() async throws {
        let p = await proposals(nil, route: ScriptedRoute(text: proposalDraft)) { $0.frameHeight = 0 }
        p.controller.observe(p.unplaced())
        await until { p.card.isShown }
        let anchor = try #require(p.card.shown.first?.anchor)
        #expect(anchor.textOrigin == CGPoint(x: 100, y: 900 - 100))
        #expect(anchor.bodyWidth == 300)
    }

    /// The body's top-left, at (100, 100), outside the page's view or the
    /// window, as a reply scrolled up out of the thread.
    enum OutOfView: CaseIterable, Sendable {
        case scrollArea, window
    }

    @Test(arguments: OutOfView.allCases)
    func aBodyScrolledOutOfViewGetsNoCardUntilItIsBack(_ outside: OutOfView) async throws {
        let p = await proposals(nil, route: ScriptedRoute(text: proposalDraft)) {
            switch outside {
            case .scrollArea: $0.scrollArea = CGRect(x: 0, y: 150, width: 1440, height: 710)
            case .window: $0.windowFrame = CGRect(x: 0, y: 150, width: 1440, height: 750)
            }
        }
        p.controller.observe(p.unplaced())
        await until { p.controller.isHidden }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(p.card.shown.isEmpty)
        #expect(p.tab == nil)
        // Scrolled back: the next observation finds it in view.
        MockField.shared.scrollArea = CGRect(x: 0, y: 80, width: 1440, height: 780)
        MockField.shared.windowFrame = CGRect(x: 0, y: 25, width: 1440, height: 875)
        p.controller.observe(p.unplaced())
        await until { p.card.isShown }
        #expect(p.card.shown.first?.anchor.textOrigin == CGPoint(x: 100, y: 900 - 100))
    }

    @Test func aShownCardFromTheFrameHidesWhenTheBodyScrollsOutAndReturnsWithIt() async throws {
        let p = await proposals(nil, route: ScriptedRoute(text: proposalDraft))
        var outcomes: [ProposalOutcome] = []
        p.controller.ended = { outcome, _ in outcomes.append(outcome) }
        p.controller.observe(p.unplaced())
        await until { p.card.isShown }
        let first = try #require(p.tab)
        MockField.shared.scrollArea = CGRect(x: 0, y: 150, width: 1440, height: 710)
        p.controller.observe(p.unplaced())
        await until { !p.card.isShown }
        #expect(p.controller.isHidden)
        #expect(p.taken.value.last == .some(nil))
        p.controller.tabTaken(generation: first)
        #expect(p.route.accepted.isEmpty)
        MockField.shared.scrollArea = CGRect(x: 0, y: 80, width: 1440, height: 780)
        p.controller.observe(p.unplaced())
        await until { p.card.isShown }
        #expect(p.tab != first)
        #expect(outcomes.isEmpty)
    }

    @Test func aFrameFromAnEarlierReadDoesNotPlaceTheCard() async throws {
        let p = await proposals(nil, route: ScriptedRoute(text: proposalDraft))
        var outcomes: [ProposalOutcome] = []
        p.controller.ended = { outcome, _ in outcomes.append(outcome) }
        p.controller.observe(p.unplaced())
        await until { p.card.isShown }
        p.focusSearch(focus: 2)
        #expect(!p.card.isShown)
        // Back in the reply, and now no scroll area answers above it: the
        // frame the first reads gave is not used without evidence of its own.
        MockField.shared.scrollArea = nil
        MockField.shared.focusedElement = 1
        MockField.shared.label = "Message Body"
        p.controller.observe(p.unplaced(focus: 3))
        await until { p.reader.bodyReads == 3 }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(!p.card.isShown)
        #expect(p.card.shown.count == 1)
        #expect(p.controller.isHidden)
        #expect(outcomes.isEmpty)
    }

    // MARK: Fresh and bound geometry

    @Test func aBodyThatMovesDuringTheBodyReadIsJudgedWhereItEnds() async throws {
        let p = await proposals(nil, route: ScriptedRoute(text: proposalDraft))
        // Once the request's read has answered, the next text read, the
        // display check's, scrolls the body's top to 40, above the page's
        // view at 80, while the view and the window stay where they are.
        p.reader.beforeAnswer = { number in
            guard number == 1 else { return }
            MockField.shared.onTextRead = {
                MockField.shared.fieldTop = 40
                MockField.shared.onTextRead = nil
            }
        }
        p.controller.observe(p.unplaced())
        await until { p.reader.bodyReads == 2 }
        await until { p.controller.isHidden }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(p.card.shown.isEmpty)
        #expect(p.tab == nil)
        // Scrolled back: the next observation finds it in view.
        MockField.shared.fieldTop = 100
        p.controller.observe(p.unplaced())
        await until { p.card.isShown }
        #expect(p.card.shown.first?.anchor.textOrigin == CGPoint(x: 100, y: 900 - 100))
    }

    /// How the body moves while its view's and window's frames are read:
    /// once, to a place still in view, or on every sample.
    enum MovingSample: CaseIterable, Sendable {
        case once, always
    }

    @Test(arguments: MovingSample.allCases)
    func aBodyMovingWhileItsViewIsSampledIsSampledAgain(_ moving: MovingSample) async throws {
        let p = await proposals(nil, route: ScriptedRoute(text: proposalDraft))
        // Moves only during the display check's sample, after the request.
        p.reader.beforeAnswer = { number in
            guard number == 1 else { return }
            MockField.shared.onFrameRead = { id in
                guard id == AXElement.scrollAreaID else { return }
                switch moving {
                case .once:
                    MockField.shared.fieldTop = 120
                    MockField.shared.onFrameRead = nil
                case .always:
                    MockField.shared.fieldTop += 1
                }
            }
        }
        p.controller.observe(p.unplaced())
        await until { p.reader.bodyReads == 2 }
        switch moving {
        case .once:
            // The second sample held still, and the card is where it ended.
            await until { p.card.isShown }
            #expect(p.card.shown.first?.anchor.textOrigin == CGPoint(x: 100, y: 900 - 120))
        case .always:
            await until { p.controller.isHidden }
            try? await Task.sleep(for: .milliseconds(150))
            #expect(p.card.shown.isEmpty)
            #expect(p.tab == nil)
        }
    }

    @Test(arguments: [false, true])
    func tabBeforeTheGeometryRereadAnswersWaitsForIt(scrolledAway: Bool) async throws {
        let p = await proposals(nil, route: ScriptedRoute(text: proposalDraft))
        let outcomes = Outcomes()
        p.controller.ended = { outcome, _ in outcomes.list.append(outcome) }
        p.controller.notInserted = { outcomes.refused.append(($0, $1)) }
        p.controller.observe(p.unplaced())
        await until { p.card.isShown }
        let tab = try #require(p.tab)
        // The next observation's reread is held on the executor, and the
        // reply scrolls up out of the page's view meanwhile, or does not.
        p.reader.holdingCandidates = true
        if scrolledAway { MockField.shared.scrollArea = CGRect(x: 0, y: 150, width: 1440, height: 710) }
        p.controller.observe(p.unplaced())
        await until { p.reader.heldCandidateCount == 1 }
        // Tab, and the button, while the cached frame still says in view.
        p.controller.tabTaken(generation: tab)
        p.card.accepted()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(p.route.accepted.isEmpty)
        #expect(p.controller.isShown)
        #expect(MockField.shared.text == "\n")
        p.reader.releaseCandidates()
        if scrolledAway {
            // The reread found the first line out of view: the card hid and
            // the held accept went nowhere.
            await until { p.controller.isHidden }
            try? await Task.sleep(for: .milliseconds(150))
            #expect(p.route.accepted.isEmpty)
            #expect(MockField.shared.text == "\n")
            #expect(outcomes.list.isEmpty)
            #expect(outcomes.refused.isEmpty)
            #expect(p.taken.value.last == .some(nil))
        } else {
            // Still in view: the one held accept goes ahead.
            await until { !outcomes.list.isEmpty }
            #expect(outcomes.list == [.inserted])
            #expect(p.route.accepted.count == 1)
            #expect(MockField.shared.text.hasPrefix(proposalDraft))
        }
    }

    /// A card placed from the body's frame with the next observation's
    /// reread held on the executor, its outcomes collected.
    private func heldReread(_ endpoint: DictationEndpoint? = nil,
                            acceptLimit: Duration = ReplyProposalController.acceptLimit) async throws -> (Proposals, Outcomes, UInt64) {
        let p = await proposals(endpoint, route: ScriptedRoute(text: proposalDraft), acceptLimit: acceptLimit)
        let outcomes = Outcomes()
        p.controller.ended = { outcome, _ in outcomes.list.append(outcome) }
        p.controller.notInserted = { outcomes.refused.append(($0, $1)) }
        p.controller.observe(p.unplaced())
        await until { p.card.isShown }
        let tab = try #require(p.tab)
        p.reader.holdingCandidates = true
        p.controller.observe(p.unplaced())
        await until { p.reader.heldCandidateCount == 1 }
        return (p, outcomes, tab)
    }

    @Test func aKeyAfterTabWhileGeometryWaitsRefusesWithPopupAndHistory() async throws {
        let (p, outcomes, tab) = try await heldReread()
        p.controller.tabTaken(generation: tab)
        await p.pressKey()
        MockField.shared.text = "After Tab\n"
        MockField.shared.selection = FieldRange(location: 9, length: 0)
        p.reader.releaseCandidates()
        await until { !outcomes.list.isEmpty }
        #expect(outcomes.list == [.ignored])
        #expect(outcomes.refused.first?.0 == .fieldChanged)
        #expect(p.history.entries.first?.text == "Hey Priya, Harbor Hall fits what we need. Can you ask what they'd charge?")
        #expect(MockField.shared.text == "After Tab\n")
        #expect(p.route.accepted.isEmpty)
        #expect(!p.card.isShown)
    }

    @Test func aSecondConsumedTabKeepsAnAcceptWaitingForGeometry() async throws {
        let (p, outcomes, tab) = try await heldReread()
        p.hold.tapInput(.init(kind: .keyDown, keyCode: 48, proposalTab: true), tabTaken: tab)
        p.hold.tapInput(.init(kind: .keyDown, keyCode: 48, proposalTab: true), tabTaken: tab)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(outcomes.list.isEmpty)
        p.reader.releaseCandidates()
        await until { !outcomes.list.isEmpty }
        #expect(outcomes.list == [.inserted])
        #expect(p.route.accepted.count == 1)
    }

    @Test func anAcceptHeldForTheRereadPastItsLimitIsRefused() async throws {
        let (p, outcomes, tab) = try await heldReread(acceptLimit: .milliseconds(300))
        p.controller.tabTaken(generation: tab)
        try? await Task.sleep(for: .milliseconds(200))
        // A second press would still have time of its own; the first's
        // limit is the one that counts.
        p.card.accepted()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(p.controller.isShown)
        // The reread answers with the body in view, after the limit.
        p.reader.releaseCandidates()
        await until { !outcomes.list.isEmpty }
        #expect(outcomes.list == [.insertRefused])
        #expect(outcomes.refused.count == 1)
        #expect(outcomes.refused.first?.0 == .busy)
        #expect(outcomes.refused.first?.1 == proposalDraft)
        #expect(p.route.accepted.isEmpty)
        #expect(MockField.shared.text == "\n")
        #expect(MockField.shared.keys.isEmpty)
        #expect(!p.card.isShown)
        let entry = try #require(p.history.entries.first)
        #expect(entry.outcome == .notInserted)
        #expect(entry.reason == "busy")
    }

    @Test func theRereadsWaitCountsAgainstTheAcceptsLimit() async throws {
        let (p, outcomes, tab) = try await heldReread(acceptLimit: .seconds(1))
        let pasteboard = try #require(MockField.shared.pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("the person's clipboard", forType: .string)
        let draft = proposalDraft
        let stage = OSAllocatedUnfairLock(initialState: (labelsRead: false, slept: false))
        nonisolated(unsafe) let clipboard = pasteboard
        MockField.shared.onPlaceholderRead = {
            guard clipboard.string(forType: .string) == draft else { return }
            stage.withLock { $0.labelsRead = true }
        }
        // The inserter's last read before the paste key takes half a second:
        // well inside a limit counted from the replayed press, past one
        // counted from Tab.
        MockField.shared.onSecureCheck = {
            let sleep = stage.withLock { stage -> Bool in
                guard stage.labelsRead, !stage.slept else { return false }
                stage.slept = true
                return true
            }
            if sleep { Thread.sleep(forTimeInterval: 0.5) }
        }
        p.controller.tabTaken(generation: tab)
        // The reread takes most of the rest.
        try? await Task.sleep(for: .milliseconds(600))
        p.reader.releaseCandidates()
        await until { !outcomes.list.isEmpty }
        MockField.shared.onSecureCheck = nil
        MockField.shared.onPlaceholderRead = nil
        // The server accepted and the inserter reached its last read, and
        // the final check refused the write.
        #expect(p.route.accepted.count == 1)
        #expect(stage.withLock { $0.slept })
        #expect(outcomes.list == [.insertRefused])
        #expect(outcomes.refused.first?.0 == .busy)
        #expect(outcomes.refused.first?.1 == proposalDraft)
        #expect(MockField.shared.keys.isEmpty)
        #expect(MockField.shared.text == "\n")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    /// What reaches a card while an accept waits for the reread.
    enum HeldInterruption: CaseIterable, Sendable {
        case escape, screenLock, reset, recording
    }

    @Test(arguments: HeldInterruption.allCases)
    func anAcceptHeldForTheRereadStopsWhenInterrupted(_ event: HeldInterruption) async throws {
        let server = try await ScriptedEndpoint([.silent])
        defer { server.stop() }
        let (p, outcomes, tab) = try await heldReread(server.endpoint)
        p.controller.tabTaken(generation: tab)
        switch event {
        case .escape:
            p.pressEscape()
        case .screenLock:
            p.card.screenLockedOrAsleep()
        case .reset:
            p.controller.reset()
        case .recording:
            // A recording starts over the card and is cancelled before the
            // reread answers: the press is not made after it.
            p.dictation.toggle()
            #expect(p.dictation.phase == .recording)
            p.dictation.cancel()
            await until { p.dictation.phase == .idle }
        }
        p.reader.releaseCandidates()
        try? await Task.sleep(for: .milliseconds(250))
        #expect(p.route.accepted.isEmpty)
        #expect(MockField.shared.text == "\n")
        #expect(MockField.shared.keys.isEmpty)
        #expect(outcomes.refused.isEmpty)
        switch event {
        case .escape:
            #expect(outcomes.list == [.dismissed])
        case .screenLock:
            #expect(outcomes.list.isEmpty)
            #expect(p.controller.isHidden)
        case .reset:
            #expect(outcomes.list == [.left])
        case .recording:
            #expect(outcomes.list.isEmpty)
            #expect(p.controller.isShown)
            #expect(p.card.acceptsInput)
        }
    }

    @Test func anAcceptFromTheFrameChecksTheFirstLineInItsOwnRead() async throws {
        let p = await proposals(nil, route: ScriptedRoute(text: proposalDraft))
        let outcomes = Outcomes()
        p.controller.ended = { outcome, _ in outcomes.list.append(outcome) }
        p.controller.notInserted = { outcomes.refused.append(($0, $1)) }
        p.controller.observe(p.unplaced())
        await until { p.card.isShown }
        p.route.hold(.accept)
        p.controller.tabTaken(generation: try #require(p.tab))
        // Scrolled out of view after Tab, with no observation to say so.
        await p.route.whileHeld { MockField.shared.scrollArea = CGRect(x: 0, y: 150, width: 1440, height: 710) }
        await until { !outcomes.list.isEmpty }
        #expect(outcomes.list == [.insertRefused])
        #expect(MockField.shared.text == "\n")
        #expect(outcomes.refused.first?.0 == .composeChanged)
        #expect(outcomes.refused.first?.1 == proposalDraft)
    }

    @Test func aQueuedGeometryRereadReadsNothingOfAnotherFocusedReply() async throws {
        let p = await proposals(nil, route: ScriptedRoute(text: proposalDraft))
        var outcomes: [ProposalOutcome] = []
        p.controller.ended = { outcome, _ in outcomes.append(outcome) }
        p.controller.observe(p.unplaced())
        await until { p.card.isShown }
        p.reader.holdingCandidates = true
        p.controller.observe(p.unplaced())
        await until { p.reader.heldCandidateCount == 1 }
        // The reread is bound to the first reply.
        let expected = try #require(p.reader.candidateExpectations.last ?? nil)
        #expect(expected.pid == p.pid)
        // Focus moves to another Gmail reply before the queued read runs,
        // and the tracker has not reported it.
        MockField.shared.focusedElement = 2
        MockField.shared.fieldReads = [:]
        p.reader.releaseCandidates()
        await until { !p.card.isShown }
        try? await Task.sleep(for: .milliseconds(100))
        // None of the second reply's description, host, frame or ancestors.
        #expect(MockField.shared.fieldReads[2] == nil)
        #expect(p.controller.isHidden)
        #expect(outcomes.isEmpty)
    }

    // MARK: Bodies whose proposal ended

    @Test func onlyTheLastSixteenEndedBodiesAreRemembered() async throws {
        let (p, outcomes) = await shownProposal()
        p.pressEscape()
        // Sixteen more replies, each proposed into and dismissed.
        for element in 2...17 {
            p.focusReply(focus: element, element: element)
            await until { p.route.created.count == element && p.card.isShown }
            p.pressEscape()
        }
        #expect(outcomes.list == Array(repeating: .dismissed, count: 17))
        // The most recent is remembered.
        p.focusReply(focus: 100, element: 17)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(p.route.created.count == 17)
        // The first went when the seventeenth was remembered, though Gmail
        // may still have it open: it is proposed into again.
        p.focusReply(focus: 101, element: 1)
        await until { p.route.created.count == 18 && p.card.isShown }
    }

    @Test func anEndedBodysElementReusedForAnotherThreadGetsNoProposal() async throws {
        let (p, outcomes) = await shownProposal()
        p.pressEscape()
        p.focusSearch(focus: 2)
        // Gmail shows another thread's reply in the same element.
        p.reader.threadID = "18c2f4a9d0e1b3ff"
        p.reader.thread = "Jordan Kim\nCan you send the slides?"
        p.focusReply(focus: 3)
        await until { p.reader.candidateReads == 3 }
        try? await Task.sleep(for: .milliseconds(200))
        // Named by its element alone, it is still the ended body.
        #expect(p.route.created.count == 1)
        #expect(p.reader.bodyReads == 2)
        #expect(!p.card.isShown)
        #expect(outcomes.list == [.dismissed])
    }

    @Test func aBodyEndedByTurningTheSettingOffIsProposedIntoOnceItIsBackOn() async throws {
        let (p, outcomes) = await shownProposal()
        p.enabled.value = false
        p.controller.reset()
        #expect(outcomes.list == [.left])
        p.enabled.value = true
        p.focusSearch(focus: 2)
        p.focusReply(focus: 3)
        await until { p.route.created.count == 2 && p.card.isShown }
    }

    // MARK: Availability and the dot

    @Test func availabilityNeedsWritingNotTheMicrophone() async {
        let route = ScriptedRoute(text: proposalDraft)
        let writer = EmailWriter(drafts: route, signedIn: true, pollInterval: .milliseconds(20), requestLimit: .seconds(5))
        func gate(drafts: Bool = true, writes: Bool = true, dot: Bool = true, accessibility: Bool = true) -> ProposalGate? {
            ReplyProposalController.gate(draftsReplies: drafts, writesEmails: writes, dotChosen: dot,
                                         accessibility: accessibility, writer: writer)
        }
        #expect(gate() == nil)
        #expect(gate(accessibility: false) == .accessibility)
        #expect(gate(drafts: false) == .setting)
        #expect(gate(writes: false) == .writesEmails)
        #expect(gate(dot: false) == .indicator)
        // The first gate shut is the one named.
        #expect(gate(drafts: false, dot: false, accessibility: false) == .setting)
        // Dictation that cannot run, as a denied microphone leaves it, plays
        // no part: the gate never asks dictation.
        let dictation = DictationController(inserter: TextInserter(), history: DictationHistory(file: nil), endpoint: nil,
                                            source: ScriptedSource(), signedIn: true, writer: writer)
        #expect(!dictation.available)
        #expect(gate() == nil)
        writer.isEnabled = false
        #expect(gate() == .writerDisabled)
        writer.isEnabled = true
        // Writing the server reported as off is remembered: no proposals,
        // though dictation still wants an email to say why it typed.
        route.onCreate = .fail(.disabled)
        _ = await writer.write(cue: "Say yes", body: EmailBody(bundleIdentifier: nil, body: "Hi"))
        #expect(writer.availability == .unavailable(.disabled))
        #expect(writer.isWanted)
        #expect(gate() == .writerUnavailable)
        let unconfigured = EmailWriter(drafts: nil, signedIn: true)
        #expect(ReplyProposalController.gate(draftsReplies: true, writesEmails: true, dotChosen: true, accessibility: true,
                                             writer: unconfigured) == .writerNotConfigured)
    }

    /// The app builds the writer signed out and tells it of the account only
    /// through dictation, at launch and when setup signs in or out
    /// (`AppModel.wireDictation`); proposals follow.
    @Test func theWriterLearnsOfTheAccountThroughDictationAsTheAppWiresIt() {
        let writer = EmailWriter(drafts: ScriptedRoute(text: proposalDraft), signedIn: false)
        let dictation = DictationController(inserter: TextInserter(), history: DictationHistory(file: nil), endpoint: nil,
                                            source: ScriptedSource(), signedIn: false, writer: writer)
        func gate() -> ProposalGate? {
            ReplyProposalController.gate(draftsReplies: true, writesEmails: true, dotChosen: true, accessibility: true, writer: writer)
        }
        #expect(gate() == .writerSignedOut)
        dictation.accountChanged(signedIn: true)
        #expect(gate() == nil)
        dictation.accountChanged(signedIn: false)
        #expect(gate() == .writerSignedOut)
    }

    @Test func theDotsLookFollowsDictationFirstAndThenTheProposal() {
        let looks: [(DictationController.Phase, ProposalPresentation, DotLook)] = [
            (.idle, .idle, .resting), (.idle, .pending, .working), (.idle, .shown, .proposed),
            (.recording, .shown, .recording), (.recording, .pending, .recording),
            (.processing, .shown, .working), (.writingEmail, .idle, .working),
        ]
        for (phase, proposal, look) in looks {
            #expect(DictationIndicators.dotLook(phase: phase, proposal: proposal) == look)
        }
    }
}

extension DictationScenarioTests {
    @Test func aTransientCandidateReadRecoversWithoutRefocusing() async {
        let p = await proposals(nil, route: ScriptedRoute(text: proposalDraft))
        let log = LoggedLines()
        await AppLog.$composeLines.withValue(log) {
            MockField.shared.descriptionUnanswered = true
            p.reader.candidateAnswered = { MockField.shared.descriptionUnanswered = false }
            p.controller.observe(p.observation())
            await until { p.card.isShown }
        }
        #expect(p.reader.candidateReads == 2)
        #expect(log.all.contains("proposal.candidate.retry"))
        #expect(p.route.created.count == 1)
        #expect(MockField.shared.accessibilityWrites == 0)
    }

    @Test func permanentCandidateReadFailureStopsAtThreeAttempts() async throws {
        let p = await proposals(nil, route: ScriptedRoute(text: proposalDraft))
        MockField.shared.descriptionUnanswered = true
        p.controller.observe(p.observation())
        await until { p.reader.candidateReads == 3 }
        try await Task.sleep(for: .milliseconds(400))
        for _ in 0..<5 { p.controller.observe(p.observation()) }
        #expect(p.reader.candidateReads == 3)
        #expect(!p.card.isShown)
        #expect(p.route.created.isEmpty)
    }

    @Test func focusLeavingDuringCandidateBackoffCancelsItsRetry() async throws {
        let p = await proposals(nil, route: ScriptedRoute(text: proposalDraft))
        MockField.shared.descriptionUnanswered = true
        p.controller.observe(p.observation())
        try await Task.sleep(for: .milliseconds(30))
        p.focusSearch(focus: 2)
        MockField.shared.descriptionUnanswered = false
        try await Task.sleep(for: .milliseconds(500))
        #expect(!p.card.isShown)
        #expect(p.route.created.isEmpty)
        #expect(p.reader.candidateReads == 2)
    }

    @Test func aNativeFocusChangeDuringCandidateBackoffCannotReadTheNewBody() async throws {
        let p = await proposals(nil, route: ScriptedRoute(text: proposalDraft))
        MockField.shared.descriptionUnanswered = true
        p.reader.candidateAnswered = {
            MockField.shared.descriptionUnanswered = false
            MockField.shared.focusedElement = 2
        }
        p.controller.observe(p.observation())
        await until { p.reader.candidateReads == 2 }
        try await Task.sleep(for: .milliseconds(400))
        #expect(p.reader.candidateExpectations[1] != nil)
        #expect(!p.card.isShown)
        #expect(p.route.created.isEmpty)
        #expect(p.reader.bodyReads == 0)
    }
}
