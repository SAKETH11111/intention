import AppKit
@testable import Dictation
import Testing

// What voice compose waits on once the words have come back, and what can
// arrive while it waits. `voiceComposeMatrix` runs one scenario for each
// reachable pairing, listed in `ComposeMatrix.cells`, in Mail's message
// body with the caret at the start of the quoted thread.
//
// The rule that holds at every point: how a dictation ends is decided
// once, by `DictationController.decide`, and whoever decides first carries
// it out. That is the dictation's own continuation, which inserts the
// email or the words; a cancel, which inserts nothing and keeps the words
// in history; or an account change while the email is written, which
// types the words with the notice. Every continuation asks `isOpen` after
// each await before it acts, and every cancel and account change asks it
// before it touches the dictation.
//
// Where it waits, in order:
// - The body read, `readFocusedEmailDraft`, on the inserter's executor.
//   Phase `processing`, nothing decided.
// - Draft creation, the writer's `create`. Phase `writingEmail` from here
//   until the writer answers, nothing decided.
// - The wait between two polls, the writer's `pollInterval`.
// - A poll, the writer's `read`.
// - Acceptance, the writer's `accept`.
// - The cancel by id the writer sends after a call that failed, before it
//   answers with that failure.
// - The start of the task an account change starts to type the words.
//   Decided, nothing written yet, and phase `processing` again.
// - The insertion: the email, the words with the notice, or the words
//   alone in a Mail field that is not an email body. Decided. Phase
//   `writingEmail` while the email goes in, `processing` while words do,
//   so no indicator says an email is on its way once it is not.
// Nothing else waits. From the words to the body read, from the body read
// to creation, and from the writer's answer to the insertion, the code
// runs without a suspension.
//
// What can arrive at any of them:
// - A sign-out.
// - A refused key. From the draft route's own call, the call fails with
//   the refusal and the writer reports it, which signs the Mac out, while
//   the attempt still counts; from any other request it reaches dictation
//   as the sign-out above.
// - The key replaced by another account's: an account change while signed
//   in.
// - A second account change: a sign-out and then a sign-in.
// - The person cancelling.
// - Focus moving to another field.
// - The selection changing: the caret moving, or a selection growing
//   forward from the caret, which leaves the text before it as it was.
// - Text typed at the caret.
// - The field turning secure.
// - The writer failing: a call that fails for good, an abstention, or a
//   draft taken back. A poll that fails for a transient reason, a 503, a
//   429 or a lost connection, is read again until the limit, so it ends as
//   a draft that finishes or as the limit passing.
// - The writer's limit passing.
// - The dictation ending: cancelled, and the next one started, while the
//   old wait goes on.
//
// What each must end with. "Words typed" is the words in once, word for
// word, with the notice and one entry saying they went in. "Kept as
// cancelled" is nothing in, no notice and one entry of the words with the
// reason `cancelled`. "Refused" is nothing in, no notice and one entry with
// the inserter's reason: the email's, with the words beside it, when an
// email was written, otherwise the words'.
//
// At the body read:
// - Any account change: the read finishes. An email body gets the words
//   typed and no request is made under the other account. A Mail field
//   that is not an email body gets the words alone, as plain dictation.
// - Cancel: kept as cancelled, with no request.
// - Focus, selection or text: the read has the selection already, so the
//   email is written and refused, `focusChanged` when focus moved and
//   `fieldChanged` otherwise. A change made before the read reaches the
//   selection is the field the read sees, under plain dictation's rule
//   that only the text before the caret must read as at the start, so a
//   selection grown forward from the caret by then is written over
//   (`aSelectionGrownForwardBeforeTheBodyReadReachesItIsWrittenOver`).
//   In a Mail field that is not an email body, plain dictation's rule
//   decides, as at the insertion below.
// - Secure: the read ends without text and the words are refused,
//   `secureField`, with no request and no text read while secure.
// - The writer: not reachable, nothing has been asked for yet.
// - The dictation ending: the read's answer is dropped and the next
//   dictation runs as its own.
//
// At creation, the wait between polls, a poll and acceptance:
// - Any account change, a refused key from that very call included: words
//   typed at once, the request withdrawn by id, and whatever the writer
//   answers later dropped, an accepted email too.
// - Cancel: kept as cancelled, and the request withdrawn.
// - Focus, selection or text: the email is written and refused by the body
//   read's guard. Secure: refused the same way, `secureField`.
// - The writer failing, at creation, a poll or acceptance: words typed.
//   Between polls no call is in flight, so nothing fails there.
// - The limit: creation, a poll or acceptance still unanswered when it
//   passes ends the attempt there, the words are typed and the request
//   withdrawn, and the call's answer when it comes is dropped.
// - The dictation ending: the old request withdrawn, nothing of it
//   released, and the next dictation runs as its own.
//
// After a failure the request is cancelled by id without the words
// waiting on that cancel, so nothing can happen there
// (`aFailedCreateTypesTheWordsWithoutWaitingOnItsCancel`).
//
// At the start of the task that types the words after an account change:
// - Another account change: nothing more, the words go in once.
// - Cancel: refused, the words go in and the entry says so.
// - Focus, selection, text or secure: the words are refused by the guard.
// - The writer answering after the change, whatever it answers: dropped.
//   The account changes at creation, a poll and acceptance let the held
//   call answer after the sign-out.
// - The dictation ending: not reachable. The dictation stays open until
//   its insertion ends it. A later dictation can start and record
//   meanwhile, but its words wait for this one to end before anything of
//   the field is read for them
//   (`aDictationStartedWhileAnEmailIsWrittenShowsRecordingThenTheEmailsCaption`).
//
// At the insertion:
// - Any account change: it finishes, with one entry for what went in.
// - Cancel: refused, it finishes.
// - Focus, selection, text or secure: the email, or the words in its
//   place, are refused by the guard and the inserter's own checks. The
//   words alone in a Mail field that is not an email body go in under
//   plain dictation's rule, unchanged by voice compose: they are refused
//   when focus moved, the field turned secure or the text before the caret
//   changed (`focusChanged`, the field is another to it), and a selection
//   grown forward from the caret is written over, as it always has been.
// - The writer: it has answered, or was never asked. The dictation ending:
//   not reachable.

/// Voice compose, from the trigger to the email in the body: dictation
/// against the local endpoint stand-in, the email writer against a draft
/// route answered inside the process, and the scripted field as Mail's
/// message body or Gmail's. The scenarios extend the dictation suite so
/// that everything touching the scripted field runs in one serialized line.
extension DictationScenarioTests {
    /// The reply the person is answering, with the caret at its start.
    private var thread: String { "\n\nOn Monday, Jane wrote:\n> Could you make Thursday at 10?" }
    private var draft: String { "Hi Jane,\n\nThursday at 10 works for me. Could you send the agenda first?\n\nBest," }

    /// Dictation with a writer over `route`, and the scripted field as
    /// Mail's message body unless `configure` says otherwise. `plain`
    /// builds dictation without a writer, as a build with no draft route.
    private func voice(_ endpoint: DictationEndpoint, route: ScriptedRoute, enabled: Bool = true, mail: Bool = true,
                       limit: Duration = .seconds(5), poll: Duration = .milliseconds(20), plain: Bool = false,
                       clock: any WriterClock = ContinuousWriterClock(), source: ScriptedSource = ScriptedSource(), clipboardReadable: Bool = true,
                       configure: (MockField) -> Void = { _ in }) -> (dictation: DictationController, writer: EmailWriter) {
        MockField.reset()
        let field = MockField.shared
        field.pasteboard = NSPasteboard(name: NSPasteboard.Name("co.intention.tests.\(UUID().uuidString)"))
        if mail {
            field.document = true
            field.text = thread
            field.selection = FieldRange(location: 0, length: 0)
        }
        configure(field)
        let inserter = TextInserter(pasteboard: PasteboardOwner(pasteboard: field.pasteboard!, mayRead: { clipboardReadable }))
        let writer = EmailWriter(drafts: route, signedIn: true, pollInterval: poll, requestLimit: limit, clock: clock)
        writer.isEnabled = enabled
        let dictation = DictationController(inserter: inserter, history: DictationHistory(file: nil), endpoint: endpoint,
                                            source: source, signedIn: true, writer: plain ? nil : writer)
        return (dictation, writer)
    }

