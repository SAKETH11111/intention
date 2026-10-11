import AppKit
@testable import Dictation
import Testing

/// What setup's last page is told about dictation, read through the real
/// controller and history. No key is watched: `HoldKey` is only named.
/// Shares the scenarios' serialized suite, since both drive the one
/// scripted field.
extension DictationScenarioTests {
    private func setupController(_ endpoint: DictationEndpoint?, source: SpeechAudioSource = ScriptedSource(),
                                 signedIn: Bool = true) -> DictationController {
        MockField.reset()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("co.intention.tests.\(UUID().uuidString)"))
        MockField.shared.pasteboard = pasteboard
        let inserter = TextInserter(pasteboard: PasteboardOwner(pasteboard: pasteboard, mayRead: { true }))
        return DictationController(inserter: inserter, history: DictationHistory(file: nil), endpoint: endpoint,
                                   source: source, signedIn: signedIn)
    }

    /// A microphone that will not open.
    @MainActor
    private final class ClosedMicrophone: SpeechAudioSource {
        var failure = Microphone.Failure.unavailable
        func start(audio: @escaping @Sendable (Data) -> Void, interrupted: @escaping @MainActor () -> Void,
                   device: @escaping @MainActor (String) -> Void) throws {
            throw failure
        }
        func stop() {}
    }

    private func settled(_ controller: DictationController) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while controller.phase != .idle, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        // A try that never ends fails here, in place of the next toggle
        // doing nothing and a later expectation misreading it.
        #expect(controller.phase == .idle)
    }

    @Test func practiceInsertionKeepsAcceptedRequestAndAccountOfItsAnswer() async throws {
        let route = ScriptedRoute(text: "Answer")
        route.onCreate = .complete
        let writer = EmailWriter(drafts: route, signedIn: true)
        var scope = "first-account"
        writer.retentionScope = { scope }
        var recorded: [(UUID, String, String?)] = []
        writer.recordInsertion = { recorded.append(($0, $1, $2)) }
        let practice = PracticeReply.of(writer)
        let first = Date(timeIntervalSince1970: 1)
        let second = Date(timeIntervalSince1970: 2)
        _ = await practice.write("first cue", nil, first)
        let firstID = try #require(writer.lastAcceptedRequestID)
        scope = "second-account"
        _ = await practice.write("second cue", nil, second)
        let secondID = try #require(writer.lastAcceptedRequestID)
        #expect(firstID != secondID)
        practice.inserted("Old answer", first)
        practice.inserted("New answer", second)
        #expect(recorded.count == 2)
        #expect(recorded.first?.0 == firstID)
        #expect(recorded.first?.2 == "first-account")
        #expect(recorded.last?.0 == secondID)
        #expect(recorded.last?.2 == "second-account")
    }

    @Test func setupReplyWritesTheSelectedThreadAndKeepsMayaAsTheFallback() async throws {
        let route = ScriptedRoute(text: "Thursday works.")
        route.onCreate = .complete
        let writer = EmailWriter(drafts: route, signedIn: true)
        let practice = PracticeReply.of(writer)
        let thread = AlphaClient.ReplyThread(id: "AAQkAD12+/=", senderName: "Alex Example",
                                           senderAddress: "alex@example.com", subject: "Thursday",
                                           message: "Can we meet Thursday?", sentAt: Date())
        _ = await practice.write("Answer how I would", thread, Date())
        let input = try #require(route.created.last)
        #expect(input.compose.threadID == thread.id)
        #expect(input.compose.subject == thread.subject)
        #expect(input.compose.recipients == [WritingRecipient(address: thread.senderAddress, role: .to)])
        #expect(input.compose.observedThread == "Alex Example wrote:\nCan we meet Thursday?")
        #expect(input.mode == .reply)
        _ = await practice.write("tell her 1 works", nil, Date())
        let fallback = try #require(route.created.last)
        #expect(fallback.compose.threadID == nil)
        #expect(fallback.compose.subject == PracticeReply.Message.subject)
        #expect(fallback.compose.observedThread == PracticeReply.Message.thread)
        #expect(fallback.compose.recipients == [WritingRecipient(address: PracticeReply.Message.address, role: .to)])
    }

    /// Setup's fields take no new words from the moment quitting begins,
    /// and take them again when the quit is refused.
    @Test func setupKnowsWhenQuittingHasBegunAndWhenItWasRefused() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A file where the queue's folder belongs: the final save fails.
        let blocked = root.appendingPathComponent("queue")
        try Data([1]).write(to: blocked)
        let archive = InteractionArchive(directory: blocked) { _, _, _ in 204 }
        archive.bind(key: "synthetic-key")
        let dictation = setupController(nil)
        dictation.archive = archive
        let page = FirstDictation.of(dictation, key: { .function }, chooseKey: { _ in })
        #expect(!page.isQuitting())
        #expect(!(await dictation.prepareToQuit()))
        #expect(!page.isQuitting())
        try FileManager.default.removeItem(at: blocked)
        #expect(await dictation.prepareToQuit())
        #expect(page.isQuitting())
    }

    /// The shortcut page records with Settings' own recorder, which saves
    /// where Settings saves, and names a held key as its cap reads.
    @Test func theShortcutPageRecordsWithSettingsRecorder() {
        let hold = HoldKey(key: .function, holdDelay: 100)
        var saved: HoldKey.Key?
        let recorder = KeyRecorder(holdKey: hold, notifications: NotificationCenter(), log: { _ in }, save: { saved = $0 })
        let page = FirstDictation.of(setupController(nil), key: { saved ?? .function }, chooseKey: { saved = $0 }, recorder: recorder)
        #expect(!page.recording().isRecording)
        page.startRecording()
        #expect(page.recording().isRecording)
        let option = HoldKey.Modifier.rightOption
        hold.modifiersChanged(HoldKey.Delivery(keyCode: option.keyCode, flags: option.deviceMask | option.family.flag.rawValue, time: 1))
        #expect(page.recording().shown == "right option")
        hold.modifiersChanged(HoldKey.Delivery(keyCode: option.keyCode, flags: 0, time: 1.2))
        #expect(saved == .single(.rightOption))
        #expect(!page.recording().isRecording)
        #expect(page.keyName() == "right option")
        page.startRecording()
        page.cancelRecording()
        #expect(!page.recording().isRecording)
    }

    @Test func thePhaseFollowsTheControllers() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = setupController(server.endpoint)
        let page = FirstDictation.of(dictation, key: { .function }, chooseKey: { _ in })
        #expect(page.phase() == .idle)
        dictation.toggle()
        #expect(page.phase() == .listening)
        try await Task.sleep(for: .milliseconds(150))
        dictation.toggle()
        #expect(page.phase() == .finishing)
        await settled(dictation)
        #expect(page.phase() == .idle)
        #expect(FirstDictation.phase(of: .recording) == .listening)
        #expect(FirstDictation.phase(of: .processing) == .finishing)
    }

    @Test func wordsAMissAndSilenceComeFromTheRealHistoryAndController() async throws {
        // A refusal is retried once by itself, so the miss takes two.
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello."), .refuse("internal"),
                                                 .refuse("internal"), .answer(transcript: "", text: "")])
        defer { server.stop() }
        let dictation = setupController(server.endpoint)
        dictation.isForSetup = { true }
        MockField.shared.focused = false
        let page = FirstDictation.of(dictation, key: { .function }, chooseKey: { _ in })
        #expect(page.latest() == nil)
        #expect(page.missed() == nil)
        #expect(page.silent() == nil)
        for _ in 0..<3 {
            dictation.toggle()
            try await Task.sleep(for: .milliseconds(150))
            dictation.toggle()
            await settled(dictation)
        }
        let latest = try #require(page.latest())
        #expect(latest.text == "Hello.")
        let missed = try #require(page.missed())
        let silent = try #require(page.silent())
        #expect(missed > latest.at)
        #expect(silent > missed)
    }

    @Test func onlyTheMicrophoneKeepsThePageOnItsFirstDictation() {
        #expect(FirstDictation.isMicrophone(.microphoneDenied))
        #expect(FirstDictation.isMicrophone(.microphoneUnavailable))
        #expect(!FirstDictation.isMicrophone(.signedOut))
        #expect(!FirstDictation.isMicrophone(.notConfigured))
        #expect(!FirstDictation.isMicrophone(nil))
        // Signed out: no attempt is offered.
        let signedOut = setupController(nil, signedIn: false)
        let page = FirstDictation.of(signedOut, key: { .function }, chooseKey: { _ in })
        #expect(!page.isAvailable())
        #expect(!page.microphoneFailed())
    }

    @Test func aMicrophoneThatWouldNotOpenKeepsThePageOnItsFirstDictation() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let microphone = ClosedMicrophone()
        let dictation = setupController(server.endpoint, source: microphone)
        let page = FirstDictation.of(dictation, key: { .function }, chooseKey: { _ in })
        #expect(page.isAvailable())
        #expect(!page.microphoneFailed())
        for failure in [Microphone.Failure.unavailable, .permissionDenied] {
            microphone.failure = failure
            dictation.toggle()
            #expect(dictation.phase == .idle)
            // The controller cannot begin an attempt, and the page still
            // keeps its first dictation and says what went wrong.
            #expect(!dictation.available)
            #expect(page.isAvailable())
            #expect(page.microphoneFailed())
        }
    }

    @Test func theKeysAreNamedAsPrintedAndChosenByThatName() {
        // The person's key, as preferences hold it: read each time the
        // page asks, and changed by the page's choice.
        let held = Held()
        let page = FirstDictation.of(setupController(nil), key: { held.key }, chooseKey: { held.key = $0 })
        #expect(page.keyName() == "right option")
        held.key = .function
        #expect(page.keyName() == "fn")
        #expect(page.keyNames() == ["fn", "right option", "right command", "Control + Option", "Control + Command", "Option + Command"])
        page.chooseKey("right command")
        #expect(held.key == .rightCommand)
        #expect(page.keyName() == "right command")
        page.chooseKey("caps lock")
        #expect(held.key == .rightCommand)
        page.chooseKey("Control + Option")
        #expect(held.key == .controlOption)
        #expect(page.keyName() == "Control + Option")
    }

    @MainActor
    private final class Held {
        var key = HoldKey.Key.rightOption
    }

    @Test func aDictationIsSetupsOwnOnlyWithItsWindowInFrontOnTheLastPage() {
        // Setup's reply page says the same words the dot says when the
        // words are typed in place of an email.
        #expect(PracticeReply.typedNotice == DictationController.Notice.typedTranscript(nil).text)
        #expect(FirstDictation.isSetupsOwn(onPracticePage: true, windowHasKeyboard: true))
        #expect(!FirstDictation.isSetupsOwn(onPracticePage: true, windowHasKeyboard: false))
        #expect(!FirstDictation.isSetupsOwn(onPracticePage: false, windowHasKeyboard: true))
        #expect(!FirstDictation.isSetupsOwn(onPracticePage: false, windowHasKeyboard: false))
    }
}
