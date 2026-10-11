import CoreGraphics
@testable import Intention
import Testing

struct CaretBoundsTests {
    // Measured on macOS 27: AppKit's collapsed range has the painted x one
    // line above the painted insertion point; Chromium's is the caret.
    /// Monaco keeps keyboard focus in a text area a point wide and a line
    /// tall, moved to the caret: that frame is the caret. Anything wider,
    /// or not a line tall, says nothing.
    @Test func aOnePointWideControlALineTallIsTheCaret() {
        #expect(CaretBounds.caretFromControlFrame(CGRect(x: 412, y: 300, width: 1, height: 18)) == CGRect(x: 412.5, y: 300, width: 0, height: 18))
        #expect(CaretBounds.caretFromControlFrame(CGRect(x: 412, y: 300, width: 0, height: 22)) == CGRect(x: 412, y: 300, width: 0, height: 22))
        #expect(CaretBounds.caretFromControlFrame(CGRect(x: 412, y: 300, width: 3, height: 18)) == nil)
        #expect(CaretBounds.caretFromControlFrame(CGRect(x: 412, y: 300, width: 1, height: 1)) == nil)
        #expect(CaretBounds.caretFromControlFrame(CGRect(x: 412, y: 300, width: 1, height: 120)) == nil)
        #expect(CaretBounds.caretFromControlFrame(CGRect(x: CGFloat.nan, y: 300, width: 1, height: 18)) == nil)
    }

    /// Gmail's empty compose body: a frame with a width and no height. Its
    /// estimate is a line at its top-left corner; a field with a height, or
    /// a narrow one, is not this case.
    @Test func aFlatControlWithAWidthAndNoHeightGetsALineAtItsTopLeft() {
        #expect(CaretBounds.flatControlLine(CGRect(x: 138, y: 399, width: 944, height: 0)) == CGRect(x: 138, y: 399, width: 0, height: 18))
        #expect(CaretBounds.flatControlLine(CGRect(x: 138, y: 399, width: 944, height: 2)) == CGRect(x: 138, y: 399, width: 0, height: 18))
        #expect(CaretBounds.flatControlLine(CGRect(x: 138, y: 399, width: 944, height: 3)) == nil)
        #expect(CaretBounds.flatControlLine(CGRect(x: 138, y: 399, width: 30, height: 0)) == nil)
        #expect(CaretBounds.flatControlBand(below: CGRect(x: 138, y: 399, width: 944, height: 0), within: CGRect(x: 0, y: 0, width: 2000, height: 2000)) == CGRect(x: 138, y: 395, width: 944, height: 44))
    }

    @Test func appKitCollapsedRangesAreOneLineAboveTheirCharacter() {
        let collapsed = CGRect(x: 135, y: 297, width: 0, height: 22)
        #expect(CaretBounds.collapsedMode(collapsed: collapsed, character: CGRect(x: 135, y: 319, width: 11.6, height: 22)) == .lineAbove)
        #expect(CaretBounds.placed(collapsed, mode: .lineAbove) == CGRect(x: 135, y: 319, width: 0, height: 22))
    }

    @Test func chromiumCollapsedRangesAreTheCaret() {
        let collapsed = CGRect(x: 131, y: 230, width: 0, height: 22)
        #expect(CaretBounds.collapsedMode(collapsed: collapsed, character: CGRect(x: 120, y: 230, width: 11, height: 22)) == .direct)
        #expect(CaretBounds.placed(collapsed, mode: .direct) == collapsed)
    }

    @Test func aCharacterOnAnotherLineDecidesNothing() {
        // Downstream soft wrap: the character before the caret ends line one.
        let collapsed = CGRect(x: 135, y: 319, width: 0, height: 22)
        #expect(CaretBounds.collapsedMode(collapsed: collapsed, character: CGRect(x: 533, y: 319, width: 10.7, height: 22)) == nil)
        #expect(CaretBounds.collapsedMode(collapsed: collapsed, character: CGRect(x: 135, y: 363, width: 11, height: 22)) == nil)
        #expect(CaretBounds.collapsedMode(collapsed: collapsed, character: CGRect(x: 135, y: 341, width: 11, height: 16)) == nil)
    }