    private func settle(_ dictation: DictationController) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while dictation.phase != .idle, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(dictation.phase == .idle)
    }

    private func until(_ condition: @escaping () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }

    /// Speaks once, by click, and waits for the dictation to end.
    private func dictate(_ dictation: DictationController) async {
        dictation.toggle()
        try? await Task.sleep(for: .milliseconds(150))
        dictation.toggle()
        await settle(dictation)
    }

    @Test(arguments: [false, true], ["none", "before", "after", "length", "selection", "focus", "secure"])
    func anEmailOrItsSpokenWordsCanFollowAConfirmedLateCaretCollapse(_ fallback: Bool, _ change: String) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "first", text: "first"), .answer(transcript: "second", text: "second")])
        defer { server.stop() }
        let route = ScriptedRoute(text: "email")
        let (dictation, writer) = voice(server.endpoint, route: route, enabled: false) {
            $0.text = "keep old keep"
            $0.selection = FieldRange(location: 5, length: 3)
            $0.writes = .held
        }
        var refused: [String] = []
        dictation.notInserted = { refused.append($1) }
        await dictate(dictation)
        let field = MockField.shared
        field.land()
        field.selection = FieldRange(location: 5, length: 5)
        writer.isEnabled = true
        if fallback { route.onCreate = .fail(.invalidInput) }
        if change != "none" {
            field.onSelectionWrite = { [field] in
                let reads = field.focusReads
                // Change the field at the caller's guard after the fresh
                // state confirmed Intention's own collapse, before the paste.
                field.onFocusRead = { [field] in
                    guard field.focusReads == reads + 4 else { return }
                    switch change {
                    case "before": field.text = "deep first keep"
                    case "after": field.text = "keep first deep"
                    case "length": field.text += "!"
                    case "selection": field.selection = FieldRange(location: 5, length: 5)
                    case "focus": field.focusedElsewhere = true
                    case "secure": field.secure = true
                    default: break
                    }
                }
            }
        }
        await dictate(dictation)
        let written = fallback ? "second" : "email"
        #expect(route.created.count == 1)
        #expect(route.created.first?.compose.observedThread == "keep first keep")
        let unchanged = change == "none"
        let shown = change == "before" ? "deep first keep" : change == "after" ? "keep first deep" : change == "length" ? "keep first keep!" : "keep first keep"
        #expect(field.text == (unchanged ? "keep first" + written + " keep" : shown))
        #expect(field.selectionWrites == 1)
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys == (unchanged ? ["paste"] : []))
        #expect(dictation.history.entries.map(\.outcome) == [unchanged ? .inserted : .notInserted, .uncertain])
        #expect(dictation.history.entries.map(\.text) == [written, "first"])
        #expect(refused == (unchanged ? [] : [written]))
        if !unchanged {
            let reason: EditReason = change == "focus" ? .focusChanged : change == "secure" ? .secureField : .fieldChanged
            #expect(dictation.history.entries.first?.reason == reason.rawValue)
        }
        #expect(dictation.notice == (unchanged && fallback ? .typedTranscript(nil) : nil))
        #expect(field.textReadsWhileSecure == 0)
        #expect(field.editsWhileSecure == 0)
    }

    @Test(arguments: [false, true], ["none", "fresh", "guard"])
    func anEmailAfterALongCaretRecoveryKeepsChangedWordsForCopy(_ fallback: Bool, _ timing: String) async throws {
        let first = String(repeating: "a", count: 100)
        let server = try await ScriptedEndpoint([.answer(transcript: first, text: first), .answer(transcript: "second", text: "second")])
        defer { server.stop() }
        let route = ScriptedRoute(text: "email")
        let (dictation, writer) = voice(server.endpoint, route: route, enabled: false) {
            $0.text = "keep old keep"
            $0.selection = FieldRange(location: 5, length: 3)
            $0.writes = .held
        }
        var timings: [DictationTiming] = []
        dictation.onOutcome = { _, recorded, _ in timings.append(recorded) }
        var refused: [String] = []
        dictation.notInserted = { refused.append($1) }
        await dictate(dictation)
        let field = MockField.shared
        field.land()
        field.selection = FieldRange(location: 5, length: 100)
        writer.isEnabled = true
        if fallback { route.onCreate = .fail(.invalidInput) }
        let changed = "keep b" + String(repeating: "a", count: 99) + " keep"
        if timing != "none" {
            field.onSelectionWrite = { [field] in
                let reads = field.focusReads
                field.onFocusRead = { [field] in
                    if field.focusReads == reads + (timing == "fresh" ? 3 : 4) { field.text = changed }
                }
            }
        }
        await dictate(dictation)
        let written = fallback ? "second" : "email"
        let unchanged = timing == "none"
        #expect(route.created.count == 1)
        #expect(route.created.first?.compose.observedThread == "keep " + first + " keep")
        #expect(field.text == (unchanged ? "keep " + first + written + " keep" : changed))
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys == (unchanged ? ["paste"] : []))
        #expect(dictation.history.entries.map(\.outcome) == [unchanged ? .inserted : .notInserted, .uncertain])
        #expect(dictation.history.entries.map(\.text) == [written, first])
        #expect(refused == (unchanged ? [] : [written]))
        if !unchanged {
            #expect(dictation.history.entries.first?.reason == "fieldChanged")
            #expect(timings.last?.insertionResult == .notInserted(.fieldChanged))
            #expect(timings.last?.outcome == .failed(.insert))
        }
    }

    @Test func wordsSpokenIntoMailsMessageBodyBecomeAnEmailInThatBody() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes and ask for the agenda", text: "Say yes and ask for the agenda.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        let (dictation, _) = voice(server.endpoint, route: route)
        var phases: [DictationController.Phase] = []
        dictation.phaseChanged = { phases.append($0) }
        await dictate(dictation)
        #expect(phases == [.recording, .processing, .writingEmail, .idle])
        // The email, not the words, at the caret above the quoted thread.
        #expect(MockField.shared.text == draft + thread)
        #expect(MockField.shared.accessibilityWrites == 1)
        let input = try #require(route.created.first)
        #expect(route.created.count == 1)
        #expect(input.cue == "Say yes and ask for the agenda.")
        #expect(input.compose.recipients.isEmpty)
        #expect(input.compose.subject == "")
        #expect(input.compose.observedThread == thread)
        #expect(input.mode == .reply)
        #expect(route.accepted == [input.requestID])
        #expect(route.cancelled.isEmpty)
        // Beyond the field, the walk to the window's To field: its role and
        // identifier, and the window's role and children. Once the body is
        // read, the same walk to the header fields and the To field's
        // value, which the scripted window leaves empty.
        #expect(MockField.shared.readsBeyondField == 9)
        #expect(MockField.shared.windowElementReads
            == [kAXRoleAttribute, kAXIdentifierAttribute, kAXRoleAttribute, kAXIdentifierAttribute, kAXValueAttribute])
        let entry = try #require(dictation.history.entries.first)
        #expect(entry.text == draft)
        #expect(entry.spoken == "Say yes and ask for the agenda.")
        #expect(entry.outcome == .inserted)
        #expect(!dictation.history.needsAttention)
        #expect(dictation.notice == nil)
        // The endpoint still heard the register and the text before the caret.
        #expect(server.connections.first?.start["app"] as? String == "email")
    }

    @Test func wordsSpokenIntoGmailsMessageBodyBecomeAnEmail() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        let (dictation, _) = voice(server.endpoint, route: route, mail: false) {
            $0.bundleIdentifier = "com.google.Chrome"
            $0.web = true
            $0.label = "Message Body"
            $0.pageURL = "https://mail.google.com/mail/u/0/#inbox?compose=new"
        }
        await dictate(dictation)
        #expect(MockField.shared.text == "a" + draft + "bc")
        #expect(route.created.first?.compose.observedThread == "abc")
        #expect(route.created.first?.compose.recipients.isEmpty == true)
        #expect(dictation.history.entries.first?.text == draft)
        // The page's address was read, and the body's text, then the
        // element above the body and its role and subrole, for the reply
        // around it: the scripted page has none, so nothing else was read.
        #expect(MockField.shared.readsBeyondField == 6)
        #expect(route.created.first?.compose.subject == "")
        #expect(route.created.first?.compose.threadID == nil)
    }

    @Test(arguments: ["Cuerpo del mensaje", "本文"])
    func localizedGmailDictationReachesTheEmailWriter(label: String) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        let (dictation, _) = voice(server.endpoint, route: route, mail: false) {
            $0.bundleIdentifier = "com.google.Chrome"
            $0.web = true
            $0.label = label
            $0.domClassList = ["Am", "editable"]
            $0.pageURL = "https://mail.google.com/mail/u/0/#inbox?compose=new"
        }
        await dictate(dictation)
        #expect(route.created.count == 1)
        #expect(MockField.shared.text == "a" + draft + "bc")
        #expect(dictation.history.entries.first?.text == draft)
    }

    @Test(arguments: ["outlook.office.com", "outlook.live.com"], ["Message body", "Message body, press Alt+F10 to exit"])
    func outlookSpokenCueReachesTheScriptedWriterAndInsertsItsWholeEmail(host: String, label: String) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        let (dictation, _) = voice(server.endpoint, route: route, mail: false) {
            $0.bundleIdentifier = "com.google.Chrome"
            $0.web = true
            $0.label = label
            $0.pageURL = "https://\(host)/mail/deeplink/compose"
            $0.text = thread
            $0.selection = FieldRange(location: 0, length: 0)
        }
        await dictate(dictation)
        #expect(MockField.shared.text == draft + thread)
        let input = try #require(route.created.first)
        #expect(route.created.count == 1)
        #expect(input.cue == "Say yes.")
        #expect(input.compose.observedThread == thread)
        #expect(input.compose.threadID == nil)
        #expect(route.accepted == [input.requestID])
        #expect(dictation.history.entries.first?.text == draft)
        #expect(MockField.shared.textReadsWhileSecure == 0)
    }

    @Test(arguments: ["To", "Cc", "Bcc", "Subject", "Search"])
    func outlookSpokenWordsInHeadersAndSearchNeverReachTheWriter(label: String) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        let (dictation, _) = voice(server.endpoint, route: route, mail: false) {
            $0.bundleIdentifier = "com.google.Chrome"
            $0.web = true
            $0.label = label
            $0.pageURL = "https://outlook.office.com/mail"
        }
        await dictate(dictation)
        #expect(route.created.isEmpty)
        #expect(MockField.shared.text == "aHello.bc")
    }

    @Test func wordsSpokenIntoAnyOtherFieldAreTypedAsTheyAre() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello there", text: "Hello there."),
                                                 .answer(transcript: "hello there", text: "Hello there.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        // The scripted field as a composer that is not a message body, in
        // an app that is not Mail. First with no writer at all, for the
        // reads a dictation made before voice compose.
        let (before, _) = voice(server.endpoint, route: route, mail: false, plain: true) { $0.bundleIdentifier = "com.tinyspeck.slackmacgap" }
        await dictate(before)
        #expect(MockField.shared.text == "aHello there.bc")
        let (textReads, lengthReads, beyond) = (MockField.shared.textReads, MockField.shared.lengthReads, MockField.shared.readsBeyondField)
        // With the writer, the same dictation types the same and reads
        // nothing more of the field: it is told from the app and labels
        // noted at the start, without another read.
        let (dictation, _) = voice(server.endpoint, route: route, mail: false) { $0.bundleIdentifier = "com.tinyspeck.slackmacgap" }
        var phases: [DictationController.Phase] = []
        dictation.phaseChanged = { phases.append($0) }
        await dictate(dictation)
        #expect(phases == [.recording, .processing, .idle])
        #expect(MockField.shared.text == "aHello there.bc")
        #expect(route.created.isEmpty)
        #expect(dictation.notice == nil)
        #expect(dictation.history.entries.first?.text == "Hello there.")
        #expect(dictation.history.entries.first?.spoken == nil)
        #expect(MockField.shared.textReads == textReads)
        #expect(MockField.shared.lengthReads == lengthReads)
        #expect(MockField.shared.readsBeyondField == beyond)
    }

    @Test func theWaitForTheEmailIsTimedApartFromTheInsertion() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes."),
                                                 .answer(transcript: "hello there", text: "Hello there.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        // The server takes 300 ms to write the email.
        route.beforeRead = { Thread.sleep(forTimeInterval: 0.3) }
        let (dictation, _) = voice(server.endpoint, route: route)
        var timings: [DictationTiming] = []
        dictation.onOutcome = { _, timing, _ in timings.append(timing) }
        await dictate(dictation)
        #expect(MockField.shared.text == draft + thread)
        let email = try #require(timings.last)
        #expect(email.outcome == .inserted)
        #expect(email.waitsForEmail)
        #expect(email.intervals.map(\.stage) == [.record, .transcribe, .clean, .email, .insert])
        let wait = try #require(email.intervals.first { $0.stage == .email }).duration
        let insertion = try #require(email.intervals.first { $0.stage == .insert }).duration
        #expect(wait >= 0.3)
        #expect(insertion < 0.3)
        // A dictation into a field that cannot be an email body has no
        // email stage, and insert follows clean.
        let (other, _) = voice(server.endpoint, route: route, mail: false) { $0.bundleIdentifier = "com.tinyspeck.slackmacgap" }
        other.onOutcome = { _, timing, _ in timings.append(timing) }
        await dictate(other)
        let plain = try #require(timings.last)
        #expect(plain.outcome == .inserted)
        #expect(!plain.waitsForEmail)
        #expect(plain.intervals.map(\.stage) == [.record, .transcribe, .clean, .insert])
    }

    @Test func wordsSpokenIntoMailsSignatureEditorAreTypedAsTheyAre() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "best jane", text: "Best, Jane")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        // Mail's signature editor in its Settings window: an editable web
        // area with focus in Mail's process, in a window with panes, a list
        // of signatures and buttons, and no To field.
        typealias Element = MockField.WindowElement
        let (dictation, _) = voice(server.endpoint, route: route) {
            $0.text = ""
            $0.windowElements = [Element(role: kAXToolbarRole, children: Array(repeating: Element(role: kAXButtonRole), count: 3)),
                                 Element(role: kAXScrollAreaRole, children: [Element(role: kAXTableRole)]),
                                 Element(role: kAXButtonRole)]
        }
        var phases: [DictationController.Phase] = []
        dictation.phaseChanged = { phases.append($0) }
        await dictate(dictation)
        // The words, as any dictation types them: no email asked for, no
        // email being written shown and no notice.
        #expect(phases == [.recording, .processing, .idle])
        #expect(MockField.shared.text == "Best, Jane")
        #expect(route.created.isEmpty)
        #expect(dictation.notice == nil)
        #expect(dictation.history.entries.first?.text == "Best, Jane")
        #expect(dictation.history.entries.first?.spoken == nil)
        #expect(!MockField.shared.windowElementReads.contains(kAXValueAttribute))
    }

    @Test func anEmailBodyWhoseTextCannotBeReadGetsTheWordsAndTheNotice() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        // Mail's body, a long run of one character with the caret in the
        // middle, whose whole text does not answer.
        let run = String(repeating: "a", count: 300)
        let (dictation, _) = voice(server.endpoint, route: route) {
            $0.text = run
            $0.selection = FieldRange(location: 150, length: 0)
            $0.failingRead = FieldRange(location: 0, length: 300)
        }
        var phases: [DictationController.Phase] = []
        dictation.phaseChanged = { phases.append($0) }
        var notices: [DictationController.Notice?] = []
        dictation.noticeChanged = { notices.append($0) }
        await dictate(dictation)
        // No request, the words at the caret, and the person told.
        #expect(phases == [.recording, .processing, .idle])
        #expect(route.created.isEmpty)
        #expect(MockField.shared.text == String(repeating: "a", count: 150) + "Say yes." + String(repeating: "a", count: 150))
        #expect(notices == [.typedTranscript(nil)])
        #expect(dictation.history.entries.first?.outcome == .inserted)
        #expect(dictation.history.entries.first?.spoken == nil)
    }

    @Test func wordsTypedByAPasteThatReplacedTheClipboardSayBothInTurn() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        route.onCreate = .fail(.unreachable)
        // The body takes only a paste, and macOS does not let Intention read
        // the clipboard, so the person's copy is not put back.
        let (dictation, _) = voice(server.endpoint, route: route, clipboardReadable: false) { $0.writes = .refuse }
        MockField.shared.pasteboard?.setString("the person's clipboard", forType: .string)
        // Ended by hand. The notice's own wait and the time kept after it
        // for whatever comes next run side by side, and each `end` passes
        // both, as four seconds would.
        let timer = NoticeTimer()
        dictation.noticePause = { try? await timer.wait(DictationController.noticeDuration) }
        var notices: [DictationController.Notice?] = []
        dictation.noticeChanged = { notices.append($0) }
        await dictate(dictation)
        #expect(MockField.shared.text == "Say yes." + thread)
        #expect(MockField.shared.pasteboard?.string(forType: .string) == "Say yes.")
        #expect(notices == [.typedTranscript(nil)])
        #expect(dictation.pasteReplacedClipboard)
        await until { timer.asked.count == 2 }
        timer.end()
        await until { notices == [.typedTranscript(nil), .clipboardReplaced] }
        await until { timer.asked.count == 4 }
        timer.end()
        await until { notices == [.typedTranscript(nil), .clipboardReplaced, nil] }
    }

    /// A proposal refusal shows immediately during the existing paste notices.
    @Test func aRefusedAcceptShowsImmediatelyDuringPasteNotices() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        route.onCreate = .fail(.unreachable)
        let (dictation, _) = voice(server.endpoint, route: route, clipboardReadable: false) { $0.writes = .refuse }
        MockField.shared.pasteboard?.setString("the person's clipboard", forType: .string)
        let timer = NoticeTimer()
        dictation.noticePause = { try? await timer.wait(DictationController.noticeDuration) }
        var refused: [String] = []
        dictation.notInserted = { refused.append($1) }
        await dictate(dictation)
        #expect(MockField.shared.text == "Say yes." + thread)
        #expect(dictation.notice == .typedTranscript(nil))
        dictation.proposalNotInserted(.focusChanged, "A proposed reply.")
        #expect(refused == ["A proposed reply."])
        #expect(dictation.hasMoreToSay)
        // The existing notice sequence keeps its own timing.
        await until { timer.asked.count == 2 }
        timer.end()
        await until { dictation.notice == .clipboardReplaced }
        #expect(refused == ["A proposed reply."])
        #expect(dictation.hasMoreToSay)
        // Ending the second notice must not produce another popup.
        await until { timer.asked.count == 4 }
        timer.end()
        await until { dictation.notice == nil }
        #expect(refused == ["A proposed reply."])
        await until { !dictation.hasMoreToSay }
    }

    /// Clearing the last notice is when the app may install a waiting update,
    /// so the next dictation must already be recording at that moment, or the
    /// update would relaunch Intention with the microphone open.
    @Test func theNextDictationIsRecordingWhenTheLastNoticeClears() async throws {
        let server = try await ScriptedEndpoint([
            .answer(transcript: "say yes", text: "Say yes."), .answer(transcript: "and more", text: "And more."),
        ])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        let run = String(repeating: "a", count: 300)
        let (dictation, _) = voice(server.endpoint, route: route) {
            $0.text = run
            $0.selection = FieldRange(location: 150, length: 0)
            $0.failingRead = FieldRange(location: 0, length: 300)
        }
        await dictate(dictation)
        #expect(dictation.notice == .typedTranscript(nil))
        var phaseWhenCleared: DictationController.Phase?
        dictation.noticeChanged = { notice in
            if notice == nil, phaseWhenCleared == nil { phaseWhenCleared = dictation.phase }
        }
        await dictate(dictation)
        #expect(phaseWhenCleared == .recording)
    }

    @Test func withTheSwitchOffWordsInAnEmailBodyAreTyped() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        let (dictation, writer) = voice(server.endpoint, route: route, enabled: false)
        var phases: [DictationController.Phase] = []
        dictation.phaseChanged = { phases.append($0) }
        await dictate(dictation)
        #expect(phases == [.recording, .processing, .idle])
        #expect(MockField.shared.text == "Say yes." + thread)
        #expect(route.created.isEmpty)
        #expect(dictation.notice == nil)
        // Turned on, the next dictation writes.
        writer.isEnabled = true
        MockField.shared.text = thread
        MockField.shared.selection = FieldRange(location: 0, length: 0)
        await dictate(dictation)
        #expect(MockField.shared.text == draft + thread)
        #expect(route.created.count == 1)
    }

    @Test func turningTheSwitchOffWhileTheEmailIsWrittenTypesTheWordsAndNeverTheEmail() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        // The server would answer with a finished email once it is let go.
        route.onCreate = .complete
        route.hold(.create)
        let (dictation, writer) = voice(server.endpoint, route: route)
        var notices: [DictationController.Notice?] = []
        dictation.noticeChanged = { notices.append($0) }
        dictation.toggle()
        try? await Task.sleep(for: .milliseconds(150))
        dictation.toggle()
        await route.whileHeld {
            #expect(dictation.phase == .writingEmail)
            dictation.writesEmailsChanged(false)
        }
        await settle(dictation)
        // Anything the held request could still set off has had its time.
        try? await Task.sleep(for: .milliseconds(200))
        // Off means words in an email body are typed as they are: they go
        // in once, with the notice, and the email the server finished does
        // not, nor is it accepted.
        #expect(MockField.shared.text == "Say yes." + thread)
        #expect(MockField.shared.accessibilityWrites == 1)
        #expect(notices == [.typedTranscript(nil)])
        #expect(route.created.count == 1)
        #expect(route.cancelled == route.created.map(\.requestID))
        #expect(route.accepted.isEmpty)
        #expect(!writer.isEnabled)
        #expect(dictation.history.entries.count == 1)
        let entry = try #require(dictation.history.entries.first)
        #expect(entry.text == "Say yes.")
        #expect(entry.outcome == .inserted)
        #expect(entry.spoken == nil)
    }

    @Test func turningTheSwitchOffWhileTheBodyIsReadAsksForNoEmail() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        let (dictation, _) = voice(server.endpoint, route: route)
        var notices: [DictationController.Notice?] = []
        dictation.noticeChanged = { notices.append($0) }
        let gate = InsertionGate()
        dictation.phaseChanged = { if $0 == .processing { gate.arm() } }
        dictation.toggle()
        try? await Task.sleep(for: .milliseconds(150))
        dictation.toggle()
        await gate.whileHeld { dictation.writesEmailsChanged(false) }
        await settle(dictation)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(MockField.shared.text == "Say yes." + thread)
        #expect(MockField.shared.accessibilityWrites == 1)
        #expect(notices == [.typedTranscript(nil)])
        #expect(route.created.isEmpty)
        #expect(dictation.history.entries.count == 1)
        #expect(dictation.history.entries.first?.outcome == .inserted)
    }

    @Test func turningTheSwitchOffWhileTheEmailGoesInLeavesTheEmail() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        let (dictation, _) = voice(server.endpoint, route: route)
        var notices: [DictationController.Notice?] = []
        dictation.noticeChanged = { notices.append($0) }
        // The email is accepted and the switch goes off while the inserter
        // is putting it in: the dictation has ended, so it finishes.
        let gate = InsertionGate()
        dictation.phaseChanged = { if $0 == .writingEmail { gate.arm() } }
        dictation.toggle()
        try? await Task.sleep(for: .milliseconds(150))
        dictation.toggle()
        await gate.whileHeld { dictation.writesEmailsChanged(false) }
        await settle(dictation)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(MockField.shared.text == draft + thread)
        #expect(MockField.shared.accessibilityWrites == 1)
        #expect(notices.isEmpty)
        #expect(route.accepted == route.created.map(\.requestID))
        #expect(route.cancelled.isEmpty)
        #expect(dictation.history.entries.count == 1)
        #expect(dictation.history.entries.first?.text == draft)
    }

    @Test(arguments: [ScriptedRoute.Answer.fail(.unreachable), .abstain(.mailImportPending), .abstain(.contextPreparing), .abstain(.intentionUnresolved), .abstain(.excluded), .fail(.busy(retryAfter: 1)),
                      .fail(.invalidInput), .fail(.unauthorized), .takeBack])
    func whenTheEmailCannotBeWrittenTheWordsAreTypedAndTheDotSaysSo(answer: ScriptedRoute.Answer) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        route.onCreate = answer
        let (dictation, _) = voice(server.endpoint, route: route)
        var phases: [DictationController.Phase] = []
        dictation.phaseChanged = { phases.append($0) }
        var notices: [DictationController.Notice?] = []
        dictation.noticeChanged = { notices.append($0) }
        await dictate(dictation)
        // Writing the email, then finishing as any dictation does while the
        // words go in in its place.
        #expect(phases == [.recording, .processing, .writingEmail, .processing, .idle])
        // The words, word for word, where the email would have gone.
        #expect(MockField.shared.text == "Say yes." + thread)
        let reason: DraftReason? = switch answer {
        case let .abstain(reason): reason
        case .takeBack: .superseded
        default: nil
        }
        let expected: DictationController.Notice = if case .abstain(.mailImportPending) = answer { .mailImportPending } else { .typedTranscript(reason) }
        #expect(dictation.notice == expected)
        #expect(notices == [expected])
        // One request, and no second one by Intention itself.
        try? await Task.sleep(for: .milliseconds(60))
        #expect(route.created.count == 1)
        #expect(route.accepted.isEmpty)
        let entry = try #require(dictation.history.entries.first)
        #expect(entry.text == "Say yes.")
        #expect(entry.outcome == .inserted)
        #expect(!dictation.history.needsAttention)
    }

    @Test func wordsThatMayHaveGoneInInPlaceOfAnEmailCarryTheUncertaintyNotice() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        route.onCreate = .fail(.unreachable)
        // Mail accepts the write of the words and does not show it, so they
        // may still land.
        let (dictation, _) = voice(server.endpoint, route: route) { $0.writes = .held }
        await dictate(dictation)
        let entry = try #require(dictation.history.entries.first)
        #expect(entry.text == "Say yes.")
        #expect(entry.outcome == .uncertain)
        #expect(dictation.notice == .insertionUncertain)
    }

    @Test func aPendingDraftThatOutlastsTheWaitIsCancelledAndTheWordsTyped() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        route.onRead = .pending
        // A short wait for the scenario, in place of the 65 seconds.
        let (dictation, _) = voice(server.endpoint, route: route, limit: .milliseconds(120))
        await dictate(dictation)
        #expect(MockField.shared.text == "Say yes." + thread)
        #expect(dictation.notice == .typedTranscript(.timeout))
        // The cancel is sent without the words waiting on its answer.
        await until { route.cancelled == route.created.map(\.requestID) }
        #expect(route.accepted.isEmpty)
    }

    @Test func aPollTheServerCouldNotAnswerIsReadAgainAndTheEmailGoesIn() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        // As build 5 met it: the first polls answer 503 while the server
        // still writes, and then the draft is complete.
        route.firstReads = [.fail(.storageUnavailable), .fail(.server(503))]
        let (dictation, _) = voice(server.endpoint, route: route)
        var notices: [DictationController.Notice?] = []
        dictation.noticeChanged = { notices.append($0) }
        await dictate(dictation)
        // The email, not the words.
        #expect(MockField.shared.text == draft + thread)
        #expect(MockField.shared.accessibilityWrites == 1)
        #expect(dictation.notice == nil)
        #expect(notices.isEmpty)
        let id = try #require(route.created.first?.requestID)
        #expect(route.created.count == 1)
        #expect(route.read == [id, id, id])
        #expect(route.accepted == [id])
        #expect(route.cancelled.isEmpty)
        #expect(dictation.history.entries.map(\.text) == [draft])
    }

    @Test func pollsTheServerCannotAnswerUntilTheLimitTypeTheWordsWithTheNotice() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        route.onRead = .fail(.storageUnavailable)
        // A short wait for the scenario, in place of the 65 seconds.
        let (dictation, _) = voice(server.endpoint, route: route, limit: .milliseconds(200))
        var notices: [DictationController.Notice?] = []
        dictation.noticeChanged = { notices.append($0) }
        await dictate(dictation)
        #expect(MockField.shared.text == "Say yes." + thread)
        #expect(MockField.shared.accessibilityWrites == 1)
        #expect(dictation.notice == .typedTranscript(.timeout))
        #expect(notices == [.typedTranscript(.timeout)])
        // The one-second retry pause outlasts the 200 ms limit, so no
        // second poll or new request is sent before the draft is withdrawn.
        #expect(route.read.count == 1)
        #expect(route.created.count == 1)
        #expect(route.accepted.isEmpty)
        await until { route.cancelled == route.created.map(\.requestID) }
        #expect(dictation.history.entries.map(\.text) == ["Say yes."])
    }

    @Test func aFailedCreateTypesTheWordsWithoutWaitingOnItsCancel() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        route.onCreate = .fail(.unreachable)
        route.hold(.cancel)
        let (dictation, _) = voice(server.endpoint, route: route)
        dictation.toggle()
        try? await Task.sleep(for: .milliseconds(150))
        dictation.toggle()
        await route.whileHeld {
            // The cancel has not answered, and the words are in.
            await settle(dictation)
            #expect(MockField.shared.text == "Say yes." + thread)
            #expect(dictation.notice == .typedTranscript(nil))
        }
        #expect(route.cancelled == route.created.map(\.requestID))
        #expect(MockField.shared.accessibilityWrites == 1)
        #expect(dictation.history.entries.count == 1)
    }

    @Test(arguments: [ScriptedRoute.Call.create, .read, .accept])
    func aCallThatOutlastsTheWaitIsCancelledAndTheWordsTypedAtTheLimit(_ call: ScriptedRoute.Call) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        route.onCreate = .pending
        route.hold(call)
        let (dictation, _) = voice(server.endpoint, route: route, limit: .milliseconds(120))
        dictation.toggle()
        try? await Task.sleep(for: .milliseconds(150))
        dictation.toggle()
        await route.whileHeld {
            // Still unanswered: the words go in at the limit all the same.
            await settle(dictation)
            #expect(MockField.shared.text == "Say yes." + thread)
            #expect(dictation.notice == .typedTranscript(.timeout))
            await until { route.cancelled == route.created.map(\.requestID) }
        }
        // The held call has answered since, with a finished email that is
        // neither inserted nor, after a poll, accepted.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(MockField.shared.text == "Say yes." + thread)
        #expect(MockField.shared.accessibilityWrites == 1)
        #expect(route.created.count == 1)
        #expect(route.cancelled == route.created.map(\.requestID))
        if call != .accept { #expect(route.accepted.isEmpty) }
        #expect(dictation.history.entries.count == 1)
    }

    @Test func writingTheServerSaysIsOffTypesTheWordsWithoutAskingAgain() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes."), .answer(transcript: "and more", text: "And more.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        route.onCreate = .fail(.disabled)
        // A body longer than the inserter reads around the caret, so only
        // the body read spans it.
        let body = String(repeating: "a", count: 200)
        let (dictation, writer) = voice(server.endpoint, route: route) { $0.text = body }
        var phases: [DictationController.Phase] = []
        dictation.phaseChanged = { phases.append($0) }
        await dictate(dictation)
        #expect(MockField.shared.text == "Say yes." + body)
        #expect(dictation.notice == .typedTranscript(.productionDisabled))
        #expect(writer.availability == .unavailable(.disabled))
        #expect(MockField.shared.wholeTextReads == 1)
        // The second dictation is typed at once, with the notice again, and
        // the server is not asked; the body's text is not read either,
        // since nothing could be written from it.
        MockField.shared.text = body
        MockField.shared.selection = FieldRange(location: 0, length: 0)
        await dictate(dictation)
        #expect(phases == [.recording, .processing, .writingEmail, .processing, .idle, .recording, .processing, .idle])
        #expect(MockField.shared.text == "And more." + body)
        #expect(dictation.notice == .typedTranscript(.productionDisabled))
        #expect(route.created.count == 1)
        #expect(MockField.shared.wholeTextReads == 1)
    }

    @Test func theNoticeIsTakenAwayWhenTheNextDictationStarts() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes."), .silent])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        route.onCreate = .fail(.unreachable)
        let (dictation, _) = voice(server.endpoint, route: route)
        await dictate(dictation)
        #expect(dictation.notice == .typedTranscript(nil))
        dictation.toggle()
        #expect(dictation.notice == nil)
        dictation.cancel()
        await settle(dictation)
    }

    /// The preferences' flag for the first email, in memory, wired as the
    /// app wires it, and each `didInsert` call.
    @MainActor private final class FirstEmail {
        var written = false
        var inserted: [Bool] = []

        func wire(_ dictation: DictationController) {
            dictation.firstEmailWritten = { self.written }
            dictation.setFirstEmailWritten = { self.written = true }
            dictation.didInsert = { self.inserted.append($0) }
        }
    }

    @Test(.timeLimit(.minutes(1))) func theFirstEmailSaysWhereItCameFromOnceAndNeverAgain() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes."),
                                                 .answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        let (dictation, _) = voice(server.endpoint, route: route)
        let first = FirstEmail()
        first.wire(dictation)
        var notices: [DictationController.Notice?] = []
        let (cleared, clear) = AsyncStream<Void>.makeStream()
        let (finished, finish) = AsyncStream<Void>.makeStream()
        dictation.noticeChanged = {
            notices.append($0)
            if $0 == nil { clear.yield() }
        }
        dictation.doneSaying = { finish.yield() }
        // The notice and its queue each wait for the same duration. They
        // need separate continuations: one shared stream yield wakes only
        // one consumer and can leave the notice on screen in this test.
        let timer = NoticeTimer()
        defer {
            timer.end()
            clear.finish()
            finish.finish()
        }
        dictation.noticePause = { try? await timer.wait(DictationController.noticeDuration) }
        await dictate(dictation)
        #expect(MockField.shared.text == draft + thread)
        #expect(dictation.notice == .firstEmail)
        #expect(dictation.notice?.text == "Written from what you said. ⌘Z takes it back")
        #expect(first.written)
        #expect(first.inserted == [true])
        await timer.untilWaiting(count: 2)
        try Task.checkCancellation()
        timer.end()
        // Await each completion even if the queue finishes before the
        // notice clears. Both streams buffer an earlier callback.
        for await _ in cleared { break }
        for await _ in finished { break }
        #expect(notices == [.firstEmail, nil])
        #expect(!dictation.hasMoreToSay)
        // The second email goes in without a word.
        MockField.shared.selection = FieldRange(location: 0, length: 0)
        await dictate(dictation)
        #expect(MockField.shared.text == draft + draft + thread)
        #expect(dictation.notice == nil)
        #expect(notices == [.firstEmail, nil])
        #expect(first.inserted == [true, true])
        #expect(route.accepted.count == 2)
    }

    @Test func wordsTypedInPlaceOfAnEmailAreNotTheFirstEmail() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        route.onCreate = .fail(.unreachable)
        let (dictation, _) = voice(server.endpoint, route: route)
        let first = FirstEmail()
        first.wire(dictation)
        await dictate(dictation)
        #expect(MockField.shared.text == "Say yes." + thread)
        // The notice that says the words were typed, as before, and the
        // first email is still to come.
        #expect(dictation.notice == .typedTranscript(nil))
        #expect(!first.written)
        #expect(first.inserted == [false])
    }

    @Test func setupsOwnDictationIsNeverTheFirstEmailOrAnInsertion() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        let (dictation, _) = voice(server.endpoint, route: route)
        dictation.isForSetup = { true }
        let first = FirstEmail()
        first.wire(dictation)
        await dictate(dictation)
        #expect(MockField.shared.text == thread)
        #expect(dictation.history.entries.first?.forSetup == true)
        #expect(dictation.notice == nil)
        #expect(!first.written)
        #expect(first.inserted.isEmpty)
    }

    @Test func didInsertIsCalledOnceForEachDictationWhoseTextWentIn() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello there", text: "Hello there."),
                                                 .answer(transcript: "hello", text: "Hello."),
                                                 .refuse("internal"), .refuse("internal")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        // Typed words in a field that is not an email body.
        let (dictation, _) = voice(server.endpoint, route: route, mail: false) { $0.bundleIdentifier = "com.tinyspeck.slackmacgap" }
        let first = FirstEmail()
        first.wire(dictation)
        await dictate(dictation)
        #expect(MockField.shared.text == "aHello there.bc")
        #expect(first.inserted == [false])
        // No text box: the words are kept, not inserted.
        MockField.shared.focused = false
        await dictate(dictation)
        #expect(dictation.history.entries.first?.outcome == .notInserted)
        #expect(first.inserted == [false])
        // A dictation that failed has no text to insert.
        MockField.shared.focused = true
        await dictate(dictation)
        #expect(dictation.history.entries.first?.outcome == .failed)
        #expect(first.inserted == [false])
        #expect(!first.written)
    }

    /// The foot, saying words with the caret dot hidden, and wired by the call the app
    /// wires it with, through a dictation into Mail's body whose email is
    /// written, then one
    /// whose email cannot be, then the start of another: it says what the
    /// dot's caption says, in the same words, for as long. The words are
    /// written out here rather than taken from the code under test. The
    /// foot's window is never put on screen.
    @Test func theFootShowsTheEmailBeingWrittenAndTheNoticeAsTheDotDoes() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes."),
                                                 .answer(transcript: "say yes", text: "Say yes."), .silent])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        let (dictation, _) = voice(server.endpoint, route: route)
        let screen = FootMark.Screen(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                           usable: CGRect(x: 0, y: 80, width: 1440, height: 795))
        let foot = FootMark(desktop: .init(screens: { [screen] }, pointer: { CGPoint(x: 700, y: 400) }, showsWindow: false))
        foot.enabled = true
        foot.saysWords = true
        // Each state the foot takes, in order, and the words it showed,
        // read after each change the app's wiring hands on.
        var shown: [FootState] = []
        var words: [(state: FootState, frame: CGRect?)] = []
        let record = {
            if shown.last != foot.state { shown.append(foot.state) }
            words.append((foot.state, foot.slipFrame))
        }
        DictationIndicators.connect(dictation, foot: foot, phase: { _ in record() }, notice: { _ in record() }, silence: { foot.show($0) },
                                    nothing: { _ in })
        let writingEmail = FootState.working("Writing your email\u{2026}")
        let typed = FootState.notice("Couldn't write it, so I typed what you said")

        await dictate(dictation)
        #expect(MockField.shared.text == draft + thread)
        #expect(shown == [.listening, .writing, writingEmail, .resting])

        // The next email cannot be written: the foot finishes as for any
        // dictation while the words go in, then says why they are words.
        shown = []
        route.onCreate = .fail(.unreachable)
        MockField.shared.text = thread
        MockField.shared.selection = FieldRange(location: 0, length: 0)
        await dictate(dictation)
        #expect(MockField.shared.text == "Say yes." + thread)
        #expect(shown == [.listening, .writing, writingEmail, .writing, typed])
        #expect(foot.state == typed)

        // The next dictation takes the notice away, as it does beside the dot.
        shown = []
        dictation.toggle()
        #expect(dictation.notice == nil)
        #expect(foot.state == .listening)
        dictation.cancel()
        await settle(dictation)
        // Straight from the notice to listening: the dictation is recording
        // before the notice clears, so the foot never rests in between.
        #expect(shown == [.listening, .resting])

        // The notice opens from the dot whole, inside the window. The email
        // being written says nothing at the foot, as an ordinary
        // dictation's text on its way does not: the warm sun carries it.
        let frame = try #require(words.first { $0.state == typed }?.frame)
        #expect(frame.width > 0 && frame.minX >= 0 && frame.maxX <= FootMark.windowSize.width)
        #expect(frame.midY == FootMark.dotInWindow.y)
        #expect(words.first { $0.state == writingEmail }?.frame == nil)
        #expect(words.first { $0.state == .writing }?.frame == nil)
        #expect(!foot.panel.isVisible)
    }

    /// The dot, wired as the app wires it, through an email that cannot be
    /// written while the dot is placed and then while it is not, as right
    /// after a paste into Gmail in Chrome: the notice goes beside the dot
    /// when there is one and to the capsule at the foot of the screen when
    /// there is none, never both, so the person always learns their words
    /// went in instead of an email. The words are written out here.
    @Test func theDotSaysTheNoticeBesideItOrAtTheFootOfTheScreenWithoutIt() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes."),
                                                 .answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        route.onCreate = .fail(.unreachable)
        let (dictation, _) = voice(server.endpoint, route: route)
        let screen = FootMark.Screen(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                           usable: CGRect(x: 0, y: 80, width: 1440, height: 795))
        let foot = FootMark(desktop: .init(screens: { [screen] }, pointer: { CGPoint(x: 700, y: 400) }, showsWindow: false))
        var caretAnchor: CGRect? = CGRect(x: 400, y: 500, width: 24, height: 24)
        var captions: [String?] = []
        var panels: [FootState?] = []
        DictationIndicators.connect(dictation, foot: foot, phase: { _ in }, notice: { notice in
            DictationIndicators.sayOnDot(notice?.text, caretAnchor: caretAnchor,
                                         caption: { captions.append($0) }, panel: { notice, _ in panels.append(notice) })
        }, silence: { panels.append($0) }, nothing: { _ in })
        let words = "Couldn't write it, so I typed what you said"

        await dictate(dictation)
        #expect(MockField.shared.text == "Say yes." + thread)
        #expect(captions == [words])
        // A caption takes any earlier notice at the foot away.
        #expect(panels == [nil])

        // The dot found no caret when the notice came.
        captions = []
        panels = []
        caretAnchor = nil
        MockField.shared.text = thread
        MockField.shared.selection = FieldRange(location: 0, length: 0)
        dictation.toggle()
        #expect(captions == [nil])
        captions = []
        try? await Task.sleep(for: .milliseconds(150))
        dictation.toggle()
        await settle(dictation)
        #expect(MockField.shared.text == "Say yes." + thread)
        #expect(captions == [nil])
        #expect(panels == [.notice(words)])
    }

    @Test func aSlowEmailWriteSaysItIsStillWaiting() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        route.hold(.read)
        let (dictation, _) = voice(server.endpoint, route: route, limit: .seconds(60))
        let clock = SteppedClock()
        dictation.emailWaitClock = clock
        let key = HoldKey(handsFreeEnabled: true, key: .function, holdDelay: 0)
        key.onEscape = { dictation.escapePressed() }
        let foot = FootMark(desktop: .init(screens: { [] }, pointer: { .zero }, showsWindow: false))
        var announcements: [String] = []
        DictationIndicators.connect(dictation, foot: foot, phase: { key.recording = $0 == .recording }, notice: { _ in },
                                    silence: { _ in }, nothing: { _ in }, email: { key.pendingEmailWrite = $0.pending },
                                    announce: { announcements.append($0) })
        dictation.toggle()
        try? await Task.sleep(for: .milliseconds(150))
        dictation.toggle()
        await route.whileHeld {
            #expect(foot.state == .working("Writing your email…"))
            #expect(key.takesEscape)
            await until { clock.waits.contains(.seconds(15)) }
            clock.advance(to: .milliseconds(14_999))
            #expect(foot.state == .working("Writing your email…"))
            #expect(announcements.isEmpty)
            clock.advance(to: .seconds(15))
            await until { foot.state == .working("Still waiting. Esc cancels") }
            #expect(foot.state == .working("Still waiting. Esc cancels"))
            #expect(dictation.phase.caption(email: dictation.emailFeedback) == "Still waiting. Esc cancels")
            #expect(announcements == ["Still waiting. Esc cancels"])
            clock.advance(to: .seconds(30))
            // A new recording owns Escape first and hides the wait message.
            dictation.toggle()
            #expect(foot.state == .listening)
            #expect(dictation.phase.caption(email: dictation.emailFeedback) == nil)
            key.claimed(.escape)
            #expect(dictation.phase == .writingEmail)
            #expect(foot.state == .working("Still waiting. Esc cancels"))
            #expect(announcements == ["Still waiting. Esc cancels"])
            #expect(dictation.history.entries.isEmpty)
            key.claimed(.escape)
            #expect(!key.takesEscape)
        }
        await settle(dictation)
        #expect(MockField.shared.text == thread)
        #expect(dictation.history.entries.first?.text == "Say yes.")
        #expect(dictation.history.entries.count == 1)
        #expect(route.accepted.isEmpty)
        #expect(dictation.emailFeedback == .init())
        #expect(clock.waits.isEmpty)
        #expect(foot.state == .resting)
        #expect(announcements == ["Still waiting. Esc cancels"])
    }

    @Test func aQueuedEscapeForARecordingThatStopsCannotCancelTheOlderEmail() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes."),
                                                 .answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        route.hold(.read)
        let source = ScriptedSource()
        let (dictation, _) = voice(server.endpoint, route: route, source: source)
        let key = HoldKey(handsFreeEnabled: true, key: .function, holdDelay: 0)
        let foot = FootMark(desktop: .init(screens: { [] }, pointer: { .zero }, showsWindow: false))
        DictationIndicators.connect(dictation, foot: foot, phase: {
            key.recording = $0 == .recording
            key.onEscape = dictation.escapeCancellation()
        }, notice: { _ in }, silence: { _ in }, nothing: { _ in }, email: {
            key.pendingEmailWrite = $0.pending
            key.onEscape = dictation.escapeCancellation()
        })
        dictation.toggle()
        try? await Task.sleep(for: .milliseconds(150))
        dictation.toggle()
        await route.whileHeld {
            dictation.toggle()
            #expect(dictation.phase == .recording)
            // The main actor stays occupied until Done has stopped this
            // recording, before it can handle the queued Escape.
            DispatchQueue.global().sync { key.tapClaimed(.escape) }
            dictation.toggle()
            #expect(dictation.phase == .writingEmail)
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(30))
            #expect(dictation.emailFeedback.pending)
            #expect(route.cancelled.isEmpty)
            #expect(dictation.history.entries.isEmpty)
        }
        await settle(dictation)
        #expect(dictation.history.entries.count == 2)
        #expect(dictation.history.entries.allSatisfy { $0.outcome == .inserted })
        #expect(route.accepted.count == 2)
    }

    @Test(arguments: [false, true])
    func escapeDuringMicrophoneStartupCannotCancelTheOlderEmail(_ failsToOpen: Bool) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        route.hold(.read)
        let source = ScriptedSource()
        let (dictation, _) = voice(server.endpoint, route: route, source: source)
        let key = HoldKey(handsFreeEnabled: true, key: .function, holdDelay: 0)
        let foot = FootMark(desktop: .init(screens: { [] }, pointer: { .zero }, showsWindow: false))
        DictationIndicators.connect(dictation, foot: foot, phase: {
            key.onEscape = dictation.escapeCancellation()
            key.recording = $0 == .recording
        }, notice: { _ in }, silence: { _ in }, nothing: { _ in }, email: {
            key.onEscape = dictation.escapeCancellation()
            key.pendingEmailWrite = $0.pending
        })
        dictation.toggle()
        try? await Task.sleep(for: .milliseconds(150))
        dictation.toggle()
        await route.whileHeld {
            source.whileStarting = {
                // The tap captures Escape while audio startup occupies the
                // main actor, then delivers it after startup returns.
                DispatchQueue.global().sync { key.tapClaimed(.escape) }
                if failsToOpen { throw Microphone.Failure.unavailable }
            }
            dictation.toggle()
            try? await Task.sleep(for: .milliseconds(30))
            await until { dictation.phase == .writingEmail }
            #expect(!source.running)
            #expect(dictation.emailFeedback.pending)
            #expect(route.cancelled.isEmpty)
            #expect(dictation.history.entries.isEmpty)
            #expect(foot.state == .working("Writing your email…"))
        }
        await settle(dictation)
        #expect(dictation.history.entries.count == 1)
        #expect(dictation.history.entries.first?.outcome == .inserted)
        #expect(route.accepted.count == 1)
    }

    @Test(arguments: [false, true])
    func aWaitAnnouncementIsHeldUntilTheEmailShowsAgain(_ finishesDuringRecording: Bool) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        route.hold(.read)
        let (dictation, _) = voice(server.endpoint, route: route, limit: .seconds(60))
        let clock = SteppedClock()
        dictation.emailWaitClock = clock
        let foot = FootMark(desktop: .init(screens: { [] }, pointer: { .zero }, showsWindow: false))
        var announcements: [String] = []
        DictationIndicators.connect(dictation, foot: foot, phase: { _ in }, notice: { _ in }, silence: { _ in },
                                    nothing: { _ in }, announce: { announcements.append($0) })
        dictation.toggle()
        try? await Task.sleep(for: .milliseconds(150))
        dictation.toggle()
        await route.whileHeld {
            await until { clock.waits.contains(.seconds(15)) }
            dictation.toggle()
            clock.advance(to: .seconds(15))
            await until { dictation.emailFeedback.slow }
            #expect(dictation.phase == .recording)
            #expect(foot.state == .listening)
            #expect(announcements.isEmpty)
            if !finishesDuringRecording {
                dictation.escapePressed()
                #expect(foot.state == .working("Still waiting. Esc cancels"))
                #expect(announcements == ["Still waiting. Esc cancels"])
                dictation.escapePressed()
            }
        }
        if finishesDuringRecording {
            await until { !dictation.emailFeedback.pending }
            #expect(dictation.phase == .recording)
            #expect(announcements.isEmpty)
            dictation.escapePressed()
        }
        await settle(dictation)
        #expect(announcements == (finishesDuringRecording ? [] : ["Still waiting. Esc cancels"]))
    }

    @Test func anEmailWriteFinishingBeforeFifteenSecondsDoesNotAnnounceTheWait() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        route.hold(.read)
        let (dictation, _) = voice(server.endpoint, route: route)
        let clock = SteppedClock()
        dictation.emailWaitClock = clock
        let foot = FootMark(desktop: .init(screens: { [] }, pointer: { .zero }, showsWindow: false))
        var announcements: [String] = []
        DictationIndicators.connect(dictation, foot: foot, phase: { _ in }, notice: { _ in }, silence: { _ in },
                                    nothing: { _ in }, announce: { announcements.append($0) })
        dictation.toggle()
        try? await Task.sleep(for: .milliseconds(150))
        dictation.toggle()
        await route.whileHeld {
            await until { clock.waits.contains(.seconds(15)) }
            clock.advance(to: .milliseconds(14_999))
            #expect(announcements.isEmpty)
        }
        await settle(dictation)
        #expect(MockField.shared.text == draft + thread)
        #expect(clock.waits.isEmpty)
        clock.advance(to: .seconds(15))
        await Task.yield()
        #expect(dictation.emailFeedback == .init())
        #expect(announcements.isEmpty)
    }

    @Test func escapePassesOnceTheEmailStartsGoingInAndItsWaitTimerCannotReturn() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        let (dictation, _) = voice(server.endpoint, route: route)
        let clock = SteppedClock()
        dictation.emailWaitClock = clock
        let gate = InsertionGate()
        dictation.phaseChanged = { if $0 == .writingEmail { gate.arm() } }
        dictation.toggle()
        try? await Task.sleep(for: .milliseconds(150))
        dictation.toggle()
        await gate.whileHeld {
            #expect(!dictation.emailFeedback.pending)
            dictation.escapePressed()
            clock.advance(to: .seconds(15))
            #expect(dictation.emailFeedback == .init())
        }
        await settle(dictation)
        #expect(MockField.shared.text == draft + thread)
        #expect(MockField.shared.accessibilityWrites == 1)
        #expect(dictation.history.entries.count == 1)
        #expect(dictation.history.entries.first?.outcome == .inserted)
        #expect(route.cancelled.isEmpty)
        #expect(clock.waits.isEmpty)
    }

    @Test(arguments: ["cancel", "escape"])
    func cancellingWhileTheEmailIsWrittenInsertsNothingAndKeepsTheWords(_ way: String) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        route.onRead = .pending
        let (dictation, _) = voice(server.endpoint, route: route)
        dictation.toggle()
        try? await Task.sleep(for: .milliseconds(150))
        dictation.toggle()
        await until { dictation.phase == .writingEmail }
        await until { !route.created.isEmpty }
        if way == "escape" { dictation.escapePressed() } else { dictation.cancel() }
        #expect(dictation.phase == .idle)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(MockField.shared.text == thread)
        #expect(MockField.shared.accessibilityWrites == 0)
        #expect(MockField.shared.keys.isEmpty)
        #expect(route.cancelled == route.created.map(\.requestID))
        #expect(route.accepted.isEmpty)
        let entry = try #require(dictation.history.entries.first)
        #expect(entry.text == "Say yes.")
        #expect(entry.outcome == .notInserted)
        #expect(entry.reason == "cancelled")
        #expect(dictation.history.needsAttention)
        #expect(dictation.notice == nil)
    }

    @Test func signingOutWhileTheEmailIsWrittenTypesTheWordsAndSaysSo() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        route.onRead = .pending
        let (dictation, writer) = voice(server.endpoint, route: route)
        var notices: [DictationController.Notice?] = []
        dictation.noticeChanged = { notices.append($0) }
        dictation.toggle()
        try? await Task.sleep(for: .milliseconds(150))
        dictation.toggle()
        await until { dictation.phase == .writingEmail }
        await until { !route.created.isEmpty }
        dictation.accountChanged(signedIn: false)
        #expect(writer.availability == .signedOut)
        #expect(dictation.problem == .signedOut)
        await settle(dictation)
        // The email cannot come for this account and its request is
        // withdrawn; the words, this Mac's own, go in once, with the notice.
        #expect(MockField.shared.text == "Say yes." + thread)
        #expect(MockField.shared.accessibilityWrites == 1)
        #expect(notices == [.typedTranscript(nil)])
        await until { route.cancelled == route.created.map(\.requestID) }
        #expect(route.accepted.isEmpty)
        let entry = try #require(dictation.history.entries.first)
        #expect(entry.text == "Say yes.")
        #expect(entry.outcome == .inserted)
        #expect(entry.reason == nil)
        #expect(!dictation.history.needsAttention)
        #expect(dictation.history.entries.count == 1)
    }

    /// A dictation started while an email is written records at once; once
    /// it stops, the indicators say the email is still being written, and
    /// its words wait for the email to go in, then become an email of their
    /// own in the same body, after it.
    @Test func aDictationStartedWhileAnEmailIsWrittenShowsRecordingThenTheEmailsCaption() async throws {
        let server = try await ScriptedEndpoint([
            .answer(transcript: "say yes", text: "Say yes."), .answer(transcript: "and more", text: "And more."),
        ])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        route.hold(.read)
        let (dictation, _) = voice(server.endpoint, route: route)
        var phases: [DictationController.Phase] = []
        dictation.phaseChanged = { phases.append($0) }
        dictation.toggle()
        try? await Task.sleep(for: .milliseconds(150))
        dictation.toggle()
        await route.whileHeld {
            #expect(dictation.phase == .writingEmail)
            dictation.toggle()
            #expect(dictation.phase == .recording)
            try? await Task.sleep(for: .milliseconds(150))
            dictation.toggle()
            #expect(dictation.phase == .writingEmail)
            await until { server.connections.count == 2 && server.connections[1].answered }
            try? await Task.sleep(for: .milliseconds(100))
            // The second's words are back and wait for the first's email.
            #expect(MockField.shared.text == thread)
            #expect(route.created.count == 1)
        }
        await settle(dictation)
        #expect(phases == [.recording, .processing, .writingEmail, .recording, .writingEmail, .processing, .writingEmail, .idle])
        #expect(route.created.map(\.cue) == ["Say yes.", "And more."])
        #expect(MockField.shared.text == draft + draft + thread)
        #expect(dictation.history.entries.map(\.spoken) == ["And more.", "Say yes."])
    }

    /// A dictation into an email body that waited for one that failed
    /// keeps the field noted at its own start. The app reused that body's
    /// element for another compose meanwhile, with other labels and text:
    /// the email is not put into it.
    @Test func aWaitingDictationKeepsItsOwnFieldWhenTheBodyIsReusedForAnotherCompose() async throws {
        let server = try await ScriptedEndpoint([
            .refuseLate(after: 0.8, reason: "too_long"), .answer(transcript: "say yes", text: "Say yes."),
        ])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        let (dictation, _) = voice(server.endpoint, route: route)
        dictation.toggle()
        try? await Task.sleep(for: .milliseconds(150))
        dictation.toggle()
        dictation.toggle()
        try? await Task.sleep(for: .milliseconds(150))
        dictation.toggle()
        await until { server.connections.count == 2 && server.connections[1].answered }
        // Another message opens in the same element.
        let other = "\n\nOn Tuesday, Sam wrote:\n> Lunch?"
        MockField.shared.label = "Message to Sam"
        MockField.shared.text = other
        await settle(dictation)
        #expect(MockField.shared.text == other)
        let entries = dictation.history.entries
        #expect(entries.map(\.outcome) == [.notInserted, .failed])
        #expect(entries.first?.reason == "focusChanged")
        #expect(entries.first?.spoken == "Say yes.")
    }

    /// A dictation into an email body that waited for one that failed
    /// keeps the note of its own start as it is, since nothing of the
    /// earlier one went into that body: the email goes in when the body
    /// still reads as noted, and is refused, as for a dictation alone,
    /// when the text before the caret changed some other way meanwhile.
    @Test(arguments: ["unchanged", "typedBeforeTheCaret"])
    func aWaitingDictationAfterOneThatFailedKeepsItsNoteAsItWas(_ body: String) async throws {
        let server = try await ScriptedEndpoint([
            .refuseLate(after: 0.8, reason: "too_long"), .answer(transcript: "say yes", text: "Say yes."),
        ])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        let (dictation, _) = voice(server.endpoint, route: route)
        dictation.toggle()
        try? await Task.sleep(for: .milliseconds(150))
        dictation.toggle()
        dictation.toggle()
        try? await Task.sleep(for: .milliseconds(150))
        dictation.toggle()
        await until { server.connections.count == 2 && server.connections[1].answered }
        if body == "typedBeforeTheCaret" {
            MockField.shared.text = "Hi " + thread
            MockField.shared.selection = FieldRange(location: 3, length: 0)
        }
        await settle(dictation)
        let entries = dictation.history.entries
        #expect(entries.map(\.outcome) == [body == "unchanged" ? .inserted : .notInserted, .failed])
        #expect(entries.first?.spoken == "Say yes.")
        if body == "unchanged" {
            #expect(MockField.shared.text == draft + thread)
        } else {
            #expect(MockField.shared.text == "Hi " + thread)
            #expect(entries.first?.reason == "focusChanged")
        }
    }

    /// A sign-out with one dictation recording and one whose email is being
    /// written: the recording is dropped, and the email's words are typed
    /// with the notice, as each would be alone.
    @Test func signingOutWhileOneRecordsAndAnEmailIsWrittenDropsOneAndTypesTheOther() async throws {
        let server = try await ScriptedEndpoint([
            .answer(transcript: "say yes", text: "Say yes."), .answer(transcript: "and more", text: "And more."),
        ])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        route.onRead = .pending
        let (dictation, _) = voice(server.endpoint, route: route)
        var notices: [DictationController.Notice?] = []
        dictation.noticeChanged = { notices.append($0) }
        dictation.toggle()
        try? await Task.sleep(for: .milliseconds(150))
        dictation.toggle()
        await until { dictation.phase == .writingEmail && !route.created.isEmpty }
        dictation.toggle()
        #expect(dictation.phase == .recording)
        try? await Task.sleep(for: .milliseconds(150))
        dictation.accountChanged(signedIn: false)
        #expect(dictation.phase == .processing)
        await settle(dictation)
        #expect(MockField.shared.text == "Say yes." + thread)
        #expect(notices == [.typedTranscript(nil)])
        await until { route.cancelled == route.created.map(\.requestID) }
        #expect(route.created.count == 1)
        #expect(dictation.history.entries.map(\.text) == ["Say yes."])
        #expect(server.connections.dropFirst().allSatisfy { $0.stopFrames == nil })
    }

    @Test func theServerRefusingThisMacsKeyTypesTheWordsAndSaysSo() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        let (dictation, writer) = voice(server.endpoint, route: route)
        // A 401 from the draft route, wired as the app wires it: the
        // adapter throws the refusal, and the writer's report of it signs
        // the Mac out, which reaches dictation.
        route.onCreate = .fail(.unauthorized)
        route.keyRefused = { dictation.accountChanged(signedIn: false) }
        var notices: [DictationController.Notice?] = []
        dictation.noticeChanged = { notices.append($0) }
        await dictate(dictation)
        #expect(MockField.shared.text == "Say yes." + thread)
        #expect(MockField.shared.accessibilityWrites == 1)
        #expect(notices == [.typedTranscript(nil)])
        #expect(writer.availability == .signedOut)
        #expect(dictation.problem == .signedOut)
        await until { route.cancelled == route.created.map(\.requestID) }
        let entry = try #require(dictation.history.entries.first)
        #expect(entry.text == "Say yes.")
        #expect(entry.outcome == .inserted)
        #expect(entry.reason == nil)
        #expect(dictation.history.entries.count == 1)
    }

    @Test func signingOutWhileTheEmailGoesInLeavesTheEmailAndOneEntry() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        let (dictation, writer) = voice(server.endpoint, route: route)
        var notices: [DictationController.Notice?] = []
        dictation.noticeChanged = { notices.append($0) }
        // The email is written and accepted, and the Mac signs out while
        // the inserter is putting it in.
        let gate = InsertionGate()
        dictation.phaseChanged = { if $0 == .writingEmail { gate.arm() } }
        dictation.toggle()
        try? await Task.sleep(for: .milliseconds(150))
        dictation.toggle()
        await gate.signOutWhileHeld(dictation)
        await settle(dictation)
        // Anything still going in has finished before the field and
        // history are read.
        try? await Task.sleep(for: .milliseconds(200))
        // The email went in once, and the words are not typed after it.
        #expect(MockField.shared.text == draft + thread)
        #expect(MockField.shared.accessibilityWrites == 1)
        #expect(notices.isEmpty)
        #expect(route.accepted == route.created.map(\.requestID))
        #expect(route.cancelled.isEmpty)
        #expect(writer.availability == .signedOut)
        #expect(dictation.problem == .signedOut)
        // One entry, and it says what happened: the email went in.
        #expect(dictation.history.entries.count == 1)
        let entry = try #require(dictation.history.entries.first)
        #expect(entry.text == draft)
        #expect(entry.spoken == "Say yes.")
        #expect(entry.outcome == .inserted)
        #expect(entry.reason == nil)
        #expect(!dictation.history.needsAttention)
    }

    @Test func signingOutWhileTheWordsGoInInsteadOfAnEmailLeavesOneEntry() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        route.onCreate = .fail(.unreachable)
        let (dictation, _) = voice(server.endpoint, route: route)
        var notices: [DictationController.Notice?] = []
        dictation.noticeChanged = { notices.append($0) }
        // No email comes, and the Mac signs out while the words are going
        // in in its place.
        let gate = InsertionGate()
        dictation.phaseChanged = { if $0 == .writingEmail { gate.arm() } }
        dictation.toggle()
        try? await Task.sleep(for: .milliseconds(150))
        dictation.toggle()
        await gate.signOutWhileHeld(dictation)
        await settle(dictation)
        // Anything still going in has finished before the field and
        // history are read.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(MockField.shared.text == "Say yes." + thread)
        #expect(MockField.shared.accessibilityWrites == 1)
        #expect(notices == [.typedTranscript(nil)])
        #expect(dictation.problem == .signedOut)
        #expect(dictation.history.entries.count == 1)
        let entry = try #require(dictation.history.entries.first)
        #expect(entry.text == "Say yes.")
        #expect(entry.outcome == .inserted)
        #expect(entry.reason == nil)
        #expect(!dictation.history.needsAttention)
    }

    @Test func signingInAgainWhileTheWordsGoInAfterASignOutTypesThemOnce() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        route.onRead = .pending
        let (dictation, writer) = voice(server.endpoint, route: route)
        let first = FirstEmail()
        first.wire(dictation)
        var notices: [DictationController.Notice?] = []
        dictation.noticeChanged = { notices.append($0) }
        dictation.toggle()
        try? await Task.sleep(for: .milliseconds(150))
        dictation.toggle()
        await until { dictation.phase == .writingEmail }
        await until { !route.created.isEmpty }
        // Signed out before anything goes in: the words are typed, with
        // the notice. The Mac signs in again while they are going in.
        let gate = InsertionGate()
        gate.arm()
        dictation.accountChanged(signedIn: false)
        await gate.whileHeld { dictation.accountChanged(signedIn: true) }
        await settle(dictation)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(MockField.shared.text == "Say yes." + thread)
        #expect(MockField.shared.accessibilityWrites == 1)
        #expect(notices == [.typedTranscript(nil)])
        await until { route.cancelled == route.created.map(\.requestID) }
        #expect(route.accepted.isEmpty)
        #expect(writer.availability == nil)
        #expect(dictation.problem == nil)
        #expect(first.inserted.isEmpty)
        #expect(dictation.history.entries.count == 1)
        let entry = try #require(dictation.history.entries.first)
        #expect(entry.text == "Say yes.")
        #expect(entry.outcome == .inserted)
        #expect(entry.reason == nil)
        #expect(!dictation.history.needsAttention)
    }

    @Test func theSelectionChangingWhileTheEmailIsWrittenInsertsNothing() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        // The person selects the quoted line while the server writes.
        route.beforeRead = { MockField.shared.selection = FieldRange(location: 2, length: 6) }
        let (dictation, _) = voice(server.endpoint, route: route)
        await dictate(dictation)
        #expect(MockField.shared.text == thread)
        #expect(MockField.shared.accessibilityWrites == 0)
        #expect(MockField.shared.keys.isEmpty)
        // The email was written and accepted, and is kept to copy with the
        // words it was written from; the words are not typed over the
        // selection either.
        #expect(route.accepted.count == 1)
        let entry = try #require(dictation.history.entries.first)
        #expect(entry.text == draft)
        #expect(entry.spoken == "Say yes.")
        #expect(entry.outcome == .notInserted)
        #expect(entry.reason == "fieldChanged")
        #expect(dictation.history.needsAttention)
        #expect(dictation.notice == nil)
    }

    @Test func theQuotedThreadChangingWhileTheEmailIsWrittenInsertsNothing() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        // A thread long enough that its end lies past the text read around
        // the caret.
        let long = thread + String(repeating: " Could you make Thursday at 10?", count: 20) + "\n\nJane"
        let edited = String(long.dropLast(4)) + "June"
        // The person edits the far end of the quoted thread while the
        // server writes, without changing its length.
        route.beforeRead = { MockField.shared.text = edited }
        let (dictation, _) = voice(server.endpoint, route: route) { $0.text = long }
        await dictate(dictation)
        #expect(MockField.shared.text == edited)
        #expect(MockField.shared.accessibilityWrites == 0)
        #expect(MockField.shared.keys.isEmpty)
        // The email, written from the thread as it was, is kept with the
        // words; it does not go into the changed message.
        let entry = try #require(dictation.history.entries.first)
        #expect(entry.text == draft)
        #expect(entry.spoken == "Say yes.")
        #expect(entry.outcome == .notInserted)
        #expect(entry.reason == "fieldChanged")
        #expect(dictation.history.entries.count == 1)
        #expect(dictation.notice == nil)
    }

    @Test func aSelectionGrowingForwardFromTheCaretWhileTheEmailIsWrittenInsertsNothing() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        // One character over and over, the caret in the middle, and a
        // selection made forward from it while the server writes: the text
        // before the caret reads the same, so only the body read's guard,
        // which holds the selection, can tell.
        let run = String(repeating: "a", count: 300)
        route.beforeRead = { MockField.shared.selection = FieldRange(location: 150, length: 40) }
        let (dictation, _) = voice(server.endpoint, route: route) {
            $0.text = run
            $0.selection = FieldRange(location: 150, length: 0)
        }
        await dictate(dictation)
        #expect(MockField.shared.text == run)
        #expect(MockField.shared.accessibilityWrites == 0)
        #expect(MockField.shared.keys.isEmpty)
        #expect(dictation.history.entries.first?.reason == "fieldChanged")
    }

    @Test func focusLeavingTheBodyWhileTheEmailIsWrittenInsertsNothing() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        route.beforeRead = { MockField.shared.focusedElement = 2 }
        let (dictation, _) = voice(server.endpoint, route: route)
        await dictate(dictation)
        #expect(MockField.shared.text == thread)
        #expect(MockField.shared.accessibilityWrites == 0)
        let entry = try #require(dictation.history.entries.first)
        #expect(entry.text == draft)
        #expect(entry.outcome == .notInserted)
        #expect(entry.reason == "focusChanged")
    }

    @Test func aBodyThatTurnsSecureBeforeTheWriteGetsNothing() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        route.beforeRead = { MockField.shared.secure = true }
        let (dictation, _) = voice(server.endpoint, route: route)
        await dictate(dictation)
        #expect(MockField.shared.text == thread)
        #expect(MockField.shared.accessibilityWrites == 0)
        #expect(MockField.shared.textReadsWhileSecure == 0)
        #expect(dictation.history.entries.first?.reason == "secureField")
    }

    @Test func focusMovingBeforeTheWordsComeBackTypesTheWordsWhereTheCursorIs() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        let (dictation, _) = voice(server.endpoint, route: route)
        dictation.toggle()
        try? await Task.sleep(for: .milliseconds(150))
        // Into another field before stopping: the body read names another
        // element than the words were for, so no email is asked for, and
        // the words go into the field the cursor is in now.
        MockField.shared.focusedElement = 2
        dictation.toggle()
        await settle(dictation)
        #expect(route.created.isEmpty)
        #expect(MockField.shared.accessibilityWrites == 1)
        #expect(dictation.history.entries.first?.outcome == .inserted)
    }

    @Test func silenceInAnEmailBodyAsksForNothing() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "", text: "")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        let (dictation, _) = voice(server.endpoint, route: route)
        var said: [DictationController.Silence] = []
        dictation.silent = { said.append($0.silence) }
        var notices: [DictationController.Notice?] = []
        dictation.noticeChanged = { notices.append($0) }
        await dictate(dictation)
        #expect(route.created.isEmpty)
        #expect(MockField.shared.text == thread)
        #expect(dictation.history.entries.isEmpty)
        // Silence's own notice, not the typed-words one: nothing was typed.
        #expect(said == [.words])
        #expect(notices.allSatisfy { $0 == nil })
        #expect(dictation.notice == nil)
    }

    /// A microphone that sent no sound ends the dictation at the stop, so
    /// an email body is never asked about, read or written into, and the
    /// indicator says Intention heard nothing rather than that it typed words.
    @Test func aSilentMicrophoneInAnEmailBodyReadsNothingAndSaysSo() async throws {
        let server = try await ScriptedEndpoint([.silent])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        let (dictation, _) = voice(server.endpoint, route: route, source: ScriptedSource(level: 0))
        var said: [DictationController.Silence] = []
        dictation.silent = { said.append($0.silence) }
        var phases: [DictationController.Phase] = []
        dictation.phaseChanged = { phases.append($0) }
        var notices: [DictationController.Notice?] = []
        dictation.noticeChanged = { notices.append($0) }
        await dictate(dictation)
        #expect(said == [.microphone])
        #expect(phases == [.recording, .processing, .idle])
        #expect(route.created.isEmpty)
        #expect(MockField.shared.text == thread)
        #expect(MockField.shared.readsBeyondField == 0)
        #expect(dictation.history.entries.isEmpty)
        #expect(notices.allSatisfy { $0 == nil })
        #expect(server.connections.allSatisfy { $0.stopFrames == nil })
    }

    /// The one change to the field after the words came back that is not
    /// refused: a selection grown forward from the caret before the body
    /// read reaches the selection. The read sees it, and the field as read
    /// is where the email goes, under plain dictation's rule that only the
    /// text before the caret must read as it did at the start. Pinned so a
    /// change to that rule shows here.
    @Test func aSelectionGrownForwardBeforeTheBodyReadReachesItIsWrittenOver() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        let (dictation, _) = voice(server.endpoint, route: route)
        // The body read's read of which element has focus is the first after
        // the words; the selection grows as it is answered.
        dictation.phaseChanged = { phase in
            guard phase == .processing else { return }
            MockField.shared.onFocusRead = { @Sendable in
                MockField.shared.selection = FieldRange(location: 0, length: 6)
                MockField.shared.onFocusRead = nil
            }
        }
        await dictate(dictation)
        #expect(MockField.shared.text == draft + String(thread.dropFirst(6)))
        #expect(MockField.shared.accessibilityWrites == 1)
        #expect(route.created.first?.compose.observedThread == thread)
        let entry = try #require(dictation.history.entries.first)
        #expect(dictation.history.entries.count == 1)
        #expect(entry.text == draft)
        #expect(entry.outcome == .inserted)
    }

    // MARK: - The matrix at the top of this file

    /// One pairing of the matrix: speaks into Mail's body, holds voice
    /// compose at `cell.wait`, makes `cell.event` happen there, lets it go
    /// on, and checks the field, the insertions, the notice, history and
    /// the requests against what the cell says.
    @Test(arguments: ComposeMatrix.cells)
    func voiceComposeMatrix(_ cell: ComposeMatrix.Cell) async throws {
        let next = cell.event == .nextDictation
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: ComposeMatrix.words)]
                                                + (next ? [.answer(transcript: "and more", text: ComposeMatrix.nextWords)] : []))
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        let plainField = cell.wait == .plainFieldRead || cell.wait == .plainInsertion
        // When the writer's limit is the event, the writer runs on a clock
        // the scenario steps: the limit passes only once its call is held,
        // and is seen before that call answers, however slowly the runner
        // gets there.
        let timesOut = cell.event == .writerTimesOut
        let clock = SteppedClock()
        let (dictation, _) = voice(server.endpoint, route: route, mail: !plainField,
                                   limit: timesOut ? .milliseconds(100) : .seconds(5),
                                   poll: cell.wait == .pollWait ? .milliseconds(400) : .milliseconds(20),
                                   clock: timesOut ? clock : ContinuousWriterClock())
        var notices: [DictationController.Notice?] = []
        dictation.noticeChanged = { notices.append($0) }
        // The popup that says text could not go in, which the app opens
        // from `notInserted`.
        var refusals: [EditReason] = []
        dictation.notInserted = { reason, _ in refusals.append(reason) }
        // Made after `voice`, which resets the scripted field it hooks.
        let gate = InsertionGate()
        // Every phase the dictations pass through, and the cell's hold armed
        // at the first time one of them reaches `armAt`.
        var phases: [DictationController.Phase] = []
        var armAt: DictationController.Phase?
        var arming: () -> Void = {}
        dictation.phaseChanged = {
            phases.append($0)
            guard $0 == armAt else { return }
            armAt = nil
            arming()
        }
        let arm = { (phase: DictationController.Phase, hold: @escaping () -> Void) in
            armAt = phase
            arming = hold
        }
        switch cell.wait {
        case .bodyRead, .plainFieldRead: arm(.processing, gate.arm)
        // The body read's own read of the focused element passes; the
        // insertion's is held.
        case .plainInsertion: arm(.processing) { gate.armAtFocusRead(passing: 1) }
        case .emailInsertion, .wordsInsertion: arm(.writingEmail, gate.arm)
        case .creation: route.hold(.create)
        case .poll: route.hold(.read)
        case .acceptance: route.hold(.accept)
        case .pollWait, .wordsAfterAccountChange: route.onRead = .pending
        }
        if cell.wait == .wordsInsertion { route.onCreate = .fail(.unreachable) }
        var phaseAfterEvent: DictationController.Phase?
        let event = { @MainActor () async in
            happen(cell.event, dictation, route)
            if timesOut {
                // The limit passes while the call is held. The writer gives
                // up and the words are on their way before the held call
                // answers.
                clock.advance(to: .milliseconds(100))
                await until { dictation.phase != .writingEmail }
            }
            phaseAfterEvent = dictation.phase
        }

        dictation.toggle()
        try? await Task.sleep(for: .milliseconds(150))
        dictation.toggle()
        switch cell.wait {
        case .bodyRead, .plainFieldRead, .plainInsertion, .emailInsertion, .wordsInsertion:
            // The next dictation's own field read waits behind the held
            // work, and must still answer within `targetDeadline`.
            await gate.whileHeld(pause: next ? .milliseconds(30) : .milliseconds(150)) { await event() }
        case .creation, .poll, .acceptance:
            if timesOut, cell.wait == .poll {
                // Created, and asleep until the first poll.
                await until { clock.waits == [.milliseconds(20)] }
                clock.advance(to: .milliseconds(20))
            }
            await route.whileHeld { await event() }
        case .pollWait:
            // The first poll has answered pending, and the writer waits
            // before the second.
            await until { route.read.count == 1 }
            try? await Task.sleep(for: .milliseconds(50))
            await event()
            route.onRead = .complete
        case .wordsAfterAccountChange:
            await until { dictation.phase == .writingEmail && !route.created.isEmpty }
            // The sign-out decides to type the words; the event lands in
            // the same turn, before that typing starts.
            dictation.accountChanged(signedIn: false)
            await event()
        }
        if next {
            route.onCreate = .pending
            try? await Task.sleep(for: .milliseconds(150))
            dictation.toggle()
        }
        await settle(dictation)
        // Anything still going in, and any withdrawal on its way, has
        // finished before the field, history and the route are read.
        try? await Task.sleep(for: .milliseconds(200))

        let field = MockField.shared
        // Mail's body holds the thread with the caret at its start; the
        // other Mail field holds "abc" with the caret after "a".
        let (base, caret) = plainField ? ("abc", 1) : (thread, 0)
        let changed = cell.event == .textTyped ? (base as NSString).replacingCharacters(in: NSRange(location: caret, length: 0), with: "X") : base
        let spoken = ComposeMatrix.words
        let expected: (text: String, insertions: Int, entries: [ComposeMatrix.Kept])
        switch cell.ending {
        case .wordsTyped:
            expected = (spoken + base, 1, [.init(spoken, nil, .inserted, nil)])
        case .wordsTypedPlainly:
            expected = ("a" + spoken + "bc", 1, [.init(spoken, nil, .inserted, nil)])
        case .wordsTypedPlainlyOverSelection:
            expected = ("a" + spoken, 1, [.init(spoken, nil, .inserted, nil)])
        case let .wordsTypedAt(before, after):
            expected = (before + spoken + after, 1, [.init(spoken, nil, .inserted, nil)])
        case .emailInserted:
            expected = (draft + base, 1, [.init(draft, spoken, .inserted, nil)])
        case .cancelled:
            expected = (base, 0, [.init(spoken, nil, .notInserted, "cancelled")])
        case let .emailRefused(reason):
            expected = (changed, 0, [.init(draft, spoken, .notInserted, reason)])
        case let .wordsRefused(reason):
            expected = (changed, 0, [.init(spoken, nil, .notInserted, reason)])
        case .cancelledThenNextEmail:
            expected = (draft + base, 1, [.init(spoken, nil, .notInserted, "cancelled"), .init(draft, ComposeMatrix.nextWords, .inserted, nil)])
        case .cancelledThenNextWordsPlainly:
            expected = ("a" + ComposeMatrix.nextWords + "bc", 1,
                        [.init(spoken, nil, .notInserted, "cancelled"), .init(ComposeMatrix.nextWords, nil, .inserted, nil)])
        }
        #expect(field.text == expected.text)
        #expect(field.accessibilityWrites == expected.insertions)
        #expect(field.keys.isEmpty)
        #expect(field.editsWhileSecure == 0)
        #expect(field.textReadsWhileSecure == 0)
        // The notices shown. Each is taken away by a timer of its own after
        // `noticeDuration`, which a slow runner can reach before this
        // check, so the nil that marks that is not counted.
        let noticeReason: DraftReason? = switch cell.event {
        case .writerAbstains: .contextPreparing
        case .writerTakesBack: .superseded
        case .writerTimesOut: .timeout
        default: nil
        }
        #expect(notices.compactMap(\.self) == (cell.ending == .wordsTyped ? [.typedTranscript(noticeReason)] : []))
        // The popup opens only for text the field refused, once, and never
        // in a dictation whose words were typed with the notice: the notice
        // says the words went in, the popup that they did not.
        let refused = switch cell.ending {
        case .wordsRefused, .emailRefused: true
        default: false
        }
        #expect(refusals.count == (refused ? 1 : 0))
        #expect(refusals.isEmpty || notices.compactMap(\.self).isEmpty)
        // One entry per dictation, oldest first, each saying what happened.
        #expect(dictation.history.entries.reversed().map(ComposeMatrix.Kept.init) == expected.entries)
        if cell.ending == .cancelled { #expect(phaseAfterEvent == .idle) }
        // What the indicators said at the end: the email's caption only
        // while an email was written and went in or was refused, and the
        // ordinary finishing state while the words went in in its place,
        // whether the writer failed, the account changed or the email
        // never was asked for.
        switch cell.ending {
        case .wordsTyped, .wordsRefused:
            #expect(Array(phases.suffix(2)) == [.processing, .idle])
            if cell.requests > 0 { #expect(Array(phases.suffix(3)) == [.writingEmail, .processing, .idle]) }
        case .emailInserted, .emailRefused, .cancelledThenNextEmail:
            #expect(Array(phases.suffix(2)) == [.writingEmail, .idle])
        case .wordsTypedPlainly, .wordsTypedPlainlyOverSelection, .wordsTypedAt, .cancelledThenNextWordsPlainly:
            #expect(!phases.contains(.writingEmail))
        case .cancelled:
            #expect(phases.last == .idle)
        }
        #expect(route.created.count == cell.requests)
        #expect(route.accepted.count == cell.acceptances)
        if cell.withdrawn > 0 { await until { Set(route.cancelled).count == cell.withdrawn } }
        #expect(Set(route.cancelled).count == cell.withdrawn)
        #expect(Set(route.cancelled).isSubset(of: route.created.map(\.requestID)))
    }

    /// Makes `event` happen while voice compose waits.
    private func happen(_ event: ComposeMatrix.Event, _ dictation: DictationController, _ route: ScriptedRoute) {
        let field = MockField.shared
        switch event {
        case .signOut:
            dictation.accountChanged(signedIn: false)
        case .refusedKey:
            // As the app wires it: the adapter throws the refusal, and the
            // writer's report of it signs the Mac out, which reaches
            // dictation.
            route.keyRefused = { dictation.accountChanged(signedIn: false) }
            route.failHeldCall(.unauthorized)
        case .keyReplaced:
            dictation.accountChanged(signedIn: true)
        case .signOutAndIn:
            dictation.accountChanged(signedIn: false)
            dictation.accountChanged(signedIn: true)
        case .cancel:
            dictation.cancel()
        case .focusMoves:
            field.focusedElement = 2
        case .caretMoves:
            field.selection = FieldRange(location: field.selection.location + 2, length: 0)
        case .selectionGrows:
            let room = (field.text as NSString).length - field.selection.location
            field.selection = FieldRange(location: field.selection.location, length: min(6, room))
        case .textTyped:
            let caret = field.selection.location
            field.text = (field.text as NSString).replacingCharacters(in: NSRange(location: caret, length: 0), with: "X")
            field.selection = FieldRange(location: caret + 1, length: 0)
        case .turnsSecure:
            field.secure = true
        case .writerFails:
            // A failure no call sends again; a poll the server could not
            // answer once is read again (`aPollTheServerCouldNotAnswerIsReadAgainAndTheEmailGoesIn`).
            route.failHeldCall(.invalidResponse)
        case .writerAbstains:
            route.onRead = .abstain(.contextPreparing)
        case .writerTakesBack:
            route.onAccept = .takeBack
        case .writerTimesOut:
            // The matrix steps the writer's clock past its limit.
            break
        case .nextDictation:
            dictation.cancel()
            dictation.toggle()
        }
    }
}

