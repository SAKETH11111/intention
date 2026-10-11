import Foundation

/// Tells the person once, for each mail connection, that Intention has read
/// their mail, so they know emails sound like them from then on. Nothing
/// else in Intention says so after setup, and an import can run for hours.
///
/// A connection seen not ready is remembered, and the notification goes
/// the first time that connection is then seen ready. One seen ready the
/// first time, such as a mailbox that was ready before this build, is
/// remembered as told and never announced, and neither is a connection
/// that goes back to not ready and returns. While a remembered connection's
/// import is still running, the mailbox list is read again after each
/// pause, so the notification comes with setup and Settings closed too.
/// Reading continues after backfill while examples are being prepared. A
/// mailbox with little sent mail may never be ready; the minute cadence
/// also notices new sent mail making it ready later.
@MainActor
final class VoiceReady {
    static let message = "Intention has read your mail. Emails sound like you now."

    /// The one place that decides a mailbox's voice is ready: only the
    /// server's own `voice_ready`, never an import being up to date. An
    /// older server that sends no answer is not ready.
    nonisolated static func isReady(_ connection: AlphaClient.MailConnection) -> Bool {
        connection.voiceReady == true
    }

    /// How macOS is asked: permission to notify, which macOS asks the
    /// person about once and answers by itself after that, the
    /// notification itself, and dropping one still waiting for permission.
    struct Notifier {
        let ask: @MainActor () -> Void
        let post: @MainActor (String) -> Void
        var cancel: @MainActor () -> Void = {}

        static let none = Notifier(ask: {}, post: { _ in })
    }

    private let notifier: Notifier
    private let defaults: UserDefaults
    /// Reads the mailbox list; a list it gets comes back through `observe`,
    /// and a read that fails calls nothing.
    private let read: @MainActor () async -> Void
    /// The wait between reads while a mailbox is coming in. It returns at
    /// once when the task is cancelled.
    private let pause: @Sendable () async -> Void
    /// Whether a background read may ask macOS for permission: only once
    /// setup has finished, which asks itself as it ends, so the question
    /// never arrives at launch or before its reason is on screen.
    private let mayAsk: @MainActor () -> Bool
    private var following: Task<Void, Never>?
    /// Whether permission has been asked since launch. macOS shows its
    /// question only while the person has not answered, so asking once a
    /// launch, when a mailbox is importing, costs nothing after that.
    private var asked = false
    /// Whether the last list seen has a remembered connection whose import
    /// still runs, so the list is worth reading again.
    private(set) var isWaiting = false

    /// When each mailbox was first seen imported and not yet ready, this
    /// launch, and how long it is followed after that.
    private var upToDateSince: [String: Date] = [:]
    static let afterImport: TimeInterval = 30 * 60

    private static let waitingKey = "voiceReadyWaiting"
    private static let toldKey = "voiceReadyTold"

    init(notifier: Notifier, defaults: UserDefaults = .standard, read: @escaping @MainActor () async -> Void,
         pause: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(60)) },
         mayAsk: @escaping @MainActor () -> Bool = { true }) {
        self.notifier = notifier
        self.defaults = defaults
        self.read = read
        self.pause = pause
        self.mayAsk = mayAsk
    }

    /// One look at the list, as at launch or when an account signs in.
    /// With a connection remembered from an earlier launch, the list is
    /// read again after each pause until one read succeeds, so a launch
    /// while offline still notices the voice turning ready.
    func check() {
        Task { await read() }
        if !ids(Self.waitingKey).isEmpty { follow() }
    }

    /// The account changed or signed out: a notification still waiting for
    /// permission belongs to the earlier account and is dropped, and its
    /// mailboxes are no longer read.
    func accountChanged() {
        notifier.cancel()
        observe([])
    }

    /// Every mailbox list Intention reads, from setup, Settings or this.
    func observe(_ connections: [AlphaClient.MailConnection]) {
        var waiting = ids(Self.waitingKey)
        var told = ids(Self.toldKey)
        var ready = false
        for connection in connections {
            let id = connection.id.uuidString
            guard !told.contains(id) else { continue }
            if Self.isReady(connection) {
                told.insert(id)
                if waiting.remove(id) != nil { ready = true }
            } else {
                waiting.insert(id)
            }
        }
        defaults.set(Array(waiting), forKey: Self.waitingKey)
        defaults.set(Array(told), forKey: Self.toldKey)
        // Followed while a mailbox's import runs, an announced one's too, so
        // the progress shown elsewhere keeps moving after a reconnect; and,
        // for one not yet announced, for a while after its import is up to
        // date, as the server prepares its examples. After that, launches,
        // setup and Settings read the list. Another mailbox's readiness must
        // not prevent this one's notification.
        let now = Date()
        isWaiting = connections.contains { connection in
            let id = connection.id.uuidString
            guard !Self.isReady(connection), !OnboardingModel.standing(of: connection).isBroken else { return false }
            if Self.isImporting(connection) {
                upToDateSince[id] = nil
                return true
            }
            guard waiting.contains(id) else { return false }
            let since = upToDateSince[id] ?? now
            upToDateSince[id] = since
            return now.timeIntervalSince(since) < Self.afterImport
        }
        // Asked when mail is coming in, once setup has finished; setup asks
        // as it ends, with its reason on the page.
        if isWaiting, mayAsk() { askPermission() }
        // Two mailboxes finishing together say it once.
        if ready {
            AppLog.mail("voice.ready")
            notifier.post(Self.message)
        }
        if isWaiting { follow() }
    }

    /// Setup promises a notification even when the mailbox was first seen
    /// ready or stopped. Asking here is independent of the import state.
    func setupFinished(connections: [AlphaClient.MailConnection]) {
        if !connections.isEmpty { askPermission() }
    }

    private func askPermission() {
        guard !asked else { return }
        asked = true
        notifier.ask()
    }

    private func follow() {
        isWaiting = true
        guard following == nil else { return }
        following = Task { [weak self] in
            while await self?.next() == true {}
        }
    }

    /// Mail is coming in, or will once a retry the server runs by itself
    /// succeeds: not up to date, and nothing the person has to fix.
    nonisolated static func isImporting(_ connection: AlphaClient.MailConnection) -> Bool {
        let standing = OnboardingModel.standing(of: connection)
        return standing != .upToDate && !standing.isBroken
    }

    /// One pause and one read, while there is still something to wait for.
    private func next() async -> Bool {
        guard isWaiting, !Task.isCancelled else {
            following = nil
            return false
        }
        await pause()
        // A list read during the pause may have ended the wait.
        guard isWaiting, !Task.isCancelled else {
            following = nil
            return false
        }
        await read()
        return true
    }

    private func ids(_ key: String) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }
}
