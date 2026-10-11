import AppKit
@testable import Dictation
import Testing

/// Recording a new dictation trigger, driven with the modifier changes and
/// key presses the trigger's watch would hand over. The expected triggers
/// and refusals are written out by hand from the keyboard: key codes from
/// Carbon's Events.h and the device bits from IOLLEvent.h.
struct KeyRecorderTests {
    private typealias Flags = NSEvent.ModifierFlags

    private struct Press {
        let code: UInt16
        let flags: Flags
    }

    // Each key's code and the flags it sets down, alone.
    private static let fn = Press(code: 63, flags: [.function])
    private static let leftControl = Press(code: 59, flags: [.control, Flags(rawValue: 0x1)])
    private static let rightControl = Press(code: 62, flags: [.control, Flags(rawValue: 0x2000)])
    private static let leftOption = Press(code: 58, flags: [.option, Flags(rawValue: 0x20)])
    private static let rightOption = Press(code: 61, flags: [.option, Flags(rawValue: 0x40)])
    private static let leftCommand = Press(code: 55, flags: [.command, Flags(rawValue: 0x8)])
    private static let rightCommand = Press(code: 54, flags: [.command, Flags(rawValue: 0x10)])
    private static let leftShift = Press(code: 56, flags: [.shift, Flags(rawValue: 0x2)])
    private static let rightShift = Press(code: 60, flags: [.shift, Flags(rawValue: 0x4)])
    private static let capsLock: UInt16 = 57
    private static let a: UInt16 = 0
    private static let space: UInt16 = 49
    private static let escape: UInt16 = 53

    /// Presses the keys in order, then lets them go in reverse, as the
    /// modifier changes arrive: each change carries the flags of every key
    /// still down.
    private static func chord(_ keys: [Press], into recording: inout KeyRecording) -> [KeyRecording.Outcome?] {
        var outcomes: [KeyRecording.Outcome?] = []
        var held: [Press] = []
        func flags() -> Flags { held.reduce(Flags()) { $0.union($1.flags) } }
        for key in keys {
            held.append(key)
            outcomes.append(recording.receive(.modifiers(keyCode: key.code, flags: flags())))
        }
        for key in keys.reversed() {
            held.removeAll { $0.code == key.code }
            outcomes.append(recording.receive(.modifiers(keyCode: key.code, flags: flags())))
        }
        return outcomes
    }

    private static func record(_ keys: Press...) -> KeyRecording.Outcome? {
        var recording = KeyRecording()
        let outcomes = chord(keys, into: &recording)
        // Nothing is decided until the last key comes up.
        #expect(outcomes.dropLast().allSatisfy { $0 == nil })
        return outcomes.last ?? nil
    }

    @Test func fnAndTheRightHandKeysAreRecordedOnTheirOwn() {
        #expect(Self.record(Self.fn) == .recorded(.function))
        #expect(Self.record(Self.rightOption) == .recorded(.rightOption))
        #expect(Self.record(Self.rightCommand) == .recorded(.rightCommand))
        #expect(Self.record(Self.rightControl) == .recorded(.single(.rightControl)))
    }

    @Test func aLeftHandKeyOrShiftOnItsOwnIsRefusedWithWhy() {
        #expect(Self.record(Self.leftCommand) == .refused("Left Command is in too many shortcuts. Try the right-hand key, fn, or two keys together."))
        #expect(Self.record(Self.leftOption) == .refused("Left Option is in too many shortcuts. Try the right-hand key, fn, or two keys together."))
        #expect(Self.record(Self.leftControl) == .refused("Left Control is in too many shortcuts. Try the right-hand key, fn, or two keys together."))
        #expect(Self.record(Self.leftShift) == .refused("Shift on its own would start with every capital letter. Try fn or two keys together."))
        #expect(Self.record(Self.rightShift) == .refused("Shift on its own would start with every capital letter. Try fn or two keys together."))
    }

