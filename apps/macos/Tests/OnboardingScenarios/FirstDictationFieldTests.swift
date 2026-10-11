import AppKit
@testable import Onboarding
import Testing

/// The text field on setup's last page, in a window that is never shown.
/// No key is pressed and nothing is put on screen.
@MainActor
@Suite
struct FirstDictationFieldTests {
    private let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 388, height: 200), styleMask: [.titled],
                                  backing: .buffered, defer: false)
    private let field = FirstDictationField.FieldView(frame: CGRect(x: 0, y: 0, width: 388, height: 60))

    init() {
        // The window never has the keyboard, so the field is told to show
        // its dot all the same, as for stills. Nothing else reads this.
        FirstDictationField.still = true
        window.contentView?.addSubview(field)
        settle()
    }

    private var scroll: NSScrollView { field.subviews.compactMap { $0 as? NSScrollView }[0] }
    private var text: NSTextView { scroll.documentView as! NSTextView }
    private var dot: NSView { field.subviews.first { $0 is FirstDictationField.DotView }! }

    /// As SwiftUI does: the field is given the height it asks for.
    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        field.setFrameSize(CGSize(width: 388, height: field.height(for: 388)))
        field.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    /// Where AppKit puts the caret, in the field's coordinates.
    private var caretX: CGFloat {
        let onScreen = text.firstRect(forCharacterRange: NSRange(location: text.selectedRange().location, length: 0), actualRange: nil)
        return field.convert(window.convertFromScreen(onScreen), from: nil).minX
    }

    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + seconds) }

    @Test func retentionSeesTheExactSpacedInsertionOnlyOnce() {
        var saved: [(String, Date)] = []
        field.inserted = { saved.append(($0, $1)) }
        field.take(("Hello", at(0)))
        field.take(("world", at(1)))
        field.take(("world", at(1)))
        #expect(saved.map(\.0) == ["Hello", " world"])
        #expect(saved.last?.1 == at(1))
        #expect(text.string == "Hello world")
    }

    @Test func eachArrivalIsWrittenOnceAtTheCaret() {
        field.take(("Running late.", at(0)))
        #expect(text.string == "Running late.")
        // The same arrival again, as the page redraws, writes nothing.
        field.take(("Running late.", at(0)))
        #expect(text.string == "Running late.")
        // An older one is never written.
        field.take(("Earlier.", at(-5)))
        #expect(text.string == "Running late.")
        // The same sentence said again is a new arrival.
        field.take(("Running late.", at(9)))
        #expect(text.string == "Running late. Running late.")
    }

    @Test func aDictationTakesThePlaceOfASelectionAndKeepsWordsApart() {
        text.insertText("Hello brave there", replacementRange: NSRange(location: 0, length: 0))
        text.setSelectedRange(NSRange(location: 6, length: 5))
        field.take(("mighty", at(0)))
        #expect(text.string == "Hello mighty there")
        text.setSelectedRange(NSRange(location: 5, length: 0))
        field.take(("and", at(1)))
        #expect(text.string == "Hello and mighty there")
        #expect(text.selectedRange() == NSRange(location: 9, length: 0))
    }

    @Test func theDotStaysOverTheCaretAsItMovesAndAsTheFieldGrows() {
        let empty = field.height(for: 388)
        field.take(("Running ten minutes late, save me a seat by the window.", at(0)))
        settle()
        #expect(abs(dot.frame.midX - (caretX + 1)) < 0.6)
        let twoLines = field.height(for: 388)
        #expect(twoLines > empty + 20)
        // Moved by hand, then typed past the end of the second line.
        text.setSelectedRange(NSRange(location: 8, length: 0))
        settle()
        #expect(abs(dot.frame.midX - (caretX + 1)) < 0.6)
        let moved = dot.frame.midX
        text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
        text.insertText(" Typed by hand, and then more words to reach a third line of the field.", replacementRange: text.selectedRange())
        settle()
        #expect(field.height(for: 388) > twoLines + 20)
        #expect(abs(dot.frame.midX - (caretX + 1)) < 0.6)
        #expect(dot.frame.midX != moved)
    }

    @Test func aLongTextScrollsInsideAFieldThatStopsGrowing() {
        // The page's buttons sit under the field in a window of fixed
        // height, so the field stops at four lines.
        text.insertText("One line of words that is long enough to wrap in this field. ", replacementRange: NSRange(location: 0, length: 0))
        settle()
        var heights: [CGFloat] = [field.height(for: 388)]
        for _ in 0..<12 {
            text.insertText("More words, and more, until the lines run well past four. ", replacementRange: text.selectedRange())
            settle()
            heights.append(field.height(for: 388))
        }
        let tallest = heights.max()!
        #expect(heights.last == tallest)
        #expect(tallest < 170)
        // Five more lines than it shows, at least: the text scrolls.
        #expect(text.frame.height > scroll.frame.height + 100)
        // Typing kept the caret, at the end, in view with the dot over it.
        #expect(!dot.isHidden)
        #expect(abs(dot.frame.midX - (caretX + 1)) < 0.6)
        #expect(dot.frame.minY >= 0)
        // Scrolled back to the top, the caret is out of view and so is
        // the dot.
        text.scroll(.zero)
        settle()
        #expect(dot.isHidden)
    }

    @Test func returnEndsSetupWhereThePageSaysAndNeverBreaksTheLine() {
        var ended = 0
        text.insertText("Running late.", replacementRange: NSRange(location: 0, length: 0))
        // Before any words: the page gives nothing to do.
        text.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(text.string == "Running late.")
        field.submit = { ended += 1 }
        text.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(ended == 1)
        #expect(text.string == "Running late.")
    }

    @Test func thePlaceholderReachesVoiceOver() {
        field.placeholder = "Try a sentence."
        #expect(text.accessibilityPlaceholderValue() == "Try a sentence.")
        #expect(text.accessibilityLabel() == "Your first dictation")
    }

    @Test func theDotTakesAClickOnlyWhileShownAndAsked() {
        var clicks = 0
        field.dotClicked = { clicks += 1 }
        settle()
        // Over the dot, in the coordinates its superview's hit testing uses.
        let overDot = field.convert(CGPoint(x: dot.frame.midX, y: dot.frame.midY), to: field.superview)
        #expect(field.hitTest(overDot) === dot)
        dot.mouseDown(with: NSEvent())
        #expect(clicks == 1)
        // Scrolled out of view, the dot is hidden and the text takes the click.
        dot.isHidden = true
        #expect(field.hitTest(overDot) !== dot)
        dot.isHidden = false
        // A page that gives the dot nothing to do leaves it a drawing.
        field.dotClicked = nil
        #expect(field.hitTest(overDot) !== dot)
    }

    @Test func theDotIsWholeAtRestAndWhileListeningAndBreathesOnlyWhileIntentionWorks() throws {
        let dot = try #require(self.dot as? FirstDictationField.DotView)
        // At rest the dot is solid, as it rests everywhere, with its hairline
        // in its frame: the dot's width plus the hairline on each side.
        #expect(dot.layer?.opacity == 1)
        #expect(dot.frame.width == FirstDictationField.DotView.width + 2 * OwnHandMark.restEdge)
        #expect(!dot.isBreathing)
        field.isListening = true
        #expect(dot.layer?.opacity == 1)
        #expect(!dot.isBreathing)
        field.isListening = false
        field.isWorking = true
        #expect(dot.isBreathing == !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        // The work ends and so does the breath, back to the solid rest.
        field.isWorking = false
        #expect(!dot.isBreathing)
        #expect(dot.layer?.opacity == 1)
    }

    @Test(.timeLimit(.minutes(1))) func aDisplayOptionsChangeFromABackgroundQueueReachesTheMainActor() async throws {
        let dot = try #require(self.dot as? FirstDictationField.DotView)
        field.isWorking = true
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                dot.displayOptionsChanged()
                done.resume()
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(dot.isBreathing == !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        field.isWorking = false
    }

    @Test(.timeLimit(.minutes(1))) func landingWordsLeaveTheTextAndItsUndoAlone() async throws {
        field.take(("Running ten minutes late", at(1)))
        let storage = try #require(text.textStorage)
        // The fade is drawn, never written into the text.
        let ink = NSColor(SetupStyle.ink)
        storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            #expect((value as? NSColor)?.alphaComponent == ink.alphaComponent)
        }
        // An edit ends it at once.
        text.insertText(" now", replacementRange: NSRange(location: storage.length, length: 0))
        #expect(!field.isLanding)
        // A landing that is left alone ends by itself, even in a window that
        // never draws.
        field.take(("save me a seat", at(2)))
        let deadline = ContinuousClock.now + .seconds(5)
        while field.isLanding, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!field.isLanding)
    }
}
