import Foundation
@testable import Dictation
import Testing

/// "Draft replies for me" saved through `Preferences` against a defaults
/// domain of its own, the rule that greys its row, and the history mark a
/// proposed draft carries.
@MainActor
struct ProposalSettingsTests {
    private func defaults() -> UserDefaults {
        let name = "ProposalSettingsTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func draftingRepliesIsOnFromTheStartAndRemembersBeingTurnedOff() {
        let store = defaults()
        #expect(Preferences(defaults: store).draftsReplies)
        #expect(store.object(forKey: "draftsReplies") == nil)
        Preferences(defaults: store).draftsReplies = false
        #expect(!Preferences(defaults: store).draftsReplies)
        #expect(store.object(forKey: "draftsReplies") as? Bool == false)
        Preferences(defaults: store).draftsReplies = true
        #expect(Preferences(defaults: store).draftsReplies)
        // Turning email writing off leaves the drafts choice as it was.
        Preferences(defaults: store).writesEmails = false
        #expect(Preferences(defaults: store).draftsReplies)
    }

    @Test func sentWithIntentionIsOffForNewAndExistingInstalls() {
        let store = defaults()
        #expect(!Preferences(defaults: store).addsSentWithIntention)
        #expect(store.object(forKey: "addsSentWithIntention") == nil)
        store.set(false, forKey: "writesEmails")
        store.set(false, forKey: "draftsReplies")
        let existing = Preferences(defaults: store)
        #expect(!existing.addsSentWithIntention)
        #expect(!existing.writesEmails)
        #expect(!existing.draftsReplies)
    }

    @Test func sentWithIntentionRemembersBeingTurnedOffAndBackOn() {
        let store = defaults()
        Preferences(defaults: store).addsSentWithIntention = false
        #expect(store.object(forKey: "addsSentWithIntention") as? Bool == false)
        #expect(!Preferences(defaults: store).addsSentWithIntention)
        Preferences(defaults: store).addsSentWithIntention = true
        #expect(store.object(forKey: "addsSentWithIntention") as? Bool == true)
        #expect(Preferences(defaults: store).addsSentWithIntention)
    }

    @Test func theDraftsRowIsGreyedWhileEmailWritingIsOffOrThePillIsChosen() {
        #expect(WritingRow.draftsBlocked(writesEmails: true, usesPill: false) == nil)
        #expect(WritingRow.draftsBlocked(writesEmails: false, usesPill: false) == "Drafts need email writing on")
        #expect(WritingRow.draftsBlocked(writesEmails: true, usesPill: true) == "Turn on Dot in emails, in System")
        // Both missing: email writing is named, since the dot alone would not do.
        #expect(WritingRow.draftsBlocked(writesEmails: false, usesPill: true) == "Drafts need email writing on")
        #expect(WritingRow.draftsExplanation.contains("Tab puts it in your draft."))
        #expect(!WritingRow.draftsExplanation.contains("\u{2014}"))
    }

    @Test func aProposedDraftIsMarkedInHistoryAndAnUnusedOneRaisesNoNotice() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = folder.appendingPathComponent("Dictation/history.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = DictationHistory(file: file)
        var unused = DictationHistory.Entry(id: UUID(), date: Date(), text: "Thursday works.", outcome: .notInserted)
        unused.proposal = .unused
        history.add(unused)
        #expect(!history.needsAttention)
        var accepted = DictationHistory.Entry(id: UUID(), date: Date(), text: "Harbor Hall it is.", outcome: .inserted)
        accepted.proposal = .accepted
        history.add(accepted)
        var changed = DictationHistory.Entry(id: UUID(), date: Date(), text: "Shorter.", outcome: .uncertain, spoken: "make it shorter")
        changed.proposal = .changed
        history.add(changed)
        // A changed draft that may not have gone in is still worth a look.
        #expect(history.needsAttention)
        let reopened = DictationHistory(file: file)
        #expect(reopened.entries.map(\.proposal) == [.changed, .accepted, .unused])
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(saved.contains("\"proposal\":\"unused\""))
        #expect(DictationHistory.Entry.Proposal.accepted.mark == "Draft")
        #expect(DictationHistory.Entry.Proposal.changed.mark == "Draft, changed")
        #expect(DictationHistory.Entry.Proposal.unused.mark == "Draft, not used")
    }

    @Test func entriesSavedBeforeProposalsStillRead() throws {
        let old = """
            [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","date":781000000,"text":"Hello.","outcome":"inserted"},
             {"id":"7F9619FF-8B86-D011-B42D-00C04FC964FF","date":781000001,"text":"An email.","outcome":"notInserted",
              "reason":"focusChanged","spoken":"say hello"}]
            """
        let entries = try JSONDecoder().decode([DictationHistory.Entry].self, from: Data(old.utf8))
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.proposal == nil })
        #expect(entries[1].spoken == "say hello")
        // A mark this build does not know is refused as the whole file would be.
        let unknown = """
            [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","date":1,"text":"Hi.","outcome":"inserted","proposal":"maybe"}]
            """
        #expect(throws: (any Error).self) { try JSONDecoder().decode([DictationHistory.Entry].self, from: Data(unknown.utf8)) }
    }
}
