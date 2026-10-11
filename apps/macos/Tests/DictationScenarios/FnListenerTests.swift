import AppKit
import Testing
@testable import Dictation

struct FnListenerTests {
    @Test func trustFlipsInvalidateAndRebuildInBothDirections() {
        var state = FnListenerRecovery()
        #expect(state.poll(trusted: false, secureInput: false, healthy: false, at: 0) == .stop)
        #expect(state.state == .waitingForAccessibility)
        #expect(state.poll(trusted: true, secureInput: false, healthy: false, at: 1) == .rebuild(.trustChanged))
        state.attached(true, at: 1)
        #expect(!state.tapProven)
        state.receivedFromTap()
        #expect(state.state == .live)
        #expect(state.poll(trusted: false, secureInput: false, healthy: true, at: 5) == .stop)
        #expect(!state.tapProven)
        #expect(state.poll(trusted: true, secureInput: false, healthy: false, at: 6) == .rebuild(.trustChanged))
    }

    @Test func disabledTapGetsTimeToRecoverThenRebuilds() {
        var state = FnListenerRecovery()
        _ = state.poll(trusted: true, secureInput: false, healthy: false, at: 0)
        state.receivedFromTap()
        state.request(.disabled, at: 3)
        #expect(!state.tapProven)
        #expect(state.poll(trusted: true, secureInput: false, healthy: true, at: 4.9) == nil)
        #expect(state.poll(trusted: true, secureInput: false, healthy: true, at: 5) == .rebuild(.disabled))
        state.receivedFromTap()
        state.request(.disabled, at: 10)
        state.receivedFromTap()
        #expect(state.poll(trusted: true, secureInput: false, healthy: true, at: 12) == nil)
        #expect(state.tapProven)
    }

    @Test func repeatedFailuresHaveAFiniteBudgetAndRetryHasARateLimit() {
        var state = FnListenerRecovery()
        var rebuilds = 0
        for time in 0..<1000 {
            if case .rebuild? = state.poll(trusted: true, secureInput: false, healthy: false, at: Double(time)) {
                rebuilds += 1
                state.attached(false, at: Double(time))
            }
        }
        #expect(rebuilds == 4)
        #expect(state.state == .failed)
        state.retry(at: 1000)
        #expect(state.poll(trusted: true, secureInput: false, healthy: false, at: 1000) == .rebuild(.retry))
        state.retry(at: 1000)
        #expect(state.poll(trusted: true, secureInput: false, healthy: false, at: 1000) == nil)
    }

    @Test func successfulRecoveryRenewsTheBudgetWithoutRemovingTheRateLimit() {
        var state = FnListenerRecovery()
        for time in stride(from: 0.0, through: 30, by: 3) {
            state.request(.healthCheck, at: time)
            #expect(state.poll(trusted: true, secureInput: false, healthy: false, at: time) != nil)
            state.receivedFromTap()
            #expect(state.attempts == 0)
            state.request(.healthCheck, at: time)
            #expect(state.poll(trusted: true, secureInput: false, healthy: false, at: time) == nil)
        }
    }

    @Test @MainActor func aSkippedCheckWarningClearsOnRecoveryOrAnotherTrigger() {
        for changeKey in [false, true] {
            let hold = HoldKey(key: .function)
            var warnings: [String?] = []
            hold.onListenerProblem = { warnings.append($0) }
            hold.reportSkippedListenerCheck()
            #expect(warnings.last! == "Can't hear fn, quit and reopen Intention")
            if changeKey { hold.key = .rightOption }
            else { hold.proveListenerForTesting() }
            #expect(warnings.count == 2)
            #expect(warnings.last! == nil)
        }
    }

    @Test @MainActor func recorderOwnedKeysDoNotRequestTapRecovery() async {
        let hold = HoldKey(key: .function)
        hold.now = { 0 }
        hold.diagnostic = { _, _ in }
        var recorded = 0
        hold.recorder = { _ in recorded += 1 }
        hold.proveListenerForTesting()
        var input = HoldKey.Monitored(kind: .keyDown, keyCode: 0)
        input.time = 10
        let down = input
        await Task.detached { hold.tapInput(down) }.value
        try? await Task.sleep(for: .milliseconds(20))
        hold.received(down)
        #expect(recorded == 1)
        #expect(hold.listenerActionForTesting(at: 100) == nil)
    }

