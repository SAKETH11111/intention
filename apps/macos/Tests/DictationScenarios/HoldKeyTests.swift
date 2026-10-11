import AppKit
@testable import Dictation
import Testing

/// The hold-to-talk rules, driven with the modifier changes, key presses
/// and clicks `HoldKey` would see. No key is pressed and no tap is made.
/// A pair's arm delay is a timer in `HoldKey`; here it has passed when
/// `armDelayElapsed` is called, and `HoldKeyTimerTests` runs the timer.
struct HoldKeyTests {
    private typealias Flags = NSEvent.ModifierFlags

    private static let leftControl: UInt16 = 59
    private static let rightControl: UInt16 = 62
    private static let leftOption: UInt16 = 58
    private static let rightOption: UInt16 = 61
    private static let leftCommand: UInt16 = 55
    private static let rightCommand: UInt16 = 54
    private static let leftShift: UInt16 = 56
    private static let fn: UInt16 = 63
    private static let a: UInt16 = 0
    private static let b: UInt16 = 11
    private static let escape: UInt16 = 53
    private static let leftArrow: UInt16 = 123

    /// Control then Option, held alone: arming, not yet held.
    private static func armedControlOption() -> HoldDetector {
        var detector = HoldDetector(key: .controlOption)
        #expect(detector.modifiersChanged(keyCode: leftControl, flags: [.control]) == nil)
        #expect(detector.modifiersChanged(keyCode: leftOption, flags: [.control, .option]) == .arm)
        #expect(detector.arming)
        #expect(!detector.held)
        return detector
    }

    @Test func aPairHeldAloneForTheArmDelayStartsAndStopsWhenEitherKeyComesUp() {
        var detector = Self.armedControlOption()
        #expect(detector.armDelayElapsed() == .press)
        #expect(detector.held)
        #expect(!detector.arming)
        // The delay passes once; it cannot press again.
        #expect(detector.armDelayElapsed() == nil)
        #expect(detector.modifiersChanged(keyCode: Self.leftControl, flags: [.option]) == .release)
        #expect(!detector.held)
        // Letting the second go after the first is not another release.
        #expect(detector.modifiersChanged(keyCode: Self.leftOption, flags: []) == nil)
    }

    @Test func aLetterOrArrowWithinTheArmDelayIsAShortcutAndNeverStarts() {
        // Control+Option+Left: the arrow goes down before the delay has passed.
        var detector = Self.armedControlOption()
        #expect(detector.keyDown(keyCode: Self.leftArrow, flags: [.control, .option]) == nil)
        #expect(!detector.arming)
        #expect(!detector.held)
        #expect(detector.armDelayElapsed() == nil)
        #expect(!detector.held)
        // The arrow comes up; the pair is still down, and still a shortcut's.
        detector.keyUp(keyCode: Self.leftArrow)
        #expect(detector.armDelayElapsed() == nil)
        #expect(!detector.held)
        // Option+Command+Esc, with the letter after a different pair.
        var force = HoldDetector(key: .optionCommand)
        _ = force.modifiersChanged(keyCode: Self.leftCommand, flags: [.command])
        #expect(force.modifiersChanged(keyCode: Self.leftOption, flags: [.command, .option]) == .arm)
        #expect(force.keyDown(keyCode: Self.escape, flags: [.command, .option]) == nil)
        #expect(force.armDelayElapsed() == nil)
        #expect(!force.held)
    }

    @Test func aThirdModifierOrAClickWithinTheArmDelayEndsTheWaitSilently() {
        var detector = Self.armedControlOption()
        #expect(detector.modifiersChanged(keyCode: Self.leftShift, flags: [.control, .option, .shift]) == nil)
        #expect(!detector.arming)
        #expect(detector.armDelayElapsed() == nil)
        var clicked = Self.armedControlOption()
        #expect(clicked.mouseDown(flags: [.control, .option]) == nil)
        #expect(!clicked.arming)
        #expect(clicked.armDelayElapsed() == nil)
        #expect(!clicked.held)
    }

    @Test func aThirdModifierPressedAndLetGoWithinTheArmDelayStartsNothingUntilThePairIsPressedAgain() {
        // Control+Option+Shift, with Shift let go while the pair stays down.
        var detector = Self.armedControlOption()
        #expect(detector.modifiersChanged(keyCode: Self.leftShift, flags: [.control, .option, .shift]) == nil)
        #expect(detector.modifiersChanged(keyCode: Self.leftShift, flags: [.control, .option]) == nil)
        #expect(!detector.arming)
        #expect(detector.armDelayElapsed() == nil)
        // Held on for as long as the person likes, the pair stays a shortcut's.
        #expect(detector.modifiersChanged(keyCode: 57, flags: [.control, .option, .capsLock]) == nil)
        #expect(detector.armDelayElapsed() == nil)
        #expect(!detector.held)
        // One of the pair let go and pressed again is a fresh press.
        #expect(detector.modifiersChanged(keyCode: Self.leftOption, flags: [.control]) == nil)
        #expect(detector.modifiersChanged(keyCode: Self.leftOption, flags: [.control, .option]) == .arm)
        #expect(detector.armDelayElapsed() == .press)
    }

    @Test func aKeyPressedAndLetGoWithinTheArmDelayStartsNothingUntilThePairIsPressedAgain() {
        // Control+Option+Left, the arrow let go while the pair stays down.
        var detector = Self.armedControlOption()
        #expect(detector.keyDown(keyCode: Self.leftArrow, flags: [.control, .option]) == nil)
        detector.keyUp(keyCode: Self.leftArrow)
        #expect(!detector.arming)
        #expect(detector.armDelayElapsed() == nil)
        // A change that leaves the pair as it was, such as Shift pressed and
        // let go or Caps Lock, does not start a new wait either.
        #expect(detector.modifiersChanged(keyCode: Self.leftShift, flags: [.control, .option, .shift]) == nil)
        #expect(detector.modifiersChanged(keyCode: Self.leftShift, flags: [.control, .option]) == nil)
        #expect(detector.modifiersChanged(keyCode: 57, flags: [.control, .option, .capsLock]) == nil)
        #expect(detector.armDelayElapsed() == nil)
        #expect(!detector.held)
        // Control let go and pressed again is a fresh press.
        #expect(detector.modifiersChanged(keyCode: Self.leftControl, flags: [.option]) == nil)
        #expect(detector.modifiersChanged(keyCode: Self.leftControl, flags: [.option, .control]) == .arm)
        #expect(detector.armDelayElapsed() == .press)
        // The same after a click within the wait.
        var clicked = Self.armedControlOption()
        #expect(clicked.mouseDown(flags: [.control, .option]) == nil)
        #expect(clicked.modifiersChanged(keyCode: Self.leftShift, flags: [.control, .option, .shift]) == nil)
        #expect(clicked.modifiersChanged(keyCode: Self.leftShift, flags: [.control, .option]) == nil)
        #expect(clicked.armDelayElapsed() == nil)
        #expect(!clicked.held)
    }

    @Test func aPairCompletedWithAThirdModifierDownDoesNotStartWhenThatModifierIsLetGo() {
        var detector = HoldDetector(key: .controlOption)
        _ = detector.modifiersChanged(keyCode: Self.leftShift, flags: [.shift])
        _ = detector.modifiersChanged(keyCode: Self.leftControl, flags: [.shift, .control])
        #expect(detector.modifiersChanged(keyCode: Self.leftOption, flags: [.shift, .control, .option]) == nil)
        #expect(detector.modifiersChanged(keyCode: Self.leftShift, flags: [.control, .option]) == nil)
        #expect(!detector.arming)
        #expect(detector.armDelayElapsed() == nil)
    }

    @Test func aPairReleasedByLockingDoesNotStartAgainWhileItsKeysStayDown() {
        var detector = Self.armedControlOption()
        #expect(detector.armDelayElapsed() == .press)
        // The screen locks while both keys are down.
        #expect(detector.release() == .release)
        #expect(detector.modifiersChanged(keyCode: Self.leftShift, flags: [.control, .option, .shift]) == nil)
        #expect(detector.modifiersChanged(keyCode: Self.leftShift, flags: [.control, .option]) == nil)
        #expect(detector.armDelayElapsed() == nil)
        #expect(!detector.held)
        // Nor does a pair chosen while its keys are already down.
        var chosen = HoldDetector(key: .controlCommand)
        _ = chosen.modifiersChanged(keyCode: Self.leftControl, flags: [.control])
        _ = chosen.modifiersChanged(keyCode: Self.leftOption, flags: [.control, .option])
        chosen.key = .controlOption
        #expect(chosen.modifiersChanged(keyCode: 57, flags: [.control, .option, .capsLock]) == nil)
        #expect(!chosen.arming)
        #expect(chosen.modifiersChanged(keyCode: Self.leftOption, flags: [.control]) == nil)
        #expect(chosen.modifiersChanged(keyCode: Self.leftOption, flags: [.control, .option]) == .arm)
    }

    @Test func lettingGoDuringTheArmDelayPressesNothing() {
        var detector = Self.armedControlOption()
        #expect(detector.modifiersChanged(keyCode: Self.leftOption, flags: [.control]) == .release)
        #expect(!detector.arming)
        #expect(detector.armDelayElapsed() == nil)
        #expect(!detector.held)
        #expect(detector.modifiersChanged(keyCode: Self.leftControl, flags: []) == nil)
        // Caps Lock toggled while the pair waits does not end the wait.
        var capsLock = Self.armedControlOption()
        #expect(capsLock.modifiersChanged(keyCode: 57, flags: [.control, .option, .capsLock]) == nil)
        #expect(capsLock.arming)
        #expect(capsLock.armDelayElapsed() == .press)
    }

    @MainActor @Test func theArmDelayIsShortAndInsideTheGestureWindow() {
        #expect(HoldDetector.armDelay >= 0.15)
        #expect(HoldDetector.armDelay <= 0.3)
        let window = Duration.seconds(DictationGesture.window)
        #expect(Duration.seconds(HoldDetector.armDelay) < window)
    }

    @Test func eitherSideOfEachKeyAndEitherOrderCounts() {
        var detector = HoldDetector(key: .optionCommand)
        #expect(detector.modifiersChanged(keyCode: Self.rightCommand, flags: [.command]) == nil)
        #expect(detector.modifiersChanged(keyCode: Self.leftOption, flags: [.command, .option]) == .arm)
        #expect(detector.armDelayElapsed() == .press)
        #expect(detector.modifiersChanged(keyCode: Self.rightCommand, flags: [.option]) == .release)
        #expect(detector.modifiersChanged(keyCode: Self.leftOption, flags: []) == nil)
        #expect(detector.modifiersChanged(keyCode: Self.rightOption, flags: [.option]) == nil)
        #expect(detector.modifiersChanged(keyCode: Self.leftCommand, flags: [.option, .command]) == .arm)
        #expect(detector.armDelayElapsed() == .press)
    }

    @Test func aThirdModifierOrAnotherKeyWhileHeldIsReportedAsAnotherKey() {
        var detector = HoldDetector(key: .controlCommand)
        _ = detector.modifiersChanged(keyCode: Self.leftControl, flags: [.control])
        #expect(detector.modifiersChanged(keyCode: Self.leftCommand, flags: [.control, .command]) == .arm)
        #expect(detector.armDelayElapsed() == .press)
        // Control+Command+Left after the delay: the arrow goes down with both
        // keys held, and dictation decides what a key that soon means.
        #expect(detector.keyDown(keyCode: Self.leftArrow, flags: [.control, .command]) == .otherKey)
        #expect(detector.held)
        detector.keyUp(keyCode: Self.leftArrow)
        #expect(detector.modifiersChanged(keyCode: Self.leftShift, flags: [.control, .command, .shift]) == .otherKey)
        #expect(detector.held)
        #expect(detector.modifiersChanged(keyCode: Self.leftCommand, flags: [.control, .shift]) == .release)
    }

    @Test func aCombinationCompletedOverAnotherKeyIsAShortcutAndDoesNotStart() {
        var detector = HoldDetector(key: .controlOption)
        // Control+A, then Option added while A is still down.
        _ = detector.modifiersChanged(keyCode: Self.leftControl, flags: [.control])
        #expect(detector.keyDown(keyCode: Self.a, flags: [.control]) == nil)
        #expect(detector.modifiersChanged(keyCode: Self.leftOption, flags: [.control, .option]) == nil)
        #expect(!detector.arming)
        #expect(detector.armDelayElapsed() == nil)
        #expect(!detector.held)
        // Once A is up the same two keys arm as usual.
        detector.keyUp(keyCode: Self.a)
        _ = detector.modifiersChanged(keyCode: Self.leftOption, flags: [.control])
        #expect(detector.modifiersChanged(keyCode: Self.leftOption, flags: [.control, .option]) == .arm)
    }

    @Test func aPairPressedWhileAnotherKeyIsStillDownDoesNotStart() {
        // A and B held, A let go, then the pair pressed over B.
        var detector = HoldDetector(key: .controlOption)
        _ = detector.keyDown(keyCode: Self.a, flags: [])
        _ = detector.keyDown(keyCode: Self.b, flags: [])
        detector.keyUp(keyCode: Self.a)
        _ = detector.modifiersChanged(keyCode: Self.leftControl, flags: [.control])
        #expect(detector.modifiersChanged(keyCode: Self.leftOption, flags: [.control, .option]) == nil)
        #expect(!detector.arming)
        #expect(detector.armDelayElapsed() == nil)
        #expect(!detector.held)
        // B up, then the pair pressed again: it starts.
        detector.keyUp(keyCode: Self.b)
        _ = detector.modifiersChanged(keyCode: Self.leftOption, flags: [.control])
        #expect(detector.modifiersChanged(keyCode: Self.leftOption, flags: [.control, .option]) == .arm)
        // A key repeating while held is still one key, gone at its one release.
        var repeating = HoldDetector(key: .controlOption)
        for _ in 0..<3 { _ = repeating.keyDown(keyCode: Self.a, flags: []) }
        repeating.keyUp(keyCode: Self.a)
        _ = repeating.modifiersChanged(keyCode: Self.leftControl, flags: [.control])
        #expect(repeating.modifiersChanged(keyCode: Self.leftOption, flags: [.control, .option]) == .arm)
    }

