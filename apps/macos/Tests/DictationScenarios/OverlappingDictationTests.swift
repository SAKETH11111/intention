import AppKit
@testable import Dictation
import Testing

/// A new dictation started while the last one's text is still on its way:
/// it records at once, the earlier one ends as it would have, and the new
/// one's text goes in after it. The scenarios extend the dictation suite so
/// that everything touching the scripted field runs in one serialized line.
extension DictationScenarioTests {
    /// 100 ms of speech as the microphone hands it on.
    private var chunk: Data { Self.tone(amplitude: 8_000) }

    /// Both bounded reads of the next insertion find nothing focused;
    /// the following insertion can find the field again.
    private func refuseNextInsertion() {
        let reads = Counter()
        field.onFocusRead = { @Sendable in MockField.shared.focused = reads.next() > 2 }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }

    /// As on Alex's Mac with build 6: a held dictation, then 1.6 seconds
    /// after its stop, while its text is being inserted, the key held again
    /// for a second dictation. It records from the press to the release,
    /// and its text goes in after the first's.
    @Test func aPressWhileTheLastDictationsTextGoesInRecordsTheWholeHoldAndGoesInAfterIt() async throws {
        let server = try await ScriptedEndpoint([
            .answer(transcript: "first", text: "First."), .answer(transcript: "second", text: "Second."),
        ])
        defer { server.stop() }
        let source = ScriptedSource()
        let dictation = controller(server.endpoint, source: source)
        let gate = InsertionGate()
        dictation.holdBegan()
        try? await Task.sleep(for: .milliseconds(400))
        // The next check of whether the field is secure is the first
        // dictation's insertion, which waits there until the second is done.
        gate.arm()
        dictation.holdEnded()
        let stopped = ContinuousClock.now
        var said = 0
        await gate.whileHeld {
            #expect(dictation.phase == .processing)
            try? await Task.sleep(until: stopped + .milliseconds(1_600))
            dictation.holdBegan()
            #expect(dictation.phase == .recording)
            #expect(source.running)
            for _ in 0..<6 {
                source.say(chunk)
                said += 1
                try? await Task.sleep(for: .milliseconds(100))
            }
            dictation.holdEnded()
            #expect(!source.running)
        }
        await idle(dictation)
        #expect(field.text == "aFirst. Second.bc")
        #expect(server.connections.count == 2)
        // Every chunk of the second hold reached its own connection: the
        // source's chunks as recording opened, those said, and the last.
        let second = try #require(server.connections.last)
        #expect(second.frames == source.chunks + said + 1)
        #expect(second.stopFrames == second.frames)
        #expect(dictation.history.entries.map(\.text) == [" Second.", "First."])
        #expect(dictation.history.entries.allSatisfy { $0.outcome == .inserted })
    }

    /// The server spaced a waiting dictation's words for the text before
    /// the caret at its start; they are spaced again for the text there
    /// when they go in, by the server's rule.
    @Test func aWaitingDictationsWordsAreSpacedForTheTextNowBeforeTheCaret() {
        // An empty field at the start, the earlier sentence in it now.
        #expect(FieldEdit.spaced("How are you?", after: "Hello there.") == " How are you?")
        // Spaced for a word at the start, at the start of a field now.
        #expect(FieldEdit.spaced(" how are you?", after: "") == "how are you?")
        // After a space or a line break, and before closing punctuation or
        // a spoken line break, no space.
        #expect(FieldEdit.spaced(" Second.", after: "First. ") == "Second.")
        #expect(FieldEdit.spaced(" Second.", after: "First.\n") == "Second.")
        #expect(FieldEdit.spaced(", then", after: "First") == ", then")
        #expect(FieldEdit.spaced("\nSecond.", after: "First.") == "\nSecond.")
        #expect(FieldEdit.spaced("", after: "First.") == "")
    }

    @Test func aLaterDictationsTextReadyFirstWaitsAndGoesInAfterTheEarlierOnes() async throws {
        let server = try await ScriptedEndpoint([
            .answerLate(after: 1, transcript: "first", text: "First."), .answer(transcript: "second", text: "Second."),
        ])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        dictation.toggle()
        await speak()
        dictation.toggle()
        #expect(dictation.phase == .processing)
        dictation.toggle()
        #expect(dictation.phase == .recording)
        await speak()
        dictation.toggle()
        // The second's text is back and waits for the first's.
        await waitUntil { server.connections.count == 2 && server.connections[1].answered }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(field.text == "abc")
        #expect(field.accessibilityWrites == 0)
        #expect(dictation.history.entries.isEmpty)
        #expect(dictation.phase == .processing)
        await idle(dictation)
        #expect(field.text == "aFirst. Second.bc")
        #expect(field.accessibilityWrites == 2)
        #expect(dictation.history.entries.map(\.text) == [" Second.", "First."])
        #expect(dictation.history.entries.allSatisfy { $0.outcome == .inserted })
    }

    /// The key starts the next dictation while the last one's text is on
    /// its way; the working sun itself takes no click, since it shows
    /// nothing under the pointer.
    @Test func theKeyWhileTheLastDictationsTextIsOnItsWayStartsRecording() async throws {
        let server = try await ScriptedEndpoint([
            .answerLate(after: 0.8, transcript: "first", text: "First."), .answer(transcript: "second", text: "Second."),
        ])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        let foot = foot(for: dictation)
        dictation.toggle()
        await speak()
        dictation.toggle()
        #expect(foot.presentation == .writing)
        foot.hover(true)
        click(foot)
        #expect(foot.presentation == .writing)
        #expect(dictation.phase == .processing)
        dictation.toggle()
        #expect(dictation.phase == .recording)
        #expect(foot.state == .listening)
        await speak()
        click(foot)
        #expect(foot.state == .writing)
        await idle(dictation)
        #expect(field.text == "aFirst. Second.bc")
        #expect(dictation.history.entries.map(\.text) == [" Second.", "First."])
    }

