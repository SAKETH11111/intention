// AppKit rather than Foundation: the Command Line Tools cannot load the
// overlay that importing Foundation beside Testing asks for.
import AppKit
@testable import Onboarding
import Testing

/// The watch for macOS's permission alert, with the clock and the looks at
/// the screen scripted. No request is made of macOS, the real window list
/// is never read and no test waits in real time. Each test has its own
/// requests, so nothing carries from one to the next.
@MainActor
@Suite
struct PermissionAlertWatchTests {
    /// A clock whose time moves only when a test says so. A watch that
    /// sleeps on it is parked, and the test wakes parked watches one at a
    /// time, the one due first, so the order they run in comes from their
    /// deadlines and never from how the tasks happen to be scheduled.
    /// Every use is on the main actor: the watch runs there, and so do the
    /// tests.
    private final class ManualClock: Clock, @unchecked Sendable {
        struct Instant: InstantProtocol {
            var offset: Duration
            func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
            func duration(to other: Instant) -> Duration { other.offset - offset }
            static func < (left: Instant, right: Instant) -> Bool { left.offset < right.offset }
        }

        private(set) var now = Instant(offset: .zero)
        let minimumResolution = Duration.zero
        private var parked: [(deadline: Instant, wake: CheckedContinuation<Void, Never>)] = []

        /// The time since the clock was made.
        var time: Duration { now.offset }
        var sleeping: Int { parked.count }
        var nextDeadline: Duration? { parked.map(\.deadline.offset).min() }

        /// Time passes with nobody woken, as while the main thread is held.
        func pass(_ duration: Duration) {
            now = now.advanced(by: duration)
        }

        @MainActor
        func sleep(until deadline: Instant, tolerance: Duration?) async throws {
            await withCheckedContinuation { parked.append((deadline, $0)) }
            // A cancelled sleeper is woken like any other and finds out
            // here.
            try Task.checkCancellation()
        }

        /// Wakes the sleeper due first, the longest parked of those due
        /// together, and moves the time to its deadline. False when nobody
        /// sleeps.
        func wakeNext() -> Bool {
            guard let index = parked.indices.min(by: { parked[$0].deadline < parked[$1].deadline }) else { return false }
            let sleeper = parked.remove(at: index)
            if now < sleeper.deadline { now = sleeper.deadline }
            sleeper.wake.resume()
            return true
        }
    }

    /// A request a test made. Its outcome is nil until it has ended, and
    /// tests read it without waiting, so a request that never ends fails
    /// its test and cannot hang the run.
    @MainActor
    private final class Made {
        var outcome: PermissionAlert.Outcome?
        var task: Task<Void, Never>?
        func cancel() { task?.cancel() }
    }

    /// What a scripted Mac shows at each look, what was asked of it and
    /// which lists were opened, and the means to run requests on it step
    /// by step.
    @MainActor
    private final class Screen {
        let requests: PermissionAlert.Requests
        let clock = ManualClock()
        var asks = 0
        var looks = 0
        var opened: [String] = []
        /// The alert in front, if any, until one scripted by `alert` comes
        /// up. A test can change it between looks.
        var front: CGWindowID?
        /// An alert that is in front from this look on, once asked.
        var alert: (number: CGWindowID, fromLook: Int)?
        /// From this look on nothing is in front, as when the person has
        /// answered the alert.
        var answeredFromLook: Int?
        /// Runs each time macOS is asked.
        var onAsk: (() -> Void)?
        /// How long a list takes to come forward once opened. Nil is at
        /// once. With a delay set and nothing opened, System Settings is
        /// not in front.
        var settingsDelay: Duration?
        /// When the list opened last is in front.
        private var settingsArrives: Duration?
        /// How often setup's scripted adapter began a request.
        var adapterStarts = 0
        /// Whether setup had queued its request, and the adapter had not
        /// begun it, when a test closed setup's window.
        var closedWhileQueued: Bool?
        /// Whether setup's own request, made by a test, has returned.
        var setupReturned = false
        /// Requests made and not yet ended.
        private var active = 0