    @Test func aKeyHeldWhileEveryModifierComesUpIsStillDown() {
        // B held while Control is tapped, then the pair pressed over B.
        var detector = HoldDetector(key: .controlOption)
        _ = detector.keyDown(keyCode: Self.b, flags: [])
        _ = detector.modifiersChanged(keyCode: Self.leftControl, flags: [.control])
        _ = detector.modifiersChanged(keyCode: Self.leftControl, flags: [])
        _ = detector.modifiersChanged(keyCode: Self.leftControl, flags: [.control])
        #expect(detector.modifiersChanged(keyCode: Self.leftOption, flags: [.control, .option]) == nil)
        #expect(!detector.arming)
    }

    @Test func aKeyWhoseReleaseWasMissedIsForgottenOnceTheKeyboardShowsItUp() {
        // A went down and its release never arrived, as secure input can hide it.
        var detector = HoldDetector(key: .controlOption)
        var keyboard: Set<UInt16> = [Self.a]
        detector.keyboardShowsDown = { keyboard.contains($0) }
        _ = detector.keyDown(keyCode: Self.a, flags: [])
        _ = detector.modifiersChanged(keyCode: Self.leftControl, flags: [.control])
        // The keyboard still shows A down: the pair is a shortcut's.
        #expect(detector.modifiersChanged(keyCode: Self.leftOption, flags: [.control, .option]) == nil)
        _ = detector.modifiersChanged(keyCode: Self.leftOption, flags: [.control])
        // A is up by the keyboard's own account.
        keyboard = []
        #expect(detector.modifiersChanged(keyCode: Self.leftOption, flags: [.control, .option]) == .arm)
        #expect(detector.armDelayElapsed() == .press)
    }

    @Test func aCombinationWithMoreThanItsKeysDownDoesNotStart() {
        var detector = HoldDetector(key: .controlOption)
        _ = detector.modifiersChanged(keyCode: Self.leftShift, flags: [.shift])
        _ = detector.modifiersChanged(keyCode: Self.leftControl, flags: [.shift, .control])
        #expect(detector.modifiersChanged(keyCode: Self.leftOption, flags: [.shift, .control, .option]) == nil)
        #expect(!detector.arming)
        var withFn = HoldDetector(key: .optionCommand)
        _ = withFn.modifiersChanged(keyCode: Self.fn, flags: [.function])
        _ = withFn.modifiersChanged(keyCode: Self.leftOption, flags: [.function, .option])
        #expect(withFn.modifiersChanged(keyCode: Self.leftCommand, flags: [.function, .option, .command]) == nil)
        // Caps Lock on is not a held key.
        var capsLock = HoldDetector(key: .controlCommand)
        _ = capsLock.modifiersChanged(keyCode: Self.leftControl, flags: [.capsLock, .control])
        #expect(capsLock.modifiersChanged(keyCode: Self.leftCommand, flags: [.capsLock, .control, .command]) == .arm)
    }

    @Test func aKeyOrClickWithoutTheCombinationsBitsLeavesItHeld() {
        var detector = Self.armedControlOption()
        _ = detector.armDelayElapsed()
        // A click with the pair held is a modified click, such as
        // Control-Option-click.
        #expect(detector.mouseDown(flags: [.control, .option]) == .click)
        #expect(detector.held)
        #expect(detector.keyDown(keyCode: Self.a, flags: [.option]) == .otherKey)
        #expect(detector.held)
        _ = detector.release()
        detector.keyUp(keyCode: Self.a)
        _ = detector.modifiersChanged(keyCode: Self.leftOption, flags: [.control])
        _ = detector.modifiersChanged(keyCode: Self.leftOption, flags: [.control, .option])
        _ = detector.armDelayElapsed()
        #expect(detector.mouseDown(flags: []) == .click)
    }

    @Test func aSingleKeyIsHeldFromItsOwnPressToItsOwnReleaseWithNoWait() {
        var detector = HoldDetector(key: .rightOption)
        let rightOptionBit = Flags(rawValue: 0x40)
        // The left Option key is not the dictation key.
        #expect(detector.modifiersChanged(keyCode: Self.leftOption, flags: [.option]) == nil)
        #expect(detector.modifiersChanged(keyCode: Self.rightOption, flags: [.option, rightOptionBit]) == .press)
        #expect(!detector.arming)
        // Left Option let go while the right one stays down hides nothing.
        #expect(detector.modifiersChanged(keyCode: Self.leftOption, flags: [.option, rightOptionBit]) == .otherKey)
        #expect(detector.keyDown(keyCode: Self.a, flags: [.option, rightOptionBit]) == .otherKey)
        #expect(detector.held)
        #expect(detector.modifiersChanged(keyCode: Self.rightOption, flags: []) == .release)
        var fn = HoldDetector(key: .function)
        #expect(fn.modifiersChanged(keyCode: Self.fn, flags: [.function]) == .press)
        // No arm delay is ever pending for a single key.
        #expect(fn.armDelayElapsed() == nil)
        #expect(fn.held)
        #expect(fn.keyDown(keyCode: Self.a, flags: []) == .otherKey)
        #expect(fn.release() == .release)
    }

    @Test func aChangeForAnotherModifierCannotReleaseTheHeldKey() {
        // Every modifier change carries the whole keyboard's flags, so one
        // without the key's bit says it is up, even under another key's code.
        let rightOptionBit = Flags(rawValue: 0x40)
        var detector = HoldDetector(key: .rightOption)
        #expect(detector.modifiersChanged(keyCode: Self.rightOption, flags: [.option, rightOptionBit]) == .press)
        #expect(detector.modifiersChanged(keyCode: Self.leftShift, flags: [.option, rightOptionBit, .shift]) == .otherKey)
        #expect(detector.modifiersChanged(keyCode: Self.leftShift, flags: []) == nil)
        #expect(detector.held)
        var fn = HoldDetector(key: .function)
        #expect(fn.modifiersChanged(keyCode: Self.fn, flags: [.function]) == .press)
        #expect(fn.modifiersChanged(keyCode: Self.leftControl, flags: [.control]) == .otherKey)
        #expect(fn.modifiersChanged(keyCode: Self.leftControl, flags: []) == nil)
    }

    @Test func aPressWithAnotherModifierOrKeyAlreadyHeldIsNotAlone() {
        let command = Flags(rawValue: Flags.command.rawValue | 0x10)
        var detector = HoldDetector(key: .rightCommand)
        detector.keyboardShowsDown = { _ in true }
        #expect(detector.modifiersChanged(keyCode: Self.rightCommand, flags: command) == .press)
        #expect(detector.pressAlone)
        _ = detector.modifiersChanged(keyCode: Self.rightCommand, flags: [])
        _ = detector.modifiersChanged(keyCode: Self.leftShift, flags: [.shift])
        #expect(detector.modifiersChanged(keyCode: Self.rightCommand, flags: command.union(.shift)) == .press)
        #expect(!detector.pressAlone)
        _ = detector.modifiersChanged(keyCode: Self.rightCommand, flags: [.shift])
        _ = detector.modifiersChanged(keyCode: Self.leftShift, flags: [])
        _ = detector.keyDown(keyCode: Self.a, flags: [])
        #expect(detector.modifiersChanged(keyCode: Self.rightCommand, flags: command) == .press)
        #expect(!detector.pressAlone)
        // A click with the key held is a modified click, as Command-click on
        // a link is, and no shortcut's key.
        #expect(detector.mouseDown(flags: command) == .click)
        #expect(detector.held)
    }

    @Test func theTapsWordOnOtherKeysIsTakenOverTheKeyboardsLaterState() {
        // A down, Right Command down, A up, Right Command up, all queued:
        // by the time the main actor reads the keyboard A is already up,
        // but the tap counted A down at Right Command's press.
        let command = Flags(rawValue: Flags.command.rawValue | 0x10)
        var detector = HoldDetector(key: .rightCommand)
        detector.keyboardShowsDown = { _ in false }
        _ = detector.keyDown(keyCode: Self.a, flags: [])
        #expect(detector.modifiersChanged(keyCode: Self.rightCommand, flags: command, keysClear: false) == .press)
        #expect(!detector.pressAlone)
        // A pair completed over a key the tap counted down is a shortcut.
        var pair = HoldDetector(key: .controlOption)
        pair.keyboardShowsDown = { _ in false }
        _ = pair.modifiersChanged(keyCode: Self.leftControl, flags: [.control], keysClear: false)
        #expect(pair.modifiersChanged(keyCode: Self.leftOption, flags: [.control, .option], keysClear: false) == nil)
        #expect(!pair.arming)
        // The tap follows the events; when it handles Right Command, a
        // moment after A went down, the keyboard still shows A.
        var claims = KeyClaims()
        claims.trigger = .rightCommand
        claims.keyShowsDown = { _ in true }
        #expect(claims.keysClear)
        claims.key(Self.a, down: true, flags: [])
        claims.modifiersChanged(keyCode: Self.rightCommand, flags: command)
        #expect(!claims.keysClear)
        claims.key(Self.a, down: false, flags: command)
        #expect(claims.keysClear)
    }

    @Test func spaceWithTheKeyHeldTurnsTheHoldHandsFree() {
        var fn = HoldDetector(key: .function)
        #expect(fn.space() == nil)
        #expect(fn.modifiersChanged(keyCode: Self.fn, flags: [.function]) == .press)
        #expect(fn.space() == .handsFree)
        // Letting go is still the key's release; dictation decides that a
        // hands-free dictation goes on.
        #expect(fn.modifiersChanged(keyCode: Self.fn, flags: []) == .release)
        #expect(fn.space() == nil)
        var pair = Self.armedControlOption()
        #expect(pair.armDelayElapsed() == .press)
        #expect(pair.space() == .handsFree)
    }

    @Test func onlyFnIsConsumedAndOnlyWhileDictationCanRun() {
        #expect(HoldKey.Key.function.consumedKeyCode(dictationAvailable: true) == 63)
        #expect(HoldKey.Key.function.consumedKeyCode(dictationAvailable: false) == nil)
        let others = HoldKey.Modifier.allCases.filter { $0 != .function }.map(HoldKey.Key.single) + HoldKey.Key.suggested.filter(\.isCombination)
            + [.combination([.function, .control])]
        for key in others {
            #expect(key.consumedKeyCode(dictationAvailable: true) == nil)
            #expect(key.consumedKeyCode(dictationAvailable: false) == nil)
        }
    }

    @Test func aTriggerIsStillDownOnlyWhenAStateShowsEveryOneOfItsKeys() {
        let controlOption = Flags([.control, .option]).rawValue
        #expect(HoldKey.Key.controlOption.isDown(in: [0, controlOption]))
        #expect(HoldKey.Key.controlOption.isDown(in: [Flags([.control, .option, .shift]).rawValue]))
        // One key of the pair, in either state, is not the pair.
        #expect(!HoldKey.Key.controlOption.isDown(in: [Flags.control.rawValue, Flags.option.rawValue]))
        #expect(!HoldKey.Key.controlOption.isDown(in: []))
        #expect(HoldKey.Key.function.isDown(in: [Flags.function.rawValue]))
        #expect(!HoldKey.Key.function.isDown(in: [Flags.option.rawValue]))
        // The right-hand keys are read by their own device bit.
        #expect(HoldKey.Key.rightOption.isDown(in: [Flags.option.rawValue | 0x40]))
        #expect(!HoldKey.Key.rightOption.isDown(in: [Flags.option.rawValue]))
        #expect(HoldKey.Key.single(.rightControl).isDown(in: [Flags.control.rawValue | 0x2000]))
        #expect(!HoldKey.Key.single(.rightControl).isDown(in: [Flags.control.rawValue | 0x1]))
        // Three keys held together are down only with all three.
        let three = HoldKey.Key.combination([.control, .option, .command])
        #expect(three.isDown(in: [Flags([.control, .option, .command]).rawValue]))
        #expect(!three.isDown(in: [Flags([.control, .option]).rawValue]))
    }

    @Test func aRecordedRightControlIsHeldFromItsPressToItsRelease() {
        var detector = HoldDetector(key: .single(.rightControl))
        let rightControlBit = Flags(rawValue: 0x2000)
        #expect(detector.modifiersChanged(keyCode: Self.rightControl, flags: [.control, rightControlBit]) == .press)
        // The left-hand key going down and up beside it is another modifier.
        #expect(detector.modifiersChanged(keyCode: Self.leftControl, flags: [.control, rightControlBit, Flags(rawValue: 0x1)]) == .otherKey)
        #expect(detector.modifiersChanged(keyCode: Self.rightControl, flags: []) == .release)
        // Left Control alone is not it.
        #expect(detector.modifiersChanged(keyCode: Self.leftControl, flags: [.control, Flags(rawValue: 0x1)]) == nil)
        #expect(!detector.held)
    }

    @Test func aRecordedPairWithShiftArmsLikeAnyOtherPair() {
        var detector = HoldDetector(key: .combination([.shift, .option]))
        #expect(detector.modifiersChanged(keyCode: Self.leftShift, flags: [.shift]) == nil)
        #expect(detector.modifiersChanged(keyCode: Self.leftOption, flags: [.shift, .option]) == .arm)
        #expect(detector.armDelayElapsed() == .press)
        #expect(detector.modifiersChanged(keyCode: Self.leftShift, flags: [.option]) == .release)
        // Typed with a letter before the delay, it is a shortcut and starts nothing.
        #expect(detector.modifiersChanged(keyCode: Self.leftOption, flags: []) == nil)
        #expect(detector.modifiersChanged(keyCode: Self.leftShift, flags: [.shift]) == nil)
        #expect(detector.modifiersChanged(keyCode: Self.leftOption, flags: [.shift, .option]) == .arm)
        #expect(detector.keyDown(keyCode: Self.a, flags: [.shift, .option]) == nil)
        #expect(detector.armDelayElapsed() == nil)
        #expect(!detector.held)
    }

