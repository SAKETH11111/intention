import AppKit
import Testing
@testable import Dictation

/// Setup's shortcut page and its key check, at the joins this package owns:
/// the trigger's presses reaching the check whatever the trigger is, and
/// whether a keyboard with fn is connected.
@MainActor
struct ShortcutCheckTests {
    private func delivery(_ keyCode: UInt16, _ modifiers: [HoldKey.Modifier], at time: TimeInterval) -> HoldKey.Delivery {
        let flags = modifiers.reduce(UInt(0)) { $0 | $1.deviceMask | $1.family.flag.rawValue }
        return HoldKey.Delivery(keyCode: keyCode, flags: flags, time: time)
    }

    @Test func aRecordedPairProvesTheCheckAndAnotherKeyIsNamed() {
        let hold = HoldKey(key: .combination([.control, .option]), holdDelay: 100)
        // Command is not the shortcut: the check names it, and it proves nothing.
        hold.modifiersChanged(delivery(55, [.leftCommand], at: 1))
        hold.modifiersChanged(delivery(55, [], at: 1.1))
        #expect(hold.listener.otherKey?.name == "left command")
        #expect(hold.listener.completedPress == nil)
        // Control alone is half the pair.
        hold.modifiersChanged(delivery(59, [.leftControl], at: 2))
        hold.modifiersChanged(delivery(59, [], at: 2.1))
        #expect(hold.listener.completedPress == nil)
        // Both down, then one let go: a press of the pair.
        hold.modifiersChanged(delivery(59, [.leftControl], at: 3))
        hold.modifiersChanged(delivery(58, [.leftControl, .leftOption], at: 3.1))
        hold.modifiersChanged(delivery(58, [.leftControl], at: 3.5))
        #expect(hold.listener.completedPress != nil)
    }

    @Test func aRightHandKeyProvesTheCheckAsFnDid() {
        let hold = HoldKey(key: .single(.rightOption), holdDelay: 100)
        hold.modifiersChanged(delivery(63, [.function], at: 1))
        hold.modifiersChanged(delivery(63, [], at: 1.1))
        #expect(hold.listener.otherKey?.name == "fn")
        #expect(hold.listener.completedPress == nil)
        hold.modifiersChanged(delivery(61, [.rightOption], at: 2))
        hold.modifiersChanged(delivery(61, [], at: 2.2))
        #expect(hold.listener.completedPress != nil)
    }

    @Test func keysPressedForTheRecorderOrBeforeAChangeProveNothing() {
        let hold = HoldKey(key: .function, holdDelay: 100)
        let recorder = KeyRecorder(holdKey: hold, notifications: NotificationCenter(), log: { _ in }, save: { hold.key = $0 })
        recorder.start()
        hold.modifiersChanged(delivery(61, [.rightOption], at: 1))
        hold.modifiersChanged(delivery(61, [], at: 1.2))
        // The recorder saved right option; its own press is neither another
        // key nor a press of the new shortcut.
        #expect(hold.key == .single(.rightOption))
        #expect(hold.listener.otherKey == nil)
        #expect(hold.listener.completedPress == nil)
        // A proof of one shortcut goes when the shortcut changes.
        hold.modifiersChanged(delivery(61, [.rightOption], at: 2))
        hold.modifiersChanged(delivery(61, [], at: 2.2))
        #expect(hold.listener.completedPress != nil)
        hold.key = .function
        #expect(hold.listener.completedPress == nil)
    }

    /// The check counts only a press the trigger itself accepts: the
    /// shortcut's keys alone, with no other modifier or key joining.
    @Test func aPressWithAnotherKeyHeldProvesNothing() {
        let hold = HoldKey(key: .combination([.control, .option]), holdDelay: 100)
        // Command first, then Control and Option, then Option let go.
        hold.modifiersChanged(delivery(55, [.leftCommand], at: 1))
        hold.modifiersChanged(delivery(59, [.leftCommand, .leftControl], at: 1.1))
        hold.modifiersChanged(delivery(58, [.leftCommand, .leftControl, .leftOption], at: 1.2))
        hold.modifiersChanged(delivery(58, [.leftCommand, .leftControl], at: 1.5))
        #expect(hold.listener.completedPress == nil)
        hold.modifiersChanged(delivery(59, [.leftCommand], at: 1.6))
        hold.modifiersChanged(delivery(55, [], at: 1.7))
        // The pair down, then Command joining it.
        hold.modifiersChanged(delivery(59, [.leftControl], at: 2))
        hold.modifiersChanged(delivery(58, [.leftControl, .leftOption], at: 2.1))
        hold.modifiersChanged(delivery(55, [.leftControl, .leftOption, .leftCommand], at: 2.2))
        hold.modifiersChanged(delivery(55, [.leftControl, .leftOption], at: 2.3))
        hold.modifiersChanged(delivery(58, [.leftControl], at: 2.4))
        #expect(hold.listener.completedPress == nil)
        hold.modifiersChanged(delivery(59, [], at: 2.5))
        // A letter typed with the pair held.
        hold.modifiersChanged(delivery(59, [.leftControl], at: 3))
        hold.modifiersChanged(delivery(58, [.leftControl, .leftOption], at: 3.1))
        hold.keyDown(keyCode: 0, flags: [.control, .option])
        hold.modifiersChanged(delivery(58, [.leftControl], at: 3.4))
        #expect(hold.listener.completedPress == nil)
        hold.modifiersChanged(delivery(59, [], at: 3.5))
        hold.keyUp(keyCode: 0)
        // The pair pressed over a letter already held, by the tap's count.
        var overLetter = delivery(58, [.leftControl, .leftOption], at: 3.6)
        overLetter.keysClear = false
        hold.modifiersChanged(delivery(59, [.leftControl], at: 3.55))
        hold.modifiersChanged(overLetter)
        hold.modifiersChanged(delivery(58, [.leftControl], at: 3.8))
        #expect(hold.listener.completedPress == nil)
        hold.modifiersChanged(delivery(59, [], at: 3.9))
        // The pair alone still proves it.
        hold.modifiersChanged(delivery(59, [.leftControl], at: 4))
        hold.modifiersChanged(delivery(58, [.leftControl, .leftOption], at: 4.1))
        hold.modifiersChanged(delivery(58, [.leftControl], at: 4.4))
        #expect(hold.listener.completedPress != nil)
    }

