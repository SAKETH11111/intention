import AppKit
@testable import Dictation
import Testing

struct HeldRecordingTests {
    @Test func unrelatedModifierFlagsCannotReleaseFn() {
        var detector = HoldDetector(key: .function)
        #expect(detector.modifiersChanged(keyCode: 63, flags: [.function]) == .press)
        #expect(detector.modifiersChanged(keyCode: 57, flags: [.capsLock]) == nil)
        #expect(detector.held)
        #expect(detector.modifiersChanged(keyCode: 56, flags: [.shift]) != .release)
        #expect(detector.held)
        #expect(detector.modifiersChanged(keyCode: 63, flags: []) == .release)
    }

    @Test func ordinaryKeysAndClicksCannotReleaseFn() {
        var detector = HoldDetector(key: .function)
        #expect(detector.modifiersChanged(keyCode: 63, flags: [.function]) == .press)
        #expect(detector.keyDown(keyCode: 0, flags: []) == .otherKey)
        #expect(detector.mouseDown(flags: []) == .click)
        #expect(detector.held)
    }
}

struct DictationGestureTests {
    @Test func aSingleTapOpensNothing() {
        var gesture = DictationGesture()
        #expect(gesture.press(at: 0, alone: true, recording: false) == nil)
        #expect(gesture.release(at: 0.1) == nil)
        #expect(!gesture.waiting)
    }

    @Test func twoShortTapsStartHandsFree() {
        var gesture = DictationGesture()
        _ = gesture.press(at: 0, alone: true, recording: false)
        #expect(gesture.release(at: 0.08) == nil)
        #expect(gesture.press(at: 0.2, alone: true, recording: false) == nil)
        #expect(gesture.release(at: 0.27) == .handsFree)
    }

    @Test func slowTapsStaySilent() {
        var gesture = DictationGesture()
        _ = gesture.press(at: 0, alone: true, recording: false)
        _ = gesture.release(at: 0.1)
        _ = gesture.press(at: 0.5, alone: true, recording: false)
        #expect(gesture.release(at: 0.6) == nil)
    }

    @Test func holdingTheSecondPressWinsOverDoubleTap() {
        var gesture = DictationGesture()
        _ = gesture.press(at: 0, alone: true, recording: false)
        _ = gesture.release(at: 0.1)
        _ = gesture.press(at: 0.2, alone: true, recording: false)
        #expect(gesture.confirm() == .press)
        #expect(gesture.release(at: 1) == .release)
    }

    @Test func shortcutsAndSpaceClearTheTapCandidate() {
        for space in [false, true] {
            var gesture = DictationGesture()
            _ = gesture.press(at: 0, alone: true, recording: false)
            _ = gesture.release(at: 0.1)
            _ = gesture.press(at: 0.2, alone: true, recording: false)
            if space { gesture.space() } else { gesture.shortcut() }
            #expect(gesture.confirm() == nil)
            #expect(gesture.release(at: 0.25) == nil)
        }
    }

    @Test func aTapStopsAnExistingRecordingOnRelease() {
        var gesture = DictationGesture()
        #expect(gesture.press(at: 0, alone: true, recording: true) == .press)
        #expect(gesture.release(at: 0.08) == .release)
    }

    @Test func otherInputDoesNotEndAConfirmedHold() {
        var gesture = DictationGesture()
        _ = gesture.press(at: 0, alone: true, recording: false)
        #expect(gesture.confirm() == .press)
        gesture.shortcut()
        #expect(gesture.release(at: 1) == .release)
    }
}

@MainActor
extension DictationScenarioTests {
    private func wire(_ dictation: DictationController, key: HoldKey.Key = .function) -> HoldKey {
        let hold = HoldKey(handsFreeEnabled: true, key: key)
        hold.now = { 1 }
        hold.keyboardFlags = { [] }
        hold.keyboardShowsKeyDown = { _ in false }
        hold.onPress = { dictation.holdBegan(alone: hold.pressWasAlone, confirmed: hold.holdWasConfirmed) }
        hold.onRelease = { dictation.holdEnded() }
        hold.onHandsFree = { dictation.holdBecameHandsFree() }
        hold.onOtherKey = { dictation.keyPressedDuringHold() }
        hold.onClick = { dictation.clickedDuringHold() }
        dictation.phaseChanged = { hold.recording = $0 == .recording }
        return hold
    }