        /// `settle` is the least time an opened list is given. Most tests
        /// are about something else and give it none. Nil is the app's
        /// own.
        init(settle: Duration? = .zero) {
            requests = settle.map { PermissionAlert.Requests(settle: $0) } ?? PermissionAlert.Requests()
        }

        func look() -> CGWindowID? {
            defer { looks += 1 }
            if let answeredFromLook, looks >= answeredFromLook { return nil }
            if asks > 0, let alert, looks >= alert.fromLook { return alert.number }
            return front
        }

        @discardableResult
        private func watch(_ list: String, blocking: Duration, opens: Bool = true, made: Made? = nil) async -> PermissionAlert.Outcome {
            let outcome = await requests.request({
                self.asks += 1
                self.onAsk?()
                self.clock.pass(blocking)
            }, clock: clock, look: look, open: {
                guard opens else { return false }
                self.opened.append(list)
                self.settingsArrives = self.settingsDelay.map { self.clock.time + $0 }
                return true
            }, arrived: { self.settingsArrives.map { self.clock.time >= $0 } ?? (self.settingsDelay == nil) })
            made?.outcome = outcome
            active -= 1
            return outcome
        }

        /// Makes a request for `list` in a task of its own, which has not
        /// had a turn when this returns.
        func make(_ list: String = "list", blocking: Duration = .zero, opens: Bool = true) -> Made {
            active += 1
            let made = Made()
            made.task = Task { await self.watch(list, blocking: blocking, opens: opens, made: made) }
            return made
        }

        /// Makes a request and lets it run until it sleeps or ends.
        /// `blocking` is how long asking macOS holds the main thread,
        /// during which nothing else runs. With `opens` false its caller
        /// declines to open the list, as when the option was turned off.
        func start(_ list: String = "list", blocking: Duration = .zero, opens: Bool = true) async -> Made {
            let request = make(list, blocking: blocking, opens: opens)
            await settle()
            return request
        }

        /// A request run to its end with nothing else going on. Nil when
        /// it did not end.
        func request(_ list: String = "list") async -> PermissionAlert.Outcome? {
            let request = await start(list)
            await finish()
            return request.outcome
        }

        /// Lets other tasks run until `condition` holds. It gives up after
        /// many turns, so a broken watch fails its test and does not hang.
        func until(_ condition: () -> Bool) async {
            var turns = 0
            while !condition(), turns < 100_000 {
                await Task.yield()
                turns += 1
            }
            if !condition() { Issue.record("gave up waiting for the requests to get this far") }
        }

        /// Returns once every request made is asleep, waiting its turn or
        /// ended, and the wait for an opened list, when there is one, is
        /// asleep too.
        func settle() async {
            await until { self.clock.sleeping + self.requests.queued == self.active + (self.requests.isHolding ? 1 : 0) }
        }

        /// Waits for a task of setup's to end, and says whether it did.
        func ended(_ task: Task<Void, Never>) async -> Bool {
            var done = false
            Task {
                await task.value
                done = true
            }
            await until { done }
            return done
        }

        /// Wakes sleepers in the order they are due until the clock reads
        /// `time`.
        func run(until time: Duration) async {
            var wakes = 0
            while let next = clock.nextDeadline, next <= time, wakes < 1000, clock.wakeNext() {
                await settle()
                wakes += 1
            }
            if clock.time < time { clock.pass(time - clock.time) }
        }

        /// Wakes sleepers in the order they are due until none is left.
        func finish() async {
            var wakes = 0
            while wakes < 1000, clock.wakeNext() {
                await settle()
                wakes += 1
            }
            // A request still waiting its turn with nobody left to pass
            // it on would never end.
            if requests.queued > 0 { Issue.record("a request never got its turn") }
        }

        /// Setup's flow over a scripted adapter that asks through this
        /// screen.
        func setup() -> OnboardingModel {
            let permissions = SetupPermissions(isGranted: { _ in false }, request: { _ in
                self.adapterStarts += 1
                self.active += 1
                _ = await self.watch("accessibility", blocking: .zero)
            })
            let name = "PermissionAlertWatchTests." + UUID().uuidString
            let defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
            return OnboardingModel(client: nil, keys: MemoryDeviceKey(), permissions: permissions,
                                   defaults: defaults)
        }
    }