    @Test func keysHeldTogetherAreRecordedAsAPairEitherSide() {
        #expect(Self.record(Self.leftControl, Self.leftOption) == .recorded(.controlOption))
        // The other side's keys, and the other order, make the same pair.
        #expect(Self.record(Self.rightOption, Self.rightControl) == .recorded(.controlOption))
        #expect(Self.record(Self.leftOption, Self.rightCommand) == .recorded(.optionCommand))
        #expect(Self.record(Self.leftShift, Self.rightOption) == .recorded(.combination([.shift, .option])))
        #expect(Self.record(Self.leftControl, Self.leftOption, Self.leftCommand) == .recorded(.combination([.control, .option, .command])))
    }

    @Test func fnIsRefusedInAPairSinceOnlyFnAloneIsTakenFromOtherApps() {
        let refusal = "fn works only on its own, since other apps listening for it would start too."
        #expect(Self.record(Self.fn, Self.leftShift) == .refused(refusal))
        #expect(Self.record(Self.rightOption, Self.fn) == .refused(refusal))
        #expect(Self.record(Self.fn, Self.leftControl, Self.leftOption) == .refused(refusal))
    }

    @Test func bothSidesOfOneModifierAreNotAPair() {
        #expect(Self.record(Self.leftOption, Self.rightOption) == .refused("Hold two different keys, or one key on its own."))
    }

    @Test func aKeyThatIsNotAModifierIsRefusedAndRecordingGoesOn() {
        let refusal = "Only fn, Control, Option, Shift and Command can be held to dictate."
        var recording = KeyRecording()
        #expect(recording.receive(.key(keyCode: Self.a)) == .refused(refusal))
        #expect(recording.receive(.keyUp(keyCode: Self.a)) == nil)
        #expect(recording.receive(.modifiers(keyCode: Self.capsLock, flags: [.capsLock])) == .refused(refusal))
        // A shortcut such as Control+Space is refused at the space, and
        // letting Control go afterwards records nothing.
        #expect(recording.receive(.modifiers(keyCode: Self.leftControl.code, flags: Self.leftControl.flags)) == nil)
        #expect(recording.shown == "Left Control")
        #expect(recording.receive(.key(keyCode: Self.space)) == .refused(refusal))
        #expect(recording.receive(.keyUp(keyCode: Self.space)) == nil)
        #expect(recording.receive(.modifiers(keyCode: Self.leftControl.code, flags: [])) == nil)
        #expect(recording.shown == nil)
        // The next attempt starts clean.
        let outcomes = Self.chord([Self.rightOption], into: &recording)
        #expect(outcomes.last == .recorded(.rightOption))
    }

    @Test func escapeCancelsWhateverIsHeld() {
        var recording = KeyRecording()
        #expect(recording.receive(.key(keyCode: Self.escape)) == .cancelled)
        var held = KeyRecording()
        #expect(held.receive(.modifiers(keyCode: Self.rightOption.code, flags: Self.rightOption.flags)) == nil)
        #expect(held.receive(.key(keyCode: Self.escape)) == .cancelled)
        var afterLetter = KeyRecording()
        _ = afterLetter.receive(.key(keyCode: Self.a))
        #expect(afterLetter.receive(.key(keyCode: Self.escape)) == .cancelled)
    }

    @Test func aReleaseThatNeverArrivedIsCorrectedByTheNextChange() {
        var recording = KeyRecording()
        // Right Option goes down; its release is lost.
        #expect(recording.receive(.modifiers(keyCode: Self.rightOption.code, flags: Self.rightOption.flags)) == nil)
        // Right Command goes down with flags that show Option up, so the
        // two were never held together: Right Command alone is the attempt.
        #expect(recording.receive(.modifiers(keyCode: Self.rightCommand.code, flags: Self.rightCommand.flags)) == nil)
        #expect(recording.shown == "Right Command")
        #expect(recording.receive(.modifiers(keyCode: Self.rightCommand.code, flags: [])) == .recorded(.rightCommand))
        // The next attempt starts clean.
        #expect(Self.chord([Self.fn], into: &recording).last == .recorded(.function))
    }