    @Test func anEmptyFieldDecidesTheModeWhenOnlyOneReadingFitsInside() {
        let field = CGRect(x: 220, y: 348, width: 440, height: 140)
        #expect(CaretBounds.containedMode(CGRect(x: 237, y: 345, width: 0, height: 21), in: field) == .lineAbove)
        let search = CGRect(x: 219, y: 437, width: 442, height: 42)
        #expect(CaretBounds.containedMode(CGRect(x: 244, y: 426, width: 0, height: 21), in: search) == .lineAbove)
        #expect(CaretBounds.containedMode(CGRect(x: 237, y: 400, width: 0, height: 21), in: field) == nil)
        #expect(CaretBounds.containedMode(CGRect(x: 237, y: 345, width: 0, height: 21), in: nil) == nil)
    }

    @Test func adjacentLeftToRightCharactersResolveTheirSharedEdge() {
        let before = CGRect(x: 100, y: 200, width: 11, height: 22)
        let after = CGRect(x: 111, y: 200, width: 7, height: 22)
        #expect(CaretBounds.sharedInsertionPoint(before: before, after: after) == CGRect(x: 111, y: 200, width: 0, height: 22))
    }

    @Test func adjacentRightToLeftCharactersResolveTheirSharedEdge() {
        let before = CGRect(x: 335.25, y: 361, width: 12, height: 22)
        let after = CGRect(x: 330.88, y: 361, width: 4.37, height: 22)
        let caret = CaretBounds.sharedInsertionPoint(before: before, after: after)
        #expect(caret != nil)
        #expect(abs((caret?.minX ?? 0) - 335.25) < 0.001)
    }

    @Test func overlappingLigatureAndSeparatedBidiBoxesRemainUnresolved() {
        let before = CGRect(x: 100, y: 200, width: 15, height: 22)
        #expect(CaretBounds.sharedInsertionPoint(before: before, after: before) == nil)
        #expect(CaretBounds.sharedInsertionPoint(before: before, after: before.offsetBy(dx: 30, dy: 0)) == nil)
        #expect(CaretBounds.sharedInsertionPoint(before: before, after: before.offsetBy(dx: 15, dy: 22)) == nil)
    }

    @Test func documentStartUsesTheOppositeEdgeOfALeftToRightFirstCharacter() {
        let first = CGRect(x: 100, y: 200, width: 11, height: 22)
        let following = CGRect(x: 111, y: 200, width: 7, height: 22)
        #expect(CaretBounds.oppositeBoundaryInsertionPoint(edge: first, neighbor: following, edgePrecedesNeighbor: true) == CGRect(x: 100, y: 200, width: 0, height: 22))
    }

    @Test func documentStartUsesTheOppositeEdgeOfARightToLeftFirstCharacter() {
        let first = CGRect(x: 335.25, y: 361, width: 12, height: 22)
        let following = CGRect(x: 330.88, y: 361, width: 4.37, height: 22)
        #expect(CaretBounds.oppositeBoundaryInsertionPoint(edge: first, neighbor: following, edgePrecedesNeighbor: true) == CGRect(x: 347.25, y: 361, width: 0, height: 22))
    }

    @Test func documentEndUsesTheOppositeEdgeOfALeftToRightLastCharacter() {
        let previous = CGRect(x: 100, y: 200, width: 11, height: 22)
        let last = CGRect(x: 111, y: 200, width: 7, height: 22)
        #expect(CaretBounds.oppositeBoundaryInsertionPoint(edge: last, neighbor: previous, edgePrecedesNeighbor: false) == CGRect(x: 118, y: 200, width: 0, height: 22))
    }