    @Test func aTapOpensNoAudioAndTwoTapsStartHandsFree() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let scenarios = DictationScenarioTests()
        let source = ScriptedSource()
        let dictation = scenarios.controller(server.endpoint, source: source)
        let hold = wire(dictation)
        hold.modifiersChanged(.init(keyCode: 63, flags: NSEvent.ModifierFlags.function.rawValue, time: 1))
        hold.modifiersChanged(.init(keyCode: 63, flags: 0, time: 1.06))
        #expect(!source.running)
        #expect(dictation.phase == .idle)
        #expect(server.connections.isEmpty)
        hold.modifiersChanged(.init(keyCode: 63, flags: NSEvent.ModifierFlags.function.rawValue, time: 1.2))
        hold.modifiersChanged(.init(keyCode: 63, flags: 0, time: 1.26))
        #expect(source.running)
        #expect(dictation.handsFree)
        await scenarios.speak()
        hold.modifiersChanged(keyCode: 63, flags: [.function])
        hold.modifiersChanged(keyCode: 63, flags: [])
        await scenarios.idle(dictation)
        #expect(scenarios.field.text == "aHello.bc")
    }

    @Test(arguments: [HoldKey.Key.function, .rightOption, .controlOption])
    func chosenKeyAndSpaceStartsAndStopsHandsFree(_ key: HoldKey.Key) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let scenarios = DictationScenarioTests()
        let dictation = scenarios.controller(server.endpoint)
        let hold = wire(dictation, key: key)
        func down() {
            if key == .controlOption { hold.modifiersChanged(keyCode: 59, flags: [.control]) }
            hold.modifiersChanged(keyCode: key == .function ? 63 : key == .rightOption ? 61 : 58,
                                 flags: NSEvent.ModifierFlags(rawValue: key.mask).union(key.families))
        }
        func up() {
            hold.modifiersChanged(keyCode: key == .function ? 63 : key == .rightOption ? 61 : 58, flags: [])
        }
        down()
        hold.claimed(.handsFree)
        up()
        #expect(dictation.phase == .recording)
        #expect(dictation.handsFree)
        await scenarios.speak()
        down()
        hold.claimed(.handsFree)
        up()
        await scenarios.idle(dictation)
        #expect(scenarios.field.text == "aHello.bc")
    }

    @Test func heldRecordingSurvivesOtherInputDoneAndAudioLossUntilRelease() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let scenarios = DictationScenarioTests()
        let source = ScriptedSource()
        let dictation = scenarios.controller(server.endpoint, source: source)
        let hold = wire(dictation)
        hold.modifiersChanged(keyCode: 63, flags: [.function])
        try await Task.sleep(for: .milliseconds(330))
        #expect(source.running)
        #expect(dictation.phase == .recording)
        hold.modifiersChanged(keyCode: 57, flags: [.capsLock])
        hold.keyDown(keyCode: 0, flags: [])
        hold.mouseDown(flags: [])
        dictation.respond(to: .done)
        dictation.toggle()
        source.interrupt()
        #expect(dictation.phase == .recording)
        #expect(dictation.available)
        hold.modifiersChanged(keyCode: 63, flags: [])
        await scenarios.idle(dictation)
        #expect(scenarios.field.text == "aHello.bc")
    }

    @Test func safetyCapNamesWhyItStopped() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let scenarios = DictationScenarioTests()
        let dictation = scenarios.controller(server.endpoint)
        dictation.recordingLimit = .milliseconds(50)
        dictation.holdBegan(confirmed: true)
        try await Task.sleep(for: .milliseconds(70))
        #expect(dictation.phase != .recording)
        #expect(dictation.notice == .recordingLimit)
        #expect(AppLog.dictationLines.all.contains("dictation stop.safetyLimit"))
        await scenarios.idle(dictation)
    }

    @Test func aSpuriousOwnFnUpIsRejectedWhenHardwareStillShowsDown() {
        let fn = NSEvent.ModifierFlags.function.rawValue
        #expect(HoldKey.modifierFlags(key: .function, delivery: .init(keyCode: 63, flags: 0, keyboard: fn, fromKeyboard: true)).contains(.function))
        #expect(HoldKey.modifierFlags(key: .function, delivery: .init(keyCode: 63, flags: 0, keyboard: 0, fromKeyboard: true)).isEmpty)
        #expect(HoldKey.modifierFlags(key: .function, delivery: .init(keyCode: 63, flags: 0, keyboard: fn)).isEmpty)
    }

    @Test func backgroundTapReenableKeepsHeldRecordingAndEscapeCancelsIt() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let scenarios = DictationScenarioTests()
        let dictation = scenarios.controller(server.endpoint)
        let hold = wire(dictation)
        hold.modifiersChanged(keyCode: 63, flags: [.function])
        try await Task.sleep(for: .milliseconds(330))
        hold.onEscape = dictation.escapeCancellation()
        let events = LoggedLines()
        await withCheckedContinuation { done in
            DispatchQueue.global().async {
                TriggerTap.reenable({ events.add("enabled") }, disabled: { events.add("disabled"); hold.tapWasDisabled() })
                hold.tapDelivered(.init(keyCode: 57, flags: NSEvent.ModifierFlags.capsLock.rawValue))
                done.resume()
            }
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(events.all == ["enabled", "disabled"])
        #expect(dictation.phase == .recording)
        await withCheckedContinuation { done in
            DispatchQueue.global().async { hold.tapClaimed(.escape); done.resume() }
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(dictation.phase == .idle)
        #expect(scenarios.field.text == "abc")
        #expect(!hold.takesEscape)
        hold.modifiersChanged(keyCode: 63, flags: [])
    }
}