    @Test func theSameKeyPressedAgainAfterALostReleaseStartsANewAttempt() {
        // Refused for a letter; Option's release is lost; Right Option again.
        var refused = KeyRecording()
        #expect(refused.receive(.modifiers(keyCode: Self.rightOption.code, flags: Self.rightOption.flags)) == nil)
        #expect(refused.receive(.key(keyCode: Self.a)) != nil)
        #expect(refused.receive(.keyUp(keyCode: Self.a)) == nil)
        #expect(refused.receive(.modifiers(keyCode: Self.rightOption.code, flags: Self.rightOption.flags)) == nil)
        #expect(refused.receive(.modifiers(keyCode: Self.rightOption.code, flags: [])) == .recorded(.rightOption))
        // Option and Command; Command let go; Option's release is lost; Right Option again alone.
        var pair = KeyRecording()
        #expect(pair.receive(.modifiers(keyCode: Self.rightOption.code, flags: Self.rightOption.flags)) == nil)
        #expect(pair.receive(.modifiers(keyCode: Self.rightCommand.code, flags: Self.rightOption.flags.union(Self.rightCommand.flags))) == nil)
        #expect(pair.receive(.modifiers(keyCode: Self.rightCommand.code, flags: Self.rightOption.flags)) == nil)
        #expect(pair.receive(.modifiers(keyCode: Self.rightOption.code, flags: Self.rightOption.flags)) == nil)
        #expect(pair.shown == "Right Option")
        #expect(pair.receive(.modifiers(keyCode: Self.rightOption.code, flags: [])) == .recorded(.rightOption))
    }

    @Test func aReleaseLostFromAPairKeepsTheKeysThatWereHeldTogether() {
        var recording = KeyRecording()
        let controlAndOption = Self.leftControl.flags.union(Self.leftOption.flags)
        #expect(recording.receive(.modifiers(keyCode: Self.leftControl.code, flags: Self.leftControl.flags)) == nil)
        #expect(recording.receive(.modifiers(keyCode: Self.leftOption.code, flags: controlAndOption)) == nil)
        // Control's release is lost; Option's arrives with nothing down.
        #expect(recording.receive(.modifiers(keyCode: Self.leftOption.code, flags: [])) == .recorded(.controlOption))
    }

    @Test func aRefusedAttemptWhoseReleaseWasLostDoesNotRefuseTheNext() {
        var recording = KeyRecording()
        #expect(recording.receive(.modifiers(keyCode: Self.rightOption.code, flags: Self.rightOption.flags)) == nil)
        #expect(recording.receive(.key(keyCode: Self.a)) != nil)
        #expect(recording.receive(.keyUp(keyCode: Self.a)) == nil)
        // Option's release is lost; Right Command alone is a new attempt.
        #expect(Self.chord([Self.rightCommand], into: &recording).last == .recorded(.rightCommand))
    }

    @Test func aRefusedChordStaysRefusedUntilEveryKeyInItIsUp() {
        var recording = KeyRecording()
        let optionAndCommand = Self.rightOption.flags.union(Self.rightCommand.flags)
        #expect(recording.receive(.modifiers(keyCode: Self.rightOption.code, flags: Self.rightOption.flags)) == nil)
        #expect(recording.receive(.key(keyCode: Self.a)) == .refused("Only fn, Control, Option, Shift and Command can be held to dictate."))
        // Command added and the letter and Option let go first: still the refused attempt.
        #expect(recording.receive(.modifiers(keyCode: Self.rightCommand.code, flags: optionAndCommand)) == nil)
        #expect(recording.receive(.keyUp(keyCode: Self.a)) == nil)
        #expect(recording.receive(.modifiers(keyCode: Self.rightOption.code, flags: Self.rightCommand.flags)) == nil)
        #expect(recording.shown == nil)
        #expect(recording.receive(.modifiers(keyCode: Self.rightCommand.code, flags: [])) == nil)
        // Only then does a new attempt count.
        #expect(Self.chord([Self.rightCommand], into: &recording).last == .recorded(.rightCommand))
    }