    @Test func secureInputSuspendsTheTapUntilItEnds() {
        var state = FnListenerRecovery()
        _ = state.poll(trusted: true, secureInput: false, healthy: false, at: 0)
        state.receivedFromTap()
        #expect(state.poll(trusted: true, secureInput: true, healthy: true, at: 5) == .stop)
        #expect(state.state == .blockedBySecureInput)
        state.receivedFromTap()
        #expect(state.state == .blockedBySecureInput)
        #expect(state.poll(trusted: true, secureInput: true, healthy: false, at: 100) == nil)
        #expect(state.poll(trusted: true, secureInput: false, healthy: false, at: 101) == .rebuild(.secureInputEnded))
    }

    @Test func silenceIsNotFailureButBrokenHealthAndMonitorMissesAre() {
        var state = FnListenerRecovery()
        _ = state.poll(trusted: true, secureInput: false, healthy: false, at: 0)
        state.attached(true, at: 0)
        #expect(state.poll(trusted: true, secureInput: false, healthy: true, at: 100) == nil)
        #expect(state.state == .checking)
        state.receivedFromTap()
        #expect(state.poll(trusted: true, secureInput: false, healthy: false, at: 101) == .rebuild(.healthCheck))
        state.receivedFromTap()
        state.request(.monitorMiss, at: 110)
        state.receivedFromMonitor(at: 110)
        #expect(!state.tapProven)
        #expect(state.poll(trusted: true, secureInput: false, healthy: true, at: 110) == .rebuild(.monitorMiss))
    }

    @Test @MainActor func shortHoldsAreCountedButHintsAreThrottled() {
        let hold = HoldKey(key: .function, holdDelay: 100)
        hold.diagnostic = { _, _ in }
        var time: TimeInterval = 1
        var hints = 0
        var shorts = 0
        hold.now = { time }
        hold.onShortHold = { hints += 1 }
        hold.diagnostic = { name, _ in if name == .fnShort { shorts += 1 } }
        for start in [1.0, 2, 3, 31, 32] {
            time = start
            hold.modifiersChanged(keyCode: 63, flags: .function)
            time += 0.05
            hold.modifiersChanged(keyCode: 63, flags: [])
        }
        #expect(shorts == 5)
        #expect(hints == 2)
    }

    @Test @MainActor func monitorAndTapCopiesCountOnceAndCallbacksHopFromBackground() async {
        let hold = HoldKey(key: .function, holdDelay: 100)
        var received = 0
        hold.diagnostic = { name, _ in if name == .fnReceived { received += 1 } }
        var press = HoldKey.Monitored(kind: .modifiers, keyCode: 63, flags: NSEvent.ModifierFlags.function.rawValue)
        press.time = 10
        var release = HoldKey.Monitored(kind: .modifiers, keyCode: 63)
        release.time = 10.1
        let down = press, up = release
        await Task.detached {
            hold.received(down)
            hold.tapDelivered(.init(keyCode: 63, flags: down.flags, time: down.time))
            hold.received(up)
            hold.tapDelivered(.init(keyCode: 63, flags: 0, time: up.time))
            hold.tapWasDisabled()
        }.value
        try? await Task.sleep(for: .milliseconds(50))
        #expect(received == 2)
    }

    @Test @MainActor func choosingAnotherKeyClearsTheFnProblem() {
        let hold = HoldKey(key: .function)
        hold.listener.update(.failed)
        var message: String? = "initial"
        hold.onListenerProblem = { message = $0 }
        hold.key = .rightOption
        #expect(message == nil)
        hold.key = .function
        #expect(message == "Can't hear fn, quit and reopen Intention")
    }

    @Test @MainActor func healthProofRequiresAFnPairAndShortHintUsesMonotonicTime() {
        let health = FnListenerHealth()
        health.update(.live)
        health.receivedTrigger(down: false, at: 1, date: Date(timeIntervalSince1970: 1))
        #expect(health.completedPress?.ended == nil)
        health.receivedTrigger(down: true, at: 2, date: Date(timeIntervalSince1970: 2))
        #expect(health.completedPress?.ended == nil)
        health.receivedTrigger(down: false, at: 3, date: Date(timeIntervalSince1970: 3))
        #expect(health.completedPress?.ended == Date(timeIntervalSince1970: 3))
        #expect(health.offerShortHint(at: 10))
        #expect(!health.offerShortHint(at: 10.1))
        #expect(health.offerShortHint(at: 40))
    }
    @Test func clearingABlockClearsItsMessageEvenDuringBackoff() {
        for secure in [false, true] {
            var state = FnListenerRecovery()
            for time in [0.0, 2, 6, 14] {
                _ = state.poll(trusted: true, secureInput: false, healthy: false, at: time)
                state.attached(false, at: time)
            }
            _ = state.poll(trusted: secure, secureInput: secure, healthy: false, at: 15)
            #expect(state.state == (secure ? .blockedBySecureInput : .waitingForAccessibility))
            #expect(state.poll(trusted: true, secureInput: false, healthy: false, at: 16) == nil)
            #expect(state.state == .checking)
            #expect(state.poll(trusted: true, secureInput: false, healthy: false, at: 30) != nil)
        }
    }

