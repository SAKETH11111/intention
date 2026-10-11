import AppKit
@testable import Onboarding
import Testing

@MainActor
struct LearningProgressTests {
    private func defaults() -> UserDefaults {
        let name = "LearningProgressTests." + UUID().uuidString
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        return store
    }

    private func response(read: Int? = nil, total: Int? = nil, ready: Bool = false,
                          done: Bool = false, id: UUID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
                          learning: String? = nil) throws -> AlphaClient.MailProgress {
        var row: [String: Any] = [
            "id": id.uuidString, "provider": "gmail", "address": "synthetic@example.com",
            "state": done ? "ready" : "syncing", "backfill_done": done,
            "stored_messages": 9999, "blocked_messages": 0, "reconciling": false,
            "connected_at": "2026-10-10T00:00:00Z", "voice_ready": ready
        ]
        row["sent_read"] = read
        row["sent_total"] = total
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: row), as: UTF8.self)
        let field = learning.map { ",\"learning\":\($0)" } ?? ""
        return try JSONDecoder().decode(AlphaClient.MailProgress.self, from: Data("{\"connections\":[\(encoded)]\(field)}".utf8))
    }

    @Test func oldHostsNeverTurnMilestonesOrStoredMailIntoSentCounts() throws {
        let model = LearningProgress(defaults: defaults())
        model.setAccount(UUID())
        let old = try response(learning: #"{"stage":"reading","percent":99}"#)
        model.observe(old.connections, learning: old.learning)
        #expect(model.label == "Reading your sent emails to learn how you write")
        #expect(model.fraction == nil)
        let imported = try response(done: true)
        model.observe(imported.connections, learning: nil)
        #expect(model.label == "Reading your sent emails to learn how you write")
        #expect(model.fraction == nil)
        let shown = LearningProgress.presentation(imported.connections, learning: nil)
        #expect(shown.label == "Reading your sent emails to learn how you write")
        #expect(shown.fraction == nil)
        #expect(shown.detail == nil)
    }

    @Test func importedMailWithoutCountsSaysWhatItReadsAndThenWhatCanHelp() throws {
        var time = Date(timeIntervalSince1970: 0)
        let model = LearningProgress(defaults: defaults(), now: { time })
        model.setAccount(UUID())
        let imported = try response(done: true)
        model.observe(imported.connections, learning: nil)
        #expect(model.label == "Reading your sent emails to learn how you write")
        #expect(model.detail == nil)
        time += LearningProgress.preparing
        model.observe(imported.connections, learning: nil)
        #expect(model.label == "Reading your sent emails to learn how you write")
        #expect(model.detail == "Needs more sent mail")
        #expect(model.fraction == nil)
    }

    @Test func noneReadYetShowsTheTotal() throws {
        let model = LearningProgress(defaults: defaults())
        model.setAccount(UUID())
        model.observe(try response(read: 0, total: 3000).connections, learning: nil)
        #expect(model.label == "Read 0 of 3,000 sent emails to learn how you write")
        #expect(model.fraction == 0)
        #expect(model.detail == nil)
    }

    @Test func realCountsAndUnknownTotalsDecode() throws {
        let wire = try response(read: 1240, total: 3000,
                                learning: #"{"stage":"reading","percent":41,"sent_read":1240,"sent_total":3000,"connection_id":"33333333-3333-4333-8333-333333333333"}"#)
        #expect(wire.learning?.sentRead == 1240)
        #expect(wire.learning?.sentTotal == 3000)
        #expect(wire.connections[0].sentRead == 1240)
        let model = LearningProgress(defaults: defaults())
        model.setAccount(UUID())
        model.observe(wire.connections, learning: wire.learning)
        #expect(model.label == "Read 1,240 of 3,000 sent emails to learn how you write")
        #expect(abs((model.fraction ?? 0) - 1240.0 / 3000.0) < 0.000001)
        let unknown = try response(read: 1240)
        let other = LearningProgress(defaults: defaults())
        other.setAccount(UUID())
        other.observe(unknown.connections, learning: nil)
        #expect(other.label == "Read 1,240 sent emails to learn how you write")
        #expect(other.fraction == nil)
    }

    @Test func countsNeverCreepRegressOrExceedTheirTotal() throws {
        let model = LearningProgress(defaults: defaults())
        model.setAccount(UUID())
        let first = try response(read: 1240, total: 3000)
        model.observe(first.connections, learning: nil)
        for _ in 0..<120 { model.observe(first.connections, learning: nil) }
        #expect(model.label == "Read 1,240 of 3,000 sent emails to learn how you write")
        let lower = try response(read: 5, total: 6000)
        model.observe(lower.connections, learning: nil)
        #expect(model.label == "Read 1,240 of 3,000 sent emails to learn how you write")
        let excessive = try response(read: 4000, total: 3000)
        let clean = LearningProgress(defaults: defaults())
        clean.setAccount(UUID())
        clean.observe(excessive.connections, learning: nil)
        #expect(clean.label == "Read 3,000 of 3,000 sent emails to learn how you write")
        #expect(clean.fraction == 1)
        #expect(clean.stage == .reading)
    }

    @Test func highWaterIsScopedToAccountAndConnectionAcrossRelaunch() throws {
        let store = defaults(), account = UUID()
        let first = LearningProgress(defaults: store)
        first.setAccount(account)
        first.observe(try response(read: 1240, total: 3000).connections, learning: nil)
        let relaunched = LearningProgress(defaults: store)
        relaunched.setAccount(account)
        #expect(relaunched.label == nil)
        relaunched.observe(try response(read: 100, total: 3000).connections, learning: nil)
        #expect(relaunched.label == "Read 1,240 of 3,000 sent emails to learn how you write")
        relaunched.observe(try response(read: 2, total: 10, id: UUID()).connections, learning: nil)
        #expect(relaunched.label == "Read 2 of 10 sent emails to learn how you write")
        relaunched.setAccount(UUID())
        relaunched.observe(try response(read: 100, total: 3000).connections, learning: nil)
        #expect(relaunched.label == "Read 100 of 3,000 sent emails to learn how you write")
        relaunched.observe([], learning: nil)
        #expect(relaunched.label == nil)
        #expect(relaunched.fraction == nil)
    }

    @Test func readyRequiresCurrentReadinessAndRescanPreservesMeasuredCount() throws {
        let model = LearningProgress(defaults: defaults())
        model.setAccount(UUID())
        model.observe(try response(read: 1240, total: 3000, ready: true).connections, learning: nil)
        #expect(model.label == "Ready to write as you")
        #expect(model.fraction == nil)
        model.observe(try response(read: 1, total: 3000).connections, learning: nil)
        #expect(model.stage == .reading)
        #expect(model.label == "Read 1,240 of 3,000 sent emails to learn how you write")
        model.setAccount(nil)
        #expect(model.label == nil)
    }

    @Test func zeroTotalDoesNotClaimReadiness() throws {
        let model = LearningProgress(defaults: defaults())
        model.setAccount(UUID())
        model.observe(try response(read: 0, total: 0, done: true).connections, learning: nil)
        #expect(model.label == "Read 0 of 0 sent emails to learn how you write")
        #expect(model.fraction == nil)
        #expect(model.stage == .learning)
    }

    @Test func importedMailKeepsItsCountAndExplainsWhatCanHelp() throws {
        var time = Date(timeIntervalSince1970: 0)
        let model = LearningProgress(defaults: defaults(), now: { time })
        model.setAccount(UUID())
        let imported = try response(read: 2, total: 2, done: true)
        model.observe(imported.connections, learning: nil)
        #expect(!model.needsMoreMail)
        time += LearningProgress.preparing
        model.observe(imported.connections, learning: nil)
        #expect(model.needsMoreMail)
        #expect(model.label == "Read 2 of 2 sent emails to learn how you write")
        #expect(model.detail == "Needs more sent mail")
        #expect(model.fraction == nil)
        model.observe(try response(read: 2, total: 2).connections, learning: nil)
        #expect(!model.needsMoreMail)
        #expect(model.label == "Read 2 of 2 sent emails to learn how you write")
        #expect(model.fraction == 1)
    }

    @Test func aFinishedImportWithoutEnoughExamplesStillPresentsItsCount() throws {
        let response = try response(read: 2, total: 2, done: true)
        let shown = LearningProgress.presentation(response.connections, learning: response.learning)
        #expect(shown.label == "Read 2 of 2 sent emails to learn how you write")
        #expect(shown.fraction == 1)
    }
}