    @Test func aLetterHeldWhileModifiersArePressedRefusesThemToo() {
        var recording = KeyRecording()
        #expect(recording.receive(.key(keyCode: Self.a)) != nil)
        // The letter is still down while Right Option is pressed and let go.
        #expect(Self.chord([Self.rightOption], into: &recording).allSatisfy { $0 == nil })
        #expect(recording.receive(.keyUp(keyCode: Self.a)) == nil)
        #expect(Self.chord([Self.rightOption], into: &recording).last == .recorded(.rightOption))
    }

    @Test func aLetterWhoseReleaseWentUnseenDoesNotHoldTheRecordingRefused() {
        var recording = KeyRecording()
        recording.keyboardShowsDown = { _ in false }
        #expect(recording.receive(.key(keyCode: Self.a)) != nil)
        #expect(Self.chord([Self.rightOption], into: &recording).last == .recorded(.rightOption))
    }

    @Test func theFieldShowsTheKeysHeldSoFar() {
        var recording = KeyRecording()
        #expect(recording.shown == nil)
        _ = recording.receive(.modifiers(keyCode: Self.leftOption.code, flags: Self.leftOption.flags))
        #expect(recording.shown == "Left Option")
        _ = recording.receive(.modifiers(keyCode: Self.leftControl.code, flags: Self.leftOption.flags.union(Self.leftControl.flags)))
        #expect(recording.shown == "Control + Option")
        // Letting one go keeps showing both: the attempt is both.
        _ = recording.receive(.modifiers(keyCode: Self.leftOption.code, flags: Self.leftControl.flags))
        #expect(recording.shown == "Control + Option")
    }
}

/// The recorder over a `HoldKey` that watches nothing, handed what its
/// monitors and tap would deliver.
@MainActor
struct KeyRecorderWithTriggerTests {
    private final class Saved {
        var keys: [HoldKey.Key] = []
    }

    @Test func whileRecordingTheOldTriggerStartsNothingAndTheNewOneIsSaved() {
        let hold = HoldKey(handsFreeEnabled: true, key: .rightOption, holdDelay: 0)
        var presses = 0
        hold.onPress = { presses += 1 }
        let saved = Saved()
        let recorder = KeyRecorder(holdKey: hold, save: { key in
            saved.keys.append(key)
            hold.key = key
        })
        recorder.start()
        #expect(recorder.isRecording)
        // Right Option, the trigger before, is recorded rather than held.
        hold.modifiersChanged(keyCode: 61, flags: [.option, NSEvent.ModifierFlags(rawValue: 0x40)])
        #expect(presses == 0)
        #expect(recorder.shown == "Right Option")
        hold.modifiersChanged(keyCode: 54, flags: [.option, NSEvent.ModifierFlags(rawValue: 0x40), .command, NSEvent.ModifierFlags(rawValue: 0x10)])
        #expect(recorder.shown == "Option + Command")
        hold.modifiersChanged(keyCode: 61, flags: [.command, NSEvent.ModifierFlags(rawValue: 0x10)])
        hold.modifiersChanged(keyCode: 54, flags: [])
        #expect(saved.keys == [.optionCommand])
        #expect(!recorder.isRecording)
        #expect(hold.recorder == nil)
        // Once saved, the old key alone starts nothing and the new one is the trigger.
        hold.modifiersChanged(keyCode: 61, flags: [.option, NSEvent.ModifierFlags(rawValue: 0x40)])
        hold.modifiersChanged(keyCode: 61, flags: [])
        #expect(presses == 0)
    }

