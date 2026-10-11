import AppKit
@testable import Dictation
import Testing

/// When Intention asks for Screen Recording by itself, and which way, against
/// a defaults domain of its own and a made-up grant. Nothing asks macOS.
@MainActor
struct ScreenRecordingRequestTests {
    @Test func laterGrantsAndRevocationsReportOnlyChanges() {
        let state = Asked()
        let watcher = ScreenRecordingRequest(preferences: Preferences(defaults: defaults()),
                                             isGranted: { state.granted }, request: {}, requestFromPress: { _ in })
        watcher.reported = { state.reports.append($0) }
        watcher.refresh()
        state.granted = true
        watcher.refresh()
        watcher.refresh()
        state.granted = false
        watcher.refresh()
        watcher.refresh()
        #expect(state.reports == [true, false])
    }

    private final class Asked {
        var granted = false
        var reports: [Bool] = []
        var plain = 0
        var fromPress = 0
        /// Press-style requests not yet run, as while `PermissionAlert`
        /// waits its turn.
        var waiting: [@MainActor () -> Bool] = []
    }

    private func defaults() -> UserDefaults {
        let name = "ScreenRecordingRequestTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func request(_ store: UserDefaults, granted: Bool = false, _ asked: Asked) -> ScreenRecordingRequest {
        ScreenRecordingRequest(preferences: Preferences(defaults: store), isGranted: { granted }, request: { asked.plain += 1 },
                               requestFromPress: { ask in asked.fromPress += 1; asked.waiting.append(ask) })
    }

    @Test func theEndOfSetupAsksTheWayAPressDoesAndOnlyOnce() {
        let store = defaults(), asked = Asked()
        request(store, asked).afterSetup()
        #expect(asked.fromPress == 1)
        #expect(!Preferences(defaults: store).screenRecordingRequested)
        _ = asked.waiting.removeFirst()()
        #expect(asked.plain == 1)
        #expect(Preferences(defaults: store).screenRecordingRequested)
        // Neither the end of setup again nor the next launch asks again.
        request(store, asked).afterSetup()
        request(store, asked).atLaunch()
        #expect(asked.fromPress == 1)
        #expect(asked.plain == 1)
    }

    @Test func setupEndingTwiceBeforeTheRequestRunsAsksOnce() {
        let store = defaults(), asked = Asked()
        let once = request(store, asked)
        // An account change, then setup again, before the first request's turn.
        once.afterSetup()
        once.afterSetup()
        #expect(asked.waiting.count == 1)
        _ = asked.waiting.removeFirst()()
        once.afterSetup()
        #expect(asked.plain == 1)
        #expect(asked.waiting.isEmpty)
    }

    @Test func aRequestThatNeverRanIsMadeAtTheNextLaunch() {
        let store = defaults(), asked = Asked()
        request(store, asked).afterSetup()
        // Intention quits before the alert's turn comes: macOS was never asked.
        asked.waiting.removeAll()
        request(store, asked).atLaunch()
        #expect(asked.plain == 1)
        #expect(Preferences(defaults: store).screenRecordingRequested)
    }

    @Test func aChoiceChangedWhileTheRequestWaitsAsksNothing() {
        // Hiding the caret dot is the one choice that can change while Intention runs:
        // finding the caret on screen is fixed for a launch since Settings
        // lost its switch.
        do {
            let store = defaults(), asked = Asked()
            let waiting = request(store, asked)
            waiting.afterSetup()
            waiting.preferences.indicator = .foot
            #expect(asked.waiting.removeFirst()() == false)
            #expect(asked.plain == 0)
            // Not remembered as asked, so turning the dot back on asks at the next launch.
            #expect(!Preferences(defaults: store).screenRecordingRequested)
        }
        let store = defaults(), asked = Asked()
        let waiting = request(store, asked)
        waiting.afterSetup()
        #expect(asked.waiting.removeFirst()() == true)
        #expect(asked.plain == 1)
    }

    @Test func aMacSetUpBeforeIsAskedAtLaunchWithoutOpeningAnything() {
        let store = defaults(), asked = Asked()
        request(store, asked).atLaunch()
        #expect(asked.plain == 1)
        #expect(asked.fromPress == 0)
        request(store, asked).afterSetup()
        #expect(asked.plain == 1)
        #expect(asked.fromPress == 0)
    }

    @Test func restoringAnOldPillDoesNotAskAtLaunchOrClaimARequestWasMade() {
        let store = defaults(), asked = Asked()
        store.set("pill", forKey: "indicator")
        request(store, asked).atLaunch()
        // The deferral survives relaunches instead of delaying the surprise.
        request(store, asked).atLaunch()
        #expect(asked.plain == 0 && asked.fromPress == 0)
        #expect(!Preferences(defaults: store).screenRecordingRequested)
        #expect(Preferences(defaults: store).indicator == .dot)
        // An explicit Hide, then Show, restores the ordinary launch flow.
        Preferences(defaults: store).indicator = .foot
        request(store, asked).atLaunch()
        #expect(asked.plain == 0)
        Preferences(defaults: store).indicator = .dot
        request(store, asked).atLaunch()
        #expect(asked.plain == 1 && asked.fromPress == 0)
    }

    @Test func anOldPillCanStillAskThroughTheExplainedSetupFlow() {
        let store = defaults(), asked = Asked()
        store.set("pill", forKey: "indicator")
        let restored = request(store, asked)
        #expect(restored.due)
        restored.afterSetup()
        #expect(asked.fromPress == 1 && asked.plain == 0)
        #expect(asked.waiting.removeFirst()())
        #expect(asked.plain == 1)
        #expect(Preferences(defaults: store).screenRecordingRequested)
        request(store, asked).atLaunch()
        #expect(asked.plain == 1)
    }

    @Test func nothingIsAskedWithTheGrantTheFootOrTheOptionOff() {
        let granted = defaults(), asked = Asked()
        request(granted, granted: true, asked).afterSetup()
        request(granted, granted: true, asked).atLaunch()
        // Held already, so the one request is still to come if it is withdrawn.
        #expect(!Preferences(defaults: granted).screenRecordingRequested)
        let foot = defaults()
        Preferences(defaults: foot).indicator = .foot
        request(foot, asked).afterSetup()
        // Turned off with the Settings switch Intention had before October 6, 2026.
        let off = defaults()
        off.set(false, forKey: "visualCaretEnabled")
        request(off, asked).afterSetup()
        #expect(asked.plain == 0)
        #expect(asked.fromPress == 0)
    }
}