    @Test func anAlertThatComesUpStopsTheWatchAndLeavesThePageToIt() async {
        let screen = Screen()
        screen.alert = (number: 41, fromLook: 4)
        #expect(await screen.request() == .alertInFront)
        #expect(screen.asks == 1)
        #expect(screen.opened == [])
        // The look before asking, then four after: the fourth saw it,
        // after three waits of a tenth of a second.
        #expect(screen.looks == 5)
        #expect(screen.clock.time == .milliseconds(300))
    }

    @Test func withNoAlertThePageOpensAfterTheWatch() async {
        let screen = Screen()
        #expect(await screen.request() == .noAlert)
        #expect(screen.asks == 1)
        #expect(screen.opened == ["list"])
        #expect(screen.clock.time == .milliseconds(1500))
    }

    @Test func anAlertThatComesUpAtTheLastLookStillCounts() async {
        // Looks 1 to 16 come 0 to 1.5 seconds after asking.
        let screen = Screen()
        screen.alert = (number: 41, fromLook: 16)
        #expect(await screen.request() == .alertInFront)
        #expect(screen.opened == [])
        #expect(screen.clock.time == .milliseconds(1500))
    }

    @Test func anotherAppsAlertAlreadyInFrontDoesNotKeepThePageShut() async {
        let screen = Screen()
        screen.front = 41
        #expect(await screen.request() == .noAlert)
        #expect(screen.opened == ["list"])
    }

    @Test func intentionsAlertComingInFrontOfAnotherAppsIsLeftAlone() async {
        let screen = Screen()
        screen.front = 41
        screen.alert = (number: 57, fromLook: 3)
        #expect(await screen.request() == .alertInFront)
        #expect(screen.opened == [])
    }

    // MARK: Asking again

    @Test func askingAgainWhileTheSameAlertIsInFrontOpensNothing() async {
        let screen = Screen()
        screen.alert = (number: 41, fromLook: 2)
        #expect(await screen.request("screenRecording") == .alertInFront)
        #expect(screen.clock.time == .milliseconds(100))
        // The person has not answered it and presses again. Intention asks
        // macOS again, finds the same alert at its first look and leaves
        // the list shut, with no wait.
        #expect(await screen.request("screenRecording") == .alertInFront)
        #expect(await screen.request("accessibility") == .alertInFront)
        #expect(screen.asks == 3)
        #expect(screen.opened == [])
        #expect(screen.clock.time == .milliseconds(100))
    }

    @Test func anAlertThatGoesWhileMacOSIsAskedAgainLetsTheListOpen() async {
        let screen = Screen()
        screen.alert = (number: 41, fromLook: 2)
        #expect(await screen.request() == .alertInFront)
        // The person answers the alert in the moment Intention asks again,
        // and macOS shows no other.
        screen.onAsk = {
            screen.alert = nil
            screen.front = nil
        }
        #expect(await screen.request("again") == .noAlert)
        #expect(screen.opened == ["again"])
        #expect(screen.clock.time == .milliseconds(1600))
    }

    @Test func onceThatAlertIsGoneAnotherAlreadyInFrontIsSomebodyElses() async {
        let screen = Screen()
        screen.alert = (number: 41, fromLook: 2)
        #expect(await screen.request() == .alertInFront)
        // Answered, and another app's alert is in front at the next press.
        screen.alert = nil
        screen.front = 57
        #expect(await screen.request("again") == .noAlert)
        #expect(screen.opened == ["again"])
        // With nothing in front the list opens too.
        screen.front = nil
        #expect(await screen.request("once more") == .noAlert)
        #expect(screen.opened == ["again", "once more"])
    }

    // MARK: Requests close together

