@testable import Intention
import Testing

struct FieldEditTests {
    /// "Hello world" with the caret after "Hello".
    private let caret = FieldState(selection: FieldRange(location: 5, length: 0), selectedText: "", before: "Hello", after: " world", length: 11)

    @Test func refusesTextMadeOnlyOfSpacesAndLineBreaks() {
        #expect(!FieldEdit.insertable(""))
        #expect(!FieldEdit.insertable("\n"))
        #expect(!FieldEdit.insertable("\r\n\n"))
        #expect(!FieldEdit.insertable(" \n"))
        #expect(!FieldEdit.insertable("\n\t "))
        #expect(FieldEdit.insertable("ok\n"))
        #expect(FieldEdit.insertable("\nok"))
    }

    @Test func factsCountUTF16Units() {
        // An emoji with a skin tone, a ZWJ sequence and a decomposed accent.
        let selected = "👋🏽 with 👩‍💻 cafe\u{301}"
        let state = FieldState(selection: FieldRange(location: 5, length: selected.utf16.count), selectedText: selected,
                               before: "Plan ", after: " today", length: 5 + selected.utf16.count + 6)
        let facts = EditFacts(replacing: state, with: "東京")
        #expect(facts.range == FieldRange(location: 5, length: 2))
        #expect(facts.lengthAfter == 5 + 2 + 6)
        #expect(facts.beforeRange == FieldRange(location: 0, length: 5))
        #expect(facts.afterRange == FieldRange(location: 7, length: 6))
    }

    @Test func contextIsBoundedOnEachSide() {
        let selection = FieldRange(location: 100, length: 4)
        #expect(FieldEdit.beforeRange(for: selection) == FieldRange(location: 36, length: 64))
        #expect(FieldEdit.afterRange(for: selection, length: 120) == FieldRange(location: 104, length: 16))
        #expect(FieldEdit.beforeRange(for: FieldRange(location: 3, length: 0)) == FieldRange(location: 0, length: 3))
    }

