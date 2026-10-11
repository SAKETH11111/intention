import AuthenticationServices
@testable import Onboarding
import Testing

/// AuthenticationServices ends a consent session on its own XPC queue, not
/// the main thread: the October 6, 2026 crash ran the handler on
/// com.apple.NSXPCConnection.m-user.com.apple.SafariLaunchAgent. These tests
/// end a real session, never started, the same way: from a background queue,
/// through the method the crash report shows the system calling. A handler
/// isolated to the main actor traps there and takes the test run with it.
@MainActor
struct NativeMailSessionTests {
    nonisolated static let ending = NSSelectorFromString("_endSessionWithCallbackURL:error:")
    static let consent = URL(string: "https://accounts.google.com/o/oauth2/v2/auth?state=\(String(repeating: "s", count: 32))")!

    @Test func aCallbackFromABackgroundQueueReachesTheAttempt() async throws {
        let received = Received()
        let session = MailAuthentication.nativeSession(url: Self.consent) { received.add($0) }
        try #require(session.responds(to: Self.ending), "AuthenticationServices ends sessions some other way now; find it before trusting this test")
        let callback = URL(string: "intention-mail://oauth/gmail?state=\(String(repeating: "s", count: 32))&code=synthetic")!
        #expect(await Self.end(session, callback: callback, error: nil) == false)
        #expect(received.urls == [callback])
    }

    @Test func aSessionThatEndsWithoutACallbackReportsNone() async throws {
        let received = Received()
        let session = MailAuthentication.nativeSession(url: Self.consent) { received.add($0) }
        try #require(session.responds(to: Self.ending))
        let cancelled = NSError(domain: ASWebAuthenticationSessionError.errorDomain,
                                code: ASWebAuthenticationSessionError.canceledLogin.rawValue)
        #expect(await Self.end(session, callback: nil, error: cancelled) == false)
        #expect(received.urls == [nil])
    }

    /// The person's default browser opens with the accounts it is already
    /// signed in to, so they are not asked to sign in to Google again.
    @Test func theSessionUsesTheBrowsersSignedInAccounts() {
        let session = MailAuthentication.nativeSession(url: Self.consent) { _ in }
        #expect(!session.prefersEphemeralWebBrowserSession)
    }

    /// Ends `session` on a background queue and returns whether that queue
    /// was the main thread.
    private static func end(_ session: ASWebAuthenticationSession, callback: URL?, error: NSError?) async -> Bool {
        let ended = Unchecked(value: session)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let onMain = Thread.isMainThread
                _ = ended.value.perform(ending, with: callback, with: error)
                continuation.resume(returning: onMain)
            }
        }
    }

    /// The session is used on one queue at a time: built here, ended there.
    private struct Unchecked: @unchecked Sendable { let value: ASWebAuthenticationSession }

    private final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [URL?] = []
        var urls: [URL?] { lock.withLock { all } }
        func add(_ url: URL?) { lock.withLock { all.append(url) } }
    }
}