    @Test func singleKeysKeepTheirCodesAndCombinationsNameBothKeys() {
        #expect(HoldKey.Key.suggested.filter { !$0.isCombination }.map(\.keyCode) == [63, 61, 54])
        #expect(HoldKey.Key.suggested.filter(\.isCombination).allSatisfy { $0.keyCode == nil })
        #expect(HoldKey.Key.suggested.count == 6)
        #expect(HoldKey.Key.single(.rightControl).keyCode == 62)
        #expect(HoldKey.Key.single(.rightControl).title == "Right Control")
        // A combination is named in the Mac's order of modifiers, whatever
        // order its keys were pressed in.
        #expect(HoldKey.Key.combination([.command, .shift, .function]).title == "Fn + Shift + Command")
        #expect(HoldKey.Key.controlOption.title == "Control + Option")
        #expect(HoldKey.Key.controlCommand.title == "Control + Command")
        #expect(HoldKey.Key.optionCommand.title == "Option + Command")
        #expect(HoldKey.Key.controlOption.mask == Flags([.control, .option]).rawValue)
        // Setup names a pair as Settings does, and the single keys as their keycaps read.
        #expect(FirstDictation.keycap(.controlOption) == "Control + Option")
        #expect(FirstDictation.keycap(.optionCommand) == "Option + Command")
        #expect(FirstDictation.keycap(.function) == "fn")
        #expect(FirstDictation.keycap(.single(.rightControl)) == "right control")
    }
}

/// Which key presses the dictation key's tap takes, decided on the tap's
/// own thread as each one arrives. Nothing is posted and no tap is made.
struct KeyClaimsTests {
    private typealias Flags = NSEvent.ModifierFlags
    private typealias Answer = KeyClaims.Answer

    private static let fn: UInt16 = 63
    private static let rightOption: UInt16 = 61
    private static let leftOption: UInt16 = 58
    private static let rightCommand: UInt16 = 54
    private static let leftControl: UInt16 = 59
    private static let leftShift: UInt16 = 56
    private static let space: UInt16 = 49
    private static let escape: UInt16 = 53
    private static let globe: UInt16 = 179
    private static let a: UInt16 = 0
    private static let b: UInt16 = 11

    @Test func spaceWithFnHeldIsTakenWithItsRepeatsAndItsRelease() {
        var claims = KeyClaims()
        claims.trigger = .function
        claims.takesSpace = true
        claims.modifiersChanged(keyCode: Self.fn, flags: [.function])
        #expect(claims.key(Self.space, down: true, flags: [.function]) == Answer(take: true, claim: .handsFree))
        #expect(claims.key(Self.space, down: true, flags: [.function], isRepeat: true) == Answer(take: true, claim: nil))
        // Fn let go before Space: Space's release is still taken, so no app
        // sees it come up without having seen it go down.
        claims.modifiersChanged(keyCode: Self.fn, flags: [])
        #expect(claims.key(Self.space, down: false, flags: []) == Answer(take: true, claim: nil))
        // Space alone afterwards types as always.
        #expect(claims.key(Self.space, down: true, flags: []) == Answer(take: false, claim: nil))
        #expect(claims.key(Self.space, down: false, flags: []) == Answer(take: false, claim: nil))
        // Fn with another key, such as Fn-A, is left alone.
        claims.modifiersChanged(keyCode: Self.fn, flags: [.function])
        #expect(claims.key(Self.a, down: true, flags: [.function]) == Answer(take: false, claim: nil))
    }

    @Test func spaceIsTakenOnlyWithTheChosenKeyDown() {
        var claims = KeyClaims()
        let rightOptionBit = Flags(rawValue: 0x40), leftOptionBit = Flags(rawValue: 0x20)
        claims.trigger = .rightOption
        claims.takesSpace = true
        // Left Option and Space type a no-break space, as they always have.
        claims.modifiersChanged(keyCode: Self.leftOption, flags: [.option, leftOptionBit])
        #expect(claims.key(Self.space, down: true, flags: [.option, leftOptionBit]) == Answer(take: false, claim: nil))
        #expect(claims.key(Self.space, down: false, flags: [.option, leftOptionBit]) == Answer(take: false, claim: nil))
        claims.modifiersChanged(keyCode: Self.leftOption, flags: [])
        claims.modifiersChanged(keyCode: Self.rightOption, flags: [.option, rightOptionBit])
        #expect(claims.key(Self.space, down: true, flags: [.option, rightOptionBit]) == Answer(take: true, claim: .handsFree))
        // Right Command chosen: Command-Space with it is hands-free dictation,
        // not Spotlight, which the left Command still opens.
        var command = KeyClaims()
        command.trigger = .rightCommand
        command.takesSpace = true
        command.modifiersChanged(keyCode: Self.rightCommand, flags: [.command, Flags(rawValue: 0x10)])
        #expect(command.key(Self.space, down: true, flags: [.command, Flags(rawValue: 0x10)]) == Answer(take: true, claim: .handsFree))
        // Space is not taken while dictation cannot run or Settings records
        // a key: Fn-Space is left to the system and to other apps.
        var off = KeyClaims()
        off.trigger = .function
        off.modifiersChanged(keyCode: Self.fn, flags: [.function])
        #expect(off.key(Self.space, down: true, flags: [.function]) == Answer(take: false, claim: nil))
        // A press whose release was lost answers afresh.
        var lost = KeyClaims()
        lost.trigger = .function
        lost.takesSpace = true
        lost.modifiersChanged(keyCode: Self.fn, flags: [.function])
        #expect(lost.key(Self.space, down: true, flags: [.function]).take)
        lost.modifiersChanged(keyCode: Self.fn, flags: [])
        #expect(lost.key(Self.space, down: true, flags: []) == Answer(take: false, claim: nil))
    }

    @Test func aChosenPairTakesSpaceBeforeOrAfterItsArmDelay() {
        var claims = KeyClaims()
        claims.trigger = .controlOption
        claims.takesSpace = true
        claims.modifiersChanged(keyCode: Self.leftControl, flags: [.control])
        claims.modifiersChanged(keyCode: Self.leftOption, flags: [.control, .option])
        // Within the arm delay Control-Option-Space is a shortcut's, as
        // VoiceOver's, and goes through.
        #expect(claims.key(Self.space, down: true, flags: [.control, .option]) == Answer(take: true, claim: .handsFree))
        #expect(claims.key(Self.space, down: false, flags: [.control, .option]) == Answer(take: true, claim: nil))
        let first = claims.generation
        claims.held(true, generation: first)
        #expect(claims.key(Self.space, down: true, flags: [.control, .option]) == Answer(take: true, claim: .handsFree))
        #expect(claims.key(Self.space, down: false, flags: [.control, .option]).take)
        // Let go, the hold is over for the tap at once, before the main
        // actor hears of it.
        claims.modifiersChanged(keyCode: Self.leftOption, flags: [.control])
        #expect(claims.key(Self.space, down: true, flags: [.control]) == Answer(take: false, claim: nil))
        claims.key(Self.space, down: false, flags: [.control])
        // Pressed again and still within its arm delay, a hold published
        // late for the earlier press takes nothing.
        claims.modifiersChanged(keyCode: Self.leftOption, flags: [.control, .option])
        claims.held(true, generation: first)
        #expect(claims.key(Self.space, down: true, flags: [.control, .option]) == Answer(take: true, claim: .handsFree))
        claims.key(Self.space, down: false, flags: [.control, .option])
        claims.held(true, generation: claims.generation)
        #expect(claims.key(Self.space, down: true, flags: [.control, .option]) == Answer(take: true, claim: .handsFree))
    }

    @Test func aKeyAlreadyHeldMakesTheKeysPressAShortcutsForSpaceToo() {
        // A held, then Fn, then Space: the rules call the press no press of
        // its own, and the tap, which saw A go down, takes no Space.
        final class Keyboard: @unchecked Sendable { var down: Set<UInt16> = [0] }
        let keyboard = Keyboard()
        var claims = KeyClaims()
        claims.trigger = .function
        claims.takesSpace = true
        claims.keyShowsDown = { keyboard.down.contains($0) }
        #expect(claims.key(Self.a, down: true, flags: []) == Answer(take: false, claim: nil))
        claims.modifiersChanged(keyCode: Self.fn, flags: [.function])
        #expect(claims.key(Self.space, down: true, flags: [.function]) == Answer(take: false, claim: nil))
        claims.key(Self.space, down: false, flags: [.function])
        claims.key(Self.a, down: false, flags: [.function])
        claims.modifiersChanged(keyCode: Self.fn, flags: [])
        claims.modifiersChanged(keyCode: Self.fn, flags: [.function])
        #expect(claims.key(Self.space, down: true, flags: [.function]) == Answer(take: true, claim: .handsFree))
        claims.key(Self.space, down: false, flags: [.function])
        claims.modifiersChanged(keyCode: Self.fn, flags: [])
        // A's release lost: the keyboard, asked at the next press, shows A
        // up, and A is forgotten.
        claims.key(Self.a, down: true, flags: [])
        keyboard.down = []
        claims.modifiersChanged(keyCode: Self.fn, flags: [.function])
        #expect(claims.key(Self.space, down: true, flags: [.function]) == Answer(take: true, claim: .handsFree))
    }

    @Test func aSpacePressedRightAfterTheKeyIsNotHeldAgainstIt() {
        // Fn, then Space so soon that the keyboard already shows Space down
        // when the tap sees Fn: Space came after, in the events' order.
        var claims = KeyClaims()
        claims.trigger = .function
        claims.takesSpace = true
        claims.keyShowsDown = { _ in true }
        claims.modifiersChanged(keyCode: Self.fn, flags: [.function])
        #expect(claims.key(Self.space, down: true, flags: [.function]) == Answer(take: true, claim: .handsFree))
    }

    @Test func aSpaceHeldBeforeTheKeyMakesItsPressAShortcutsUntilLetGo() {
        // Space held, then Fn, then Space let go and pressed again with Fn
        // still held: the rules called Fn no press of its own, and so does
        // the tap, which followed Space in the events' order.
        var claims = KeyClaims()
        claims.trigger = .function
        claims.takesSpace = true
        final class Keyboard: @unchecked Sendable { var spaceDown = true }
        let keyboard = Keyboard()
        claims.keyShowsDown = { $0 == Self.space && keyboard.spaceDown }
        #expect(claims.key(Self.space, down: true, flags: []) == Answer(take: false, claim: nil))
        claims.modifiersChanged(keyCode: Self.fn, flags: [.function])
        #expect(claims.key(Self.space, down: false, flags: [.function]) == Answer(take: false, claim: nil))
        #expect(claims.key(Self.space, down: true, flags: [.function]) == Answer(take: false, claim: nil))
        // A Space whose release the tap missed, which the keyboard shows up,
        // is forgotten at the next press.
        claims.modifiersChanged(keyCode: Self.fn, flags: [])
        keyboard.spaceDown = false
        claims.modifiersChanged(keyCode: Self.fn, flags: [.function])
        #expect(claims.key(Self.space, down: true, flags: [.function]) == Answer(take: true, claim: .handsFree))
    }

    @Test func aReleaseStillOnItsWayToTheTapLeavesItsKeyDownAtThePress() {
        // A down, Right Command down, A up 3 ms later, and the tap handling
        // Right Command after that: the keyboard already shows A up, but
        // its release came after the press, so A was down at it.
        let command = Flags(rawValue: Flags.command.rawValue | 0x10)
        var claims = KeyClaims()
        claims.trigger = .rightCommand
        claims.takesSpace = true
        claims.keyShowsDown = { _ in false }
        claims.key(Self.a, down: true, flags: [])
        claims.modifiersChanged(keyCode: Self.rightCommand, flags: command, releasesArrived: { false })
        #expect(!claims.keysClear)
        #expect(claims.key(Self.space, down: true, flags: command) == Answer(take: false, claim: nil))
        var detector = HoldDetector(key: .rightCommand)
        detector.keyboardShowsDown = { _ in false }
        _ = detector.keyDown(keyCode: Self.a, flags: [])
        #expect(detector.modifiersChanged(keyCode: Self.rightCommand, flags: command, keysClear: claims.keysClear) == .press)
        #expect(!detector.pressAlone)
        // The same for a pair completed over A and held past its delay.
        var pair = KeyClaims()
        pair.trigger = .controlOption
        pair.keyShowsDown = { _ in false }
        pair.key(Self.a, down: true, flags: [])
        pair.modifiersChanged(keyCode: Self.leftControl, flags: [.control], releasesArrived: { false })
        pair.modifiersChanged(keyCode: Self.leftOption, flags: [.control, .option], releasesArrived: { false })
        #expect(!pair.keysClear)
        var pairRules = HoldDetector(key: .controlOption)
        pairRules.keyboardShowsDown = { _ in false }
        _ = pairRules.keyDown(keyCode: Self.a, flags: [])
        _ = pairRules.modifiersChanged(keyCode: Self.leftControl, flags: [.control], keysClear: pair.keysClear)
        #expect(pairRules.modifiersChanged(keyCode: Self.leftOption, flags: [.control, .option], keysClear: pair.keysClear) == nil)
        #expect(!pairRules.arming)
    }

    @Test func aKeyLetGoAsTheTapReadsTheKeyboardStaysDownAtThePress() {
        // A held, then Right Command, and A let go just as the tap reads the
        // keyboard at Command's press: the timing check comes after the
        // read, so it sees that release, made after the press.
        final class Keyboard: @unchecked Sendable { var letGoAfterPress = false }
        let command = Flags(rawValue: Flags.command.rawValue | 0x10)
        let keyboard = Keyboard()
        var claims = KeyClaims()
        claims.trigger = .rightCommand
        claims.takesSpace = true
        claims.keyShowsDown = { _ in
            keyboard.letGoAfterPress = true
            return false
        }
        claims.key(Self.a, down: true, flags: [])
        claims.modifiersChanged(keyCode: Self.rightCommand, flags: command, releasesArrived: { !keyboard.letGoAfterPress })
        #expect(!claims.keysClear)
        #expect(claims.key(Self.space, down: true, flags: command) == Answer(take: false, claim: nil))
        // A pair completed over A, the same way.
        let pairKeyboard = Keyboard()
        var pair = KeyClaims()
        pair.trigger = .controlOption
        pair.keyShowsDown = { _ in
            pairKeyboard.letGoAfterPress = true
            return false
        }
        pair.key(Self.a, down: true, flags: [])
        pair.modifiersChanged(keyCode: Self.leftControl, flags: [.control], releasesArrived: { !pairKeyboard.letGoAfterPress })
        pair.modifiersChanged(keyCode: Self.leftOption, flags: [.control, .option],
                              releasesArrived: { !pairKeyboard.letGoAfterPress })
        #expect(!pair.keysClear)
    }