    /// What the recorder wrote to the log, by fixed name.
    private final class Logged {
        var lines: [String] = []
    }

    @Test func aHeldRefusedKeyLogsOneRefusal() {
        let hold = HoldKey(handsFreeEnabled: true, key: .function, holdDelay: 0), logged = Logged()
        let recorder = KeyRecorder(holdKey: hold, log: { logged.lines.append($0) }, save: { _ in })
        recorder.start()
        // Through the window's monitor, as AppKit hands it: the press, then
        // auto-repeats while the letter stays down.
        _ = hold.receivedInWindow(HoldKey.Monitored(kind: .keyDown, keyCode: 0))
        for _ in 0..<5 { _ = hold.receivedInWindow(HoldKey.Monitored(kind: .keyDown, keyCode: 0, isRepeat: true)) }
        _ = hold.receivedInWindow(HoldKey.Monitored(kind: .keyUp, keyCode: 0))
        #expect(logged.lines == ["key.refused"])
        #expect(recorder.refusal == KeyRecording.notModifier)
    }

    @Test func twoSeparatePressesOfARefusedKeyLogTwoRefusals() {
        let hold = HoldKey(handsFreeEnabled: true, key: .function, holdDelay: 0), logged = Logged()
        let recorder = KeyRecorder(holdKey: hold, log: { logged.lines.append($0) }, save: { _ in })
        recorder.start()
        for _ in 0..<2 {
            hold.keyDown(keyCode: 0, flags: [])
            hold.keyUp(keyCode: 0)
        }
        #expect(logged.lines == ["key.refused", "key.refused"])
    }

    @Test func aRefusedKeyThenAnAcceptedCombinationLogsTheRefusalThenTheRecording() {
        let hold = HoldKey(handsFreeEnabled: true, key: .function, holdDelay: 0), logged = Logged(), saved = Saved()
        let recorder = KeyRecorder(holdKey: hold, log: { logged.lines.append($0) }, save: { saved.keys.append($0) })
        recorder.start()
        hold.keyDown(keyCode: 0, flags: [])
        hold.keyDown(keyCode: 0, flags: [], isRepeat: true)
        hold.keyUp(keyCode: 0)
        // Left Control, then Left Option, held together and let go.
        hold.modifiersChanged(keyCode: 59, flags: [.control, NSEvent.ModifierFlags(rawValue: 0x1)])
        hold.modifiersChanged(keyCode: 58, flags: [.control, NSEvent.ModifierFlags(rawValue: 0x1), .option, NSEvent.ModifierFlags(rawValue: 0x20)])
        hold.modifiersChanged(keyCode: 59, flags: [.option, NSEvent.ModifierFlags(rawValue: 0x20)])
        hold.modifiersChanged(keyCode: 58, flags: [])
        #expect(logged.lines == ["key.refused", "key.recorded"])
        #expect(saved.keys == [.combination([.control, .option])])
        #expect(!recorder.isRecording)
    }

    @Test func aRefusalStaysUntilTheNextAttemptAndCancelSavesNothing() {
        let hold = HoldKey(handsFreeEnabled: true, key: .function, holdDelay: 0)
        let saved = Saved()
        let recorder = KeyRecorder(holdKey: hold, save: { saved.keys.append($0) })
        recorder.start()
        hold.keyDown(keyCode: 0, flags: [])
        #expect(recorder.refusal == "Only fn, Control, Option, Shift and Command can be held to dictate.")
        #expect(recorder.isRecording)
        hold.modifiersChanged(keyCode: 58, flags: [.option, NSEvent.ModifierFlags(rawValue: 0x20)])
        #expect(recorder.refusal == nil)
        hold.modifiersChanged(keyCode: 58, flags: [])
        #expect(recorder.refusal == "Left Option is in too many shortcuts. Try the right-hand key, fn, or two keys together.")
        hold.keyDown(keyCode: 53, flags: [])
        #expect(!recorder.isRecording)
        #expect(hold.recorder == nil)
        #expect(saved.keys.isEmpty)
        // Cancelling when not recording does nothing.
        recorder.cancel()
        #expect(!recorder.isRecording)
    }

