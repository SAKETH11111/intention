import Foundation
import Observation

/// Measured counts are kept per account and connection across launches. Readiness
/// always comes from the current response, since a rescan can withhold context.
@MainActor
@Observable
final class LearningProgress {
    typealias Stage = AlphaClient.MailLearning.Stage
    private(set) var stage: Stage?
    private(set) var label: String?
    private(set) var fraction: Double?
    private(set) var detail: String?
    private(set) var needsMoreMail = false
    static let preparing: TimeInterval = 30 * 60

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var importedSince: Date?
    @ObservationIgnored private var accountID: UUID?
    @ObservationIgnored private var selected: UUID?
    @ObservationIgnored private var saved: [String: Counts] = [:]

    private struct Counts: Codable {
        var read: Int
        var total: Int?
    }

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    func setAccount(_ accountID: UUID?) {
        guard self.accountID != accountID else { return }
        self.accountID = accountID
        selected = nil
        importedSince = nil
        needsMoreMail = false
        stage = nil
        label = nil
        fraction = nil
        detail = nil
        saved = accountID.flatMap { id in
            defaults.data(forKey: Self.key(id)).flatMap { try? JSONDecoder().decode([String: Counts].self, from: $0) }
        } ?? [:]
    }

    func observe(_ connections: [AlphaClient.MailConnection], learning: AlphaClient.MailLearning?) {
        guard let accountID, !connections.isEmpty else {
            selected = nil
            importedSince = nil
            needsMoreMail = false
            stage = nil
            label = nil
            fraction = nil
            detail = nil
            return
        }
        let value = Self.value(connections, learning: learning, selected: selected)
        selected = value.connectionID
        var read = value.sentRead.map { max(0, $0) }
        var total = value.sentTotal.flatMap { $0 >= 0 ? $0 : nil }
        if let id = selected {
            let previous = saved[id.uuidString]
            total = previous?.total ?? total
            if let prior = previous?.read { read = max(prior, read ?? 0) }
            // A newly discovered total smaller than a previously observed count
            // cannot describe that count. Keep the measured count without a ratio.
            if let measured = read, let limit = total, measured > limit {
                if previous != nil { total = nil } else { read = limit }
            }
            if let read {
                saved[id.uuidString] = Counts(read: read, total: total)
                if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: Self.key(accountID)) }
            }
        }
        stage = value.stage
        let live = connections.filter { !OnboardingModel.standing(of: $0).isBroken }
        let imported = value.stage != .ready && !live.isEmpty
            && live.allSatisfy { !VoiceReady.isImporting($0) && !VoiceReady.isReady($0) }
        if imported {
            let since = importedSince ?? now()
            importedSince = since
            needsMoreMail = now().timeIntervalSince(since) >= Self.preparing
        } else {
            importedSince = nil
            needsMoreMail = false
        }
        let shown = Self.display(stage: value.stage, read: read, total: total, needsMoreMail: needsMoreMail)
        label = shown.label
        fraction = shown.fraction
        detail = shown.detail
    }

    /// The setup page uses the same words without maintaining its own progress clock.
    static func presentation(_ connections: [AlphaClient.MailConnection], learning: AlphaClient.MailLearning?)
        -> (label: String?, fraction: Double?, detail: String?) {
        guard !connections.isEmpty else { return (nil, nil, nil) }
        let value = value(connections, learning: learning, selected: nil)
        let total = value.sentTotal.flatMap { $0 >= 0 ? $0 : nil }
        let read = value.sentRead.map { count in max(0, total.map { min(count, $0) } ?? count) }
        return display(stage: value.stage, read: read, total: total, needsMoreMail: false)
    }

    private static func value(_ connections: [AlphaClient.MailConnection], learning: AlphaClient.MailLearning?, selected: UUID?) -> AlphaClient.MailLearning {
        let connection = connections.first(where: { $0.id == selected })
            ?? connections.first(where: { $0.id == learning?.connectionID }) ?? connections[0]
        let ready = connections.contains(where: VoiceReady.isReady)
        let wire = learning?.connectionID == connection.id ? learning : nil
        return .init(stage: ready ? .ready : (connection.backfillDone ? .learning : .reading),
                     percent: nil, sentRead: wire?.sentRead ?? connection.sentRead,
                     sentTotal: wire?.sentTotal ?? connection.sentTotal, connectionID: connection.id)
    }

    private static func display(stage: Stage, read: Int?, total: Int?, needsMoreMail: Bool) -> (label: String?, fraction: Double?, detail: String?) {
        if stage == .ready { return ("Ready to write as you", nil, nil) }
        guard let read else {
            return ("Reading your sent emails to learn how you write", nil, needsMoreMail ? "Needs more sent mail" : nil)
        }
        let number = read.formatted(.number.grouping(.automatic))
        let count = total.map { "Read \(number) of \($0.formatted(.number.grouping(.automatic))) sent emails" }
            ?? "Read \(number) sent emails"
        if needsMoreMail { return ("\(count) to learn how you write", nil, "Needs more sent mail") }
        return ("\(count) to learn how you write",
                total.flatMap { $0 > 0 ? min(1, Double(read) / Double($0)) : nil }, nil)
    }

    private static func key(_ id: UUID) -> String { "sentReadingProgress.\(id.uuidString)" }
}