    @Test func aPressQueuedBeforeTheTapKnewWhatWasHeldIsNeverAlone() {
        // The tap was seeded and started at 1000 ticks. Right Command came
        // down at 900, queued for it before then, with A perhaps held and
        // its press still on its way to the monitors: not alone, and no
        // Space is taken for it. A press after the start is judged as usual.
        let command = Flags(rawValue: Flags.command.rawValue | 0x10)
        var claims = KeyClaims()
        claims.trigger = .rightCommand
        claims.takesSpace = true
        claims.startedAt = 1000
        claims.modifiersChanged(keyCode: Self.rightCommand, flags: command, stamp: 900)
        #expect(!claims.keysClear)
        #expect(claims.key(Self.space, down: true, flags: command) == Answer(take: false, claim: nil))
        claims.key(Self.space, down: false, flags: command)
        claims.modifiersChanged(keyCode: Self.rightCommand, flags: [], stamp: 950)
        claims.modifiersChanged(keyCode: Self.rightCommand, flags: command, stamp: 1100)
        #expect(claims.keysClear)
        #expect(claims.key(Self.space, down: true, flags: command) == Answer(take: true, claim: .handsFree))
        // A pair completed before the start never arms.
        var pair = KeyClaims()
        pair.trigger = .controlOption
        pair.startedAt = 1000
        pair.modifiersChanged(keyCode: Self.leftControl, flags: [.control], stamp: 900)
        pair.modifiersChanged(keyCode: Self.leftOption, flags: [.control, .option], stamp: 950)
        #expect(!pair.keysClear)
        var rules = HoldDetector(key: .controlOption)
        _ = rules.modifiersChanged(keyCode: Self.leftControl, flags: [.control], keysClear: pair.keysClear)
        #expect(rules.modifiersChanged(keyCode: Self.leftOption, flags: [.control, .option], keysClear: pair.keysClear) == nil)
        #expect(!rules.arming)
    }

    @Test func timePassingBeforeTheClockIsReadCountsAgainstTheRelease() {
        // Right Command stamped at 500 ms and A's release recorded at 503.2
        // ms. The tap's thread pauses until 510 ms before asking for the
        // latest release, which is then 6.8 ms old; the clock, read after
        // it, makes the press 10 ms old, so the release came after it.
        var ms: UInt64 = 505
        let late = KeyClaims.releasesPrecede(stamp: 500, latestRelease: {
            ms = 510
            return 0.0068
        }, now: { ms }, tickSeconds: 0.001)
        #expect(!late)
        // A release recorded 20 ms before 510 ms came before the press.
        ms = 505
        let early = KeyClaims.releasesPrecede(stamp: 500, latestRelease: {
            ms = 510
            return 0.020
        }, now: { ms }, tickSeconds: 0.001)
        #expect(early)
        // No stamp, or one after now, is uncertain.
        #expect(!KeyClaims.releasesPrecede(stamp: 0, latestRelease: { 1 }, now: { 505 }, tickSeconds: 0.001))
        #expect(!KeyClaims.releasesPrecede(stamp: 600, latestRelease: { 1 }, now: { 505 }, tickSeconds: 0.001))
    }

    @Test func releasesPrecedeAChangeOnlyWhenTheLatestCameBeforeIt() {
        // A change 5 ms old: a release recorded 2 ms ago came after it, one
        // recorded 10 ms ago before it, and one within a millisecond of it
        // waits for its event.
        #expect(!KeyClaims.releasesPrecede(age: 0.005, sinceLatestRelease: 0.002))
        #expect(KeyClaims.releasesPrecede(age: 0.005, sinceLatestRelease: 0.010))
        #expect(!KeyClaims.releasesPrecede(age: 0.005, sinceLatestRelease: 0.0055))
    }

    @Test func aKeyTheMonitorsSawHeldBeforeTheTapBeganStillCounts() {
        // A down while only the monitors watched; the tap begins with A
        // still held, then Right Command, or a pair, goes down over it.
        var detector = HoldDetector(key: .rightCommand)
        _ = detector.keyDown(keyCode: Self.a, flags: [])
        #expect(detector.keysHeld == [Self.a])
        let command = Flags(rawValue: Flags.command.rawValue | 0x10)
        var claims = KeyClaims()
        claims.trigger = .rightCommand
        claims.takesSpace = true
        claims.keyShowsDown = { $0 == Self.a }
        claims.seed(keysDown: detector.keysHeld)
        claims.modifiersChanged(keyCode: Self.rightCommand, flags: command)
        #expect(!claims.keysClear)
        #expect(claims.key(Self.space, down: true, flags: command) == Answer(take: false, claim: nil))
        var pair = KeyClaims()
        pair.trigger = .controlOption
        pair.keyShowsDown = { $0 == Self.a }
        pair.seed(keysDown: [Self.a])
        pair.modifiersChanged(keyCode: Self.leftControl, flags: [.control])
        pair.modifiersChanged(keyCode: Self.leftOption, flags: [.control, .option])
        #expect(!pair.keysClear)
    }

    @Test func aReleaseOfAKeyTheTapNeverSawGoDownForgetsNoOtherKey() {
        // A went down before the tap existed; then B down, then A up with B
        // still held: B keeps Right Command's press from being alone.
        let command = Flags(rawValue: Flags.command.rawValue | 0x10)
        var claims = KeyClaims()
        claims.trigger = .rightCommand
        claims.takesSpace = true
        claims.keyShowsDown = { $0 == Self.b }
        claims.key(Self.b, down: true, flags: [])
        claims.key(Self.a, down: false, flags: [])
        claims.modifiersChanged(keyCode: Self.rightCommand, flags: command)
        #expect(!claims.keysClear)
        #expect(claims.key(Self.space, down: true, flags: command) == Answer(take: false, claim: nil))
        // A missed A release while Fn is pressed and Space follows at once:
        // only A is forgotten, and the Space after Fn is taken.
        var fn = KeyClaims()
        fn.trigger = .function
        fn.takesSpace = true
        fn.keyShowsDown = { $0 == Self.space }
        fn.key(Self.a, down: true, flags: [])
        fn.modifiersChanged(keyCode: Self.fn, flags: [.function])
        #expect(fn.keysClear)
        #expect(fn.key(Self.space, down: true, flags: [.function]) == Answer(take: true, claim: .handsFree))
    }

    @Test func aPressAfterAReleaseOnlyTheWatchSawIsAPressOfItsOwn() {
        // Fn's release never reached the tap; the watch ended the hold. The
        // next press takes Space at once.
        var claims = KeyClaims()
        claims.trigger = .function
        claims.takesSpace = true
        claims.modifiersChanged(keyCode: Self.fn, flags: [.function])
        let first = claims.generation
        let ended = claims.withdraw(generation: first, handled: nil)
        #expect(ended)
        claims.modifiersChanged(keyCode: Self.fn, flags: [.function])
        #expect(claims.generation == first + 1)
        #expect(claims.key(Self.space, down: true, flags: [.function]) == Answer(take: true, claim: .handsFree))
    }

    @Test func settingsTakingTheKeyboardWithdrawsAPressTheMainActorHasNotHeardOf() {
        var claims = KeyClaims()
        claims.trigger = .function
        claims.takesSpace = true
        claims.modifiersChanged(keyCode: Self.fn, flags: [.function])
        claims.withdrawAll()
        #expect(claims.key(Self.space, down: true, flags: [.function]) == Answer(take: false, claim: nil))
    }

    @Test func theWatchMayEndAPressOnlyOnceItsSpaceIsHandled() {
        var claims = KeyClaims()
        claims.trigger = .function
        claims.takesSpace = true
        claims.modifiersChanged(keyCode: Self.fn, flags: [.function])
        let press = claims.generation
        #expect(claims.key(Self.space, down: true, flags: [.function]) == Answer(take: true, claim: .handsFree))
        claims.key(Self.space, down: false, flags: [.function])
        let unhandled = claims.withdraw(generation: press, handled: nil)
        let earlierHandled = claims.withdraw(generation: press, handled: press - 1)
        let handled = claims.withdraw(generation: press, handled: press)
        #expect(!unhandled)
        #expect(!earlierHandled)
        #expect(handled)
        // Withdrawn, the press takes no Space between the answer and the
        // release.
        #expect(claims.key(Self.space, down: true, flags: [.function]) == Answer(take: false, claim: nil))
        // A press whose Space was never taken may be ended at once.
        claims.key(Self.space, down: false, flags: [.function])
        claims.modifiersChanged(keyCode: Self.fn, flags: [])
        claims.modifiersChanged(keyCode: Self.fn, flags: [.function])
        let untaken = claims.withdraw(generation: claims.generation, handled: press)
        #expect(untaken)
    }

    @Test func theSameModifierOnTheOtherSideMakesThePressAShortcuts() {
        // Left Command held, then Right Command chosen as the key.
        let both = Flags(rawValue: Flags.command.rawValue | 0x10 | 0x8)
        var claims = KeyClaims()
        claims.trigger = .rightCommand
        claims.takesSpace = true
        claims.modifiersChanged(keyCode: Self.rightCommand, flags: both)
        #expect(claims.key(Self.space, down: true, flags: both) == Answer(take: false, claim: nil))
        var detector = HoldDetector(key: .rightCommand)
        detector.keyboardShowsDown = { _ in false }
        #expect(detector.modifiersChanged(keyCode: Self.rightCommand, flags: both) == .press)
        #expect(!detector.pressAlone)
        #expect(!HoldKey.Key.rightCommand.isAlone(in: both))
        #expect(HoldKey.Key.rightCommand.isAlone(in: Flags(rawValue: Flags.command.rawValue | 0x10)))
    }

    @Test func aKeyChosenWhileItWasDownMustBeLetGoFirst() {
        // Right Command and Shift held while Right Command is chosen; Shift
        // let go is no press of Right Command's.
        let command = Flags(rawValue: Flags.command.rawValue | 0x10)
        var claims = KeyClaims()
        claims.trigger = .rightCommand
        claims.takesSpace = true
        claims.modifiersChanged(keyCode: Self.leftShift, flags: command)
        #expect(claims.key(Self.space, down: true, flags: command) == Answer(take: false, claim: nil))
        claims.key(Self.space, down: false, flags: command)
        claims.modifiersChanged(keyCode: Self.rightCommand, flags: [])
        claims.modifiersChanged(keyCode: Self.rightCommand, flags: command)
        #expect(claims.key(Self.space, down: true, flags: command) == Answer(take: true, claim: .handsFree))
    }

    @Test func noFromTheMainActorTakesBackWhatThePressWasAllowed() {
        // Fn pressed on its own, then the main actor says this press is no
        // dictation's, as when Settings starts recording a key with Fn still
        // held: Space is no longer taken, even once Settings stops.
        var claims = KeyClaims()
        claims.trigger = .function
        claims.takesSpace = true
        claims.modifiersChanged(keyCode: Self.fn, flags: [.function])
        let press = claims.generation
        claims.held(false, generation: press)
        claims.takesSpace = false
        claims.takesSpace = true
        #expect(claims.key(Self.space, down: true, flags: [.function]) == Answer(take: false, claim: nil))
        claims.key(Self.space, down: false, flags: [.function])
        // Word about an earlier press changes nothing for this one.
        claims.modifiersChanged(keyCode: Self.fn, flags: [])
        claims.modifiersChanged(keyCode: Self.fn, flags: [.function])
        claims.held(false, generation: press)
        #expect(claims.key(Self.space, down: true, flags: [.function]) == Answer(take: true, claim: .handsFree))
    }

    @Test func aHoldSettingsSawIsNotADictationsWhenSettingsStopsRecording() {
        // Fn pressed while Settings recorded a key, then Escape cancelled the
        // recording with Fn still down.
        var claims = KeyClaims()
        claims.trigger = .function
        claims.modifiersChanged(keyCode: Self.fn, flags: [.function], dropped: true)
        claims.takesSpace = true
        #expect(claims.key(Self.space, down: true, flags: [.function]) == Answer(take: false, claim: nil))
    }

    @Test func spaceWithAnotherModifierIsAShortcutsEvenWithTheKeyHeld() {
        let command = Flags(rawValue: Flags.command.rawValue | 0x10)
        var claims = KeyClaims()
        claims.trigger = .rightCommand
        claims.takesSpace = true
        // Option held, then Right Command: Option-Command-Space.
        claims.modifiersChanged(keyCode: Self.leftOption, flags: [.option])
        claims.modifiersChanged(keyCode: Self.rightCommand, flags: command.union(.option))
        #expect(claims.key(Self.space, down: true, flags: command.union(.option)) == Answer(take: false, claim: nil))
        claims.key(Self.space, down: false, flags: command.union(.option))
        // Option let go: that press was still a shortcut's.
        claims.modifiersChanged(keyCode: Self.leftOption, flags: command)
        #expect(claims.key(Self.space, down: true, flags: command) == Answer(take: false, claim: nil))
        claims.key(Self.space, down: false, flags: command)
        // Right Command pressed on its own takes Space, but not with Shift
        // added for it.
        claims.modifiersChanged(keyCode: Self.rightCommand, flags: [])
        claims.modifiersChanged(keyCode: Self.rightCommand, flags: command)
        #expect(claims.key(Self.space, down: true, flags: command.union(.shift)) == Answer(take: false, claim: nil))
        claims.key(Self.space, down: false, flags: command.union(.shift))
        // The typed shortcut rejects this whole press, even without Shift.
        #expect(claims.key(Self.space, down: true, flags: command) == Answer(take: false, claim: nil))
        claims.key(Self.space, down: false, flags: command)
        claims.modifiersChanged(keyCode: Self.rightCommand, flags: [])
        claims.modifiersChanged(keyCode: Self.rightCommand, flags: command)
        #expect(claims.key(Self.space, down: true, flags: command) == Answer(take: true, claim: .handsFree))
    }

