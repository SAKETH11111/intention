import AppKit
import Testing
@testable import Onboarding

/// The shortcut page, before the first dictation, and the dictation page
/// saying exactly what went wrong with the shortcut or a try.
@MainActor
struct ShortcutSetupTests {
    @MainActor private final class Speech {
        let listener = FnListenerHealth()
        var key = "fn"
        var hasFn: Bool? = true
        var recording = FirstDictation.Recording()
        var recordingStarts = true
        var listenerRetries = 0
        var phase = FirstDictation.Phase.idle
        var missed: Date?
        var silent: Date?
        var silenceWasMicrophone = false
        var microphoneFailed = false
        var microphoneFailedAt: Date?

        var port: FirstDictation {
            FirstDictation(microphoneFailed: { self.microphoneFailed }, microphoneFailedAt: { self.microphoneFailedAt }, keyName: { self.key }, phase: { self.phase }, latest: { nil },
                           missed: { self.missed }, silent: { self.silent }, silenceWasMicrophone: { self.silenceWasMicrophone },
                           keyNames: { ["fn", "right option"] }, chooseKey: { self.key = $0 }, recording: { self.recording },
                           startRecording: { if self.recordingStarts { self.recording = FirstDictation.Recording(isRecording: true) } },
                           cancelRecording: { self.recording = FirstDictation.Recording() },
                           hasFnKey: { self.hasFn }, listener: listener, retryListener: { self.listenerRetries += 1 })
        }
    }

    private func model(_ speech: Speech, defaults: UserDefaults? = nil) -> OnboardingModel {
        let model = OnboardingModel(client: nil, keys: MemoryDeviceKey("synthetic-key"),
                        permissions: SetupPermissions(isGranted: { _ in true }, request: { _ in }),
                        dictation: speech.port,
                        defaults: defaults ?? UserDefaults(suiteName: "ShortcutSetupTests." + UUID().uuidString)!)
        if model.step == .mail { model.continueFromMail() }
        return model
    }

    @Test func theShortcutComesBeforeTheFirstDictationWithFnChosen() {
        let speech = Speech()
        let model = model(speech)
        #expect(model.step == .shortcut)
        #expect(model.holdsFn)
        // Recording goes through the shared recorder, and pressing again stops it.
        model.recordShortcut()
        #expect(model.shortcutRecording.isRecording)
        model.recordShortcut()
        #expect(!model.shortcutRecording.isRecording)
        // Keys recorded elsewhere are the page's too, and fn comes back with one press.
        speech.key = "Control + Option"
        #expect(!model.holdsFn)
        model.recordShortcut()
        model.useFn()
        #expect(!model.shortcutRecording.isRecording)
        #expect(speech.key == "fn")
        // Continuing stops a recording still listening.
        model.recordShortcut()
        model.continueFromShortcut()
        #expect(!model.shortcutRecording.isRecording)
        #expect(model.step == .tryIt)
    }