    @Test func documentEndUsesTheOppositeEdgeOfARightToLeftLastCharacter() {
        let previous = CGRect(x: 335.25, y: 361, width: 12, height: 22)
        let last = CGRect(x: 330.88, y: 361, width: 4.37, height: 22)
        #expect(CaretBounds.oppositeBoundaryInsertionPoint(edge: last, neighbor: previous, edgePrecedesNeighbor: false) == CGRect(x: 330.88, y: 361, width: 0, height: 22))
    }

    @Test func boundaryWithoutOneUniqueSameLineSharedEdgeRemainsUnresolved() {
        let edge = CGRect(x: 100, y: 200, width: 11, height: 22)
        #expect(CaretBounds.oppositeBoundaryInsertionPoint(edge: edge, neighbor: edge.offsetBy(dx: 30, dy: 0), edgePrecedesNeighbor: true) == nil)
        #expect(CaretBounds.oppositeBoundaryInsertionPoint(edge: edge, neighbor: edge.offsetBy(dx: 11, dy: 22), edgePrecedesNeighbor: true) == nil)
    }

    @Test func collapsedWitnessUsesACharacterMinimumEdgeAndCharacterLine() {
        let collapsed = CGRect(x: 248.126953125, y: 345, width: 0, height: 21)
        let character = CGRect(x: 248.126953125, y: 366, width: 11, height: 21)
        #expect(CaretBounds.nativeBoundaryInsertionPoint(collapsed: collapsed, character: character) == CGRect(x: 248.126953125, y: 366, width: 0, height: 21))
    }

    @Test func collapsedWitnessUsesACharacterMaximumEdgeForRightToLeftText() {
        let collapsed = CGRect(x: 259.126953125, y: 345, width: 0, height: 21)
        let character = CGRect(x: 248.126953125, y: 366, width: 11, height: 21)
        #expect(CaretBounds.nativeBoundaryInsertionPoint(collapsed: collapsed, character: character) == CGRect(x: 259.126953125, y: 366, width: 0, height: 21))
    }

    @Test func collapsedWitnessRejectsASameLineCollapsedRange() {
        let character = CGRect(x: 248, y: 366, width: 11, height: 21)
        let collapsed = CGRect(x: 248, y: 366, width: 0, height: 21)
        #expect(CaretBounds.nativeBoundaryInsertionPoint(collapsed: collapsed, character: character) == nil)
    }

    @Test func collapsedWitnessRejectsAWrongPriorLineDistance() {
        let character = CGRect(x: 248, y: 366, width: 11, height: 21)
        let collapsed = CGRect(x: 248, y: 344, width: 0, height: 21)
        #expect(CaretBounds.nativeBoundaryInsertionPoint(collapsed: collapsed, character: character) == nil)
    }

    @Test func collapsedWitnessRejectsMismatchedLineHeights() {
        let character = CGRect(x: 248, y: 366, width: 11, height: 21)
        let collapsed = CGRect(x: 248, y: 345, width: 0, height: 20)
        #expect(CaretBounds.nativeBoundaryInsertionPoint(collapsed: collapsed, character: character) == nil)
    }

    @Test func collapsedWitnessRejectsWideCollapsedRanges() {
        let character = CGRect(x: 248, y: 366, width: 11, height: 21)
        let collapsed = CGRect(x: 248, y: 345, width: 2.1, height: 21)
        #expect(CaretBounds.nativeBoundaryInsertionPoint(collapsed: collapsed, character: character) == nil)
    }

    @Test func collapsedWitnessRejectsAnXThatMatchesBothThinCharacterEdges() {
        let character = CGRect(x: 248, y: 366, width: 0.8, height: 21)
        let collapsed = CGRect(x: 248.4, y: 345, width: 0, height: 21)
        #expect(CaretBounds.nativeBoundaryInsertionPoint(collapsed: collapsed, character: character) == nil)
    }

    @Test func collapsedWitnessRejectsAnXOutsideBothCharacterEdges() {
        let character = CGRect(x: 248, y: 366, width: 11, height: 21)
        let collapsed = CGRect(x: 253, y: 345, width: 0, height: 21)
        #expect(CaretBounds.nativeBoundaryInsertionPoint(collapsed: collapsed, character: character) == nil)
    }
}
