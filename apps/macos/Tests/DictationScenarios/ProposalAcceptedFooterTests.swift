import AppKit
@testable import Dictation
import Testing

extension DictationScenarioTests {
    // HTTP acceptance can succeed while the accepted receipt adds the server's
    // footer. The real writer, controller and inserter must finish this case.
    @Test func anAcceptedServerFooterReachesTheEmptyReplyBody() async throws {
        let accepted = proposalDraft + "\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-"
        let route = ScriptedRoute(text: proposalDraft, acceptedText: accepted)
        route.onCreate = .complete
        // Keep the writer's 300 ms timeout asleep so a slow test cannot use
        // the late-answer path and insert before checking this receipt.
        let clock = SteppedClock()
        let (p, outcomes) = await shownProposal(route: route, addSentWithIntention: true, clock: clock) {
            $0.hiddenPlaceholder = true
        }
        #expect(p.card.shown.last?.text == proposalDraft)
        #expect(route.created.first?.compose.addSentWithIntention == true)
        #expect(route.created.first?.compose.proposal == true)
        let clipboard = try #require(MockField.shared.pasteboard)
        clipboard.clearContents()
        clipboard.setString("Synthetic clipboard before acceptance.", forType: .string)
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { !outcomes.list.isEmpty }
        #expect(route.recordedAcceptances.count == 1)
        #expect(outcomes.list == [.inserted])
        #expect(outcomes.refused.isEmpty)
        let timing = try #require(outcomes.timings.last)
        #expect(timing.failure == nil)
        #expect(timing.diagnostics.failureKind != .acceptanceFailed)
        #expect(MockField.shared.text == proposalDraft + "\n")
        #expect(MockField.shared.keys == ["paste"])
        #expect(MockField.shared.accessibilityWrites == 0)
        #expect(p.history.entries.first?.outcome == .inserted)
        #expect(p.history.entries.first?.proposal == .accepted)
        #expect(clipboard.string(forType: .string) == "Synthetic clipboard before acceptance.")
    }

    @Test func theSameEmptyReplyAcceptsAnUnchangedReceipt() async throws {
        let route = ScriptedRoute(text: proposalDraft)
        route.onCreate = .complete
        let (p, outcomes) = await shownProposal(route: route, clock: SteppedClock()) {
            $0.hiddenPlaceholder = true
        }
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { !outcomes.list.isEmpty }
        #expect(p.route.recordedAcceptances.count == 1)
        #expect(outcomes.list == [.inserted])
        #expect(outcomes.refused.isEmpty)
        #expect(MockField.shared.text == proposalDraft + "\n")
        #expect(MockField.shared.keys == ["paste"])
        #expect(MockField.shared.accessibilityWrites == 0)
    }

    @Test(arguments: [
        ("Friday works.", "Friday works.\n\nSent with Intention https://intention.example/?ref=AbCdEf0123_-"),
        ("Friday works. \t\r\n", "Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-"),
        (" Caf\u{00E9}  Friday works.", " Caf\u{00E9}  Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-"),
    ])
    func aDecoratedReceiptInsertsEveryShownByte(_ texts: (String, String)) async throws {
        let (shown, accepted) = texts
        let route = ScriptedRoute(text: shown, acceptedText: accepted)
        route.onCreate = .complete
        let (p, outcomes) = await shownProposal(route: route, addSentWithIntention: true, clock: SteppedClock()) {
            $0.hiddenPlaceholder = true
        }
        #expect(p.card.shown.last?.text.utf8.elementsEqual(shown.utf8) == true)
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { !outcomes.list.isEmpty }
        #expect(outcomes.list == [.inserted])
        #expect(outcomes.refused.isEmpty)
        let timing = try #require(outcomes.timings.last)
        #expect(timing.failure == nil)
        #expect(MockField.shared.text.utf8.elementsEqual((shown + "\n").utf8))
        #expect(MockField.shared.keys == ["paste"])
        #expect(MockField.shared.accessibilityWrites == 0)
        #expect(p.history.entries.first?.outcome == .inserted)
        #expect(p.history.entries.first?.proposal == .accepted)
    }

