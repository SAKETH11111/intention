@testable import Intention
import Testing

struct CaretReadRequestsTests {
    @Test func inputDuringReadRequiresOneFreshFollowup() {
        var requests = CaretReadRequests()
        let initial = requests.request()
        let oldGeneration = requests.begin()
        let input = requests.request()
        let notification = requests.request()
        let followup = requests.finish(oldGeneration)
        let freshGeneration = requests.begin()
        let redundant = requests.finish(freshGeneration)
        let next = requests.request()
        #expect(initial && !input && !notification && followup && !redundant && next)
        #expect(freshGeneration != oldGeneration)
    }

    @Test func requestsBeforeReadBeginsAreCoalesced() {
        var requests = CaretReadRequests()
        var decisions = [requests.request()]
        for _ in 0..<20 { decisions.append(requests.request()) }
        let redundant = requests.finish(requests.begin())
        let next = requests.request()
        #expect(decisions == [true] + Array(repeating: false, count: 20))
        #expect(!redundant && next)
    }

    /// While the dot is not the chosen indicator: input, the interval and
    /// the focused app's notifications all ask for reads, and none happens.
    @Test func whilePausedNoReadStartsAndAQueuedOneIsSkipped() {
        var requests = CaretReadRequests()
        let queued = requests.request()
        let paused = requests.pause()
        let pausedAgain = requests.pause()
        let refused = (0..<5).map { _ in requests.request() }
        // The read queued before the pause begins, sees the pause and is skipped.
        let skipped = requests.paused
        let followup = requests.finish(requests.begin())
        requests.resume()
        let resumed = requests.request()
        #expect(queued && paused && !pausedAgain && skipped && !followup && resumed)
        #expect(refused == Array(repeating: false, count: 5))
    }

    /// Hiding the caret dot while no read is queued: requests stay refused until the dot returns.
    @Test func anIdlePausedGateRefusesEveryRequestUntilResumed() {
        var requests = CaretReadRequests()
        _ = requests.pause()
        let refused = [requests.request(), requests.request()]
        requests.resume()
        let resumed = requests.request()
        #expect(refused == [false, false] && resumed)
    }

    @Test func aPauseDuringARunningReadLeavesNoReadQueued() {
        var requests = CaretReadRequests()
        _ = requests.request()
        let running = requests.begin()
        // Input arrives during the read, then the caret dot is hidden.
        let input = requests.request()
        _ = requests.pause()
        // The follow-up the input earned is queued, begins paused and is skipped.
        let followup = requests.finish(running)
        let skipped = requests.paused
        let after = requests.finish(requests.begin())
        #expect(!input && followup && skipped && !after)
        requests.resume()
        let next = requests.request()
        #expect(next)
    }

    @Test func fullExecutorDoesNotLatchTheReadGate() {
        var requests = CaretReadRequests()
        let initial = requests.request()
        requests.rejected()
        let retried = requests.request()
        #expect(initial && retried)
    }
}