    @Test func startingToRecordReleasesAHeldTrigger() {
        let hold = HoldKey(handsFreeEnabled: true, key: .rightOption, holdDelay: 0)
        var events: [String] = []
        hold.onPress = { events.append("press") }
        hold.onRelease = { events.append("release") }
        hold.modifiersChanged(keyCode: 61, flags: [.option, NSEvent.ModifierFlags(rawValue: 0x40)])
        let recorder = KeyRecorder(holdKey: hold, save: { _ in })
        recorder.start()
        #expect(events == ["press", "release"])
        recorder.cancel()
    }
}

/// The tap's choice of which modifier changes to drop, from the presses
/// and releases a person makes while what is consumed changes.
struct ConsumedHoldsTests {
    private static let fnDown = NSEvent.ModifierFlags.function
    private static let fn: UInt16 = 63

    @Test func aDroppedPressHasItsReleaseDroppedEvenAfterConsumingStops() {
        var holds = ConsumedHolds()
        holds.consumed = Self.fn
        #expect(holds.drops(keyCode: Self.fn, flags: Self.fnDown) == true)
        // Settings stopped recording while Fn was down.
        holds.consumed = nil
        #expect(holds.drops(keyCode: Self.fn, flags: []) == true)
        // The next press and release both pass.
        #expect(holds.drops(keyCode: Self.fn, flags: Self.fnDown) == false)
        #expect(holds.drops(keyCode: Self.fn, flags: []) == false)
    }

    @Test func aPressLetThroughHasItsReleaseLetThroughEvenAfterConsumingStarts() {
        var holds = ConsumedHolds()
        #expect(holds.drops(keyCode: Self.fn, flags: Self.fnDown) == false)
        holds.consumed = Self.fn
        #expect(holds.drops(keyCode: Self.fn, flags: []) == false)
        #expect(holds.drops(keyCode: Self.fn, flags: Self.fnDown) == true)
        #expect(holds.drops(keyCode: Self.fn, flags: []) == true)
    }

    @Test func otherModifiersAlwaysPassAndALostReleaseIsForgottenAtTheNextPress() {
        var holds = ConsumedHolds()
        holds.consumed = Self.fn
        #expect(holds.drops(keyCode: 61, flags: [.option, NSEvent.ModifierFlags(rawValue: 0x40)]) == false)
        #expect(holds.drops(keyCode: 61, flags: []) == false)
        #expect(holds.drops(keyCode: 57, flags: [.capsLock]) == false)
        // A dropped press whose release was lost; the next press answers afresh.
        #expect(holds.drops(keyCode: Self.fn, flags: Self.fnDown) == true)
        holds.consumed = nil
        #expect(holds.drops(keyCode: Self.fn, flags: Self.fnDown) == false)
        #expect(holds.drops(keyCode: Self.fn, flags: []) == false)
    }
}