    @Test func aRequestMadeDuringAWatchWaitsItsTurnAndEachOpensItsOwnPage() async {
        // Both permissions were refused before, so macOS shows nothing for
        // either request.
        let screen = Screen()
        let first = await screen.start("accessibility")
        await screen.run(until: .milliseconds(300))
        let second = await screen.start("screenRecording")
        // The second has not asked macOS yet.
        #expect(screen.asks == 1)
        await screen.run(until: .milliseconds(1500))
        #expect(first.outcome == .noAlert)
        #expect(screen.opened == ["accessibility"])
        // Its turn came when the first one's list had opened.
        #expect(screen.asks == 2)
        await screen.run(until: .milliseconds(2900))
        #expect(screen.opened == ["accessibility"])
        await screen.finish()
        #expect(second.outcome == .noAlert)
        #expect(screen.opened == ["accessibility", "screenRecording"])
        #expect(screen.clock.time == .milliseconds(3000))
    }

    @Test func theSecondRequestLeavesTheFirstOnesAlertAlone() async {
        let screen = Screen()
        let first = await screen.start("accessibility")
        // The first request's alert comes up while its watch sleeps, and
        // the second request is made before the first has looked again.
        screen.front = 41
        let second = await screen.start("screenRecording")
        await screen.finish()
        #expect(first.outcome == .alertInFront)
        // At its turn the second finds the alert the first left the list
        // to, and leaves the list to it as well.
        #expect(second.outcome == .alertInFront)
        #expect(screen.asks == 2)
        #expect(screen.opened == [])
        #expect(screen.clock.time == .milliseconds(100))
    }

    @Test func theSecondRequestOpensItsPageWhenTheFirstOnesAlertWasAnswered() async {
        let screen = Screen()
        let first = await screen.start("accessibility")
        screen.front = 41
        let second = await screen.start("screenRecording")
        // Looks 0 to 2 are the first request's: before asking, straight
        // after, and a tenth of a second on, when it sees the alert. The
        // person answers the alert before the second request's turn, and
        // macOS shows nothing for the second.
        screen.answeredFromLook = 3
        await screen.finish()
        #expect(first.outcome == .alertInFront)
        #expect(second.outcome == .noAlert)
        #expect(screen.opened == ["screenRecording"])
        #expect(screen.clock.time == .milliseconds(1600))
    }

    @Test func aLateAlertStillWinsAfterAnEarlierRequestOpenedItsPage() async {
        let screen = Screen()
        let first = await screen.start("accessibility")
        let second = await screen.start("screenRecording")
        // The first watch ends with no alert and opens its page, so System
        // Settings is in front, which reads as no alert in front. The
        // second request then asks.
        await screen.run(until: .milliseconds(1500))
        #expect(first.outcome == .noAlert)
        #expect(screen.opened == ["accessibility"])
        // The second request's alert comes up in front of System Settings.
        screen.front = 57
        await screen.finish()
        #expect(second.outcome == .alertInFront)
        #expect(screen.opened == ["accessibility"])
        #expect(screen.clock.time == .milliseconds(1600))
    }

    @Test func aLaterRequestThatHoldsTheMainThreadStillOpensAfterTheEarlierOne() async {
        let screen = Screen()
        let first = await screen.start("accessibility")
        // Asking for the second holds the main thread for longer than a
        // whole watch. It asks only at its turn, so it cannot get ahead.
        let second = await screen.start("screenRecording", blocking: .milliseconds(1700))
        await screen.finish()
        #expect(first.outcome == .noAlert)
        #expect(second.outcome == .noAlert)
        #expect(screen.opened == ["accessibility", "screenRecording"])
        #expect(screen.clock.time == .milliseconds(3200))
    }

    @Test func theNextRequestAsksOnlyOnceTheOpenedListIsInFront() async {
        // Accessibility was refused before; Screen Recording is asked for
        // the first time, so macOS answers it with an alert.
        let screen = Screen()
        screen.settingsDelay = .milliseconds(700)
        let first = await screen.start("accessibility")
        let second = await screen.start("screenRecording")
        // The first opens its list after its watch, and the list is not
        // in front yet. An alert that came up now would end under it.
        await screen.run(until: .milliseconds(2100))
        #expect(screen.opened == ["accessibility"])
        #expect(screen.asks == 1)
        // With the list in front, the second asks, and its alert comes up
        // over the list.
        await screen.run(until: .milliseconds(2200))
        #expect(first.outcome == .noAlert)
        #expect(screen.asks == 2)
        screen.front = 57
        await screen.finish()
        #expect(second.outcome == .alertInFront)
        #expect(screen.opened == ["accessibility"])
        #expect(screen.clock.time == .milliseconds(2300))
    }