/// The pairings of the matrix at the top of this file, each with what it
/// must end with, written out by hand from the product's rules.
enum ComposeMatrix {
    static let words = "Say yes."
    static let nextWords = "And more."

    /// Where voice compose is held.
    enum Wait: String, Sendable {
        /// The body read of Mail's message body.
        case bodyRead
        /// The body read of a Mail field that is not a message body.
        case plainFieldRead
        case creation
        /// The writer's wait between the first poll and the second.
        case pollWait
        case poll
        case acceptance
        /// The start of the typing a sign-out decided on while the email
        /// was written.
        case wordsAfterAccountChange
        /// The insertion of the email.
        case emailInsertion
        /// The insertion of the words after creation failed.
        case wordsInsertion
        /// The insertion of the words in a Mail field that is not a message
        /// body.
        case plainInsertion
    }

    /// What arrives while it is held.
    enum Event: String, Sendable {
        case signOut, refusedKey, keyReplaced, signOutAndIn, cancel
        case focusMoves, caretMoves, selectionGrows, textTyped, turnsSecure
        case writerFails, writerAbstains, writerTakesBack, writerTimesOut
        /// Cancelled, and the next dictation started, while the old wait
        /// goes on.
        case nextDictation
    }

    /// How the dictation must end.
    enum Ending: Sendable, Equatable {
        /// The words in once, with the notice.
        case wordsTyped
        /// The words in once, without the notice: the field is no email
        /// body.
        case wordsTypedPlainly
        /// The same, over a selection grown forward from the caret, which
        /// plain dictation writes over as it always has.
        case wordsTypedPlainlyOverSelection
        /// The words in once, without the notice, wherever the caret is
        /// now: between these two.
        case wordsTypedAt(before: String, after: String)
        case emailInserted
        /// Nothing in, the words kept with the reason `cancelled`.
        case cancelled
        /// Nothing in, the email kept with the words beside it and this
        /// reason.
        case emailRefused(String)
        /// Nothing in, the words kept with this reason.
        case wordsRefused(String)
        /// The first dictation kept as cancelled, and the next one's email
        /// in once.
        case cancelledThenNextEmail
        /// The first dictation kept as cancelled, and the next one's words
        /// in once, in a field that is no email body.
        case cancelledThenNextWordsPlainly
    }