@MainActor
extension DictationScenarioTests {
    @Test func grantRefreshAndExpiryDoNotEndAHeldRecording() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let clock = SteppedClock()
        let origin = ContinuousClock.now
        let fetches = LoggedLines()
        let grants = SpeechGrants(fetch: { _ in
            fetches.add("issued")
            return .init(grant: ScriptedEndpoint.grant, expiresIn: 300)
        }, key: { "synthetic-key" }, keyRefused: { _ in }, now: { origin + clock.now })
        let source = ScriptedSource()
        let dictation = controller(.init(url: server.endpoint.url, credentials: grants), source: source)
        dictation.holdBegan(confirmed: true)
        await speak()
        #expect(fetches.all.count == 1)
        clock.advance(to: .seconds(240))
        #expect(try await grants.grant() == ScriptedEndpoint.grant)
        #expect(fetches.all.count == 2)
        clock.advance(to: .seconds(600))
        #expect(dictation.phase == .recording)
        #expect(source.running)
        #expect(server.connections.count == 1)
        dictation.holdEnded()
        await idle(dictation)
        #expect(field.text == "aHello.bc")
    }

    @Test func losingFocusOrTurningSecureCannotEndAHeldRecording() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let source = ScriptedSource()
        let dictation = controller(server.endpoint, source: source)
        dictation.holdBegan(confirmed: true)
        await speak()
        field.focused = false
        field.secure = true
        await speak()
        #expect(source.running)
        #expect(dictation.phase == .recording)
        dictation.holdEnded()
        await idle(dictation)
        #expect(field.text == "abc")
        #expect(dictation.history.entries.count == 1)
    }
}

@MainActor
struct HoldGestureDeliveryTests {
    @Test func typingBetweenTapsClearsCandidate() {
        let hold = HoldKey(handsFreeEnabled: true, key: .function)
        hold.now = { 1 }
        hold.keyboardFlags = { [] }
        hold.keyboardShowsKeyDown = { _ in false }
        var handsFree = 0
        hold.onHandsFree = { handsFree += 1 }
        let fn = NSEvent.ModifierFlags.function.rawValue
        hold.modifiersChanged(.init(keyCode: 63, flags: fn, time: 1))
        hold.modifiersChanged(.init(keyCode: 63, flags: 0, time: 1.06))
        hold.keyDown(keyCode: 0, flags: [])
        hold.keyUp(keyCode: 0)
        hold.modifiersChanged(.init(keyCode: 63, flags: fn, time: 1.2))
        hold.modifiersChanged(.init(keyCode: 63, flags: 0, time: 1.26))
        #expect(handsFree == 0)
    }

    @Test func queuedRealFnReleaseStillSeparatesTwoTaps() {
        let hold = HoldKey(handsFreeEnabled: true, key: .function)
        hold.now = { 1 }
        hold.keyboardFlags = { [] }
        hold.keyboardShowsKeyDown = { _ in false }
        var handsFree = 0
        hold.onHandsFree = { handsFree += 1 }
        let fn = NSEvent.ModifierFlags.function.rawValue
        hold.modifiersChanged(.init(keyCode: 63, flags: fn, keyboard: fn, fromKeyboard: true, time: 1))
        // At the first release's tap delivery, the second press has already happened.
        hold.modifiersChanged(.init(keyCode: 63, flags: 0, keyboard: fn, fromKeyboard: true, time: 1.06))
        hold.modifiersChanged(.init(keyCode: 63, flags: fn, keyboard: fn, fromKeyboard: true, time: 1.2))
        hold.modifiersChanged(.init(keyCode: 63, flags: 0, keyboard: 0, fromKeyboard: true, time: 1.26))
        #expect(handsFree == 1)
    }