    @Test(arguments: ["escape", "foot"])
    func cancellingTheNewRecordingLeavesTheEarlierDictationToGoIn(_ way: String) async throws {
        let server = try await ScriptedEndpoint([
            .answerLate(after: 0.6, transcript: "first", text: "First."), .answer(transcript: "second", text: "Second."),
        ])
        defer { server.stop() }
        let source = ScriptedSource()
        let dictation = controller(server.endpoint, source: source)
        let foot = foot(for: dictation)
        dictation.toggle()
        await speak()
        dictation.toggle()
        dictation.holdBegan()
        #expect(dictation.phase == .recording)
        dictation.holdBecameHandsFree()
        dictation.holdEnded()
        await speak()
        #expect(dictation.phase == .recording)
        if way == "escape" {
            dictation.escapePressed()
        } else {
            try cancel(foot)
        }
        // Only the recording one is dropped; the first is still on its way.
        #expect(!source.running)
        #expect(!dictation.handsFree)
        #expect(dictation.phase == .processing)
        await idle(dictation)
        #expect(field.text == "aFirst.bc")
        #expect(dictation.history.entries.map(\.text) == ["First."])
        #expect(dictation.history.entries.first?.outcome == .inserted)
        // The second was never stopped, so its connection heard no stop.
        #expect(server.connections.dropFirst().allSatisfy { $0.stopFrames == nil })
    }

    /// A sign-out treats each open dictation as it treats one alone: one
    /// recording is dropped, one whose words have not come back is dropped,
    /// and text already going in finishes.
    @Test(arguments: ["waitingForWords", "goingIn"])
    func signingOutWithOneRecordingAndOneOnItsWay(_ earlier: String) async throws {
        let server = try await ScriptedEndpoint([
            earlier == "goingIn" ? .answer(transcript: "first", text: "First.") : .answerLate(after: 1, transcript: "first", text: "First."),
            .answer(transcript: "second", text: "Second."),
        ])
        defer { server.stop() }
        let source = ScriptedSource()
        let dictation = controller(server.endpoint, source: source)
        let gate = InsertionGate()
        dictation.toggle()
        await speak()
        if earlier == "goingIn" { gate.arm() }
        dictation.toggle()
        let signOut = {
            dictation.toggle()
            #expect(dictation.phase == .recording)
            await self.speak()
            dictation.accountChanged(signedIn: false)
            #expect(!source.running)
            #expect(dictation.problem == .signedOut)
        }
        if earlier == "goingIn" {
            await gate.whileHeld {
                await signOut()
                #expect(dictation.phase == .processing)
            }
        } else {
            await signOut()
            #expect(dictation.phase == .idle)
        }
        await idle(dictation)
        try? await Task.sleep(for: .milliseconds(300))
        if earlier == "goingIn" {
            #expect(field.text == "aFirst.bc")
            #expect(dictation.history.entries.map(\.text) == ["First."])
        } else {
            #expect(field.text == "abc")
            #expect(dictation.history.entries.isEmpty)
            #expect(server.connections.first?.cancelled == true)
        }
        #expect(server.connections.dropFirst().allSatisfy { $0.stopFrames == nil })
    }

    /// While one records the indicators show recording; once none does,
    /// the phase of the one still on its way; idle once both have ended.
    @Test func theIndicatorsShowRecordingThenTheEarlierDictationsPhaseThenRest() async throws {
        let server = try await ScriptedEndpoint([
            .answerLate(after: 0.8, transcript: "first", text: "First."), .answer(transcript: "second", text: "Second."),
        ])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        let foot = foot(for: dictation)
        let shown = dictation.phaseChanged
        var phases: [DictationController.Phase] = []
        var states: [FootState] = []
        dictation.phaseChanged = {
            shown?($0)
            phases.append($0)
            states.append(foot.state)
        }
        dictation.toggle()
        await speak()
        dictation.toggle()
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(phases == [.recording, .processing, .recording, .processing, .idle])
        #expect(states == [.listening, .writing, .listening, .writing, .resting])
        #expect(field.text == "aFirst. Second.bc")
    }

    /// The words of a dictation that waited are spaced by the read its
    /// write makes, and the field is read for them nowhere else. The caret
    /// moves to the start of the field once the earlier text is in: before
    /// any read for them, when they are spaced for the start; or right
    /// after a separate read for their spacing, as one once was, which left
    /// a space meant for the old place at the new one.
    @Test(arguments: ["beforeTheWrite", "afterASpacingRead"])
    func aWaitingDictationIsSpacedForTheCaretItsWriteReads(_ moved: String) async throws {
        let server = try await ScriptedEndpoint([
            .answerLate(after: 0.8, transcript: "first", text: "First."), .answer(transcript: "second", text: "Second."),
        ])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        dictation.toggle()
        await speak()
        dictation.toggle()
        dictation.toggle()
        await speak()
        dictation.toggle()
        await waitUntil { server.connections.count == 2 && server.connections[1].answered }
        let noted = Counter()
        if moved == "beforeTheWrite" {
            field.onFocusRead = { @Sendable in
                let field = MockField.shared
                if field.text == "aFirst.bc", noted.next() == 1 { field.selection = FieldRange(location: 0, length: 0) }
            }
        } else {
            // A read that notes the field, as at a dictation's start: the
            // caret moves once its selection has been read.
            field.onFieldNoted = { @Sendable in
                _ = noted.next()
                MockField.shared.moveSelectionOnRead = FieldRange(location: 0, length: 0)
            }
        }
        await idle(dictation)
        if moved == "beforeTheWrite" {
            #expect(field.text == "Second.aFirst.bc")
            #expect(dictation.history.entries.map(\.text) == ["Second.", "First."])
        } else {
            #expect(noted.count == 0)
            #expect(field.text == "aFirst. Second.bc")
            #expect(dictation.history.entries.map(\.text) == [" Second.", "First."])
        }
    }