    struct Cell: Sendable, CustomTestStringConvertible {
        let wait: Wait
        let event: Event
        let ending: Ending
        /// Requests created, acceptances made, and requests withdrawn by
        /// id.
        let requests: Int
        let acceptances: Int
        let withdrawn: Int

        var testDescription: String { "\(event.rawValue) at \(wait.rawValue)" }
    }

    /// An entry of history as the matrix checks it.
    struct Kept: Equatable {
        let text: String
        let spoken: String?
        let outcome: DictationHistory.Entry.Outcome
        let reason: String?

        init(_ text: String, _ spoken: String?, _ outcome: DictationHistory.Entry.Outcome, _ reason: String?) {
            (self.text, self.spoken, self.outcome, self.reason) = (text, spoken, outcome, reason)
        }

        init(_ entry: DictationHistory.Entry) {
            self.init(entry.text, entry.spoken, entry.outcome, entry.reason)
        }
    }

    private static func cell(_ wait: Wait, _ event: Event, _ ending: Ending, requests: Int = 1, acceptances: Int = 0,
                             withdrawn: Int = 0) -> Cell {
        Cell(wait: wait, event: event, ending: ending, requests: requests, acceptances: acceptances, withdrawn: withdrawn)
    }

    private static let accountChanges: [Event] = [.signOut, .keyReplaced, .signOutAndIn]
    /// The field's changes, with the reason the guard or the inserter
    /// gives for each.
    private static let fieldChanges: [(Event, String)] = [(.focusMoves, "focusChanged"), (.caretMoves, "fieldChanged"),
                                                          (.selectionGrows, "fieldChanged"), (.textTyped, "fieldChanged"),
                                                          (.turnsSecure, "secureField")]