    @Test func unseenReleaseDuringHoldDelayOpensNothing() async throws {
        let hold = HoldKey(handsFreeEnabled: true, key: .function)
        hold.now = { 1 }
        var keyboard: UInt = NSEvent.ModifierFlags.function.rawValue
        hold.keyboardFlags = { [keyboard] }
        hold.keyboardShowsKeyDown = { _ in false }
        var presses = 0
        hold.onPress = { presses += 1; hold.recording = true }
        hold.modifiersChanged(.init(keyCode: 63, flags: keyboard, keyboard: keyboard, fromKeyboard: true))
        // Secure input or a disabled tap hides release after a short tap.
        keyboard = 0
        try await Task.sleep(for: .milliseconds(350))
        #expect(presses == 0)
        hold.recording = false
        hold.modifiersChanged(keyCode: 63, flags: [])
    }
}


@MainActor
extension DictationScenarioTests {
    @Test func clickRecordingFinishesWithChosenKeyAndSpace() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        let hold = wire(dictation)
        dictation.toggle()
        #expect(dictation.handsFree)
        await speak()
        hold.modifiersChanged(keyCode: 63, flags: [.function])
        hold.claimed(.handsFree)
        hold.modifiersChanged(keyCode: 63, flags: [])
        #expect(dictation.phase != .recording)
        await idle(dictation)
        #expect(field.text == "aHello.bc")
    }

    @Test(arguments: [false, true], [false, true])
    func reconnectingNoticeUsesOneIndicatorAndClearsOnRecovery(throughFoot: Bool, hasCaret: Bool) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        let foot = FootMark(desktop: .init(screens: { [] }, pointer: { .zero }, showsWindow: false))
        var captions: [String?] = [], panels: [FootState?] = []
        DictationIndicators.connect(dictation, foot: foot, phase: { _ in }, notice: { _ in },
            silence: { _ in }, nothing: { _ in }, recordingIssue: { words in
                DictationIndicators.sayRecordingIssue(words, throughFoot: throughFoot,
                    caretAnchor: hasCaret ? .init(x: 1, y: 1, width: 8, height: 8) : nil,
                    caption: { captions.append($0) }, panel: { panels.append($0) })
            })
        foot.state = .listening
        let words = "Reconnecting microphone…"
        dictation.recordingIssueChanged?(words)
        #expect(foot.recordingIssue == words)
        #expect(captions == [!throughFoot && hasCaret ? words : nil])
        #expect(panels == [!throughFoot && !hasCaret ? .notice(words) : nil])
        dictation.recordingIssueChanged?(nil)
        #expect(foot.recordingIssue == nil)
        #expect(captions.last == .some(nil))
        #expect(panels.last == .some(nil))
        #expect(foot.state == .listening)
    }
}

struct NativeGestureTimestampTests {
    @Test func nativeEventTimesKeepTheDoubleTapWindowInSeconds() throws {
        var gesture = DictationGesture()
        for (seconds, down) in [(1.0, true), (1.06, false), (1.2, true), (1.26, false)] {
            let event = try #require(NSEvent.keyEvent(with: down ? .keyDown : .keyUp,
                location: .zero, modifierFlags: [], timestamp: seconds, windowNumber: 0, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 63)?.cgEvent)
            let time = TriggerTap.eventTime(event.timestamp)
            #expect(abs(time - seconds) < 0.000001)
            let action = down ? gesture.press(at: time, alone: true, recording: false) : gesture.release(at: time)
            #expect(action == (seconds == 1.26 ? .handsFree : nil))
        }
    }
}

