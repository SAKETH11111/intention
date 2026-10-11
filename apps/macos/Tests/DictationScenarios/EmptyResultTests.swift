import AppKit
@testable import Dictation
import Testing

/// A dictation the endpoint found no words in. After real sound it keeps
/// its audio for Retry as a failed one does, and whatever it was, the
/// person is told which microphone it recorded from. The scenarios extend
/// the dictation suite so that everything touching the scripted field runs
/// in one serialized line.
extension DictationScenarioTests {
    /// The made-up microphone these dictations record from.
    static let headset = "Studio Headset"

    /// 1.2 seconds of speech-loud audio from the headset: 12 chunks at the
    /// start and a partial one at the stop, its loudest sample about -11
    /// dBFS, none of it exactly zero.
    func spokenIntoHeadset() -> ScriptedSource {
        ScriptedSource(chunks: 12, level: 9_000, device: Self.headset)
    }

    private func until(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }

    /// On October 8, 2026 the endpoint found no words in five of Alex's
    /// dictations, one of them 114.6 seconds long, recorded from earbuds
    /// he was not speaking into, and each was gone. Now one with real
    /// sound in it waits in history with its audio, the popup offers Retry
    /// and another microphone and names the one it recorded from, and
    /// Retry sends the same audio again.
    @Test func anEmptyAnswerAfterRealSoundKeepsItsAudioForRetryAndNamesTheMicrophone() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "", text: ""), .answer(transcript: "hello there", text: "Hello there.")])
        defer { server.stop() }
        let source = spokenIntoHeadset()
        let dictation = controller(server.endpoint, source: source)
        var popups: [DictationController.EmptyResult] = []
        let foot = foot(for: dictation, popup: { popups.append($0) })
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(field.text == "abc")
        let kept = try #require(dictation.history.entries.first)
        #expect(kept.outcome == .failed)
        #expect(kept.reason == "noWords")
        #expect(kept.text.isEmpty)
        #expect(kept.device == Self.headset)
        #expect(dictation.history.needsAttention)
        #expect(dictation.history.retry(for: kept.id)?.chunks.count == source.sent)
        // The popup, not the one-line notice, since there is something to do.
        #expect(popups == [.init(silence: .words, device: Self.headset, retry: kept.id, actionable: true)])
        #expect(!foot.showsNotice)
        #expect(popups.first.map(FootState.words(for:)) == "Heard no words from Studio Headset")

        dictation.retry(kept.id)
        #expect(dictation.phase == .processing)
        await idle(dictation)
        // The same recording went out again, every chunk of it.
        #expect(server.connections.count == 2)
        #expect(server.connections.last?.frames == source.sent)
        #expect(server.connections.last?.stopFrames == source.sent)
        let recovered = try #require(dictation.history.entries.first)
        #expect(recovered.id == kept.id)
        #expect(recovered.text == "Hello there.")
        #expect(recovered.outcome == .notInserted)
        #expect(recovered.reason == "retried")
        #expect(dictation.history.retry(for: kept.id) == nil)
        // A retry is never inserted.
        #expect(field.text == "abc")
    }

    /// A retry that comes back with no words again leaves the entry as it
    /// was, ready to retry, rather than marking it recovered.
    @Test func aRetryThatHearsNoWordsAgainStaysReadyToRetry() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "", text: "")])
        defer { server.stop() }
        let dictation = controller(server.endpoint, source: spokenIntoHeadset())
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        let kept = try #require(dictation.history.entries.first)
        dictation.retry(kept.id)
        await idle(dictation)
        #expect(server.connections.count == 2)
        let again = try #require(dictation.history.entries.first)
        #expect(again.outcome == .failed)
        #expect(again.reason == "noWords")
        #expect(again.device == Self.headset)
        #expect(dictation.history.retry(for: kept.id) != nil)
    }

    /// A tap, a short press with nothing said in a quiet room, or anything
    /// shorter than a second, or quieter than speech and shorter than five
    /// seconds: nothing to hear again, so history keeps no row and no
    /// audio, and the indicator says so in one line that still names the
    /// microphone.
    @Test(arguments: [("a click on and off", 3, Int16(9_000)), ("a quiet press", 12, Int16(257)),
                      ("a long quiet press", 40, Int16(1_000))])
    func anEmptyAnswerAfterATapOrNearSilenceKeepsNothing(_ what: String, chunks: Int, level: Int16) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "", text: "")])
        defer { server.stop() }
        let dictation = controller(server.endpoint, source: ScriptedSource(chunks: chunks, level: level, device: Self.headset))
        var said: [DictationController.EmptyResult] = []
        var popups = 0
        let foot = foot(for: dictation, popup: { _ in popups += 1 })
        // Noted on its way to the indicators' own wiring.
        let wired = dictation.silent
        dictation.silent = { empty in
            said.append(empty)
            wired?(empty)
        }
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(field.text == "abc", "\(what)")
        #expect(dictation.history.entries.isEmpty, "\(what)")
        #expect(!dictation.history.needsAttention, "\(what)")
        #expect(said == [.init(silence: .words, device: Self.headset, retry: nil, actionable: false)], "\(what)")
        #expect(popups == 0, "\(what)")
        #expect(foot.state == .notice("Heard no words from Studio Headset"), "\(what)")
    }

    /// With the lid closed on the only microphone nothing opens and no audio
    /// comes at all, however long the key is held: a second or more of
    /// recording still offers another microphone.
    @Test func aRecordingThatGetsNoAudioForASecondOffersAnotherMicrophone() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "", text: "")])
        defer { server.stop() }
        // No chunk while it records, and silence in the one it hands on at the
        // stop: nothing reached the microphone.
        let dictation = controller(server.endpoint, source: ScriptedSource(chunks: 0, level: 0))
        var popups: [DictationController.EmptyResult] = []
        _ = foot(for: dictation, popup: { popups.append($0) })
        var said: [DictationController.EmptyResult] = []
        let wired = dictation.silent
        dictation.silent = { said.append($0); wired?($0) }
        dictation.toggle()
        #expect(dictation.phase == .recording)
        try await Task.sleep(for: .milliseconds(1_100))
        dictation.toggle()
        await idle(dictation)
        #expect(dictation.history.entries.isEmpty)
        #expect(said == [.init(silence: .microphone, device: nil, retry: nil, actionable: true)])
        #expect(popups == [.init(silence: .microphone, device: nil, retry: nil, actionable: true)])
    }

    /// A recognizer that heard only fillers, which the endpoint cleans to
    /// nothing on purpose, heard the person: nothing is kept for Retry,
    /// which would be cleaned away again, and nothing suggests another
    /// microphone, however loud or long the recording.
    @Test(arguments: [("a loud um", 13, Int16(9_000)), ("a long um", 60, Int16(9_000))])
    func fillersTheEndpointCleanedAwayAreNotKeptForRetry(_ what: String, chunks: Int, level: Int16) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "Um.", text: "")])
        defer { server.stop() }
        let dictation = controller(server.endpoint, source: ScriptedSource(chunks: chunks, level: level, device: Self.headset))
        var popups = 0
        _ = foot(for: dictation, popup: { _ in popups += 1 })
        var said: [DictationController.EmptyResult] = []
        let wired = dictation.silent
        dictation.silent = { empty in
            said.append(empty)
            wired?(empty)
        }
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(dictation.history.entries.isEmpty, "\(what)")
        #expect(said == [.init(silence: .words, device: Self.headset, retry: nil, actionable: false)], "\(what)")
        #expect(popups == 0, "\(what)")
    }

    /// Speech from earbuds away from the mouth arrives at about -60 dBFS
    /// under the room's noise, and the recognizer finds no words in it,
    /// over 114.6 seconds as over five: the case of October 8. Too faint to
    /// be worth sending again, and too long to be a press with nothing
    /// said, so the popup names the microphone and offers another, with no
    /// Retry and no history entry. Just under five seconds stays a press.
    @Test(arguments: [(50, Int16(40), true), (60, Int16(1_000), true), (49, Int16(40), false)])
    func aLongFaintCaptureNamesTheMicrophoneAndOffersAnother(chunks: Int, level: Int16, offered: Bool) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "", text: "")])
        defer { server.stop() }
        let source = ScriptedSource(chunks: chunks, level: level, device: Self.headset)
        let dictation = controller(server.endpoint, source: source)
        var popups: [DictationController.EmptyResult] = []
        let foot = foot(for: dictation, popup: { popups.append($0) })
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        // The endpoint was asked: it is faint, not silent.
        #expect(server.connections.first?.stopFrames == source.sent)
        #expect(field.text == "abc")
        #expect(dictation.history.entries.isEmpty)
        if offered {
            #expect(popups == [.init(silence: .words, device: Self.headset, retry: nil, actionable: true)])
            #expect(!foot.showsNotice)
        } else {
            #expect(popups.isEmpty)
            #expect(foot.state == .notice("Heard no words from Studio Headset"))
        }
    }

    /// A capture of nearly all zeros, and one with no sound at all, are
    /// what a wrong or failed input sends. Sending them again finds nothing
    /// more, so neither waits in history, but the popup names the
    /// microphone and offers another.
    @Test(arguments: [(DictationController.Silence.nearlyNothing, 95, Int16(9_000), "Almost no sound from Studio Headset"),
                      (.microphone, 0, Int16(0), "No sound from Studio Headset")])
    func aMostlyZeroOrSilentCaptureNamesTheMicrophoneAndOffersNoRetry(_ silence: DictationController.Silence, zeros: Int,
                                                                       level: Int16, words: String) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "", text: "")])
        defer { server.stop() }
        let dictation = controller(server.endpoint, source: ScriptedSource(chunks: 12, level: level, zeros: zeros, device: Self.headset))
        var popups: [DictationController.EmptyResult] = []
        let foot = foot(for: dictation, popup: { popups.append($0) })
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(field.text == "abc")
        #expect(dictation.history.entries.isEmpty)
        #expect(popups == [.init(silence: silence, device: Self.headset, retry: nil, actionable: true)])
        #expect(!foot.showsNotice)
        #expect(popups.first.map(FootState.words(for:)) == words)
    }

    /// Without a microphone's name, as from a recording played in its
    /// place, the words are those Intention has always used.
    @Test func withoutANameTheNoticeSaysWhatItAlwaysHas() {
        func words(_ silence: DictationController.Silence) -> String {
            FootState.words(for: .init(silence: silence, device: nil, retry: nil, actionable: false))
        }
        #expect(words(.microphone) == "Intention heard nothing from your microphone")
        #expect(words(.nearlyNothing) == "Your microphone sent almost nothing")
        #expect(words(.words) == "Intention heard no words")
    }

    /// The recording's microphone went away mid-dictation and it moved to
    /// the built-in one: the notice names the microphone it ended on.
    @Test func theNoticeNamesTheMicrophoneTheRecordingMovedTo() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "", text: "")])
        defer { server.stop() }
        let hardware = StandInHardware(MadeUpInputs.inputs([MadeUpInputs.builtIn, MadeUpInputs.usb], default: MadeUpInputs.usb))
        let microphone = Microphone(preference: { .device(uid: MadeUpInputs.usb.uid, name: "USB Microphone") }, hardware: hardware)
        let dictation = controller(server.endpoint, source: microphone)
        var said: [DictationController.EmptyResult] = []
        dictation.silent = { said.append($0) }
        dictation.toggle()
        hardware.current?.speak()
        hardware.change { $0 = MadeUpInputs.inputs([MadeUpInputs.builtIn], default: MadeUpInputs.builtIn) }
        hardware.current?.speak()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(hardware.opened.map(\.name) == ["USB Microphone", "MacBook Pro Microphone"])
        #expect(said.map(\.device) == ["MacBook Pro Microphone"])
        #expect(said.first.map(FootState.words(for:)) == "Heard no words from MacBook Pro Microphone")
    }

    /// A microphone's name can identify the person. It reaches their own
    /// notice and history on this Mac, and no log line or anything sent to
    /// the endpoint, the retry's connection included.
    @Test func theMicrophonesNameIsNeverLoggedOrSent() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "", text: "")])
        defer { server.stop() }
        let dictation = controller(server.endpoint, source: spokenIntoHeadset())
        var said: [DictationController.EmptyResult] = []
        dictation.silent = { said.append($0) }
        let logged = AppLog.dictationLines.all.count
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        let kept = try #require(dictation.history.entries.first)
        dictation.retry(kept.id)
        await idle(dictation)
        // Shown to the person: the name did reach the notice and history.
        #expect(said.first?.device == Self.headset)
        #expect(dictation.history.entries.first?.device == Self.headset)
        let lines = AppLog.dictationLines.all.dropFirst(logged)
        #expect(lines.contains("dictation silent.words.kept"))
        #expect(!lines.contains { $0.localizedCaseInsensitiveContains("headset") || $0.localizedCaseInsensitiveContains("studio") })
        #expect(server.connections.count == 2)
        for connection in server.connections {
            let start = try JSONSerialization.data(withJSONObject: connection.start)
            #expect(!String(decoding: start, as: UTF8.self).localizedCaseInsensitiveContains("headset"))
        }
    }

    /// An earlier dictation's empty answer, kept for Retry, ends while the
    /// next one records: its popup waits until the recording stops, so it
    /// never covers the recording's controls, then comes.
    @Test func anEarlierDictationsRetryWaitsForTheRecordingToStop() async throws {
        let server = try await ScriptedEndpoint([
            .answerLate(after: 0.3, transcript: "", text: ""), .answerLate(after: 1, transcript: "second", text: "Second."),
        ])
        defer { server.stop() }
        let dictation = controller(server.endpoint, source: spokenIntoHeadset())
        var popups: [DictationController.EmptyResult] = []
        let foot = foot(for: dictation, popup: { popups.append($0) })
        dictation.toggle()
        await speak()
        dictation.toggle()
        dictation.toggle()
        await until { dictation.history.entries.first?.reason == "noWords" }
        let kept = try #require(dictation.history.entries.first)
        #expect(dictation.phase == .recording)
        #expect(foot.presentation == .listening)
        #expect(popups.isEmpty)
        #expect(dictation.hasMoreToSay)
        dictation.toggle()
        #expect(popups == [.init(silence: .words, device: Self.headset, retry: kept.id, actionable: true)])
        await idle(dictation)
        #expect(field.text.contains("Second."))
    }

    /// Setup's own page shows its silence itself and history keeps no row
    /// for it, whatever sound came, as before.
    @Test func anEmptyAnswerAfterRealSoundOnSetupsPageStaysThatPages() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "", text: "")])
        defer { server.stop() }
        let dictation = controller(server.endpoint, source: spokenIntoHeadset())
        dictation.isForSetup = { true }
        field.focused = false
        var said = 0
        dictation.silent = { _ in said += 1 }
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(dictation.setupSilence != nil)
        #expect(dictation.history.entries.isEmpty)
        #expect(said == 0)
    }
}

/// What counts as real sound for keeping an empty answer.
@Suite struct EmptyResultRuleTests {
    @Test func onlyASecondOrMoreOfSpeechLoudAudioIsWorthRetrying() {
        let speech = DictationController.speechPeak
        // The October 8 dictation: almost two minutes, loud, a headset that
        // mutes itself between words.
        #expect(DictationController.worthRetrying(seconds: 114.6, peak: 4_000, zeroShare: 0.69))
        #expect(DictationController.worthRetrying(seconds: 1, peak: speech, zeroShare: 0))
        // A click on and off again.
        #expect(!DictationController.worthRetrying(seconds: 0.99, peak: 9_000, zeroShare: 0))
        // Nothing said in a quiet room: the microphone's hiss alone.
        #expect(!DictationController.worthRetrying(seconds: 30, peak: speech - 1, zeroShare: 0))
        // A capture of almost nothing but zeros.
        #expect(!DictationController.worthRetrying(seconds: 30, peak: 9_000, zeroShare: DictationController.mostlyZero))
    }
}