    @Test @MainActor func delayedMonitorPressCannotFollowAnImmediateRelease() async {
        let hold = HoldKey(key: .function, holdDelay: 0)
        var delayed: (@MainActor @Sendable () -> Void)?
        var starts = 0
        hold.onPress = { starts += 1 }
        hold.diagnostic = { _, _ in }
        hold.scheduleMonitorFallback = { _, action in delayed = action }
        // Establish a live tap with a real epoch. No native listener is installed.
        hold.accessibilityTrusted = { false }
        hold.checkListener()
        hold.accessibilityTrusted = { true }
        // Pause the production fallback scheduler at the failing interleaving.
        hold.proveListenerForTesting()
        var down = HoldKey.Monitored(kind: .modifiers, keyCode: 63, flags: NSEvent.ModifierFlags.function.rawValue)
        down.time = 10
        hold.received(down)
        #expect(delayed != nil)
        hold.tapWasDisabled(epoch: 1)
        try? await Task.sleep(for: .milliseconds(20))
        var up = HoldKey.Monitored(kind: .modifiers, keyCode: 63)
        up.time = 10.05
        hold.received(up)
        delayed?()
        #expect(starts == 0)
        #expect(!hold.holdWasConfirmed)
    }

    @Test @MainActor func staleEpochCannotProveDeliveryButConsumedEscapeKeepsItsOwner() async {
        let hold = HoldKey(key: .function, holdDelay: 0)
        hold.diagnostic = { _, _ in }
        hold.accessibilityTrusted = { false }
        hold.checkListener() // Invalidates epoch zero without installing a native tap.
        var events = 0
        var cancelled = 0
        hold.diagnostic = { name, _ in if name == .fnReceived { events += 1 } }
        let cancellation: @Sendable @MainActor () -> Void = { cancelled += 1 }
        await Task.detached {
            hold.tapDelivered(.init(keyCode: 63, flags: NSEvent.ModifierFlags.function.rawValue), epoch: 0)
            hold.tapInput(.init(kind: .keyDown, keyCode: 48), epoch: 0)
            hold.tapWasDisabled(epoch: 0)
            hold.tapClaimed(.escape, cancellation: cancellation, epoch: 0)
        }.value
        try? await Task.sleep(for: .milliseconds(20))
        #expect(events == 0)
        #expect(cancelled == 1)
        #expect(hold.listener.state == .waitingForAccessibility)
    }

