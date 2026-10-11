import AppKit
import Testing
@testable import Inserter

extension TextInserterScenarioTests {
    @Test func retainedPlainBlockParagraphs() async {
        MockField.reset()
        let board = NSPasteboard(name: .init("co.intention.tests." + UUID().uuidString))
        let field = MockField.shared
        field.pasteboard = board
        field.web = true
        field.blocks = true
        field.text = "ab\ncd"
        field.selection = FieldRange(location: 3, length: 0)
        let inserter = TextInserter(pasteboard: PasteboardOwner(pasteboard: board, mayRead: { true }))
        let result = await inserter.insert("X\nY", spaced: false)
        #expect(result.result == .inserted(.paste, clipboardRestored: true))
        #expect(field.text == "ab\ncX\nYd")
        #expect(result.text == "X\nY")
    }

    @Test(arguments: ["Sent with Intention", "sent with intention"])
    func retainedRichFooterBlockParagraphs(_ label: String) async {
        MockField.reset()
        let board = NSPasteboard(name: .init("co.intention.tests." + UUID().uuidString))
        let field = MockField.shared
        field.pasteboard = board
        field.web = true
        field.blocks = true
        field.text = ""
        field.selection = FieldRange(location: 0, length: 0)
        field.pastesLand = false
        field.onKey = { MockField.shared.type("Hello\n\nsent with intention") }
        let inserter = TextInserter(pasteboard: PasteboardOwner(pasteboard: board, mayRead: { true }))
        let result = await inserter.insert(
            "Hello\n\n\(label) https://intention.example/?ref=EcAlU4tZBsYK", spaced: false, linkEmailFooter: true)
        #expect(result.result == .inserted(.paste, clipboardRestored: true))
        #expect(field.text == "Hello\n\nsent with intention")
        #expect(result.text == "Hello\n\nsent with intention")
    }
    @Test func refusedTerminalPasteKeepsOriginalParagraphs() async {
        MockField.reset()
        let board = NSPasteboard(name: .init("co.intention.tests." + UUID().uuidString))
        let field = MockField.shared
        field.pasteboard = board
        field.settable = false
        let owner = PasteboardOwner(pasteboard: board, mayRead: {
            field.focusedElsewhere = true
            return true
        })
        let result = await TextInserter(pasteboard: owner).insert("First\n\nSecond", spaced: false)
        #expect(result.result == .notInserted(.focusChanged))
        #expect(result.text == "First\n\nSecond")
        #expect(field.text == "abc")
        #expect(field.keys.isEmpty)
    }

}