    @Test func aListOpenedWithSystemSettingsAlreadyInFrontStillKeepsTheTurnForASecond() async {
        // System Settings was in front on another page, so it reads as
        // arrived the moment the list is opened. The open brings it
        // forward again a moment later, and the next request must not ask
        // before that.
        // The app's own minimum, one second.
        let screen = Screen(settle: nil)
        let first = await screen.start("accessibility")
        let second = await screen.start("screenRecording")
        await screen.run(until: .milliseconds(2400))
        #expect(first.outcome == .noAlert)
        #expect(screen.opened == ["accessibility"])
        #expect(screen.asks == 1)
        await screen.run(until: .milliseconds(2500))
        #expect(screen.asks == 2)
        await screen.finish()
        #expect(second.outcome == .noAlert)
        #expect(screen.opened == ["accessibility", "screenRecording"])
    }

    @Test func aListThatNeverComesForwardHoldsTheTurnForThreeSeconds() async throws {
        let screen = Screen()
        screen.settingsDelay = .seconds(60)
        let first = await screen.start("accessibility")
        let second = await screen.start("screenRecording")
        await screen.run(until: .milliseconds(4400))
        #expect(screen.asks == 1)
        await screen.run(until: .milliseconds(4500))
        // Required, since a turn never passed on would leave the waits
        // below without an end.
        try #require(screen.asks == 2)
        #expect(first.outcome == .noAlert)
        await screen.finish()
        #expect(second.outcome == .noAlert)
        #expect(screen.opened == ["accessibility", "screenRecording"])
    }

    @Test func aRequestWhoseCallerOpensNothingPassesTheTurnAtOnce() async throws {
        let screen = Screen()
        screen.settingsDelay = .seconds(60)
        // The option was turned off again during the watch.
        let first = await screen.start("screenRecording", opens: false)
        _ = await screen.start("accessibility")
        await screen.run(until: .milliseconds(1500))
        // Required, since a first request still holding the turn would
        // leave the wait below without an end.
        try #require(screen.asks == 2)
        #expect(first.outcome == .noAlert)
        #expect(screen.opened == [])
        await screen.run(until: .milliseconds(3000))
        #expect(screen.opened == ["accessibility"])
    }

    @Test func aRequestCancelledWhileItWaitsItsTurnAsksNothing() async {
        let screen = Screen()
        let first = await screen.start("first")
        let second = await screen.start("second")
        let third = await screen.start("third")
        second.cancel()
        await screen.finish()
        #expect(first.outcome == .noAlert)
        #expect(second.outcome == .cancelled)
        #expect(third.outcome == .noAlert)
        #expect(screen.asks == 2)
        #expect(screen.opened == ["first", "third"])
        #expect(screen.clock.time == .milliseconds(3000))
    }

    // MARK: Whoever asked has left

    @Test func aCancelledWatchOpensNothing() async {
        let screen = Screen()
        let request = await screen.start()
        request.cancel()
        await screen.finish()
        #expect(request.outcome == .cancelled)
        #expect(screen.asks == 1)
        #expect(screen.opened == [])
        #expect(screen.clock.time == .milliseconds(100))
    }

    @Test func aRequestCancelledBeforeItBeginsAsksNothing() async {
        let screen = Screen()
        let request = screen.make()
        // Cancelled before the task has had a turn.
        request.cancel()
        await screen.settle()
        #expect(request.outcome == .cancelled)
        #expect(screen.asks == 0)
        #expect(screen.looks == 0)
        #expect(screen.opened == [])
    }

