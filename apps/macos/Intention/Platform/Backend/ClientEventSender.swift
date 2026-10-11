import Foundation

/// A typed sink for the local diagnostic journal. Only the first sign-in may
/// claim this launch's pre-sign-in setup marks. A later account never receives
/// events observed while the earlier account was signed out or being replaced.
final class ClientEventSender: @unchecked Sendable {
    private struct Pending {
        let name: ClientEventName
        let outcome: ClientEventOutcome?
        let at: Date
        let interactionID: UUID
    }
    private let lock = NSLock()
    private let archive: InteractionArchive
    private let appVersion: String
    private let appBuild: String
    private var scope: String?
    private var hasBound = false
    private var collectingPending = true
    private var hasCheckedIdentity = false
    private var pendingScope: String?
    private var pending: [Pending] = []

    init(archive: InteractionArchive, bundle: Bundle = .main) {
        self.archive = archive
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        appVersion = version.range(of: "^[0-9]{1,5}(\\.[0-9]{1,5}){1,3}$", options: .regularExpression) == nil ? "0.0" : version
        appBuild = build.range(of: "^[0-9]{1,10}$", options: .regularExpression) == nil ? "0" : build
    }

    /// Suspend uploads before resolving a replacement identity. Fresh events may
    /// wait for this lookup, but nothing from the previous lookup crosses it.
    func beginAccountCheck(scope: String? = nil, buffer: Bool) {
        lock.withLock {
            self.scope = nil
            if hasCheckedIdentity, pendingScope != scope, pendingScope != nil { pending.removeAll() }
            pendingScope = scope
            hasCheckedIdentity = true
            collectingPending = buffer || !hasBound
        }
    }

    /// Call after the archive has bound the key, including before sign-out.
    func bind(scope: String?) {
        lock.withLock {
            self.scope = scope
            pendingScope = scope
            if let scope {
                for event in pending { send(event, scope: scope) }
                hasBound = true
                collectingPending = false
            }
            if scope != nil || hasBound { pending.removeAll() }
        }
    }

    func record(_ name: ClientEventName, outcome: ClientEventOutcome? = nil,
                at: Date = Date(), interactionID: UUID? = nil) {
        // The retained archive already publishes correlated terminal and
        // proposal records. The journal mirrors them for local reports only.
        switch name {
        case .dictationFinished, .draftShown, .draftInserted, .draftDismissed,
             .draftOutcome, .proposalClient, .proposalGate: return
        default: break
        }
        let event = Pending(name: name, outcome: outcome, at: at, interactionID: interactionID ?? UUID())
        lock.withLock {
            if let scope { send(event, scope: scope) }
            else if collectingPending && pending.count < 4096 { pending.append(event) }
        }
    }

    private func send(_ event: Pending, scope: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var payload: [String: JSONValue] = [
            "version": .number(1), "name": .string(event.name.rawValue),
            "occurred_at": .string(formatter.string(from: event.at)),
            "app_version": .string(appVersion), "app_build": .string(appBuild),
        ]
        if let outcome = event.outcome { payload["outcome"] = .string(outcome.rawValue) }
        archive.event(event.interactionID, kind: "client_event", payload: payload, scope: scope,
                      once: [.firstDictation, .firstEmail].contains(event.name))
    }
}