    @Test func aRepeatNeverTakesAKeyWhosePressWentThrough() {
        // Space held first, then Fn: the repeats and the release are the
        // app's, which saw Space go down.
        var claims = KeyClaims()
        claims.trigger = .function
        claims.takesSpace = true
        #expect(claims.key(Self.space, down: true, flags: []) == Answer(take: false, claim: nil))
        claims.modifiersChanged(keyCode: Self.fn, flags: [.function])
        #expect(claims.key(Self.space, down: true, flags: [.function], isRepeat: true) == Answer(take: false, claim: nil))
        #expect(claims.key(Self.space, down: false, flags: [.function]) == Answer(take: false, claim: nil))
        // Escape held when recording starts, the same.
        #expect(claims.key(Self.escape, down: true, flags: []) == Answer(take: false, claim: nil))
        claims.escapeCancels = true
        #expect(claims.key(Self.escape, down: true, flags: [], isRepeat: true) == Answer(take: false, claim: nil))
        #expect(claims.key(Self.escape, down: false, flags: []) == Answer(take: false, claim: nil))
    }

    @Test func escapeIsTakenOnlyWhileADictationRecords() {
        var claims = KeyClaims()
        #expect(claims.key(Self.escape, down: true, flags: []) == Answer(take: false, claim: nil))
        #expect(claims.key(Self.escape, down: false, flags: []) == Answer(take: false, claim: nil))
        claims.escapeCancels = true
        #expect(claims.key(Self.escape, down: true, flags: []) == Answer(take: true, claim: .escape))
        claims.escapeCancels = false
        // Its release follows its press, whatever changed in between.
        #expect(claims.key(Self.escape, down: false, flags: []) == Answer(take: true, claim: nil))
    }

    @Test func theGlobeKeysOwnEventGoesWhereFnWent() {
        // As the tap runs them: `ConsumedHolds` decides Fn, and the globe
        // event follows that decision, even when what is consumed changes
        // between Fn's press and its release, as when the microphone fails
        // to open and dictation can no longer run.
        var holds = ConsumedHolds(), claims = KeyClaims()
        func fn(_ down: Bool) {
            let flags: Flags = down ? [.function] : []
            claims.modifiersChanged(keyCode: Self.fn, flags: flags, dropped: holds.drops(keyCode: Self.fn, flags: flags))
        }
        fn(true)
        fn(false)
        #expect(claims.key(Self.globe, down: true, flags: []) == Answer(take: false, claim: nil))
        #expect(claims.key(Self.globe, down: false, flags: []) == Answer(take: false, claim: nil))
        holds.consumed = Self.fn
        fn(true)
        holds.consumed = nil
        fn(false)
        #expect(claims.key(Self.globe, down: true, flags: []) == Answer(take: true, claim: nil))
        #expect(claims.key(Self.globe, down: false, flags: []) == Answer(take: true, claim: nil))
        // A press let through keeps its globe event with it, whatever is
        // consumed by its release.
        fn(true)
        holds.consumed = Self.fn
        fn(false)
        #expect(claims.key(Self.globe, down: true, flags: []) == Answer(take: false, claim: nil))
    }

    @Test func aHoldThatBeganWhileDictationCouldNotRunTakesSpaceOnceItCan() {
        // The microphone failed and is retried by this very press.
        var fn = KeyClaims()
        fn.trigger = .function
        fn.modifiersChanged(keyCode: Self.fn, flags: [.function])
        // Confirmed while unavailable: this press retried the microphone.
        fn.held(true, generation: fn.generation)
        #expect(!fn.key(Self.space, down: true, flags: [.function]).take)
        fn.key(Self.space, down: false, flags: [.function])
        fn.takesSpace = true
        // Once available, the confirmed recording accepts hands-free.
        #expect(fn.key(Self.space, down: true, flags: [.function]) == Answer(take: true, claim: .handsFree))
        var pair = KeyClaims()
        pair.trigger = .controlOption
        pair.modifiersChanged(keyCode: Self.leftControl, flags: [.control])
        pair.modifiersChanged(keyCode: Self.leftOption, flags: [.control, .option])
        pair.held(true, generation: pair.generation)
        pair.takesSpace = true
        #expect(pair.key(Self.space, down: true, flags: [.control, .option]) == Answer(take: true, claim: .handsFree))
    }
}

/// Every trigger Settings can record, held and let go, held with Space and
/// let go unseen, through the rules and through the tap's claims as each
/// sees the same keyboard.
struct EveryRecordableKeyTests {
    private typealias Flags = NSEvent.ModifierFlags

    static let singles: [HoldKey.Modifier] = [.function, .rightControl, .rightOption, .rightCommand]
    static let pairs: [Set<HoldKey.Family>] = {
        let families: [HoldKey.Family] = [.control, .option, .shift, .command]
        var sets: [Set<HoldKey.Family>] = []
        for mask in 1..<(1 << families.count) where mask.nonzeroBitCount >= 2 {
            sets.append(Set(families.indices.filter { mask & (1 << $0) != 0 }.map { families[$0] }))
        }
        return sets
    }()

    /// The left-hand key of each family, as a pair is pressed.
    private static func leftKey(_ family: HoldKey.Family) -> HoldKey.Modifier {
        switch family {
        case .control: .leftControl
        case .option: .leftOption
        case .shift: .leftShift
        case .command: .leftCommand
        case .function: .function
        }
    }

    private static func flags(_ keys: [HoldKey.Modifier]) -> Flags {
        keys.reduce(Flags()) { $0.union($1.family.flag).union(Flags(rawValue: $1.deviceMask)) }
    }

    @Test(arguments: singles)
    func aSingleKeyIsPushToTalkAndGoesHandsFreeWithSpace(_ modifier: HoldKey.Modifier) {
        let key = HoldKey.Key.single(modifier)
        let down = Self.flags([modifier])
        var detector = HoldDetector(key: key)
        var claims = KeyClaims()
        claims.trigger = key
        claims.takesSpace = true
        // Held and let go.
        #expect(detector.modifiersChanged(keyCode: modifier.keyCode, flags: down) == .press)
        #expect(detector.pressAlone)
        #expect(detector.modifiersChanged(keyCode: modifier.keyCode, flags: []) == .release)
        // Held, Space, let go: Space is taken and asks for hands-free.
        claims.modifiersChanged(keyCode: modifier.keyCode, flags: down)
        #expect(detector.modifiersChanged(keyCode: modifier.keyCode, flags: down) == .press)
        #expect(claims.key(KeyClaims.space, down: true, flags: down) == KeyClaims.Answer(take: true, claim: .handsFree))
        #expect(detector.space() == .handsFree)
        #expect(claims.key(KeyClaims.space, down: false, flags: down).take)
        claims.modifiersChanged(keyCode: modifier.keyCode, flags: [])
        #expect(detector.modifiersChanged(keyCode: modifier.keyCode, flags: []) == .release)
        // Space with the key up types as always.
        #expect(!claims.key(KeyClaims.space, down: true, flags: []).take)
        // Held, then its release unseen and the next change showing it up.
        #expect(detector.modifiersChanged(keyCode: modifier.keyCode, flags: down) == .press)
        #expect(detector.modifiersChanged(keyCode: HoldKey.Modifier.leftShift.keyCode, flags: [.shift]) != .release)
    }

    @Test(arguments: pairs)
    func keysHeldTogetherArePushToTalkAndGoHandsFreeWithSpace(_ families: Set<HoldKey.Family>) {
        let key = HoldKey.Key.combination(families)
        let keys = families.sorted().map(Self.leftKey)
        var detector = HoldDetector(key: key)
        detector.keyboardShowsDown = { _ in false }
        var claims = KeyClaims()
        claims.trigger = key
        claims.takesSpace = true
        func press() {
            for (index, key) in keys.enumerated() {
                let flags = Self.flags(Array(keys[...index]))
                claims.modifiersChanged(keyCode: key.keyCode, flags: flags)
                #expect(detector.modifiersChanged(keyCode: key.keyCode, flags: flags) == (index == keys.count - 1 ? .arm : nil))
            }
            #expect(detector.armDelayElapsed() == .press)
            claims.held(true, generation: claims.generation)
        }
        let all = Self.flags(keys)
        press()
        #expect(claims.key(KeyClaims.space, down: true, flags: all) == KeyClaims.Answer(take: true, claim: .handsFree))
        #expect(detector.space() == .handsFree)
        #expect(claims.key(KeyClaims.space, down: false, flags: all).take)
        // Letting any one key go is the release, for the rules and the tap.
        let rest = Self.flags(Array(keys.dropFirst()))
        claims.modifiersChanged(keyCode: keys[0].keyCode, flags: rest)
        #expect(detector.modifiersChanged(keyCode: keys[0].keyCode, flags: rest) == .release)
        #expect(!claims.key(KeyClaims.space, down: true, flags: rest).take)
    }
}

/// `HoldKey` itself, with its own arm timer on the main run loop, handed
/// the modifier changes, keys and clicks its monitors and tap would
/// deliver. It watches nothing, since `start` is never called, and waits
/// 50 ms instead of 200 so the suite stays quick.
@MainActor
struct HoldKeyTimerTests {
    private static let delay: TimeInterval = 0.05
    private static let leftControl: UInt16 = 59
    private static let leftOption: UInt16 = 58
    private static let leftShift: UInt16 = 56
    private static let leftArrow: UInt16 = 123

    private final class Count {
        var presses = 0
        var releases = 0
    }

    private func controlOption() -> (HoldKey, Count) {
        let hold = HoldKey(handsFreeEnabled: true, key: .controlOption, holdDelay: 0, armDelay: Self.delay)
        let count = Count()
        hold.onPress = { count.presses += 1 }
        hold.onRelease = { count.releases += 1 }
        return (hold, count)
    }

    private func pressPair(_ hold: HoldKey) {
        hold.modifiersChanged(keyCode: Self.leftControl, flags: [.control])
        hold.modifiersChanged(keyCode: Self.leftOption, flags: [.control, .option])
    }

    /// Lets Option go and presses it again, Control staying down.
    private func pressOptionAgain(_ hold: HoldKey) {
        hold.modifiersChanged(keyCode: Self.leftOption, flags: [.control])
        hold.modifiersChanged(keyCode: Self.leftOption, flags: [.control, .option])
    }