struct RejectedShortcutSpaceTests {
    @Test func commandCThenSpaceKeepsSpotlightShortcutEvenBeforeMainActorDelivery() {
        var claims = KeyClaims()
        var tabs = TakenTabs()
        claims.trigger = .rightCommand
        claims.takesSpace = true
        let command = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x10)
        claims.modifiersChanged(keyCode: 54, flags: command)
        let generation = claims.generation
        #expect(!TriggerTap.key(8, down: true, flags: command, isRepeat: false,
                                claims: &claims, tabs: &tabs).take)
        _ = TriggerTap.key(8, down: false, flags: command, isRepeat: false, claims: &claims, tabs: &tabs)
        // A delayed confirmation belongs to the rejected press too.
        claims.held(true, generation: generation)
        let space = TriggerTap.key(49, down: true, flags: command, isRepeat: false, claims: &claims, tabs: &tabs)
        #expect(!space.take)
        #expect(space.claim == nil)
        #expect(!TriggerTap.key(49, down: false, flags: command, isRepeat: false, claims: &claims, tabs: &tabs).take)
    }

    @Test func typingDuringAConfirmedHoldKeepsRecordingAndAllowsHandsFree() {
        var claims = KeyClaims()
        claims.trigger = .function
        claims.takesSpace = true
        claims.modifiersChanged(keyCode: 63, flags: [.function])
        claims.held(true, generation: claims.generation)
        #expect(!claims.key(0, down: true, flags: [.function]).take)
        #expect(claims.key(49, down: true, flags: [.function]).claim == .handsFree)
    }
}

@MainActor
extension DictationScenarioTests {
    @Test func safetyNoticeWaitsForEarlierNoticeAndReservesItsOwnTime() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        let timer = NoticeTimer()
        dictation.noticePause = { try? await timer.wait(DictationController.noticeDuration) }
        dictation.recordingLimit = .milliseconds(50)
        dictation.holdBegan(confirmed: true)
        dictation.proposalInserted(clipboardRestored: false)
        try await Task.sleep(for: .milliseconds(70))
        #expect(dictation.phase != .recording)
        #expect(dictation.notice == .clipboardReplaced)
        await idle(dictation)
        let deadline = ContinuousClock.now + .seconds(2)
        while timer.asked.count < 2, ContinuousClock.now < deadline { await Task.yield() }
        #expect(timer.asked.count == 2)
        timer.end()
        while dictation.notice != .recordingLimit, ContinuousClock.now < deadline { await Task.yield() }
        #expect(dictation.notice == .recordingLimit)
        #expect(dictation.hasMoreToSay)
        while timer.asked.count < 4, ContinuousClock.now < deadline { await Task.yield() }
        #expect(timer.asked.count == 4)
        timer.end()
        while dictation.hasMoreToSay, ContinuousClock.now < deadline { await Task.yield() }
        #expect(!dictation.hasMoreToSay)
    }
}

@MainActor
struct HeldBoundaryTests {
    @Test func genuineReleaseAfterConfirmedHoldCannotBeErasedByLaterHardwarePress() async throws {
        let fn = NSEvent.ModifierFlags.function.rawValue
        let hold = HoldKey(handsFreeEnabled: true, key: .function)
        hold.now = { 1 }
        hold.keyboardFlags = { [fn] }
        hold.keyboardShowsKeyDown = { _ in true }
        var presses = 0, releases = 0
        hold.onPress = { presses += 1; hold.recording = true }
        hold.onRelease = { releases += 1; hold.recording = false }
        hold.modifiersChanged(.init(keyCode: 63, flags: fn, keyboard: fn, fromKeyboard: true, time: 1))
        let deadline = ContinuousClock.now + .seconds(10)
        while presses == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(presses == 1)
        // Genuine first release is queued while the next press has reached hardware.
        hold.modifiersChanged(.init(keyCode: 63, flags: 0, keyboard: fn, fromKeyboard: true, time: 2))
        #expect(releases == 1)
        hold.modifiersChanged(.init(keyCode: 63, flags: fn, keyboard: fn, fromKeyboard: true, time: 2.05))
        hold.recording = false
        hold.modifiersChanged(.init(keyCode: 63, flags: 0, keyboard: 0, fromKeyboard: true, time: 2.1))
    }

