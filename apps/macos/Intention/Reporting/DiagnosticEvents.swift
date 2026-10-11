import CryptoKit
import Foundation
import os

/// A bounded private copy of fixed events for a report, kept across relaunches. Recording
/// works without disabled telemetry and never reads another app or the system log store.
final class DiagnosticEvents: Sendable {
    static let shared = DiagnosticEvents(file: defaultFile, requiresAccount: true)
    private static var defaultFile: URL? {
        #if DEBUG
        // Setup's fixture and the renders that use it keep their events in
        // memory, apart from this Mac's own journal.
        if ["--onboarding-fixture", "--onboarding-demo"].contains(where: CommandLine.arguments.contains) { return nil }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "co.intention.mac", isDirectory: true)
            .appendingPathComponent("diagnostic-events.json")
    }
    typealias Name = ClientEventName
    typealias Outcome = ClientEventOutcome
    static let limit = 4096
    struct Event: Codable, Sendable, Equatable {
        let name: Name
        let outcome: Outcome?
        let at: String
    }
    struct Snapshot: Sendable {
        let events: [Event]
        let truncated: Bool
    }
    private struct Entry: Codable, Sendable { let event: Event; let date: Date }
    private struct State: Codable, Sendable {
        var entries: [Entry] = []
        var droppedAt: Date?
        var since: Date?
        var account: String?
        var verified = true
        var pending: [Entry] = []
        var pendingTruncated = false
        var pendingSince: Date?
        // Never restored from disk; only this process can own these anonymous events.
        var anonymousThisLaunch = false
        enum CodingKeys: String, CodingKey { case entries, droppedAt, since, account }
    }
    private let state: OSAllocatedUnfairLock<State>
    private let file: URL?
    private let io = DispatchQueue(label: "co.intention.mac.diagnostic-events", qos: .utility)
    private let sink = OSAllocatedUnfairLock<(@Sendable (Name, Outcome?, Date, UUID?) -> Void)?>(initialState: nil)

    /// The timeline uploader binds its own account scope here. Delivery is
    /// outside the ring lock, so a sink can inspect a snapshot without deadlock.
    func setSink(_ callback: (@Sendable (Name, Outcome?, Date, UUID?) -> Void)?) {
        sink.withLock { $0 = callback }
    }

    init(file: URL? = nil, requiresAccount: Bool = false) {
        self.file = file
        var restored: State
        if let file, let data = try? Data(contentsOf: file), data.count <= 2 * 1024 * 1024,
           let decoded = try? JSONDecoder().decode(State.self, from: data), decoded.entries.count <= Self.limit {
            restored = decoded
        } else {
            // A damaged journal is incomplete evidence, not a claim that no
            // events happened. A missing file is normal on first launch.
            let missing = file.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true
            restored = State(droppedAt: missing ? nil : Date())
        }
        restored.verified = !requiresAccount
        restored.pendingSince = requiresAccount ? Date() : nil
        let count = restored.entries.count
        restored.entries.removeAll { $0.date < Date().addingTimeInterval(-1800) }
        state = OSAllocatedUnfairLock(initialState: restored)
        if restored.entries.count != count { persist(restored) }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    func clear() {
        state.withLock {
            $0 = State(since: Date(), account: $0.account, verified: $0.verified)
            persist($0)
        }
    }

    /// Until identity is confirmed, old disk events are private to their
    /// previous account. Fresh events wait in memory for this identity lookup.
    func beginAccountCheck() {
        state.withLock {
            $0.verified = false
            $0.pending = []
            $0.pendingTruncated = false
            $0.pendingSince = Date()
        }
    }

    var accountVerified: Bool { state.withLock { $0.verified } }

    /// The persisted marker is a hash of the server account UUID, never a
    /// device credential. An old unmarked journal cannot establish ownership.
    func bind(accountID: UUID?) {
        let marker = accountID.map {
            SHA256.hash(data: Data($0.uuidString.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
        }
        state.withLock { state in
            let pending = state.pending
            let truncated = state.pendingTruncated
            let scopeStarted = state.pendingSince ?? Date()
            let keepSetup = state.account == nil && state.anonymousThisLaunch && marker != nil
            if !keepSetup, state.account == nil || state.account != marker {
                state = State(since: scopeStarted, account: marker)
            }
            state.account = marker
            state.anonymousThisLaunch = marker == nil
            state.verified = true
            state.pending = []
            state.pendingTruncated = false
            state.pendingSince = nil
            state.entries += pending
            state.entries.removeAll { $0.date < Date().addingTimeInterval(-1800) }
            if truncated { state.droppedAt = Date() }
            while state.entries.count > Self.limit {
                let removed = state.entries.removeFirst().date
                state.droppedAt = max(state.droppedAt ?? removed, removed)
            }
            persist(state)
        }
    }

    /// Enum-only entry point shared with the per-person timeline uploader.
    func note(_ name: Name, outcome: Outcome? = nil, at date: Date = Date(),
              interactionID: UUID? = nil, startedAt: Date? = nil) {
        append(name, outcome: outcome, at: date, interactionID: interactionID, startedAt: startedAt)
    }

    private func persist(_ value: State) {
        guard file != nil else { return }
        io.async { self.write(value) }
    }

    private func write(_ value: State) {
        guard let file else { return }
        do {
            let data = try JSONEncoder().encode(value)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: file, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            // The shutdown retry includes this marker, so a transient final
            // write failure cannot restore an older file as complete evidence.
            let now = Date()
            state.withLock { $0.droppedAt = max($0.droppedAt ?? now, now) }
        }
    }

    /// Drain queued writes, then retry the current snapshot including any gap
    /// marker. Shutdown calls this off the main actor and waits for the retry.
    func flush() {
        io.sync {
            let current = state.withLock { state in
                state.entries.removeAll { $0.date < Date().addingTimeInterval(-1800) }
                return state
            }
            write(current)
        }
    }

    private func append(_ name: Name, outcome: Outcome? = nil, at date: Date,
                        interactionID: UUID? = nil, startedAt: Date? = nil) {
        let event = Event(name: name, outcome: outcome, at: Self.timestamp(date))
        let recorded = state.withLock { state in
            // A cancelled or delayed session can finish after account clearing.
            // Its start belongs to the old account even when its outcome is new.
            let cutoff = state.verified ? state.since : max(state.since ?? .distantPast, state.pendingSince ?? .distantPast)
            if let cutoff, (startedAt ?? date) < cutoff { return false }
            if !state.verified {
                state.pending.append(Entry(event: event, date: date))
                if state.pending.count > Self.limit {
                    state.pending.removeFirst()
                    state.pendingTruncated = true
                }
                return true
            }
            state.entries.append(Entry(event: event, date: date))
            state.entries.removeAll { $0.date < Date().addingTimeInterval(-1800) }
            if state.entries.count > Self.limit {
                let removed = state.entries.removeFirst().date
                state.droppedAt = max(state.droppedAt ?? removed, removed)
            }
            persist(state)
            return true
        }
        if recorded { sink.withLock { $0 }?(name, outcome, date, interactionID) }
    }

    func snapshot(at date: Date = Date()) -> Snapshot {
        state.withLock { state in
            guard state.verified else { return Snapshot(events: [], truncated: true) }
            let start = date.addingTimeInterval(-1800)
            let count = state.entries.count
            state.entries.removeAll { $0.date < start }
            if state.entries.count != count { persist(state) }
            return Snapshot(events: state.entries.filter { $0.date >= start && $0.date <= date }.map(\.event),
                            truncated: state.droppedAt.map { $0 >= start } ?? false)
        }
    }

    /// Setup can run again after sign-out, while first-run telemetry remains once-only.
    @MainActor
    func observing(_ record: FirstRunRecord) -> FirstRunRecord {
        var seen = Set<FirstRunRecord.Event>()
        var cutoff = state.withLock { $0.since }
        return FirstRunRecord(mark: { event in
            let current = self.state.withLock { $0.since }
            if event == .setupOpened || current != cutoff { seen.removeAll() }
            cutoff = current
            if seen.insert(event).inserted { self.firstRun(event, at: Date()) }
            record.mark(event)
        })
    }

    func firstRun(_ event: FirstRunRecord.Event, at date: Date) {
        let name: Name = switch event {
        case .setupOpened: .setupOpened
        case .signedIn: .signedIn
        case .permissionsGranted: .permissionsGranted
        case .firstSetupDictation: .firstSetupDictation
        case .mailboxConnected: .mailboxConnected
        case .firstSetupEmail: .firstSetupEmail
        case .setupFinished: .setupFinished
        case .firstDictation: .firstDictation
        case .firstEmail: .firstEmail
        }
        append(name, at: date)
    }

    func dictation(_ timing: DictationTiming) {
        guard let outcome = timing.outcome else { return }
        let name: Outcome = switch outcome {
        case .inserted: .inserted
        case .cancelled: .cancelled
        case .heardNothing: .heardNothing
        case .heardAlmostNothing: .heardAlmostNothing
        case .failed(let stage):
            switch stage {
            case .record: .failedRecord
            case .transcribe: .failedTranscribe
            case .clean: .failedClean
            case .email: .failedEmail
            case .insert: .failedInsert
            }
        }
        append(.dictationFinished, outcome: name, at: timing.startDate.addingTimeInterval(timing.elapsed ?? 0), startedAt: timing.startDate)
    }

    func proposal(_ timing: ProposalTiming) {
        guard let outcome = timing.outcome else { return }
        append(.proposalClient, outcome: Outcome(rawValue: outcome.rawValue),
               at: timing.startDate.addingTimeInterval(timing.elapsed ?? 0), startedAt: timing.startDate)
    }
}
