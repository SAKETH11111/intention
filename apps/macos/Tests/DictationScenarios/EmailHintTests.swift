import Foundation
@testable import Dictation
import Testing

/// The hint beside an email body: its rules (`EmailHint`) and when it
/// shows (`EmailHints`), with the preferences and the key scripted.
@MainActor
@Suite struct EmailHintTests {
    /// The preferences the app keeps, in memory.
    private final class Store {
        var shown = 0
        var firstEmailWritten = false
        var canWriteEmails = true
        var key = "fn"
        var quiet = true
        var said: [String?] = []
        var saidOnMain: [Bool] = []
    }

    /// The coach over `store`, with each showing's pause held until a step.
    private func hints(_ store: Store) -> (EmailHints, AsyncStream<Void>.Continuation) {
        let hints = EmailHints(shown: { store.shown }, countShown: { store.shown += 1 },
                               firstEmailWritten: { store.firstEmailWritten },
                               canWriteEmails: { store.canWriteEmails }, keyName: { store.key })
        hints.say = { words in
            store.said.append(words)
            store.saidOnMain.append(Thread.isMainThread)
        }
        hints.quiet = { store.quiet }
        let (steps, step) = AsyncStream<Void>.makeStream()
        hints.pause = { for await _ in steps { return } }
        return (hints, step)
    }

    private func until(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }

    @Test func theHintIsWantedUntilItsThirdShowingOrTheFirstEmail() {
        #expect(EmailHint.wanted(shown: 0, firstEmailWritten: false, canWriteEmails: true))
        #expect(EmailHint.wanted(shown: 2, firstEmailWritten: false, canWriteEmails: true))
        #expect(!EmailHint.wanted(shown: 3, firstEmailWritten: false, canWriteEmails: true))
        #expect(!EmailHint.wanted(shown: 7, firstEmailWritten: false, canWriteEmails: true))
        #expect(!EmailHint.wanted(shown: 0, firstEmailWritten: true, canWriteEmails: true))
        // With "Write emails for me" off, or dictation unable to begin, a
        // dictation into the body would type the words, so it says nothing.
        #expect(!EmailHint.wanted(shown: 0, firstEmailWritten: false, canWriteEmails: false))
        // That pauses it; only the third showing or the first email retire it.
        #expect(!EmailHint.retired(shown: 0, firstEmailWritten: false))
        #expect(!EmailHint.retired(shown: 2, firstEmailWritten: false))
        #expect(EmailHint.retired(shown: 3, firstEmailWritten: false))
        #expect(EmailHint.retired(shown: 0, firstEmailWritten: true))
        #expect(EmailHint.limit == 3)
        #expect(EmailHint.duration == .seconds(4))
    }

    @Test func theWordsNameTheKeyAsSetupPrintsIt() {
        #expect(EmailHint.words(key: FirstDictation.keycap(.function)) == "Hold fn and say your reply")
        #expect(EmailHint.words(key: FirstDictation.keycap(.rightOption)) == "Hold right option and say your reply")
        #expect(EmailHint.words(key: FirstDictation.keycap(.controlOption)) == "Hold Control + Option and say your reply")
    }

    @Test func aBodyShowsTheHintForItsPauseAndCountsIt() async {
        let store = Store()
        let (hints, step) = hints(store)
        hints.focusChanged(emailBody: false)
        #expect(store.said.isEmpty)
        #expect(store.shown == 0)
        hints.focusChanged(emailBody: true)
        #expect(store.said == ["Hold fn and say your reply"])
        #expect(hints.words == "Hold fn and say your reply")
        #expect(store.shown == 1)
        // Told again while it shows, as when a page refocuses the body, it
        // neither shows twice nor counts twice.
        hints.focusChanged(emailBody: true)
        #expect(store.said.count == 1)
        #expect(store.shown == 1)
        step.yield()
        await until { store.said == ["Hold fn and say your reply", nil] }
        #expect(hints.words == nil)
        #expect(store.shown == 1)
    }

    @Test func theHintRetiresAfterItsThirdShowing() async {
        let store = Store()
        store.key = "Control + Option"
        let (hints, step) = hints(store)
        for _ in 0..<3 {
            hints.focusChanged(emailBody: true)
            step.yield()
            await until { hints.words == nil }
        }
        #expect(store.shown == 3)
        #expect(!hints.wanted)
        #expect(hints.retired)
        hints.focusChanged(emailBody: true)
        #expect(store.shown == 3)
        #expect(store.said.compactMap { $0 } == Array(repeating: "Hold Control + Option and say your reply", count: 3))
    }

