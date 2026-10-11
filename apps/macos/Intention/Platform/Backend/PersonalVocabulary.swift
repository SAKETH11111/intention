import Foundation

struct PersonalWords: Sendable, Equatable {
    var names: [String] = []
    var terms: [String] = []
    var expiresAt: ContinuousClock.Instant?
    static let empty = PersonalWords()
}

/// Every speech connection asks again. A previous release or retry cannot
/// authorize terms after their source has changed or permission was withdrawn.
protocol DictationVocabulary: Sendable {
    func words(register: String, before: String?) async -> PersonalWords
    func reset() async
}

struct EmptyVocabulary: DictationVocabulary {
    func words(register: String, before: String?) async -> PersonalWords { .empty }
    func reset() async {}
}

/// No disk cache and no vocabulary reuse, including on retries. The request
/// overlaps recording and waits at most 200 ms; failure keeps dictation usable.
actor PersonalVocabulary: DictationVocabulary {
    private let fetch: @Sendable (String, String, String?) async throws -> AlphaClient.VocabularyReply
    private let key: @Sendable @MainActor () -> String?
    private let keyRefused: @Sendable @MainActor (String) -> Void
    private let now: @Sendable () -> ContinuousClock.Instant
    /// Waits out `budget`, throwing once cancelled. The app sleeps on the
    /// continuous clock; the dictation checks end the wait themselves.
    private let wait: @Sendable (Duration) async throws -> Void
    private let budget: Duration
    private var generation = 0
    private var pending: [UUID: (Task<Void, Never>, AsyncStream<Result<AlphaClient.VocabularyReply, Error>>.Continuation)] = [:]

    init(client: AlphaClient, key: @escaping @Sendable @MainActor () -> String?,
         keyRefused: @escaping @Sendable @MainActor (String) -> Void) {
        self.init(fetch: { try await client.vocabulary(deviceKey: $0, register: $1, before: $2) },
                  key: key, keyRefused: keyRefused)
    }

    init(fetch: @escaping @Sendable (String, String, String?) async throws -> AlphaClient.VocabularyReply,
         key: @escaping @Sendable @MainActor () -> String?,
         keyRefused: @escaping @Sendable @MainActor (String) -> Void,
         budget: Duration = .milliseconds(200), now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
         wait: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.fetch = fetch
        self.key = key
        self.keyRefused = keyRefused
        self.budget = budget
        self.now = now
        self.wait = wait
    }

    func words(register: String, before: String?) async -> PersonalWords {
        guard let key = await key(), !Task.isCancelled else { return .empty }
        let generation = generation, asked = now(), id = UUID()
        let (results, continuation) = AsyncStream<Result<AlphaClient.VocabularyReply, Error>>.makeStream()
        let fetch = fetch
        let request = Task {
            do { continuation.yield(.success(try await fetch(key, register, before))) }
            catch { continuation.yield(.failure(error)) }
            continuation.finish()
        }
        pending[id] = (request, continuation)
        let wait = wait
        let timer = Task {
            do { try await wait(budget) } catch { return }
            continuation.finish()
        }
        defer {
            request.cancel()
            timer.cancel()
            continuation.finish()
            pending[id] = nil
        }
        let result = await withTaskCancellationHandler {
            var iterator = results.makeAsyncIterator()
            return await iterator.next()
        } onCancel: {
            request.cancel()
            continuation.finish()
        }
        let current = await self.key()
        guard generation == self.generation, current == key, !Task.isCancelled, now() < asked + budget else { return .empty }
        switch result {
        case let .success(reply):
            guard reply.isValid, now() < asked + .seconds(reply.expiresIn) else { return .empty }
            guard !reply.names.isEmpty || !reply.terms.isEmpty else { return .empty }
            return PersonalWords(names: reply.names, terms: reply.terms, expiresAt: asked + .seconds(reply.expiresIn))
        case .failure(AlphaClient.Failure.rejected(401)):
            await keyRefused(key)
            return .empty
        default: return .empty
        }
    }

    func reset() {
        generation += 1
        for (request, continuation) in pending.values {
            request.cancel()
            continuation.finish()
        }
        pending = [:]
    }
}