    @Test func replacementKeepsConsumedFnTabEscapeAndSpaceReleases() {
        var holds = ConsumedHolds()
        holds.consumed = 63
        let tookFn = holds.drops(keyCode: 63, flags: .function)
        #expect(tookFn)
        var claims = KeyClaims()
        claims.escapeCancels = true
        #expect(claims.key(53, down: true, flags: []).take)
        claims.trigger = .function
        claims.takesSpace = true
        claims.modifiersChanged(keyCode: 63, flags: .function, dropped: true)
        #expect(claims.key(49, down: true, flags: .function).take)
        var tabs = TakenTabs()
        tabs.generation = 7
        #expect(tabs.decide(.keyDown(keyCode: 48, flags: 0, isRepeat: false)).drops)
        // This is the value snapshot stop() transfers to the replacement.
        var replacement = TriggerTap.PressState(holds: holds, claims: claims, tabs: tabs)
        replacement.holds.consumed = nil
        replacement.claims.escapeCancels = false
        replacement.claims.takesSpace = false
        replacement.tabs.generation = nil
        let tookFnRelease = replacement.holds.drops(keyCode: 63, flags: [])
        #expect(tookFnRelease)
        for code: UInt16 in [53, 49, 48] {
            #expect(TriggerTap.key(code, down: true, flags: [], isRepeat: true,
                                   claims: &replacement.claims, tabs: &replacement.tabs).take)
            #expect(TriggerTap.key(code, down: false, flags: [], isRepeat: false,
                                   claims: &replacement.claims, tabs: &replacement.tabs).take)
        }
    }

    @Test @MainActor func retiredTapStillDeliversCapturedTabAndItsOwnFnRelease() async {
        let hold = HoldKey(key: .function, holdDelay: 0)
        hold.diagnostic = { _, _ in }
        var released = 0
        var accepted: [UInt64] = []
        hold.onRelease = { released += 1 }
        hold.tabTaken = { accepted.append($0) }
        hold.modifiersChanged(.init(keyCode: 63, flags: NSEvent.ModifierFlags.function.rawValue,
                                    generation: 7, tapOwned: true), epoch: 0)
        hold.accessibilityTrusted = { false }
        hold.checkListener()
        await Task.detached {
            hold.tapInput(.init(kind: .keyDown, keyCode: 48, proposalTab: true), tabTaken: 91, epoch: 0)
            hold.tapDelivered(.init(keyCode: 63, flags: 0, generation: 7, tapOwned: true), epoch: 0)
        }.value
        try? await Task.sleep(for: .milliseconds(20))
        #expect(accepted == [91])
        #expect(released == 1)
        #expect(hold.listener.state == .waitingForAccessibility)
        // A late release from that old press cannot end a new epoch's hold.
        hold.modifiersChanged(.init(keyCode: 63, flags: NSEvent.ModifierFlags.function.rawValue,
                                    generation: 8, tapOwned: true), epoch: 1)
        hold.tapDelivered(.init(keyCode: 63, flags: 0, generation: 7, tapOwned: true), epoch: 0)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(released == 1)
        hold.modifiersChanged(.init(keyCode: 63, flags: 0, generation: 8, tapOwned: true), epoch: 1)
    }

    @Test func eventsDuringATapGapReconcileTheRetainedPress() {
        var tabs = TakenTabs()
        tabs.generation = 1
        _ = tabs.decide(.keyDown(keyCode: 48, flags: 0, isRepeat: false))
        var retained = TriggerTap.PressState(holds: ConsumedHolds(), claims: KeyClaims(), tabs: tabs,
                                            eventTimes: [48: 10])
        var up = HoldKey.Monitored(kind: .keyUp, keyCode: 48)
        up.time = 11
        retained.observePassed(up)
        var down = HoldKey.Monitored(kind: .keyDown, keyCode: 48)
        down.time = 12
        retained.observePassed(down)
        let repeated = TriggerTap.key(48, down: true, flags: [], isRepeat: true,
                                      claims: &retained.claims, tabs: &retained.tabs)
        let released = TriggerTap.key(48, down: false, flags: [], isRepeat: false,
                                      claims: &retained.claims, tabs: &retained.tabs)
        #expect(!repeated.take)
        #expect(!released.take)
    }

    @Test func lateGapEventsDoNotRejectANewerFnPress() {
        var claims = KeyClaims()
        claims.trigger = .function
        claims.takesSpace = true
        claims.modifiersChanged(keyCode: 63, flags: .function, stamp: 20_000_000_000)
        var state = TriggerTap.PressState(holds: ConsumedHolds(), claims: claims, tabs: TakenTabs())
        var down = HoldKey.Monitored(kind: .keyDown, keyCode: 0)
        down.time = 10
        var up = HoldKey.Monitored(kind: .keyUp, keyCode: 0)
        up.time = 11
        state.observePassed(down)
        state.observePassed(up)
        var modifier = HoldKey.Monitored(kind: .modifiers, keyCode: 55,
                                        flags: NSEvent.ModifierFlags([.function, .command]).rawValue)
        modifier.time = 12
        state.observePassed(modifier)
        #expect(state.claims.keysClear)
        let acceptedNewerHold = state.claims.held(true, generation: state.claims.generation)
        #expect(acceptedNewerHold)
        state.claims.held(false, generation: state.claims.generation)
        down.time = 21
        state.observePassed(down)
        let acceptedShortcut = state.claims.held(true, generation: state.claims.generation)
        #expect(!acceptedShortcut)
    }

    @Test @MainActor func lateGapKeysDoNotCancelTheNewerMainActorHold() {
        let hold = HoldKey(key: .function, holdDelay: 100)
        hold.now = { 20 }
        hold.diagnostic = { _, _ in }
        var otherKeys = 0
        hold.onOtherKey = { otherKeys += 1 }
        hold.modifiersChanged(.init(keyCode: 63, flags: NSEvent.ModifierFlags.function.rawValue, time: 20))
        var down = HoldKey.Monitored(kind: .keyDown, keyCode: 0)
        down.time = 10
        var up = HoldKey.Monitored(kind: .keyUp, keyCode: 0)
        up.time = 11
        #expect(hold.reconcileLateGapInput(down))
        #expect(hold.reconcileLateGapInput(up))
        #expect(otherKeys == 0)
        down.time = 21
        #expect(!hold.reconcileLateGapInput(down))
        hold.received(down)
        #expect(otherKeys == 1)
    }

}