    @Test func closingSetupWhileItsRequestIsWatchedOpensNothing() async {
        // Accessibility was refused before, so no alert comes up and the
        // list would open when the watch ends.
        let screen = Screen()
        let model = screen.setup()
        Task {
            await model.request(.accessibility)
            screen.setupReturned = true
        }
        await screen.until { screen.adapterStarts == 1 }
        await screen.settle()
        model.windowClosed()
        await screen.finish()
        await screen.until { screen.setupReturned }
        #expect(screen.setupReturned)
        #expect(screen.adapterStarts == 1)
        #expect(screen.asks == 1)
        #expect(screen.opened == [])
        // The request ended at its first wake after the close, not when
        // its watch would have.
        #expect(screen.clock.time == .milliseconds(100))
    }

    @Test func closingSetupAfterItsListOpenedStillKeepsTheTurnForTheList() async {
        // Accessibility was refused before, so setup's request opens the
        // list after its watch. The list takes 0.7 seconds to come
        // forward, and another request waits its turn meanwhile.
        let screen = Screen()
        screen.settingsDelay = .milliseconds(700)
        let model = screen.setup()
        Task {
            await model.request(.accessibility)
            screen.setupReturned = true
        }
        await screen.until { screen.adapterStarts == 1 }
        await screen.settle()
        let second = await screen.start("screenRecording")
        await screen.run(until: .milliseconds(1500))
        #expect(screen.opened == ["accessibility"])
        // Setup's window closes while its list is on the way. The list
        // cannot be taken back, so the turn is still kept for it.
        await screen.run(until: .milliseconds(1600))
        model.windowClosed()
        await screen.run(until: .milliseconds(2100))
        #expect(screen.asks == 1)
        await screen.run(until: .milliseconds(2200))
        #expect(screen.asks == 2)
        await screen.finish()
        #expect(second.outcome == .noAlert)
        #expect(screen.opened == ["accessibility", "screenRecording"])
    }

    @Test func closingSetupStraightAfterThePressAsksNothing() async {
        let screen = Screen()
        let model = screen.setup()
        // The button's press returns before its request has had a turn,
        // and the window closes in that gap.
        let press = model.allow(.accessibility)
        model.windowClosed()
        Task {
            await press.value
            screen.setupReturned = true
        }
        // A request that began all the same is run to its end, so that it
        // shows in what was asked and opened.
        await screen.until { screen.setupReturned || screen.clock.sleeping > 0 }
        await screen.finish()
        await screen.until { screen.setupReturned }
        #expect(screen.setupReturned)
        #expect(!model.asked.contains(.accessibility))
        #expect(screen.adapterStarts == 0)
        #expect(screen.asks == 0)
        #expect(screen.opened == [])
    }

    @Test func aPressWithTheWindowLeftOpenAsks() async {
        let screen = Screen()
        let model = screen.setup()
        let press = model.allow(.accessibility)
        await screen.until { screen.adapterStarts == 1 }
        await screen.settle()
        await screen.finish()
        #expect(await screen.ended(press))
        #expect(model.asked.contains(.accessibility))
        #expect(screen.asks == 1)
        #expect(screen.opened == ["accessibility"])
    }

    @Test func closingSetupBeforeItsRequestBeginsAsksNothing() async {
        let screen = Screen()
        let model = screen.setup()
        // The press is queued and then the close. So setup takes the press
        // and queues its request behind the close, and the window closes
        // before that request has had a turn.
        Task {
            await model.request(.accessibility)
            screen.setupReturned = true
        }
        Task {
            screen.closedWhileQueued = model.asked.contains(.accessibility) && screen.adapterStarts == 0
            model.windowClosed()
        }
        // A request that began all the same is run to its end, so that it
        // shows in what was asked and opened.
        await screen.until { screen.setupReturned || screen.clock.sleeping > 0 }
        await screen.finish()
        await screen.until { screen.setupReturned }
        #expect(screen.setupReturned)
        #expect(screen.closedWhileQueued == true)
        #expect(screen.adapterStarts == 0)
        #expect(screen.asks == 0)
        #expect(screen.opened == [])
    }
}