    @Test func theHintRetiresOnceTheFirstEmailIsWritten() {
        let store = Store()
        store.firstEmailWritten = true
        let (hints, _) = hints(store)
        #expect(!hints.wanted)
        #expect(hints.retired)
        hints.focusChanged(emailBody: true)
        #expect(store.said.isEmpty)
        #expect(store.shown == 0)
    }

    @Test func beforeSignInOrWithTheSwitchOffTheHintWaitsWithoutRetiring() {
        let store = Store()
        store.canWriteEmails = false
        let (hints, _) = hints(store)
        #expect(!hints.wanted)
        #expect(!hints.retired)
        hints.focusChanged(emailBody: true)
        #expect(store.said.isEmpty)
        #expect(store.shown == 0)
        // Signed in, or the switch back on: the next body shows it.
        store.canWriteEmails = true
        #expect(hints.wanted)
        hints.focusChanged(emailBody: true)
        #expect(store.shown == 1)
    }

    @Test func leavingTheBodyOrStartingADictationTakesTheWordsAway() async {
        let store = Store()
        let (hints, _) = hints(store)
        hints.focusChanged(emailBody: true)
        hints.focusChanged(emailBody: false)
        #expect(store.said == ["Hold fn and say your reply", nil])
        hints.focusChanged(emailBody: true)
        hints.dictationStarted()
        #expect(store.said == ["Hold fn and say your reply", nil, "Hold fn and say your reply", nil])
        #expect(store.shown == 2)
        // Nothing showing: nothing to take away.
        hints.dictationStarted()
        #expect(store.said.count == 4)
    }

    @Test func theHintWaitsWhileAnythingElseIsSaidAndIsNotCounted() {
        let store = Store()
        store.quiet = false
        let (hints, _) = hints(store)
        hints.focusChanged(emailBody: true)
        #expect(store.said.isEmpty)
        #expect(store.shown == 0)
        store.quiet = true
        hints.focusChanged(emailBody: true)
        #expect(store.shown == 1)
    }

    @Test func aHintThatWaitedShowsByItselfOnceTheIndicatorIsQuiet() async {
        let store = Store()
        store.quiet = false
        let (hints, _) = hints(store)
        let (looks, look) = AsyncStream<Void>.makeStream()
        hints.retryPause = { for await _ in looks { return } }
        // The body takes focus while a notice is up. The watch reports a
        // field once, so the hint looks again on its own.
        hints.focusChanged(emailBody: true)
        #expect(store.said.isEmpty)
        look.yield()
        await until { store.said.count == 0 && store.shown == 0 }
        #expect(store.shown == 0)
        store.quiet = true
        look.yield()
        await until { store.shown == 1 }
        #expect(store.said == ["Hold fn and say your reply"])
        #expect(hints.words != nil)
        // Focus leaving while a hint waits ends the wait without a showing.
        let second = Store()
        second.quiet = false
        let (waiting, _) = self.hints(second)
        waiting.retryPause = { for await _ in looks { return } }
        waiting.focusChanged(emailBody: true)
        waiting.focusChanged(emailBody: false)
        second.quiet = true
        look.yield()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(second.shown == 0)
        #expect(second.said.isEmpty)
    }

    /// `EmailBodyWatch` reports from its own Accessibility thread. The
    /// reporter reaches the main actor itself, so a report from a
    /// background queue shows the hint on the main thread and nothing
    /// main-actor runs off it, which would trap at runtime.
    @Test func aReportFromABackgroundQueueShowsTheHintOnTheMainThread() async {
        let store = Store()
        let (hints, _) = hints(store)
        let report = EmailHints.reporter(to: hints)
        let sentOffMain = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                report(true)
                done.resume(returning: !Thread.isMainThread)
            }
        }
        #expect(sentOffMain)
        await until { store.said == ["Hold fn and say your reply"] }
        #expect(store.saidOnMain == [true])
        // And from the main thread, at once.
        report(false)
        #expect(store.said == ["Hold fn and say your reply", nil])
    }
}