    static let cells: [Cell] = bodyRead + plainFieldRead + writing(.creation) + writing(.pollWait) + writing(.poll)
        + writing(.acceptance) + wordsAfterAccountChange + emailInsertion + wordsInsertion + plainInsertion

    private static var bodyRead: [Cell] {
        accountChanges.map { cell(.bodyRead, $0, .wordsTyped, requests: 0) }
            + [cell(.bodyRead, .cancel, .cancelled, requests: 0)]
            + fieldChanges.map { event, reason in
                // Secure ends the read without the body's text, so no
                // email is asked for and the words are what is refused.
                event == .turnsSecure ? cell(.bodyRead, event, .wordsRefused(reason), requests: 0)
                    : cell(.bodyRead, event, .emailRefused(reason), acceptances: 1)
            }
            + [cell(.bodyRead, .nextDictation, .cancelledThenNextEmail, acceptances: 1)]
    }

    private static var plainFieldRead: [Cell] {
        accountChanges.map { cell(.plainFieldRead, $0, .wordsTypedPlainly, requests: 0) }
            + [cell(.plainFieldRead, .cancel, .cancelled, requests: 0)]
            + plainChanges(.plainFieldRead)
            + [cell(.plainFieldRead, .nextDictation, .cancelledThenNextWordsPlainly, requests: 0)]
    }