    @Test func insertionIsExpectedOnlyWithTheSameSurroundings() {
        let facts = EditFacts(replacing: caret, with: " there")
        let unchanged = Readback(length: 11, text: "", before: "Hello", after: " world")
        #expect(FieldEdit.verifyInsertion(Readback(length: 17, text: " there", before: "Hello", after: " world"),
                                          unchangedProbe: unchanged, facts: facts) == .expected)
        #expect(FieldEdit.verifyInsertion(Readback(length: 11, text: " worl", before: "Hello", after: nil),
                                          unchangedProbe: unchanged, facts: facts) == .unchanged)
        // The person typed next to the caret while the text was on its way.
        #expect(FieldEdit.verifyInsertion(Readback(length: 18, text: " there", before: "HelloX", after: " world"),
                                          unchangedProbe: Readback(length: 12, text: "", before: "elloX", after: " world"), facts: facts) == .differs)
    }

    @Test func lineBreaksLeftOutOfTheOffsetsShortenTheRangeAndCompareWithoutThem() {
        let facts = EditFacts(replacing: caret, with: " one\ntwo").leavingOutLineBreaks()
        #expect(facts.leftOut == [true])
        #expect(facts.readText == " onetwo")
        #expect(facts.range == FieldRange(location: 5, length: 7))
        #expect(facts.lengthAfter == 18)
        let unchanged = Readback(length: 11, text: "", before: "Hello", after: " world")
        #expect(FieldEdit.verifyInsertion(Readback(length: 18, text: " onetwo", before: "Hello", after: " world", characters: 19),
                                          unchangedProbe: unchanged, facts: facts) == .expected)
        #expect(FieldEdit.verifyInsertion(Readback(length: 18, text: " oneXwo", before: "Hello", after: " world", characters: 19),
                                          unchangedProbe: Readback(length: 18), facts: facts) == .differs)
    }

    @Test func aParagraphBreakAddedWithTheInsertionIsNotConfirmed() {
        let facts = EditFacts(replacing: caret, with: " there")
        let unchanged = Readback(length: 11)
        // The text reads as inserted, with one character more than the
        // insertion accounts for: a paragraph break the offsets leave out.
        #expect(FieldEdit.verifyInsertion(Readback(length: 17, text: " there", before: "Hello", after: " world", characters: 18),
                                          unchangedProbe: unchanged, facts: facts) == .differs)
        #expect(FieldEdit.verifyInsertion(Readback(length: 17, text: " there", before: "Hello", after: " world", characters: 17),
                                          unchangedProbe: unchanged, facts: facts) == .expected)
    }

    @Test func aBlankFieldsPlaceholderBreakIsAllowedButNotAParagraphBreakInTheText() {
        // An empty rich editor: one line break, which its offsets count.
        let blank = FieldState(selection: FieldRange(location: 0, length: 0), selectedText: "", before: "", after: "\n", length: 1)
        let facts = EditFacts(replacing: blank, with: "XY")
        let unchanged = Readback(length: 2)
        #expect(FieldEdit.verifyInsertion(Readback(length: 3, text: "XY", before: "", after: "\n", whole: "XY\n"),
                                          unchangedProbe: unchanged, facts: facts) == .expected)
        // Split into two paragraphs as it landed: the same text by offsets,
        // with a break those offsets leave out.
        #expect(FieldEdit.verifyInsertion(Readback(length: 2, text: "XY", before: "", after: nil, whole: "XY", characters: 3),
                                          unchangedProbe: unchanged, facts: facts) == .differs)
    }




    @Test func theFieldsReadingOfInsertedLineBreaksIsRecognised() {
        // One break between two lines reads as nothing; an empty line after
        // it reads as one break.
        #expect(FieldEdit.breaksLeftOut(of: "X\nY", in: "XY") == [true])
        #expect(FieldEdit.breaksLeftOut(of: "X\n\nY", in: "X\nY") == [true])
        #expect(FieldEdit.breaksLeftOut(of: "X\n\nY", in: "X\n\nY") == [false])
        #expect(FieldEdit.breaksLeftOut(of: "X\nY\n\nZ", in: "XY\nZ") == [true, true])
        #expect(FieldEdit.breaksLeftOut(of: "\nX\n", in: "X") == [true, true])
        // Anything else is a different text.
        #expect(FieldEdit.breaksLeftOut(of: "X\nY", in: "XZ") == nil)
        #expect(FieldEdit.breaksLeftOut(of: "X\n\nY", in: "XY") == nil)
        #expect(FieldEdit.breaksLeftOut(of: "X\nY", in: "XY!") == nil)
    }

    @Test func aReadingWithBreaksLeftOutSaysWhatIsCounted() {
        let facts = EditFacts(replacing: caret, with: "X\n\nY\nZ").reading(leftOut: [true, true])
        #expect(facts.readText == "X\nYZ")
        #expect(facts.range == FieldRange(location: 5, length: 4))
        #expect(facts.lengthAfter == 15)
        // The single break still counts as a character; the pair counts as one.
        #expect(facts.breaksUncounted == 1)
    }


    @Test func webNonBreakingSpacesCompareAsSpaces() {
        let facts = EditFacts(replacing: caret, with: " there")
        let readback = Readback(length: 17, text: "\u{00A0}there", before: "Hello", after: "\u{00A0}world")
        #expect(FieldEdit.verifyInsertion(readback, unchangedProbe: Readback(length: 17), facts: facts) == .expected)
    }



    @Test func aFieldOfOnlyLineBreaksCountsAsEmpty() {
        // A rich editor's empty body holds a placeholder line break, which
        // the editor drops once text arrives and restores once it leaves.
        let blank = FieldState(selection: FieldRange(location: 0, length: 0), selectedText: "", before: "", after: "\n", length: 1)
        let facts = EditFacts(replacing: blank, with: "Hi there")
        #expect(facts.blankBefore)
        #expect(facts.wholeLimit == 10)
        let dropped = Readback(length: 8, text: "Hi there", before: "", after: nil, whole: "Hi there")
        let kept = Readback(length: 9, text: "Hi there", before: "", after: "\n", whole: "Hi there\n")
        #expect(FieldEdit.verifyInsertion(dropped, unchangedProbe: Readback(length: 8), facts: facts) == .expected)
        #expect(FieldEdit.verifyInsertion(kept, unchangedProbe: Readback(length: 9), facts: facts) == .expected)
        // Any other shape is not the editor's placeholder.
        let doubled = Readback(length: 10, text: "Hi there", before: "", after: nil, whole: "Hi there\n\n")
        #expect(FieldEdit.verifyInsertion(doubled, unchangedProbe: Readback(length: 10), facts: facts) == .differs)
        #expect(!EditFacts(replacing: caret, with: "x").blankBefore)
    }




    @Test func aBlankFieldIsOnlyJudgedWholeWhenItsContextCoversIt() {
        // Context that ends before the field does cannot show it is blank.
        let partial = FieldState(selection: FieldRange(location: 0, length: 0), selectedText: "", before: "", after: "\n", length: 200)
        #expect(!EditFacts(replacing: partial, with: "x").blankBefore)
    }
}