    @Test func everyWayRecordingFailsIsSaidWithRetryAndNothingWaitsForever() {
        let speech = Speech()
        let model = model(speech)
        model.recordShortcut()
        #expect(model.shortcutProblem == nil)
        // Nothing pressed: said after the wait, and Retry listens afresh.
        model.checkShortcut(at: Date().addingTimeInterval(OnboardingModel.recordingWait - 1))
        #expect(model.shortcutProblem == nil)
        model.checkShortcut(at: Date().addingTimeInterval(OnboardingModel.recordingWait + 1))
        #expect(model.shortcutProblem == .nothingPressed)
        #expect(model.shortcutProblemMessage == "Intention hasn't seen a key yet. Press the keys you want, then let go.")
        model.retryShortcut()
        #expect(model.shortcutProblem == nil)
        #expect(model.shortcutRecording.isRecording)
        // A key held starts the wait again.
        speech.recording.shown = "right option"
        model.checkShortcut(at: Date().addingTimeInterval(OnboardingModel.recordingWait + 1))
        #expect(model.shortcutProblem == nil)
        // Keys that cannot be a shortcut: the recorder's reason.
        speech.recording = FirstDictation.Recording(isRecording: true, refusal: "Hold two different keys, or one key on its own.")
        #expect(model.shortcutProblem == .refused("Hold two different keys, or one key on its own."))
        model.retryShortcut()
        #expect(model.shortcutProblem == nil)
        // A listener that cannot hear is named only once the recorder has
        // heard nothing either, and Retry asks it to recover too.
        speech.listener.update(.failed)
        #expect(model.shortcutProblem == nil)
        model.checkShortcut(at: Date().addingTimeInterval(OnboardingModel.recordingWait + 1))
        #expect(model.shortcutProblem == .listener(.failed))
        #expect(model.shortcutProblemMessage == "Intention can't hear the keyboard. If Retry doesn't help, quit and reopen Intention.")
        model.retryShortcut()
        #expect(speech.listenerRetries == 1)
        speech.listener.update(.checking)
        // A recorder that would not start, as during a dictation.
        model.recordShortcut()
        speech.recordingStarts = false
        model.recordShortcut()
        #expect(model.shortcutProblem == .couldNotStart)
        speech.recordingStarts = true
        model.retryShortcut()
        #expect(model.shortcutProblem == nil)
        #expect(model.shortcutRecording.isRecording)
    }

    /// However the shortcut page is left, an account reset included, the
    /// shared recorder stops taking the keyboard, so sign-in's code field
    /// gets its keys.
    @Test func leavingTheShortcutPageStopsTheRecorder() {
        let speech = Speech()
        let model = model(speech)
        model.recordShortcut()
        #expect(model.shortcutRecording.isRecording)
        model.backendKeyRefused("synthetic-key")
        #expect(model.step == .signIn)
        #expect(!speech.recording.isRecording)
    }

    /// Holding the shortcut on its page presses the caps down from the key
    /// listener alone, with no dictation to cross to the next page.
    @Test func theShortcutPageShowsAHoldWithoutDictating() {
        let speech = Speech()
        speech.listener.update(.live)
        let model = model(speech)
        #expect(model.holdOnlyShows)
        speech.listener.receivedTrigger(down: true, at: 1, date: Date())
        #expect(model.shortcutHeld)
        speech.listener.receivedTrigger(down: false, at: 2, date: Date())
        #expect(!model.shortcutHeld)
        model.continueFromShortcut()
        #expect(!model.holdOnlyShows)
    }

    /// The demo that `--onboarding-demo` records goes through the shortcut
    /// page before its first dictation, rather than stopping there.
    @Test func theDemoMovesFromTheShortcutThroughTheFirstDictation() async {
        let script = OnboardingFixture.Script(wait: { _ in })
        let model = OnboardingModel(client: nil, keys: MemoryDeviceKey("synthetic-key"),
                                    permissions: SetupPermissions(isGranted: { _ in true }, request: { _ in }),
                                    dictation: script.port,
                                    defaults: UserDefaults(suiteName: "ShortcutSetupTests." + UUID().uuidString)!)
        // Mail comes first; the demo connects it before the permissions.
        if model.step == .mail { model.continueFromMail() }
        #expect(model.step == .shortcut)
        await script.firstDictation(model)
        #expect(model.step == .reply)
        #expect(script.latest?.text == OnboardingFixture.demoDictation)
    }

    @Test func aKeyboardWithoutFnLeadsWithRecording() {
        let speech = Speech()
        let model = model(speech)
        model.readKeyboards()
        #expect(!model.leadsWithRecording)
        speech.hasFn = false
        model.readKeyboards()
        #expect(model.leadsWithRecording)
        // A keyboard that could not be read leads with fn, which almost every Mac has.
        speech.hasFn = nil
        model.readKeyboards()
        #expect(!model.leadsWithRecording)
    }