    /// Waits `seconds`, or until `done` holds, without holding up the main
    /// actor: the main run loop, where the timer is, keeps running, and so
    /// do the other suites' main-actor tests.
    private func run(for seconds: TimeInterval, until done: () -> Bool = { false }) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Holds the main thread for `seconds` without letting its run loop
    /// turn, so no timer fires meanwhile.
    private func block(for seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    @Test func theTimerPressesOnceWhenTheDelayHasPassed() async {
        let (hold, count) = controlOption()
        let pressed = Date()
        pressPair(hold)
        #expect(count.presses == 0)
        await run(for: 2) { count.presses > 0 }
        #expect(count.presses == 1)
        #expect(Date().timeIntervalSince(pressed) >= Self.delay)
        // The timer fires once, however long the pair stays down.
        await run(for: Self.delay * 4)
        #expect(count.presses == 1)
        hold.modifiersChanged(keyCode: Self.leftOption, flags: [.control])
        #expect(count.releases == 1)
    }

    @Test func aPairLetGoWithinTheDelayNeverPresses() async {
        let (hold, count) = controlOption()
        pressPair(hold)
        hold.modifiersChanged(keyCode: Self.leftOption, flags: [.control])
        await run(for: Self.delay * 4)
        #expect(count.presses == 0)
        #expect(count.releases == 0)
    }

    @Test func aKeyDuringTheWaitCancelsItAndTheTimerDoesNothingLater() async {
        let (hold, count) = controlOption()
        pressPair(hold)
        hold.keyDown(keyCode: Self.leftArrow, flags: [.control, .option])
        await run(for: Self.delay * 4)
        #expect(count.presses == 0)
        // The arrow let go with the pair still down starts nothing either.
        hold.keyUp(keyCode: Self.leftArrow)
        await run(for: Self.delay * 4)
        #expect(count.presses == 0)
        // The pair pressed again waits afresh and presses once.
        pressOptionAgain(hold)
        await run(for: 2) { count.presses > 0 }
        await run(for: Self.delay * 2)
        #expect(count.presses == 1)
    }

    @Test func aThirdModifierOrAClickDuringTheWaitCancelsItAndTheTimerDoesNothingLater() async {
        let (hold, count) = controlOption()
        pressPair(hold)
        hold.modifiersChanged(keyCode: Self.leftShift, flags: [.control, .option, .shift])
        hold.modifiersChanged(keyCode: Self.leftShift, flags: [.control, .option])
        await run(for: Self.delay * 4)
        #expect(count.presses == 0)
        let (clicked, clicks) = controlOption()
        pressPair(clicked)
        clicked.mouseDown(flags: [.control, .option])
        await run(for: Self.delay * 4)
        #expect(clicks.presses == 0)
        pressOptionAgain(clicked)
        await run(for: 2) { clicks.presses > 0 }
        #expect(clicks.presses == 1)
    }

    @Test func aPairPressedAgainWithinTheDelayWaitsAgainAndPressesOnce() async throws {
        let (hold, count) = controlOption()
        pressPair(hold)
        let first = try #require(hold.arm)
        // The pause blocks the main thread rather than yielding, so the run
        // loop cannot turn and the first wait's timer cannot fire before
        // the second press, however long the pause takes on a busy Mac.
        block(for: Self.delay / 2)
        let again = Date()
        pressOptionAgain(hold)
        // The first wait's timer is gone, so it never fires, and the second
        // waits in full from the second press. Timers can fire late on a
        // busy run loop, so they are checked themselves, not by the clock.
        #expect(!first.isValid)
        let second = try #require(hold.arm)
        #expect(second !== first)
        #expect(second.fireDate.timeIntervalSince(again) >= Self.delay)
        #expect(count.presses == 0)
        await run(for: 2) { count.presses > 0 }
        await run(for: Self.delay * 4)
        #expect(count.presses == 1)
    }

    /// The keyboard as `HoldKey` reads it while a key is held, changed by
    /// the check.
    private final class Keyboard {
        var flags: UInt = 0
    }

    private func rightOption(watch: TimeInterval = 0.02, wait: TimeInterval = 0.06) -> (HoldKey, Count, Keyboard) {
        let hold = HoldKey(handsFreeEnabled: true, key: .rightOption, holdDelay: 0, armDelay: Self.delay, watchInterval: watch, unseenReleaseWait: wait)
        let count = Count(), keyboard = Keyboard()
        hold.keyboardFlags = { [keyboard.flags, 0] }
        hold.onPress = { count.presses += 1 }
        hold.onRelease = { count.releases += 1 }
        return (hold, count, keyboard)
    }

    @Test func aReleaseTheTapNeverSawEndsTheHoldOnceTheKeyboardShowsTheKeyUp() async {
        let (hold, count, keyboard) = rightOption()
        let down = NSEvent.ModifierFlags.option.rawValue | 0x40
        keyboard.flags = down
        hold.modifiersChanged(keyCode: 61, flags: NSEvent.ModifierFlags(rawValue: down))
        #expect(count.presses == 1)
        await run(for: 0.2)
        #expect(count.releases == 0)
        // The key comes up and no modifier change says so, as when secure
        // input, a disabled tap or another app's tap hides it.
        keyboard.flags = 0
        await run(for: 2) { count.releases > 0 }
        #expect(count.releases == 1)
        // The release the tap sees late is not a second one.
        hold.modifiersChanged(keyCode: 61, flags: [])
        #expect(count.releases == 1)
    }

    @Test func aReleaseUnseenBeforeTheWatchFirstReadsTheKeyboardStillEndsTheHold() async {
        // The keyboard showed the key down with its press, as the tap read
        // it, and is up before the watch first looks, as when opening a
        // headset's microphone holds the main actor that long.
        let (hold, count, keyboard) = rightOption()
        let down = NSEvent.ModifierFlags.option.rawValue | 0x40
        hold.modifiersChanged(HoldKey.Delivery(keyCode: 61, flags: down, keyboard: down))
        #expect(count.presses == 1)
        keyboard.flags = 0
        await run(for: 2) { count.releases > 0 }
        #expect(count.releases == 1)
    }

    @Test func aPressTheKeyboardSentIsWatchedEvenWhenItsStateIsAlreadyUp() async {
        // Pressed and let go before the tap saw the press, whose release is
        // then lost: the press itself, sent by the keyboard, says the key
        // was down.
        let (hold, count, _) = rightOption()
        let down = NSEvent.ModifierFlags.option.rawValue | 0x40
        hold.modifiersChanged(HoldKey.Delivery(keyCode: 61, flags: down, keyboard: 0, fromKeyboard: true))
        #expect(count.presses == 1)
        await run(for: 2) { count.releases > 0 }
        #expect(count.releases == 1)
    }

    @Test func aChangeReadAfterAnUnseenReleaseKeepsThePairsKeyboardEvidence() async {
        // The pair completes with the keyboard showing both keys down; Caps
        // Lock changes, read after the pair has come up unseen.
        let hold = HoldKey(handsFreeEnabled: true, key: .controlOption, holdDelay: 0, armDelay: Self.delay, watchInterval: 0.02)
        let count = Count(), keyboard = Keyboard()
        hold.keyboardFlags = { [keyboard.flags, 0] }
        hold.onPress = { count.presses += 1 }
        let both = NSEvent.ModifierFlags([.control, .option]).rawValue
        hold.modifiersChanged(HoldKey.Delivery(keyCode: Self.leftControl, flags: NSEvent.ModifierFlags.control.rawValue,
                                               keyboard: NSEvent.ModifierFlags.control.rawValue))
        hold.modifiersChanged(HoldKey.Delivery(keyCode: Self.leftOption, flags: both, keyboard: both))
        hold.modifiersChanged(HoldKey.Delivery(keyCode: 57, flags: both | NSEvent.ModifierFlags.capsLock.rawValue, keyboard: 0))
        keyboard.flags = 0
        await run(for: Self.delay * 6)
        #expect(count.presses == 0)
    }

    @Test func aPressAgainStartsTheWaitForAnUnseenReleaseOver() throws {
        // Four of five keyboard readings show the key up before the next
        // press. That press must restart the wait, leaving time for its
        // queued Space to arrive before the unseen release is delivered.
        let (hold, _, keyboard) = rightOption(watch: 0.02, wait: 0.1)
        var events: [String] = []
        hold.onPress = { events.append("press") }
        hold.onRelease = { events.append("release") }
        hold.onHandsFree = { events.append("handsFree") }
        let down = NSEvent.ModifierFlags.option.rawValue | 0x40
        hold.modifiersChanged(HoldKey.Delivery(keyCode: 61, flags: down, keyboard: down))
        let watch = try #require(hold.watch)
        keyboard.flags = 0
        for _ in 0..<4 { watch.fire() }
        #expect(events == ["press"])
        hold.modifiersChanged(HoldKey.Delivery(keyCode: 61, flags: down, keyboard: down, fromKeyboard: true))
        for _ in 0..<2 { watch.fire() }
        #expect(events == ["press"])
        hold.claimed(.handsFree)
        #expect(events == ["press", "handsFree"])
        for _ in 0..<2 { watch.fire() }
        #expect(events == ["press", "handsFree"])
        watch.fire()
        #expect(events == ["press", "handsFree"])
        #expect(!watch.isValid)
        #expect(hold.watch == nil)
    }

    @Test func aKeyHeldWithNoDictationRecordingIsWithdrawnFromTheTap() async {
        // A press that started a dictation is published to the tap; once the
        // dictation stops recording with the key still held, as Escape
        // stops it, or for a press that started none, it is withdrawn.
        let (hold, _, _) = rightOption()
        var startsDictation = true
        hold.onPress = { if startsDictation { hold.recording = true } }
        let down = NSEvent.ModifierFlags.option.rawValue | 0x40
        hold.modifiersChanged(keyCode: 61, flags: NSEvent.ModifierFlags(rawValue: down))
        #expect(hold.publishedHold)
        hold.recording = false
        #expect(!hold.publishedHold)
        hold.modifiersChanged(keyCode: 61, flags: [])
        startsDictation = false
        hold.modifiersChanged(keyCode: 61, flags: NSEvent.ModifierFlags(rawValue: down))
        #expect(!hold.publishedHold)
    }

    @Test func spaceIsLeftToTheAppOnlyWhileNoDictationCanStart() {
        let hold = HoldKey(handsFreeEnabled: true, key: .rightCommand, holdDelay: 0)
        #expect(hold.takesSpace)
        hold.dictationAvailable = false
        #expect(!hold.takesSpace)
        hold.dictationAvailable = true
        hold.recorder = { _ in }
        #expect(!hold.takesSpace)
    }

    @Test func theKeyUpForLessThanTheWaitEndsNothing() async {
        let (hold, count, keyboard) = rightOption(watch: 0.02, wait: 0.2)
        let down = NSEvent.ModifierFlags.option.rawValue | 0x40
        keyboard.flags = down
        hold.modifiersChanged(HoldKey.Delivery(keyCode: 61, flags: down, keyboard: down))
        // Up for less than the wait, then down again.
        keyboard.flags = 0
        await run(for: 0.08)
        keyboard.flags = down
        await run(for: 0.3)
        #expect(count.releases == 0)
        keyboard.flags = 0
        await run(for: 2) { count.releases > 0 }
        #expect(count.releases == 1)
    }

    @Test func aPairWhoseOneKeyCameUpUnseenArmsAgainWhenThatKeyIsPressed() async {
        // Option's release is lost with Control still down; the watch ends
        // the hold, and Option pressed again starts a new one.
        let hold = HoldKey(handsFreeEnabled: true, key: .controlOption, holdDelay: 0, armDelay: Self.delay, watchInterval: 0.02, unseenReleaseWait: 0.06)
        let count = Count(), keyboard = Keyboard()
        hold.keyboardFlags = { [keyboard.flags, 0] }
        hold.onPress = { count.presses += 1 }
        hold.onRelease = { count.releases += 1 }
        let control = NSEvent.ModifierFlags.control.rawValue, both = NSEvent.ModifierFlags([.control, .option]).rawValue
        keyboard.flags = both
        hold.modifiersChanged(HoldKey.Delivery(keyCode: Self.leftControl, flags: control, keyboard: control))
        hold.modifiersChanged(HoldKey.Delivery(keyCode: Self.leftOption, flags: both, keyboard: both))
        await run(for: 2) { count.presses == 1 }
        keyboard.flags = control
        await run(for: 2) { count.releases == 1 }
        #expect(count.releases == 1)
        keyboard.flags = both
        hold.modifiersChanged(HoldKey.Delivery(keyCode: Self.leftOption, flags: both, keyboard: both))
        await run(for: 2) { count.presses == 2 }
        #expect(count.presses == 2)
    }

    @Test func aPairWhoseKeyCameUpUnseenDuringItsArmDelayArmsAgainWhenItComesDown() async {
        let hold = HoldKey(handsFreeEnabled: true, key: .controlOption, holdDelay: 0, armDelay: Self.delay, watchInterval: 0.02, unseenReleaseWait: 0.06)
        let count = Count(), keyboard = Keyboard()
        hold.keyboardFlags = { [keyboard.flags, 0] }
        hold.onPress = { count.presses += 1 }
        let control = NSEvent.ModifierFlags.control.rawValue, both = NSEvent.ModifierFlags([.control, .option]).rawValue
        keyboard.flags = both
        hold.modifiersChanged(HoldKey.Delivery(keyCode: Self.leftControl, flags: control, keyboard: control))
        hold.modifiersChanged(HoldKey.Delivery(keyCode: Self.leftOption, flags: both, keyboard: both))
        // Option comes up and the tap never says so; the wait ends unstarted.
        keyboard.flags = control
        await run(for: Self.delay * 4)
        #expect(count.presses == 0)
        keyboard.flags = both
        hold.modifiersChanged(HoldKey.Delivery(keyCode: Self.leftOption, flags: both, keyboard: both))
        await run(for: 2) { count.presses == 1 }
        #expect(count.presses == 1)
    }

    @Test func aPairLetGoUnseenDuringItsArmDelayDoesNotStart() async {
        let hold = HoldKey(handsFreeEnabled: true, key: .controlOption, holdDelay: 0, armDelay: Self.delay, watchInterval: 0.02)
        let count = Count(), keyboard = Keyboard()
        hold.keyboardFlags = { [keyboard.flags, 0] }
        hold.onPress = { count.presses += 1 }
        let both = NSEvent.ModifierFlags([.control, .option]).rawValue
        keyboard.flags = both
        pressPair(hold)
        // Both keys come up and the tap never says so.
        keyboard.flags = 0
        await run(for: Self.delay * 6)
        #expect(count.presses == 0)
    }

    @Test func aPairIsPublishedToTheTapBeforeThePressIsHandedOn() async {
        let (hold, _) = controlOption()
        var published: [Bool] = []
        hold.onPress = { published.append(hold.publishedHold) }
        hold.onRelease = { published.append(hold.publishedHold) }
        pressPair(hold)
        await run(for: 2) { !published.isEmpty }
        hold.modifiersChanged(keyCode: Self.leftOption, flags: [.control])
        #expect(published == [true, false])
    }

    @Test func aHoldTheKeyboardNeverShowedDownIsLeftToItsOwnRelease() async {
        // A key another process posted, as the dictation checks do, shows in
        // no keyboard state; it ends only with its own release.
        let (hold, count, _) = rightOption()
        hold.modifiersChanged(keyCode: 61, flags: NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x40))
        await run(for: 0.3)
        #expect(count.presses == 1)
        #expect(count.releases == 0)
        hold.modifiersChanged(keyCode: 61, flags: [])
        #expect(count.releases == 1)
    }
}

/// The trigger and indicator choices, saved and read back through
/// `Preferences` against a defaults domain of their own.
@MainActor
struct ChoicePreferenceTests {
    private func defaults() -> UserDefaults {
        let name = "ChoicePreferenceTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func aFreshInstallShowsTheDotAndADeliberateHideSticks() {
        let store = defaults()
        #expect(Preferences(defaults: store).indicator == .dot)
        #expect(store.bool(forKey: "indicatorStyleMigrated"))
        Preferences(defaults: store).indicator = .foot
        #expect(Preferences(defaults: store).indicator == .foot)
        // After the marker is written, "pill" is a deliberate Hide.
        #expect(store.string(forKey: "indicator") == "pill")
        Preferences(defaults: store).indicator = .dot
        #expect(Preferences(defaults: store).indicator == .dot)
    }

    @Test func anIndicatorThisBuildDoesNotKnowFallsBackToTheDot() {
        let store = defaults()
        store.set("banner", forKey: "indicator")
        #expect(Preferences(defaults: store).indicator == .dot)
    }

