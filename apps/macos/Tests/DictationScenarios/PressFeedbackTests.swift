import AppKit
import Testing
@testable import Dictation

/// No key listeners or windows. The real HoldKey and AppModel's shared
/// bindings deliver into a Bool sink; pixels remain a native acceptance check.
// These controllers use MockField.shared, like the rest of this serialized suite.
extension DictationScenarioTests {
@MainActor
struct PressFeedbackTests {
    private func wired(_ pending: @escaping @MainActor (Bool) -> Void) -> (HoldKey, DictationController, ScriptedSource) {
        let source = ScriptedSource(chunks: 0)
        let endpoint = DictationEndpoint(url: URL(string: "ws://127.0.0.1:1/unused")!, credentials: FeedbackNoCredentials())
        let dictation = DictationScenarioTests().controller(endpoint, source: source)
        dictation.frontmostBundle = { nil }
        let key = HoldKey(key: .function)
        key.keyboardFlags = { [NSEvent.ModifierFlags.function.rawValue] }
        key.keyboardShowsKeyDown = { $0 == 63 }
        DictationIndicators.connectTrigger(key, dictation: dictation, pending: pending)
        // The existing phase-to-key binding, independent of any native view.
        dictation.phaseChanged = { [weak key, weak dictation] phase in
            key?.recording = phase == .recording
            if let dictation { key?.onEscape = dictation.escapeCancellation() }
        }
        return (key, dictation, source)
    }

    private func press(_ key: HoldKey, at time: TimeInterval = 10) {
        var event = HoldKey.Monitored(kind: .modifiers, keyCode: 63, flags: NSEvent.ModifierFlags.function.rawValue)
        event.time = time
        _ = key.receivedInWindow(event)
    }

    private func release(_ key: HoldKey, at time: TimeInterval = 10.05) {
        var event = HoldKey.Monitored(kind: .modifiers, keyCode: 63)
        event.time = time
        _ = key.receivedInWindow(event)
    }

    @Test func loneFnRequestsFeedbackWithinFiftyMilliseconds() {
        var time: TimeInterval = 10
        var firstFeedback: TimeInterval?
        var states: [Bool] = []
        let (key, dictation, source) = wired {
            states.append($0)
            if $0 { firstFeedback = firstFeedback ?? time }
        }
        key.now = { time }
        press(key)
        time += 0.05
        #expect(firstFeedback.map { $0 - 10 <= 0.05 } == true)
        #expect(states == [true])
        #expect(!source.running)
        #expect(dictation.phase == .idle)
        #expect(!key.holdWasConfirmed)
        release(key)
        #expect(states == [true, false])
        #expect(key.gestureTimer == nil)
    }

    @Test(arguments: [0.0, 0.299, 0.3])
    func recordingStartKeepsTheThreeHundredMillisecondGate(elapsed: TimeInterval) async {
        var states: [Bool] = []
        let (key, dictation, source) = wired { states.append($0) }
        key.now = { 10 + elapsed }
        press(key)
        #expect(source.running == (elapsed >= DictationGesture.window))
        #expect(key.holdWasConfirmed == (elapsed >= DictationGesture.window))
        #expect(states == (elapsed >= DictationGesture.window ? [true, false] : [true]))
        // Capture before release removes the session. Awaiting preparation
        // below finishes its queued field read before the next fixture reset.
        let preparation = dictation.preparationForTesting().task
        #expect((preparation != nil) == source.running)
        release(key, at: 10 + elapsed)
        dictation.cancel()
        #expect(!source.running)
        #expect(!key.keyPending)
        #expect(key.gestureTimer == nil)
        await preparation?.value
    }

    @Test(arguments: ["chord", "escape", "lock", "unavailable", "key", "recorder", "scroll", "click"])
    func cancelledPendingCannotLaterStartAudio(reason: String) {
        var states: [Bool] = []
        let (key, dictation, source) = wired { states.append($0) }
        var time: TimeInterval = 10
        key.now = { time }
        press(key)
        switch reason {
        case "chord": key.keyDown(keyCode: 0, flags: [.function])
        case "escape": _ = key.receivedInWindow(.init(kind: .keyDown, keyCode: KeyClaims.escape))
        case "lock": key.onLock()
        case "unavailable": key.dictationAvailable = false
        case "key": key.key = .single(.rightCommand)
        case "recorder": key.recorder = { _ in }
        case "scroll": _ = key.receivedInWindow(.init(kind: .scroll, keyCode: 0))
        default: _ = key.receivedInWindow(.init(kind: .mouseDown, flags: NSEvent.ModifierFlags.function.rawValue))
        }
        time = 11
        #expect(states == [true, false])
        #expect(key.gestureTimer == nil)
        #expect(!source.running)
        #expect(dictation.phase == .idle)
        release(key, at: time)
    }