    /// The field's changes under plain dictation's rule, with no guard: the
    /// words go wherever the caret is when they come, in the field focus
    /// moved to, at a caret moved or after text typed since.
    private static func plainChanges(_ wait: Wait) -> [Cell] {
        [cell(wait, .focusMoves, .wordsTypedPlainly, requests: 0),
         cell(wait, .caretMoves, .wordsTypedAt(before: "abc", after: ""), requests: 0),
         cell(wait, .selectionGrows, .wordsTypedPlainlyOverSelection, requests: 0),
         cell(wait, .textTyped, .wordsTypedAt(before: "aX", after: "bc"), requests: 0),
         cell(wait, .turnsSecure, .wordsRefused("secureField"), requests: 0)]
    }

    /// While the writer works: at creation, the wait between polls, a
    /// poll or acceptance.
    private static func writing(_ wait: Wait) -> [Cell] {
        let accepted = wait == .acceptance ? 1 : 0
        let onCall = wait != .pollWait
        var cells = accountChanges.map { cell(wait, $0, .wordsTyped, acceptances: accepted, withdrawn: 1) }
        if onCall { cells.append(cell(wait, .refusedKey, .wordsTyped, acceptances: accepted, withdrawn: 1)) }
        cells.append(cell(wait, .cancel, .cancelled, acceptances: accepted, withdrawn: 1))
        cells += fieldChanges.map { cell(wait, $0.0, .emailRefused($0.1), acceptances: 1) }
        if onCall { cells.append(cell(wait, .writerFails, .wordsTyped, acceptances: accepted, withdrawn: 1)) }
        if wait == .poll { cells.append(cell(wait, .writerAbstains, .wordsTyped)) }
        if wait == .acceptance { cells.append(cell(wait, .writerTakesBack, .wordsTyped, acceptances: 1)) }
        if wait == .creation || wait == .poll { cells.append(cell(wait, .writerTimesOut, .wordsTyped, withdrawn: 1)) }
        cells.append(cell(wait, .nextDictation, .cancelledThenNextEmail, requests: 2, acceptances: accepted + 1, withdrawn: 1))
        return cells
    }