    @Test func extraModifierRejectsSpaceEvenBeforeQueuedMainActorDelivery() {
        var claims = KeyClaims()
        claims.trigger = .rightCommand
        claims.takesSpace = true
        let command = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x10)
        claims.modifiersChanged(keyCode: 54, flags: command)
        let generation = claims.generation
        claims.modifiersChanged(keyCode: 58, flags: command.union(.option))
        claims.modifiersChanged(keyCode: 58, flags: command)
        // Same late-confirmation defense required by the Command-C regression.
        claims.held(true, generation: generation)
        #expect(!claims.key(KeyClaims.space, down: true, flags: command).take)
    }

    @Test func modifierShortcutThenSpaceCannotStartRecordingThroughQueuedDeliveries() {
        let hold = HoldKey(handsFreeEnabled: true, key: .rightCommand)
        hold.keyboardFlags = { [] }
        hold.keyboardShowsKeyDown = { _ in false }
        var starts = 0
        hold.onHandsFree = { starts += 1; hold.recording = true }
        let command = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x10)
        var claims = KeyClaims()
        claims.trigger = .rightCommand
        claims.takesSpace = true
        let deliveries: [(UInt16, NSEvent.ModifierFlags)] = [(54, command), (58, command.union(.option)), (58, command)]
        for (code, flags) in deliveries { claims.modifiersChanged(keyCode: code, flags: flags) }
        let answer = claims.key(KeyClaims.space, down: true, flags: command)
        // Tap queued all changes plus Space before the main actor gets a turn.
        for (code, flags) in deliveries { hold.modifiersChanged(.init(keyCode: code, flags: flags.rawValue, generation: claims.generation)) }
        if let claim = answer.claim { hold.claimed(claim, generation: claims.generation) }
        #expect(!answer.take)
        #expect(starts == 0)
        hold.recording = false
        hold.modifiersChanged(keyCode: 54, flags: [])
    }
}

@MainActor
extension DictationScenarioTests {
    @Test(arguments: [false, true])
    func settingsCannotSynthesizeReleaseOfAPhysicallyHeldSession(changeTrigger: Bool) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let source = ScriptedSource()
        let dictation = controller(server.endpoint, source: source)
        let hold = HoldKey(handsFreeEnabled: true, key: .function)
        hold.now = { 1 }
        hold.keyboardFlags = { [] }
        hold.keyboardShowsKeyDown = { _ in false }
        hold.onPress = { dictation.holdBegan(alone: hold.pressWasAlone, confirmed: hold.holdWasConfirmed) }
        hold.onRelease = { dictation.holdEnded() }
        dictation.phaseChanged = { hold.recording = $0 == .recording }
        hold.modifiersChanged(keyCode: 63, flags: [.function])
        try await Task.sleep(for: .milliseconds(350))
        await speak()
        #expect(dictation.phase == .recording)
        if changeTrigger { hold.key = .rightOption } else { hold.recorder = { _ in } }
        #expect(dictation.phase == .recording)
        #expect(source.running)
        #expect(hold.key == .function)
        #expect(hold.recorder == nil)
        hold.modifiersChanged(keyCode: 63, flags: [])
        await idle(dictation)
        #expect(!source.running)
        #expect(field.text == "aHello.bc")
        if changeTrigger { #expect(hold.key == .rightOption) }
        else { #expect(hold.recorder != nil) }
        hold.recorder = nil
    }
}

@MainActor
struct RejectedClickClaimTests {
    @Test func clickRejectedBeforeHoldConfirmationCannotLeaveAQueuedSpaceClaim() {
        let hold = HoldKey(handsFreeEnabled: true, key: .rightCommand)
        hold.keyboardFlags = { [] }
        hold.keyboardShowsKeyDown = { _ in false }
        var starts = 0
        hold.onHandsFree = { starts += 1; hold.recording = true }
        let command = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x10)
        var claims = KeyClaims()
        claims.trigger = .rightCommand
        claims.takesSpace = true
        claims.modifiersChanged(keyCode: 54, flags: command)
        // The mouse path rejects the candidate synchronously, before it
        // queues input to the main actor.
        claims.rejectCandidate()
        let answer = claims.key(KeyClaims.space, down: true, flags: command)
        hold.modifiersChanged(.init(keyCode: 54, flags: command.rawValue, generation: claims.generation))
        hold.mouseDown(flags: command)
        if let claim = answer.claim { hold.claimed(claim, generation: claims.generation) }
        #expect(!answer.take)
        #expect(starts == 0)
        hold.recording = false
        hold.modifiersChanged(keyCode: 54, flags: [])
    }
}