    @Test(arguments: [
        "Caf\u{00E9} Thursday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-",
        "Caf\u{00E9} Friday works. Another sentence.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-",
        "Caf\u{00E9} Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-\nAnother sentence.",
        "Caf\u{00E9} Friday works.\n\nsent with intention https://elsewhere.example/?ref=AbCdEf0123_-",
        "Caf\u{00E9} Friday works.\n\nsent with intention https://intention.example/?ref=short",
        "Caf\u{00E9} Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-X",
        "Caf\u{00E9} Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_/",
        "Caf\u{00E9} Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-&extra=1",
        "Caf\u{00E9} Friday works. sent with intention https://intention.example/?ref=AbCdEf0123_-",
        "Caf\u{00E9} Friday works.\n\n> sent with intention https://intention.example/?ref=AbCdEf0123_-",
        "Caf\u{00E9} Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-",
        "Caf\u{00E9} Friday works.\nsent with intention https://intention.example/?ref=AbCdEf0123_-",
        "Caf\u{00E9} Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-\n",
        "Caf\u{00E9} Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_- ",
        " Caf\u{00E9} Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-",
        "Caf\u{00E9}  Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-",
        "Cafe\u{0301} Friday works.",
        "Cafe\u{0301} Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-",
        "Caf\u{00E9} Friday works.\n\nSent with intention https://intention.example/?ref=AbCdEf0123_-",
        "Caf\u{00E9} Friday works.\n\nsent with intention https://intention.example/other?ref=AbCdEf0123_-",
        "Caf\u{00E9} Friday works.\n\nsent with intention http://intention.example/?ref=AbCdEf0123_-",
        "Caf\u{00E9} Friday works.\r\n\r\nsent with intention https://intention.example/?ref=AbCdEf0123_-",
        "Caf\u{00E9} Friday works.\n\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-",
        "Caf\u{00E9} Friday works. \n\nsent with intention https://intention.example/?ref=AbCdEf0123_-",
    ])
    func anImmediateMutatedReceiptNeverReachesTheInserter(_ accepted: String) async throws {
        try await refusedFooterReceipt(accepted, enabled: true)
    }

    @Test func aFooterReceiptIsRefusedWhenDecorationWasOff() async throws {
        try await refusedFooterReceipt("Caf\u{00E9} Friday works.\n\nsent with intention https://intention.example/?ref=AbCdEf0123_-", enabled: false)
    }

    private func refusedFooterReceipt(_ accepted: String, enabled: Bool) async throws {
        let shown = "Caf\u{00E9} Friday works."
        let route = ScriptedRoute(text: shown, acceptedText: accepted)
        route.onCreate = .complete
        let (p, outcomes) = await shownProposal(route: route, addSentWithIntention: enabled, clock: SteppedClock()) {
            $0.hiddenPlaceholder = true
        }
        let clipboard = try #require(MockField.shared.pasteboard)
        clipboard.clearContents()
        clipboard.setString("Synthetic clipboard before refusal.", forType: .string)
        #expect(p.card.shown.last?.text.utf8.elementsEqual(shown.utf8) == true)
        #expect(route.created.first?.compose.addSentWithIntention == enabled)
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { !outcomes.list.isEmpty }
        #expect(route.recordedAcceptances.count == 1)
        #expect(outcomes.list == [.insertRefused])
        #expect(outcomes.refused.count == 1)
        #expect(outcomes.refused.first?.0 == .busy)
        #expect(outcomes.refused.first?.1.utf8.elementsEqual(shown.utf8) == true)
        let timing = try #require(outcomes.timings.last)
        #expect(timing.failure == .request(.conflict))
        #expect(timing.diagnostics.failureKind == .acceptanceFailed)
        #expect(timing.insertionResult == nil)
        #expect(MockField.shared.text == "\n")
        #expect(MockField.shared.keys.isEmpty)
        #expect(MockField.shared.accessibilityWrites == 0)
        #expect(p.history.entries.first?.outcome == .notInserted)
        #expect(p.history.entries.first?.proposal == .accepted)
        #expect(clipboard.string(forType: .string) == "Synthetic clipboard before refusal.")
    }
}
