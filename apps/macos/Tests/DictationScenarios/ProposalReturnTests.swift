import AppKit
@testable import Dictation
import Testing

extension DictationScenarioTests {
    @Test(arguments: ["same", "element", "thread", "account"])
    func returningToATypedReplyRestoresOnlyItsOwnHeldProposal(change: String) async throws {
        let (p, _) = await shownProposal()
        let typed = "My reply to Priya\n"
        await p.pressKey()
        MockField.shared.text = typed
        MockField.shared.selection = FieldRange(location: typed.utf16.count - 1, length: 0)
        p.controller.observe(p.observation(edit: 1))
        #expect(p.card.isShown)
        let shownBeforeB = p.card.shown.count
        let thread = p.reader.thread
        p.reader.threadID = "18c2f4a9d0e1b3b7"
        p.reader.thread = "Tomás Ortega\nCan you send the deck before Friday?"
        MockField.shared.text = "\n"
        MockField.shared.selection = FieldRange(location: 0, length: 0)
        p.focusReply(focus: 2, element: 2)
        await until { p.route.created.count == 2 && p.card.isShown && p.card.shown.count > shownBeforeB }
        let shownBeforeReturn = p.card.shown.count
        p.reader.threadID = change == "thread" ? "18c2f4a9d0e1b3c8" : "18c2f4a9d0e1b3a2"
        p.reader.thread = thread
        if change == "account" { p.accountShift.value += 1 }
        MockField.shared.text = typed
        MockField.shared.selection = FieldRange(location: typed.utf16.count - 1, length: 0)
        let reads = p.reader.bodyReads
        p.focusReply(focus: 3, element: change == "element" ? 3 : 1)
        await until { p.reader.bodyReads > reads }
        if change == "same" { await until { p.card.isShown } }
        else { try await Task.sleep(for: .milliseconds(150)) }
        #expect(p.card.isShown == (change == "same"))
        #expect(p.card.shown.count == (change == "same" ? shownBeforeReturn + 1 : shownBeforeReturn))
        #expect(p.route.created.count == 2)
        #expect(MockField.shared.text == typed)
        #expect(p.route.accepted.isEmpty)
        p.controller.reset()
    }
}