@MainActor
struct HoldConfirmationRaceTests {
    @Test func shortcutQueuedDuringHardwareReadPreventsHoldConfirmation() async throws {
        let fn = NSEvent.ModifierFlags.function.rawValue
        let hold = HoldKey(handsFreeEnabled: true, key: .function, watchInterval: 5)
        hold.now = { 1 }
        var injected = false, presses = 0
        hold.keyboardFlags = {
            if !injected {
                injected = true
                // A shortcut's earlier key event reaches the tap while confirmation reads hardware.
                DispatchQueue.global().sync {
                    var input = HoldKey.Monitored(kind: .keyDown, keyCode: 0, flags: fn)
                    input.time = 1.1
                    hold.tapInput(input)
                }
            }
            return [fn]
        }
        hold.keyboardShowsKeyDown = { _ in true }
        hold.onPress = { presses += 1; hold.recording = true }
        hold.modifiersChanged(.init(keyCode: 63, flags: fn, keyboard: fn, fromKeyboard: true, time: 1))
        let deadline = ContinuousClock.now + .seconds(10)
        while !injected, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(injected)
        #expect(presses == 0)
        hold.recording = false
        hold.modifiersChanged(keyCode: 63, flags: [])
    }
}

@MainActor
struct KeyEditingDuringDictationTests {
    @Test func revertingADeferredTriggerKeepsTheOriginalKey() {
        let hold = HoldKey(handsFreeEnabled: true, key: .function)
        hold.recording = true
        hold.key = .rightOption
        hold.key = .function
        hold.recording = false
        #expect(hold.key == .function)
    }

    @Test func settingsKeyEditorWaitsUntilDictationEnds() {
        let hold = HoldKey(handsFreeEnabled: true, key: .function)
        hold.now = { 1 }
        let editor = KeyRecorder(holdKey: hold, save: { _ in })
        hold.recording = true
        editor.start()
        #expect(!editor.isRecording)
        #expect(hold.recorder == nil)
        #expect(hold.takesEscape)
        hold.recording = false
        editor.start()
        #expect(editor.isRecording)
        editor.cancel()
    }
}

@MainActor
struct LateHoldDeliveryTests {
    @Test(arguments: [HoldKey.Key.function, .rightOption, .controlOption])
    func aPressDeliveredTwoHundredMillisecondsLateWaitsOnlyTheRemainingWindow(key: HoldKey.Key) throws {
        let hold = HoldKey(handsFreeEnabled: true, key: key)
        hold.now = { 1.2 }
        hold.keyboardFlags = { [] }
        let keyCode = key.keyCode ?? 58
        var starts = 0, ends = 0
        hold.onPress = { starts += 1; hold.recording = true }
        hold.onRelease = { ends += 1; hold.recording = false }
        hold.modifiersChanged(.init(keyCode: keyCode, flags: 0, time: 0.9))
        hold.modifiersChanged(.init(keyCode: keyCode, flags: key.mask | key.families.rawValue, time: 1))
        if let arm = hold.arm {
            #expect(arm.fireDate.timeIntervalSinceNow < 0.01)
            arm.fire()
        }
        let timer = try #require(hold.gestureTimer)
        #expect(timer.fireDate.timeIntervalSinceNow < 0.15)
        timer.fire()
        #expect(starts == 1)
        hold.modifiersChanged(.init(keyCode: keyCode, flags: 0, time: 1.4))
        #expect(ends == 1)
    }

    @Test(arguments: [HoldKey.Key.function, .rightOption, .controlOption])
    func aPressDeliveredAfterTheWindowConfirmsWithoutASecondWait(key: HoldKey.Key) {
        let hold = HoldKey(handsFreeEnabled: true, key: key)
        hold.now = { 1.35 }
        hold.keyboardFlags = { [] }
        let keyCode = key.keyCode ?? 58
        var starts = 0
        hold.onPress = { starts += 1; hold.recording = true }
        hold.modifiersChanged(.init(keyCode: keyCode, flags: 0, time: 0.9))
        hold.modifiersChanged(.init(keyCode: keyCode, flags: key.mask | key.families.rawValue, time: 1))
        #expect(starts == 1)
        #expect(hold.arm == nil)
        #expect(hold.gestureTimer == nil)
        hold.modifiersChanged(.init(keyCode: keyCode, flags: 0, time: 1.4))
    }

    @Test func confirmationDeliveredBeforeTheArmCallbackIsRetriedWhenThePairArms() throws {
        let hold = HoldKey(handsFreeEnabled: true, key: .controlOption)
        hold.keyboardFlags = { [] }
        var starts = 0
        hold.onPress = { starts += 1; hold.recording = true }
        hold.modifiersChanged(keyCode: 58, flags: [])
        hold.modifiersChanged(keyCode: 58, flags: [.control, .option])
        let arm = try #require(hold.arm)
        try #require(hold.gestureTimer).fire()
        #expect(starts == 0)
        arm.fire()
        #expect(starts == 1)
        hold.modifiersChanged(keyCode: 58, flags: [])
    }
}

