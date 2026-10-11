import AppKit
@testable import Dictation
import Testing

/// A clock and a backend for `SpeechGrants`, scripted.
private final class Backend: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    private var answers: [Result<AlphaClient.SpeechGrant, Error>]
    private(set) var asked: [String] = []
    var delay: Duration = .zero
    var beforeAnswer: (@Sendable () async -> Void)?

    init(_ answers: [Result<AlphaClient.SpeechGrant, Error>]) {
        self.answers = answers
    }

    var now: ContinuousClock.Instant { lock.withLock { instant } }

    func advance(_ by: Duration) {
        lock.withLock { instant += by }
    }

    func fetch(_ key: String) async throws -> AlphaClient.SpeechGrant {
        let answer = lock.withLock {
            asked.append(key)
            return answers.count > 1 ? answers.removeFirst() : answers[0]
        }
        if let beforeAnswer { await beforeAnswer() }
        if delay > .zero { try? await Task.sleep(for: delay) }
        return try answer.get()
    }
}

/// The device key setup holds, and the keys the backend refused.
@MainActor
private final class Account {
    var key: String? = "device-key-one"
    var refused: [String] = []
}

@MainActor
@Suite struct SpeechGrantsTests {
    private func grants(_ backend: Backend, _ account: Account) -> SpeechGrants {
        SpeechGrants(fetch: { try await backend.fetch($0) }, key: { account.key },
                     keyRefused: { account.refused.append($0) }, now: { backend.now })
    }

    private func issued(_ grant: String, lasting seconds: Int = 300) -> Result<AlphaClient.SpeechGrant, Error> {
        .success(AlphaClient.SpeechGrant(grant: grant, expiresIn: seconds))
    }

    @Test func aGrantIsReusedUntilAMinuteBeforeItExpires() async throws {
        let backend = Backend([issued("first"), issued("second")])
        let speech = grants(backend, Account())
        #expect(try await speech.grant() == "first")
        backend.advance(.seconds(239))
        #expect(try await speech.grant() == "first")
        backend.advance(.seconds(1))
        #expect(try await speech.grant() == "second")
        #expect(backend.asked == ["device-key-one", "device-key-one"])
    }

    @Test func withoutAKeyNothingIsAsked() async {
        let backend = Backend([issued("first")])
        let account = Account()
        account.key = nil
        await #expect(throws: DictationStreamError.signedOut) { try await grants(backend, account).grant() }
        #expect(backend.asked.isEmpty)
    }

    @Test func anotherAccountsKeyNeverGetsTheEarlierGrant() async throws {
        let backend = Backend([issued("first"), issued("second")])
        let account = Account()
        let speech = grants(backend, account)
        #expect(try await speech.grant() == "first")
        account.key = "device-key-two"
        #expect(try await speech.grant() == "second")
        #expect(backend.asked == ["device-key-one", "device-key-two"])
    }

    @Test func aRefusedKeySignsThisMacOut() async {
        let backend = Backend([.failure(AlphaClient.Failure.rejected(401))])
        let account = Account()
        await #expect(throws: DictationStreamError.signedOut) { try await grants(backend, account).grant() }
        #expect(account.refused == ["device-key-one"])
    }

    @Test func otherFailuresAreNamedAndSignNobodyOut() async {
        let account = Account()
        let failures: [(Error, DictationStreamError)] = [
            (AlphaClient.Failure.tooManyRequests(retryAfter: 60), .limited),
            (AlphaClient.Failure.rejected(503), .unreachable),
            (URLError(.notConnectedToInternet), .unreachable),
            (AlphaClient.Failure.invalidResponse, .unreachable),
        ]
        for (failure, name) in failures {
            await #expect(throws: name) { try await grants(Backend([.failure(failure)]), account).grant() }
        }
        #expect(account.refused.isEmpty)
    }

    @Test func aGrantTheEndpointRefusedIsNotOfferedAgain() async throws {
        let backend = Backend([issued("first"), issued("second")])
        let speech = grants(backend, Account())
        let first = try await speech.grant()
        await speech.refused("an-older-grant")
        #expect(try await speech.grant() == first)
        await speech.refused(first)
        #expect(try await speech.grant() == "second")
    }

    @Test func aResetDropsTheGrantAndOneStillOnItsWay() async throws {
        let backend = Backend([issued("first"), issued("late"), issued("third")])
        let speech = grants(backend, Account())
        #expect(try await speech.grant() == "first")
        await speech.reset()
        let requested = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        backend.beforeAnswer = {
            requested.continuation.yield(())
            for await _ in release.stream {}
        }
        let late = Task { try await speech.grant() }
        // Reset while the request is pending, regardless of executor load.
        var requests = requested.stream.makeAsyncIterator()
        await requests.next()
        await speech.reset()
        release.continuation.finish()
        await #expect(throws: DictationStreamError.signedOut) { try await late.value }
        backend.beforeAnswer = nil
        #expect(try await speech.grant() == "third")
    }

    @Test func callersAtOnceShareOneRequest() async throws {
        let backend = Backend([issued("first"), issued("second")])
        backend.delay = .milliseconds(100)
        let speech = grants(backend, Account())
        async let one = speech.grant()
        async let two = speech.grant()
        let both = try await [one, two]
        #expect(both == ["first", "first"])
        #expect(backend.asked.count == 1)
    }
}