    /// A release HoldKey makes itself, as the keyboard watch does for one
    /// that never arrived, shows the shortcut up again and proves nothing,
    /// while a real release still on its way proves it.
    @Test func aForcedReleaseEndsTheHeldStateWithoutProvingTheKey() {
        let hold = HoldKey(key: .function, holdDelay: 100)
        hold.modifiersChanged(delivery(63, [.function], at: 1))
        #expect(hold.listener.isHeld)
        // Recording a new shortcut releases the trigger through the same
        // release the watch uses.
        hold.recorder = { _ in }
        #expect(!hold.listener.isHeld)
        #expect(hold.listener.completedPress == nil)
        hold.recorder = nil
        hold.modifiersChanged(delivery(63, [], at: 1.3))
        #expect(hold.listener.completedPress != nil)
        // After a forced release, the next press starts afresh: its start is
        // its own, not the earlier press's.
        hold.modifiersChanged(delivery(63, [.function], at: 2))
        hold.recorder = { _ in }
        hold.recorder = nil
        let later = Date().addingTimeInterval(5)
        hold.listener.receivedTrigger(down: true, at: 3, date: later)
        hold.listener.receivedTrigger(down: false, at: 3.2, date: later.addingTimeInterval(0.2))
        #expect(hold.listener.completedPress?.began == later)
    }

    /// A press only shown, as on setup's shortcut page, starts nothing and
    /// is not logged as a rejection; while a click's dictation records, the
    /// key still reaches dictation, so it can end it.
    @Test func aShownPressStartsNothingButStillEndsARecording() {
        let hold = HoldKey(key: .function)
        var time = 2.0
        var presses = 0, rejections = 0
        hold.now = { time }
        hold.keyboardFlags = { [NSEvent.ModifierFlags.function.rawValue] }
        hold.diagnostic = { name, _ in if name == .fnRejected { rejections += 1 } }
        hold.onPress = { presses += 1 }
        hold.pressOnlyShows = { true }
        // Delivered late enough to confirm the 300 ms hold at once.
        hold.modifiersChanged(.init(keyCode: 63, flags: NSEvent.ModifierFlags.function.rawValue, keysClear: true, time: 1.6))
        #expect(hold.holdWasConfirmed)
        #expect(presses == 0)
        #expect(rejections == 0)
        time = 2.5
        hold.modifiersChanged(.init(keyCode: 63, flags: 0, time: time))
        // A dictation a click started is recording: the same press reaches
        // dictation.
        hold.recording = true
        time = 4.0
        hold.modifiersChanged(.init(keyCode: 63, flags: NSEvent.ModifierFlags.function.rawValue, keysClear: true, time: 3.6))
        #expect(presses == 1)
        hold.recording = false
    }

    @Test func onlyABuiltInOrAppleKeyboardCountsAsHavingFn() {
        typealias Keyboard = KeyboardInventory.Keyboard
        #expect(KeyboardInventory.hasFnKey([]) == nil)
        #expect(KeyboardInventory.hasFnKey([Keyboard(builtIn: true, vendorID: nil)]) == true)
        #expect(KeyboardInventory.hasFnKey([Keyboard(builtIn: false, vendorID: 0x05AC)]) == true)
        #expect(KeyboardInventory.hasFnKey([Keyboard(builtIn: false, vendorID: 0x004C)]) == true)
        // A Logitech keyboard alone: its fn never reaches the Mac.
        #expect(KeyboardInventory.hasFnKey([Keyboard(builtIn: false, vendorID: 0x046D)]) == false)
        #expect(KeyboardInventory.hasFnKey([Keyboard(builtIn: false, vendorID: 0x046D), Keyboard(builtIn: true, vendorID: nil)]) == true)
    }
}
