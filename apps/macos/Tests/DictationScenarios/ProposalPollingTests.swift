import Foundation
@testable import Dictation
import Testing

/// How often the writer polls a pending draft, on a clock the scenario
/// steps, with the writer's own intervals as the app builds it: a reply
/// proposal four times a second, a dictated email once a second, and a
/// poll the server could not answer made again no sooner than a second
/// later, or its `Retry-After` when that is longer.
@MainActor
struct ProposalPollingTests {
    private let thread = "Could you make Thursday at 10?"
    private let draft = "Hi Jane, Thursday at 10 works. Best,"

    /// A Gmail inline reply's untouched body, as a proposal is asked from.
    private var reply: EmailBody {
        EmailBody(bundleIdentifier: "com.google.Chrome", body: "\n", thread: thread, threadID: "FMfcgzQcqxTVrKbF", kind: .reply,
                  inThread: true)
    }

    /// A route whose draft the server finishes at `finished` on `clock`:
    /// a poll before then reads pending, one at or after it complete.
    private func route(finishingAt finished: Duration, on clock: SteppedClock) -> ScriptedRoute {
        let route = ScriptedRoute(text: draft)
        route.onRead = .pending
        route.beforeRead = { [weak route, clock] in
            if clock.now >= finished { route?.onRead = .complete }
        }
        return route
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        try #require(condition())
    }

    /// Waits for calls and their deadline timers to settle, leaving only
    /// the sleep the scenario intends to advance.
    private func sleeping(_ clock: SteppedClock, until time: Duration) async throws {
        try await waitUntil { clock.waits == [time] }
    }

    private func tick(_ clock: SteppedClock, to time: Duration) async throws {
        try await sleeping(clock, until: time)
        clock.advance(to: time)
    }

    @Test func aProposalThatCompletesBetweenTicksIsSeenAtTheNextQuarterSecond() async throws {
        let clock = SteppedClock()
        // The server finishes 1.1 seconds after the request.
        let route = route(finishingAt: .milliseconds(1100), on: clock)
        let writer = EmailWriter(drafts: route, signedIn: true, clock: clock)
        let proposing = Task { await writer.propose(body: reply) }
        defer { proposing.cancel() }
        for time in [250, 500, 750, 1000, 1250] {
            try await tick(clock, to: .milliseconds(time))
        }
        let proposal = try await proposing.value.get()
        #expect(proposal.text == draft)
        // Seen at 1.25 seconds, 150 ms after the server finished, by the
        // fifth poll; a poll a second would have seen it at 2 seconds.
        #expect(clock.now == .milliseconds(1250))
        #expect(route.read.count == 5)
        #expect(route.accepted.isEmpty)
        #expect(route.cancelled.isEmpty)
        #expect(clock.waits.isEmpty)
    }

    @Test func aDictatedEmailIsStillPolledOnceASecond() async throws {
        let clock = SteppedClock()
        let route = route(finishingAt: .milliseconds(1100), on: clock)
        let writer = EmailWriter(drafts: route, signedIn: true, clock: clock)
        let writing = Task { await writer.write(cue: "Say yes", body: EmailBody(bundleIdentifier: "com.apple.mail", body: thread)) }
        defer { writing.cancel() }
        try await tick(clock, to: .seconds(1))
        try await sleeping(clock, until: .seconds(2))
        #expect(route.read.count == 1)
        clock.advance(to: .seconds(2))
        #expect(try await writing.value.get() == draft)
        #expect(clock.now == .seconds(2))
        #expect(route.read.count == 2)
        #expect(route.accepted.count == 1)
    }

    @Test(arguments: [Duration.seconds(1), .milliseconds(20)])
    func aProposalPollTheServerCouldNotAnswerWaitsASecondOrItsRetryAfter(pollInterval: Duration) async throws {
        let clock = SteppedClock()
        let route = ScriptedRoute(text: draft)
        // A 503, two 429s and a lost connection, then the draft.
        route.firstReads = [.fail(.storageUnavailable), .fail(.busy(retryAfter: 2)),
                            .fail(.busy(retryAfter: 30)), .fail(.unreachable)]
        let writer = EmailWriter(drafts: route, signedIn: true, pollInterval: pollInterval, clock: clock)
        let proposing = Task { await writer.propose(body: reply) }
        defer { proposing.cancel() }
        try await tick(clock, to: .milliseconds(250))
        // The 503 waits a whole second, not a quarter.
        try await tick(clock, to: .milliseconds(1250))
        try await sleeping(clock, until: .milliseconds(3250))
        #expect(route.read.count == 2)
        // The 429 waits the two seconds it asked for.
        clock.advance(to: .milliseconds(3250))
        // Retry-After of 30 seconds is capped at five seconds.
        try await tick(clock, to: .milliseconds(8250))
        // An unreachable server also waits at least one second.
        try await tick(clock, to: .milliseconds(9250))
        #expect(try await proposing.value.get().text == draft)
        #expect(route.read.count == 5)
        #expect(route.cancelled.isEmpty)
    }

