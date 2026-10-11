import CoreGraphics
@testable import Intention
import Testing

/// What counts as covering the caret, from the element at its point up.
struct CaretCoverTests {
    private static let text = CaretCover.Step.element(role: "AXStaticText", subrole: nil)
    private static let group = CaretCover.Step.element(role: "AXGroup", subrole: nil)

    @Test func theFieldItselfAnythingInsideItOrSomethingHoldingItLeavesItVisible() {
        #expect(!CaretCover.covered(by: [.field]))
        #expect(!CaretCover.covered(by: [Self.text, Self.group, .field]))
    }

    /// Gmail's "Press / to write" hint, a placeholder, ghost text that
    /// completes a sentence, a chip or a link: the hit test finds its text
    /// inside the field, away from the element that holds the caret's own
    /// text position, and the caret still blinks beside it.
    @Test func aHintPlaceholderGhostTextOrChipInsideTheFieldLeavesItVisible() {
        #expect(!CaretCover.covered(by: [Self.text, Self.group, .field]))
        #expect(!CaretCover.covered(by: [.element(role: "AXLink", subrole: nil), Self.group, .field]))
        #expect(!CaretCover.covered(by: [.element(role: "AXImage", subrole: nil), .field]))
    }

    @Test func aMenuListBoxDialogOrTooltipDrawnInsideTheEditorStillCoversIt() {
        #expect(CaretCover.covered(by: [.element(role: "AXMenuItem", subrole: nil), .element(role: "AXMenu", subrole: nil), .field]))
        #expect(CaretCover.covered(by: [Self.text, .element(role: "AXListBox", subrole: nil), .field]))
        // A list inside the field: a list box such as a mention picker has
        // the same role as a bulleted list, so it covers either way.
        #expect(CaretCover.covered(by: [Self.text, .element(role: "AXList", subrole: nil), .field]))
        #expect(CaretCover.covered(by: [Self.text, .element(role: "AXGroup", subrole: "AXUserInterfaceTooltip"), .field]))
        #expect(CaretCover.covered(by: [.element(role: "AXGroup", subrole: "AXApplicationDialog"), Self.group, .field]))
    }

    @Test func aMenuListBoxDialogPopoverTooltipOrSheetCoversItHoweverSmall() {
        for (role, subrole) in [("AXMenuItem", nil), ("AXMenu", nil), ("AXList", nil), ("AXPopover", nil), ("AXSheet", nil), ("AXHelpTag", nil),
                                ("AXGroup", "AXApplicationDialog"), ("AXGroup", "AXApplicationAlertDialog"), ("AXGroup", "AXUserInterfaceTooltip")] as [(String, String?)] {
            #expect(CaretCover.covered(by: [Self.text, .element(role: role, subrole: subrole), .joins(insideField: true)]))
        }
    }

    @Test func aMenuDialogOrTooltipHoldingTheCaretStillCoversItButItsListDoesNot() {
        #expect(!CaretCover.refused([("AXStaticText", nil), ("AXGroup", nil), ("AXList", nil), ("AXTextArea", nil)]))
        #expect(CaretCover.refused([("AXStaticText", nil), ("AXGroup", "AXUserInterfaceTooltip"), ("AXTextArea", nil)]))
        #expect(CaretCover.refused([("AXStaticText", nil), ("AXMenu", nil), ("AXTextArea", nil)]))
        #expect(CaretCover.refused([("AXGroup", "AXApplicationDialog"), ("AXTextArea", nil)]))
        #expect(CaretCover.refused([("AXStaticText", nil), ("AXListBox", nil), ("AXTextArea", nil)]))
    }

    @Test func anotherWindowOfTheSameAppCoversIt() {
        #expect(CaretCover.covered(by: [.element(role: "AXMenuButton", subrole: nil), .otherWindow]))
        #expect(CaretCover.covered(by: [Self.group, .otherWindow]))
    }

    /// Chrome's address bar suggestions: a borderless window drawn as a
    /// frame around the omnibox, whose see-through strip over it is a bare
    /// group. The caret stays in plain view.
    @Test func aBorderlessWindowDrawnAsAFrameAroundTheFieldLeavesItVisible() {
        #expect(!CaretCover.covered(by: [Self.group, Self.group, .frameAround]))
    }

    /// The page's own overlays, with or without a role: a branch beside the
    /// field that reaches outside it covers the caret, and one that stays
    /// inside it, as a placeholder beside an empty composer does, does not.
    @Test func aBranchBesideTheFieldCoversItOnlyWhenItReachesOutsideTheField() {
        #expect(CaretCover.covered(by: [Self.text, Self.group, .joins(insideField: false)]))
        #expect(!CaretCover.covered(by: [Self.text, Self.group, .joins(insideField: true)]))
    }

    @Test func aBranchIsInsideTheFieldWithinAFewPointsOfIt() {
        let field = CGRect(x: 100, y: 100, width: 400, height: 80)
        #expect(CaretCover.inside(CGRect(x: 108, y: 106, width: 120, height: 20), field: field))
        #expect(CaretCover.inside(CGRect(x: 96, y: 96, width: 408, height: 88), field: field))
        // A dropdown that hangs below the field, or a dialog over the page.
        #expect(!CaretCover.inside(CGRect(x: 104, y: 120, width: 300, height: 140), field: field))
        #expect(!CaretCover.inside(CGRect(x: 0, y: 0, width: 1200, height: 800), field: field))
    }

    /// A walk that ran out of parents or depth says nothing.
    @Test func aWalkThatEndsWithoutSayingLeavesItVisible() {
        #expect(!CaretCover.covered(by: []))
        #expect(!CaretCover.covered(by: [Self.text, Self.group]))
    }
}
