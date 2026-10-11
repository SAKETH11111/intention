import AppKit
import Testing
@testable import Dictation

struct FnRejectionTests {
    @Test @MainActor func launchRebuildThenFourSecondLoneFnHoldStartsDictation() {
        var retained = KeyClaims()
        retained.trigger = .function
        retained.keyShowsDown = { _ in false }
        retained.seed(keysDown: [0, KeyClaims.globe])
        var replacement = retained
        // The new listener's keyboard snapshot is clear. Retained key
        // history must not survive that snapshot as a held letter.
        replacement.seed(keysDown: [])
        replacement.startedAt = 3_000_000
        replacement.modifiersChanged(keyCode: 63, flags: .function, stamp: 1_668_000_000,
                                     releasesArrived: { false })

        let hold = HoldKey(key: .function)
        var time = 2.0
        var starts = 0
        var stops = 0
        var rejections = 0
        hold.now = { time }
        hold.keyboardFlags = { [NSEvent.ModifierFlags.function.rawValue] }
        hold.diagnostic = { name, _ in if name == .fnRejected { rejections += 1 } }
        hold.onPress = { starts += 1; hold.recording = true }
        hold.onRelease = { stops += 1; hold.recording = false }
        // Launch at zero, trust rebuild at .003, Fn at 1.668, release at
        // 5.859. Delivery is late enough to confirm the normal 300 ms hold.
        hold.modifiersChanged(.init(keyCode: 63, flags: NSEvent.ModifierFlags.function.rawValue,
                                    keysClear: replacement.keysClear, time: 1.668))
        #expect(hold.pressWasAlone)
        #expect(hold.holdWasConfirmed)
        #expect(starts == 1)
        time = 5.859
        hold.modifiersChanged(.init(keyCode: 63, flags: 0, time: time))
        #expect(stops == 1)
        #expect(rejections == 0)
    }

    @Test @MainActor func globeCompanionDuringLoneFnDoesNotRejectIt() {
        let hold = HoldKey(key: .function, holdDelay: 100)
        var rejections = 0
        hold.diagnostic = { name, _ in if name == .fnRejected { rejections += 1 } }
        hold.modifiersChanged(keyCode: 63, flags: .function)
        hold.keyDown(keyCode: KeyClaims.globe, flags: .function)
        #expect(rejections == 0)
        hold.modifiersChanged(keyCode: 63, flags: [])
        var claims = KeyClaims()
        claims.trigger = .function
        claims.observePassed(keyCode: KeyClaims.globe, down: true, isRepeat: false)
        claims.modifiersChanged(keyCode: 63, flags: .function)
        #expect(claims.keysClear)
    }

    @Test @MainActor func thirtySecondsOfMonitorFirstTypingNeverRebuildsALiveTap() async {
        let hold = HoldKey(key: .function)
        var time = 0.0
        var rebuilds = 0
        var presses = 0
        hold.now = { time }
        hold.diagnostic = { _, _ in }
        hold.scheduleMonitorFallback = { _, action in action() }
        hold.keyPressed = { _, _ in presses += 1 }
        hold.proveListenerForTesting()
        for index in 1...300 {
            time = Double(index) / 10
            var input = HoldKey.Monitored(kind: index.isMultiple(of: 2) ? .keyUp : .keyDown, keyCode: 0)
            input.time = time
            // Even after its 80 ms head start, the monitor can win the
            // race with the tap's asynchronous delivery to the main actor.
            hold.received(input)
            if hold.listenerActionForTesting(at: time) != nil { rebuilds += 1 }
            hold.tapInput(input)
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        #expect(rebuilds == 0)
        #expect(presses == 150)
    }

    @Test func aQuietKeyboardNeedsSustainedMonitorKeysBeforeRecovery() {
        var recovery = FnListenerRecovery()
        #expect(recovery.poll(trusted: true, secureInput: false, healthy: true, at: 0) == .rebuild(.trustChanged))
        recovery.attached(true, at: 0)
        recovery.receivedFromTap()
        #expect(recovery.poll(trusted: true, secureInput: false, healthy: true, at: 100) == nil)
        recovery.receivedFromMonitor(at: 100)
        #expect(recovery.poll(trusted: true, secureInput: false, healthy: true, at: 100) == nil)
        recovery.receivedFromTap()
        recovery.receivedFromMonitor(at: 200, observingKeys: false)
        recovery.receivedFromMonitor(at: 210, observingKeys: false)
        #expect(recovery.poll(trusted: true, secureInput: false, healthy: true, at: 210) == nil)
        recovery.receivedFromMonitor(at: 220)
        recovery.receivedFromMonitor(at: 222.9)
        #expect(recovery.poll(trusted: true, secureInput: false, healthy: true, at: 222.9) == nil)
        recovery.receivedFromMonitor(at: 223)
        #expect(recovery.poll(trusted: true, secureInput: false, healthy: true, at: 223) == .rebuild(.monitorMiss))
    }

    @Test func aKeyStillPhysicallyHeldAcrossRebuildRemainsAShortcut() {
        var claims = KeyClaims()
        claims.trigger = .function
        claims.seed(keysDown: [0, 1])
        claims.seed(keysDown: [0])
        claims.keyShowsDown = { $0 == 0 }
        claims.modifiersChanged(keyCode: 63, flags: .function)
        #expect(!claims.keysClear)
        claims.key(0, down: false, flags: .function)
        claims.modifiersChanged(keyCode: 63, flags: [])
        claims.modifiersChanged(keyCode: 63, flags: .function)
        #expect(claims.keysClear)
    }

    @Test func monitorSilenceCannotShortenDisabledTapRecovery() {
        var recovery = FnListenerRecovery()
        _ = recovery.poll(trusted: true, secureInput: false, healthy: true, at: 0)
        recovery.attached(true, at: 0)
        recovery.receivedFromTap()
        recovery.receivedFromMonitor(at: 100)
        recovery.request(.disabled, at: 102.5)
        recovery.receivedFromMonitor(at: 103)
        #expect(recovery.poll(trusted: true, secureInput: false, healthy: true, at: 103) == nil)
        #expect(recovery.poll(trusted: true, secureInput: false, healthy: true, at: 104.5) == .rebuild(.disabled))
    }
}