    /// The sign-out has decided to type the words; another sign-out, a
    /// sign-in, a cancel or a change to the field lands before they go in.
    private static var wordsAfterAccountChange: [Cell] {
        [cell(.wordsAfterAccountChange, .signOut, .wordsTyped, withdrawn: 1),
         cell(.wordsAfterAccountChange, .keyReplaced, .wordsTyped, withdrawn: 1),
         cell(.wordsAfterAccountChange, .cancel, .wordsTyped, withdrawn: 1)]
            + fieldChanges.map { cell(.wordsAfterAccountChange, $0.0, .wordsRefused($0.1), withdrawn: 1) }
    }

    private static var emailInsertion: [Cell] {
        (accountChanges + [.cancel]).map { cell(.emailInsertion, $0, .emailInserted, acceptances: 1) }
            + fieldChanges.map { cell(.emailInsertion, $0.0, .emailRefused($0.1), acceptances: 1) }
    }

    private static var wordsInsertion: [Cell] {
        (accountChanges + [.cancel]).map { cell(.wordsInsertion, $0, .wordsTyped, withdrawn: 1) }
            + fieldChanges.map { cell(.wordsInsertion, $0.0, .wordsRefused($0.1), withdrawn: 1) }
    }

    private static var plainInsertion: [Cell] {
        (accountChanges + [.cancel]).map { cell(.plainInsertion, $0, .wordsTypedPlainly, requests: 0) }
            + plainChanges(.plainInsertion)
    }
}