    @Test func anOldPillBecomesShowWithoutChangingOtherPreferences() {
        let store = defaults()
        store.set("pill", forKey: "indicator")
        store.set("rightOption", forKey: "dictationKey")
        store.set(["en", "es"], forKey: "dictationLanguages")
        store.set(false, forKey: "writesEmails")
        store.set(false, forKey: "draftsReplies")
        store.set(true, forKey: "addsSentWithIntention")
        store.set(false, forKey: "visualCaretEnabled")
        store.set(true, forKey: "screenRecordingRequested")
        store.set("device", forKey: "microphone")
        store.set("synthetic-mic", forKey: "microphoneDevice")
        store.set("Test microphone", forKey: "microphoneName")
        store.set("kept", forKey: "unrelatedPreference")
        let migrated = Preferences(defaults: store)
        #expect(migrated.indicator == .dot)
        #expect(store.string(forKey: "indicator") == "dot")
        #expect(store.bool(forKey: "indicatorStyleMigrated"))
        #expect(Preferences(defaults: store).indicator == .dot)
        #expect(migrated.dictationKey == .rightOption)
        #expect(migrated.dictationLanguages == ["en", "es"])
        #expect(!migrated.writesEmails && !migrated.draftsReplies)
        #expect(migrated.addsSentWithIntention)
        #expect(!migrated.visualCaretEnabled && migrated.screenRecordingRequested)
        #expect(migrated.microphone == .device(uid: "synthetic-mic", name: "Test microphone"))
        #expect(store.string(forKey: "unrelatedPreference") == "kept")
    }

    @Test func anOldPillRestoresDraftEligibilityAndALaterHideSurvivesRelaunch() {
        let store = defaults()
        store.set("pill", forKey: "indicator")
        let migrated = Preferences(defaults: store)
        #expect(migrated.draftsReplies)
        #expect(WritingRow.draftsBlocked(writesEmails: migrated.writesEmails, usesPill: migrated.indicator == .foot) == nil)
        migrated.indicator = .foot
        let relaunched = Preferences(defaults: store)
        #expect(relaunched.indicator == .foot)
        #expect(store.string(forKey: "indicator") == "pill")
        #expect(relaunched.draftsReplies)
        #expect(!relaunched.screenRecordingLaunchDeferred)
    }

    @Test func anOldDotKeepsShowAndTheExistingPermissionFlow() {
        let store = defaults()
        store.set("dot", forKey: "indicator")
        let loaded = Preferences(defaults: store)
        #expect(loaded.indicator == .dot)
        #expect(store.bool(forKey: "indicatorStyleMigrated"))
        #expect(!loaded.screenRecordingLaunchDeferred)
        #expect(loaded.asksForScreenRecordingAtLaunch)
    }

    @Test func aMarkedHideIsNeverTreatedAsAnOldPill() {
        let store = defaults()
        store.set(true, forKey: "indicatorStyleMigrated")
        store.set("pill", forKey: "indicator")
        #expect(Preferences(defaults: store).indicator == .foot)
        #expect(store.string(forKey: "indicator") == "pill")
    }

    @Test func aCombinationIsSavedAsTheDictationKey() {
        let store = defaults()
        #expect(Preferences(defaults: store).dictationKey == .function)
        Preferences(defaults: store).dictationKey = .controlOption
        #expect(Preferences(defaults: store).dictationKey == .controlOption)
        #expect(store.string(forKey: "dictationKey") == "control+option")
        let recorded: [HoldKey.Key] = HoldKey.Key.suggested + [.single(.rightControl), .combination([.function, .shift]),
                                                                .combination([.control, .option, .command])]
        for key in recorded {
            Preferences(defaults: store).dictationKey = key
            #expect(Preferences(defaults: store).dictationKey == key)
        }
        #expect(store.string(forKey: "dictationKey") == "control+option+command")
    }

    @Test func thePairsSavedBeforeKeysWereRecordedStillRead() {
        let store = defaults()
        for (saved, key) in [("controlOption", HoldKey.Key.controlOption), ("controlCommand", .controlCommand),
                             ("optionCommand", .optionCommand), ("function", .function), ("rightOption", .rightOption),
                             ("rightCommand", .rightCommand)] {
            store.set(saved, forKey: "dictationKey")
            #expect(Preferences(defaults: store).dictationKey == key)
        }
    }

    @Test func aKeyThisBuildDoesNotKnowFallsBackToFn() {
        let store = defaults()
        for unknown in ["capsLock", "control", "control+control", "control+capsLock", "+", ""] {
            store.set(unknown, forKey: "dictationKey")
            #expect(Preferences(defaults: store).dictationKey == .function)
        }
    }

    @Test func launchAsksForScreenRecordingOnlyForTheDot() {
        let store = defaults()
        // A first launch with the dot and the on-screen option as they come.
        #expect(Preferences(defaults: store).asksForScreenRecordingAtLaunch)
        // The foot, chosen at an earlier launch, is never asked for it.
        Preferences(defaults: store).indicator = .foot
        #expect(!Preferences(defaults: store).asksForScreenRecordingAtLaunch)
        // Back on the dot, it is asked once.
        Preferences(defaults: store).indicator = .dot
        #expect(Preferences(defaults: store).asksForScreenRecordingAtLaunch)
        Preferences(defaults: store).screenRecordingRequested = true
        #expect(!Preferences(defaults: store).asksForScreenRecordingAtLaunch)
        // A launch with the on-screen option off does not use it.
        #expect(!Preferences(defaults: defaults(), arguments: ["Intention", "-visualCaretEnabled", "NO"]).asksForScreenRecordingAtLaunch)
    }

    @Test func theIndicatorHasTwoNamedChoices() {
        #expect(IndicatorStyle.allCases == [.dot, .foot])
        #expect(IndicatorStyle.dot.title == "Show")
        #expect(IndicatorStyle.foot.title == "Hide")
    }
}

/// The Tab the trigger's tap takes while a reply proposal's card shows,
/// driven through `TakenTabs` and `TriggerTap.key`, the very code the tap
/// runs on its own thread, and Escape and key presses reported to the
/// reply proposals. No tap is made and no key is pressed.
@MainActor
struct TakenTabTests {
    private nonisolated static let tab: UInt16 = 48
    private nonisolated static let escape: UInt16 = 53
    private nonisolated static let space: UInt16 = 49
    private nonisolated static let a: UInt16 = 0
    private nonisolated static let shift = NSEvent.ModifierFlags.shift.rawValue
    private nonisolated static let option = NSEvent.ModifierFlags.option.rawValue
    private nonisolated static let capsLock = NSEvent.ModifierFlags.capsLock.rawValue