@MainActor
extension DictationScenarioTests {
    @Test func aQueuedFnReleaseFinishesHandsFreeEvenWhenHardwareShowsTheNextPress() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        let hold = wire(dictation)
        let fn = NSEvent.ModifierFlags.function.rawValue
        dictation.toggle()
        await speak()
        hold.modifiersChanged(.init(keyCode: 63, flags: fn, keyboard: fn, fromKeyboard: true, time: 1))
        hold.modifiersChanged(.init(keyCode: 63, flags: 0, keyboard: fn, fromKeyboard: true, time: 1.06))
        #expect(dictation.phase != .recording)
        await idle(dictation)
        #expect(field.text == "aHello.bc")
    }

    @Test func stoppingDuringMicrophoneRecoveryReleasesTheUnavailableFnClaim() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let source = ScriptedSource()
        let dictation = controller(server.endpoint, source: source)
        let hold = HoldKey(handsFreeEnabled: true, key: .function)
        let foot = FootMark(desktop: .init(screens: { [] }, pointer: { .zero }, showsWindow: false))
        DictationIndicators.connect(dictation, foot: foot, key: hold, phase: { hold.recording = $0 == .recording },
            notice: { _ in }, silence: { _ in }, nothing: { _ in })
        dictation.holdBegan(confirmed: true)
        #expect(hold.dictationAvailable)
        source.interrupt()
        #expect(hold.dictationAvailable)
        dictation.holdEnded()
        #expect(!hold.dictationAvailable)
        await idle(dictation)
        source.whileStarting = { throw Microphone.Failure.unavailable }
        dictation.toggle()
        #expect(!hold.dictationAvailable)
        #expect(HoldKey.Key.function.consumedKeyCode(dictationAvailable: hold.dictationAvailable) == nil)
    }
}

@MainActor
struct RecordingIssuePresentationTests {
    @Test func theFootDoesNotRepeatTheCaretIndicatorsRecordingWarning() {
        let foot = FootPlacementTests.foot(saysWords: false)
        foot.state = .listening
        foot.recordingIssue = "Reconnecting microphone…"
        #expect(foot.slipFrame == nil)
        foot.saysWords = true
        #expect(foot.slipFrame != nil)
        foot.recordingIssue = nil
        #expect(foot.slipFrame == nil)
    }

    @Test func aPersistentNoCaretWarningEndsOnlyWhenRecoveryClearsIt() async throws {
        let panel = DotNotice(showsWindow: false)
        var caption: String?
        func show(_ words: String?) {
            DictationIndicators.sayRecordingIssue(words, throughFoot: false, caretAnchor: nil,
                caption: { caption = $0 }, panel: { notice in
                    if let notice { panel.show(notice, beside: nil, for: nil) } else { panel.hide() }
                })
        }
        // Prove the same panel honors a timeout, then a persistent status
        // replaces it and cancels that pending dismissal.
        panel.show(.notice("Earlier notice"), beside: nil, for: .milliseconds(10))
        show("Reconnecting microphone…")
        try await Task.sleep(for: .milliseconds(30))
        #expect(caption == nil)
        #expect(panel.isShown)
        show(nil)
        #expect(!panel.isShown)
    }
}

@MainActor
extension DictationScenarioTests {
    @Test func aSecondSpaceWithTheTriggerStillDownFinishesHandsFree() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        let hold = wire(dictation)
        hold.modifiersChanged(keyCode: 63, flags: [.function])
        hold.claimed(.handsFree)
        #expect(dictation.handsFree)
        await speak()
        hold.claimed(.handsFree)
        #expect(dictation.phase != .recording)
        hold.modifiersChanged(keyCode: 63, flags: [])
        await idle(dictation)
        #expect(field.text == "aHello.bc")
    }
}

@MainActor
struct DeferredKeyEditorTests {
    @Test func cancellingADeferredEditorDoesNotReactivateItAfterRecording() {
        let hold = HoldKey(handsFreeEnabled: true, key: .function)
        var keys = 0
        hold.recorder = { _ in keys += 1 }
        hold.recording = true
        hold.recorder = nil
        hold.recording = false
        #expect(hold.recorder == nil)
        hold.keyDown(keyCode: 0, flags: [])
        #expect(keys == 0)
    }
}