    /// An earlier paste the app has not read yet: the next dictation's text
    /// waits until that paste's late-read window has passed, so the app
    /// reading the clipboard late still finds the earlier text, and then
    /// goes in after it. The person's own clipboard comes back at the end.
    @Test func aWaitingDictationGoesInOnlyOnceAnEarlierUnreadPastesWindowHasPassed() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "first", text: "First."), .answer(transcript: "second", text: "Second.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        // A field that refuses the Accessibility write takes the paste.
        field.writes = .refuse
        let board = try #require(field.pasteboard)
        board.clearContents()
        board.setString("mine", forType: .string)
        let keys = Stamps()
        // The app is too busy to read the first paste's clipboard; it takes
        // later keys at once.
        field.onKey = { @Sendable in
            MockField.shared.pastesLand = keys.add() > 1
        }
        dictation.toggle()
        await speak()
        dictation.toggle()
        dictation.toggle()
        await speak()
        dictation.toggle()
        await waitUntil { keys.count == 1 }
        let first = try #require(keys.all.first)
        // It reads the clipboard late, within the window.
        try? await Task.sleep(until: first + .milliseconds(1_900))
        field.type(try #require(board.string(forType: .string)))
        await idle(dictation)
        #expect(field.text == "aFirst. Second.bc")
        #expect(keys.count == 2)
        #expect(try #require(keys.all.dropFirst().first) - first >= .seconds(2))
        #expect(dictation.history.entries.map(\.outcome) == [.inserted, .uncertain], "\(dictation.history.entries.map(\.reason))")
        try? await Task.sleep(for: .seconds(2))
        #expect(board.string(forType: .string) == "mine")
    }

    /// The same with a second dictation started only after the first
    /// ended, its paste unconfirmed: every insertion waits for the one
    /// before, not only a dictation that waited for another.
    @Test func aDictationStartedAfterAnUnreadPasteGoesInOnlyOnceItsWindowHasPassed() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "first", text: "First."), .answer(transcript: "second", text: " Second.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        field.writes = .refuse
        let board = try #require(field.pasteboard)
        board.clearContents()
        board.setString("mine", forType: .string)
        let keys = Stamps()
        field.onKey = { @Sendable in
            MockField.shared.pastesLand = keys.add() > 1
        }
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        let returned = ContinuousClock.now
        #expect(dictation.history.entries.map(\.outcome) == [.uncertain])
        let first = try #require(keys.all.first)
        // A short second dictation, done well within the first paste's
        // window, which began when its insertion returned.
        dictation.toggle()
        await speak()
        dictation.toggle()
        await waitUntil { server.connections.count == 2 && server.connections[1].answered }
        #expect(ContinuousClock.now - returned < .milliseconds(1_500))
        // The first app reads the clipboard late, within the window.
        try? await Task.sleep(until: first + .milliseconds(1_900))
        #expect(keys.count == 1)
        field.type(try #require(board.string(forType: .string)))
        await idle(dictation)
        #expect(field.text == "aFirst. Second.bc")
        #expect(keys.count == 2)
        #expect(try #require(keys.all.dropFirst().first) - first >= .seconds(2))
        #expect(dictation.history.entries.map(\.outcome) == [.inserted, .uncertain])
        #expect(board.string(forType: .string) == "mine")
    }

    /// An earlier Accessibility write the field accepted and did not show
    /// may still land. Once it shows right before the caret it has landed,
    /// and the next words go in after it, whether their dictation waited
    /// for that one or started after it ended. The field is remembered as
    /// one that did not show a write in time, so they are pasted.
    @Test(arguments: ["waiting", "later"])
    func wordsAfterAnEarlierUnshownWriteHasShownGoIn(_ when: String) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "first", text: "First."), .answer(transcript: "second", text: "Second.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        field.writes = .held
        // The app shows the write before anything more is read: every read
        // of focus after the write is for the next words.
        field.onFocusRead = { @Sendable in
            if MockField.shared.accessibilityWrites == 1 { MockField.shared.land() }
        }
        var refused: [String] = []
        dictation.notInserted = { refused.append($1) }
        dictation.toggle()
        await speak()
        dictation.toggle()
        if when == "later" { await waitUntil { !dictation.history.entries.isEmpty } }
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(field.keys == ["paste"])
        #expect(field.accessibilityWrites == 1)
        // Words that waited are spaced for the text before the caret.
        #expect(field.text == (when == "waiting" ? "aFirst. Second.bc" : "aFirst.Second.bc"))
        #expect(dictation.history.entries.map(\.outcome) == [.inserted, .uncertain])
        #expect(refused.isEmpty)
    }

    /// A late WebKit selection replacement must be preserved for the next
    /// dictation. A collapse that does not take keeps those words for Copy.
    @Test(arguments: [false, true])
    func wordsAfterALateSelectedMarkerWriteArePreserved(_ ignoredCollapse: Bool) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "first", text: "First."), .answer(transcript: "second", text: "Second.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        field.document = true
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        field.writes = .held
        var refused: [(EditReason, String)] = []
        dictation.notInserted = { refused.append(($0, $1)) }
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(dictation.history.entries.map(\.outcome) == [.uncertain])
        field.land()
        field.selection = FieldRange(location: 5, length: 6)
        field.selectionWritesIgnored = ignoredCollapse
        try await Task.sleep(for: .milliseconds(2_300))
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(field.text == (ignoredCollapse ? "keep First. keep" : "keep First.Second. keep"))
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys == (ignoredCollapse ? [] : ["paste"]))
        #expect(dictation.history.entries.map(\.outcome) == [ignoredCollapse ? .notInserted : .inserted, .uncertain])
        #expect(dictation.history.entries.first?.text == "Second.")
        #expect(refused.map(\.0) == (ignoredCollapse ? [.earlierUnsettled] : []))
        #expect(refused.map(\.1) == (ignoredCollapse ? ["Second."] : []))
        if ignoredCollapse { #expect(dictation.history.entries.first?.reason == "earlierUnsettled") }
    }

    @Test(arguments: ["inside", "elsewhere", "length"])
    func wordsAfterTextChangesDuringTheFreshCollapseReadStayInHistoryWithCopy(_ change: String) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "first", text: "first"), .answer(transcript: "second", text: "second")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        let tail = String(repeating: "z", count: 100)
        let suffix = change == "length" ? tail : ""
        let changed = change == "inside" ? "keep xfirst keep" : change == "elsewhere" ? "keep first deep" : "keep first keep" + tail + "z"
        field.document = true
        field.text = "keep old keep" + suffix
        field.selection = FieldRange(location: 5, length: 3)
        field.writes = .held
        var refused: [(EditReason, String)] = []
        dictation.notInserted = { refused.append(($0, $1)) }
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        field.land()
        field.selection = FieldRange(location: 5, length: 5)
        field.onSelectionWrite = { [field] in
            let reads = field.focusReads
            field.onFocusRead = { [field] in
                if field.focusReads == reads + 3 { field.text = changed }
            }
        }
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(field.text == changed)
        #expect(field.text.contains("first"))
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
        #expect(dictation.history.entries.map(\.outcome) == [.notInserted, .uncertain])
        #expect(dictation.history.entries.map(\.text) == ["second", "first"])
        #expect(dictation.history.entries.first?.reason == "fieldChanged")
        #expect(refused.map(\.0) == [.fieldChanged])
        #expect(refused.map(\.1) == ["second"])
    }

    /// Issue #326 as a dictation meets it: "old" is selected and the first
    /// dictation's write over it is still on its way well after the two
    /// seconds within which the next words used to be refused. Those words
    /// are refused and kept, with the popup's Copy, and the earlier write
    /// then lands alone, over "old".
    @Test(arguments: ["accepted", "unanswered"])
    func wordsLongAfterAWriteStillOnItsWayAreRefusedAndKept(_ write: String) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "first", text: "First."), .answer(transcript: "second", text: "Second.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        field.writes = write == "accepted" ? .held : .unanswered
        var refused: [(EditReason, String)] = []
        dictation.notInserted = { refused.append(($0, $1)) }
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        let returned = ContinuousClock.now
        #expect(dictation.history.entries.map(\.outcome) == [.uncertain])
        // The app takes later writes at once; this one is still on its way.
        field.writes = .apply
        try await Task.sleep(until: returned + .milliseconds(2_300))
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(field.keys.isEmpty)
        #expect(field.accessibilityWrites == 1)
        #expect(field.text == "keep old keep")
        let entries = dictation.history.entries
        #expect(entries.map(\.outcome) == [.notInserted, .uncertain])
        #expect(entries.first?.reason == "earlierUnsettled")
        #expect(entries.first?.text == "Second.")
        #expect(refused.map(\.0) == [.earlierUnsettled])
        #expect(refused.map(\.1) == ["Second."])
        field.land()
        #expect(field.text == "keep First. keep")
    }

    /// The earlier write shows while the next dictation's words are still
    /// on their way, more than two seconds after it, and they go in after
    /// it, pasted, since the field is remembered as one that did not show
    /// a write in time.
    @Test func wordsAfterTheWindowOfAnEarlierUnshownWriteGoIn() async throws {
        let server = try await ScriptedEndpoint([
            .answer(transcript: "first", text: "First."),
            .answerLate(after: 3.5, transcript: "second", text: "Second."),
        ])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        field.writes = .held
        dictation.toggle()
        await speak()
        dictation.toggle()
        dictation.toggle()
        await speak()
        dictation.toggle()
        await waitUntil { !dictation.history.entries.isEmpty }
        field.land()
        await idle(dictation)
        #expect(field.keys == ["paste"])
        #expect(field.accessibilityWrites == 1)
        #expect(field.text == "aFirst. Second.bc")
        #expect(dictation.history.entries.map(\.outcome) == [.inserted, .uncertain])
    }

    /// Three dictations: the second and the third both wait on the first,
    /// whose write is unknown and never shows. Neither goes in while it may
    /// still land, so the third cannot pass once the second has been
    /// refused.
    @Test func twoDictationsWaitingOnAnUnshownWriteAreBothRefused() async throws {
        let server = try await ScriptedEndpoint([
            .answer(transcript: "first", text: "First."), .answer(transcript: "second", text: "Second."),
            .answer(transcript: "third", text: "Third."),
        ])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        field.writes = .held
        // Each popup comes in turn after the one before has had its time;
        // here that time passes at once.
        dictation.noticePause = {}
        var refused: [String] = []
        dictation.notInserted = { refused.append($1) }
        for _ in 0..<3 {
            dictation.toggle()
            await speak()
            dictation.toggle()
        }
        await idle(dictation)
        #expect(field.keys.isEmpty)
        #expect(field.accessibilityWrites == 1)
        let entries = dictation.history.entries
        #expect(entries.map(\.text) == ["Third.", "Second.", "First."])
        #expect(entries.map(\.outcome) == [.notInserted, .notInserted, .uncertain])
        #expect(entries.prefix(2).map(\.reason) == ["earlierUnsettled", "earlierUnsettled"])
        await waitUntil { refused == ["Second.", "Third."] }
        // The write lands at last, alone.
        field.land()
        #expect(field.text == "aFirst.bc")
    }

    /// An app that does not answer the write in time may still apply it
    /// once it catches up, so the next words wait on it as on one the field
    /// accepted and did not show.
    @Test func wordsWaitingOnAWriteTheAppDidNotAnswerAreRefusedAndKept() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "first", text: "First."), .answer(transcript: "second", text: "Second.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        dictation.noticePause = {}
        field.writes = .unanswered
        var refused: [String] = []
        dictation.notInserted = { refused.append($1) }
        dictation.toggle()
        await speak()
        dictation.toggle()
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
        let entries = dictation.history.entries
        #expect(entries.map(\.outcome) == [.notInserted, .uncertain])
        #expect(entries.map(\.reason) == ["earlierUnsettled", "targetUnresponsive"])
        #expect(refused == ["Second."])
        field.land()
        #expect(field.text == "aFirst.bc")
    }

    /// The person moves to another field of the same app while the first
    /// dictation's write is still on its way in its own: the next words go
    /// in there at once, since the write names only its own field, and the
    /// first field stays held.
    @Test func wordsIntoAnotherFieldGoInWhileAnEarlierWriteHoldsItsOwn() async throws {
        let server = try await ScriptedEndpoint([
            .answer(transcript: "first", text: "First."), .answer(transcript: "second", text: "Second."),
            .answer(transcript: "third", text: "Third."),
        ])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        field.writes = .held
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(dictation.history.entries.map(\.outcome) == [.uncertain])
        field.writes = .apply
        field.focusedElement = 2
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(field.accessibilityWrites == 2)
        #expect(field.text.contains("Second."))
        #expect(dictation.history.entries.map(\.outcome) == [.inserted, .uncertain])
        // Back in the first field, as it was, where the write is still on
        // its way: held, and kept.
        field.focusedElement = 1
        field.text = "abc"
        field.selection = FieldRange(location: 1, length: 0)
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(field.accessibilityWrites == 2)
        #expect(field.keys.isEmpty)
        #expect(dictation.history.entries.map(\.outcome) == [.notInserted, .inserted, .uncertain])
        #expect(dictation.history.entries.first?.reason == "earlierUnsettled")
        field.land()
        #expect(field.text == "aFirst.bc")
    }

    /// Chrome gives the field of a dictation whose write is still on its
    /// way a new object, and the editor grows a point wider. Nothing tells
    /// the new object from another field of the page, so the next words,
    /// within ten seconds of the write, are refused with the reason that
    /// says to try again in a few seconds, kept in history and offered on
    /// the popup's Copy; the earlier write then lands alone.
    @Test func wordsIntoAPageWhoseFieldWasReplacedAreRefusedForAFewSeconds() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "first", text: "First."), .answer(transcript: "second", text: "Second.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        field.bundleIdentifier = "com.google.Chrome"
        field.web = true
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        field.writes = .held
        var refused: [(EditReason, String)] = []
        dictation.notInserted = { refused.append(($0, $1)) }
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(dictation.history.entries.map(\.outcome) == [.uncertain])
        field.writes = .apply
        field.objectGeneration += 1
        field.frameWidth = 301
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
        #expect(field.text == "keep old keep")
        let entries = dictation.history.entries
        #expect(entries.map(\.outcome) == [.notInserted, .uncertain])
        #expect(entries.first?.reason == "earlierUnsettledNearby")
        #expect(entries.first?.text == "Second.")
        #expect(refused.map(\.0) == [.earlierUnsettledNearby])
        #expect(refused.map(\.1) == ["Second."])
        field.land()
        #expect(field.text == "keep First. keep")
    }

    @Test(arguments: [false, true])
    func wordsStayInHistoryWhenAPageHasMatchingTextOrItsMovedTabDoesNotAnswer(_ moved: Bool) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "first", text: "first"),
                                               .answer(transcript: "other", text: "other"),
                                               .answer(transcript: "second", text: "second")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        field.bundleIdentifier = "com.google.Chrome"
        field.web = true
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        field.writes = .held
        var refused: [(EditReason, String)] = []
        dictation.notInserted = { refused.append(($0, $1)) }
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        field.writes = .apply
        field.objectGeneration += 1
        if moved {
            field.windowGeneration = 1
            field.webAreaRoleUnanswered = true
        } else {
            field.focusedElement = 2
            field.text = "keep first keep"
            field.selection = FieldRange(location: 15, length: 0)
        }
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        field.focusedElement = 1
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        field.webAreaRoleUnanswered = false
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
        #expect(dictation.history.entries.map(\.outcome) == [.notInserted, .notInserted, .uncertain])
        #expect(dictation.history.entries.prefix(2).map(\.text) == ["second", "other"])
        #expect(refused.map(\.0) == [.earlierUnsettledNearby, .earlierUnsettledNearby])
        #expect(refused.map(\.1) == ["other", "second"])
        field.land()
        #expect(field.text == "keep first keep")
    }

    @Test func wordsStayInHistoryWhenAMovedWebTabBecomesAnUnlistedTarget() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "first", text: "first"),
                                               .answer(transcript: "second", text: "second")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        field.web = true
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        field.writes = .held
        var refused: [(EditReason, String)] = []
        dictation.notInserted = { refused.append(($0, $1)) }
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        field.writes = .apply
        field.objectGeneration += 1
        field.windowGeneration = 1
        // Capture the second dictation's field while it is still readable,
        // then lose the container role before its insertion checks.
        dictation.toggle()
        await speak()
        field.containerRoleFails = true
        dictation.toggle()
        await idle(dictation)
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
        #expect(field.text == "keep old keep")
        #expect(dictation.history.entries.map(\.outcome) == [.notInserted, .uncertain])
        #expect(dictation.history.entries.map(\.text) == ["second", "first"])
        #expect(dictation.history.entries.first?.reason == "earlierUnsettledNearby")
        #expect(refused.map(\.0) == [.earlierUnsettledNearby])
        #expect(refused.map(\.1) == ["second"])
        field.land()
        #expect(field.text == "keep first keep")
    }

    @Test(arguments: [("straße", "STRASSE")])
    func wordsAfterCaseFoldingGoIn(_ written: String, _ shown: String) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: written, text: written), .answer(transcript: "second", text: "second")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        field.text = "Note: "
        field.selection = FieldRange(location: 6, length: 0)
        field.reformat = { @Sendable _ in shown }
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        field.reformat = nil
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(field.text == "Note: " + shown + "second")
        #expect(dictation.history.entries.map(\.outcome) == [.inserted, .uncertain])
        #expect(dictation.history.entries.map(\.text) == ["second", written])
    }

    @Test(arguments: [false, true])
    func wordsAfterAShortAutocorrectionStayInHistory(_ web: Bool) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "teh", text: "teh"),
                                               .answer(transcript: "second", text: "second")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        field.web = web
        field.text = "Note: "
        field.selection = FieldRange(location: 6, length: 0)
        field.reformat = { @Sendable _ in "the" }
        var refused: [(EditReason, String)] = []
        dictation.notInserted = { refused.append(($0, $1)) }
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        field.reformat = nil
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(field.text == "Note: the")
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
        #expect(dictation.history.entries.map(\.outcome) == [.notInserted, .uncertain])
        #expect(dictation.history.entries.map(\.text) == ["second", "teh"])
        #expect(dictation.history.entries.first?.reason == "earlierUnsettled")
        #expect(refused.map(\.0) == [.earlierUnsettled])
        #expect(refused.map(\.1) == ["second"])
    }

    @Test(arguments: [("dog", "cat", "car"), ("dogs", "cats", "cars"),
                      ("doggy", "catty", "carty"), ("doggie", "catnap", "carnap"),
                      ("doggies", "catalog", "caralog")], [false, true])
    func wordsStayInHistoryAfterAOneLetterEditWhileAShortWriteIsPending(_ words: (String, String, String), _ web: Bool) async throws {
        let (original, written, edit) = words
        let server = try await ScriptedEndpoint([.answer(transcript: written, text: written),
                                               .answer(transcript: "second", text: "second")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        field.web = web
        field.text = "keep " + original + " keep"
        field.selection = FieldRange(location: 5, length: original.utf16.count)
        field.writes = .held
        let edited = "keep " + edit + " keep"
        field.onEdit = { [field] in field.text = edited }
        var refused: [(EditReason, String)] = []
        dictation.notInserted = { refused.append(($0, $1)) }
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        field.onEdit = nil
        field.writes = .apply
        field.selection = FieldRange(location: 5, length: edit.utf16.count)
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
        #expect(field.text == edited)
        #expect(dictation.history.entries.map(\.outcome) == [.notInserted, .uncertain])
        #expect(dictation.history.entries.map(\.text) == ["second", written])
        #expect(dictation.history.entries.first?.reason == "earlierUnsettled")
        #expect(refused.map(\.0) == [.earlierUnsettled])
        #expect(refused.map(\.1) == ["second"])
        field.land()
        #expect(field.text == "keep " + written + " keep")
    }

    /// Astra's eight-letter ligature sequence must preserve the later
    /// dictation in history and offer Copy while the earlier write can land.
    @Test(arguments: [false, true])
    func wordsStayInHistoryAfterAnEditBeyondTheOriginalLetterBudget(_ web: Bool) async throws {
        let written = "ﬃﬃﬃﬃabcd", edit = "ﬃﬃﬃﬃabxy"
        let server = try await ScriptedEndpoint([.answer(transcript: written, text: written),
                                               .answer(transcript: "second", text: "second")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        field.web = web
        field.text = "keep zzzzzzzz keep"
        field.selection = FieldRange(location: 5, length: 8)
        field.writes = .held
        let edited = "keep " + edit + " keep"
        field.onEdit = { [field] in field.text = edited }
        var refused: [(EditReason, String)] = []
        dictation.notInserted = { refused.append(($0, $1)) }
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        field.onEdit = nil
        field.writes = .apply
        field.selection = FieldRange(location: 5, length: 8)
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
        #expect(field.text == edited)
        #expect(dictation.history.entries.map(\.outcome) == [.notInserted, .uncertain])
        #expect(dictation.history.entries.map(\.text) == ["second", written])
        #expect(dictation.history.entries.first?.reason == "earlierUnsettled")
        #expect(refused.map(\.0) == [.earlierUnsettled])
        #expect(refused.map(\.1) == ["second"])
        field.land()
        #expect(field.text == "keep " + written + " keep")
    }

    /// The next dictation stays in history with Copy when a separate edit
    /// of the old selection resembles the pending replacement.
    @Test(arguments: [("Straße beim Laden", "Straße beim Hafen", "Straße beim Haden"),
                      ("Strase beim Laden", "Strase beim Hafen", "Strase beim Haden"),
                      ("Street by the ladxer", "Street by the harbor", "Street by the hadxor"),
                      ("ﬃﬃﬃﬃabxy", "ﬃﬃﬃﬃabcd", "ﬃﬃﬃﬃabcy")], [false, true])
    func wordsStayInHistoryAfterANearbySelectionEdit(_ words: (String, String, String), _ web: Bool) async throws {
        let (original, written, edit) = words
        let server = try await ScriptedEndpoint([.answer(transcript: written, text: written),
                                               .answer(transcript: "second", text: "second")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        field.web = web
        let tail = " keep" + String(repeating: "k", count: 32)
        field.text = "keep " + original + tail
        field.selection = FieldRange(location: 5, length: original.utf16.count)
        field.writes = .held
        let edited = "keep " + edit + tail
        field.onEdit = { [field] in field.text = edited }
        var refused: [(EditReason, String)] = []
        dictation.notInserted = { refused.append(($0, $1)) }
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        field.onEdit = nil
        field.writes = .apply
        field.selection = FieldRange(location: 5, length: edit.utf16.count)
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
        #expect(field.text == edited)
        #expect(dictation.history.entries.map(\.outcome) == [.notInserted, .uncertain])
        #expect(dictation.history.entries.map(\.text) == ["second", written])
        #expect(dictation.history.entries.first?.reason == "earlierUnsettled")
        #expect(refused.map(\.0) == [.earlierUnsettled])
        #expect(refused.map(\.1) == ["second"])
        field.land()
        #expect(field.text == "keep " + written + tail)
    }

    /// A rich editor capitalizes a sentence as it goes in, so the first
    /// dictation's readback does not match and it stays uncertain in
    /// history. Its words stand at their place in another form, so the
    /// next dictation into the same field goes in.
    @Test func wordsAfterADictationAnEditorReformattedGoIn() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "first", text: "first."), .answer(transcript: "second", text: "Second.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        field.reformat = { @Sendable text in text.prefix(1).uppercased() + text.dropFirst() }
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(field.text == "aFirst.bc")
        #expect(dictation.history.entries.map(\.outcome) == [.uncertain])
        #expect(dictation.history.entries.first?.reason == "readbackMismatch")
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(field.accessibilityWrites == 2)
        #expect(field.text.contains("Second."))
        #expect(dictation.history.entries.map(\.outcome) == [.inserted, .uncertain])
    }

    /// An earlier dictation that fails, is refused or is cancelled ends,
    /// and the one waiting on it goes in.
    @Test(arguments: ["failed", "refused", "cancelled"])
    func anEarlierDictationEndingWithoutItsTextLetsTheWaitingOneGoIn(_ ending: String) async throws {
        let server = try await ScriptedEndpoint([
            ending == "failed" ? .refuseLate(after: 0.8, reason: "too_long") : ending == "cancelled" ? .silent
                : .answerLate(after: 0.8, transcript: "first", text: "First."),
            .answer(transcript: "second", text: "Second."),
        ])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        var insertions = 0
        dictation.didInsert = { _ in insertions += 1 }
        dictation.toggle()
        await speak()
        dictation.toggle()
        dictation.toggle()
        await speak()
        dictation.toggle()
        if ending == "cancelled" {
            // The first endpoint is silent. One accepted text therefore belongs
            // to the second dictation, before sign-out decides either outcome.
            await waitUntil { dictation.pendingTextCount == 1 }
            try #require(dictation.pendingTextCount == 1)
        } else {
            await waitUntil { server.connections.count == 2 && server.connections[1].answered }
        }
        #expect(dictation.history.entries.isEmpty)
        switch ending {
        case "refused": refuseNextInsertion()
        // A sign-out drops the first, whose words have not come back, and
        // leaves the second's, which have.
        case "cancelled": dictation.accountChanged(signedIn: false)
        default: break
        }
        await idle(dictation)
        #expect(field.text == "a Second.bc")
        let entries = dictation.history.entries
        #expect(entries.first?.text == " Second.")
        #expect(entries.first?.outcome == .inserted)
        switch ending {
        case "failed": #expect(entries.map(\.outcome) == [.inserted, .failed])
        case "refused": #expect(entries.dropFirst().map(\.reason) == ["noTextField"])
        default:
            #expect(entries.count == 1)
            #expect(field.accessibilityWrites == 1)
            // Sign-out suppresses the account-scoped callback, even though
            // text accepted before sign-out still inserts and enters history.
            #expect(insertions == 0)
        }
    }

    /// Neither endpoint answers, so signing out precedes accepted text in both
    /// dictations and cannot leave an insertion or a history entry behind.
    @Test func signingOutBeforeEitherOverlappingTranscriptIsAccepted() async throws {
        let server = try await ScriptedEndpoint([.silent, .silent])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        var insertions = 0
        dictation.didInsert = { _ in insertions += 1 }
        dictation.toggle()
        await speak()
        dictation.toggle()
        dictation.toggle()
        await speak()
        dictation.toggle()
        await waitUntil {
            let connections = server.connections
            return connections.count == 2 && connections.allSatisfy { $0.stopFrames != nil }
        }
        try #require(dictation.pendingTextCount == 0)
        dictation.accountChanged(signedIn: false)
        await idle(dictation)
        #expect(dictation.pendingTextCount == 0)
        #expect(field.text == "abc")
        #expect(field.accessibilityWrites == 0)
        #expect(dictation.history.entries.isEmpty)
        #expect(insertions == 0)
    }

    /// Silence from an earlier dictation while the next one records keeps
    /// the recording's controls and voice. The notice waits for the stop,
    /// shows for its time, and the foot then shows the phase dictation is
    /// in, not rest.
    @Test func anEarlierDictationsSilenceWaitsForTheRecordingAndGivesTheFootBackToTheCurrentPhase() async throws {
        let server = try await ScriptedEndpoint([
            .answerLate(after: 0.3, transcript: "", text: ""), .answerLate(after: 1, transcript: "second", text: "Second."),
        ])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        let timer = NoticeTimer()
        let foot = foot(for: dictation, noticeWait: timer.wait)
        var refused = 0
        dictation.notInserted = { _, _ in refused += 1 }
        dictation.toggle()
        await speak()
        dictation.toggle()
        dictation.toggle()
        await waitUntil { server.connections.first?.answered == true }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(dictation.phase == .recording)
        #expect(foot.presentation == .listening)
        #expect(!foot.showsNotice)
        dictation.toggle()
        #expect(foot.state == .heardNoWords)
        await timer.untilWaiting()
        timer.end()
        await foot.noticeEnds?.value
        #expect(foot.presentation == .writing)
        await idle(dictation)
        #expect(foot.state == .resting)
        #expect(field.text == "a Second.bc")
        #expect(refused == 0)
    }

    /// A not-inserted popup from an earlier dictation waits for the
    /// recording to stop, then comes.
    @Test func anEarlierDictationsPopupWaitsForTheRecordingToStop() async throws {
        let server = try await ScriptedEndpoint([
            .answerLate(after: 0.5, transcript: "first", text: "First."), .answerLate(after: 1, transcript: "second", text: "Second."),
        ])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        let foot = foot(for: dictation)
        var refused: [String] = []
        dictation.notInserted = { refused.append($1) }
        dictation.toggle()
        await speak()
        dictation.toggle()
        dictation.toggle()
        await speak()
        refuseNextInsertion()
        await waitUntil { dictation.history.entries.count == 1 }
        #expect(dictation.history.entries.first?.reason == "noTextField")
        #expect(refused.isEmpty)
        #expect(foot.presentation == .listening)
        dictation.toggle()
        #expect(refused == ["First."])
        await idle(dictation)
        #expect(field.text == "a Second.bc")
    }

    /// The notice of an earlier dictation that pasted and could not put
    /// the clipboard back waits for the recording to stop, then shows in
    /// the foot while the later one's text is on its way, as it shows
    /// beside the dot.
    @Test func anEarlierDictationsNoticeWaitsForTheRecordingThenShowsWhileTheNextTextIsOnItsWay() async throws {
        let server = try await ScriptedEndpoint([
            .answerLate(after: 0.3, transcript: "first", text: "First."), .answerLate(after: 1, transcript: "second", text: "Second."),
        ])
        defer { server.stop() }
        let dictation = controller(server.endpoint, clipboardReadable: false)
        // Refused writes are pasted, and the clipboard cannot be read to
        // put it back.
        field.writes = .refuse
        let foot = foot(for: dictation)
        dictation.toggle()
        await speak()
        dictation.toggle()
        dictation.toggle()
        await waitUntil { dictation.history.entries.count == 1 }
        #expect(dictation.history.entries.first?.outcome == .inserted)
        #expect(dictation.phase == .recording)
        #expect(dictation.notice == nil)
        #expect(foot.presentation == .listening)
        dictation.toggle()
        #expect(dictation.notice == .clipboardReplaced)
        #expect(foot.state == .notice(DictationController.Notice.clipboardReplaced.text))
        await idle(dictation)
        #expect(field.text == "aFirst. Second.bc")
    }

    /// Two earlier dictations end while a third records: one heard no
    /// words and one could not go in. Once the recording stops each is
    /// said in turn, the second only once the first has had its time, so
    /// neither replaces the other at once.
    @Test func whatTwoEarlierDictationsHaveToSayComesInTurnOnceTheRecordingStops() async throws {
        let server = try await ScriptedEndpoint([
            .answerLate(after: 0.6, transcript: "", text: ""), .answer(transcript: "second", text: "Second."),
            .answer(transcript: "third", text: "Third."),
        ])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        let foot = foot(for: dictation)
        let (steps, step) = AsyncStream<Void>.makeStream()
        var pauses = 0
        dictation.noticePause = {
            pauses += 1
            for await _ in steps { return }
        }
        var refused: [String] = []
        dictation.notInserted = { refused.append($1) }
        for _ in 0..<2 {
            dictation.toggle()
            await speak()
            dictation.toggle()
        }
        dictation.toggle()
        await speak()
        refuseNextInsertion()
        await waitUntil { dictation.history.entries.count == 1 }
        #expect(dictation.history.entries.first?.reason == "noTextField")
        #expect(dictation.phase == .recording)
        #expect(foot.presentation == .listening)
        dictation.toggle()
        // The silence first, for its time; the popup waits, and the app
        // is not quiet until it has been shown.
        #expect(foot.state == .heardNoWords)
        #expect(refused.isEmpty)
        #expect(dictation.hasMoreToSay)
        await waitUntil { pauses == 1 }
        #expect(refused.isEmpty)
        step.yield()
        await waitUntil { refused == ["Second."] }
        // The popup has its own time, and then nothing is left to say.
        #expect(dictation.hasMoreToSay)
        await waitUntil { pauses == 2 }
        step.yield()
        await waitUntil { !dictation.hasMoreToSay }
        await idle(dictation)
        #expect(field.text == "a Third.bc")
    }

    /// Two dictations on their way and none recording: the first finds no
    /// field, and its popup is said with nothing waiting behind it; the
    /// second's paste could not put the clipboard back, which it says a
    /// moment later. The notice waits out the popup's whole time, then
    /// shows for its own, and until that has passed too something is still
    /// being said, so an update does not relaunch over it (#328).
    @Test func aPopupSaidWithNothingBehindItKeepsItsTimeWhenTheNextDictationsNoticeComes() async throws {
        let server = try await ScriptedEndpoint([
            .answerLate(after: 0.5, transcript: "first", text: "First."), .answer(transcript: "second", text: "Second."),
        ])
        defer { server.stop() }
        let dictation = controller(server.endpoint, clipboardReadable: false)
        // Refused writes are pasted, and the clipboard cannot be read to
        // put it back.
        field.writes = .refuse
        let timer = NoticeTimer()
        dictation.noticePause = { try? await timer.wait(DictationController.noticeDuration) }
        var refused: [String] = []
        dictation.notInserted = { refused.append($1) }
        for _ in 0..<2 {
            dictation.toggle()
            await speak()
            dictation.toggle()
        }
        refuseNextInsertion()
        await idle(dictation)
        #expect(refused == ["First."])
        #expect(field.text == "a Second.bc")
        // The popup still has its time: the second's notice waits.
        #expect(dictation.notice == nil)
        #expect(dictation.hasMoreToSay)
        await waitUntil { timer.asked.count == 1 }
        timer.end()
        await waitUntil { dictation.notice == .clipboardReplaced }
        #expect(dictation.hasMoreToSay)
        // The notice's own time, for the notice beside the dot and for
        // what is said after it.
        await waitUntil { timer.asked.count == 3 }
        timer.end()
        await waitUntil { dictation.notice == nil && !dictation.hasMoreToSay }
        #expect(refused == ["First."])
    }

    /// A dictation starts recording at once while the last one's notice
    /// still has its time, and takes the notice away as before, and that
    /// time with it: what the new dictation has to say comes as soon as it
    /// is ready, without waiting out the rest of a notice no longer shown,
    /// and then has its own whole time.
    @Test func aRecordingStartedDuringANoticesTimeTakesTheNoticeAndItsTimeAway() async throws {
        let server = try await ScriptedEndpoint([
            .answer(transcript: "first", text: "First."), .answer(transcript: "second", text: "Second."),
        ])
        defer { server.stop() }
        let source = ScriptedSource()
        let dictation = controller(server.endpoint, source: source, clipboardReadable: false)
        field.writes = .refuse
        let timer = NoticeTimer()
        dictation.noticePause = { try? await timer.wait(DictationController.noticeDuration) }
        var refused: [String] = []
        dictation.notInserted = { refused.append($1) }
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(dictation.notice == .clipboardReplaced)
        #expect(dictation.hasMoreToSay)
        dictation.toggle()
        #expect(dictation.phase == .recording)
        #expect(source.running)
        #expect(dictation.notice == nil)
        #expect(!dictation.hasMoreToSay)
        await speak()
        refuseNextInsertion()
        dictation.toggle()
        await idle(dictation)
        #expect(refused == ["Second."])
        #expect(dictation.hasMoreToSay)
        // The first notice has two waits; the second popup has one.
        // End their time only after the new saying task registered its wait.
        await waitUntil { timer.asked.count == 3 }
        timer.end()
        await waitUntil { !dictation.hasMoreToSay }
        #expect(field.text == "aFirst.bc")
    }

    /// The app is told once, when the last of two things said in turn has
    /// had its time, and not between them: a waiting update that the
    /// indicators' own ends found still held back is tried again then,
    /// rather than waiting for the next dictation.
    @Test func theAppHearsOnceWhenTheLastThingSaidHasHadItsTime() async throws {
        let server = try await ScriptedEndpoint([
            .answerLate(after: 0.5, transcript: "first", text: "First."), .answer(transcript: "second", text: "Second."),
        ])
        defer { server.stop() }
        let dictation = controller(server.endpoint, clipboardReadable: false)
        field.writes = .refuse
        let timer = NoticeTimer()
        dictation.noticePause = { try? await timer.wait(DictationController.noticeDuration) }
        var quiet: [Bool] = []
        dictation.doneSaying = { quiet.append(dictation.hasMoreToSay) }
        for _ in 0..<2 {
            dictation.toggle()
            await speak()
            dictation.toggle()
        }
        refuseNextInsertion()
        await idle(dictation)
        await waitUntil { timer.asked.count == 1 }
        timer.end()
        await waitUntil { dictation.notice == .clipboardReplaced }
        #expect(quiet.isEmpty)
        await waitUntil { timer.asked.count == 3 }
        timer.end()
        await waitUntil { !quiet.isEmpty }
        #expect(quiet == [false])
    }
}

/// Counts calls from any thread, from one.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func next() -> Int { lock.withLock { calls += 1; return calls } }
    var count: Int { lock.withLock { calls } }
}

/// When each call came, from any thread.
final class Stamps: @unchecked Sendable {
    private let lock = NSLock()
    private var stamps: [ContinuousClock.Instant] = []

    /// Notes now and returns how many there are.
    func add() -> Int { lock.withLock { stamps.append(.now); return stamps.count } }
    var all: [ContinuousClock.Instant] { lock.withLock { stamps } }
    var count: Int { all.count }
}

/// A switch a scenario turns on once, read from any thread.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false

    func set() { lock.withLock { on = true } }
    var isSet: Bool { lock.withLock { on } }
}