    /// What a check collected, from whichever thread it ran on.
    private final class Collected<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Value] = []
        func add(_ value: Value) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }
        var all: [Value] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    /// `TakenTabs` as the tap holds it, under a lock, collecting the
    /// generation of each press it newly takes.
    private final class Tabs: @unchecked Sendable {
        private let lock = NSLock()
        private var tabs = TakenTabs()
        let taken = Collected<UInt64>()

        func takeTab(_ generation: UInt64?) {
            lock.lock()
            tabs.generation = generation
            lock.unlock()
        }

        func drops(_ event: TapEvent) -> Bool {
            lock.lock()
            let decision = tabs.decide(event)
            lock.unlock()
            if let generation = decision.taken { taken.add(generation) }
            return decision.drops
        }
    }

    /// The tap's state for key events and modifier changes, driven as
    /// `TriggerTap.handle` drives it, handing what the tap would hand on to
    /// `hold` from the calling thread.
    private final class Tap: @unchecked Sendable {
        private let lock = NSLock()
        private var claims = KeyClaims()
        private var tabs = TakenTabs()
        private let hold: HoldKey

        init(_ hold: HoldKey, trigger: HoldKey.Key) {
            self.hold = hold
            claims.trigger = trigger
            claims.takesSpace = true
        }

        func takeTab(_ generation: UInt64?) {
            lock.lock()
            tabs.generation = generation
            lock.unlock()
        }

        /// A modifier change, delivered with the tap's count of the keys down.
        func modifiers(keyCode: UInt16, flags: UInt) {
            lock.lock()
            claims.modifiersChanged(keyCode: keyCode, flags: NSEvent.ModifierFlags(rawValue: flags))
            let delivery = HoldKey.Delivery(keyCode: keyCode, flags: flags, generation: claims.generation, keysClear: claims.keysClear)
            lock.unlock()
            hold.tapDelivered(delivery)
        }

        /// A key press or release; answers whether the tap drops it.
        func key(_ keyCode: UInt16, down: Bool, flags: UInt = 0, isRepeat: Bool = false) -> Bool {
            lock.lock()
            let decision = TriggerTap.key(keyCode, down: down, flags: NSEvent.ModifierFlags(rawValue: flags), isRepeat: isRepeat,
                                          claims: &claims, tabs: &tabs)
            let generation = claims.generation
            lock.unlock()
            if let claim = decision.claim {
                hold.tapClaimed(claim, generation: generation)
            } else if decision.handOn {
                hold.tapInput(HoldKey.Monitored(kind: down ? .keyDown : .keyUp, keyCode: keyCode, flags: flags, isRepeat: isRepeat,
                                               proposalTab: decision.take), tabTaken: decision.tabTaken)
            }
            return decision.take
        }
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private static func offMain<Value: Sendable>(_ body: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { (done: CheckedContinuation<Value, Never>) in
            DispatchQueue.global(qos: .userInteractive).async { done.resume(returning: body()) }
        }
    }

    /// Waits without holding up the main run loop, where the arm timer is.
    private static func wait(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    @Test func aPlainTabIsTakenWithItsRepeatsAndReleaseWhileAGenerationIsSet() {
        let tabs = Tabs()
        tabs.takeTab(7)
        #expect(tabs.drops(.keyDown(keyCode: Self.tab, flags: 0, isRepeat: false)))
        #expect(tabs.drops(.keyDown(keyCode: Self.tab, flags: 0, isRepeat: true)))
        #expect(tabs.drops(.keyDown(keyCode: Self.tab, flags: 0, isRepeat: true)))
        #expect(tabs.drops(.keyUp(keyCode: Self.tab)))
        // Reported once, for the press, with its generation.
        #expect(tabs.taken.all == [7])
        // Caps Lock is not a modifier: Tab with the light on is still taken.
        #expect(tabs.drops(.keyDown(keyCode: Self.tab, flags: Self.capsLock, isRepeat: false)))
        #expect(tabs.drops(.keyUp(keyCode: Self.tab)))
        #expect(tabs.taken.all == [7, 7])
    }

    @Test func tabPassesWithNoGenerationAndEveryOtherKeyAlwaysPasses() {
        let tabs = Tabs()
        #expect(!tabs.drops(.keyDown(keyCode: Self.tab, flags: 0, isRepeat: false)))
        #expect(!tabs.drops(.keyDown(keyCode: Self.tab, flags: 0, isRepeat: true)))
        #expect(!tabs.drops(.keyUp(keyCode: Self.tab)))
        tabs.takeTab(3)
        for key in [Self.a, Self.escape, 36, 51, 123] {
            #expect(!tabs.drops(.keyDown(keyCode: key, flags: 0, isRepeat: false)))
            #expect(!tabs.drops(.keyUp(keyCode: key)))
        }
        #expect(tabs.taken.all.isEmpty)
    }

    @Test func shiftTabAndOptionTabPassAndSoDoTheirReleases() {
        let tabs = Tabs()
        tabs.takeTab(4)
        for flags in [Self.shift, Self.option, NSEvent.ModifierFlags.command.rawValue, NSEvent.ModifierFlags.control.rawValue] {
            #expect(!tabs.drops(.keyDown(keyCode: Self.tab, flags: flags, isRepeat: false)))
            #expect(!tabs.drops(.keyDown(keyCode: Self.tab, flags: flags, isRepeat: true)))
            #expect(!tabs.drops(.keyUp(keyCode: Self.tab)))
        }
        #expect(tabs.taken.all.isEmpty)
    }

    @Test func aTakenPressHasItsReleaseTakenAfterTheGenerationIsCleared() {
        let tabs = Tabs()
        tabs.takeTab(9)
        #expect(tabs.drops(.keyDown(keyCode: Self.tab, flags: 0, isRepeat: false)))
        // The card ends while Tab is still down.
        tabs.takeTab(nil)
        #expect(tabs.drops(.keyDown(keyCode: Self.tab, flags: 0, isRepeat: true)))
        #expect(tabs.drops(.keyUp(keyCode: Self.tab)))
        // The next press, with nothing set, passes, and so does its release.
        #expect(!tabs.drops(.keyDown(keyCode: Self.tab, flags: 0, isRepeat: false)))
        #expect(!tabs.drops(.keyUp(keyCode: Self.tab)))
        #expect(tabs.taken.all == [9])
    }

    @Test func aPressLetThroughIsNotTakenWhenTheCardShowsWhileItIsHeld() {
        let tabs = Tabs()
        #expect(!tabs.drops(.keyDown(keyCode: Self.tab, flags: 0, isRepeat: false)))
        tabs.takeTab(5)
        // Its repeats and release go to the app that saw it go down.
        #expect(!tabs.drops(.keyDown(keyCode: Self.tab, flags: 0, isRepeat: true)))
        #expect(!tabs.drops(.keyUp(keyCode: Self.tab)))
        #expect(tabs.taken.all.isEmpty)
        // A press whose release was lost answers afresh.
        #expect(tabs.drops(.keyDown(keyCode: Self.tab, flags: 0, isRepeat: false)))
        #expect(tabs.drops(.keyDown(keyCode: Self.tab, flags: Self.shift, isRepeat: false)) == false)
        #expect(!tabs.drops(.keyUp(keyCode: Self.tab)))
        #expect(tabs.taken.all == [5])
    }

    @Test func takingTabLeavesTheKeysTakenForDictationAsTheyWere() {
        var claims = KeyClaims()
        claims.trigger = .single(.function)
        claims.takesSpace = true
        claims.escapeCancels = true
        var tabs = TakenTabs()
        tabs.generation = 1
        let fn = NSEvent.ModifierFlags.function
        claims.modifiersChanged(keyCode: 63, flags: fn)
        // Space with Fn held is still dictation's, and never reaches the rules.
        #expect(TriggerTap.key(Self.space, down: true, flags: fn, isRepeat: false, claims: &claims, tabs: &tabs)
            == .init(take: true, claim: .handsFree, handOn: false))
        #expect(TriggerTap.key(Self.space, down: false, flags: fn, isRepeat: false, claims: &claims, tabs: &tabs)
            == .init(take: true, claim: nil, handOn: false))
        claims.modifiersChanged(keyCode: 63, flags: [])
        // So is Escape while a dictation records.
        #expect(TriggerTap.key(Self.escape, down: true, flags: [], isRepeat: false, claims: &claims, tabs: &tabs)
            == .init(take: true, claim: .escape, handOn: false))
        #expect(TriggerTap.key(Self.escape, down: false, flags: [], isRepeat: false, claims: &claims, tabs: &tabs)
            == .init(take: true, claim: nil, handOn: false))
        // A plain Tab is taken for the card, and still handed on to the rules.
        #expect(TriggerTap.key(Self.tab, down: true, flags: [], isRepeat: false, claims: &claims, tabs: &tabs)
            == .init(take: true, claim: nil, handOn: true, tabTaken: 1))
        // Held, it counts among the keys down, so Fn pressed now is no press of its own.
        claims.modifiersChanged(keyCode: 63, flags: fn)
        #expect(!claims.keysClear)
        #expect(TriggerTap.key(Self.space, down: true, flags: fn, isRepeat: false, claims: &claims, tabs: &tabs)
            == .init(take: false, claim: nil, handOn: true))
        _ = TriggerTap.key(Self.space, down: false, flags: fn, isRepeat: false, claims: &claims, tabs: &tabs)
        claims.modifiersChanged(keyCode: 63, flags: [])
        #expect(TriggerTap.key(Self.tab, down: false, flags: [], isRepeat: false, claims: &claims, tabs: &tabs)
            == .init(take: true, claim: nil, handOn: true))
        #expect(claims.keysClear)
        // Any other key passes and is handed on.
        #expect(TriggerTap.key(Self.a, down: true, flags: [], isRepeat: false, claims: &claims, tabs: &tabs)
            == .init(take: false, claim: nil, handOn: true))
    }

    @Test func theTapsDecisionRunsOffTheMainThread() async {
        let tabs = Tabs()
        tabs.takeTab(11)
        let dropped = await Self.offMain {
            [tabs.drops(.keyDown(keyCode: Self.tab, flags: 0, isRepeat: false)), tabs.drops(.keyUp(keyCode: Self.tab))]
        }
        #expect(dropped == [true, true])
        #expect(tabs.taken.all == [11])
    }

    @Test func aTakenTabReportedFromTheTapsThreadReachesTheMainActor() async {
        let hold = HoldKey(handsFreeEnabled: true, key: .function, holdDelay: 0)
        var generations: [UInt64] = []
        var presses: [UInt16] = []
        hold.tabTaken = { generations.append($0) }
        hold.keyPressed = { code, _ in presses.append(code) }
        await Self.offMain { hold.tapInput(HoldKey.Monitored(kind: .keyDown, keyCode: Self.tab, proposalTab: true), tabTaken: 12) }
        #expect(await eventually { generations == [12] })
        // The release and repeats it takes are no new acceptance.
        await Self.offMain {
            hold.tapInput(HoldKey.Monitored(kind: .keyDown, keyCode: Self.tab, isRepeat: true, proposalTab: true))
            hold.tapInput(HoldKey.Monitored(kind: .keyUp, keyCode: Self.tab))
        }
        await Self.offMain {}
        #expect(generations == [12])
        #expect(presses.isEmpty)
        await Self.offMain { hold.tapInput(HoldKey.Monitored(kind: .keyDown, keyCode: Self.a)) }
        #expect(await eventually { presses == [Self.a] })
    }

    @Test func onlyATakenPressCarriesItsGeneration() {
        var claims = KeyClaims()
        claims.trigger = .single(.function)
        var tabs = TakenTabs()
        func key(_ keyCode: UInt16, _ down: Bool, flags: NSEvent.ModifierFlags = [], isRepeat: Bool = false) -> TriggerTap.KeyDecision {
            TriggerTap.key(keyCode, down: down, flags: flags, isRepeat: isRepeat, claims: &claims, tabs: &tabs)
        }
        // Let through with nothing set: handed on, with no generation.
        #expect(key(Self.tab, true) == .init(take: false, claim: nil, handOn: true))
        #expect(key(Self.tab, false) == .init(take: false, claim: nil, handOn: true))
        tabs.generation = 6
        #expect(key(Self.a, true) == .init(take: false, claim: nil, handOn: true))
        #expect(key(Self.tab, true, flags: .shift) == .init(take: false, claim: nil, handOn: true))
        #expect(key(Self.tab, false) == .init(take: false, claim: nil, handOn: true))
        // Taken: the press with its generation, then its repeat and release without one.
        #expect(key(Self.tab, true) == .init(take: true, claim: nil, handOn: true, tabTaken: 6))
        #expect(key(Self.tab, true, isRepeat: true) == .init(take: true, claim: nil, handOn: true))
        #expect(key(Self.tab, false) == .init(take: true, claim: nil, handOn: true))
    }

    /// A made-up keyboard for the trigger's rules to ask, so a key the
    /// check holds stays down whatever the real keyboard shows.
    private final class Keyboard {
        var down: Set<UInt16> = []
    }

    /// Control+Option with a 50 ms arm delay, every event handed from a
    /// background queue as the tap's thread hands it.
    @Test func aPairPressedWhileATakenTabIsHeldStaysAShortcutUntilTabIsUpAndThePairPressedAgain() async {
        let delay: TimeInterval = 0.05
        let hold = HoldKey(handsFreeEnabled: true, key: .controlOption, holdDelay: 0, armDelay: delay)
        let keyboard = Keyboard()
        hold.keyboardShowsKeyDown = { keyboard.down.contains($0) }
        var presses = 0
        var generations: [UInt64] = []
        hold.onPress = { presses += 1 }
        hold.tabTaken = { generations.append($0) }
        let tap = Tap(hold, trigger: .controlOption)
        tap.takeTab(3)
        let control = NSEvent.ModifierFlags.control.rawValue
        let controlOption = control | NSEvent.ModifierFlags.option.rawValue

        // Tab goes down to accept the card and stays down while the pair goes down.
        keyboard.down = [Self.tab]
        let pressed = await Self.offMain {
            let tab = tap.key(Self.tab, down: true)
            tap.modifiers(keyCode: 59, flags: control)
            tap.modifiers(keyCode: 58, flags: controlOption)
            return [tab, tap.key(Self.tab, down: true, flags: controlOption, isRepeat: true)]
        }
        #expect(pressed == [true, true])
        #expect(await eventually { generations == [3] })
        // Held well past the arm delay, the pair never arms: Tab is down.
        await Self.wait(delay * 6)
        #expect(hold.arm == nil)
        #expect(presses == 0)

        // Tab comes up with the pair still down: still a shortcut's pair.
        keyboard.down = []
        #expect(await Self.offMain { tap.key(Self.tab, down: false) })
        await Self.wait(delay * 6)
        #expect(presses == 0)

        // Option let go and pressed again, with Tab up, arms and presses once.
        await Self.offMain {
            tap.modifiers(keyCode: 58, flags: control)
            tap.modifiers(keyCode: 58, flags: controlOption)
        }
        #expect(await eventually { presses == 1 })
        await Self.wait(delay * 4)
        #expect(presses == 1)
        #expect(generations == [3])
    }

    @Test func aPairPressedOverAHeldTabThatPassesIsAShortcutToo() async {
        let delay: TimeInterval = 0.05
        let hold = HoldKey(handsFreeEnabled: true, key: .controlOption, holdDelay: 0, armDelay: delay)
        let keyboard = Keyboard()
        hold.keyboardShowsKeyDown = { keyboard.down.contains($0) }
        var presses = 0
        hold.onPress = { presses += 1 }
        let tap = Tap(hold, trigger: .controlOption)
        let control = NSEvent.ModifierFlags.control.rawValue
        let controlOption = control | NSEvent.ModifierFlags.option.rawValue
        // No card: Tab passes, and is still handed to the rules.
        keyboard.down = [Self.tab]
        #expect(await Self.offMain { tap.key(Self.tab, down: true) } == false)
        await Self.offMain {
            tap.modifiers(keyCode: 59, flags: control)
            tap.modifiers(keyCode: 58, flags: controlOption)
        }
        await Self.wait(delay * 6)
        #expect(presses == 0)
        keyboard.down = []
        #expect(await Self.offMain { tap.key(Self.tab, down: false) } == false)
        await Self.offMain {
            tap.modifiers(keyCode: 58, flags: control)
            tap.modifiers(keyCode: 58, flags: controlOption)
        }
        #expect(await eventually { presses == 1 })
    }

    @Test func withoutTheTapNothingIsTakenAndNothingReported() {
        let hold = HoldKey(handsFreeEnabled: true, key: .function, holdDelay: 0)
        var generations: [UInt64] = []
        hold.tabTaken = { generations.append($0) }
        hold.takeTab(generation: 2)
        // The monitors see Tab, and the trigger's rules ignore it.
        hold.received(HoldKey.Monitored(kind: .keyDown, keyCode: Self.tab))
        hold.received(HoldKey.Monitored(kind: .keyUp, keyCode: Self.tab))
        hold.takeTab(generation: nil)
        #expect(generations.isEmpty)
    }

    @Test func escapeIsReportedFromTheMonitorsAndLeftToTheApp() async {
        let hold = HoldKey(handsFreeEnabled: true, key: .function, holdDelay: 0)
        var escapes = 0
        hold.escapePressed = { escapes += 1 }
        let local = HoldKey.localMonitor(for: hold)
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                      characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: Self.escape)!
        // Intention's own window still gets it.
        #expect(local(escape) != nil)
        #expect(escapes == 1)
        // A held Escape's repeats and its release are not more presses.
        hold.received(HoldKey.Monitored(kind: .keyDown, keyCode: Self.escape, isRepeat: true))
        hold.received(HoldKey.Monitored(kind: .keyUp, keyCode: Self.escape))
        hold.received(HoldKey.Monitored(kind: .keyDown, keyCode: Self.a))
        #expect(escapes == 1)
        // From the global monitor, called off the main thread as AppKit might.
        let global = HoldKey.globalMonitor(for: hold)
        await Self.offMain {
            global(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                    characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!)
        }
        #expect(await eventually { escapes == 2 })
    }

    @Test func anEscapeTheTapPassedDoesNotCancelAnEmailThatBecamePendingBeforeDelivery() async {
        let hold = HoldKey(handsFreeEnabled: true, key: .function, holdDelay: 0)
        var presses = 0, cancels = 0
        hold.keyPressed = { _, _ in presses += 1 }
        hold.onEscape = { cancels += 1 }
        // The tap let Escape through with nothing pending. Its delivery is
        // queued on the main actor, behind the email becoming pending.
        hold.tapInput(.init(kind: .keyDown, keyCode: Self.escape))
        hold.pendingEmailWrite = true
        #expect(await eventually { presses == 1 })
        #expect(cancels == 0)
        #expect(hold.pendingEmailWrite)
    }

    @Test func aPendingEmailTakesEscapeUntilItEnds() async {
        let hold = HoldKey(handsFreeEnabled: true, key: .function, holdDelay: 0)
        var cancels = 0
        hold.onEscape = { cancels += 1; hold.pendingEmailWrite = false }
        #expect(!hold.takesEscape)
        hold.pendingEmailWrite = true
        #expect(hold.takesEscape)
        #expect(!hold.recording)
        hold.recorder = { _ in }
        #expect(!hold.takesEscape)
        hold.received(.init(kind: .keyDown, keyCode: Self.escape))
        #expect(cancels == 0)
        hold.recorder = nil
        // AppKit may deliver this off the main thread. Only a fresh press
        // cancels, and an email never makes Space a hands-free command.
        await Self.offMain { hold.received(.init(kind: .keyDown, keyCode: Self.escape, isRepeat: true)) }
        await Self.offMain { hold.received(.init(kind: .keyDown, keyCode: Self.space)) }
        #expect(cancels == 0)
        await Self.offMain { hold.received(.init(kind: .keyDown, keyCode: Self.escape)) }
        #expect(await eventually { cancels == 1 })
        #expect(!hold.takesEscape)
        hold.recording = true
        #expect(hold.takesEscape)
    }

    @Test func escapeAndSpaceTheTapTakesAreReportedAsPressesToo() async {
        let hold = HoldKey(handsFreeEnabled: true, key: .function, holdDelay: 0)
        var escapes = 0, presses = 0, cancels = 0
        hold.escapePressed = { escapes += 1 }
        hold.keyPressed = { _, _ in presses += 1 }
        hold.onEscape = { cancels += 1 }
        // Escape taken to cancel a recording still reaches the proposals first.
        await Self.offMain { hold.tapClaimed(.escape) }
        #expect(await eventually { cancels == 1 })
        #expect(escapes == 1)
        #expect(presses == 1)
        // Space taken for hands-free is a key press, and no Escape.
        await Self.offMain { hold.tapClaimed(.handsFree) }
        #expect(await eventually { presses == 2 })
        #expect(escapes == 1)
    }

    @Test func everyKeyPressIsReportedFromTheMonitorsAndNothingIsTaken() async {
        let hold = HoldKey(handsFreeEnabled: true, key: .function, holdDelay: 0)
        var presses = 0
        hold.keyPressed = { _, _ in presses += 1 }
        let local = HoldKey.localMonitor(for: hold)
        let a = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                 characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: Self.a)!
        #expect(local(a) != nil)
        #expect(presses == 1)
        // A repeat is a press; a release and a modifier change are not.
        hold.received(HoldKey.Monitored(kind: .keyDown, keyCode: Self.a, isRepeat: true))
        hold.received(HoldKey.Monitored(kind: .keyUp, keyCode: Self.a))
        hold.received(HoldKey.Monitored(kind: .modifiers, keyCode: 56, flags: NSEvent.ModifierFlags.shift.rawValue))
        #expect(presses == 2)
        // From the global monitor, called off the main thread as AppKit might.
        let global = HoldKey.globalMonitor(for: hold)
        await Self.offMain {
            global(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                    characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!)
        }
        #expect(await eventually { presses == 3 })
    }
}
