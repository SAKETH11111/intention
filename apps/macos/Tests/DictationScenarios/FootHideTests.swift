import AppKit
@testable import Dictation
import Testing

@MainActor
struct FootHideTests {
    private let start = Date(timeIntervalSince1970: 2_000_000_000)

    @MainActor
    private final class Waiter {
        var durations: [Duration] = []
        var pending: [CheckedContinuation<Void, Never>] = []

        func wait(_ duration: Duration) async {
            durations.append(duration)
            await withCheckedContinuation { pending.append($0) }
        }

        func releaseFirst() { pending.removeFirst().resume() }
    }

    private func foot(_ waiter: Waiter, hiddenUntil: Date? = nil) -> FootMark {
        let screen = FootMark.Screen(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                     usable: CGRect(x: 0, y: 80, width: 1440, height: 795))
        let foot = FootMark(desktop: .init(screens: { [screen] }, pointer: { CGPoint(x: 700, y: 400) }, showsWindow: false),
                            hiddenUntil: hiddenUntil, dateNow: { start }, hideWait: waiter.wait)
        foot.mark.reducesMotion = { true }
        foot.enabled = true
        return foot
    }

    @Test func aHideStopsPaintingAndReturnsAfterTheRequestedWait() async throws {
        let waiter = Waiter()
        let foot = foot(waiter)
        defer { foot.enabled = false }
        var changes: [Date?] = []
        foot.hiddenChanged = { changes.append($0) }
        #expect(foot.painting)
        let until = start.addingTimeInterval(3600)
        foot.hide(until: until)
        #expect(foot.hiddenUntil == until)
        #expect(!foot.painting)
        #expect(!foot.carriesRed)
        #expect(foot.markFrame == nil)
        try #require(await AppearanceCallbackTests.eventually { waiter.pending.count == 1 })
        #expect(waiter.durations == [.seconds(3600)])
        let ends = foot.hideEnds
        waiter.releaseFirst()
        await ends?.value
        #expect(foot.hiddenUntil == nil)
        #expect(foot.painting)
        #expect(changes == [until, nil])
    }

    @Test func aNewHideReplacesTheOldEvenWhenItsCancelledWaitFinishes() async throws {
        let waiter = Waiter()
        let foot = foot(waiter)
        defer { foot.enabled = false }
        foot.hide(until: start.addingTimeInterval(60))
        try #require(await AppearanceCallbackTests.eventually { waiter.pending.count == 1 })
        let old = foot.hideEnds
        let replacement = start.addingTimeInterval(120)
        foot.hide(until: replacement)
        try #require(await AppearanceCallbackTests.eventually { waiter.pending.count == 2 })
        waiter.releaseFirst()
        await old?.value
        #expect(foot.hiddenUntil == replacement)
        #expect(!foot.painting)
        let current = foot.hideEnds
        waiter.releaseFirst()
        await current?.value
        #expect(foot.hiddenUntil == nil)
        #expect(foot.painting)
        #expect(waiter.durations == [.seconds(60), .seconds(120)])
    }

    @Test func showAgainCancelsTheHideAndAnExpiredHideDoesNothing() async throws {
        let waiter = Waiter()
        let foot = foot(waiter)
        defer { foot.enabled = false }
        foot.hide(until: start.addingTimeInterval(60))
        try #require(await AppearanceCallbackTests.eventually { waiter.pending.count == 1 })
        let cancelled = foot.hideEnds
        foot.showAgain()
        #expect(cancelled?.isCancelled == true)
        #expect(foot.hiddenUntil == nil)
        #expect(foot.painting)
        waiter.releaseFirst()
        await cancelled?.value
        foot.hide(until: start.addingTimeInterval(-1))
        #expect(foot.hiddenUntil == nil)
        #expect(foot.painting)
        #expect(waiter.durations.count == 1)
    }

    @Test func hidingSurvivesRelaunchAndAnExpiredSavedDeadlineIsCleared() async throws {
        let suite = "co.intention.tests.foot-hide.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let until = start.addingTimeInterval(3600)
        Preferences(defaults: defaults, now: start).footHiddenUntil = until
        let restored = Preferences(defaults: defaults, now: start)
        #expect(restored.footHiddenUntil == until)
        let waiter = Waiter()
        let foot = foot(waiter, hiddenUntil: restored.footHiddenUntil)
        foot.hiddenChanged = { restored.footHiddenUntil = $0 }
        defer { foot.enabled = false }
        #expect(foot.hiddenUntil == until)
        #expect(!foot.painting)
        try #require(await AppearanceCallbackTests.eventually { waiter.pending.count == 1 })
        let ends = foot.hideEnds
        waiter.releaseFirst()
        await ends?.value
        #expect(Preferences(defaults: defaults, now: start).footHiddenUntil == nil)
        restored.footHiddenUntil = start.addingTimeInterval(-1)
        #expect(Preferences(defaults: defaults, now: start).footHiddenUntil == nil)
        #expect(defaults.object(forKey: "footHiddenUntil") == nil)
        let expired = self.foot(Waiter(), hiddenUntil: start)
        defer { expired.enabled = false }
        #expect(expired.hiddenUntil == nil)
        #expect(expired.painting)
    }

    /// The hide puts away only the resting dot: a recording started or
    /// running while hidden shows its sun with Done, a notice shows, and the
    /// dot goes again once it rests.
    @Test func aHiddenFootStillShowsARecordingAndANotice() async throws {
        let waiter = Waiter()
        let foot = foot(waiter)
        defer { foot.enabled = false }
        foot.state = .listening
        foot.hide(until: start.addingTimeInterval(3600))
        #expect(foot.painting)
        #expect(foot.target.buttons.map(\.name) == ["Stop dictating"])
        foot.state = .resting
        #expect(!foot.painting)
        foot.state = .notice("Pasted it, which replaced what you'd copied")
        #expect(foot.painting)
        foot.state = .resting
        #expect(!foot.painting)
        #expect(foot.hiddenUntil != nil)
    }
}