/// The callbacks the dictation key hands to AppKit and to its event tap,
/// called from a background queue as a framework might. Swift traps a
/// main-actor closure run off the main thread, in `_dispatch_assert_queue_fail`;
/// each of these must instead reach the main actor and act there.
@MainActor
struct OffMainCallbackTests {
    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private static func offMain(_ body: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                body()
                done.resume()
            }
        }
    }

    /// A key event made where it is used, as AppKit would hand a monitor one.
    private nonisolated static func key(_ type: NSEvent.EventType, _ keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: keyCode)!
    }

    @Test func theMonitorsHandlersCalledOffTheMainThreadReachTheTrigger() async {
        // The very handlers `start` gives AppKit.
        let hold = HoldKey(handsFreeEnabled: true, key: .function, holdDelay: 0)
        let global = HoldKey.globalMonitor(for: hold), local = HoldKey.localMonitor(for: hold)
        let recorder = KeyRecorder(holdKey: hold, notifications: NotificationCenter(), save: { _ in })
        recorder.start()
        await Self.offMain { global(Self.key(.keyDown, 0)) }
        #expect(await eventually { recorder.refusal != nil })
        // Off the main thread the local monitor hands Intention's window every
        // event, and the recording still hears it.
        recorder.cancel()
        recorder.start()
        let passed = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async { done.resume(returning: local(Self.key(.keyDown, 11)) != nil) }
        }
        #expect(passed)
        #expect(await eventually { recorder.refusal != nil })
        // On the main thread it keeps a recording's keys from the window,
        // and lets a click through.
        #expect(local(Self.key(.keyUp, 11)) == nil)
        #expect(local(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                         context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!) != nil)
        recorder.cancel()
        #expect(local(Self.key(.keyDown, 0)) != nil)
    }

    @Test func theTapsCallbacksFromItsOwnThreadReachTheTrigger() async {
        let hold = HoldKey(handsFreeEnabled: true, key: .rightCommand, holdDelay: 0, watchInterval: 0.02, unseenReleaseWait: 0.06)
        // A made-up keyboard, with nothing down whatever is pressed on the
        // Mac running the checks.
        hold.keyboardFlags = { [0, 0] }
        var events: [String] = []
        hold.onPress = { events.append("press") }
        hold.onRelease = { events.append("release") }
        await Self.offMain { hold.tapDelivered(.init(keyCode: 54, flags: NSEvent.ModifierFlags.command.rawValue | 0x10, keyboard: NSEvent.ModifierFlags.command.rawValue | 0x10)) }
        #expect(await eventually { events == ["press"] })
        // A disabled tap with the key no longer down counts as its release,
        // once the keyboard has shown it up for the wait.
        await Self.offMain { hold.tapWasDisabled() }
        #expect(await eventually { events == ["press", "release"] })
    }

    @Test func theTapsClaimsFromItsOwnThreadReachTheTrigger() async {
        let hold = HoldKey(handsFreeEnabled: true, key: .function, holdDelay: 0)
        hold.keyboardFlags = { [0, 0] }
        var events: [String] = []
        hold.onPress = { events.append("press") }
        hold.onHandsFree = { events.append("handsFree") }
        hold.onEscape = { events.append("escape") }
        await Self.offMain { hold.tapDelivered(keyCode: 63, flags: NSEvent.ModifierFlags.function.rawValue) }
        await Self.offMain { hold.tapClaimed(.handsFree) }
        await Self.offMain { hold.tapClaimed(.escape) }
        hold.onOtherKey = { events.append("otherKey") }
        await Self.offMain { hold.tapInput(HoldKey.Monitored(kind: .keyDown, keyCode: 0, flags: NSEvent.ModifierFlags.function.rawValue)) }
        #expect(await eventually { events == ["press", "handsFree", "escape", "otherKey"] })
    }

    /// Holds the main thread without letting its run loop turn.
    private func block(for seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    @Test func whileSettingsRecordsItsKeysComeFromTheMonitorsNotTheTap() async {
        // Escape cancels the recording in the same turn the local monitor
        // keeps it from Settings' window; the tap's copy, on its way by
        // another route, does nothing.
        let hold = HoldKey(handsFreeEnabled: true, key: .function, holdDelay: 0)
        var recorded: [HoldKey.Recorded] = []
        hold.recorder = { recorded.append($0) }
        await Self.offMain { hold.tapInput(HoldKey.Monitored(kind: .keyDown, keyCode: 53)) }
        #expect(!(await eventually { !recorded.isEmpty }))
        let local = HoldKey.localMonitor(for: hold)
        #expect(local(Self.key(.keyDown, 53)) == nil)
        #expect(recorded == [.key(keyCode: 53)])
    }

    @Test func theWatchWaitsForASpaceTheTapTookBeforeTheKeyCameUp() async {
        // Fn held, Space taken, Fn let go: whichever runs first once the
        // main actor is free, the Space or a reading of the keyboard, the
        // hold turns hands-free before it is released.
        let hold = HoldKey(handsFreeEnabled: true, key: .function, holdDelay: 0, watchInterval: 0.02, unseenReleaseWait: 0.06)
        final class Keyboard: @unchecked Sendable { var flags = NSEvent.ModifierFlags.function.rawValue }
        let keyboard = Keyboard()
        hold.keyboardFlags = { [keyboard.flags, 0] }
        var events: [String] = []
        hold.onPress = { events.append("press") }
        hold.onRelease = { events.append("release") }
        hold.onHandsFree = { events.append("handsFree") }
        hold.modifiersChanged(HoldKey.Delivery(keyCode: 63, flags: NSEvent.ModifierFlags.function.rawValue,
                                               keyboard: NSEvent.ModifierFlags.function.rawValue))
        await Self.offMain { hold.tapClaimed(.handsFree) }
        keyboard.flags = 0
        // The watch is due by the time the main actor turns again. Kept
        // short: other suites' main-actor tests run beside this one.
        block(for: 0.03)
        #expect(await eventually { hold.watch == nil })
        #expect(events == ["press", "handsFree"])
    }

    @Test func aWindowLosingTheKeyboardOffTheMainThreadCancelsARecording() async {
        // Its own notification center, so no other check's recording hears it.
        let center = NotificationCenter()
        let hold = HoldKey(handsFreeEnabled: true, key: .function, holdDelay: 0)
        let recorder = KeyRecorder(holdKey: hold, notifications: center, save: { _ in })
        recorder.start()
        await Self.offMain { center.post(name: NSWindow.didResignKeyNotification, object: nil) }
        #expect(await eventually { !recorder.isRecording })
        #expect(hold.recorder == nil)
        // Started twice, it still watches once and stops cleanly.
        recorder.start()
        recorder.start()
        recorder.cancel()
        await Self.offMain { center.post(name: NSWindow.didResignKeyNotification, object: nil) }
        #expect(!recorder.isRecording)
    }

    @Test func eventsMadeOffTheMainThreadAreCopiedWithoutReadingAClicksKeyCode() async {
        let copies = await withCheckedContinuation { (done: CheckedContinuation<[HoldKey.Monitored?], Never>) in
            DispatchQueue.global().async {
                let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0,
                                           context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)
                let click = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [.option], timestamp: 0, windowNumber: 0,
                                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                let moved = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                               context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
                let right = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [.option], timestamp: 0, windowNumber: 0,
                                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                let other = NSEvent.mouseEvent(with: .otherMouseDown, location: .zero, modifierFlags: [.option], timestamp: 0, windowNumber: 0,
                                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                done.resume(returning: [key, click, moved, right, other].map { $0.flatMap(HoldKey.Monitored.init) })
            }
        }
        #expect(copies.map { $0?.time } == [0, 0, nil, 0, 0])
        let inputs = copies.map { value in
            var value = value
            value?.time = nil
            return value
        }
        #expect(inputs[0] == HoldKey.Monitored(kind: .keyDown, keyCode: 0, flags: NSEvent.ModifierFlags.command.rawValue))
        #expect(inputs[1] == HoldKey.Monitored(kind: .mouseDown, flags: NSEvent.ModifierFlags.option.rawValue))
        #expect(inputs[2] == nil)
        // Right and other buttons are clicks too, as a right-click with the
        // key held is.
        #expect(inputs[3] == HoldKey.Monitored(kind: .mouseDown, flags: NSEvent.ModifierFlags.option.rawValue))
        #expect(inputs[4] == HoldKey.Monitored(kind: .mouseDown, flags: NSEvent.ModifierFlags.option.rawValue))
    }
}
