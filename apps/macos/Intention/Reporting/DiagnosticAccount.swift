import Foundation

/// Resolves the non-secret account identity before releasing a restored journal.
/// Failed key reads and failed requests preserve the disk buffer, quarantined.
@MainActor
final class DiagnosticAccount {
    enum Credential: Equatable { case key(String), signedOut, unreadable }
    private(set) var accountID: UUID?
    /// Nil immediately while identity is unconfirmed or signed out.
    var identityChanged: (@MainActor (UUID?) -> Void)? {
        didSet { identityChanged?(accountID) }
    }
    private let journal: DiagnosticEvents
    private let read: @MainActor () -> Credential
    private let identify: @Sendable (String) async throws -> UUID
    private let refused: @MainActor (String) -> Void
    private var credential: Credential?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var failures = 0
    private var waitingToRetry = false
    private let retryPause: @Sendable (Int) async throws -> Void

    init(journal: DiagnosticEvents, read: @escaping @MainActor () -> Credential,
         identify: @escaping @Sendable (String) async throws -> UUID,
         refused: @escaping @MainActor (String) -> Void,
         retryPause: @escaping @Sendable (Int) async throws -> Void = { failures in
             try await Task.sleep(for: .seconds(min(60, pow(2, Double(min(failures - 1, 6))))))
         }) {
        self.journal = journal
        self.read = read
        self.identify = identify
        self.refused = refused
        self.retryPause = retryPause
    }

    /// Called at launch, account changes, and before making a report. Returning
    /// the observed key keeps the report bound to the same credential read.
    @discardableResult
    func refresh(retryNow: Bool = false) -> String? {
        let next = read()
        if !retryNow, next == credential, task != nil || journal.accountVerified {
            if case let .key(key) = next { return key }
            return nil
        }
        generation += 1
        let attempt = generation
        task?.cancel()
        task = nil
        let firstRead = credential == nil
        let changed = credential != next
        credential = next
        waitingToRetry = false
        if changed {
            failures = 0
            accountID = nil
            if !firstRead || journal.accountVerified { journal.beginAccountCheck() }
        }
        guard case let .key(key) = next else {
            if next == .signedOut { journal.bind(accountID: nil) }
            if changed { identityChanged?(nil) }
            return nil
        }
        task = Task { [weak self, identify] in
            do {
                let account = try await identify(key)
                guard let self, self.generation == attempt else { return }
                defer { if self.generation == attempt { self.task = nil } }
                guard !Task.isCancelled, self.read() == next else {
                    self.refresh()
                    return
                }
                self.journal.bind(accountID: account)
                self.accountID = account
                self.failures = 0
                self.identityChanged?(account)
            } catch {
                guard let self, self.generation == attempt else { return }
                self.task = nil
                if case AlphaClient.Failure.rejected(401) = error {
                    self.refused(key)
                    return
                }
                self.failures += 1
                self.waitingToRetry = true
                let delay = self.failures, pause = self.retryPause
                self.task = Task { [weak self] in
                    do { try await pause(delay) } catch { return }
                    guard let self, self.generation == attempt else { return }
                    self.refresh(retryNow: true)
                }
            }
        }
        if changed { identityChanged?(nil) }
        return key
    }

    /// A successful alpha request can wake a backoff early. Transport callbacks
    /// are nonisolated and may arrive from URLSession's background queue.
    nonisolated static func serverResponded(_ account: DiagnosticAccount) -> @Sendable () -> Void {
        { [weak account] in
            DispatchQueue.main.async {
                guard let account, account.waitingToRetry else { return }
                account.refresh(retryNow: true)
            }
        }
    }
}
