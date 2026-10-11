import AppKit
import AuthenticationServices

@MainActor
protocol MailConsentSession: AnyObject {
    func start() -> Bool
    func cancel()
}

extension ASWebAuthenticationSession: MailConsentSession {}

@MainActor
protocol MailConnecting: AnyObject {
    func connect(provider: AlphaClient.MailProvider, client: AlphaClient, deviceKey: String,
                 anchor: NSWindow, isCurrent: @escaping @MainActor () -> Bool) async throws -> UUID
    func cancel()
}

/// Onboarding calls this after sign-in and cancels it on logout or any backend,
/// account or device change. No general URL handler can complete mailbox consent.
@MainActor
final class MailAuthentication: NSObject, ASWebAuthenticationPresentationContextProviding, MailConnecting {
    private var attempt: UUID?
    private var session: (any MailConsentSession)?
    private var continuation: CheckedContinuation<URL, any Error>?
    private var timeout: Task<Void, Never>?
    private var anchor: NSWindow?
    typealias SessionFactory = @MainActor (URL, @escaping @Sendable (URL?) -> Void) -> any MailConsentSession
    private let makeSession: SessionFactory?
    private let consentTimeout: Duration

    init(makeSession: SessionFactory? = nil, consentTimeout: Duration = .seconds(120)) {
        self.makeSession = makeSession
        self.consentTimeout = consentTimeout
        super.init()
    }

    func connect(
        provider: AlphaClient.MailProvider, client: AlphaClient,
        deviceKey: String, anchor: NSWindow, isCurrent: @escaping @MainActor () -> Bool = { true }
    ) async throws -> UUID {
        throw AlphaClient.MailFailure.couldNotOpen
    }

    /// A fixed name for why a connection failed: never a message, an
    /// address or a URL.
    nonisolated static func failureName(_ error: any Error) -> String {
        switch error {
        case let failure as AlphaClient.MailFailure:
            switch failure {
            case .invalidConsent: "invalidConsent"
            case .denied: "denied"
            case .cancelled: "cancelled"
            case .couldNotOpen: "couldNotOpen"
            case .timedOut: "timedOut"
            case .busy: "busy"
            }
        case let failure as AlphaClient.Failure:
            switch failure {
            case .insecureEndpoint: "insecureEndpoint"
            case .invalidResponse: "invalidResponse"
            case let .rejected(status): "rejected.\(status)"
            case .tooManyRequests: "tooManyRequests"
            }
        case let failure as URLError: "unreachable.\(failure.code.rawValue)"
        case is CancellationError: "cancelled"
        default: "other"
        }
    }

    private func perform(
        provider: AlphaClient.MailProvider, client: AlphaClient, deviceKey: String, id: UUID, isCurrent: @escaping @MainActor () -> Bool
    ) async throws -> UUID {
        try await withTaskCancellationHandler {
            guard attempt == id, !Task.isCancelled, isCurrent() else { throw AlphaClient.MailFailure.cancelled }
            let flow = try await client.beginMail(provider: provider, deviceKey: deviceKey)
            guard attempt == id, !Task.isCancelled, isCurrent() else { throw AlphaClient.MailFailure.cancelled }
            let callback = try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let returned: @Sendable (URL?) -> Void = { [weak self] url in
                    Task { @MainActor in
                        guard let self, self.attempt == id else { return }
                        self.finish(url: url)
                    }
                }
                let session: any MailConsentSession
                if let makeSession {
                    session = makeSession(flow.authorizationURL, returned)
                } else {
                    let native = Self.nativeSession(url: flow.authorizationURL, returned: returned)
                    native.presentationContextProvider = self
                    session = native
                }
                self.session = session
                timeout = Task { [weak self] in
                    guard let self else { return }
                    do { try await Task.sleep(for: self.consentTimeout) } catch { return }
                    guard self.attempt == id else { return }
                    AppLog.mail("\(provider.rawValue).consent.timedOut")
                    self.fail(.timedOut)
                }
                if session.start() {
                    AppLog.mail("\(provider.rawValue).consent.shown")
                } else {
                    AppLog.mail("\(provider.rawValue).consent.notStarted")
                    fail(.couldNotOpen)
                }
            }
            guard attempt == id, !Task.isCancelled, isCurrent() else { throw AlphaClient.MailFailure.cancelled }
            AppLog.mail("\(provider.rawValue).consent.returned")
            // Validate host, path, provider, state and duplicate parameters before the
            // device credential or provider code reaches the completion endpoint.
            _ = try flow.completionCode(from: callback)
            let connection = try await client.completeMail(flow: flow, callback: callback, deviceKey: deviceKey)
            guard attempt == id, !Task.isCancelled, isCurrent() else { throw AlphaClient.MailFailure.cancelled }
            return connection
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.attempt == id else { return }
                self.cancel()
            }
        }
    }

    /// The system's consent session, which reports its callback to `returned`.
    ///
    /// AuthenticationServices calls the completion handler on its own XPC
    /// queue, not the main thread. A handler written in this main-actor class
    /// would inherit the main actor, and Swift 6 traps when the system calls it
    /// there, so the handler is `@Sendable` and `returned` hops to the main
    /// actor itself.
    ///
    /// The session is not ephemeral. macOS opens the person's default browser
    /// when it supports authentication sessions, Safari otherwise, and a shared
    /// session lets that browser use the Google or Microsoft account it is
    /// already signed in to. The callback still returns only to this session.
    nonisolated static func nativeSession(url: URL, returned: @escaping @Sendable (URL?) -> Void) -> ASWebAuthenticationSession {
        let native = ASWebAuthenticationSession(url: url, callbackURLScheme: "intention-mail") { @Sendable url, _ in returned(url) }
        native.prefersEphemeralWebBrowserSession = false
        return native
    }

    func cancel() {
        let pending = continuation
        continuation = nil
        clear()
        pending?.resume(throwing: AlphaClient.MailFailure.cancelled)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? NSWindow()
    }

    private func finish(url: URL?) {
        guard let pending = continuation else { return }
        continuation = nil
        timeout?.cancel()
        timeout = nil
        session = nil
        if let url { pending.resume(returning: url) }
        else { pending.resume(throwing: AlphaClient.MailFailure.cancelled) }
    }

    private func fail(_ failure: AlphaClient.MailFailure) {
        guard let pending = continuation else { return }
        continuation = nil
        timeout?.cancel()
        timeout = nil
        let failedSession = session
        session = nil
        failedSession?.cancel()
        // Keep the attempt until connect catches this failure. Clearing it
        // here would classify a timeout or start failure as cancellation.
        pending.resume(throwing: failure)
    }

    private func clear() {
        attempt = nil
        timeout?.cancel()
        timeout = nil
        session?.cancel()
        session = nil
        anchor = nil
    }
}