    @Test(arguments: [false, true])
    func cancellationEndsAProposalDuringItsPollOrRetrySleep(retrying: Bool) async throws {
        let clock = SteppedClock()
        let route = ScriptedRoute(text: draft)
        route.onRead = .fail(.storageUnavailable)
        let writer = EmailWriter(drafts: route, signedIn: true, clock: clock)
        let proposing = Task { await writer.propose(body: reply) }
        defer { proposing.cancel() }
        if retrying {
            try await tick(clock, to: .milliseconds(250))
            try await sleeping(clock, until: .milliseconds(1250))
        } else {
            try await sleeping(clock, until: .milliseconds(250))
        }
        writer.cancelProposal()
        try await tick(clock, to: retrying ? .milliseconds(1250) : .milliseconds(250))
        #expect(await proposing.value == .failure(.withdrawn))
        let id = try #require(route.created.first?.requestID)
        try await waitUntil { route.cancelled == [id] }
        #expect(route.read.count == (retrying ? 1 : 0))
        #expect(route.accepted.isEmpty)
        #expect(clock.waits.isEmpty)
    }

    @Test(arguments: [false, true])
    func theDeadlineEndsAProposalDuringItsPollOrRetrySleep(retrying: Bool) async throws {
        let clock = SteppedClock()
        let route = ScriptedRoute(text: draft)
        route.onRead = retrying ? .fail(.server(503)) : .pending
        let writer = EmailWriter(drafts: route, signedIn: true, requestLimit: .milliseconds(600), clock: clock)
        let proposing = Task { await writer.propose(body: reply) }
        defer { proposing.cancel() }
        try await tick(clock, to: .milliseconds(250))
        if !retrying { try await tick(clock, to: .milliseconds(500)) }
        try await tick(clock, to: .milliseconds(600))
        #expect(await proposing.value == .failure(.timedOut))
        let id = try #require(route.created.first?.requestID)
        try await waitUntil { route.cancelled == [id] }
        #expect(route.read.count == (retrying ? 1 : 2))
        #expect(route.accepted.isEmpty)
        #expect(clock.waits.isEmpty)
    }
}

extension DictationScenarioTests {
    @Test func aRetiredHeldProposalIsRemovedWithoutAnotherWriterRequest() async {
        let route = ScriptedRoute(text: proposalDraft)
        let p = await proposals(nil, route: route, validityInterval: .milliseconds(20))
        defer { p.controller.reset() }
        p.controller.observe(p.observation())
        await until { p.card.isShown }
        route.onRead = .takeBack
        await until { !p.card.isShown }
        #expect(!p.controller.isShown)
        #expect(p.tab == nil)
        #expect(route.created.count == 1)
        #expect(route.accepted.isEmpty)
        #expect(MockField.shared.text == "\n")
    }

    @Test func aTemporaryReceiptFailureKeepsTheCardUntilRetirementIsKnown() async {
        let route = ScriptedRoute(text: proposalDraft)
        let p = await proposals(nil, route: route, validityInterval: .milliseconds(20))
        defer { p.controller.reset() }
        p.controller.observe(p.observation())
        await until { p.card.isShown }
        let reads = route.read.count
        route.onRead = .fail(.storageUnavailable)
        await until { route.read.count >= reads + 2 }
        #expect(p.card.isShown)
        route.onRead = .takeBack
        await until { !p.card.isShown }
        #expect(route.created.count == 1)
    }

    @Test func aRecordingKeepsItsParentUntilItsWordsCanBeRebased() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let p = await proposals(nil, route: route, validityInterval: .milliseconds(20))
        defer { p.controller.reset() }
        p.controller.observe(p.observation())
        await until { p.card.isShown }
        let intention = try #require(p.controller.dictationStarted())
        route.onRead = .takeBack
        try? await Task.sleep(for: .milliseconds(100))
        #expect(p.card.isShown)
        #expect(p.controller.recordingIntention == intention)
        p.controller.dictationEnded()
        await until { !p.card.isShown }
        #expect(route.created.count == 1)
    }

    @Test func aRetirementReadThatFinishesDuringRecordingKeepsItsParent() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let p = await proposals(nil, route: route, validityInterval: .milliseconds(20))
        defer { p.controller.reset() }
        p.controller.observe(p.observation())
        await until { p.card.isShown }
        route.hold(.read)
        var intention: ProposalChangeIntention?
        await route.whileHeld {
            intention = p.controller.dictationStarted()
            route.onRead = .takeBack
        }
        let recording = try #require(intention)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(p.card.isShown)
        #expect(p.controller.recordingIntention == recording)
        p.controller.dictationEnded()
        await until { !p.card.isShown }
        #expect(route.created.count == 1)
    }
}

extension DictationScenarioTests {
    @Test func releasingTheControllerStopsReceiptPolling() async {
        let route = ScriptedRoute(text: proposalDraft)
        weak var controller: ReplyProposalController?
        do {
            let p = await proposals(nil, route: route, validityInterval: .milliseconds(20))
            controller = p.controller
            p.controller.observe(p.observation())
            await until { p.card.isShown }
            let reads = route.read.count
            await until { route.read.count > reads }
        }
        await until { controller == nil }
        #expect(controller == nil)
        let reads = route.read.count
        try? await Task.sleep(for: .milliseconds(100))
        #expect(route.read.count == reads)
    }
}