    @Test(arguments: [false, true])
    func delayedCaretObservationsCannotCancelANewHold(readStartsAfterPress: Bool) async throws {
        var time: TimeInterval = 10
        var states: [Bool] = []
        var observed: [ProposalObservation] = []
        let (key, dictation, source) = wired { states.append($0) }
        let observe = DictationIndicators.caretObserver { observed.append($0) }
        let origin = ContinuousClock.now
        func field(_ focus: Int, generation: Int = 1, milliseconds: Int) -> CaretTracker.Observation {
            .init(reading: nil, visualTarget: nil, pid: 100, generation: generation,
                  startedAt: origin.advanced(by: .milliseconds(milliseconds)), fieldFocused: true, focus: focus)
        }
        observe(field(1, milliseconds: -100))
        key.now = { time }
        press(key)
        let timer = try #require(key.gestureTimer)

        // The new field may have gained focus before keydown even when its
        // read begins afterward. Delivery time cannot cancel this press.
        observe(field(2, milliseconds: readStartsAfterPress ? 20 : -20))
        // A stale old field, then a later read discovering another field,
        // likewise supplies no physical focus-change time.
        observe(field(1, generation: 0, milliseconds: -50))
        observe(field(3, generation: 2, milliseconds: 100))
        #expect(observed.map(\.focus) == [1, 2, 1, 3])
        #expect(states == [true])
        #expect(key.gestureTimer === timer)
        #expect(!source.running)

        time = 10.3
        timer.fire()
        #expect(source.running)
        #expect(dictation.phase == .recording)
        #expect(key.holdWasConfirmed)
        #expect(states == [true, false])
        let preparation = try #require(dictation.preparationForTesting().task)
        release(key, at: time)
        dictation.cancel()
        #expect(!source.running)
        await preparation.value
    }

    @Test(arguments: ["click", "scroll", "chord"])
    func inputCancellationSurvivesDelayedCaretObservations(input: String) throws {
        var time: TimeInterval = 10
        var states: [Bool] = []
        var observed: [Int] = []
        let (key, dictation, source) = wired { states.append($0) }
        let observe = DictationIndicators.caretObserver { observed.append($0.focus) }
        let origin = ContinuousClock.now
        let old = CaretTracker.Observation(reading: nil, visualTarget: nil, pid: 100, generation: 1,
                                           startedAt: origin, fieldFocused: true, focus: 1)
        var new = old
        new.focus = 2
        new.startedAt = origin.advanced(by: .milliseconds(20))
        observe(old)
        key.now = { time }
        press(key)
        let timer = try #require(key.gestureTimer)
        let flags = NSEvent.ModifierFlags.function.rawValue
        switch input {
        case "click": _ = key.receivedInWindow(.init(kind: .mouseDown, flags: flags))
        case "scroll": _ = key.receivedInWindow(.init(kind: .scroll, flags: flags))
        default: _ = key.receivedInWindow(.init(kind: .keyDown, keyCode: 0, flags: flags))
        }
        // A new field read arriving after the cancelling input, followed by
        // an older observation, must never rearm the cancelled hold.
        observe(new)
        observe(old)
        #expect(observed == [1, 2, 1])
        #expect(states == [true, false])
        #expect(key.gestureTimer == nil)
        time = 10.3
        timer.fire()
        #expect(!source.running)
        #expect(dictation.phase == .idle)
        release(key, at: time)
    }

    @Test func globeCompanionLeavesPendingAloneAndHeldReleaseClearsIt() {
        var states: [Bool] = []
        let (key, dictation, source) = wired { states.append($0) }
        key.now = { 10 }
        press(key)
        key.keyDown(keyCode: KeyClaims.globe, flags: [.function])
        #expect(states == [true])
        #expect(!source.running)
        release(key)
        #expect(states == [true, false])
        #expect(dictation.phase == .idle)
    }

    @Test func unavailablePressNeverRequestsPending() {
        var states: [Bool] = []
        let (key, dictation, source) = wired { states.append($0) }
        key.now = { 10 }
        key.dictationAvailable = false
        press(key)
        #expect(states.isEmpty)
        #expect(dictation.phase == .idle)
        #expect(!source.running)
        release(key)
    }
}

}

/// Prevent any network request even when a controller's preparation task runs.
struct FeedbackNoCredentials: SpeechCredentials {
    func grant() async throws -> String { throw DictationStreamError.unreachable }
    func refused(_ grant: String) async {}
    func reset() async {}
}