/// A stand-in for the draft route inside the dictation package: a request
/// is pending, then complete with `text`, then accepted, unless a scenario
/// says otherwise. Every call is recorded when it is made, and a scenario
/// can hold one call until it lets it answer (`hold`, `whileHeld`).
final class ScriptedRoute: DraftService, @unchecked Sendable {
    enum Answer: Sendable {
        case pending
        case complete
        case abstain(DraftReason)
        /// A cancelled receipt, as a draft the server took back.
        case takeBack
        case fail(DraftRequestFailure)
    }

    /// A call to the route, as a scenario holds one.
    enum Call: Sendable {
        case create, read, accept, cancel, shown
    }

    private let lock = NSLock()
    private let text: String
    private let acceptedText: String?
    var onCreate: Answer = .pending
    var onRead: Answer = .complete
    /// What the first polls answer, in turn, before `onRead` answers the
    /// rest.
    var firstReads: [Answer] = []
    /// What acceptance answers: `complete` is the draft accepted with its
    /// text, `takeBack` a draft the server took back before it was
    /// accepted, and `fail` a call that fails.
    var onAccept: Answer = .complete
    var firstAccepts: [Answer] = []
    private(set) var recordedAcceptances: [UUID] = []
    /// Runs before each poll is answered, as something that happens to the
    /// field while the server writes.
    var beforeRead: (@Sendable () -> Void)?
    /// Set, a scripted `unauthorized` is thrown as the adapter throws a
    /// refused key, with this as its report.
    var keyRefused: (@Sendable @MainActor () -> Void)?
    private(set) var created: [WritingInput] = []
    private(set) var read: [UUID] = []
    private(set) var cancelled: [UUID] = []
    private(set) var accepted: [UUID] = []
    /// Every admission asked, with its proposal's id and revision.
    private(set) var shownCalls: [(id: UUID, revision: Int)] = []
    /// What each admission answers in turn, nil for 204; the last
    /// repeats.
    var onShown: [DraftRequestFailure?] = [nil]
    var shownRecipientCheck: String?
    private(set) var shownRecipients: [[WritingRecipient]] = []
    private(set) var admittedCards: [UUID] = []
    /// The kind of call held next, the one being held, and the held call
    /// waiting to answer.
    private var holding: Call?
    private var held: Call?
    private var released = false
    private var waiting: CheckedContinuation<Void, Never>?

    init(text: String, acceptedText: String? = nil) {
        self.text = text
        self.acceptedText = acceptedText
    }

    /// A stand-in has no accounts: every request goes to it.
    func forThisAccount() async throws -> any DraftService { self }

    func create(_ input: WritingInput) async throws -> DraftReceipt {
        lock.withLock { created.append(input) }
        await pass(.create)
        let answer = onCreate
        return try receipt(answer, input.requestID)
    }

    func read(_ requestID: UUID) async throws -> DraftReceipt {
        lock.withLock { read.append(requestID) }
        await pass(.read)
        beforeRead?()
        let answer = lock.withLock { firstReads.isEmpty ? onRead : firstReads.removeFirst() }
        return try receipt(answer, requestID)
    }

    func cancel(_ requestID: UUID) async throws -> DraftReceipt {
        lock.withLock { cancelled.append(requestID) }
        await pass(.cancel)
        return make(requestID, status: .cancelled, reason: .cancelled)
    }

    func accept(_ requestID: UUID, revision: Int) async throws -> DraftReceipt {
        lock.withLock { accepted.append(requestID) }
        await pass(.accept)
        let answer = lock.withLock { firstAccepts.isEmpty ? onAccept : firstAccepts.removeFirst() }
        switch answer {
        case .takeBack: return make(requestID, status: .cancelled, reason: .superseded)
        case let .fail(failure): throw refusal(failure)
        case .pending, .complete, .abstain:
            lock.withLock { recordedAcceptances.append(requestID) }
            return make(requestID, status: .complete, text: acceptedText ?? text, accepted: true)
        }
    }

    func shown(_ requestID: UUID, revision: Int, recipients: [WritingRecipient]) async throws {
        lock.withLock {
            shownCalls.append((requestID, revision))
            shownRecipients.append(recipients)
        }
        await pass(.shown)
        let failure = lock.withLock { onShown.count > 1 ? onShown.removeFirst() : onShown.first ?? nil }
        if let failure { throw failure }
        lock.withLock { admittedCards.append(requestID) }
    }

    /// Holds the next call of this kind, after it is recorded and before it
    /// answers, until `whileHeld` lets it answer.
    func hold(_ call: Call) {
        lock.withLock { holding = call }
    }

    /// The held call fails with `failure` when it answers.
    func failHeldCall(_ failure: DraftRequestFailure) {
        switch lock.withLock({ held }) {
        case .create?: onCreate = .fail(failure)
        case .read?: onRead = .fail(failure)
        case .accept?: onAccept = .fail(failure)
        case .shown?: onShown = [failure]
        case .cancel?, nil: Issue.record("no create, poll or acceptance is held to fail")
        }
    }

    /// Runs `action` while the held call waits, gives what it started
    /// `pause` to run, then lets the call answer.
    @MainActor func whileHeld(pause: Duration = .milliseconds(150), _ action: @MainActor () async -> Void) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while lock.withLock({ held }) == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(lock.withLock { held } != nil, "the route's call was not held")
        await action()
        try? await Task.sleep(for: pause)
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { waiting = nil }
            return waiting
        }
        continuation?.resume()
    }

    private func pass(_ call: Call) async {
        let holds = lock.withLock { () -> Bool in
            guard holding == call else { return false }
            holding = nil
            held = call
            return true
        }
        guard holds else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if released { return true }
                waiting = continuation
                return false
            }
            if now { continuation.resume() }
        }
    }

    private func receipt(_ answer: Answer, _ id: UUID) throws -> DraftReceipt {
        switch answer {
        case .pending: make(id, status: .pending)
        case .complete: make(id, status: .complete, text: text)
        case let .abstain(reason): make(id, status: .abstained, reason: reason)
        case .takeBack: make(id, status: .cancelled, reason: .superseded)
        case let .fail(failure): throw refusal(failure)
        }
    }

    private func refusal(_ failure: DraftRequestFailure) -> Error {
        guard failure == .unauthorized, let keyRefused else { return failure }
        return RefusedKey(report: keyRefused)
    }

    private func make(_ id: UUID, status: DraftReceipt.Status, reason: DraftReason? = nil, text: String? = nil, accepted: Bool = false) -> DraftReceipt {
        DraftReceipt(requestID: id, revision: 1, status: status, reason: reason, text: text, accepted: accepted,
                     identity: .init(candidate: "retrieval-examples-v1", provider: "synthetic", model: "synthetic-model", modelRevision: "0",
                                     adapter: "synthetic-adapter", configurationID: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!),
                     sources: [], cost: .init(status: .notStarted, inputTokens: nil, outputTokens: nil, usd: nil, limitUSD: "0.05"),
                     shownRecipientCheck: shownRecipientCheck)
    }
}

/// Holds work on the inserter's executor, so a scenario can act on the
/// main actor while it waits. After `arm`, at the first check of whether
/// the field is secure: the body read, held after it has read the
/// selection and the field's length and before it reads any text, or an
/// insertion, held in the body read's guard after its check that focus has
/// not moved, before anything is written. After `armAtFocusRead`, at a
/// read of which element has focus: an insertion without a guard, held
/// before it knows which field has focus. Made after `MockField.reset`,
/// since it hooks the scripted field of the moment.
final class InsertionGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var armed = false
    /// How many more reads of the focused element pass before one is held;
    /// nil holds none.
    private var focusReadsToPass: Int?
    private var held = false

    init() {
        MockField.shared.onSecureCheck = { @Sendable [self] in hold() }
    }

    /// The next check of whether the field is secure waits until
    /// `whileHeld` lets it go on.
    func arm() {
        lock.withLock { armed = true }
    }

    /// The read of which element has focus after `passing` more of them
    /// waits until `whileHeld` lets it go on.
    func armAtFocusRead(passing: Int) {
        MockField.shared.onFocusRead = { @Sendable [self] in holdAtFocusRead() }
        lock.withLock { focusReadsToPass = passing }
    }

    /// Runs `action` while the work is held, then gives anything it
    /// started `pause` to run, such as a second insertion, before the held
    /// work goes on.
    @MainActor func whileHeld(pause: Duration = .milliseconds(150), _ action: @MainActor () async -> Void) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !lock.withLock({ held }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(lock.withLock { held }, "the work did not reach the point it is held at")
        await action()
        try? await Task.sleep(for: pause)
        release.signal()
    }

    /// The Mac signs out, as a sign-out or a refused key reaches dictation.
    @MainActor func signOutWhileHeld(_ dictation: DictationController) async {
        await whileHeld { dictation.accountChanged(signedIn: false) }
    }

    /// Runs on the executor.
    private func hold() {
        let holds = lock.withLock { () -> Bool in
            guard armed else { return false }
            armed = false
            held = true
            return true
        }
        if holds { _ = release.wait(timeout: .now() + 10) }
    }

    /// Runs on the executor.
    private func holdAtFocusRead() {
        let holds = lock.withLock { () -> Bool in
            guard let passing = focusReadsToPass else { return false }
            guard passing == 0 else {
                focusReadsToPass = passing - 1
                return false
            }
            focusReadsToPass = nil
            held = true
            return true
        }
        if holds { _ = release.wait(timeout: .now() + 10) }
    }
}

extension DictationScenarioTests {
    @Test func anEarlierWriters65SecondDeadlineCannotEndALaterHeldRecording() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "say yes", text: "Say yes.")])
        defer { server.stop() }
        let route = ScriptedRoute(text: draft)
        let clock = SteppedClock()
        route.hold(.create)
        let (dictation, _) = voice(server.endpoint, route: route, limit: .seconds(65), clock: clock)
        dictation.toggle()
        await speak()
        dictation.toggle()
        await route.whileHeld {
            dictation.holdBegan(confirmed: true)
            #expect(dictation.phase == .recording)
            await until { clock.waits.contains(.seconds(65)) }
            clock.advance(to: .seconds(65))
            await until { !dictation.history.entries.isEmpty }
            #expect(dictation.phase == .recording)
            dictation.escapePressed()
        }
        await settle(dictation)
        #expect(dictation.history.entries.count == 1)
        #expect(MockField.shared.text == "Say yes." + thread)
    }
}