    @Test func aSetupSavedOnTheDictationPageResumesThere() {
        let defaults = UserDefaults(suiteName: "ShortcutSetupTests." + UUID().uuidString)!
        defaults.set("tryIt", forKey: "onboardingStep")
        defaults.set(2, forKey: "onboardingStepOrder")
        #expect(model(Speech(), defaults: defaults).step == .tryIt)
    }

    @Test func theCheckUsesTheChosenShortcutAndNamesAnotherKeyPressed() {
        let speech = Speech()
        speech.key = "right option"
        speech.listener.update(.live)
        let model = model(speech)
        model.continueFromShortcut()
        #expect(model.firstKeyCheck == .waiting)
        #expect(model.firstKeyMessage == "Press right option once to check it")
        speech.listener.receivedOtherKey("fn", date: Date())
        #expect(model.firstKeyCheck == .notSeen(other: "fn"))
        #expect(model.firstKeyMessage == "Intention saw fn, not right option. Hold right option, or change the shortcut.")
        #expect(model.firstKeyFailed)
        // Holding the shortcut is a press on its way.
        speech.phase = .listening
        #expect(model.firstKeyCheck == .waiting)
        speech.phase = .idle
        speech.listener.receivedTrigger(down: true, at: 1, date: Date())
        speech.listener.receivedTrigger(down: false, at: 2, date: Date())
        #expect(model.firstKeyCheck == .works)
        #expect(model.firstKeyMessage == "right option works")
        #expect(!model.firstKeyFailed)
    }

    @Test func aKeyPressedBeforeThePageOpenedIsNotNamed() {
        let speech = Speech()
        speech.listener.update(.live)
        speech.listener.receivedOtherKey("left command", date: Date().addingTimeInterval(-10))
        let model = model(speech)
        model.continueFromShortcut()
        #expect(model.firstKeyCheck == .waiting)
    }

    @Test func eachFailedTryIsSaidExactlyAndRetryClearsIt() {
        let speech = Speech()
        let model = model(speech)
        model.continueFromShortcut()
        #expect(model.firstDictationProblem == nil)
        speech.microphoneFailed = true
        speech.microphoneFailedAt = Date()
        #expect(model.firstDictationProblem == "Intention couldn't open the microphone. Allow it in System Settings, then retry.")
        // Retry clears it while the controller still reports it, and the
        // next failure shows again.
        model.retryFirstDictation()
        #expect(model.firstDictationProblem == nil)
        speech.microphoneFailedAt = Date()
        #expect(model.firstDictationProblem != nil)
        speech.microphoneFailed = false
        speech.microphoneFailedAt = nil
        speech.silent = Date()
        speech.silenceWasMicrophone = true
        #expect(model.firstDictationProblem == "The microphone sent only silence. Choose another in Intention's Settings, then retry.")
        speech.silenceWasMicrophone = false
        #expect(model.firstDictationProblem == "Intention heard sound but no words. Hold fn, say a sentence, then let go.")
        speech.missed = Date()
        #expect(model.firstDictationProblem == "The words didn't come back from Intention's server.")
        model.retryFirstDictation()
        #expect(model.firstDictationProblem == nil)
        #expect(model.firstDictation == .waiting)
    }

    @Test func goingBackToTheShortcutAndOnChecksTheKeyAfresh() {
        let speech = Speech()
        speech.listener.update(.live)
        let model = model(speech)
        model.continueFromShortcut()
        speech.listener.receivedTrigger(down: true, at: 1, date: Date())
        speech.listener.receivedTrigger(down: false, at: 2, date: Date())
        #expect(model.firstKeyCheck == .works)
        model.changeShortcut()
        #expect(model.step == .shortcut)
        speech.key = "right option"
        model.continueFromShortcut()
        #expect(model.firstKeyCheck == .waiting)
    }
}
