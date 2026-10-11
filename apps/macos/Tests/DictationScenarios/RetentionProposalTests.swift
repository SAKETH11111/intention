import Foundation
import Testing
@testable import Dictation

extension DictationScenarioTests {
    private func retainProposals(_ p: Proposals, in folder: URL) -> InteractionArchive {
        let archive = InteractionArchive(directory: folder) { _, _, _ in throw URLError(.notConnectedToInternet) }
        archive.bind(key: "synthetic-proposal-key")
        p.controller.archive = archive
        p.dictation.archive = archive
        p.writer.retentionScope = { archive.scope }
        return archive
    }

    private func retainedProposalEvents(_ folder: URL) throws -> [[String: Any]] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "body" }
            .compactMap { try JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as? [String: Any] }
    }

    @Test func retentionQuitEndsAShownProposalBeforeFlushing() async throws {
        let p = await proposals(nil, route: ScriptedRoute(text: proposalDraft))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = retainProposals(p, in: folder)
        p.controller.observe(p.observation())
        await until { p.card.isShown }
        #expect(await p.dictation.prepareToQuit())
        #expect(!p.card.isShown)
        #expect(await archive.flush())
        let events = try retainedProposalEvents(folder)
        #expect(events.contains { $0["kind"] as? String == "proposal_client" })
    }

    @Test func retentionQuitWaitsForAnIssuedProposalPaste() async throws {
        let issued = Collected()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let p = await proposals(nil, route: ScriptedRoute(text: proposalDraft), configure: {
            $0.settable = false
            $0.onKey = {
                issued.add(Data([1]))
                _ = release.wait(timeout: .now() + 5)
            }
        })
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = retainProposals(p, in: folder)
        p.controller.observe(p.observation())
        await until { p.card.isShown }
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { !issued.chunks.isEmpty }
        #expect(!issued.chunks.isEmpty)
        var finished = false
        let quitting = Task { @MainActor in
            let saved = await p.dictation.prepareToQuit()
            finished = true
            return saved
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!finished)
        release.signal()
        #expect(await quitting.value)
        let events = try retainedProposalEvents(folder)
        #expect(events.contains { $0["kind"] as? String == "draft_inserted" })
    }

    @Test func retentionReplacementKeepsBothRequestOutcomes() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        let p = await proposals(nil, route: route)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = retainProposals(p, in: folder)
        route.hold(.create)
        p.controller.observe(p.observation())
        await route.whileHeld { p.reader.thread = "Priya\nA newer synthetic question" }
        await until { p.card.isShown }
        #expect(route.created.count == 2)
        p.controller.reset()
        #expect(await archive.flush())
        let events = try retainedProposalEvents(folder).filter { $0["kind"] as? String == "proposal_client" }
        #expect(events.count == 2)
        #expect(Set(events.compactMap { $0["interaction_id"] as? String }.map { $0.lowercased() }) == Set(route.created.map { $0.requestID.uuidString.lowercased() }))
    }

    @Test func retentionProposalInsertionKeepsItsTargetKind() async throws {
        let p = await proposals(nil, route: ScriptedRoute(text: proposalDraft))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = retainProposals(p, in: folder)
        p.controller.observe(p.observation())
        await until { p.card.isShown }
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { !p.history.entries.isEmpty }
        #expect(await archive.flush())
        let event = try #require(try retainedProposalEvents(folder).first { $0["kind"] as? String == "draft_inserted" })
        let payload = try #require(event["payload"] as? [String: Any])
        #expect(payload["target_kind"] as? String == "web")
    }
}
