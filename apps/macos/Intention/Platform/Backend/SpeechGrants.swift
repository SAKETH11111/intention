import Foundation

/// Speech grants from the alpha backend for the device key signed in now.
///
/// A grant is kept in memory only, with the device key it was fetched for,
/// and used until a minute before it expires; a dictation then asks for a
/// new one while the person is still speaking. A grant fetched for a key
/// that has since changed is never returned. The backend refusing the key
/// (401) signs this Mac out through `keyRefused`, as setup's own requests
/// do. Neither grants nor keys are logged.
actor SpeechGrants: SpeechCredentials {
    /// A grant is renewed when less than this is left, so the endpoint
    /// never receives one about to expire.
    static let margin: Duration = .seconds(60)

    private let fetch: @Sendable (String) async throws -> AlphaClient.SpeechGrant
    private let key: @Sendable @MainActor () -> String?
    private let keyRefused: @Sendable @MainActor (String) -> Void
    private let now: @Sendable () -> ContinuousClock.Instant
    private var cached: (grant: String, key: String, expires: ContinuousClock.Instant)?
    private var fetching: (key: String, task: Task<AlphaClient.SpeechGrant, Error>)?
    /// Changes with every `reset`, so a fetch that finishes after one is
    /// dropped.
    private var generation = 0

    init(client: AlphaClient, key: @escaping @Sendable @MainActor () -> String?,
         keyRefused: @escaping @Sendable @MainActor (String) -> Void) {
        self.init(fetch: { try await client.speechGrant(deviceKey: $0) }, key: key, keyRefused: keyRefused)
    }

    init(fetch: @escaping @Sendable (String) async throws -> AlphaClient.SpeechGrant,
         key: @escaping @Sendable @MainActor () -> String?,
         keyRefused: @escaping @Sendable @MainActor (String) -> Void,
         now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.fetch = fetch
        self.key = key
        self.keyRefused = keyRefused
        self.now = now
    }

    func grant() async throws -> String {
        guard let key = await key() else { throw DictationStreamError.signedOut }
        if let cached, cached.key == key, now() + Self.margin < cached.expires { return cached.grant }
        let generation = generation
        // Counted from before the request, so the grant is thought to
        // expire no later than it does.
        let asked = now()
        let task: Task<AlphaClient.SpeechGrant, Error>
        if let fetching, fetching.key == key {
            task = fetching.task
        } else {
            let fetch = fetch
            task = Task { try await fetch(key) }
            fetching = (key, task)
        }
        let issued: AlphaClient.SpeechGrant
        do {
            issued = try await task.value
        } catch {
            if fetching?.task == task { fetching = nil }
            throw await Self.failure(error, key: key, keyRefused: keyRefused)
        }
        if fetching?.task == task { fetching = nil }
        // Signed out or another account while the request was out.
        guard generation == self.generation, await self.key() == key else { throw DictationStreamError.signedOut }
        cached = (issued.grant, key, asked + .seconds(issued.expiresIn))
        return issued.grant
    }

    func refused(_ grant: String) {
        if cached?.grant == grant { cached = nil }
    }

    func reset() {
        generation += 1
        cached = nil
        fetching?.task.cancel()
        fetching = nil
    }

    private static func failure(_ error: Error, key: String,
                                keyRefused: @Sendable @MainActor (String) -> Void) async -> DictationStreamError {
        switch error {
        case AlphaClient.Failure.rejected(401):
            await keyRefused(key)
            return .signedOut
        case AlphaClient.Failure.tooManyRequests:
            return .limited
        default:
            return .unreachable
        }
    }
}
