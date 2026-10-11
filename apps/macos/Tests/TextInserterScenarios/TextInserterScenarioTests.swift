import AppKit
@testable import Inserter
import ObjectiveC
import Testing

/// Has a second process copy "another copy" to the test pasteboard named
/// `name`, as plain text, HTML and a custom type. It is a real other app to
/// the pasteboard: its clearing takes the clipboard from this process, whose
/// writes then fail.
@discardableResult
private func anotherProcessCopies(to name: NSPasteboard.Name) -> Bool {
    guard name.rawValue.hasPrefix("co.intention.tests.") else {
        Issue.record("another process copies only to a test's private pasteboard")
        return false
    }
    let script = """
    ObjC.import('AppKit');
    var pasteboard = $.NSPasteboard.pasteboardWithName('\(name.rawValue)');
    pasteboard.clearContents;
    var item = $.NSPasteboardItem.alloc.init;
    item.setStringForType('another copy', 'public.utf8-plain-text');
    item.setStringForType('<b>another copy</b>', 'public.html');
    item.setStringForType('custom data', 'co.intention.tests.custom');
    pasteboard.writeObjects($([item])) ? 'copied' : 'not copied';
    """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-l", "JavaScript", "-e", script]
    let output = Pipe()
    process.standardOutput = output
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    do {
        try process.run()
    } catch {
        Issue.record("the other process did not start: \(error)")
        return false
    }
    // A stalled pasteboard service or interpreter fails the test instead of
    // holding up the suite.
    guard finished.wait(timeout: .now() + .seconds(10)) == .success else {
        process.terminate()
        Issue.record("the other process did not finish within ten seconds")
        return false
    }
    let said = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0, said == "copied" else {
        Issue.record("the other process did not copy: exit \(process.terminationStatus), said \(said)")
        return false
    }
    return true
}

/// Where another process's copy lands around Intention's next clearing of a
/// test pasteboard, while `racingTheClearing` has exchanged
/// `clearContents()` for `clearContentsInARace()`.
private enum ClearingRace {
    /// Just before the clearing.
    case copyBefore
    /// Just after it, with the clearing answering the count read after that
    /// copy, as two processes clearing at once were measured to.
    case copyAfter
}

private enum Clearing {
    nonisolated(unsafe) static var pasteboard: NSPasteboard.Name?
    nonisolated(unsafe) static var race = ClearingRace.copyBefore
}

extension NSPasteboard {
    /// Its own call reaches the real `clearContents()` while the two are
    /// exchanged. Acts once, and only on the pasteboard a test named.
    @objc fileprivate func clearContentsInARace() -> Int {
        guard name == Clearing.pasteboard else { return clearContentsInARace() }
        Clearing.pasteboard = nil
        switch Clearing.race {
        case .copyBefore:
            anotherProcessCopies(to: name)
            return clearContentsInARace()
        case .copyAfter:
            _ = clearContentsInARace()
            anotherProcessCopies(to: name)
            return changeCount
        }
    }
}

/// The production TextInserter against a scripted field, replaying the
/// failures found in review of PR #76. Each scenario uses a private
/// pasteboard and a field reset to "abc" with the caret after "a".
@MainActor
@Suite(.serialized)
struct TextInserterScenarioTests {
    private let pasteboard = NSPasteboard(name: NSPasteboard.Name("co.intention.tests.\(UUID().uuidString)"))

    private func inserter(clipboardReadable: Bool = true) -> TextInserter {
        MockField.reset()
        MockField.shared.pasteboard = pasteboard
        pasteboard.clearContents()
        pasteboard.setString("the person's clipboard", forType: .string)
        return TextInserter(pasteboard: PasteboardOwner(pasteboard: pasteboard, mayRead: { clipboardReadable }))
    }

    private var field: MockField { .shared }

    @Test(arguments: ["Sent with Intention", "sent with intention"])
    func emailFooterOffersHTMLAndPreservesPlainText(_ label: String) async {
        let inserter = inserter()
        field.text = ""
        field.selection = FieldRange(location: 0, length: 0)
        let text = "Hi & <Maya> 😀\n\nFriday works.\n\n\(label) https://intention.example/?ref=EcAlU4tZBsYK"
        nonisolated(unsafe) var html: String?
        field.onKey = { html = MockField.shared.pasteboard?.string(forType: .html) }
        #expect(await inserter.insert(text, linkEmailFooter: true) == .inserted(.paste, clipboardRestored: true))
        #expect(field.text == text)
        #expect(html == "<span style=\"white-space: pre-wrap\">Hi &amp; &lt;Maya&gt; 😀<br><br>Friday works.<br><br><span style=\"font-family:Georgia,'Times New Roman',serif;font-size:12px\">sent with <a href=\"https://intention.example/?ref=EcAlU4tZBsYK\" style=\"color:inherit\">intention</a></span></span>")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test(arguments: ["Sent with Intention", "sent with intention"])
    func emailFooterConfirmsTheRichTextActuallyPasted(_ label: String) async {
        let inserter = inserter()
        field.text = ""
        field.selection = FieldRange(location: 0, length: 0)
        field.pastesLand = false
        let text = "Hi & <Maya> 😀\n\nFriday works.\n\n\(label) https://intention.example/?ref=EcAlU4tZBsYK"
        field.onKey = { MockField.shared.type("Hi & <Maya> 😀\n\nFriday works.\n\nsent with intention") }
        let inserted = await inserter.insert(text, spaced: false, linkEmailFooter: true)
        #expect(inserted.result == .inserted(.paste, clipboardRestored: true))
        #expect(inserted.text == "Hi & <Maya> 😀\n\nFriday works.\n\nsent with intention")
        #expect(field.text == "Hi & <Maya> 😀\n\nFriday works.\n\nsent with intention")
    }

    @Test func linkedBlockFooterNotYetPastedKeepsTheClipboard() async {
        let inserter = inserter()
        field.web = true
        field.blocks = true
        field.text = "Hello\n\nsent with intention"
        field.select(from: 0, to: field.text.utf16.count)
        field.keysPending = true
        let text = "Hello\n\nsent with intention https://intention.example/?ref=EcAlU4tZBsYK"
        #expect(await inserter.insert(text, linkEmailFooter: true) == .unknown(.writeUnconfirmed))
        #expect(pasteboard.string(forType: .string) == text)
    }

    @Test(arguments: [false, true])
    func linkedBlockFooterWaitsForItsCaretOrAnAnswer(_ selectionUnanswered: Bool) async {
        let inserter = inserter()
        field.web = true
        field.blocks = true
        field.text = "Hello\n\nsent with intention"
        field.select(from: 0, to: field.text.utf16.count)
        field.pastesLand = false
        field.onKey = {
            let field = MockField.shared
            field.type("Hello\n\nsent with intention")
            field.selectionUnanswered = selectionUnanswered
        }
        let text = "Hello\n\nsent with intention https://intention.example/?ref=EcAlU4tZBsYK"
        let result = await inserter.insert(text, linkEmailFooter: true)
        if selectionUnanswered {
            #expect(result == .unknown(.writeUnconfirmed))
            #expect(pasteboard.string(forType: .string) == text)
        } else {
            #expect(result == .inserted(.paste, clipboardRestored: true))
            #expect(pasteboard.string(forType: .string) == "the person's clipboard")
        }
    }

    @Test func ordinaryDictationDoesNotMakeALink() async {
        let inserter = inserter()
        let text = "sent with intention https://intention.example/?ref=EcAlU4tZBsYK"
        #expect(await inserter.insert(text) == .inserted(.selectedText, clipboardRestored: nil))
        #expect(field.text == "a" + text + "bc")
    }

    @Test func linkedEmailStillChecksTheCallerAfterBorrowingTheClipboard() async {
        let inserter = inserter()
        let captured = await guardedField(inserter)
        field.guardAnswer = { $0 == 3 ? .composeChanged : nil }
        let text = "Hello\n\nsent with intention https://intention.example/?ref=EcAlU4tZBsYK"
        #expect(await inserter.insert(text, into: captured, linkEmailFooter: true) == .notInserted(.composeChanged))
        #expect(field.guardCalls == 3)
        #expect(field.keys.isEmpty)
        #expect(field.text == "abc")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func linkedEmailRefusesACopyDuringTheFinalCheck() async {
        let inserter = inserter()
        nonisolated(unsafe) let clipboard = pasteboard
        let text = "Hello\n\nsent with intention https://intention.example/?ref=EcAlU4tZBsYK"
        let result = await inserter.insert(text, linkEmailFooter: true, finalCheck: {
            clipboard.clearContents()
            clipboard.setString("a new copy", forType: .string)
            return nil
        })
        #expect(result == .notInserted(.clipboardBusy))
        #expect(field.keys.isEmpty)
        #expect(field.text == "abc")
        #expect(pasteboard.string(forType: .string) == "a new copy")
    }

    @Test func aLinkedEmailReadbackThatTurnsSecureIsUnconfirmed() async {
        let inserter = inserter()
        field.onKey = { MockField.shared.secure = true }
        let text = "Hello\n\nsent with intention https://intention.example/?ref=EcAlU4tZBsYK"
        #expect(await inserter.insert(text, linkEmailFooter: true) == .unknown(.secureField))
        #expect(field.textReadsWhileSecure == 0)
    }

    @Test func linkRenderingRecognizesOnlyTheExactTerminalFooter() {
        for suffix in [
            "sent with intention https://other.example/?ref=EcAlU4tZBsYK",
            "sent with intention https://intention.example/?ref=short",
            "sent with intention https://intention.example/?ref=EcAlU4tZBsYK&next=bad",
            "Mention sent with intention https://intention.example/?ref=EcAlU4tZBsYK",
            "sent with intention https://intention.example/?ref=EcAlU4tZBsYK\nP.S. Hello"
        ] {
            #expect(EmailFooter("Hello\n\n" + suffix) == nil)
        }
        let body = "\n\nA & B <tag> \"quoted\" 'single' 😀\n \nLast\n\n"
        let footer = EmailFooter(body + "sent with intention https://intention.example/?ref=EcAlU4tZBsYK")
        #expect(footer?.renderedText == body + "sent with intention")
        #expect(footer?.html == "<span style=\"white-space: pre-wrap\"><br><br>A &amp; B &lt;tag&gt; \"quoted\" 'single' 😀<br> <br>Last<br><br><span style=\"font-family:Georgia,'Times New Roman',serif;font-size:12px\">sent with <a href=\"https://intention.example/?ref=EcAlU4tZBsYK\" style=\"color:inherit\">intention</a></span></span>")
    }

    /// An inserter whose clipboard write fails after the clipboard is
    /// cleared.
    private func inserterWhoseClipboardWriteFails() -> TextInserter {
        _ = inserter()
        return TextInserter(pasteboard: PasteboardOwner(pasteboard: pasteboard, mayRead: { true }, put: { _, _ in false }))
    }

    @Test func insertsAtTheCaret() async {
        let inserter = inserter()
        #expect(await inserter.insert("X") == .inserted(.selectedText, clipboardRestored: nil))
        #expect(field.text == "aXbc")
    }

    @Test func aSelectionMovedWhileObservingIsNotWrittenTo() async {
        let inserter = inserter()
        field.moveSelectionOnRead = FieldRange(location: 3, length: 0)
        #expect(await inserter.insert("X") == .notInserted(.fieldChanged))
        #expect(field.text == "abc")
        #expect(field.accessibilityWrites == 0)
    }

    // The reads an insertion keeps of the person's text, each shown to be
    // needed. The field's length is read when it is observed, again in the
    // recheck right before the write, and then for each readback.

    @Test func selectedTextChangedWhileObservingIsNotWrittenOver() async {
        let inserter = inserter()
        field.selection = FieldRange(location: 1, length: 1)
        // "b" becomes "Z" before the recheck: same selection, length and
        // surroundings.
        field.onLengthRead = { [field] count in if count == 2 { field.text = "aZc" } }
        #expect(await inserter.insert("X") == .notInserted(.fieldChanged))
        #expect(field.accessibilityWrites == 0)
        #expect(field.text == "aZc")
    }

    @Test func aSelectionThatChangesUnderARefusedWriteIsNotPastedOver() async {
        let inserter = inserter()
        field.selection = FieldRange(location: 1, length: 1)
        field.writes = .refuse
        // The field neither shows the text nor still holds what was
        // selected, so nothing tells the write was refused.
        field.onLengthRead = { [field] count in if count == 3 { field.text = "aZc" } }
        #expect(await inserter.insert("X") == .unknown(.readbackMismatch))
        #expect(field.keys.isEmpty)
        #expect(field.text == "aZc")
    }

    @Test func textThatLandsAwayFromTheCaretIsNotConfirmed() async {
        let inserter = inserter()
        field.text = "aXb"
        field.selection = FieldRange(location: 2, length: 0)
        // The field shows the text at the start instead: "X" still sits at
        // the caret's place and the length is right; only the text before
        // it differs.
        field.onLengthRead = { [field] count in if count == 3 { field.text = "XaXb" } }
        #expect(await inserter.insert("X") == .unknown(.readbackMismatch))
        #expect(field.keys.isEmpty)
    }

    @Test func aFieldThatGrowsOutsideTheComparedContextIsNotConfirmed() async {
        let inserter = inserter()
        field.text = "a" + String(repeating: "b", count: 100)
        field.selection = FieldRange(location: 1, length: 0)
        // A character arrives at the end, beyond the 64 units after the
        // caret that are compared: only the field's length shows it.
        field.onLengthRead = { [field] count in if count == 3 { field.text += "Z" } }
        #expect(await inserter.insert("X") == .unknown(.readbackMismatch))
        #expect(field.keys.isEmpty)
    }

    @Test func aBlankFieldThatDropsItsPlaceholderBreakIsConfirmedFromItsWholeText() async {
        let inserter = inserter()
        field.text = "\n"
        field.selection = FieldRange(location: 0, length: 0)
        // The editor drops its placeholder break as the text arrives, so
        // the field is one shorter than the text and the break.
        field.onLengthRead = { [field] count in if count == 3 { field.text = "hello" } }
        #expect(await inserter.insert("hello") == .inserted(.selectedText, clipboardRestored: nil))
        #expect(field.text == "hello")
    }

    // An empty field in Chromium: its placeholder line break with the caret
    // in front of it. Gmail's empty compose body reads exactly so, with
    // Gemini's hint hidden from the tree, and Chromium accepted a replace
    // range at offset 0 there and put nothing anywhere (Chrome 156, October
    // 7, 2026), while a paste went in at the caret. Nothing tells that body
    // from any other empty editor, so every blank Chromium field pastes.

    /// An empty web field in Chromium. With `hiddenPlaceholder`, a replace
    /// range at offset 0 is accepted and lands nowhere, as in Gmail's body.
    private func emptyChromiumField(hiddenPlaceholder: Bool = false) -> TextInserter {
        let inserter = inserter()
        field.web = true
        field.text = "\n"
        field.selection = FieldRange(location: 0, length: 0)
        field.hiddenPlaceholder = hiddenPlaceholder
        return inserter
    }

    // The live Outlook traces start at [0, 0] in a body containing one
    // or two breaks. Pasting consumes the first placeholder. The remaining
    // break, in popped-out replies and forwards, stays a literal trailing br.
    @Test(arguments: [1, 2], ["Synthetic first line.\n\nSynthetic second line.", "Synthetic single line.", "One 😀 line.\nSecond line.", "Hello from the Outlook test.\n\nThursday at two works.\nThanks."])
    func outlookInitialBlankParagraphIsConfirmed(breaks: Int, text: String) async {
        let inserter = emptyChromiumField()
        field.bundleIdentifier = "com.google.Chrome"
        field.label = "Message body"
        field.pageURL = "https://outlook.live.com/mail/0/"
        field.text = String(repeating: "\n", count: breaks)
        field.onKey = {
            let field = MockField.shared
            field.text = breaks == 1 ? "" : "\n\n"
            field.blocks = true
            if breaks == 2 { field.literalBlockBreaks = [text.utf16.count + 1] }
        }
        #expect(await inserter.insert(text) == .inserted(.paste, clipboardRestored: true))
        #expect(field.text == text + (breaks == 1 ? "" : "\n\n"))
        if text.hasPrefix("Hello from") {
            // Recorded on outlook.live.com: a 60-unit paste reads as
            // 58/59 ranged units and 59/60 value units in these two shapes.
            #expect(field.ranged.utf16.count == 57 + breaks)
            #expect(field.value.utf16.count == 58 + breaks)
        }
        #expect(field.accessibilityWrites == 0)
        #expect(field.keys == ["paste"])
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    private func untouchedOutlookBody() -> TextInserter {
        let inserter = emptyChromiumField()
        field.bundleIdentifier = "com.google.Chrome"
        field.label = "Message body"
        field.pageURL = "https://outlook.live.com/mail/0/"
        return inserter
    }

    @Test(arguments: [false, true])
    func outlookMixedBreaksRequireTheirRecordedPositions(moved: Bool) async {
        let inserter = untouchedOutlookBody()
        field.pastesLand = false
        field.onKey = {
            let field = MockField.shared
            field.blocks = true
            field.text = moved ? "a\nb\n\nc" : "a\n\nb\nc"
            field.literalBlockBreaks = moved ? [1] : [4]
            field.select(from: field.text.utf16.count, to: field.text.utf16.count)
        }
        let result = await inserter.insert("a\n\nb\nc")
        #expect(result == (moved ? .unknown(.readbackMismatch) : .inserted(.paste, clipboardRestored: true)))
    }

    @Test(arguments: ["otherHost", "subject", "native", "unansweredPage", "secure", "extraBlankLines", "extraText", "duplicate", "elsewhere", "missingCount", "missingMarkers", "missingValue", "missingBlocks"])
    func outlookBlankParagraphCannotExcuseAnotherChange(_ change: String) async {
        let inserter = untouchedOutlookBody()
        let text = String(repeating: "a", count: 80) + "\n\n" + String(repeating: "a", count: 80)
        switch change {
        case "otherHost": field.pageURL = "https://example.net/"
        case "subject": field.label = "Subject"
        case "native": field.web = false; inserter.pasteOnly = true
        case "unansweredPage": field.pageURL = nil
        default: break
        }
        field.pastesLand = false
        field.onKey = {
            let field = MockField.shared
            field.blocks = true
            switch change {
            case "secure": field.secure = true
            case "extraBlankLines": field.type(text + "\n\n")
            case "extraText": field.type(text + "b")
            case "duplicate": field.type(text + text)
            case "elsewhere": field.text = "\n" + text; field.select(from: field.text.utf16.count, to: field.text.utf16.count)
            case "missingCount": field.type(text); field.countUnanswered = true
            case "missingMarkers": field.type(text); field.markerLengthUnanswered = true
            case "missingValue": field.type(text); field.valueUnanswered = true
            case "missingBlocks": field.type(text); field.childrenUnanswered = true
            default: field.type(text)
            }
        }
        let result = await inserter.insert(text)
        if case .unknown = result {} else { Issue.record("unexpected confirmation: \(result)") }
        #expect(field.keys == ["paste"])
        #expect(pasteboard.string(forType: .string) == text)
    }

    @Test(arguments: ["short", "repeated", "extraInternal"])
    func outlookRequiresTheBlankParagraphToStayAtTheEnd(_ change: String) async {
        let inserter = untouchedOutlookBody()
        let text = change == "short" ? "aa" : change == "repeated" ? String(repeating: "a", count: 80) : "a\na"
        let wrong = change == "short" ? "a\na" : change == "repeated"
            ? String(repeating: "a", count: 40) + "\n" + String(repeating: "a", count: 40) : "a\n\na\n"
        field.pastesLand = false
        field.onKey = {
            let field = MockField.shared
            field.blocks = true
            field.text = wrong
            field.select(from: wrong.utf16.count, to: wrong.utf16.count)
        }
        #expect(await inserter.insert(text) == .unknown(.readbackMismatch))
        #expect(pasteboard.string(forType: .string) == text)
    }

    @Test func outlookDoesNotGuessWhereTrailingInsertedBreaksEnd() async {
        let inserter = untouchedOutlookBody()
        field.text = "\n\n"
        field.pastesLand = false
        field.onKey = {
            let field = MockField.shared
            field.blocks = true
            // One original blank line is gone. Repeated text and the
            // merged trailing run must not hide that loss.
            field.text = "a\na\n\n\n"
            field.select(from: field.text.utf16.count, to: field.text.utf16.count)
        }
        #expect(await inserter.insert("a\na\n\n") == .unknown(.readbackMismatch))
        #expect(pasteboard.string(forType: .string) == "a\na\n\n")
    }

    @Test func outlookIgnoredPasteKeepsTheBlankBodyUnconfirmed() async {
        let inserter = untouchedOutlookBody()
        field.pastesLand = false
        #expect(await inserter.insert(String(repeating: "a", count: 80)) == .unknown(.writeUnconfirmed))
        #expect(field.text == "\n")
        #expect(field.keys == ["paste"])
    }

    @Test func anEmptyChromiumFieldWhoseReplaceRangeLandsNowhereIsPastedInto() async {
        let inserter = emptyChromiumField(hiddenPlaceholder: true)
        #expect(await inserter.insert("hello") == .inserted(.paste, clipboardRestored: true))
        #expect(field.text == "hello\n")
        #expect(field.replaceRangeWrites == 0)
        #expect(field.accessibilityWrites == 0)
        #expect(field.keys == ["paste"])
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func anEmptyChromiumFieldWithoutAHiddenPlaceholderPastesToo() async {
        // No read tells the two apart, so the route is the same.
        let inserter = emptyChromiumField()
        #expect(await inserter.insert("hello") == .inserted(.paste, clipboardRestored: true))
        #expect(field.text == "hello\n")
        #expect(field.replaceRangeWrites == 0)
    }

    @Test func anEmptyChromiumFieldHoldingNothingAtAllPastesToo() async {
        let inserter = emptyChromiumField()
        field.text = ""
        #expect(await inserter.insert("hello") == .inserted(.paste, clipboardRestored: true))
        #expect(field.text == "hello")
        #expect(field.replaceRangeWrites == 0)
    }

    @Test func anEmptyChromiumFieldPastesSeveralLinesAtTheCaret() async {
        let inserter = emptyChromiumField(hiddenPlaceholder: true)
        #expect(await inserter.insert("X\nY") == .inserted(.paste, clipboardRestored: true))
        #expect(field.text == "X\nY\n")
    }

    @Test func theSameChromiumFieldWithTextKeepsTheReplaceRange() async {
        // With text in it the caret sits in text the tree shows, and the
        // replace range lands, as it did for Alex once he had typed.
        let inserter = emptyChromiumField(hiddenPlaceholder: true)
        field.text = "Hi"
        field.selection = FieldRange(location: 2, length: 0)
        #expect(await inserter.insert(" there") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == "Hi there")
        #expect(field.keys.isEmpty)
    }

    @Test func anEmptyWebKitFieldKeepsTheReplaceRange() async {
        // WebKit's replace range wrote at the caret in the same structure.
        let inserter = emptyChromiumField()
        field.webKitPlain = true
        #expect(await inserter.insert("hello") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == "hello\n")
        #expect(field.keys.isEmpty)
    }

    @Test func anEmptyNativeFieldKeepsItsWrite() async {
        let inserter = inserter()
        field.text = ""
        field.selection = FieldRange(location: 0, length: 0)
        #expect(await inserter.insert("hello") == .inserted(.selectedText, clipboardRestored: nil))
        #expect(field.keys.isEmpty)
    }

    @Test func anEmptyChromiumFieldWhoseSelectionMovesBeforeThePasteIsNotPastedInto() async {
        let inserter = emptyChromiumField(hiddenPlaceholder: true)
        // The person clicks after the break while the field is observed.
        field.onLengthRead = { [field] count in if count == 2 { field.selection = FieldRange(location: 1, length: 0) } }
        #expect(await inserter.insert("hello") == .notInserted(.fieldChanged))
        #expect(field.keys.isEmpty)
        #expect(field.text == "\n")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func anEmptyChromiumFieldThatGainsTextBeforeThePasteKeyIsNotPastedInto() async {
        let inserter = emptyChromiumField(hiddenPlaceholder: true)
        // A letter arrives before the caret at the check right before the
        // key, the third read of the field's length, after the clipboard
        // is borrowed: the length grows and the text before the caret
        // changes, no key is posted and the clipboard goes back, which
        // its change count shows as Intention's write and the restore.
        let count = pasteboard.changeCount
        field.onLengthRead = { [field] count in if count == 3 { field.text = "a\n"; field.selection = FieldRange(location: 1, length: 0) } }
        #expect(await inserter.insert("hello") == .notInserted(.fieldChanged))
        #expect(field.keys.isEmpty)
        #expect(field.lengthReads == 3)
        #expect(pasteboard.changeCount == count + 2)
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func anEmptyChromiumFieldThatTurnsSecureBeforeThePasteKeyIsNotPastedInto() async {
        let inserter = emptyChromiumField(hiddenPlaceholder: true)
        // The third read of the placeholder ends the check right before the
        // key, after the clipboard is borrowed; the first observes the
        // field and the second ends the check before the clipboard.
        let count = pasteboard.changeCount
        afterPlaceholderRead(3, [true])
        #expect(await inserter.insert("hello") == .notInserted(.secureField))
        #expect(field.keys.isEmpty)
        #expect(field.textReadsWhileSecure == 0)
        #expect(pasteboard.changeCount == count + 2)
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func anEmptyChromiumFieldWithoutClipboardAccessLeavesThePastedTextOnTheClipboard() async {
        // The cost of the route where Intention may not read the clipboard:
        // the text replaces what was copied, and the result says so.
        let inserter = inserter(clipboardReadable: false)
        field.web = true
        field.text = "\n"
        field.selection = FieldRange(location: 0, length: 0)
        field.hiddenPlaceholder = true
        #expect(await inserter.insert("hello") == .inserted(.paste, clipboardRestored: false))
        #expect(field.text == "hello\n")
        #expect(pasteboard.string(forType: .string) == "hello")
    }

    @Test func aFieldTurningSecureIsNotReadAgain() async {
        let inserter = inserter()
        field.secureAfterWrite = true
        #expect(await inserter.insert("X") == .unknown(.secureField))
        #expect(field.textReadsWhileSecure == 0)
    }

    @Test func anAcceptedWriteThatLandsLateIsNeverPastedToo() async throws {
        let inserter = inserter()
        field.writes = .held
        #expect(await inserter.insert("X") == .unknown(.writeUnconfirmed))
        #expect(field.keys.isEmpty)
        // While it is still on its way the next insertion is refused: its
        // text could go in ahead of the write, or under it.
        field.writes = .ignore
        let writes = field.accessibilityWrites
        #expect(await inserter.insert("Y") == .notInserted(.earlierUnsettled))
        #expect(field.accessibilityWrites == writes)
        #expect(field.keys.isEmpty)
        // The app applies the write after Intention stopped waiting, and the
        // field shows it at its own place: it has landed, and the next
        // insertion goes in after it. The field is remembered, so that
        // insertion pastes without an Accessibility write.
        field.land()
        #expect(field.text == "aXbc")
        #expect(await inserter.insert("Y") == .inserted(.paste, clipboardRestored: true))
        #expect(field.accessibilityWrites == writes)
        #expect(field.text == "aXYbc")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
        // The hold has ended: the insertion after that one goes in too.
        #expect(await inserter.insert("Z") == .inserted(.paste, clipboardRestored: true))
        #expect(field.text == "aXYZbc")
    }

    /// A write the app does not answer in time may still be applied once
    /// the app catches up, so it holds the next insertion as one the field
    /// accepted and did not show does, though the field is not remembered.
    @Test func aWriteTheAppDoesNotAnswerRefusesTheNextInsertionUntilItShows() async throws {
        let inserter = inserter()
        field.writes = .unanswered
        #expect(await inserter.insert("X") == .unknown(.targetUnresponsive))
        #expect(field.text == "abc")
        let writes = field.accessibilityWrites
        #expect(await inserter.insert("Y") == .notInserted(.earlierUnsettled))
        #expect(field.accessibilityWrites == writes)
        #expect(field.keys.isEmpty)
        // The app catches up, and the write shows at its own place.
        field.land()
        #expect(field.text == "aXbc")
        field.writes = .apply
        #expect(await inserter.insert("Y") == .inserted(.selectedText, clipboardRestored: nil))
        #expect(field.text == "aXYbc")
    }

    /// Issue #326, as GPT-6-Astra's review of #298 found it: "old" is
    /// selected and replaced by a write whose effect is unknown, and the
    /// write is still on its way when the next insertion comes, two
    /// seconds on, which is when #298 let that one go in. The field still
    /// has "old" selected. Text written or pasted over it now would have
    /// the earlier write land over part of it, so it is refused, and the
    /// earlier write then lands alone.
    @Test(arguments: ["accepted", "unanswered"])
    func aWriteStillOnItsWayPastTheOldWindowHoldsTheNextInsertion(_ write: String) async throws {
        let inserter = inserter()
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        field.writes = write == "accepted" ? .held : .unanswered
        #expect(await inserter.insert("first") == (write == "accepted" ? .unknown(.writeUnconfirmed) : .unknown(.targetUnresponsive)))
        let returned = ContinuousClock.now
        // The app takes later writes at once; this one is still on its way.
        field.writes = .apply
        // Pinned here, not read from the inserter: #298's two seconds.
        try await Task.sleep(until: returned + .milliseconds(2_300))
        #expect(await inserter.insert("second") == .notInserted(.earlierUnsettled))
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
        #expect(field.text == "keep old keep")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
        field.land()
        #expect(field.text == "keep first keep")
    }

    /// The same, past ten seconds, when the first version of this fix let
    /// the next insertion paste: no wait proves the write will not land,
    /// so time never ends the hold on its own field. The field is a web
    /// page's, whose page and window holds end after ten seconds; while
    /// its own object is there, the field is held as any other. Pinned
    /// here, not read from the inserter.
    @Test func aWriteStillOnItsWayPastTenSecondsStillHoldsItsField() async throws {
        let inserter = inserter()
        field.web = true
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        field.writes = .held
        #expect(await inserter.insert("first") == .unknown(.writeUnconfirmed))
        let returned = ContinuousClock.now
        field.writes = .apply
        try await Task.sleep(until: returned + .milliseconds(10_500))
        #expect(await inserter.insert("second") == .notInserted(.earlierUnsettled))
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
        #expect(field.text == "keep old keep")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
        #expect(!AppLog.edits.contains("hold.webScopeExpired"))
        field.land()
        #expect(field.text == "keep first keep")
    }

    /// GPT-6-Astra's review of the first version: "old" is selected and
    /// replaced by a write still on its way, and the person collapses the
    /// selection to its start. The caret then follows text that ends as
    /// the write's own text does, all of it for "X" after "X", and the
    /// last 64 units, all an insertion reads before its caret, for the
    /// long one. That text was there before the write and says nothing
    /// about it: the write shows only as its whole text at its own place
    /// in a field as long as it leaves it, so the next insertion is held,
    /// and the write lands alone.
    @Test(arguments: ["short", "long"])
    func aCollapsedSelectionWhoseReplacementIsStillOnItsWayHoldsTheNextInsertion(_ length: String) async {
        let inserter = inserter()
        let written = length == "short" ? "X" : String(repeating: "y", count: 36) + String(repeating: "x", count: 63) + "!"
        let lead = length == "short" ? "X" : String(written.suffix(64))
        field.text = lead + "old"
        field.selection = FieldRange(location: lead.utf16.count, length: 3)
        field.writes = .held
        #expect(await inserter.insert(written) == .unknown(.writeUnconfirmed))
        field.selection = FieldRange(location: lead.utf16.count, length: 0)
        field.writes = .apply
        #expect(await inserter.insert("second") == .notInserted(.earlierUnsettled))
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
        #expect(field.text == lead + "old")
        field.land()
        #expect(field.text == lead + written)
        // Now it shows at its place, and the next text goes in after it.
        #expect(await inserter.insert("second") == .inserted(.paste, clipboardRestored: true))
        #expect(field.text == lead + written + "second")
    }

    /// Issue #327: a late marker write remains selected beyond the paste
    /// window. Finish its caret collapse before inserting the next words.
    /// Matching words before the write's own place do not establish landing.
    @Test(arguments: ["keep old keep", "keep firstold keep"])
    func aLateMarkerWriteStillSelectedGetsACaretBeforeTheNextInsertion(_ text: String) async throws {
        let inserter = inserter()
        field.document = true
        field.text = text
        let old = (text as NSString).range(of: "old")
        field.selection = FieldRange(location: old.location, length: old.length)
        field.writes = .held
        #expect(await inserter.insert("first") == .unknown(.writeUnconfirmed))
        let returned = ContinuousClock.now
        field.land()
        field.selection = FieldRange(location: old.location, length: 5)
        let landed = text.replacingOccurrences(of: "old", with: "first")
        #expect(field.text == landed)
        try await Task.sleep(until: returned + .milliseconds(2_300))
        #expect(await inserter.insert("second") == .inserted(.paste, clipboardRestored: true))
        #expect(field.keys == ["paste"])
        #expect(field.accessibilityWrites == 1)
        #expect(field.selectionWrites == 1)
        #expect(field.text == landed.replacingOccurrences(of: "first keep", with: "firstsecond keep"))
    }

    /// The focus and ignored cases were already safe at #340. The other
    /// mutations become reachable when a late caret collapse is attempted.
    @Test(arguments: ["focus", "ignored", "text", "secure", "markers", "focusAtMarkers", "secureAtMarkers", "selectionAtMarkers", "selectionRead", "textRead", "lengthRead"])
    func anUnconfirmedLateCaretCollapseKeepsTheNextWords(_ change: String) async {
        let inserter = inserter()
        field.document = true
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        field.writes = .held
        #expect(await inserter.insert("first") == .unknown(.writeUnconfirmed))
        field.land()
        field.selection = FieldRange(location: 5, length: 5)
        switch change {
        case "focus":
            // Focus moves during the landing read, before the collapse.
            field.onTextRead = { [field] in field.focusedElsewhere = true }
        case "ignored": field.selectionWritesIgnored = true
        case "text": field.onSelectionWrite = { [field] in field.text = "keep other keep" }
        case "secure": field.onSelectionWrite = { [field] in field.secure = true }
        case "markers": field.caretMarkersUnanswered = true
        case "focusAtMarkers": field.onCaretMarkersRead = { [field] in field.focusedElsewhere = true }
        case "secureAtMarkers": field.onCaretMarkersRead = { [field] in field.secure = true }
        case "selectionAtMarkers": field.onCaretMarkersRead = { [field] in field.selection = FieldRange(location: 0, length: 4) }
        case "selectionRead": field.onCaretMarkersRead = { [field] in field.selectionUnanswered = true }
        case "textRead": field.onSelectionWrite = { [field] in field.failingRead = FieldRange(location: 5, length: 5) }
        case "lengthRead": field.onSelectionWrite = { [field] in field.markerLengthUnanswered = true }
        default: break
        }
        #expect(await inserter.insert("second") == .notInserted(.earlierUnsettled))
        #expect(field.keys.isEmpty)
        #expect(field.accessibilityWrites == 1)
        if change == "focus" { #expect(field.selectionWrites == 0) }
        if change == "text" {
            // At #340 no collapse was attempted, so this edit did not run.
            #expect(field.text == (field.selectionWrites == 0 ? "keep first keep" : "keep other keep"))
        } else { #expect(field.text == "keep first keep") }
        #expect(field.textReadsWhileSecure == 0)
        #expect(field.editsWhileSecure == 0)
    }

    @Test(arguments: ["Hello", "don't wait", "bold and soft"])
    func aReformattedMarkerReplacementGetsACaretBeforeTheNextInsertion(_ shown: String) async {
        let inserter = inserter()
        field.document = true
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        let written = shown == "Hello" ? "hello" : shown == "don't wait" ? "dont wait" : "**bold** and _soft_"
        field.reformat = { @Sendable _ in shown }
        #expect(await inserter.insert(written) == .unknown(.readbackMismatch))
        #expect(field.selection == FieldRange(location: 5 + shown.utf16.count, length: 0))
        field.reformat = nil
        #expect(await inserter.insert("second") == .inserted(.textOperation, clipboardRestored: nil))
        #expect(field.text == "keep " + shown + "second keep")
        #expect(field.keys.isEmpty)
    }

    @Test(arguments: [false, true])
    func anImmediateMarkerReplacementWhoseCollapseDoesNotTakeHoldsTheNextWords(_ reformats: Bool) async {
        let inserter = inserter()
        field.document = true
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        field.selectionWritesIgnored = true
        if reformats { field.reformat = { @Sendable _ in "Hello" } }
        #expect(await inserter.insert("hello") == .unknown(reformats ? .readbackMismatch : .writeUnconfirmed))
        field.reformat = nil
        #expect(await inserter.insert("second") == .notInserted(.earlierUnsettled))
        #expect(field.text == (reformats ? "keep Hello keep" : "keep hello keep"))
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
    }

    /// A hold that ended without moving the caret must keep its original
    /// recheck. Reading anew would adopt this newly selected earlier text.
    @Test func aSelectionChangedDuringTheLandingReadCannotReplaceEarlierWords() async {
        let inserter = inserter()
        field.document = true
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        field.writes = .held
        #expect(await inserter.insert("first") == .unknown(.writeUnconfirmed))
        field.land()
        let reads = field.textReads
        field.onTextRead = { [field] in
            if field.textReads == reads + 3 { field.selection = FieldRange(location: 5, length: 5) }
        }
        #expect(await inserter.insert("second") == .notInserted(.fieldChanged))
        #expect(field.text == "keep first keep")
        #expect(field.keys.isEmpty)
    }

    @Test func aSelectionChangedAfterTheCollapseCannotBeAdoptedByTheFreshRead() async {
        let inserter = inserter()
        field.document = true
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        field.writes = .held
        #expect(await inserter.insert("first") == .unknown(.writeUnconfirmed))
        field.land()
        field.selection = FieldRange(location: 5, length: 5)
        field.onSelectionWrite = { [field] in
            let reads = field.focusReads
            // The collapse's confirmation asks focus twice, then the fresh
            // target read asks it. WebKit reselects its replacement there.
            field.onFocusRead = { [field] in
                if field.focusReads == reads + 3 { field.selection = FieldRange(location: 5, length: 5) }
            }
        }
        #expect(await inserter.insert("second") == .notInserted(.fieldChanged))
        #expect(field.selectionWrites == 1)
        #expect(field.text == "keep first keep")
        #expect(field.keys.isEmpty)
        #expect(field.accessibilityWrites == 1)
        // A refusal must retain the hold, so the following insertion
        // completes another checked collapse instead of replacing "first".
        field.onSelectionWrite = nil
        field.onFocusRead = nil
        #expect(await inserter.insert("third") == .inserted(.paste, clipboardRestored: true))
        #expect(field.text == "keep firstthird keep")
        #expect(field.selectionWrites == 2)
    }

    @Test(arguments: ["late", "immediate", "unanswered"])
    func aCaretChangeWhoseConfirmationFailsKeepsTheHoldAcrossALaterRefusal(_ timing: String) async {
        let inserter = inserter()
        field.document = true
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        field.writes = timing == "immediate" ? .apply : timing == "unanswered" ? .unanswered : .held
        field.onSelectionWrite = { [field] in field.failingRead = FieldRange(location: 5, length: 5) }
        #expect(await inserter.insert("first") == .unknown(timing == "unanswered" ? .targetUnresponsive : .writeUnconfirmed))
        if timing != "immediate" {
            field.land()
            field.selection = FieldRange(location: 5, length: 5)
            #expect(await inserter.insert("waiting") == .notInserted(.earlierUnsettled))
        }
        #expect(field.selection == FieldRange(location: 10, length: 0))
        field.onSelectionWrite = nil
        field.failingRead = nil
        field.writes = .apply
        let refuse: FocusedField.Guard = { [field] in
            field.selection = FieldRange(location: 5, length: 5)
            return .fieldChanged
        }
        #expect(await inserter.insert("second", finalCheck: refuse) == .notInserted(.fieldChanged))
        #expect(field.text == "keep first keep")
        #expect(field.keys.isEmpty)
        #expect(await inserter.insert("third") == .inserted(timing == "unanswered" ? .textOperation : .paste,
                                                           clipboardRestored: timing == "unanswered" ? nil : true))
        #expect(field.text == "keep firstthird keep")
        #expect(field.selectionWrites == 2)
    }

    /// Astra's third review: the confirmed caret alone cannot authorize
    /// adopting text changed during the fresh read after the collapse.
    @Test(arguments: ["inside", "before", "after", "grow", "shrink"])
    func textChangedDuringTheFreshReadAfterACollapseKeepsTheEarlierHold(_ change: String) async {
        let inserter = inserter()
        let tail = String(repeating: "z", count: 100)
        let suffix = change == "grow" || change == "shrink" ? tail : ""
        let landed = "keep first keep" + suffix
        let changed: String
        switch change {
        case "inside": changed = "keep xfirst keep"
        case "before": changed = "deep first keep"
        case "after": changed = "keep first deep"
        case "grow": changed = landed + "z"
        default: changed = String(landed.dropLast())
        }
        field.document = true
        field.text = "keep old keep" + suffix
        field.selection = FieldRange(location: 5, length: 3)
        field.writes = .held
        #expect(await inserter.insert("first") == .unknown(.writeUnconfirmed))
        field.land()
        field.selection = FieldRange(location: 5, length: 5)
        field.onSelectionWrite = { [field] in
            let reads = field.focusReads
            // Two confirmation focus reads precede the fresh target read.
            field.onFocusRead = { [field] in
                if field.focusReads == reads + 3 { field.text = changed }
            }
        }
        #expect(await inserter.insert("second") == .notInserted(.fieldChanged))
        #expect(field.selection == FieldRange(location: 10, length: 0))
        #expect(field.text == changed)
        #expect(field.text.contains("first"))
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
        // Restore the editor's text and reselect the earlier words. The
        // retained hold must collapse them again before the next paste.
        field.onSelectionWrite = nil
        field.onFocusRead = nil
        field.text = landed
        field.selection = FieldRange(location: 5, length: 5)
        #expect(await inserter.insert("third") == .inserted(.paste, clipboardRestored: true))
        #expect(field.text == "keep firstthird keep" + suffix)
        #expect(field.selectionWrites == 2)
        #expect(field.accessibilityWrites == 1)
    }

    @Test(arguments: ["paste", "direct", "finalCheck"])
    func aRefusalAfterTheFreshReadRetainsTheCollapseHold(_ route: String) async {
        let inserter = inserter()
        field.document = true
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        field.writes = route == "direct" ? .unanswered : .held
        #expect(await inserter.insert("first") == .unknown(route == "direct" ? .targetUnresponsive : .writeUnconfirmed))
        field.land()
        field.selection = FieldRange(location: 5, length: 5)
        field.writes = .apply
        let destination = await guardedField(inserter)
        let refusingCall = route == "direct" ? 2 : 3
        field.onGuard = { [field] calls in
            if route != "finalCheck", calls == refusingCall { field.selection = FieldRange(location: 5, length: 5) }
        }
        let finalCheck: FocusedField.Guard?
        if route == "finalCheck" {
            finalCheck = { [field] in
                field.selection = FieldRange(location: 5, length: 5)
                return .fieldChanged
            }
        } else { finalCheck = nil }
        #expect(await inserter.insert("second", into: destination, finalCheck: finalCheck) == .notInserted(.fieldChanged))
        #expect(field.text == "keep first keep")
        #expect(field.keys.isEmpty)
        #expect(field.accessibilityWrites == 1)
        field.onGuard = nil
        let third = await inserter.insert("third")
        #expect(third == .inserted(route == "direct" ? .textOperation : .paste, clipboardRestored: route == "direct" ? nil : true))
        #expect(field.text == "keep firstthird keep")
        #expect(field.selectionWrites == 2)
    }

    @Test func twoRefusalsAfterACollapseRetainTheEarlierWordsForTheFollowingInsertion() async {
        let inserter = inserter()
        field.document = true
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        field.writes = .held
        #expect(await inserter.insert("first") == .unknown(.writeUnconfirmed))
        field.land()
        field.selection = FieldRange(location: 5, length: 5)
        field.writes = .apply
        #expect(await inserter.insert("second", finalCheck: { .composeChanged }) == .notInserted(.composeChanged))
        #expect(field.text == "keep first keep")
        let destination = await guardedField(inserter)
        field.onGuard = { [field] calls in
            if calls == 2 { field.selection = FieldRange(location: 5, length: 5) }
        }
        #expect(await inserter.insert("third", into: destination) == .notInserted(.fieldChanged))
        #expect(field.text == "keep first keep")
        #expect(field.keys.isEmpty)
        field.onGuard = nil
        #expect(await inserter.insert("fourth") == .inserted(.paste, clipboardRestored: true))
        #expect(field.text == "keep firstfourth keep")
        #expect(field.selectionWrites == 2)
        #expect(field.accessibilityWrites == 1)
    }

    /// GPT-6-Astra's second review: words equal to the selected text,
    /// written over it, leave the field reading as it did, so the readback
    /// took the unchanged field for the write and reported it inserted,
    /// with no hold, though the app had not applied it or had not
    /// answered. The next words then went over "old", and the write landed
    /// over part of them: "keep oldond keep". The field already shows the
    /// words, so nothing is written: the insertion reports them in, and the
    /// selection stays where the person left it.
    @Test(arguments: ["accepted", "unanswered"])
    func wordsEqualToTheSelectedTextAreNotWritten(_ write: String) async {
        let inserter = inserter()
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        field.writes = write == "accepted" ? .held : .unanswered
        #expect(await inserter.insert("old") == .inserted(.selectedText, clipboardRestored: nil))
        #expect(field.accessibilityWrites == 0)
        #expect(field.keys.isEmpty)
        #expect(field.text == "keep old keep")
        #expect(field.selection == FieldRange(location: 5, length: 3))
        field.writes = .apply
        #expect(await inserter.insert("second") == .inserted(.selectedText, clipboardRestored: nil))
        field.land()
        #expect(field.text == "keep second keep")
    }

    /// The same in a web field, written by replace range, which would take
    /// the selection's offsets: nothing is written there either.
    @Test func wordsEqualToTheSelectedTextAreNotWrittenInAWebField() async {
        let inserter = inserter()
        field.web = true
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        field.writes = .held
        #expect(await inserter.insert("old") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.accessibilityWrites == 0)
        field.writes = .apply
        #expect(await inserter.insert("second") == .inserted(.replaceRange, clipboardRestored: nil))
        field.land()
        #expect(field.text == "keep second keep")
    }

    /// A write shows by all of its text at its own place, in a field as
    /// long as it leaves it, wherever the caret is. The run of one letter
    /// ends in another character, so only the whole range tells it.
    @Test func anEarlierWriteShowsByItsWholeTextAtItsOwnPlace() async throws {
        let inserter = inserter()
        let long = String(repeating: "x", count: 99) + "!"
        field.writes = .held
        #expect(await inserter.insert(long) == .unknown(.writeUnconfirmed))
        field.land()
        let landed = field.text
        #expect(landed == "a" + long + "bc")
        // One unit of it reads otherwise, in a field of the same length,
        // with the caret right after it: not shown.
        field.text = (landed as NSString).replacingCharacters(in: NSRange(location: 50, length: 1), with: "y")
        field.selection = FieldRange(location: 101, length: 0)
        #expect(await inserter.insert("Y") == .notInserted(.earlierUnsettled))
        // As written, with the caret inside it: shown, and the next text
        // goes where the caret is.
        field.text = landed
        field.selection = FieldRange(location: 50, length: 0)
        #expect(await inserter.insert("Y") == .inserted(.paste, clipboardRestored: true))
        #expect(field.text == "a" + String(repeating: "x", count: 49) + "Y" + String(repeating: "x", count: 50) + "!bc")
    }

    /// The hold is for the field the write went to. Another field of the
    /// same app has an object of its own, which the write does not name,
    /// and a field of another app is in another process; both take text at
    /// once, and text going in there does not end the hold.
    @Test func theHoldCoversTheFieldTheWriteWentToAndNoOther() async throws {
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/bin/sleep")
        other.arguments = ["60"]
        try other.run()
        defer { other.terminate() }
        let inserter = inserter()
        field.writes = .held
        #expect(await inserter.insert("X") == .unknown(.writeUnconfirmed))
        field.writes = .apply
        // Another field of the same app.
        field.focusedElement = 2
        #expect(await inserter.insert("Y") == .inserted(.selectedText, clipboardRestored: nil))
        // A field of another app.
        field.appPID = other.processIdentifier
        #expect(await inserter.insert("Y") == .inserted(.selectedText, clipboardRestored: nil))
        #expect(field.accessibilityWrites == 3)
        // Back in the first app's field, where the write is still on its
        // way. Every field here reads the one scripted text, so this one's
        // is put back as it was.
        field.appPID = nil
        field.focusedElement = 1
        field.text = "abc"
        field.selection = FieldRange(location: 1, length: 0)
        #expect(await inserter.insert("Z") == .notInserted(.earlierUnsettled))
        #expect(field.accessibilityWrites == 3)
        #expect(field.keys.isEmpty)
        field.land()
        #expect(field.text == "aXbc")
        #expect(await inserter.insert("Z") == .inserted(.paste, clipboardRestored: true))
        #expect(field.text == "aXZbc")
    }

    /// GPT-6-Astra's second review: Chrome gives the field a new
    /// Accessibility object while the editor grows from 300 points wide to
    /// 301, and the write over "old" is still on its way. Matched by its
    /// frame, the new object was another field, and the next words went
    /// over "old", for the write to land over part of them. Once the
    /// field's object is gone nothing tells which of the page's fields is
    /// its own, so the whole page is held: the new object, and every other
    /// field of the page.
    @Test(arguments: [300, 301])
    func aWebFieldsReplacedObjectHoldsItsWholePage(_ width: Int) async {
        let inserter = inserter()
        field.web = true
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        field.writes = .held
        #expect(await inserter.insert("first") == .unknown(.writeUnconfirmed))
        field.writes = .apply
        field.objectGeneration += 1
        field.frameWidth = CGFloat(width)
        #expect(await inserter.insert("second") == .notInserted(.earlierUnsettledNearby))
        // Another field of the page, with a frame of its own.
        field.focusedElement = 2
        #expect(await inserter.insert("other") == .notInserted(.earlierUnsettledNearby))
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
        #expect(field.text == "keep old keep")
        field.land()
        #expect(field.text == "keep first keep")
    }

    @Test func matchingTextInAnotherFieldCannotReleaseAPendingPagesWrite() async {
        let inserter = inserter()
        field.web = true
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        field.writes = .held
        #expect(await inserter.insert("first") == .unknown(.writeUnconfirmed))
        field.writes = .apply
        field.objectGeneration += 1
        // Field B has the same prefix, write, suffix and total length.
        // Matching content alone cannot say which field was rebuilt.
        field.focusedElement = 2
        field.text = "keep first keep"
        field.selection = FieldRange(location: 15, length: 0)
        #expect(await inserter.insert("other") == .notInserted(.earlierUnsettledNearby))
        field.focusedElement = 1
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        #expect(await inserter.insert("second") == .notInserted(.earlierUnsettledNearby))
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
        field.land()
        #expect(field.text == "keep first keep")
    }

    @Test func aMovedWebTabWhosePageReadFailsKeepsItsHold() async {
        let inserter = inserter()
        field.web = true
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        field.writes = .held
        #expect(await inserter.insert("first") == .unknown(.writeUnconfirmed))
        field.writes = .apply
        field.objectGeneration += 1
        field.windowGeneration = 1
        field.webAreaRoleUnanswered = true
        #expect(await inserter.insert("second") == .notInserted(.earlierUnsettledNearby))
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
        field.land()
        #expect(field.text == "keep first keep")
    }

    /// Greptile's PR #371 sequence. A container's failed role read sends
    /// the moved web field through the unlisted paste fallback. Its failed
    /// page walk cannot establish that it is native or outside the hold.
    @Test func aMovedWebTabAdmittedAsUnlistedKeepsItsHold() async {
        let inserter = inserter()
        field.web = true
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        field.writes = .held
        #expect(await inserter.insert("first") == .unknown(.writeUnconfirmed))
        field.writes = .apply
        field.objectGeneration += 1
        field.windowGeneration = 1
        field.containerRoleFails = true
        let fallback = try? FieldAccess.focusedTarget(ownPID: ProcessInfo.processInfo.processIdentifier).get()
        #expect(fallback?.method == .paste)
        #expect(fallback?.web == false)
        #expect(fallback?.state == nil)
        #expect(await inserter.insert("second") == .notInserted(.earlierUnsettledNearby))
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
        #expect(field.text == "keep old keep")
        field.land()
        #expect(field.text == "keep first keep")
    }

    /// The page holds no other page's fields: another tab's field, in a
    /// page whose object is there, takes text while the first page is
    /// held.
    @Test func aPageHoldLeavesOtherPagesAlone() async {
        let inserter = inserter()
        field.web = true
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        field.writes = .held
        #expect(await inserter.insert("first") == .unknown(.writeUnconfirmed))
        field.writes = .apply
        field.objectGeneration += 1
        field.pageID = -3
        field.focusedElement = 3
        #expect(await inserter.insert("other") == .inserted(.replaceRange, clipboardRestored: nil))
        field.pageID = -1
        field.focusedElement = 1
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        #expect(await inserter.insert("second") == .notInserted(.earlierUnsettledNearby))
        #expect(field.accessibilityWrites == 2)
    }

    /// Even a reformatted write shown in a rebuilt object could be text
    /// already present in another field. Only the bounded expiry can
    /// release a scope whose original field can no longer be identified.
    @Test func aWriteShownInAReplacedObjectKeepsItsPagesHold() async {
        let inserter = inserter()
        field.web = true
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        field.writes = .held
        #expect(await inserter.insert("first") == .unknown(.writeUnconfirmed))
        field.writes = .apply
        field.objectGeneration += 1
        field.frameWidth = 301
        #expect(await inserter.insert(" second") == .notInserted(.earlierUnsettledNearby))
        field.reformat = { @Sendable text in text.prefix(1).uppercased() + text.dropFirst() }
        field.land()
        field.reformat = nil
        #expect(field.text == "keep First keep")
        #expect(await inserter.insert(" second") == .notInserted(.earlierUnsettledNearby))
        #expect(field.text == "keep First keep")
        #expect(!AppLog.edits.contains("hold.webScopeExpired"))
    }

    /// GPT-6-Astra's second review: Chrome rebuilds the page's tree for the
    /// same document, as it can when its accessibility mode changes, so
    /// the page's object is gone too, and a new page object stands where it
    /// was. That may be the same document, where the write can still land,
    /// so the whole window is held, and no other. Closing the window ends
    /// the hold.
    @Test func aReplacedPageHoldsItsWindowUntilTheWindowCloses() async {
        let inserter = inserter()
        field.web = true
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        field.writes = .held
        #expect(await inserter.insert("first") == .unknown(.writeUnconfirmed))
        field.writes = .apply
        field.objectGeneration += 1
        field.pageGeneration += 1
        #expect(await inserter.insert("second") == .notInserted(.earlierUnsettledNearby))
        // Another page in the window.
        field.pageID = -3
        field.focusedElement = 3
        #expect(await inserter.insert("second") == .notInserted(.earlierUnsettledNearby))
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
        // A field in another window.
        field.windowGeneration = 1
        #expect(await inserter.insert("other") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.accessibilityWrites == 2)
        field.windowGeneration = 0
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        #expect(await inserter.insert("second") == .notInserted(.earlierUnsettledNearby))
        // The window closes, and the same page opens in another.
        field.closedWindows = [0]
        field.windowGeneration = 2
        field.pageID = -1
        field.focusedElement = 1
        #expect(await inserter.insert("second") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == "keep second keep")
        #expect(!AppLog.edits.contains("hold.webScopeExpired"))
    }

    /// The write's field, and its page, do not answer whether they are
    /// still there, as a page that is busy rebuilding its tree. Either may
    /// be gone, so the field cannot be told and the window is held: a read
    /// that did not answer is no evidence the field is the old one.
    @Test func aWebFieldWhoseObjectDoesNotAnswerHoldsItsWindow() async {
        let inserter = inserter()
        field.web = true
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        field.writes = .held
        #expect(await inserter.insert("first") == .unknown(.writeUnconfirmed))
        field.writes = .apply
        field.objectGeneration += 1
        field.identityUnanswered = true
        #expect(await inserter.insert("second") == .notInserted(.earlierUnsettledNearby))
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
        field.land()
        #expect(field.text == "keep first keep")
    }

    /// Matching case or exact text in a different object cannot release
    /// the page hold, including a write of the selection's own letters.
    @Test func aPageHoldForAWriteOfTheSameLettersKeepsHoldingMatchingText() async {
        let inserter = inserter()
        field.web = true
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        field.writes = .held
        #expect(await inserter.insert("Old") == .unknown(.writeUnconfirmed))
        field.writes = .apply
        field.objectGeneration += 1
        field.selection = FieldRange(location: 8, length: 0)
        #expect(await inserter.insert(" new") == .notInserted(.earlierUnsettledNearby))
        field.land()
        #expect(field.text == "keep Old keep")
        #expect(await inserter.insert(" new") == .notInserted(.earlierUnsettledNearby))
        #expect(field.text == "keep Old keep")
    }

    /// The coordinator's decision of October 8, 2026: where a web field's
    /// object is gone, so its page or window is held, the hold ends ten
    /// seconds after the write, since refusing every dictation into a
    /// Chrome window with no end, Gmail's among them, is worse than the
    /// overwrite it prevents. Before then the page is held; after, the
    /// next words go in, and a fixed outcome name is logged. The object is
    /// replaced at the frame the field had, which the earlier version held
    /// with no end. Ten seconds is pinned here, not read from the inserter.
    @Test func aPageHoldEndsTenSecondsAfterTheWrite() async throws {
        let inserter = inserter()
        field.web = true
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        field.writes = .held
        let started = ContinuousClock.now
        #expect(await inserter.insert("first") == .unknown(.writeUnconfirmed))
        let returned = ContinuousClock.now
        field.writes = .apply
        field.objectGeneration += 1
        // A sleep this long may otherwise wake up to a second late.
        try await Task.sleep(until: started + .milliseconds(9_500), tolerance: .milliseconds(20), clock: .continuous)
        #expect(ContinuousClock.now - started < .milliseconds(9_900))
        #expect(await inserter.insert("second") == .notInserted(.earlierUnsettledNearby))
        #expect(!AppLog.edits.contains("hold.webScopeExpired"))
        try await Task.sleep(until: returned + .milliseconds(10_500), tolerance: .milliseconds(20), clock: .continuous)
        #expect(await inserter.insert("second") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == "keep second keep")
        #expect(AppLog.edits.filter { $0 == "hold.webScopeExpired" }.count == 1)
        // The hold has ended, and logs nothing more.
        #expect(await inserter.insert(" third") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(AppLog.edits.filter { $0 == "hold.webScopeExpired" }.count == 1)
    }

    /// GPT-6.1-Sol's check of round three: on the text operation's route the
    /// ten seconds were counted from before its reads of the selection's
    /// markers, focus and the secure ancestry, which can take seconds in a
    /// slow WebKit, so the hold ended that much less than ten seconds after
    /// the write itself. Here those reads take 2.5 seconds: nine seconds
    /// after the write the window is still held, and ten and a half after
    /// it the words go in.
    @Test func aWindowHoldsTenSecondsRunFromTheTextOperationsOwnWrite() async throws {
        let inserter = inserter()
        field.document = true
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        field.writes = .held
        field.onSelectionMarkersRead = { @Sendable in
            MockField.shared.onSelectionMarkersRead = nil
            Thread.sleep(forTimeInterval: 2.5)
        }
        let started = ContinuousClock.now
        #expect(await inserter.insert("first") == .unknown(.writeUnconfirmed))
        let returned = ContinuousClock.now
        #expect(returned - started >= .milliseconds(2_500))
        field.writes = .apply
        field.objectGeneration += 1
        // The write came after the 2.5 seconds; a sleep this long may
        // otherwise wake up to a second late.
        try await Task.sleep(until: started + .milliseconds(11_500), tolerance: .milliseconds(20), clock: .continuous)
        #expect(ContinuousClock.now - started < .milliseconds(11_900))
        #expect(await inserter.insert("second") == .notInserted(.earlierUnsettledNearby))
        #expect(!AppLog.edits.contains("hold.webScopeExpired"))
        try await Task.sleep(until: returned + .milliseconds(10_500), tolerance: .milliseconds(20), clock: .continuous)
        #expect(await inserter.insert("second") == .inserted(.textOperation, clipboardRestored: nil))
        #expect(AppLog.edits.filter { $0 == "hold.webScopeExpired" }.count == 1)
    }

    /// GPT-6.1-Sol's check of round three: a page hold compared the page of
    /// a field only where it has one, so a native field in another browser
    /// window, its address bar, was refused. A field in another window is
    /// elsewhere, unless its page is the write's own; in the write's window
    /// a field that is in no page stays held, as one whose page does not
    /// answer is.
    @Test func aPageHoldLeavesNativeFieldsOfOtherWindowsAlone() async {
        let inserter = inserter()
        field.web = true
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        field.writes = .held
        #expect(await inserter.insert("first") == .unknown(.writeUnconfirmed))
        field.writes = .apply
        field.objectGeneration += 1
        // The address bar of another window.
        field.web = false
        field.windowGeneration = 1
        field.focusedElement = 2
        #expect(await inserter.insert("other") == .inserted(.selectedText, clipboardRestored: nil))
        #expect(field.accessibilityWrites == 2)
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        // The address bar of the write's own window.
        field.windowGeneration = 0
        #expect(await inserter.insert("other") == .notInserted(.earlierUnsettledNearby))
        // The write's own page, moved to another window.
        field.web = true
        field.windowGeneration = 1
        field.focusedElement = 1
        #expect(await inserter.insert("second") == .notInserted(.earlierUnsettledNearby))
        #expect(field.accessibilityWrites == 2)
        #expect(field.keys.isEmpty)
    }

    /// A native app resolves the object a write names when it handles the
    /// write, and a gone object resolves to nothing. Intention's read that
    /// finds the object gone reaches the app after the write did, so the
    /// write has been handled by then and cannot land later; the field's
    /// new object takes text. The scripted field keeps the write, which a
    /// native app would not apply to a gone object, so it is not landed.
    @Test func aNativeFieldWhoseObjectIsGoneIsNotHeld() async {
        let inserter = inserter()
        field.writes = .unanswered
        #expect(await inserter.insert("X") == .unknown(.targetUnresponsive))
        field.writes = .apply
        field.objectGeneration += 1
        #expect(await inserter.insert("Y") == .inserted(.selectedText, clipboardRestored: nil))
        #expect(field.text == "aYbc")
    }

    /// A field that accepts a write and never shows it cannot be told from
    /// one whose write is late, so it stays held; the person's words go
    /// in anywhere else, and are kept in history with Copy here.
    @Test func aWriteTheFieldIgnoresHoldsThatFieldOnly() async {
        let inserter = inserter()
        field.writes = .ignore
        #expect(await inserter.insert("X") == .unknown(.writeUnconfirmed))
        #expect(await inserter.insert("Y") == .notInserted(.earlierUnsettled))
        #expect(field.keys.isEmpty)
        #expect(field.accessibilityWrites == 1)
        field.writes = .apply
        field.focusedElement = 2
        #expect(await inserter.insert("Y") == .inserted(.selectedText, clipboardRestored: nil))
        field.focusedElement = 1
        #expect(await inserter.insert("Z") == .notInserted(.earlierUnsettled))
        #expect(field.accessibilityWrites == 2)
        #expect(field.keys.isEmpty)
    }

    /// The field changes while a write still on its way is read back: the
    /// person types at its end. The readback shows neither the write nor
    /// the field as it was, so the write's effect is unknown, and "old",
    /// which it may still land over, stays selected at its place with the
    /// text after it as it was: nothing changed there, so the next
    /// insertion is held, and the write then lands alone. With "!!" the
    /// field grows by exactly what the write would add, somewhere else.
    @Test(arguments: ["!", "!!"])
    func aWriteWhoseReadbackMismatchesHoldsTheNextInsertion(_ typed: String) async {
        let inserter = inserter()
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        field.writes = .held
        field.onEdit = { @Sendable in
            MockField.shared.onEdit = nil
            MockField.shared.text += typed
        }
        #expect(await inserter.insert("first") == .unknown(.readbackMismatch))
        field.writes = .apply
        #expect(await inserter.insert("second") == .notInserted(.earlierUnsettled))
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
        #expect(field.text == "keep old keep" + typed)
        field.land()
        #expect(field.text == "keep first keep" + typed)
    }

    /// The same at a caret in a run of one letter, the person typing past
    /// the text read after the caret: every slice there reads alike, so the
    /// text that followed the caret reads as if it had moved by any amount.
    /// Only that it still starts right at the caret tells the write has not
    /// gone in, and the next insertion is held.
    @Test func aMismatchedWriteWhosePlaceReadsAsBeforeStaysHeldInARunOfOneLetter() async {
        let inserter = inserter()
        field.text = String(repeating: "x", count: 200)
        field.selection = FieldRange(location: 50, length: 0)
        field.writes = .held
        field.onEdit = { @Sendable in
            MockField.shared.onEdit = nil
            MockField.shared.text += "!"
        }
        #expect(await inserter.insert("first") == .unknown(.readbackMismatch))
        field.writes = .apply
        #expect(await inserter.insert("second") == .notInserted(.earlierUnsettled))
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
        field.land()
        #expect(field.text == String(repeating: "x", count: 50) + "first" + String(repeating: "x", count: 150) + "!")
    }

    /// A rich editor reformats what goes in, here correcting "dont" and
    /// capitalizing the sentence: the readback does not match, but where
    /// "old" was, the text that followed it now follows something about as
    /// long as what was written, and "old" is gone. The write has landed
    /// in another form, so the next insertion into the field goes in. An
    /// editor that leaves nothing there, or far more than was written, has
    /// not shown the write, and the field stays held.
    @Test(arguments: [("Don't worry", true), ("", false), ("dont worry, as you were told before by all of them", false)])
    func aReformattingEditorsNextInsertionGoesIn(_ shown: String, _ landed: Bool) async {
        let inserter = inserter()
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        field.reformat = { @Sendable _ in shown }
        #expect(await inserter.insert("dont worry") == .unknown(.readbackMismatch))
        #expect(field.text == "keep " + shown + " keep")
        field.reformat = nil
        let caret = 5 + shown.utf16.count
        field.selection = FieldRange(location: caret, length: 0)
        #expect(await inserter.insert(" second") == (landed ? .inserted(.selectedText, clipboardRestored: nil) : .notInserted(.earlierUnsettled)))
        #expect(field.text == "keep " + shown + (landed ? " second" : "") + " keep")
    }

    /// GPT-6-Astra's second review: "old" is selected and replaced by a
    /// write still on its way, and while it is read back something else
    /// replaces "old" with text as long as the shortest or the longest
    /// reformatting the earlier version allowed. The readback matches
    /// neither the write nor the field as it was, and the text that
    /// followed "old" starts about as far on as the write is long, so that
    /// version took the write for landed in another form and held nothing:
    /// the next words went over "x" and the write landed over part of
    /// them. The text at the write's place is not the write's, so its field
    /// stays held, as it does for unrelated text as long as the write. A
    /// run of one letter, 100 units long, differs from the write only in
    /// its length. Each runs with the field ending right after " keep", and
    /// with 64 more units after it.
    @Test(arguments: [("first", "x"), ("first", "xxxxx"), ("first", "xxxxxxxxx"),
                      (String(repeating: "x", count: 100), String(repeating: "x", count: 68)),
                      (String(repeating: "x", count: 100), String(repeating: "y", count: 100)),
                      (String(repeating: "x", count: 100), String(repeating: "x", count: 132))],
          ["", String(repeating: "z", count: 64)])
    func anUnrelatedEditAtAWritesPlaceKeepsItsFieldHeld(_ write: (String, String), _ rest: String) async {
        let (written, edit) = write
        let inserter = inserter()
        field.text = "keep old keep" + rest
        field.selection = FieldRange(location: 5, length: 3)
        field.writes = .held
        let edited = "keep " + edit + " keep" + rest
        field.onEdit = { @Sendable in
            MockField.shared.onEdit = nil
            MockField.shared.text = edited
        }
        #expect(await inserter.insert(written) == .unknown(.readbackMismatch))
        field.writes = .apply
        field.selection = FieldRange(location: 5, length: edit.utf16.count)
        #expect(await inserter.insert("second") == .notInserted(.earlierUnsettled))
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
        #expect(field.text == edited)
    }

    /// A write that changes only the case of the selection has its letters,
    /// so text at its place with those letters says nothing of it. Here,
    /// while it is read back, something else turns "old" into "OLD": the
    /// earlier version took that for the write in another form and held
    /// nothing, and the next words over "OLD" would have had the write land
    /// over them. The field stays held.
    @Test func aWriteOfTheSelectionsOwnLettersIsNotToldByThem() async {
        let inserter = inserter()
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        field.writes = .held
        field.onEdit = { @Sendable in
            MockField.shared.onEdit = nil
            MockField.shared.text = "keep OLD keep"
        }
        #expect(await inserter.insert("Old") == .unknown(.readbackMismatch))
        field.writes = .apply
        #expect(await inserter.insert("new") == .notInserted(.earlierUnsettled))
        #expect(field.accessibilityWrites == 1)
        #expect(field.text == "keep OLD keep")
    }

    /// Rich editors reformat what goes in: they change case, curl quotes,
    /// correct a word, collapse spaces and turn markdown into formatting.
    /// The readback does not match, but the text now at the write's place
    /// is the write's, letter for letter or within an editor's correction,
    /// so it has landed and the next words go in. At the field's end, with
    /// nothing after the caret, Greptile found that the earlier version
    /// held every one of these: "hello" becoming "Hello" there left the
    /// field held.
    @Test(arguments: [("hello there", "Hello there"), ("it's \"fine\"", "it\u{2019}s \u{201C}fine\u{201D}"),
                      ("see you tomorow", "see you tomorrow"), ("one  two ", "one two"),
                      ("**bold** and _soft_", "bold and soft")])
    func aWriteAnEditorReformattedAtTheFieldsEndHasLanded(_ written: String, _ shown: String) async {
        let inserter = inserter()
        field.text = "Note: "
        field.selection = FieldRange(location: 6, length: 0)
        field.reformat = { @Sendable _ in shown }
        #expect(await inserter.insert(written) == .unknown(.readbackMismatch))
        #expect(field.text == "Note: " + shown)
        field.reformat = nil
        #expect(await inserter.insert(" second") == .inserted(.selectedText, clipboardRestored: nil))
        #expect(field.text == "Note: " + shown + " second")
    }

    @Test(arguments: [("straße", "STRASSE"),
                      ("ﬃﬃﬃﬃﬃ", "FFIFFIFFIFFIFFI"), ("SSSSSSSSSS", "ßßßßß")])
    func aCaseFoldedExpansionHasLanded(_ written: String, _ shown: String) async {
        let inserter = inserter()
        field.text = "Note: "
        field.selection = FieldRange(location: 6, length: 0)
        field.reformat = { @Sendable _ in shown }
        #expect(await inserter.insert(written) == .unknown(.readbackMismatch))
        field.reformat = nil
        #expect(await inserter.insert(" second") == .inserted(.selectedText, clipboardRestored: nil))
        #expect(field.text == "Note: " + shown + " second")
    }

    /// A short correction cannot establish that the write landed. Keep
    /// the field held even when the editor actually applied that correction.
    @Test(arguments: [false, true])
    func aShortAutocorrectionKeepsTheFieldHeld(_ web: Bool) async {
        let inserter = inserter()
        field.web = web
        field.text = "Note: "
        field.selection = FieldRange(location: 6, length: 0)
        field.reformat = { @Sendable _ in "the" }
        #expect(await inserter.insert("teh") == .unknown(.readbackMismatch))
        field.reformat = nil
        #expect(await inserter.insert(" second") == .notInserted(.earlierUnsettled))
        #expect(field.text == "Note: the")
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
    }

    /// Astra's PR #371 sequence, at every short length that gained an
    /// allowance. An unrelated one-letter edit must leave the pending
    /// write held, so its eventual landing cannot overwrite later words.
    @Test(arguments: [("dog", "cat", "car"), ("dogs", "cats", "cars"),
                      ("doggy", "catty", "carty"), ("doggie", "catnap", "carnap"),
                      ("doggies", "catalog", "caralog")], [false, true])
    func aPendingShortWriteStaysHeldAfterAOneLetterEdit(_ words: (String, String, String), _ web: Bool) async {
        let (original, written, edit) = words
        let inserter = inserter()
        field.web = web
        field.text = "keep " + original + " keep"
        field.selection = FieldRange(location: 5, length: original.utf16.count)
        field.writes = .held
        let edited = "keep " + edit + " keep"
        field.onEdit = { [field] in field.text = edited }
        #expect(await inserter.insert(written) == .unknown(.readbackMismatch))
        field.onEdit = nil
        field.writes = .apply
        field.selection = FieldRange(location: 5, length: edit.utf16.count)
        #expect(await inserter.insert("second") == .notInserted(.earlierUnsettled))
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
        #expect(field.text == edited)
        field.land()
        #expect(field.text == "keep " + written + " keep")
    }

    /// Folding can expand a short write past eight letters. It still needs
    /// an exact folded match, even with one unrelated letter changed.
    @Test(arguments: [3, 4, 5, 6, 7], [false, true])
    func aPendingShortFoldedWriteStaysHeldAfterAOneLetterEdit(_ length: Int, _ web: Bool) async {
        let written = String(repeating: "ﬃ", count: length)
        let edit = String(repeating: "FFI", count: length - 1) + "FFX"
        let inserter = inserter()
        field.web = web
        field.text = "keep " + String(repeating: "z", count: edit.utf16.count) + " keep"
        field.selection = FieldRange(location: 5, length: edit.utf16.count)
        field.writes = .held
        let edited = "keep " + edit + " keep"
        field.onEdit = { [field] in field.text = edited }
        #expect(await inserter.insert(written) == .unknown(.readbackMismatch))
        field.onEdit = nil
        field.writes = .apply
        field.selection = FieldRange(location: 5, length: edit.utf16.count)
        #expect(await inserter.insert("second") == .notInserted(.earlierUnsettled))
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
        #expect(field.text == edited)
    }

    /// Folding expands the comparison, never the correction allowance.
    /// At eight original letters two edits must stay held; at sixteen and
    /// seventeen, three must. The first case is Astra's PR #371 sequence.
    @Test(arguments: [("ﬃﬃﬃﬃabcd", "ﬃﬃﬃﬃabxy"),
                      (String(repeating: "ß", count: 8), String(repeating: "SS", count: 7) + "XY"),
                      (String(repeating: "ﬃ", count: 12) + "abcd", String(repeating: "ﬃ", count: 12) + "axyz"),
                      (String(repeating: "ß", count: 12) + "abcd", String(repeating: "ß", count: 12) + "axyz"),
                      (String(repeating: "ﬃ", count: 13) + "abcd", String(repeating: "ﬃ", count: 13) + "axyz"),
                      (String(repeating: "ß", count: 13) + "abcd", String(repeating: "ß", count: 13) + "axyz")], [false, true])
    func aPendingExpandingWriteKeepsItsOriginalLetterBudget(_ words: (String, String), _ web: Bool) async {
        let (written, edit) = words
        let inserter = inserter()
        field.web = web
        let original = String(repeating: "z", count: edit.utf16.count)
        // Leave enough tail for the longer held range even if the broken
        // version permits the later replacement before this write lands.
        let tail = " keep" + (original.utf16.count > 8 ? String(repeating: "k", count: 32) : "")
        field.text = "keep " + original + tail
        field.selection = FieldRange(location: 5, length: original.utf16.count)
        field.writes = .held
        let edited = "keep " + edit + tail
        field.onEdit = { [field] in field.text = edited }
        #expect(await inserter.insert(written) == .unknown(.readbackMismatch))
        field.onEdit = nil
        field.writes = .apply
        field.selection = FieldRange(location: 5, length: edit.utf16.count)
        #expect(await inserter.insert("second") == .notInserted(.earlierUnsettled))
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
        #expect(field.text == edited)
        field.land()
        #expect(field.text == "keep " + written + tail)
    }

    /// A pending replacement and a nearby selection can both reach the
    /// same shown text within the landing allowance. That text must not
    /// retire the write before it lands, on either insertion route.
    @Test(arguments: [("Straße beim Laden", "Straße beim Hafen", "Straße beim Haden"),
                      ("Strase beim Laden", "Strase beim Hafen", "Strase beim Haden"),
                      ("Street by the ladxer", "Street by the harbor", "Street by the hadxor"),
                      ("ﬃﬃﬃﬃabxy", "ﬃﬃﬃﬃabcd", "ﬃﬃﬃﬃabcy")], [false, true])
    func aNearbySelectionEditKeepsThePendingReplacementHeld(_ words: (String, String, String), _ web: Bool) async {
        let (original, written, edit) = words
        let inserter = inserter()
        field.web = web
        let tail = " keep" + String(repeating: "k", count: 32)
        field.text = "keep " + original + tail
        field.selection = FieldRange(location: 5, length: original.utf16.count)
        field.writes = .held
        let edited = "keep " + edit + tail
        field.onEdit = { [field] in field.text = edited }
        #expect(await inserter.insert(written) == .unknown(.readbackMismatch))
        field.onEdit = nil
        field.writes = .apply
        field.selection = FieldRange(location: 5, length: edit.utf16.count)
        #expect(await inserter.insert("second") == .notInserted(.earlierUnsettled))
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
        #expect(field.text == edited)
        field.land()
        #expect(field.text == "keep " + written + tail)
    }

    /// Swapping neighbours is one landing edit. The restricted swap
    /// distance is not a metric: CA to AC and AC to ABC cost one each,
    /// while CA to ABC costs three. Padding makes the allowance one.
    @Test(arguments: [("Straße beim Hafen", "Straße beim Laden", "Straße beim Haden", 1),
                      ("Strase beim Hafen", "Strase beim Laden", "Strase beim Haden", 1),
                      ("Street by the harbor", "Street by the ladxer", "Street by the hadxor", 2),
                      ("ﬃﬃﬃﬃabcd", "ﬃﬃﬃﬃabxy", "FFIFFIFFIFFIabcy", 1),
                      ("xxxxxxCA", "xxxxxxABC", "xxxxxxAC", 1)])
    func overlappingLandingCorrectionsCannotDistinguishTheSelection(_ words: (String, String, String, Int)) {
        let (written, original, shown, allowance) = words
        let shape = Reformatting(written)
        #expect(shape.allowance == allowance)
        #expect(shape.places(in: shown).contains(shown.utf16.count))
        let originalLetters = FieldEdit.letters(original), shownLetters = FieldEdit.letters(shown)
        #expect(FieldEdit.distances(originalLetters, toPrefixesOf: shownLetters, limit: allowance)[shownLetters.count] <= allowance)
        #expect(!shape.differs(from: original))
    }

    @Test(arguments: [("abcdefgh", "abcdWXYZ", "abcVWXYZ"),
                      ("ßßßßabcd", "ßßßßwxyz", "ßßßsVwxyz"),
                      ("ﬃﬃﬃﬃabcd", "ﬃﬃﬃﬃwxyz", "ﬃﬃﬃﬂwxyz")])
    func selectionDistinctionRequiresMoreThanFourOrdinaryEdits(_ words: (String, String, String)) {
        let (written, boundary, beyond) = words
        let shape = Reformatting(written)
        #expect(shape.allowance == 1)
        #expect(!shape.differs(from: boundary))
        #expect(shape.differs(from: beyond))
    }

    /// Both matching entry points use the budget for the original letters
    /// and digits. Folding still permits expanded and contracted forms,
    /// including a correction within that budget and their length bounds.
    nonisolated private static let expandingCorrections: [(String, String, String, Int)] = [("ﬃﬃﬃﬃabcd", "FFIFFIFFIFFIabcx", "FFIFFIFFIFFIabxy", 1),
                      (String(repeating: "ß", count: 8), String(repeating: "SS", count: 7) + "SX",
                       String(repeating: "SS", count: 7) + "XY", 1),
                      (String(repeating: "ﬃ", count: 12) + "abcd", String(repeating: "FFI", count: 12) + "abxy",
                       String(repeating: "FFI", count: 12) + "axyz", 2),
                      (String(repeating: "ß", count: 12) + "abcd", String(repeating: "SS", count: 12) + "abxy",
                       String(repeating: "SS", count: 12) + "axyz", 2),
                      (String(repeating: "ﬃ", count: 13) + "abcd", String(repeating: "FFI", count: 13) + "abxy",
                       String(repeating: "FFI", count: 13) + "axyz", 2),
                      (String(repeating: "ß", count: 13) + "abcd", String(repeating: "SS", count: 13) + "abxy",
                       String(repeating: "SS", count: 13) + "axyz", 2),
                      ("ﬃß 12-34 ab", "FFISS 12-34 ax", "FFISS 12-34 xy", 1)]

    @Test(arguments: expandingCorrections)
    func anExpandingWriteUsesItsOriginalLetterBudget(_ words: (String, String, String, Int)) {
        let (written, corrected, unrelated, allowance) = words
        let shape = Reformatting(written)
        #expect(shape.allowance == allowance)
        #expect(shape.shows(corrected))
        #expect(shape.places(in: corrected).contains(corrected.utf16.count))
        #expect(!shape.shows(unrelated))
        #expect(!shape.places(in: unrelated).contains(unrelated.utf16.count))
        let contracted = corrected.replacingOccurrences(of: "FFI", with: "ﬃ").replacingOccurrences(of: "SS", with: "ß")
        #expect(shape.shows(contracted))
        #expect(shape.places(in: contracted).contains(contracted.utf16.count))
        for shown in [corrected, contracted] {
            #expect(shown.utf16.count >= max(0, written.utf16.count - shape.shorter))
            #expect(shown.utf16.count <= written.utf16.count + shape.longer)
        }
    }

    @Test(arguments: [("teh", "xyz"), ("at", "ax"), ("a", "b"), ("123", "124")])
    func anUnrelatedShortEditKeepsTheWriteHeld(_ written: String, _ shown: String) async {
        let inserter = inserter()
        field.text = "Note: "
        field.selection = FieldRange(location: 6, length: 0)
        field.writes = .held
        field.onEdit = { [field] in field.text = "Note: " + shown }
        #expect(await inserter.insert(written) == .unknown(.readbackMismatch))
        field.onEdit = nil
        field.writes = .apply
        field.selection = FieldRange(location: 6 + shown.utf16.count, length: 0)
        #expect(await inserter.insert(" second") == .notInserted(.earlierUnsettled))
        #expect(field.text == "Note: " + shown)
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
    }

    /// Greptile's and GPT-6.1-Sol's checks of round three: words that start
    /// with the selected text, "**old news**" over "old", shown as "old
    /// news", left the selection's own text at the place, which the earlier
    /// version took for the write still on its way, so the field stayed
    /// held with no end. What counts is the write's own text there,
    /// followed by the text that followed the selection, so it has landed
    /// and the next words go in. At the field's end and in its middle.
    @Test(arguments: ["", " " + String(repeating: "z", count: 64)])
    func aWriteThatStartsWithTheSelectedTextHasLandedInAnotherForm(_ rest: String) async {
        let inserter = inserter()
        field.text = "keep old keep" + rest
        field.selection = FieldRange(location: 5, length: 3)
        field.reformat = { @Sendable _ in "old news" }
        #expect(await inserter.insert("**old news**") == .unknown(.readbackMismatch))
        #expect(field.text == "keep old news keep" + rest)
        field.reformat = nil
        #expect(await inserter.insert(" second") == .inserted(.selectedText, clipboardRestored: nil))
        #expect(field.text == "keep old news second keep" + rest)
    }

    /// The same write still on its way, while something else leaves "old"
    /// and types another continuation after it: the text at the place is
    /// not the write's, so the field stays held.
    @Test(arguments: ["", " " + String(repeating: "z", count: 64)])
    func aWriteThatStartsWithTheSelectedTextStaysHeldBehindAnotherContinuation(_ rest: String) async {
        let inserter = inserter()
        field.text = "keep old keep" + rest
        field.selection = FieldRange(location: 5, length: 3)
        field.writes = .held
        let edited = "keep old stuff keep" + rest
        field.onEdit = { @Sendable in
            MockField.shared.onEdit = nil
            MockField.shared.text = edited
        }
        #expect(await inserter.insert("**old news**") == .unknown(.readbackMismatch))
        field.writes = .apply
        field.selection = FieldRange(location: 14, length: 0)
        #expect(await inserter.insert(" second") == .notInserted(.earlierUnsettled))
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
        #expect(field.text == edited)
    }

    /// Markdown turned into formatting can drop more than the earlier
    /// version's 32 units, as ten bold items do, 40 units of asterisks, in
    /// the middle of a field. Every letter and digit of the write stands
    /// at its place, so it has landed.
    @Test func aLongWriteWhoseMarkdownBecameFormattingHasLanded() async {
        let inserter = inserter()
        let rest = " " + String(repeating: "z", count: 70)
        field.text = "keep old" + rest
        field.selection = FieldRange(location: 5, length: 3)
        let written = (1...10).map { "**item \($0)**" }.joined(separator: " ")
        let shown = written.replacingOccurrences(of: "**", with: "")
        field.reformat = { @Sendable _ in shown }
        #expect(await inserter.insert(written) == .unknown(.readbackMismatch))
        #expect(field.text == "keep " + shown + rest)
        field.reformat = nil
        #expect(await inserter.insert(" second") == .inserted(.selectedText, clipboardRestored: nil))
        #expect(field.text == "keep " + shown + " second" + rest)
    }

    /// The field does not answer that it is not secure when the write is
    /// read back, so the readback is withheld and the write's effect is
    /// unknown. Accepted, it is reported as before; unanswered, it was
    /// refused as if nothing had been written, though it may still land.
    /// Either way the next insertion is held, and the write lands alone.
    @Test(arguments: ["accepted", "unanswered"])
    func aWriteWhoseReadbackIsWithheldHoldsTheNextInsertion(_ write: String) async {
        let inserter = inserter()
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        field.writes = write == "accepted" ? .held : .unanswered
        field.onEdit = { @Sendable in
            MockField.shared.onEdit = nil
            MockField.shared.secureAnswers = [nil]
        }
        #expect(await inserter.insert("first") == .unknown(write == "accepted" ? .secureField : .targetUnresponsive))
        field.writes = .apply
        #expect(await inserter.insert("second") == .notInserted(.earlierUnsettled))
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
        #expect(field.text == "keep old keep")
        field.land()
        #expect(field.text == "keep first keep")
    }

    /// Chromium reports a CSS placeholder as the editor's text, with the
    /// caret after it, and accepts a replace range there that changes
    /// nothing (support matrix, October 7, 2026). Its static text lists no
    /// editable ancestor, so the editor takes the paste, and no
    /// write that could still land is issued. The words are spaced for an
    /// empty field, and the paste is read back against one.
    @Test func aChromiumEditorShowingACSSPlaceholderTakesThePaste() async {
        let inserter = inserter()
        field.web = true
        field.generatedPlaceholder = true
        field.text = "Synthetic placeholder"
        field.selection = FieldRange(location: 21, length: 0)
        let (result, written) = await inserter.insert("Hello.", spaced: true)
        #expect(result == .inserted(.paste, clipboardRestored: true))
        #expect(written == "Hello.")
        #expect(field.replaceRangeWrites == 0)
        #expect(field.accessibilityWrites == 0)
        #expect(field.text == "Hello.")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    /// The walk that tells a placeholder does not answer: the editor takes
    /// the paste, since a replace range could be ignored, and its text is
    /// still taken as the field's own for spacing and the readback.
    @Test func aChromiumEditorWhoseTextCannotBeToldFromAPlaceholderTakesThePaste() async {
        let inserter = inserter()
        field.web = true
        field.generatedUnanswered = true
        field.text = "Draft"
        field.selection = FieldRange(location: 5, length: 0)
        let (result, written) = await inserter.insert("reply", spaced: true)
        #expect(result == .inserted(.paste, clipboardRestored: true))
        #expect(written == " reply")
        #expect(field.replaceRangeWrites == 0)
        #expect(field.text == "Draft reply")
    }

    @Test func aRefusedWriteFallsBackToPasteAndRestoresTheClipboard() async {
        let inserter = inserter()
        field.writes = .refuse
        #expect(await inserter.insert("X") == .inserted(.paste, clipboardRestored: true))
        #expect(field.text == "aXbc")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func withoutClipboardAccessThePastedTextReplacesTheClipboard() async {
        let inserter = inserter(clipboardReadable: false)
        field.writes = .refuse
        #expect(await inserter.insert("X") == .inserted(.paste, clipboardRestored: false))
        #expect(pasteboard.string(forType: .string) == "X")
    }

    @Test func aPasteOverASelectionWithoutClipboardAccessLeavesThePastedText() async {
        let inserter = inserter(clipboardReadable: false)
        field.text = "private source"
        field.selection = FieldRange(location: 0, length: 14)
        field.writes = .refuse
        #expect(await inserter.insert("replacement") == .inserted(.paste, clipboardRestored: false))
        #expect(field.text == "replacement")
        #expect(pasteboard.string(forType: .string) == "replacement")
    }

    @Test func aPasteOverASelectionRestoresTheClipboard() async {
        let inserter = inserter()
        field.text = "plain source"
        field.selection = FieldRange(location: 0, length: 12)
        field.writes = .refuse
        #expect(await inserter.insert("replacement") == .inserted(.paste, clipboardRestored: true))
        #expect(field.text == "replacement")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func anUnconfirmedPasteKeepsOtherClipboardWritesWaiting() async {
        _ = inserter()
        let owner = PasteboardOwner(pasteboard: pasteboard, mayRead: { true })
        let inserter = TextInserter(pasteboard: owner)
        field.writes = .refuse
        // The app has not read the text off the clipboard yet; a copy from
        // history now could be what it pastes.
        field.pastesLand = false
        #expect(await inserter.insert("replacement") == .unknown(.writeUnconfirmed))
        #expect(!owner.copy("an older dictation"))
        #expect(pasteboard.string(forType: .string) == "replacement")
    }

    @Test(arguments: [false, true])
    func checkRecordsOnlyAnUnknownInsertionThatBorrowedTheClipboard(paste: Bool) async throws {
        let inserter = inserter()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("intention-outcome-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = InsertionCheckClipboard.Run(file: .init(url: directory.appendingPathComponent("clipboard.json")))
        // The check records this before playback. A person copies during
        // playback, then an Accessibility write or a paste is unconfirmed.
        let beforeRecording = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString("copied during playback", forType: .string)
        field.writes = paste ? .refuse : .ignore
        field.pastesLand = false
        let result = await inserter.insert("replacement")
        #expect(result == .unknown(.writeUnconfirmed))
        #expect(inserter.clipboardRestorationPending == paste)
        #expect(pasteboard.changeCount != beforeRecording)
        run.recordInsertion(result, with: inserter)
        #expect(run.pasteUnconfirmed == paste)
        #expect(await run.mayPrepareSentinel(inserters: [inserter]) == !paste)
        #expect(pasteboard.string(forType: .string) == "copied during playback")
    }

    @Test(arguments: [false, true])
    func checkCleanupWaitsForEveryInserterBeforeRestoringThePersonsClipboard(cleanupDelayed: Bool) async throws {
        let first = inserter()
        let owner = PasteboardOwner(pasteboard: pasteboard, mayRead: { true })
        let saved = try #require(await owner.backUp().snapshot)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("intention-cleanup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = InsertionCheckClipboard.RecoveryFile(url: directory.appendingPathComponent("clipboard.json"))
        try file.save(saved, sentinels: ["sentinel"], changeCount: saved.changeCount)
        pasteboard.clearContents()
        pasteboard.setString("sentinel", forType: .string)
        field.unreadable = true
        #expect(await first.insert("first paste") == .unknown(.unreadableField))

        let secondBoard = NSPasteboard(name: .init("co.intention.tests.\(UUID())"))
        defer { secondBoard.releaseGlobally() }
        secondBoard.clearContents()
        secondBoard.setString("second sentinel", forType: .string)
        field.pasteboard = secondBoard
        let second = TextInserter(pasteboard: PasteboardOwner(pasteboard: secondBoard, mayRead: { true }))
        #expect(await second.insert("second paste") == .unknown(.unreadableField))
        if cleanupDelayed { try await Task.sleep(for: TextInserter.lateReadWindow + .milliseconds(300)) }
        let outcome = try await InsertionCheckClipboard.cleanUp(saved, file: file, inserters: [first, second],
            sentinels: ["sentinel"], pastedStrings: ["first paste"],
            read: {
                // These assertions hold whether cleanup starts immediately
                // or scheduling lets both restoration deadlines pass first.
                #expect(!first.clipboardRestorationPending)
                #expect(!second.clipboardRestorationPending)
                #expect(pasteboard.string(forType: .string) == "sentinel")
                #expect(secondBoard.string(forType: .string) == "second sentinel")
                return await owner.backUp()
            }, restore: { owner.restore($0, ifUnchangedSince: $1) })
        #expect(outcome == .restored)
        #expect(!first.clipboardRestorationPending)
        #expect(!second.clipboardRestorationPending)
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
        #expect(secondBoard.string(forType: .string) == "second sentinel")
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
    }

    @Test(arguments: [false, true])
    func checkPreparationWaitsForEveryInserterOrStopsAtItsDeadline(timesOut: Bool) async throws {
        let first = inserter()
        let owner = PasteboardOwner(pasteboard: pasteboard, mayRead: { true })
        let saved = try #require(await owner.backUp().snapshot)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("intention-preparation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = InsertionCheckClipboard.RecoveryFile(url: directory.appendingPathComponent("clipboard.json"))
        let run = InsertionCheckClipboard.Run(file: file)
        #expect(try await run.prepareSentinel(current: saved, ownsCurrent: false,
            sentinels: ["sentinel"], currentChangeCount: { pasteboard.changeCount }))
        let bytes = try Data(contentsOf: file.url)
        pasteboard.clearContents()
        pasteboard.setString("sentinel", forType: .string)
        field.unreadable = true
        #expect(await first.insert("first paste") == .unknown(.unreadableField))
        let secondBoard = NSPasteboard(name: .init("co.intention.tests.\(UUID())"))
        defer { secondBoard.releaseGlobally() }
        secondBoard.clearContents()
        secondBoard.setString("second sentinel", forType: .string)
        field.pasteboard = secondBoard
        let second = TextInserter(pasteboard: PasteboardOwner(pasteboard: secondBoard, mayRead: { true }))
        #expect(await second.insert("second paste") == .unknown(.unreadableField))
        #expect(first.clipboardRestorationPending)
        #expect(second.clipboardRestorationPending)
        let timeout = timesOut ? Duration.milliseconds(20) : TextInserter.lateReadWindow + .seconds(1)
        #expect(await run.mayPrepareSentinel(inserters: [first, second], timeout: timeout) == !timesOut)
        #expect(run.stopped == timesOut)
        if !timesOut {
            #expect(!first.clipboardRestorationPending)
            #expect(!second.clipboardRestorationPending)
            #expect(pasteboard.string(forType: .string) == "sentinel")
            #expect(secondBoard.string(forType: .string) == "second sentinel")
        }
        #expect(try Data(contentsOf: file.url) == bytes)
        // Let production restore tasks finish before releasing test boards.
        if first.clipboardRestorationPending || second.clipboardRestorationPending {
            try await Task.sleep(for: TextInserter.lateReadWindow + .milliseconds(100))
        }
    }

    @Test func anUnconfirmedPastePutsTheClipboardBackOnceTheAppCouldHaveReadIt() async throws {
        let inserter = inserter()
        field.writes = .refuse
        field.pastesLand = false
        #expect(await inserter.insert("replacement") == .unknown(.writeUnconfirmed))
        #expect(pasteboard.string(forType: .string) == "replacement")
        try await Task.sleep(for: .milliseconds(2_300))
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func aCopyMadeAfterAnUnconfirmedPasteIsNotPutBackOver() async throws {
        let inserter = inserter()
        field.unreadable = true
        #expect(await inserter.insert("hello") == .unknown(.unreadableField))
        // The person copies something while the app could still read the paste.
        pasteboard.clearContents()
        pasteboard.setString("copied since", forType: .string)
        try await Task.sleep(for: .milliseconds(2_300))
        #expect(pasteboard.string(forType: .string) == "copied since")
    }

    @Test func twoUnconfirmedPastesInARowPutThePersonsClipboardBack() async throws {
        let inserter = inserter()
        field.unreadable = true
        #expect(await inserter.insert("first") == .unknown(.unreadableField))
        #expect(await inserter.insert("second") == .unknown(.unreadableField))
        #expect(pasteboard.string(forType: .string) == "second")
        try await Task.sleep(for: .milliseconds(2_300))
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    /// The app an unconfirmed paste went to reads the clipboard late,
    /// within the window, while the next insertion waits: it finds the
    /// earlier text, never the next, and the next goes in after it once
    /// the person's copy is back, putting that copy back at once itself.
    @Test func aPasteRightAfterAnUnconfirmedOneWaitsUntilThatAppCanNoLongerReadTheClipboard() async throws {
        let inserter = inserter()
        field.writes = .refuse
        field.pastesLand = false
        #expect(await inserter.insert("first") == .unknown(.writeUnconfirmed))
        let returned = ContinuousClock.now
        field.pastesLand = true
        let late = Task { [pasteboard, field] in
            try? await Task.sleep(until: returned + .milliseconds(1_500))
            let read = pasteboard.string(forType: .string)
            field.type(read ?? "")
            return read
        }
        #expect(await inserter.insert("second") == .inserted(.paste, clipboardRestored: true))
        #expect(ContinuousClock.now - returned >= .seconds(2))
        #expect(await late.value == "first")
        #expect(field.text == "afirstsecondbc")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    /// The wait holds an insertion that ends up refused too: nothing of the
    /// clipboard is touched before the earlier paste's window has passed.
    @Test func anInsertionAfterAnUnconfirmedPasteTouchesTheClipboardOnlyOnceItsWindowHasPassed() async throws {
        let inserter = inserter()
        field.writes = .refuse
        field.pastesLand = false
        #expect(await inserter.insert("first") == .unknown(.writeUnconfirmed))
        let returned = ContinuousClock.now
        field.pastesLand = true
        let captured = await guardedField(inserter)
        // Refused before the key, once the clipboard holds this paste's text.
        nonisolated(unsafe) var refusedAt: ContinuousClock.Instant?
        field.guardAnswer = { calls in
            guard calls == 4 else { return nil }
            refusedAt = .now
            return .composeChanged
        }
        #expect(await inserter.insert("second", into: captured) == .notInserted(.composeChanged))
        #expect(try #require(refusedAt) - returned >= .seconds(2))
        #expect(field.keys == ["paste"])
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func aCopyBetweenTwoUnconfirmedPastesIsWhatComesBack() async throws {
        let inserter = inserter()
        field.unreadable = true
        #expect(await inserter.insert("first") == .unknown(.unreadableField))
        pasteboard.clearContents()
        pasteboard.setString("copied between", forType: .string)
        #expect(await inserter.insert("second") == .unknown(.unreadableField))
        try await Task.sleep(for: .milliseconds(2_300))
        #expect(pasteboard.string(forType: .string) == "copied between")
    }

    // MARK: - Every app

    @Test func textThatReportsNoWriteGetsAPasteAsTerminalsDoes() async {
        let inserter = inserter()
        // Terminal's text area reports only its selection range as settable.
        field.settable = false
        #expect(await inserter.insert("ls") == .inserted(.paste, clipboardRestored: true))
        #expect(field.text == "alsbc")
        #expect(field.accessibilityWrites == 0)
        #expect(field.keys == ["paste"])
    }

    @Test func readOnlyTextWhoseSelectionCannotBeSetIsNoTextBox() async {
        let inserter = inserter()
        field.settable = false
        field.rangeSettable = false
        #expect(await inserter.insert("x") == .notInserted(.noTextField))
        #expect(field.keys.isEmpty)
    }

    @Test func lineBreaksGoIntoATerminalAsSpacesSoNothingRuns() async {
        let inserter = inserter()
        field.settable = false
        #expect(await inserter.insert("ls\n  rm -rf build\n\n") == .inserted(.paste, clipboardRestored: true))
        #expect(field.text == "als rm -rf build bc")
    }

    @Test func aPasteIntoAnAppWithNoAccessibleTextHasNoLineBreaks() async {
        let inserter = inserter()
        field.focused = false
        field.bareWindow = true
        // The scripted app takes the paste into its text.
        #expect(await inserter.insert(" one\ntwo") == .unknown(.unreadableField))
        #expect(field.text == "a one twobc")
    }

    @Test func aButtonInAWindowThatExposesNoTextIsNoTextBox() async {
        let inserter = inserter()
        field.role = kAXButtonRole
        field.selectionUnanswered = true
        field.bareWindow = true
        #expect(await inserter.insert("x") == .notInserted(.noTextField))
        #expect(field.keys.isEmpty)
    }

    @Test func aCustomEditorThatHasASelectionGetsAPasteThatIsNeverRead() async {
        let inserter = inserter()
        // A code editor that draws its own text and exposes it as a group.
        // How it counts its text is not known, so nothing of it is read.
        field.role = "AXGroup"
        field.web = true
        field.blocks = true
        field.text = "ab\ncd"
        field.selection = FieldRange(location: 3, length: 0)
        field.namesUnanswered = true
        #expect(await inserter.insert("x") == .unknown(.unreadableField))
        #expect(field.keys == ["paste"])
        #expect(field.accessibilityWrites == 0)
        #expect(field.lengthReads == 0)
    }

    @Test func aFieldWhoseRoleSaysSecureIsAPasswordField() async {
        let inserter = inserter()
        field.role = kAXSecureTextFieldSubrole
        #expect(await inserter.insert("x") == .notInserted(.secureField))
        #expect(field.keys.isEmpty)
        #expect(field.textReadsWhileSecure == 0)
    }

    @Test func aPasteWithNothingFocusedStopsWhenAnotherAppTakesFocus() async {
        let inserter = inserter()
        field.focused = false
        field.bareWindow = true
        // After the target is found, another app that also answers that
        // nothing has focus comes in front.
        field.onFocusRead = { [field] in if field.focusReads >= 2 { field.otherAppFocused = true } }
        #expect(await inserter.insert("x") == .notInserted(.focusChanged))
        #expect(field.keys.isEmpty)
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func focusOnSomethingThatIsNotTextIsNoTextBox() async {
        let inserter = inserter()
        field.role = kAXButtonRole
        field.selectionUnanswered = true
        #expect(await inserter.insert("x") == .notInserted(.noTextField))
        #expect(field.keys.isEmpty)
        #expect(field.text == "abc")
    }

    @Test func aPageWithNoFieldFocusedIsNoTextBoxThoughItHasASelection() async {
        let inserter = inserter()
        // A web area is editable text only when its value is settable.
        field.role = "AXWebArea"
        field.web = true
        field.settable = false
        #expect(await inserter.insert("x") == .notInserted(.noTextField))
        #expect(field.keys.isEmpty)
    }

    @Test func anAppThatExposesNoTextGetsAPasteThatIsNeverRead() async {
        let inserter = inserter()
        // Focus answers a bare group in a window that exposes no text, as in
        // a terminal or editor that draws its own.
        field.role = "AXGroup"
        field.selectionUnanswered = true
        field.bareWindow = true
        #expect(await inserter.insert("x") == .unknown(.unreadableField))
        #expect(field.keys == ["paste"])
        #expect(field.textReadsWhileSecure == 0)
    }

    @Test func anAppThatAnswersNothingHasFocusAndExposesNoTextGetsAPaste() async {
        let inserter = inserter()
        field.focused = false
        field.bareWindow = true
        #expect(await inserter.insert("x") == .unknown(.unreadableField))
        #expect(field.keys == ["paste"])
    }

    @Test func nothingFocusedInAWindowThatExposesTextIsNoTextBox() async {
        let inserter = inserter()
        field.focused = false
        #expect(await inserter.insert("x") == .notInserted(.noTextField))
        #expect(field.keys.isEmpty)
    }

    /// A window taken as bare when the target was made gains a field, a
    /// password field perhaps, while focus still answers the same, at the
    /// check before the clipboard is borrowed and at the one before the key.
    @Test(arguments: [false, true], [2, 3])
    func aBareWindowThatGainsAFieldBeforeThePasteGetsNothing(focusOnAGroup: Bool, gainsAtScan: Int) async {
        await bareWindowGains(secure: false, focusOnAGroup: focusOnAGroup, gainsAtScan: gainsAtScan)
    }

    /// The same with a password field, or one that does not say whether it
    /// is one: refused as a password field, so nothing of the words shows.
    @Test(arguments: [false, true], [2, 3])
    func aBareWindowThatGainsAPasswordFieldBeforeThePasteIsAPasswordField(focusOnAGroup: Bool, gainsAtScan: Int) async {
        await bareWindowGains(secure: true, focusOnAGroup: focusOnAGroup, gainsAtScan: gainsAtScan)
    }

    @Test(arguments: [false, true])
    func aWindowWithAPasswordFieldAndNothingElseFocusedIsAPasswordField(focusOnAGroup: Bool) async {
        let inserter = inserter()
        if focusOnAGroup {
            field.role = "AXGroup"
            field.selectionUnanswered = true
        } else {
            field.focused = false
        }
        field.secureInWindow = true
        #expect(await inserter.insert("x") == .notInserted(.secureField))
        #expect(field.keys.isEmpty)
    }

    private func bareWindowGains(secure: Bool, focusOnAGroup: Bool, gainsAtScan: Int) async {
        let inserter = inserter()
        if focusOnAGroup {
            field.role = "AXGroup"
            field.selectionUnanswered = true
        } else {
            field.focused = false
        }
        field.bareAnswers = Array(repeating: true, count: gainsAtScan - 1) + [false]
        field.secureInWindow = secure
        #expect(await inserter.insert("x") == .notInserted(secure ? .secureField : .fieldChanged))
        #expect(field.bareScans == gainsAtScan)
        #expect(field.keys.isEmpty)
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func anUnlistedElementInsideASecureWrapperIsAPasswordField() async {
        let inserter = inserter()
        field.role = "AXGroup"
        field.bareWindow = true
        // `surface` stops at the element's role; its ancestors are asked after.
        field.secureAnswers = [true]
        #expect(await inserter.insert("x") == .notInserted(.secureField))
        #expect(field.keys.isEmpty)
        #expect(field.textReadsWhileSecure == 0)
    }

    @Test func insertsIntoAnEmptyField() async {
        let inserter = inserter()
        field.text = ""
        field.selection = FieldRange(location: 0, length: 0)
        #expect(await inserter.insert("hello") == .inserted(.selectedText, clipboardRestored: nil))
        #expect(field.text == "hello")
    }

    @Test func aDocumentFieldIsWrittenAtItsCaretNeverThroughReplaceRange() async {
        let inserter = inserter()
        field.document = true
        #expect(await inserter.insert("X") == .inserted(.textOperation, clipboardRestored: nil))
        #expect(field.text == "aXbc")
        #expect(field.replaceRangeWrites == 0)
        #expect(field.keys.isEmpty)
    }

    @Test func aSelectionReplacedInADocumentFieldLeavesTheCaretAfterIt() async {
        let inserter = inserter()
        field.document = true
        field.text = "Alpha Beta"
        field.selection = FieldRange(location: 6, length: 4)
        #expect(await inserter.insert("Gamma") == .inserted(.textOperation, clipboardRestored: nil))
        #expect(field.text == "Alpha Gamma")
        // The caret sits after the insertion, not around it.
        #expect(field.selection == FieldRange(location: 11, length: 0))
    }

    @Test func severalLinesInADocumentFieldAreWrittenAtItsCaret() async {
        let inserter = inserter()
        field.document = true
        #expect(await inserter.insert("X\nY") == .inserted(.textOperation, clipboardRestored: nil))
        #expect(field.text == "aX\nYbc")
    }

    @Test func severalLinesReplaceASelectionInADocumentField() async {
        let inserter = inserter()
        field.document = true
        field.text = "Alpha Beta"
        field.selection = FieldRange(location: 6, length: 4)
        #expect(await inserter.insert("X\nY") == .inserted(.textOperation, clipboardRestored: nil))
        #expect(field.text == "Alpha X\nY")
        #expect(field.selection == FieldRange(location: 9, length: 0))
    }

    @Test func aDocumentFieldThatDoesNotKnowTheTextOperationGetsAPaste() async {
        let inserter = inserter()
        field.document = true
        field.textOperationUnknown = true
        #expect(await inserter.insert("X") == .inserted(.paste, clipboardRestored: true))
        #expect(field.text == "aXbc")
        #expect(field.replaceRangeWrites == 0)
    }

    // A web editor that keeps each line in its own block. Its offsets leave
    // the break between blocks out; its character count includes it.

    private func blockEditor(_ text: String, _ selection: FieldRange) -> TextInserter {
        let inserter = inserter()
        field.web = true
        field.blocks = true
        field.text = text
        field.selection = selection
        return inserter
    }

    @Test func severalLinesInABlockEditorAreConfirmed() async {
        let inserter = blockEditor("abc", FieldRange(location: 1, length: 0))
        #expect(await inserter.insert("X\nY") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == "aX\nYbc")
    }

    @Test func textAfterAnEarlierParagraphInABlockEditorIsPastedAtTheCaret() async {
        // The caret is after "c", at offset 3 once the break is left out. A
        // replace range there would land one character early.
        let inserter = blockEditor("ab\ncd", FieldRange(location: 3, length: 0))
        #expect(await inserter.insert("X") == .inserted(.paste, clipboardRestored: true))
        #expect(field.replaceRangeWrites == 0)
        #expect(field.text == "ab\ncXd")
    }

    @Test func anInsertionThatStartsWithAParagraphBreakIsConfirmed() async {
        let inserter = blockEditor("abc", FieldRange(location: 1, length: 0))
        #expect(await inserter.insert("\nX") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == "a\nXbc")
    }

    @Test func aPastedLeadingBreakThatBecameAnEmptyLineReadsAsWritten() async {
        let inserter = blockEditor("abc", FieldRange(location: 1, length: 0))
        field.writes = .refuse
        field.pasteAddsParagraphBreak = true
        // The field reads the pasted text back as written, a line break and
        // "X", though it now holds a paragraph break and an empty line.
        #expect(await inserter.insert("\nX") == .inserted(.paste, clipboardRestored: true))
        #expect(field.text == "a\n\nXbc")
    }

    @Test func anInsertionThatEndsWithAParagraphBreakIsConfirmed() async {
        let inserter = blockEditor("abc", FieldRange(location: 1, length: 0))
        #expect(await inserter.insert("X\n") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == "aX\nbc")
    }

    @Test func aPasteAtTheEndOfAParagraphLandsBeforeItsBreak() async {
        // The caret is at the end of the first paragraph, before its break.
        let inserter = blockEditor("a\nbc", FieldRange(location: 1, length: 0))
        field.startAfterBreak = false
        field.endAfterBreak = false
        #expect(await inserter.insert("X") == .inserted(.paste, clipboardRestored: true))
        #expect(field.text == "aX\nbc")
    }

    @Test func anEmptyLineBetweenParagraphsIsConfirmed() async {
        let inserter = blockEditor("abc", FieldRange(location: 1, length: 0))
        // The field reads this back as "X", one line break and "Y": the
        // paragraph break is left out and the empty line is one break.
        #expect(await inserter.insert("X\n\nY") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == "aX\n\nYbc")
    }

    @Test func threeLinesInABlockEditorAreConfirmed() async {
        let inserter = blockEditor("abc", FieldRange(location: 1, length: 0))
        #expect(await inserter.insert("X\nY\nZ") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == "aX\nY\nZbc")
    }

    @Test func aParagraphBreakAddedBeforeABlankFieldIsReadBackIsNotConfirmed() async {
        // Blank, the Chromium editor takes the paste. The person splits
        // the text as it lands, before the readback's first read, the
        // fourth read of the field's length after the one that observed it
        // and the two rechecks before the clipboard and the key: by
        // offsets it still reads "XY"; only the character count shows the
        // break.
        let inserter = blockEditor("", FieldRange(location: 0, length: 0))
        field.onLengthRead = { count in if count == 4 { MockField.shared.text = "X\nY" } }
        #expect(await inserter.insert("XY") == .unknown(.readbackMismatch))
        #expect(field.keys == ["paste"])
        #expect(field.text == "X\nY")
    }

    @Test func aParagraphBreakAddedBeforeABlankFieldsWriteIsReadBackIsNotConfirmed() async {
        // The same through an Accessibility write that lands late, in a
        // WebKit editor, whose blank fields keep the replace range.
        let inserter = webKitLineEditor("", FieldRange(location: 0, length: 0))
        field.writes = .held
        field.landsAfterLengthReads = 3
        field.onLand = { MockField.shared.text = "X\nY" }
        #expect(await inserter.insert("XY") == .unknown(.readbackMismatch))
        #expect(field.text == "X\nY")
    }

    @Test func aWriteThatLandsLateIsNotMistakenForParagraphsLeftOut() async {
        let inserter = inserter()
        field.web = true
        field.text = "one two"
        field.selection = FieldRange(location: 4, length: 3)
        // Until the write lands the field is one unit shorter than expected,
        // as it would be if the inserted line break were left out.
        field.writes = .held
        field.landsAfterLengthReads = 5
        #expect(await inserter.insert("X\nYZ") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == "one X\nYZ")
    }

    @Test func aFailedRangedReadIsNotAnsweredFromTheValue() async {
        // "d" is selected, at offset 3 once the break is left out. In the
        // value, offset 3 is "c".
        let inserter = blockEditor("ab\ncd", FieldRange(location: 3, length: 1))
        field.failingRead = FieldRange(location: 3, length: 1)
        // Unreadable, so the paste is sent unverified, rather than "c" being
        // taken for the replaced text.
        #expect(await inserter.insert("c") == .unknown(.unreadableField))
    }

    @Test func severalLinesReplaceAWordInABlockEditor() async {
        let inserter = blockEditor("one two", FieldRange(location: 4, length: 3))
        #expect(await inserter.insert("X\nY") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == "one X\nY")
    }

    @Test func aSelectionAcrossTwoParagraphsInABlockEditorIsPastedOver() async {
        // "bc" spans the break between the two paragraphs.
        let inserter = blockEditor("ab\ncd", FieldRange(location: 1, length: 2))
        #expect(await inserter.insert("X") == .inserted(.paste, clipboardRestored: true))
        #expect(field.text == "aXd")
    }

    @Test func severalLinesPastedIntoABlockEditorAreConfirmed() async {
        let inserter = blockEditor("abc", FieldRange(location: 1, length: 0))
        field.writes = .refuse
        #expect(await inserter.insert("X\nY") == .inserted(.paste, clipboardRestored: true))
        #expect(field.text == "aX\nYbc")
    }

    // Focus moving to another field of the same app, where a key posted to
    // the process would land.

    @Test func focusMovingWhileTheFieldIsObservedStopsTheWrite() async {
        let inserter = inserter()
        // The second read of the field's length is the recheck before the
        // write; focus moves to another field during it.
        field.onLengthRead = { [field] count in if count == 2 { field.focusedElsewhere = true } }
        #expect(await inserter.insert("X") == .notInserted(.focusChanged))
        #expect(field.accessibilityWrites == 0)
        #expect(field.text == "abc")
    }

    @Test func focusMovingBeforeAPasteIntoAnUnreadableFieldStopsTheKey() async {
        let inserter = blockEditor("ab\ncd", FieldRange(location: 3, length: 1))
        field.failingRead = FieldRange(location: 3, length: 1)
        // Once the field has proved unreadable it is checked twice more:
        // before the clipboard is touched, and right before the key. Focus
        // moves during the second check of whether it is secure.
        field.onFailedRead = { [field] in
            nonisolated(unsafe) var checks = 0
            field.onSecureCheck = {
                checks += 1
                if checks == 2 { field.focusedElsewhere = true }
            }
        }
        #expect(await inserter.insert("c") == .notInserted(.focusChanged))
        #expect(field.keys.isEmpty)
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func aSelectionMovedWhileADocumentFieldsMarkersAreReadIsNotWrittenOver() async {
        let inserter = inserter()
        field.document = true
        // The person selects "bc" as the selection's markers are read for
        // the write.
        field.onSelectionMarkersRead = { [field] in
            field.onSelectionMarkersRead = nil
            field.selection = FieldRange(location: 1, length: 2)
        }
        #expect(await inserter.insert("X") == .notInserted(.fieldChanged))
        #expect(field.accessibilityWrites == 0)
        #expect(field.text == "abc")
    }

    @Test func aFieldTurningSecureWhileItIsReadBackIsNotReadFurther() async {
        let inserter = inserter()
        // The third read of the field's length is the readback after the
        // write; the field turns secure during it.
        field.onLengthRead = { [field] count in if count == 3 { field.secure = true } }
        #expect(await inserter.insert("X") == .unknown(.secureField))
        #expect(field.textReadsWhileSecure == 0)
    }

    @Test func aPasteBesideIdenticalTextElsewhereIsConfirmedAtItsPlace() async {
        // The same 64 characters sit on each side of both places, and the
        // text pasted is the text that already sits between them elsewhere.
        let (before, after) = (String(repeating: "a", count: 64), String(repeating: "b", count: 64))
        let inserter = blockEditor(before + after + "|" + before + "X" + after, FieldRange(location: 64, length: 0))
        field.writes = .refuse
        #expect(await inserter.insert("X") == .inserted(.paste, clipboardRestored: true))
        let inserted = before + "X" + after + "|" + before + "X" + after
        #expect(field.text == inserted)
    }

    @Test func aRefusedWriteAfterALineBreakInAPlainWebFieldIsPastedAtTheCaret() async {
        let inserter = inserter()
        field.web = true
        field.text = "ab\ncd"
        field.selection = FieldRange(location: 4, length: 0)
        field.writes = .refuse
        #expect(await inserter.insert("X") == .inserted(.paste, clipboardRestored: true))
        #expect(field.text == "ab\ncXd")
        #expect(field.keys == ["paste"])
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func aPlainWebFieldWithEarlierLinesKeepsItsReplaceRange() async {
        let inserter = inserter()
        field.web = true
        field.text = "ab\ncd"
        field.selection = FieldRange(location: 4, length: 0)
        #expect(await inserter.insert("X") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == "ab\ncXd")
        #expect(field.keys.isEmpty)
    }

    // An empty paragraph that was there before the insertion. The breaks
    // around it show in neither length: the character count and the offsets
    // agree, as in a field of one paragraph.

    @Test func textAfterAnEmptyParagraphIsPastedAtTheCaret() async {
        // The caret is after "c": offset 4, counting the empty line as one.
        let inserter = blockEditor("ab\n\ncd", FieldRange(location: 4, length: 0))
        #expect(await inserter.insert("X") == .inserted(.paste, clipboardRestored: true))
        #expect(field.replaceRangeWrites == 0)
        #expect(field.text == "ab\n\ncXd")
    }

    @Test func aBlockEditorWhoseChildrenDoNotAnswerIsPastedInto() async {
        let inserter = blockEditor("ab\n\ncd", FieldRange(location: 4, length: 0))
        field.childrenUnanswered = true
        #expect(await inserter.insert("X") == .inserted(.paste, clipboardRestored: true))
        #expect(field.replaceRangeWrites == 0)
        #expect(field.text == "ab\n\ncXd")
    }

    @Test func aSelectionOverAnEmptyParagraphIsPastedOver() async {
        // "b", the empty line and "c" are selected.
        let inserter = blockEditor("ab\n\ncd\nef", FieldRange(location: 1, length: 3))
        #expect(await inserter.insert("X") == .inserted(.paste, clipboardRestored: true))
        #expect(field.text == "aXd\nef")
    }

    // A web editor as WebKit shows one: its ranged reads, value and
    // character count hold the break between two paragraphs twice, and its
    // selection, replace range and markers hold it once.

    private func webKitEditor(_ text: String, _ selection: FieldRange) -> TextInserter {
        let inserter = inserter()
        field.web = true
        field.doubles = true
        field.text = text
        field.selection = selection
        return inserter
    }

    @Test func textAfterAnEarlierParagraphInAWebKitEditorIsConfirmed() async {
        // The caret is after "c". By the value's offsets that place is one
        // further on, after the doubled break.
        let inserter = webKitEditor("ab\ncd", FieldRange(location: 4, length: 0))
        #expect(await inserter.insert("X") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == "ab\ncXd")
        #expect(field.keys.isEmpty)
    }

    @Test func severalLinesInAWebKitEditorAreConfirmed() async {
        let inserter = webKitEditor("abc", FieldRange(location: 1, length: 0))
        #expect(await inserter.insert("X\nY") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == "aX\nYbc")
    }

    @Test func textThatEndsWithALineBreakInAWebKitEditorIsConfirmed() async {
        let inserter = webKitEditor("abc", FieldRange(location: 1, length: 0))
        #expect(await inserter.insert("X\n") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == "aX\nbc")
    }

    // Text that starts with a line break in WebKit. A text area takes it as
    // written. An editable element, the paragraph editor and the line
    // editor each write it with an empty line before it, as the WebKit host
    // showed: one unit more than was written, which no reading confirms.

    @Test func textThatStartsWithALineBreakInAWebKitTextAreaIsConfirmed() async {
        let inserter = inserter()
        field.web = true
        field.webKitPlain = true
        field.text = "abc"
        #expect(await inserter.insert("\nX") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == "a\nXbc")
    }

    enum WebKitField: String, CaseIterable, Sendable {
        case editable = "editable element", paragraphs = "paragraph editor", lines = "line editor"
    }

    @Test(arguments: WebKitField.allCases)
    func textThatStartsWithALineBreakInAWebKitEditorGetsAnEmptyLineAndIsNotConfirmed(_ kind: WebKitField) async {
        let inserter = inserter()
        field.web = true
        switch kind {
        case .editable: field.webKitPlain = true
        case .paragraphs: field.doubles = true
        case .lines: field.lines = true
        }
        field.text = "abc"
        field.leadingBreakAddsLine = true
        #expect(await inserter.insert("\nX") == .unknown(.readbackMismatch), "\(kind.rawValue)")
        #expect(field.replaceRangeWrites == 1)
        #expect(field.keys.isEmpty)
        #expect(field.text == "a\n\nXbc")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func aSelectionAcrossParagraphsInAWebKitEditorKeepsTheReplaceRange() async {
        // "b", the break and "c" are selected.
        let inserter = webKitEditor("ab\ncd", FieldRange(location: 1, length: 3))
        #expect(await inserter.insert("X") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == "aXd")
        #expect(field.keys.isEmpty)
    }

    @Test func severalLinesReplaceAWordInAWebKitEditor() async {
        let inserter = webKitEditor("one two\nthree", FieldRange(location: 4, length: 3))
        #expect(await inserter.insert("X\nY") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == "one X\nY\nthree")
    }

    @Test func aSelectionInALaterParagraphOfAWebKitEditorIsReplaced() async {
        // "cd" is selected. By the value's offsets that range would name
        // other text.
        let inserter = webKitEditor("ab\ncd", FieldRange(location: 3, length: 2))
        #expect(await inserter.insert("X") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == "ab\nX")
    }

    // Where the markers' text is not as long as the markers say, or does
    // not answer, nothing reads the field in the offsets its selection
    // takes, so it is pasted into unverified. Its ranged reads would name
    // other text, and are not used.

    @Test func aWebKitEditorWhoseMarkersReadOtherTextIsPastedIntoUnverified() async {
        let inserter = webKitEditor("ab\ncd", FieldRange(location: 1, length: 0))
        field.wholeTextExtra = "\u{2022} "
        #expect(await inserter.insert("X") == .unknown(.unreadableField))
        #expect(field.replaceRangeWrites == 0)
        #expect(field.text == "aXb\ncd")
    }

    @Test func aWebKitEditorWhoseMarkersDoNotAnswerForItsTextIsPastedIntoUnverified() async {
        let inserter = webKitEditor("ab\ncd", FieldRange(location: 4, length: 0))
        field.wholeTextUnanswered = true
        #expect(await inserter.insert("X") == .unknown(.unreadableField))
        #expect(field.replaceRangeWrites == 0)
    }

    // A field's length in the value's offsets is longer than its length in
    // the selection's by one for each paragraph break. With one break, a
    // readback that changed from the one kind to the other would show the
    // field longer by exactly one character that was never written. The
    // text is the same character throughout, so every slice reads alike.

    private static let alike = "ab\n" + String(repeating: "X", count: 200)

    /// A write of one "X" that the field accepts and ignores, with
    /// `afterWrite` run when the first readback after it starts.
    private func ignoredWrite(_ afterWrite: @escaping @Sendable (MockField) -> Void) async {
        let inserter = webKitEditor(Self.alike, FieldRange(location: 100, length: 0))
        field.writes = .ignore
        // The field's length is read when it is observed, again right
        // before the write and then for each readback.
        field.onLengthRead = { [field] reads in if reads == 3 { afterWrite(field) } }
        #expect(await inserter.insert("X") != .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.keys.isEmpty)
        #expect(field.text == Self.alike)
    }

    @Test func anIgnoredWriteIsNotConfirmedWhenTheMarkersTextStopsAnswering() async {
        await ignoredWrite { $0.wholeTextUnanswered = true }
    }

    @Test func anIgnoredWriteIsNotConfirmedWhenTheMarkersTextComesBackLonger() async {
        await ignoredWrite { $0.wholeTextExtra = "\u{2022} " }
    }

    @Test func anIgnoredWriteIsNotConfirmedWhenTheMarkerLengthStopsAnswering() async {
        await ignoredWrite { $0.markerLengthUnanswered = true }
    }

    @Test func anIgnoredWriteIsNotConfirmedWhenTheCharacterCountStopsAnswering() async {
        await ignoredWrite { $0.countUnanswered = true }
    }

    /// A paste of one "X" over two that the app does not take, into a field
    /// that `before` made unreadable and `onKey` makes readable again as
    /// the key is posted.
    private func ignoredPaste(before: (MockField) -> Void, onKey: @escaping @Sendable (MockField) -> Void) async {
        let inserter = webKitEditor(Self.alike, FieldRange(location: 100, length: 2))
        before(field)
        field.pastesLand = false
        field.onKey = { [field] in onKey(field) }
        #expect(await inserter.insert("X") == .unknown(.unreadableField))
        #expect(field.keys == ["paste"])
        #expect(field.text == Self.alike)
    }

    @Test func anIgnoredPasteIsNotConfirmedWhenTheMarkersTextStartsAnswering() async {
        await ignoredPaste(before: { $0.wholeTextUnanswered = true }, onKey: { $0.wholeTextUnanswered = false })
    }

    @Test func anIgnoredPasteIsNotConfirmedWhenTheMarkersTextComesBackRight() async {
        await ignoredPaste(before: { $0.wholeTextExtra = "\u{2022} " }, onKey: { $0.wholeTextExtra = "" })
    }

    // The engine comes from what the field offers, so no read that fails
    // can make a WebKit field read as Chromium's, whose ranged reads would
    // name text one place off after a paragraph break.

    @Test func aWebKitEditorWhoseRangedReadFailsIsStillReadByItsMarkers() async {
        // "YX" is selected, between runs of "X". One place earlier the
        // field holds "XY".
        let text = "ab\n" + String(repeating: "X", count: 97) + "YX" + String(repeating: "X", count: 100)
        let inserter = webKitEditor(text, FieldRange(location: 100, length: 2))
        // The read of one character at the markers' length, which tells a
        // Chromium field's two readings apart.
        field.failingRead = FieldRange(location: 202, length: 1)
        #expect(await inserter.insert("XX") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == "ab\n" + String(repeating: "X", count: 199))
    }

    @Test func aBlockEditorWhoseLengthProbeGoesUnansweredIsPastedIntoUnverified() async {
        // The caret is after "c". The markers measure the field as 4 long
        // and its character count is 5.
        let inserter = blockEditor("ab\ncd", FieldRange(location: 3, length: 0))
        field.failingRead = FieldRange(location: 4, length: 1)
        field.failingReadTimesOut = true
        #expect(await inserter.insert("X") == .unknown(.unreadableField))
        #expect(field.accessibilityWrites == 0)
        #expect(field.text == "ab\ncXd")
    }

    @Test func aWebFieldThatDoesNotSayWhatItOffersIsLeftAlone() async {
        let inserter = webKitEditor("ab\ncd", FieldRange(location: 4, length: 0))
        field.namesUnanswered = true
        #expect(await inserter.insert("X") == .notInserted(.targetUnresponsive))
        #expect(field.accessibilityWrites == 0)
        #expect(field.keys.isEmpty)
        #expect(field.text == "ab\ncd")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func aWebFieldThatSaysWhatItOffersWhenAskedAgainIsWrittenTo() async {
        let inserter = webKitEditor("ab\ncd", FieldRange(location: 4, length: 0))
        field.namesUnansweredTimes = 1
        #expect(await inserter.insert("X") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == "ab\ncXd")
        #expect(field.keys.isEmpty)
    }

    @Test func aWebFieldIsAskedWhatItOffersOnlyOnceMore() async {
        let inserter = webKitEditor("ab\ncd", FieldRange(location: 4, length: 0))
        field.namesUnansweredTimes = 2
        #expect(await inserter.insert("X") == .notInserted(.targetUnresponsive))
        #expect(field.accessibilityWrites == 0)
        #expect(field.keys.isEmpty)
        #expect(field.text == "ab\ncd")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    // A field that turns secure during an insertion, at each moment of one
    // kind in turn: as it is asked whether it is secure, which that asking
    // then answers; as one of its reads of text, of its length or marker
    // ranges, or any other of its reads (its role, labels, selection,
    // children, which element has focus) is answered; or right after a
    // write or the paste key has had its effect. The moments are counted
    // in a run where the field stays clear, so the sweep does not depend on
    // the order of the reads. Once the field is secure no text may be read
    // and nothing written or pasted, and the insertion must report the
    // secure field: nothing read after the field turned secure may confirm
    // it. A field turning secure at a read that is not of text can still
    // have its next length or marker range read before it is asked; no
    // text follows that.

    private enum Moment: String, CaseIterable {
        case asking, textRead = "text read", lengthRead = "length read", otherRead = "other read", edit = "write or key"
    }

    /// A field holding `base` with the caret after "c" (at the start of a
    /// blank one), its result in a run where it stays clear, and its result
    /// when it turns secure after its write or key.
    private struct Editor {
        let name: String
        let make: (TextInserterScenarioTests) -> TextInserter
        let clean: InsertionResult
        var base = "ab\ncd"
        var afterEdit = InsertionResult.unknown(.secureField)
        /// False for a field that is never asked for its text or length.
        var read = true
        /// The text before the caret as the field's offsets read it.
        var before = "ab\nc"
        /// The field's text once `text` went in, where it is not `base`
        /// with the text at the caret.
        var writtenText: ((String) -> String)? = nil
        /// The field's text once `text` went in.
        func written(_ text: String) -> String { writtenText?(text) ?? (base.isEmpty ? text : "ab\nc" + text + "d") }
    }

    private static let sweptEditors = [
        // Read whole by its markers, written through AXReplaceRangeWithText.
        Editor(name: "WebKit paragraph editor", make: { $0.webKitEditor("ab\ncd", FieldRange(location: 4, length: 0)) },
               clean: .inserted(.replaceRange, clipboardRestored: nil)),
        // Read by ranges, pasted into, since it holds two blocks.
        Editor(name: "WebKit line editor", make: { $0.webKitLineEditor("ab\ncd", FieldRange(location: 4, length: 0)) },
               clean: .inserted(.paste, clipboardRestored: true)),
        // Measured past its own marker range, which ends at the caret, to
        // the end of its last block, and pasted into.
        Editor(name: "WebKit line editor read past its own range", make: {
            let inserter = $0.webKitLineEditor("ab\ncd", FieldRange(location: 4, length: 0))
            MockField.shared.ownEndAtCaret = true
            return inserter
        }, clean: .inserted(.paste, clipboardRestored: true)),
        // Ending in an image with alt text, so measured by its own marker
        // range alone, and pasted into.
        Editor(name: "WebKit paragraph editor ending in an image", make: {
            let inserter = $0.webKitEditor("ab\ncd", FieldRange(location: 4, length: 0))
            MockField.shared.trailingAttachment = true
            return inserter
        }, clean: .inserted(.paste, clipboardRestored: true)),
        // Chromium's, whose offsets leave the break between blocks out.
        Editor(name: "Chromium block editor", make: { $0.blockEditor("ab\ncd", FieldRange(location: 3, length: 0)) },
               clean: .inserted(.paste, clipboardRestored: true), before: "abc"),
        // A native field without ranged reads, read by its whole value.
        Editor(name: "native field read by value", make: {
            let inserter = $0.inserter()
            MockField.shared.rangedReadsOffered = false
            MockField.shared.text = "ab\ncd"
            MockField.shared.selection = FieldRange(location: 4, length: 0)
            return inserter
        }, clean: .inserted(.selectedText, clipboardRestored: nil)),
        // Chromium's, empty: the placeholder line break with the caret in
        // front of it, pasted into, since a replace range there can land
        // in an element the tree leaves out, as in Gmail's body.
        Editor(name: "empty Chromium field", make: { $0.emptyChromiumField(hiddenPlaceholder: true) },
               clean: .inserted(.paste, clipboardRestored: true), base: "\n", before: "", writtenText: { $0 + "\n" }),
        // A blank field, read whole after the write.
        Editor(name: "blank native field", make: {
            let inserter = $0.inserter()
            MockField.shared.text = ""
            MockField.shared.selection = FieldRange(location: 0, length: 0)
            return inserter
        }, clean: .inserted(.selectedText, clipboardRestored: nil), base: ""),
        // A web area that is itself the editable text, written with the
        // text operation at its selection's markers.
        Editor(name: "editable document", make: {
            let inserter = $0.inserter()
            MockField.shared.document = true
            MockField.shared.text = "ab\ncd"
            MockField.shared.selection = FieldRange(location: 4, length: 0)
            return inserter
        }, clean: .inserted(.textOperation, clipboardRestored: nil)),
        // A field whose selection and text cannot be read, pasted into
        // unverified: after its key it is never read again.
        Editor(name: "unreadable field", make: {
            let inserter = $0.inserter()
            MockField.shared.unreadable = true
            MockField.shared.text = "ab\ncd"
            MockField.shared.selection = FieldRange(location: 4, length: 0)
            return inserter
        }, clean: .unknown(.unreadableField), afterEdit: .unknown(.unreadableField), read: false),
    ]

    /// Runs `turn` at each moment of `moment`'s kind, counted from one.
    private func arm(_ moment: Moment, _ turn: @escaping @Sendable (Int) -> Void) {
        nonisolated(unsafe) var seen = 0
        let next: @Sendable () -> Void = { seen += 1; turn(seen) }
        switch moment {
        case .asking: field.onSecureCheck = next
        case .textRead: field.onTextRead = next
        case .lengthRead: field.onMeasure = next
        case .otherRead: field.onOtherRead = next
        case .edit: field.onEdit = next
        }
    }

    private func sweep(_ moment: Moment) async {
        for editor in Self.sweptEditors {
            for text in ["X", "X\nY"] {
                let written = editor.written(text)
                nonisolated(unsafe) var total = 0
                let clean = editor.make(self)
                arm(moment) { total = $0 }
                #expect(await clean.insert(text) == editor.clean, "\(editor.name), \(text.debugDescription)")
                #expect(field.text == written, "\(editor.name), \(text.debugDescription)")
                #expect((total > 0) == (editor.read || ![.textRead, .lengthRead].contains(moment)), "\(editor.name), \(text.debugDescription)")
                for turn in stride(from: 1, through: total, by: 1) {
                    let label = "\(editor.name), \(text.debugDescription), secure at \(moment.rawValue) \(turn) of \(total)"
                    let inserter = editor.make(self)
                    arm(moment) { [field] seen in if seen == turn { field.secure = true } }
                    let result = await inserter.insert(text)
                    let edited = field.accessibilityWrites > 0 || !field.keys.isEmpty
                    #expect(result == (edited ? editor.afterEdit : .notInserted(.secureField)), "\(label): \(result)")
                    #expect(field.textReadsWhileSecure == 0, "\(label)")
                    #expect(field.editsWhileSecure == 0, "\(label)")
                    if [.asking, .textRead, .edit].contains(moment) { #expect(field.measuresWhileSecure == 0, "\(label)") }
                    #expect(field.text == (edited ? written : editor.base), "\(label)")
                    // A paste that is not confirmed leaves its text on the
                    // clipboard; one that never had its key leaves the
                    // person's clipboard there.
                    #expect(pasteboard.string(forType: .string) == (field.keys.isEmpty ? "the person's clipboard" : text), "\(label)")
                }
            }
        }
    }

    @Test func aFieldThatTurnsSecureAtAnyAskingIsNotReadOrConfirmed() async {
        await sweep(.asking)
    }

    @Test func aFieldThatTurnsSecureAtAnyReadOfItsTextIsNotReadAgainOrConfirmed() async {
        await sweep(.textRead)
    }

    @Test func aFieldThatTurnsSecureAtAnyReadOfItsLengthIsNotReadOrConfirmed() async {
        await sweep(.lengthRead)
    }

    @Test func aFieldThatTurnsSecureAtAnyOtherReadIsNotReadOrWrittenTo() async {
        await sweep(.otherRead)
    }

    @Test func aFieldThatTurnsSecureAsItIsWrittenIsNotReadOrConfirmed() async {
        await sweep(.edit)
    }

    @Test func aFieldMeasuredByItsCountAtTheReadbackThatTurnsSecureIsNotReadAgainOrConfirmed() async {
        // "b", the break and "c" of a WebKit paragraph editor are replaced,
        // which joins it into one block: the readback measures it by its
        // count and reads its last unit for the run that ends it. The field
        // turns secure at each asking and each read of its text in turn.
        for moment in [Moment.asking, .textRead] {
            nonisolated(unsafe) var total = 0
            let clean = webKitEditor("ab\ncd", FieldRange(location: 1, length: 3))
            arm(moment) { total = $0 }
            #expect(await clean.insert("X") == .inserted(.replaceRange, clipboardRestored: nil))
            #expect(field.text == "aXd")
            for turn in stride(from: 1, through: total, by: 1) {
                let label = "secure at \(moment.rawValue) \(turn) of \(total)"
                let inserter = webKitEditor("ab\ncd", FieldRange(location: 1, length: 3))
                arm(moment) { [field] seen in if seen == turn { field.secure = true } }
                let result = await inserter.insert("X")
                let edited = field.accessibilityWrites > 0
                #expect(result == (edited ? .unknown(.secureField) : .notInserted(.secureField)), "\(label): \(result)")
                #expect(field.textReadsWhileSecure == 0, "\(label)")
                #expect(field.editsWhileSecure == 0, "\(label)")
                #expect(field.text == (edited ? "aXd" : "ab\ncd"), "\(label)")
            }
        }
    }

    // The last check of the field before a write or key, at the end of the
    // check before it and, for an editable document, after the reads of its
    // selection's markers, answers as `answers` say. A check that does not
    // answer is asked once more there, at once; any other check is not.

    /// Scripts the next checks after the `nth` read of the field's
    /// placeholder, the last read of each recheck.
    private func afterPlaceholderRead(_ nth: Int, _ answers: [Bool?]) {
        nonisolated(unsafe) var reads = 0
        field.onPlaceholderRead = { [field] in
            reads += 1
            if reads == nth { field.secureAnswers = answers }
        }
    }

    @Test func aFinalCheckThatDoesNotAnswerOnceBeforeAWriteIsAskedAgain() async {
        let inserter = webKitEditor("ab\ncd", FieldRange(location: 4, length: 0))
        afterPlaceholderRead(2, [nil])
        #expect(await inserter.insert("X") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == "ab\ncXd")
    }

    @Test func aFinalCheckThatDoesNotAnswerOnceBeforeThePasteKeyIsAskedAgain() async {
        let inserter = webKitLineEditor("ab\ncd", FieldRange(location: 4, length: 0))
        afterPlaceholderRead(3, [nil])
        #expect(await inserter.insert("X") == .inserted(.paste, clipboardRestored: true))
        #expect(field.keys == ["paste"])
        #expect(field.text == "ab\ncXd")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func aFinalCheckThatDoesNotAnswerOnceBeforeTheTextOperationIsAskedAgain() async {
        let inserter = inserter()
        field.document = true
        field.text = "ab\ncd"
        field.selection = FieldRange(location: 4, length: 0)
        field.onSelectionMarkersRead = { [field] in field.secureAnswers = [nil] }
        #expect(await inserter.insert("X") == .inserted(.textOperation, clipboardRestored: nil))
        #expect(field.text == "ab\ncXd")
    }

    /// After the `nth` placeholder read the last check does not answer, and
    /// focus moves to another field as it is read next.
    private func focusMovesAfterAMissedAnswer(_ nth: Int) {
        afterPlaceholderRead(nth, [nil, false])
        field.onSecureCheck = { [field] in
            guard field.secureAnswers == [nil, false] else { return }
            field.onFocusRead = {
                field.onFocusRead = nil
                field.focusedElement = 2
            }
        }
    }

    @Test func focusMovingWhileTheLastCheckDoesNotAnswerStopsTheWrite() async {
        let inserter = webKitEditor("ab\ncd", FieldRange(location: 4, length: 0))
        focusMovesAfterAMissedAnswer(2)
        #expect(await inserter.insert("X") == .notInserted(.focusChanged))
        #expect(field.accessibilityWrites == 0)
        #expect(field.keys.isEmpty)
        #expect(field.text == "ab\ncd")
    }

    @Test func focusMovingWhileTheLastCheckDoesNotAnswerStopsThePasteKey() async {
        let inserter = webKitLineEditor("ab\ncd", FieldRange(location: 4, length: 0))
        focusMovesAfterAMissedAnswer(3)
        #expect(await inserter.insert("X") == .notInserted(.focusChanged))
        #expect(field.accessibilityWrites == 0)
        #expect(field.keys.isEmpty)
        #expect(field.text == "ab\ncd")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func theLastCheckAskedAgainReadsFocusOnceMoreAndNotTheGuard() async {
        // A run where every check answers.
        let clean = inserter()
        let cleanCaptured = await guardedField(clean)
        let focusBefore = field.focusReads
        #expect(await clean.insert("X", into: cleanCaptured) == .inserted(.selectedText, clipboardRestored: nil))
        let cleanFocusReads = field.focusReads - focusBefore
        #expect(field.guardCalls == 2)
        // The same field, the last check not answering once.
        let inserter = inserter()
        let captured = await guardedField(inserter)
        let start = field.focusReads
        afterPlaceholderRead(2, [nil])
        #expect(await inserter.insert("X", into: captured) == .inserted(.selectedText, clipboardRestored: nil))
        #expect(field.text == "aXbc")
        #expect(field.focusReads - start == cleanFocusReads + 1)
        #expect(field.guardCalls == 2)
        #expect(field.guardCallsAtWrites == [2])
    }

    @Test func aFinalCheckThatDoesNotAnswerTwiceRefusesTheWrite() async {
        let inserter = webKitEditor("ab\ncd", FieldRange(location: 4, length: 0))
        afterPlaceholderRead(2, [nil, nil])
        #expect(await inserter.insert("X") == .notInserted(.targetUnresponsive))
        #expect(field.accessibilityWrites == 0)
        #expect(field.text == "ab\ncd")
    }

    @Test func aFinalCheckThatDoesNotAnswerTwiceRefusesThePasteKey() async {
        let inserter = webKitLineEditor("ab\ncd", FieldRange(location: 4, length: 0))
        afterPlaceholderRead(3, [nil, nil])
        #expect(await inserter.insert("X") == .notInserted(.targetUnresponsive))
        #expect(field.keys.isEmpty)
        #expect(field.text == "ab\ncd")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func aFinalCheckThatDoesNotAnswerAndThenAnswersSecureRefusesTheWrite() async {
        let inserter = webKitEditor("ab\ncd", FieldRange(location: 4, length: 0))
        afterPlaceholderRead(2, [nil, true])
        #expect(await inserter.insert("X") == .notInserted(.secureField))
        #expect(field.accessibilityWrites == 0)
        #expect(field.text == "ab\ncd")
    }

    @Test func aFinalCheckThatAnswersSecureIsNotAskedAgain() async {
        let inserter = webKitEditor("ab\ncd", FieldRange(location: 4, length: 0))
        afterPlaceholderRead(2, [true, false])
        #expect(await inserter.insert("X") == .notInserted(.secureField))
        #expect(field.accessibilityWrites == 0)
        #expect(field.text == "ab\ncd")
    }

    @Test func aCheckThatDoesNotAnswerInTheReadbackIsNotAskedAgain() async {
        let inserter = webKitEditor("ab\ncd", FieldRange(location: 4, length: 0))
        field.onEdit = { [field] in field.secureAnswers = [nil] }
        #expect(await inserter.insert("X") == .unknown(.secureField))
        #expect(field.accessibilityWrites == 1)
        #expect(field.text == "ab\ncXd")
    }

    // A dictation reads the focused field when it starts and sends the text
    // before the caret to its endpoint, so a field that turns secure as any
    // read of its text is answered gives no field at all.
    @Test func aFieldThatTurnsSecureAtAnyReadOfItsTextGivesADictationNothing() async {
        // A blank field has no text before its caret to read.
        for editor in Self.sweptEditors where editor.read && !editor.base.isEmpty {
            nonisolated(unsafe) var total = 0
            let clean = editor.make(self)
            arm(.textRead) { total = $0 }
            guard case let .success(read) = await clean.readFocusedField().value.field else {
                Issue.record("\(editor.name): no field when it stays clear")
                continue
            }
            #expect(read.before == editor.before, "\(editor.name)")
            #expect(total > 0, "\(editor.name)")
            for turn in stride(from: 1, through: total, by: 1) {
                let inserter = editor.make(self)
                arm(.textRead) { [field] seen in if seen == turn { field.secure = true } }
                if case .success = await inserter.readFocusedField().value.field {
                    Issue.record("\(editor.name), secure at text read \(turn) of \(total): a field was given")
                }
                #expect(field.textReadsWhileSecure == 0, "\(editor.name), secure at text read \(turn) of \(total)")
            }
        }
    }

    // A WebKit editor whose lines are blocks and whose counts all agree,
    // as one with a `div` for each line. It takes the paste, as any web
    // field of several blocks whose breaks do not read doubled does, and
    // its readback must find the whole field.

    private func webKitLineEditor(_ text: String, _ selection: FieldRange) -> TextInserter {
        let inserter = inserter()
        field.web = true
        field.lines = true
        field.text = text
        field.selection = selection
        return inserter
    }

    @Test func aWebKitLineEditorWhoseOwnRangeEndsAtTheCaretIsMeasuredToItsLastBlock() async {
        // By its own range the field would be 4 long, its count 14, and
        // its text would read as breaks counted twice.
        let inserter = webKitLineEditor("ab\ncd and more", FieldRange(location: 4, length: 0))
        field.ownEndAtCaret = true
        #expect(await inserter.insert("X\nY") == .inserted(.paste, clipboardRestored: true))
        #expect(field.text == "ab\ncX\nYd and more")
        #expect(field.keys == ["paste"])
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func aWebKitFieldWhoseMarkersAllEndAtTheCaretIsNotReadAsBreaksCountedTwice() async {
        // The count is longer than the markers by 10, and the text by
        // markers holds one line break.
        let inserter = webKitLineEditor("ab\ncd and more", FieldRange(location: 4, length: 0))
        field.ownEndAtCaret = true
        field.lastEndShortBy = 10
        #expect(await inserter.insert("X") == .unknown(.unreadableField))
        #expect(field.replaceRangeWrites == 0)
    }

    @Test func anIgnoredWriteIsNotConfirmedWhenALastBlockThatEndedShortComesRight() async {
        // While the field is observed its own range ends at the caret and
        // its last block one unit short, which by lengths alone is its one
        // break counted twice. By the first readback the last block ends
        // right, and the field reads one longer. A field read past its own
        // range takes the paste, which the app ignores too.
        let inserter = webKitLineEditor(Self.alike, FieldRange(location: 100, length: 0))
        field.writes = .ignore
        field.pastesLand = false
        field.ownEndAtCaret = true
        field.lastEndShortBy = 1
        field.onLengthRead = { [field] reads in if reads == 3 { field.lastEndShortBy = 0 } }
        #expect(await inserter.insert("X") == .unknown(.unreadableField))
        #expect(field.replaceRangeWrites == 0)
        #expect(field.text == Self.alike)
    }

    @Test func anIgnoredWriteIsNotConfirmedWhenATrailingRunOfBreaksThatEndedShortComesRight() async {
        // The field ends with an empty line. While it is observed its own
        // range ends at the caret and its last block one unit short, inside
        // that last run of breaks, which by markers is one break facing two.
        // By the first readback the last block ends right, and the field
        // reads one longer, as an insertion of one character would.
        let text = "ab\n" + String(repeating: "X", count: 197) + "\n\n"
        let inserter = webKitLineEditor(text, FieldRange(location: 100, length: 0))
        field.writes = .ignore
        field.ownEndAtCaret = true
        field.lastEndShortBy = 1
        field.onLengthRead = { [field] reads in if reads == 3 { field.lastEndShortBy = 0 } }
        #expect(await inserter.insert("X") == .unknown(.unreadableField))
        #expect(field.replaceRangeWrites == 0)
        #expect(field.keys == ["paste"])
    }

    @Test func anIgnoredPasteIsNotConfirmedWhenAListsMarkerRangeThatEndedShortComesRight() async {
        // As `<p>ab</p><ul><li>` and 197 "X" `</li></ul><p><br><br></p>`,
        // which the WebKit host measured 203 by markers and 205 by its count,
        // ending in three breaks by markers and four by ranged reads. While
        // the field is observed its own range and its last block end one
        // break short, at 202. When the paste key goes the range comes
        // right, and the field reads one longer though the paste was
        // ignored. A list's last run must face as many breaks by ranged
        // reads, so the field is unreadable throughout.
        let text = "ab\n" + String(repeating: "X", count: 197) + "\n\n\n"
        let inserter = webKitList(text, labels: [1: "\u{2022} "], items: [201, 202], FieldRange(location: 100, length: 0))
        field.ownEnd = 202
        field.lastEndShortBy = 1
        field.writes = .ignore
        field.pastesLand = false
        field.onKey = { [field] in
            field.ownEnd = 203
            field.lastEndShortBy = 0
        }
        #expect(field.value == "ab\n\n" + String(repeating: "X", count: 197) + "\n\n\n\n")
        #expect(field.markerText(from: 0, to: 203) == "ab\n\u{2022} " + String(repeating: "X", count: 197) + "\n\n\n")
        #expect(await inserter.insert("X") == .unknown(.unreadableField))
        #expect(field.text == text)
        #expect(field.replaceRangeWrites == 0)
        #expect(pasteboard.string(forType: .string) == "X")
    }

    // A WebKit field read by its own range, with no list labels, whose
    // last run of breaks faces more by ranged reads: as `<p>ab</p>`, a
    // paragraph of 197 "X" and `<p><br><br></p>`, 203 by markers and 205
    // by its count, ending in three breaks by markers and four by ranged
    // reads. A range ending one break short, at 202, passes the run-by-run
    // rule too, so only the run a readback finds can tell where it ends.

    private static let trailingRun = "ab\n" + String(repeating: "X", count: 197) + "\n\n\n"

    private func webKitFieldEndingInEmptyLines(_ selection: FieldRange) -> TextInserter {
        let inserter = webKitEditor(Self.trailingRun, selection)
        field.singleBreaks = [201, 202]
        return inserter
    }

    @Test func aWebKitFieldEndingInEmptyLinesIsReadAsTheHostReadIt() {
        _ = webKitFieldEndingInEmptyLines(FieldRange(location: 100, length: 0))
        #expect(field.value == "ab\n\n" + String(repeating: "X", count: 197) + "\n\n\n\n")
        #expect(field.markerText(from: 0, to: 203) == Self.trailingRun)
    }

    @Test func anIgnoredWriteIsNotConfirmedWhenItsOwnRangeEndedShortAndComesRight() async {
        // The range ends at 202 while the field is observed and at 203 by
        // the first readback, which reads one longer, as one "X" written at
        // 100 would. The run that ends the field reads three breaks there,
        // where the insertion leaves the two observed.
        let inserter = webKitFieldEndingInEmptyLines(FieldRange(location: 100, length: 0))
        field.ownEnd = 202
        field.lastEndShortBy = 1
        field.writes = .ignore
        field.onLengthRead = { [field] reads in
            if reads == 3 {
                field.ownEnd = 203
                field.lastEndShortBy = 0
            }
        }
        #expect(await inserter.insert("X") == .unknown(.readbackMismatch))
        #expect(field.text == Self.trailingRun)
        #expect(field.replaceRangeWrites == 1)
        #expect(field.keys.isEmpty)
    }

    @Test func anIgnoredPasteIsNotConfirmedWhenItsOwnRangeEndedShortAndComesRight() async {
        let inserter = webKitFieldEndingInEmptyLines(FieldRange(location: 100, length: 0))
        inserter.pasteOnly = true
        field.ownEnd = 202
        field.lastEndShortBy = 1
        field.pastesLand = false
        field.onKey = { [field] in
            field.ownEnd = 203
            field.lastEndShortBy = 0
        }
        #expect(await inserter.insert("X") == .unknown(.readbackMismatch))
        #expect(field.text == Self.trailingRun)
        #expect(field.keys == ["paste"])
        #expect(pasteboard.string(forType: .string) == "X")
    }

    @Test func anIgnoredWriteIsNotConfirmedInALineEditorWhoseOwnRangeEndedShortAndComesRight() async {
        // One `div` for each line and an empty last line, as the WebKit host
        // read `<div>ab</div>`, a line of 197 "X" and `<div><br></div>`:
        // 202 by every count. With the range one break short, at 201, the
        // field reads as its last break counted twice. By the readback the
        // range is right and the field is measured by its count, one longer,
        // and its last two units are both breaks.
        let text = "ab\n" + String(repeating: "X", count: 197) + "\n\n"
        let inserter = webKitLineEditor(text, FieldRange(location: 100, length: 0))
        field.ownEnd = 201
        field.lastEndShortBy = 1
        field.writes = .ignore
        field.onLengthRead = { [field] reads in
            if reads == 3 {
                field.ownEnd = nil
                field.lastEndShortBy = 0
            }
        }
        #expect(await inserter.insert("X") == .unknown(.readbackMismatch))
        #expect(field.text == text)
        #expect(field.replaceRangeWrites == 1)
    }

    @Test func anIgnoredWriteIsNotConfirmedWhenTheEndOfAFieldMeasuredByItsCountDoesNotAnswer() async {
        // As above, with the read of the field's last two units failing in
        // the readback: without the run that ends it, nothing is confirmed.
        let text = "ab\n" + String(repeating: "X", count: 197) + "\n\n"
        let inserter = webKitLineEditor(text, FieldRange(location: 100, length: 0))
        field.ownEnd = 201
        field.lastEndShortBy = 1
        field.writes = .ignore
        field.failingRead = FieldRange(location: 200, length: 2)
        field.onLengthRead = { [field] reads in
            if reads == 3 {
                field.ownEnd = nil
                field.lastEndShortBy = 0
            }
        }
        #expect(await inserter.insert("X") == .unknown(.readbackMismatch))
        #expect(field.text == text)
    }

    @Test func aWriteIsConfirmedInAWebKitFieldEndingInEmptyLinesWhoseOwnRangeIsRight() async {
        let inserter = webKitFieldEndingInEmptyLines(FieldRange(location: 100, length: 0))
        #expect(await inserter.insert("X") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == "ab\n" + String(repeating: "X", count: 198) + "\n\n\n")
        #expect(field.replaceRangeWrites == 1)
    }

    @Test func aPasteIsConfirmedInAWebKitFieldEndingInEmptyLinesWhoseOwnRangeIsRight() async {
        let inserter = webKitFieldEndingInEmptyLines(FieldRange(location: 100, length: 0))
        inserter.pasteOnly = true
        #expect(await inserter.insert("X") == .inserted(.paste, clipboardRestored: true))
        #expect(field.text == "ab\n" + String(repeating: "X", count: 198) + "\n\n\n")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    /// The field's last two breaks become "X" and a break while the field
    /// is checked again before the write, far past the compared context:
    /// 203 by markers and 205 by its count as before, its run three breaks
    /// then one.
    private func endChangesDuringTheRecheck() {
        field.onLengthRead = { [field] reads in
            if reads == 2 {
                field.text = "ab\n" + String(repeating: "X", count: 197) + "\nX\n"
                field.singleBreaks = [202]
            }
        }
    }

    @Test func aWebKitFieldWhoseEndChangesBeforeTheWriteIsNotWritten() async {
        let inserter = webKitFieldEndingInEmptyLines(FieldRange(location: 100, length: 0))
        endChangesDuringTheRecheck()
        #expect(await inserter.insert("X") == .notInserted(.fieldChanged))
        #expect(field.value.utf16.count == 205)
        #expect(field.replaceRangeWrites == 0)
        #expect(field.keys.isEmpty)
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func aWebKitFieldWhoseEndChangesBeforeThePasteIsNotPasted() async {
        let inserter = webKitFieldEndingInEmptyLines(FieldRange(location: 100, length: 0))
        inserter.pasteOnly = true
        endChangesDuringTheRecheck()
        #expect(await inserter.insert("X") == .notInserted(.fieldChanged))
        #expect(field.text == "ab\n" + String(repeating: "X", count: 197) + "\nX\n")
        #expect(field.keys.isEmpty)
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func anIgnoredWriteIsNotConfirmedWhenItsOwnRangeEndsShortByTheReadback() async {
        // "XX" at 100 is replaced by one "X" and the write is ignored. The
        // range is right while the field is observed and ends at 202 by the
        // readback, which reads one shorter, as the replacement would.
        let inserter = webKitFieldEndingInEmptyLines(FieldRange(location: 100, length: 2))
        field.writes = .ignore
        field.onLengthRead = { [field] reads in
            if reads == 3 {
                field.ownEnd = 202
                field.lastEndShortBy = 1
            }
        }
        #expect(await inserter.insert("X") == .unknown(.readbackMismatch))
        #expect(field.text == Self.trailingRun)
    }

    @Test func textThatOnlyAddsLineBreaksAtTheEndOfAWebKitFieldWithAShortRangeIsNotConfirmed() async {
        // The last "X" is replaced by "X" and a line break, right before
        // the run of breaks. Ignored, with the range one break short while
        // the field is observed and right by the readback, the field reads
        // exactly as written, run and all, so no readback can tell.
        let inserter = webKitFieldEndingInEmptyLines(FieldRange(location: 199, length: 1))
        field.ownEnd = 202
        field.lastEndShortBy = 1
        field.writes = .ignore
        field.onLengthRead = { [field] reads in
            if reads == 3 {
                field.ownEnd = 203
                field.lastEndShortBy = 0
            }
        }
        #expect(await inserter.insert("X\n") == .unknown(.readbackMismatch))
        #expect(field.text == Self.trailingRun)
    }

    @Test func textWrittenAtTheEndOfAWebKitFieldEndingInEmptyLinesIsConfirmed() async {
        // Right before the run of breaks and inside it: the run the field
        // then ends in is the breaks that followed the caret.
        let inserter = webKitFieldEndingInEmptyLines(FieldRange(location: 200, length: 0))
        #expect(await inserter.insert("Y") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == "ab\n" + String(repeating: "X", count: 197) + "Y\n\n\n")
        field.selection = FieldRange(location: 203, length: 0)
        #expect(await inserter.insert("Z") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == "ab\n" + String(repeating: "X", count: 197) + "Y\n\nZ\n")
    }

    @Test func aWebKitFieldWhoseLastBlockDoesNotSayWhereItEndsIsPastedIntoUnverified() async {
        let inserter = webKitLineEditor("ab\ncd", FieldRange(location: 4, length: 0))
        field.lastBlockMarkersUnanswered = true
        #expect(await inserter.insert("X") == .unknown(.unreadableField))
        #expect(field.replaceRangeWrites == 0)
    }

    @Test func aWebKitFieldWhoseLastBlockDoesNotSayWhatItHoldsIsPastedIntoUnverified() async {
        let inserter = webKitLineEditor("ab\ncd", FieldRange(location: 4, length: 0))
        field.lastBlockChildrenUnanswered = true
        #expect(await inserter.insert("X") == .unknown(.unreadableField))
        #expect(field.replaceRangeWrites == 0)
    }

    // Line breaks of two kinds in a WebKit editor whose paragraph breaks
    // count twice: a `<br>` counts once.

    @Test func aWebKitEditorWithALineBreakInsideAParagraphIsReadByItsMarkers() async {
        // As `<p>Alpha<br>Bravo</p><p>Charlie</p>`: by markers 19 units, by
        // the count 20. The caret is after "Ch".
        let inserter = webKitEditor("Alpha\nBravo\nCharlie", FieldRange(location: 14, length: 0))
        field.singleBreaks = [5]
        #expect(await inserter.insert("X") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == "Alpha\nBravo\nChXarlie")
    }

    @Test func aWebKitEditorWhoseLastLineEndsInALineBreakIsMeasuredToItsOwnEnd() async {
        // As `<p>Alpha</p><p>Bravo<br></p>`: the last block's range ends
        // before the `<br>`, the field's own range after it.
        let inserter = webKitEditor("Alpha\nBravo\n", FieldRange(location: 2, length: 0))
        field.singleBreaks = [11]
        field.lastEndShortBy = 1
        #expect(await inserter.insert("X") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == "AlXpha\nBravo\n")
    }

    // A WebKit field read past its own range must not reach the replace
    // range that reading it by that range alone would not have reached.

    @Test func aWebKitFieldReadPastItsOwnRangeIsPastedInto() async {
        // As `<p>Alpha</p><div>Bravo<img>Delta</div>` with "Delta" selected:
        // the field's own range ends before the image, at 11, its last
        // block at 16, and its count is 17. By its own range alone the
        // selection lies past the field's end.
        let inserter = webKitEditor("Alpha\nBravoDelta", FieldRange(location: 11, length: 5))
        field.ownEnd = 11
        #expect(await inserter.insert("X") == .inserted(.paste, clipboardRestored: true))
        #expect(field.replaceRangeWrites == 0)
        #expect(field.text == "Alpha\nBravoX")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func aWebKitFieldThatComesToBeReadPastItsOwnRangeBeforeTheWriteIsNotWritten() async {
        // As `<p>Alpha</p><div>BravoDelta</div>` with "Delta" selected, read
        // by its own range, 16. Before the write an image arrives before
        // "Delta": the own range now ends at 11 while the last block still
        // ends at 16, so the text, the selection and the length read the
        // same. The second read of the field's length is the recheck's.
        let inserter = webKitEditor("Alpha\nBravoDelta", FieldRange(location: 11, length: 5))
        field.onLengthRead = { [field] reads in if reads == 2 { field.ownEnd = 11 } }
        #expect(await inserter.insert("X") == .notInserted(.fieldChanged))
        #expect(field.accessibilityWrites == 0)
        #expect(field.keys.isEmpty)
        #expect(field.text == "Alpha\nBravoDelta")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func aPasteGoesAheadWhenAWebKitFieldComesToBeReadPastItsOwnRange() async {
        // The same field and the same change, on the paste route. A paste
        // goes where the selection is however the field was measured, and
        // the text, the selection and the length read the same, so the
        // checks before the clipboard is borrowed and before the key pass.
        let inserter = webKitEditor("Alpha\nBravoDelta", FieldRange(location: 11, length: 5))
        inserter.pasteOnly = true
        field.onLengthRead = { [field] reads in if reads == 2 { field.ownEnd = 11 } }
        #expect(await inserter.insert("X") == .inserted(.paste, clipboardRestored: true))
        #expect(field.replaceRangeWrites == 0)
        #expect(field.text == "Alpha\nBravoX")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func aWebKitFieldEndingInAnImageWithAltTextIsReadByItsOwnRange() async {
        // As `<p>Alpha</p><p>BravoDelta<img alt="Picture"></p>` with "Delta"
        // selected, as the WebKit host measured it: 16 by the field's own
        // range, 17 to its last descendant, the image included, and 17 by
        // its count, the break counted twice. By those lengths alone the
        // ranged reads would stand, and the selection would read "oDelt".
        let inserter = webKitEditor("Alpha\nBravoDelta", FieldRange(location: 11, length: 5))
        field.trailingAttachment = true
        #expect(await inserter.insert("X") == .inserted(.paste, clipboardRestored: true))
        #expect(field.replaceRangeWrites == 0)
        #expect(field.text == "Alpha\nBravoX")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func aWebKitFieldOfThreeParagraphsEndingInAnImageWithAltTextIsReadByItsOwnRange() async {
        // One paragraph more: 17 by the own range, 18 to the last
        // descendant and 19 by the count, so the reach past the own range
        // is shorter than the count and its text ends in a unit the ranged
        // reads do not hold.
        let inserter = webKitEditor("Al\npha\nBravoDelta", FieldRange(location: 12, length: 5))
        field.trailingAttachment = true
        #expect(await inserter.insert("X") == .inserted(.paste, clipboardRestored: true))
        #expect(field.replaceRangeWrites == 0)
        #expect(field.text == "Al\npha\nBravoX")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func aWebKitFieldEndingInALineBreakAndAnImageWithAltTextIsReadByItsOwnRange() async {
        // As `<p>Alpha</p><p>BravoDelta<br><img alt="Picture"></p>` with
        // "Delta" selected, as the WebKit host measured it: 16 by the
        // field's own range, which ends before the `<br>`, 18 to its last
        // descendant and 18 by its count. The ranged reads end in a break
        // the text by the own range does not hold.
        let inserter = webKitEditor("Alpha\nBravoDelta\n", FieldRange(location: 11, length: 5))
        field.singleBreaks = [16]
        field.trailingAttachment = true
        field.ownEndShortBy = 1
        #expect(await inserter.insert("X") == .inserted(.paste, clipboardRestored: true))
        #expect(field.replaceRangeWrites == 0)
        #expect(field.text == "Alpha\nBravoX\n")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    // An image with alt text inside the field's own range, as the WebKit
    // host measured two fields `main` reads: the markers hold it as U+FFFC
    // and the ranged reads leave it out.

    @Test func aWebKitFieldWithAnEmptyParagraphAfterAnImageWithAltTextIsRead() async {
        // As `<p>Alpha</p><p>BravoDelta<img alt="Picture"></p><p><br></p>`
        // with "Delta" selected: 19 by markers, 20 by the count.
        let inserter = webKitEditor("Alpha\nBravoDelta\u{E000}\n\n", FieldRange(location: 11, length: 5))
        field.singleBreaks = [18]
        #expect(field.value == "Alpha\n\nBravoDelta\n\n\n")
        #expect(await inserter.insert("X") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == "Alpha\nBravoX\u{E000}\n\n")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func aWebKitFieldWithAnImageWithAltTextAloneInItsLastParagraphIsRead() async {
        // As `<p>Alpha</p><p>BravoDelta</p><p><img alt="Picture"></p>` with
        // "Delta" selected: 18 by markers, 19 by the count.
        let inserter = webKitEditor("Alpha\nBravoDelta\n\u{E000}", FieldRange(location: 11, length: 5))
        #expect(field.value == "Alpha\n\nBravoDelta\n\n")
        #expect(await inserter.insert("X") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == "Alpha\nBravoX\n\u{E000}")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func anIgnoredWriteInAWebKitFieldHoldingAnImageWithAltTextIsNotConfirmed() async {
        let inserter = webKitEditor("Alpha\nBravoDelta\n\u{E000}", FieldRange(location: 11, length: 5))
        field.writes = .ignore
        #expect(await inserter.insert("X") == .unknown(.writeUnconfirmed))
        #expect(field.text == "Alpha\nBravoDelta\n\u{E000}")
    }

    // A WebKit editor that holds a list between two paragraphs without
    // margins, as the WebKit host read
    // `<p>Start.</p><ul><li>One</li><li>Two</li></ul><p>End.</p>`: 21 by its
    // count, which holds the breaks before and after the list twice and the
    // one between the items once, 19 by its markers and in the selection's
    // offsets, and 23 in its markers' text, which holds a label in front of
    // each item. The labels have no offsets, and `AXReplaceRangeWithText`
    // and the text operation wrote at the selection in every place probed.

    nonisolated private static let bullets = [1: "\u{2022} ", 2: "\u{2022} "]
    private static let numbers = [1: "1. ", 2: "2. "]

    private func webKitList(_ text: String = "Start.\nOne\nTwo\nEnd.", labels: [Int: String], items: Set<Int> = [10],
                            _ selection: FieldRange) -> TextInserter {
        let inserter = webKitEditor(text, selection)
        field.listLabels = labels
        field.singleBreaks = items
        return inserter
    }

    @Test func aWebKitListIsReadAsTheHostReadIt() {
        _ = webKitList(labels: Self.bullets, FieldRange(location: 8, length: 0))
        #expect(field.value == "Start.\n\nOne\nTwo\n\nEnd.")
        #expect(field.markerText(from: 0, to: 19) == "Start.\n\u{2022} One\n\u{2022} Two\nEnd.")
        field.listLabels = Self.numbers
        #expect(field.markerText(from: 0, to: 19) == "Start.\n1. One\n2. Two\nEnd.")
    }

    // Before the list, at the start, middle and end of the first item, at
    // the end of the second and after the list. A field whose labels were
    // taken out takes the paste, so the clipboard is borrowed and put back.

    @Test(arguments: zip([6, 7, 8, 10, 14, 15], [
        "Start.X\nOne\nTwo\nEnd.", "Start.\nXOne\nTwo\nEnd.", "Start.\nOXne\nTwo\nEnd.",
        "Start.\nOneX\nTwo\nEnd.", "Start.\nOne\nTwoX\nEnd.", "Start.\nOne\nTwo\nXEnd.",
    ])) func anInsertionInAWebKitBulletedListIsConfirmed(caret: Int, expected: String) async {
        let inserter = webKitList(labels: Self.bullets, FieldRange(location: caret, length: 0))
        #expect(await inserter.insert("X") == .inserted(.paste, clipboardRestored: true))
        #expect(field.replaceRangeWrites == 0)
        #expect(field.text == expected)
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test(arguments: zip([6, 7, 8, 10, 14, 15], [
        "Start.X\nOne\nTwo\nEnd.", "Start.\nXOne\nTwo\nEnd.", "Start.\nOXne\nTwo\nEnd.",
        "Start.\nOneX\nTwo\nEnd.", "Start.\nOne\nTwoX\nEnd.", "Start.\nOne\nTwo\nXEnd.",
    ])) func anInsertionInAWebKitNumberedListIsConfirmed(caret: Int, expected: String) async {
        let inserter = webKitList(labels: Self.numbers, FieldRange(location: caret, length: 0))
        #expect(await inserter.insert("X") == .inserted(.paste, clipboardRestored: true))
        #expect(field.replaceRangeWrites == 0)
        #expect(field.text == expected)
    }

    @Test func aWholeItemOfAWebKitListIsReplaced() async {
        let inserter = webKitList(labels: Self.numbers, FieldRange(location: 7, length: 3))
        #expect(await inserter.insert("X") == .inserted(.paste, clipboardRestored: true))
        #expect(field.text == "Start.\nX\nTwo\nEnd.")
    }

    @Test func aWebKitListWhoseLabelsChangeLengthBeforeTheRecheckIsConfirmed() async {
        // As `<ol start="9">`: "9. " and "10. ", which become "10. " and
        // "11. " between the first read and the check before the paste, as
        // an item added above the list would make them.
        let inserter = webKitList(labels: [1: "9. ", 2: "10. "], FieldRange(location: 12, length: 0))
        field.onLengthRead = { [field] reads in if reads == 2 { field.listLabels = [1: "10. ", 2: "11. "] } }
        #expect(await inserter.insert("X") == .inserted(.paste, clipboardRestored: true))
        #expect(field.text == "Start.\nOne\nTXwo\nEnd.")
    }

    @Test func aWebKitListThatTurnsSecureBetweenItsTwoReadsOfTextIsNotReadFurther() async {
        // The labels are taken out against the ranged reads, read right
        // after the text by markers.
        let inserter = webKitList(labels: Self.bullets, FieldRange(location: 8, length: 0))
        field.onMarkerTextRead = { [field] in field.secure = true }
        #expect(await inserter.insert("X") == .notInserted(.secureField))
        #expect(field.textReadsWhileSecure == 0)
        #expect(field.accessibilityWrites == 0)
        #expect(field.keys.isEmpty)
        #expect(field.text == "Start.\nOne\nTwo\nEnd.")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func aWebKitFieldWhoseListAppearsBeforeTheReplaceRangeIsNotWritten() async {
        // Paragraphs whose breaks read doubled take the replace range. By
        // the check right before it the field holds a list with the same
        // text, which takes the paste: an image in an item, which no read
        // may show, would decide where a replace range lands.
        let inserter = webKitEditor("Start.\nOne\nTwo\nEnd.", FieldRange(location: 8, length: 0))
        field.onLengthRead = { [field] reads in if reads == 2 { field.listLabels = Self.bullets } }
        #expect(await inserter.insert("X") == .notInserted(.fieldChanged))
        #expect(field.accessibilityWrites == 0)
        #expect(field.keys.isEmpty)
        #expect(field.text == "Start.\nOne\nTwo\nEnd.")
    }

    // An image with alt text in a list item, as
    // `<li>One<img alt="Picture">Six</li>`: U+FFFC and one unit by the
    // markers, nothing in the selection, the replace range and the ranged
    // reads. WebKit's replace range wrote before the image with the caret
    // right after it, and removed it with the word after it selected; a
    // paste goes where the caret is.

    private func webKitListWithAnImage() -> TextInserter {
        let inserter = webKitList("Start.\nOne\u{E000}Six\nTwo\nEnd.", labels: Self.bullets, items: [14], FieldRange(location: 0, length: 0))
        return inserter
    }

    @Test func aWebKitListWithAnImageIsReadAsTheHostReadIt() {
        _ = webKitListWithAnImage()
        field.select(from: 12, to: 12)
        #expect(field.selection == FieldRange(location: 11, length: 0))
        #expect(field.value == "Start.\n\nOneSix\nTwo\n\nEnd.")
        #expect(field.markerText(from: 0, to: 23) == "Start.\n\u{2022} One\u{FFFC}Six\n\u{2022} Two\nEnd.")
    }

    @Test(arguments: zip([(10, 10), (11, 11), (12, 12), (11, 14)], [
        "Start.\nOneX\u{E000}Six\nTwo\nEnd.", "Start.\nOne\u{E000}XSix\nTwo\nEnd.",
        "Start.\nOne\u{E000}SXix\nTwo\nEnd.", "Start.\nOne\u{E000}X\nTwo\nEnd.",
    ])) func anInsertionBesideAnImageInAWebKitListIsConfirmedWhereTheCaretIs(place: (Int, Int), expected: String) async {
        // Right before the image, right after it, after the "S" that
        // follows it, and "Six" selected.
        let inserter = webKitListWithAnImage()
        field.select(from: place.0, to: place.1)
        #expect(await inserter.insert("X") == .inserted(.paste, clipboardRestored: true))
        #expect(field.replaceRangeWrites == 0)
        #expect(field.text == expected)
    }

    @Test func anIgnoredPasteInAWebKitListIsNotConfirmed() async {
        // Two of a long run of "X" in the first item, after an image, are
        // replaced by one "X" that the app never pastes.
        let text = "Start.\n" + String(repeating: "X", count: 40) + "\u{E000}" + String(repeating: "X", count: 120) + "\nTwo\nEnd."
        let inserter = webKitList(text, labels: Self.bullets, items: [168], FieldRange(location: 0, length: 0))
        field.select(from: 120, to: 122)
        field.pastesLand = false
        #expect(await inserter.insert("X") == .unknown(.writeUnconfirmed))
        #expect(field.keys == ["paste"])
        #expect(field.text == text)
        #expect(pasteboard.string(forType: .string) == "X")
    }

    @Test func listLabelsAndImagesAreToldFromTheTextsTheHostGave() {
        // The texts the WebKit host gave by markers and by ranged reads.
        func kept(_ byMarkers: String, _ ranged: String) -> String? { FieldEdit.aligned(byMarkers: byMarkers, ranged: ranged)?.selectionText }
        let start = "Start.\n\nOne\nTwo\n\nEnd."
        #expect(kept("Start.\n\u{2022} One\n\u{2022} Two\nEnd.", start) == "Start.\nOne\nTwo\nEnd.")
        #expect(kept("Start.\n9. One\n10. Two\nEnd.", start) == "Start.\nOne\nTwo\nEnd.")
        #expect(kept("Start.\n\u{2022} One\n\u{25E6} Inner\n\u{2022} Two\nEnd.", "Start.\n\nOne\nInner\nTwo\n\nEnd.") == "Start.\nOne\nInner\nTwo\nEnd.")
        #expect(FieldEdit.aligned(byMarkers: "Start.\n\u{2022} One\n\u{2022} Two\nEnd.", ranged: start)?.labels == true)
        #expect(FieldEdit.aligned(byMarkers: "Alpha\nBravo", ranged: "Alpha\n\nBravo")?.labels == false)
        // A `<br>` in an item, an empty item and an item that starts with
        // an image: no label in front of the line after the `<br>`, the
        // empty line or the image.
        #expect(kept("Start.\n\u{2022} One\nMore\n\u{2022} Two\nEnd.", "Start.\n\nOne\nMore\nTwo\n\nEnd.") == "Start.\nOne\nMore\nTwo\nEnd.")
        #expect(kept("Start.\n\u{2022} One\n\n\u{2022} Two\nEnd.", "Start.\n\nOne\n\nTwo\n\nEnd.") == "Start.\nOne\n\nTwo\nEnd.")
        #expect(kept("Start.\n\u{FFFC}Six\n\u{2022} Two\nEnd.", "Start.\n\nSix\nTwo\n\nEnd.") == "Start.\nSix\nTwo\nEnd.")
        // An image in an item and in a paragraph: in the markers' text and
        // their length, out of what is kept.
        let image = FieldEdit.aligned(byMarkers: "Start.\n\u{2022} One\u{FFFC}Six\n\u{2022} Two\nEnd.", ranged: "Start.\n\nOneSix\nTwo\n\nEnd.")
        #expect(image?.text == "Start.\nOne\u{FFFC}Six\nTwo\nEnd.")
        #expect(image?.images == [10])
        #expect(image?.selectionText == "Start.\nOneSix\nTwo\nEnd.")
        #expect(kept("Start.\nOne\u{FFFC}Six\nEnd.", "Start.\n\nOneSix\n\nEnd.") == "Start.\nOneSix\nEnd.")
        // A U+FFFC typed as text is in both reads and stays, alone, in a
        // list item and beside an image in the same line, on either side.
        #expect(kept("Alpha\nBravo\u{FFFC}Delta", "Alpha\n\nBravo\u{FFFC}Delta") == "Alpha\nBravo\u{FFFC}Delta")
        #expect(kept("Alpha\n\u{2022} Bravo\u{FFFC}Delta\n\u{2022} Two", "Alpha\n\nBravo\u{FFFC}Delta\nTwo") == "Alpha\nBravo\u{FFFC}Delta\nTwo")
        #expect(kept("Alpha\nBravo\u{FFFC}Del\u{FFFC}ta", "Alpha\n\nBravo\u{FFFC}Delta") == "Alpha\nBravo\u{FFFC}Delta")
        #expect(kept("Alpha\nBravo\u{FFFC}Del\u{FFFC}ta", "Alpha\n\nBravoDel\u{FFFC}ta") == "Alpha\nBravoDel\u{FFFC}ta")
        #expect(kept("Alpha\nBravo\u{FFFC}\u{FFFC}Delta", "Alpha\n\nBravo\u{FFFC}Delta") == "Alpha\nBravo\u{FFFC}Delta")
        // An image alone between the last paragraphs, whose line the ranged
        // reads leave out with the breaks around it run together, as the
        // host read `<p>Alpha</p><p>BravoDelta</p><p><img alt></p><p><br></p>`
        // and, with a `<br>` after the image, `<p><img alt><br></p>`.
        #expect(kept("Alpha\nBravoDelta\n\u{FFFC}\n\n", "Alpha\n\nBravoDelta\n\n\n\n\n") == "Alpha\nBravoDelta\n\n\n")
        #expect(kept("Alpha\nBravoDelta\n\u{FFFC}\n", "Alpha\n\nBravoDelta\n\n\n") == "Alpha\nBravoDelta\n\n")
        // A typed U+FFFC alone on a line above a line holding only an
        // image, as the host read them after "\n\u{FFFC}\n" replaced "Delta"
        // before an image: the runs tell which is which.
        #expect(kept("Alpha\nBravo\n\u{FFFC}\n\u{FFFC}\n\n", "Alpha\n\nBravo\n\n\u{FFFC}\n\n\n\n\n") == "Alpha\nBravo\n\u{FFFC}\n\n\n")
        // Two lines of one U+FFFC each where the runs do not tell which is
        // the typed one.
        #expect(FieldEdit.aligned(byMarkers: "Alpha\n\u{FFFC}\n\u{FFFC}\nBravo", ranged: "Alpha\n\n\u{FFFC}\n\nBravo") == nil)
        // Text other than in front of a line, a line that differs, another
        // number of lines, a U+FFFC the markers do not hold, and a label
        // after an image.
        #expect(FieldEdit.aligned(byMarkers: "Start.\nOne\u{2022} \nTwo", ranged: "Start.\n\nOne\nTwo") == nil)
        #expect(FieldEdit.aligned(byMarkers: "Start.\n\u{2022} Onf\nTwo", ranged: "Start.\n\nOne\nTwo") == nil)
        #expect(FieldEdit.aligned(byMarkers: "Start.\n\u{2022} One Two", ranged: "Start.\n\nOne\nTwo") == nil)
        #expect(FieldEdit.aligned(byMarkers: "Alpha\nBravoDelta", ranged: "Alpha\n\nBravo\u{FFFC}Delta") == nil)
        #expect(FieldEdit.aligned(byMarkers: "Start.\n\u{FFFC}\u{2022} One", ranged: "Start.\n\nOne") == nil)
    }

    @Test func linesOfImagesBetweenLinesOfATypedUFFFCAreLinedUpQuickly() {
        // As `<p>A</p>`, then 400 times `<p><img alt="Picture"></p><p>￼</p>`
        // with the U+FFFC typed, then `<p>B</p>`: the texts the WebKit host
        // gave by markers (1,603 units) and by ranged reads (2,004). Each
        // line of one U+FFFC could be an image or the typed one, and the
        // runs of breaks tell them apart. Followed to the end, the ways took
        // over two seconds in a release build.
        let byMarkers = "A\n" + Array(repeating: "\u{FFFC}", count: 800).joined(separator: "\n") + "\nB"
        let ranged = "A\n\n\n\n" + Array(repeating: "\u{FFFC}", count: 400).joined(separator: "\n\n\n\n") + "\n\nB"
        let clock = ContinuousClock()
        var alignment: FieldEdit.Alignment?
        let took = clock.measure { alignment = FieldEdit.aligned(byMarkers: byMarkers, ranged: ranged) }
        #expect(alignment?.selectionText == "A\n" + String(repeating: "\n\u{FFFC}\n", count: 400) + "B")
        #expect(alignment?.images.count == 400)
        #expect(took < .milliseconds(200))
        // Twice as many lines of one U+FFFC by markers as by ranged reads,
        // with runs that allow many ways: refused as quickly.
        let ambiguous = clock.measure {
            alignment = FieldEdit.aligned(byMarkers: "A\n" + Array(repeating: "\u{FFFC}", count: 800).joined(separator: "\n") + "\nB",
                                          ranged: "A\n\n" + Array(repeating: "\u{FFFC}", count: 400).joined(separator: "\n\n") + "\n\nB")
        }
        #expect(alignment == nil)
        #expect(ambiguous < .milliseconds(200))
        // Three lines of one U+FFFC by markers for each typed one, with runs
        // of four breaks that take two to four of the markers': hundreds of
        // ways stay open together, and past `maxAlignmentPlaces` the field
        // is refused at once.
        let open = clock.measure {
            alignment = FieldEdit.aligned(byMarkers: "A\n" + Array(repeating: "\u{FFFC}", count: 2400).joined(separator: "\n") + "\nB",
                                          ranged: "A\n\n\n\n" + Array(repeating: "\u{FFFC}", count: 800).joined(separator: "\n\n\n\n") + "\n\nB")
        }
        #expect(alignment == nil)
        #expect(open < .milliseconds(200))
    }

    // A U+FFFC typed as text has an offset in every read, as the WebKit
    // host read `<p>Alpha</p><p>Bravo￼Delta</p>`: 17 by markers and the
    // selection, 18 by the count, and a replace range at the selection.
    // Only an image's U+FFFC is left out of what is kept.

    @Test(arguments: zip([FieldRange(location: 11, length: 0), FieldRange(location: 12, length: 0), FieldRange(location: 12, length: 5)],
                         ["Alpha\nBravoX\u{FFFC}Delta", "Alpha\nBravo\u{FFFC}XDelta", "Alpha\nBravo\u{FFFC}X"]))
    func aUFFFCTypedAsTextInAWebKitFieldIsConfirmed(selection: FieldRange, expected: String) async {
        // Before it, after it, and "Delta" after it selected.
        let inserter = webKitEditor("Alpha\nBravo\u{FFFC}Delta", selection)
        #expect(await inserter.insert("X") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == expected)
    }

    @Test func textHoldingAUFFFCIsConfirmedInAWebKitField() async {
        let inserter = webKitEditor("Alpha\nBravoDelta", FieldRange(location: 11, length: 0))
        #expect(await inserter.insert("X\u{FFFC}Y") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == "Alpha\nBravoX\u{FFFC}YDelta")
    }

    @Test func aWebKitFieldWithAnImageAloneBetweenItsLastParagraphsIsRead() async {
        // As `<p>Alpha</p><p>BravoDelta</p><p><img alt="Picture"></p><p><br></p>`
        // with "Delta" selected: the ranged reads leave the image's line
        // out, "Alpha\n\nBravoDelta\n\n\n\n\n", and it takes the replace
        // range as on `main`.
        let inserter = webKitEditor("Alpha\nBravoDelta\n\u{E000}\n\n", FieldRange(location: 11, length: 5))
        field.singleBreaks = [19]
        #expect(field.value == "Alpha\n\nBravoDelta\n\n\n\n\n")
        #expect(await inserter.insert("X") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == "Alpha\nBravoX\n\u{E000}\n\n")
    }

    @Test func aLineOfATypedUFFFCAboveALineOfAnImageIsConfirmed() async {
        // As `<p>Alpha</p><p>BravoDelta<img alt="Picture"></p><p><br></p>`
        // with "Delta" replaced by a typed U+FFFC on a line of its own,
        // which leaves the image on the next line, as the host showed.
        let inserter = webKitEditor("Alpha\nBravoDelta\u{E000}\n\n", FieldRange(location: 11, length: 5))
        field.singleBreaks = [18]
        #expect(await inserter.insert("\n\u{FFFC}\n") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == "Alpha\nBravo\n\u{FFFC}\n\u{E000}\n\n")
        #expect(field.value == "Alpha\n\nBravo\n\n\u{FFFC}\n\n\n\n\n")
    }

    @Test(arguments: zip([(11, 11, 11, 0), (12, 12, 12, 0), (15, 15, 15, 0), (17, 17, 16, 0), (12, 15, 12, 3)], [
        "Alpha\nBravoX\u{FFFC}Del\u{E000}ta\nEnd.", "Alpha\nBravo\u{FFFC}XDel\u{E000}ta\nEnd.",
        "Alpha\nBravo\u{FFFC}DelX\u{E000}ta\nEnd.", "Alpha\nBravo\u{FFFC}Del\u{E000}tXa\nEnd.",
        "Alpha\nBravo\u{FFFC}X\u{E000}ta\nEnd.",
    ])) func aUFFFCTypedAsTextBesideAnImageInAWebKitParagraphIsConfirmed(place: (Int, Int, Int, Int), expected: String) async {
        // As `<p>Alpha</p><p>Bravo￼Del<img alt="Picture">ta</p><p>End.</p>`,
        // which the host read "Alpha\nBravo￼Del￼ta\nEnd." by markers and
        // "Alpha\n\nBravo￼Delta\n\nEnd." by ranged reads: the caret before
        // and after the typed character, before the image and after the "t"
        // that follows it, and "Del" selected, with the selection where the
        // host had it.
        let inserter = webKitEditor("Alpha\nBravo\u{FFFC}Del\u{E000}ta\nEnd.", FieldRange(location: 0, length: 0))
        field.select(from: place.0, to: place.1)
        #expect(field.selection == FieldRange(location: place.2, length: place.3))
        #expect(field.value == "Alpha\n\nBravo\u{FFFC}Delta\n\nEnd.")
        #expect(await inserter.insert("X") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == expected)
    }

    @Test func textHoldingAUFFFCIsConfirmedInAWebKitList() async {
        let inserter = webKitList(labels: Self.bullets, FieldRange(location: 8, length: 0))
        #expect(await inserter.insert("X\u{FFFC}Y") == .inserted(.paste, clipboardRestored: true))
        #expect(field.text == "Start.\nOX\u{FFFC}Yne\nTwo\nEnd.")
    }

    @Test(arguments: zip([(10, 10), (11, 11), (12, 12), (14, 14), (18, 18)], [
        "Start.\nOneX\u{FFFC}Six\u{E000}Ten\nTwo\nEnd.", "Start.\nOne\u{FFFC}XSix\u{E000}Ten\nTwo\nEnd.",
        "Start.\nOne\u{FFFC}SXix\u{E000}Ten\nTwo\nEnd.", "Start.\nOne\u{FFFC}SixX\u{E000}Ten\nTwo\nEnd.",
        "Start.\nOne\u{FFFC}Six\u{E000}TenX\nTwo\nEnd.",
    ])) func aUFFFCTypedAsTextBesideAnImageInAWebKitListIsConfirmed(place: (Int, Int), expected: String) async {
        // An item holding "One", a typed U+FFFC, "Six", an image and
        // "Ten", with the caret before and after the typed character, after
        // the "S", before the image and at the end of the item.
        let inserter = webKitList("Start.\nOne\u{FFFC}Six\u{E000}Ten\nTwo\nEnd.", labels: Self.bullets, items: [18], FieldRange(location: 0, length: 0))
        field.select(from: place.0, to: place.1)
        #expect(await inserter.insert("X") == .inserted(.paste, clipboardRestored: true))
        #expect(field.text == expected)
    }

    // Empty last paragraphs, as the WebKit host read them: the ranged reads
    // hold one break more in the last run than the markers do.

    @Test func aWebKitEditorWithAnEmptyLastParagraphIsReadByItsMarkers() async {
        // As `<p>Alpha</p><p><br></p>`: "Alpha\n\n" by markers, 7, and
        // "Alpha\n\n\n" by ranged reads, 8.
        let inserter = webKitEditor("Alpha\n\n", FieldRange(location: 2, length: 0))
        field.singleBreaks = [6]
        #expect(await inserter.insert("X") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == "AlXpha\n\n")
    }

    @Test func aWebKitEditorWithTwoEmptyLastParagraphsIsReadByItsMarkers() async {
        // As `<p>Alpha</p><p><br></p><p><br></p>`: 8 by markers, 10 by
        // ranged reads.
        let inserter = webKitEditor("Alpha\n\n\n", FieldRange(location: 2, length: 0))
        field.singleBreaks = [7]
        #expect(await inserter.insert("X") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == "AlXpha\n\n\n")
    }

    @Test func aWebKitEditorOfTwoEmptyParagraphsIsReadByItsMarkers() async {
        // As `<p><br></p><p><br></p>`: "\n\n" by markers, "\n\n\n" by
        // ranged reads.
        let inserter = webKitEditor("\n\n", FieldRange(location: 0, length: 0))
        field.singleBreaks = [1]
        #expect(await inserter.insert("X") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == "X\n\n")
    }

    @Test func anEmojiInAWebKitEditorIsReadAsWritten() async {
        // The caret is after the emoji in the second paragraph.
        let inserter = webKitEditor("ab\nc\u{1F600}d", FieldRange(location: 6, length: 0))
        #expect(await inserter.insert("X") == .inserted(.replaceRange, clipboardRestored: nil))
        #expect(field.text == "ab\nc\u{1F600}Xd")
    }

    @Test func breaksCountedTwiceAreToldFromTextThatStopsEarly() {
        // The texts the WebKit host gave by markers and by ranged reads.
        #expect(FieldEdit.breaksCountedTwice(byMarkers: "Alpha\nBravo\nCharlie", ranged: "Alpha\nBravo\n\nCharlie"))
        #expect(FieldEdit.breaksCountedTwice(byMarkers: "Alpha\nBravo\n\nCharlie", ranged: "Alpha\nBravo\n\n\n\nCharlie"))
        #expect(FieldEdit.breaksCountedTwice(byMarkers: "Alpha\n\nBravo\nCharlie", ranged: "Alpha\n\n\n\nBravo\nCharlie"))
        #expect(FieldEdit.breaksCountedTwice(byMarkers: "Alpha\n\nBravo", ranged: "Alpha\n\n\nBravo"))
        #expect(FieldEdit.breaksCountedTwice(byMarkers: "Alpha\nBravo\n", ranged: "Alpha\n\nBravo\n"))
        #expect(FieldEdit.breaksCountedTwice(byMarkers: "Alpha\n\nBravo\nCharlie", ranged: "Alpha\n\nBravo\n\nCharlie"))
        #expect(FieldEdit.breaksCountedTwice(byMarkers: "AlphaBravo\nCharlie", ranged: "AlphaBravo\n\nCharlie"))
        // Text by markers that stops early: one unit short, at the caret,
        // and short of a trailing break.
        #expect(!FieldEdit.breaksCountedTwice(byMarkers: "ab\nXXXX", ranged: "ab\nXXXXX"))
        #expect(!FieldEdit.breaksCountedTwice(byMarkers: "ab\nc", ranged: "ab\ncd and more"))
        #expect(!FieldEdit.breaksCountedTwice(byMarkers: "Alpha\nBravo", ranged: "Alpha\n\nBravo\n"))
        // An empty last paragraph, and a range that stops one break short
        // of the end, which only the last run's exact count refuses.
        #expect(FieldEdit.breaksCountedTwice(byMarkers: "Alpha\n\n", ranged: "Alpha\n\n\n"))
        #expect(FieldEdit.breaksCountedTwice(byMarkers: "\n\n", ranged: "\n\n\n"))
        #expect(FieldEdit.breaksCountedTwice(byMarkers: "Alpha\nBravo\n\n", ranged: "Alpha\n\nBravo\n\n\n"))
        #expect(!FieldEdit.breaksCountedTwice(byMarkers: "Alpha\n\n", ranged: "Alpha\n\n\n", lastRunExact: true))
        #expect(!FieldEdit.breaksCountedTwice(byMarkers: "ab\nXX\n", ranged: "ab\nXX\n\n", lastRunExact: true))
        #expect(FieldEdit.breaksCountedTwice(byMarkers: "Alpha\nBravo\n", ranged: "Alpha\n\nBravo\n", lastRunExact: true))
        // A run more than twice as long, and other text.
        #expect(!FieldEdit.breaksCountedTwice(byMarkers: "ab\ncd", ranged: "ab\n\n\ncd"))
        #expect(!FieldEdit.breaksCountedTwice(byMarkers: "ab\ncd", ranged: "ab\n\nce"))
        #expect(!FieldEdit.breaksCountedTwice(byMarkers: "ab\n\ncd", ranged: "ab\ncd"))
    }

    // Pasting text equal to the selection it replaces: the field reads as
    // expected before the app has taken the key.

    @Test func pastingTheSelectedTextOverItselfIsConfirmedByTheCaret() async {
        let inserter = inserter()
        inserter.pasteOnly = true
        field.selection = FieldRange(location: 1, length: 1)
        #expect(await inserter.insert("b") == .inserted(.paste, clipboardRestored: true))
        #expect(field.selection == FieldRange(location: 2, length: 0))
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func aPasteOfTheSelectedTextNotYetTakenKeepsTheClipboard() async {
        let inserter = inserter()
        inserter.pasteOnly = true
        field.selection = FieldRange(location: 1, length: 1)
        field.keysPending = true
        // The clipboard stays as written: the app may still read it.
        #expect(await inserter.insert("b") == .unknown(.writeUnconfirmed))
        #expect(pasteboard.string(forType: .string) == "b")
    }

    @Test func aSelectionThatStopsAnsweringDoesNotShowThePasteWasTaken() async {
        let inserter = inserter()
        inserter.pasteOnly = true
        field.selection = FieldRange(location: 1, length: 1)
        // The app takes the key, and from then on the field does not answer
        // for its selection: the text reads as it did, and only the caret
        // after it would show the paste was taken.
        field.onKey = { [field] in field.selectionUnanswered = true }
        #expect(await inserter.insert("b") == .unknown(.writeUnconfirmed))
        #expect(field.keys == ["paste"])
        #expect(field.text == "abc")
        #expect(pasteboard.string(forType: .string) == "b")
    }

    // The clipboard write that a paste needs fails after Intention has cleared
    // the clipboard.

    @Test func aFailedClipboardWriteBeforeAPastePutsTheClipboardBack() async {
        let inserter = inserterWhoseClipboardWriteFails()
        field.writes = .refuse
        #expect(await inserter.insert("X") == .notInserted(.pasteUnavailable))
        #expect(field.keys.isEmpty)
        #expect(field.text == "abc")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func aFailedClipboardWriteLeavesACopyMadeInThatMoment() async {
        _ = inserter()
        // Another app copies between Intention's clearing and its write, which
        // then fails as a write after another app's clearing does.
        let owner = PasteboardOwner(pasteboard: pasteboard, mayRead: { true }, put: { pasteboard, item in
            anotherProcessCopies(to: pasteboard.name)
            return pasteboard.writeObjects([item])
        })
        let inserter = TextInserter(pasteboard: owner)
        field.writes = .refuse
        #expect(await inserter.insert("X") == .notInserted(.pasteUnavailable))
        #expect(field.keys.isEmpty)
        #expect(field.text == "abc")
        expectTheOtherCopy()
        #expect(!owner.borrowed)
    }

    // The person, or another app, copies something in the moment between
    // Intention's clipboard write and the paste key. Without the check right
    // before the key, that copy is what the field gets.

    /// An inserter and the clipboard owner it uses.
    private func ownedInserter(clipboardReadable: Bool = true) -> (TextInserter, PasteboardOwner) {
        _ = inserter(clipboardReadable: clipboardReadable)
        let owner = PasteboardOwner(pasteboard: pasteboard, mayRead: { clipboardReadable })
        return (TextInserter(pasteboard: owner), owner)
    }

    /// Copies "another copy" to the test clipboard the first time it runs
    /// while the clipboard holds `text`, Intention's write.
    private func copyWhileHolding(_ text: String) -> @Sendable () -> Void {
        nonisolated(unsafe) let pasteboard = pasteboard
        nonisolated(unsafe) var copied = false
        return {
            guard !copied, pasteboard.string(forType: .string) == text else { return }
            copied = true
            pasteboard.clearContents()
            pasteboard.setString("another copy", forType: .string)
        }
    }

    /// Inserts "X" with the copy made at the last read of the check before
    /// the key, after the caller's guard and every read of the field.
    private func copiedBeforeTheKey(_ inserter: TextInserter, _ owner: PasteboardOwner, leaving text: String = "abc") async {
        field.onPlaceholderRead = copyWhileHolding("X")
        #expect(await inserter.insert("X") == .notInserted(.clipboardBusy))
        #expect(field.keys.isEmpty)
        #expect(field.text == text)
        #expect(pasteboard.string(forType: .string) == "another copy")
        #expect(!owner.borrowed)
    }

    @Test func aCopyMadeBeforeThePasteKeyOfAForcedPasteIsNotPasted() async {
        let (inserter, owner) = ownedInserter()
        inserter.pasteOnly = true
        await copiedBeforeTheKey(inserter, owner)
    }

    @Test func aCopyMadeBeforeThePasteKeyAfterARefusedWriteIsNotPasted() async {
        let (inserter, owner) = ownedInserter()
        field.writes = .refuse
        await copiedBeforeTheKey(inserter, owner)
    }

    @Test func aCopyMadeBeforeThePasteKeyInABlockEditorIsNotPasted() async {
        let (inserter, owner) = ownedInserter()
        field.web = true
        field.blocks = true
        field.text = "ab\ncd"
        field.selection = FieldRange(location: 3, length: 0)
        await copiedBeforeTheKey(inserter, owner, leaving: "ab\ncd")
        #expect(field.replaceRangeWrites == 0)
    }

    @Test func aCopyMadeBeforeThePasteKeyOfAForcedPasteIsNotPastedWithoutClipboardAccess() async {
        let (inserter, owner) = ownedInserter(clipboardReadable: false)
        inserter.pasteOnly = true
        await copiedBeforeTheKey(inserter, owner)
    }

    @Test func aCopyMadeBeforeThePasteKeyAfterARefusedWriteIsNotPastedWithoutClipboardAccess() async {
        let (inserter, owner) = ownedInserter(clipboardReadable: false)
        field.writes = .refuse
        await copiedBeforeTheKey(inserter, owner)
    }

    @Test func aCopyMadeBeforeThePasteKeyInABlockEditorIsNotPastedWithoutClipboardAccess() async {
        let (inserter, owner) = ownedInserter(clipboardReadable: false)
        field.web = true
        field.blocks = true
        field.text = "ab\ncd"
        field.selection = FieldRange(location: 3, length: 0)
        await copiedBeforeTheKey(inserter, owner, leaving: "ab\ncd")
        #expect(field.replaceRangeWrites == 0)
    }

    @Test func anInsertionAfterACopyMadeBeforeThePasteKeyPastesNormally() async {
        let (inserter, owner) = ownedInserter()
        inserter.pasteOnly = true
        await copiedBeforeTheKey(inserter, owner)
        field.onPlaceholderRead = nil
        // The newer copy is now the person's clipboard, and goes back.
        #expect(await inserter.insert("Y") == .inserted(.paste, clipboardRestored: true))
        #expect(field.text == "aYbc")
        #expect(pasteboard.string(forType: .string) == "another copy")
        #expect(owner.copy("an older dictation"))
        #expect(pasteboard.string(forType: .string) == "an older dictation")
    }

    // Another app copies inside Intention's own clipboard write, after Intention's
    // item is on the clipboard and before Intention reads the count again.
    // Without the count bound to Intention's write, that copy is taken for
    // Intention's and is what the key pastes.

    private let html = NSPasteboard.PasteboardType.html
    private let custom = NSPasteboard.PasteboardType("co.intention.tests.custom")

    /// An inserter whose clipboard writes go through, and whose first write
    /// is followed at once by another app's copy of "another copy" in three
    /// types.
    private func inserterWithACopyInsideTheWrite(clipboardReadable: Bool) -> (TextInserter, PasteboardOwner) {
        _ = inserter(clipboardReadable: clipboardReadable)
        let custom = custom
        var copied = false
        let owner = PasteboardOwner(pasteboard: pasteboard, mayRead: { clipboardReadable }, put: { pasteboard, item in
            let wrote = pasteboard.writeObjects([item])
            if !copied {
                copied = true
                pasteboard.clearContents()
                let other = NSPasteboardItem()
                other.setString("another copy", forType: .string)
                other.setString("<b>another copy</b>", forType: .html)
                other.setData(Data("custom data".utf8), forType: custom)
                pasteboard.writeObjects([other])
            }
            return wrote
        })
        return (TextInserter(pasteboard: owner), owner)
    }

    private func expectTheOtherCopy() {
        let items = pasteboard.pasteboardItems ?? []
        #expect(items.count == 1)
        #expect(items.first?.string(forType: .string) == "another copy")
        #expect(items.first?.string(forType: html) == "<b>another copy</b>")
        #expect(items.first?.data(forType: custom) == Data("custom data".utf8))
    }

    /// Inserts "X", which the copy inside the write stops, then "Y", which
    /// pastes as any insertion does.
    private func copiedInsideTheWrite(_ inserter: TextInserter, _ owner: PasteboardOwner, clipboardReadable: Bool) async {
        #expect(await inserter.insert("X") == .notInserted(.clipboardBusy))
        #expect(field.keys.isEmpty)
        #expect(field.text == "abc")
        expectTheOtherCopy()
        #expect(!owner.borrowed)
        #expect(await inserter.insert("Y") == .inserted(.paste, clipboardRestored: clipboardReadable))
        #expect(field.keys == ["paste"])
        #expect(field.text == "aYbc")
        if clipboardReadable {
            // The other copy is now the person's clipboard, and goes back.
            expectTheOtherCopy()
        } else {
            #expect(pasteboard.string(forType: .string) == "Y")
        }
        #expect(!owner.borrowed)
    }

    @Test func aCopyInsideTheClipboardWriteOfAForcedPasteIsNotPasted() async {
        let (inserter, owner) = inserterWithACopyInsideTheWrite(clipboardReadable: true)
        inserter.pasteOnly = true
        await copiedInsideTheWrite(inserter, owner, clipboardReadable: true)
    }

    @Test func aCopyInsideTheClipboardWriteAfterARefusedWriteIsNotPasted() async {
        let (inserter, owner) = inserterWithACopyInsideTheWrite(clipboardReadable: true)
        field.writes = .refuse
        await copiedInsideTheWrite(inserter, owner, clipboardReadable: true)
    }

    @Test func aCopyInsideTheClipboardWriteOfAForcedPasteIsNotPastedWithoutClipboardAccess() async {
        let (inserter, owner) = inserterWithACopyInsideTheWrite(clipboardReadable: false)
        inserter.pasteOnly = true
        await copiedInsideTheWrite(inserter, owner, clipboardReadable: false)
    }

    @Test func aCopyInsideTheClipboardWriteAfterARefusedWriteIsNotPastedWithoutClipboardAccess() async {
        let (inserter, owner) = inserterWithACopyInsideTheWrite(clipboardReadable: false)
        field.writes = .refuse
        await copiedInsideTheWrite(inserter, owner, clipboardReadable: false)
    }

    // Another process copies around Intention's clearing of the clipboard, in a
    // second process so that its clearing takes the clipboard from Intention's
    // as another app's does.

    /// Runs `work` while another process copies once around this test
    /// pasteboard's next clearing, at `race`.
    private func racingTheClearing(_ race: ClearingRace, _ work: () async -> Void) async {
        let real = class_getInstanceMethod(NSPasteboard.self, #selector(NSPasteboard.clearContents))!
        let racing = class_getInstanceMethod(NSPasteboard.self, #selector(NSPasteboard.clearContentsInARace))!
        Clearing.pasteboard = pasteboard.name
        Clearing.race = race
        method_exchangeImplementations(real, racing)
        await work()
        method_exchangeImplementations(real, racing)
        #expect(Clearing.pasteboard == nil, "the other process did not copy")
        Clearing.pasteboard = nil
    }

    /// A forced paste whose clipboard write fails, or goes through.
    private func forcedPaste(clipboardReadable: Bool, writeFails: Bool) -> (TextInserter, PasteboardOwner) {
        _ = inserter(clipboardReadable: clipboardReadable)
        let owner = PasteboardOwner(pasteboard: pasteboard, mayRead: { clipboardReadable },
                                    put: { pasteboard, item in writeFails ? false : pasteboard.writeObjects([item]) })
        let inserter = TextInserter(pasteboard: owner)
        inserter.pasteOnly = true
        return (inserter, owner)
    }

    @Test func aCopyJustBeforeTheClipboardIsClearedStillLetsTheWritePasteAndRestore() async {
        // Intention's clearing comes two counts after the count it last read.
        let (inserter, owner) = forcedPaste(clipboardReadable: true, writeFails: false)
        await racingTheClearing(.copyBefore) {
            #expect(await inserter.insert("X") == .inserted(.paste, clipboardRestored: true))
        }
        #expect(field.keys == ["paste"])
        #expect(field.text == "aXbc")
        #expect(pasteboard.pasteboardItems?.count == 1)
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
        #expect(!owner.borrowed)
    }

    @Test func aCopyJustBeforeTheClipboardIsClearedStillLetsAFailedWritePutTheCopyBack() async {
        let (inserter, owner) = forcedPaste(clipboardReadable: true, writeFails: true)
        await racingTheClearing(.copyBefore) {
            #expect(await inserter.insert("X") == .notInserted(.pasteUnavailable))
        }
        #expect(field.keys.isEmpty)
        #expect(field.text == "abc")
        #expect(pasteboard.pasteboardItems?.count == 1)
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
        #expect(!owner.borrowed)
    }

    @Test func aCopyJustBeforeTheClipboardIsClearedWithoutClipboardAccessLeavesThePastedText() async {
        // There is no copy to put back, and Intention's clearing erased the
        // other one.
        let (inserter, owner) = forcedPaste(clipboardReadable: false, writeFails: false)
        await racingTheClearing(.copyBefore) {
            #expect(await inserter.insert("X") == .inserted(.paste, clipboardRestored: false))
        }
        #expect(field.text == "aXbc")
        #expect(pasteboard.string(forType: .string) == "X")
        #expect(!owner.borrowed)
    }

    @Test func aCopyJustBeforeTheClipboardIsClearedWithoutClipboardAccessAndAFailedWriteLeavesItEmpty() async {
        let (inserter, owner) = forcedPaste(clipboardReadable: false, writeFails: true)
        await racingTheClearing(.copyBefore) {
            #expect(await inserter.insert("X") == .notInserted(.pasteUnavailable))
        }
        #expect(field.keys.isEmpty)
        #expect(field.text == "abc")
        #expect(pasteboard.pasteboardItems?.isEmpty != false)
        #expect(!owner.borrowed)
    }

    @Test func aCopyJustAfterTheClipboardIsClearedIsNotOverwrittenWhenTheCountMatchesIt() async {
        // The clearing answers the other process's count, and Intention's write
        // fails. Putting the copy back by that count would erase the other.
        let (inserter, owner) = forcedPaste(clipboardReadable: true, writeFails: false)
        await racingTheClearing(.copyAfter) {
            #expect(await inserter.insert("X") == .notInserted(.pasteUnavailable))
        }
        #expect(field.keys.isEmpty)
        #expect(field.text == "abc")
        expectTheOtherCopy()
        #expect(!owner.borrowed)
        // The other copy is now the person's clipboard, and goes back.
        #expect(await inserter.insert("Y") == .inserted(.paste, clipboardRestored: true))
        #expect(field.text == "aYbc")
        expectTheOtherCopy()
    }

    @Test func aComposedAccentReplacesADecomposedOneUnitForUnit() async {
        let inserter = inserter()
        // "e" with a combining accent, then "b". The two spellings are equal
        // as strings and different as text.
        field.text = "e\u{301}b"
        field.selection = FieldRange(location: 0, length: 2)
        #expect(await inserter.insert("\u{E9}") == .inserted(.selectedText, clipboardRestored: nil))
        #expect(Array(field.text.utf16) == Array("\u{E9}b".utf16))
    }

    @Test func aBlockFieldTurningSecureBeforeItsLengthProbeIsNotRead() async {
        // With a paragraph break the field's lengths differ, and the reader
        // probes for a character at the shorter one.
        let inserter = blockEditor("ab\ncd", FieldRange(location: 3, length: 0))
        field.onLengthRead = { [field] count in if count == 1 { field.secure = true } }
        _ = await inserter.insert("X")
        #expect(field.textReadsWhileSecure == 0)
        #expect(field.text == "ab\ncd")
    }

    @Test func pastingTextThatComparesEqualToTheSelectionIsConfirmed() async {
        let inserter = inserter()
        inserter.pasteOnly = true
        field.text = "a\u{00A0}b"
        field.selection = FieldRange(location: 0, length: 3)
        #expect(await inserter.insert("a b") == .inserted(.paste, clipboardRestored: true))
        #expect(field.text == "a b")
    }

    /// Text that compares equal to the selection, a non-breaking space for
    /// a space, would leave the field reading as it did, so no readback
    /// could tell the write from one still on its way. It is not written,
    /// and the words are reported in: the field shows them.
    @Test func textThatComparesEqualToTheSelectionIsNotWrittenAndIsReportedIn() async {
        let inserter = inserter()
        field.text = "a\u{00A0}b"
        field.selection = FieldRange(location: 0, length: 3)
        #expect(await inserter.insert("a b") == .inserted(.selectedText, clipboardRestored: nil))
        #expect(field.accessibilityWrites == 0)
        #expect(field.text == "a\u{00A0}b")
    }

    // A caller's guard on the field (`FocusedField.stillCurrent`), as the
    // writing flow attaches one to tell its compose from another. The field
    // is captured first, as that flow does when it is invoked, and the
    // scripted guard counts its calls from the insertion's start.

    private func guardedField(_ inserter: TextInserter) async -> FocusedField {
        guard case var .success(captured) = await inserter.readFocusedField().value.field else {
            preconditionFailure("the scripted field could not be captured")
        }
        captured.stillCurrent = { MockField.shared.stillCurrent() }
        field.lengthReads = 0
        return captured
    }

    @Test func aGuardThatPassesLeavesTheInsertionAsItWas() async {
        let inserter = inserter()
        let captured = await guardedField(inserter)
        #expect(await inserter.insert("X", into: captured) == .inserted(.selectedText, clipboardRestored: nil))
        #expect(field.text == "aXbc")
        // Asked when the insertion starts and in the check before the write.
        #expect(field.guardCalls == 2)
        #expect(field.guardCallsAtWrites == [2])
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func aGuardThatRefusesAtTheStartStopsTheInsertionBeforeTheFieldIsRead() async {
        let inserter = inserter()
        let captured = await guardedField(inserter)
        field.guardAnswer = { $0 == 1 ? .composeChanged : nil }
        #expect(await inserter.insert("X", into: captured) == .notInserted(.composeChanged))
        #expect(field.guardCalls == 1)
        // Refused before the inserter read anything of the field.
        #expect(field.lengthReads == 0)
        #expect(field.accessibilityWrites == 0)
        #expect(field.keys.isEmpty)
        #expect(field.text == "abc")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func aGuardThatRefusesInTheCheckBeforeTheWriteStopsTheWrite() async {
        let inserter = inserter()
        let captured = await guardedField(inserter)
        field.guardAnswer = { $0 == 2 ? .composeChanged : nil }
        #expect(await inserter.insert("X", into: captured) == .notInserted(.composeChanged))
        #expect(field.guardCalls == 2)
        #expect(field.accessibilityWrites == 0)
        #expect(field.keys.isEmpty)
        #expect(field.text == "abc")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func aGuardThatRefusesBeforeThePasteKeyOfARefusedWritePutsTheClipboardBack() async {
        let inserter = inserter()
        let captured = await guardedField(inserter)
        field.writes = .refuse
        // Asked at the start, before the write the field refuses, before
        // the clipboard is borrowed, and then before the key, once the
        // clipboard holds the text to paste.
        nonisolated(unsafe) var clipboardAtFourthCall: String?
        nonisolated(unsafe) let pasteboard = pasteboard
        field.onGuard = { call in if call == 4 { clipboardAtFourthCall = pasteboard.string(forType: .string) } }
        field.guardAnswer = { $0 == 4 ? .composeChanged : nil }
        #expect(await inserter.insert("X", into: captured) == .notInserted(.composeChanged))
        #expect(field.guardCalls == 4)
        #expect(clipboardAtFourthCall == "X")
        #expect(field.keys.isEmpty)
        #expect(field.text == "abc")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func aGuardThatRefusesBeforeTheClipboardIsBorrowedLeavesAClipboardIntentionCannotRead() async {
        // macOS does not let Intention read the clipboard, so there is no copy
        // to put back. The compose changes after the refused write: the
        // guard is asked before the clipboard is touched, and it stays.
        let inserter = inserter(clipboardReadable: false)
        let captured = await guardedField(inserter)
        field.writes = .refuse
        field.guardAnswer = { $0 == 3 ? .composeChanged : nil }
        #expect(await inserter.insert("X", into: captured) == .notInserted(.composeChanged))
        #expect(field.guardCalls == 3)
        #expect(field.keys.isEmpty)
        #expect(field.text == "abc")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func aGuardThatRefusesBeforeThePasteKeyOfAForcedPastePutsTheClipboardBack() async {
        let inserter = inserter()
        inserter.pasteOnly = true
        let captured = await guardedField(inserter)
        nonisolated(unsafe) var clipboardAtThirdCall: String?
        nonisolated(unsafe) let pasteboard = pasteboard
        field.onGuard = { call in if call == 3 { clipboardAtThirdCall = pasteboard.string(forType: .string) } }
        field.guardAnswer = { $0 == 3 ? .composeChanged : nil }
        #expect(await inserter.insert("X", into: captured) == .notInserted(.composeChanged))
        #expect(field.guardCalls == 3)
        #expect(clipboardAtThirdCall == "X")
        #expect(field.accessibilityWrites == 0)
        #expect(field.keys.isEmpty)
        #expect(field.text == "abc")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    // The caller's final check (`TextInserter.insert`'s `finalCheck`), as
    // an accepted reply proposal passes its latch and deadline: asked after
    // every read of the field, right before the write and the paste key.

    /// Counts the field's secure checks, the last read before a write or
    /// the key, those made before anything was written, and what the final
    /// check saw when it was asked.
    private final class FinalCheckLog: @unchecked Sendable {
        private let lock = NSLock()
        private var secureChecks = 0
        private var beforeAnyWrite = 0
        private var seen: [(secureChecks: Int, writes: Int, keys: Int)] = []

        func secureCheck() {
            let written = MockField.shared.accessibilityWrites > 0 || !MockField.shared.keys.isEmpty
            lock.withLock {
                secureChecks += 1
                if !written { beforeAnyWrite += 1 }
            }
        }

        var checksBeforeAnyWrite: Int { lock.withLock { beforeAnyWrite } }

        func asked() {
            let field = MockField.shared
            lock.withLock { seen.append((secureChecks, field.accessibilityWrites, field.keys.count)) }
        }

        var checks: Int { lock.withLock { secureChecks } }
        var calls: [(secureChecks: Int, writes: Int, keys: Int)] { lock.withLock { seen } }
    }

    @Test func aFinalCheckIsAskedAfterTheLastReadBeforeTheWrite() async {
        let inserter = inserter()
        let captured = await guardedField(inserter)
        let log = FinalCheckLog()
        field.onSecureCheck = { log.secureCheck() }
        let result = await inserter.insert("X", into: captured, finalCheck: {
            log.asked()
            return nil
        })
        #expect(result == .inserted(.selectedText, clipboardRestored: nil))
        #expect(field.text == "aXbc")
        // Asked once, after every secure check made before the write, and
        // with nothing written yet.
        let calls = log.calls
        #expect(calls.count == 1)
        #expect(calls.first?.writes == 0)
        #expect(calls.first?.secureChecks == log.checksBeforeAnyWrite)
    }

    @Test func aFinalCheckThatRefusesStopsTheWrite() async {
        let inserter = inserter()
        let captured = await guardedField(inserter)
        #expect(await inserter.insert("X", into: captured, finalCheck: { .composeChanged }) == .notInserted(.composeChanged))
        #expect(field.accessibilityWrites == 0)
        #expect(field.keys.isEmpty)
        #expect(field.text == "abc")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func aCopyDuringTheFinalCheckRefusesThePasteAndKeepsTheNewClipboard() async {
        let inserter = inserter()
        inserter.pasteOnly = true
        let captured = await guardedField(inserter)
        nonisolated(unsafe) let clipboard = pasteboard
        let result = await inserter.insert("X", into: captured, finalCheck: {
            clipboard.clearContents()
            clipboard.setString("newly copied text", forType: .string)
            return nil
        })
        #expect(result == .notInserted(.clipboardBusy))
        #expect(field.keys.isEmpty)
        #expect(field.text == "abc")
        #expect(pasteboard.string(forType: .string) == "newly copied text")
    }

    @Test func aFinalCheckThatRefusesBeforeThePasteKeyPutsTheClipboardBack() async {
        let inserter = inserter()
        inserter.pasteOnly = true
        let captured = await guardedField(inserter)
        let log = FinalCheckLog()
        field.onSecureCheck = { log.secureCheck() }
        nonisolated(unsafe) var clipboardWhenAsked: String?
        nonisolated(unsafe) let pasteboard = pasteboard
        let result = await inserter.insert("X", into: captured, finalCheck: {
            log.asked()
            clipboardWhenAsked = pasteboard.string(forType: .string)
            return .busy
        })
        #expect(result == .notInserted(.busy))
        // Asked once the clipboard held the text, after the last secure
        // check, and before the key.
        #expect(log.calls.count == 1)
        #expect(log.calls.first?.secureChecks == log.checks)
        #expect(log.calls.first?.keys == 0)
        #expect(clipboardWhenAsked == "X")
        #expect(field.keys.isEmpty)
        #expect(field.text == "abc")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    // The same final check on the path a waiting dictation's words take,
    // spaced for the text before the caret the write itself reads: asked
    // there too, after that read and every check of the field, right
    // before the write and the paste key.

    @Test func aFinalCheckIsAskedAfterTheLastReadBeforeASpacedWrite() async {
        let inserter = inserter()
        let captured = await guardedField(inserter)
        let log = FinalCheckLog()
        field.onSecureCheck = { log.secureCheck() }
        let inserted = await inserter.insert("X", into: captured, spaced: true, finalCheck: {
            log.asked()
            return nil
        })
        #expect(inserted.result == .inserted(.selectedText, clipboardRestored: nil))
        #expect(inserted.text == " X")
        #expect(field.text == "a Xbc")
        let calls = log.calls
        #expect(calls.count == 1)
        #expect(calls.first?.writes == 0)
        #expect(calls.first?.secureChecks == log.checksBeforeAnyWrite)
    }

    @Test(arguments: [false, true])
    func aFinalCheckThatRefusesStopsASpacedWriteOrItsPaste(paste: Bool) async {
        let inserter = inserter()
        inserter.pasteOnly = paste
        let captured = await guardedField(inserter)
        let log = FinalCheckLog()
        field.onSecureCheck = { log.secureCheck() }
        nonisolated(unsafe) var clipboardWhenAsked: String?
        nonisolated(unsafe) let pasteboard = pasteboard
        let inserted = await inserter.insert("X", into: captured, spaced: true, finalCheck: {
            log.asked()
            clipboardWhenAsked = pasteboard.string(forType: .string)
            return .composeChanged
        })
        #expect(inserted.result == .notInserted(.composeChanged))
        // Asked once, after the last secure check: for the paste once the
        // clipboard held the spaced text, before the key.
        #expect(log.calls.count == 1)
        #expect(log.calls.first?.secureChecks == log.checks)
        #expect(clipboardWhenAsked == (paste ? " X" : "the person's clipboard"))
        #expect(field.accessibilityWrites == 0)
        #expect(field.keys.isEmpty)
        #expect(field.text == "abc")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    /// A cancellation, as an accept's latch is set from the main actor,
    /// made while the inserter makes its final reads of the field.
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = false
        private var cancelled = false

        func arm() { lock.withLock { armed = true } }
        func cancel() { lock.withLock { cancelled = true } }
        /// Cancels once armed: on the read after the one that armed it.
        func cancelIfArmed() { lock.withLock { if armed { cancelled = true } } }
        var isCancelled: Bool { lock.withLock { cancelled } }

        var check: FocusedField.Guard { { [self] in isCancelled ? .composeChanged : nil } }
    }

    /// Where a cancellation lands among the final reads before a write: on
    /// the read named for the branch, or on the secure check after it, the
    /// very last read of the field.
    enum FinalRead: CaseIterable, Sendable {
        case named, lastSecureCheck
    }

    @Test(arguments: FinalRead.allCases)
    func aCancellationDuringTheRangeWritesFinalReadsStopsTheWrite(_ when: FinalRead) async {
        // The block editor takes the replace range at a caret mid-line.
        let inserter = blockEditor("abc", FieldRange(location: 1, length: 0))
        let cancellation = Cancellation()
        // The field's labels are the check's last reads before its secure
        // check; the second placeholder read is the check before the write,
        // the first having been made as the field was found.
        nonisolated(unsafe) var reads = 0
        field.onPlaceholderRead = {
            reads += 1
            guard reads == 2 else { return }
            switch when {
            case .named: cancellation.cancel()
            case .lastSecureCheck: cancellation.arm()
            }
        }
        field.onSecureCheck = { cancellation.cancelIfArmed() }
        #expect(await inserter.insert("X", finalCheck: cancellation.check) == .notInserted(.composeChanged))
        #expect(cancellation.isCancelled)
        #expect(field.replaceRangeWrites == 0)
        #expect(field.accessibilityWrites == 0)
        #expect(field.keys.isEmpty)
        #expect(field.text == "abc")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test(arguments: FinalRead.allCases)
    func aCancellationDuringTheMarkerOperationsFinalReadsStopsTheWrite(_ when: FinalRead) async {
        let inserter = inserter()
        field.document = true
        let cancellation = Cancellation()
        // The selection's markers are read for the write itself, after the
        // check before it; the secure check follows them.
        field.onSelectionMarkersRead = {
            switch when {
            case .named: cancellation.cancel()
            case .lastSecureCheck: cancellation.arm()
            }
        }
        field.onSecureCheck = { cancellation.cancelIfArmed() }
        #expect(await inserter.insert("X", finalCheck: cancellation.check) == .notInserted(.composeChanged))
        #expect(cancellation.isCancelled)
        #expect(field.markerSelectionReads.contains(.markers))
        #expect(field.accessibilityWrites == 0)
        #expect(field.keys.isEmpty)
        #expect(field.text == "abc")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    // The guard answers that nothing changed, and something did while it
    // was answering. Its answer is not the last word: the inserter's own
    // checks all come after it.

    /// An insertion whose guard passes every time, with `change` made to
    /// the field while the guard answers its call numbered `call`: the
    /// second is the check before the write or, with `paste`, the check
    /// before the clipboard is borrowed, and the third with `paste` the
    /// check before the key, once the clipboard holds the text.
    private func changedWhileTheGuardAnswers(paste: Bool, call: Int = 2, _ change: @escaping @Sendable (MockField) -> Void,
                                             expecting reason: EditReason) async {
        let inserter = inserter()
        inserter.pasteOnly = paste
        let captured = await guardedField(inserter)
        field.onGuard = { [field] count in if count == call { change(field) } }
        #expect(await inserter.insert("X", into: captured) == .notInserted(reason))
        #expect(field.guardCalls == call)
        #expect(field.accessibilityWrites == 0)
        #expect(field.keys.isEmpty)
        #expect(field.text == "abc")
        #expect(field.textReadsWhileSecure == 0)
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func focusMovingWhileTheGuardAnswersStopsTheWrite() async {
        await changedWhileTheGuardAnswers(paste: false, { $0.focusedElsewhere = true }, expecting: .focusChanged)
    }

    @Test func aFieldTurningSecureWhileTheGuardAnswersStopsTheWrite() async {
        await changedWhileTheGuardAnswers(paste: false, { $0.secure = true }, expecting: .secureField)
    }

    @Test func aSelectionMovedWhileTheGuardAnswersStopsTheWrite() async {
        await changedWhileTheGuardAnswers(paste: false, { $0.selection = FieldRange(location: 3, length: 0) }, expecting: .fieldChanged)
    }

    @Test(arguments: [2, 3]) func focusMovingWhileTheGuardAnswersStopsThePaste(call: Int) async {
        await changedWhileTheGuardAnswers(paste: true, call: call, { $0.focusedElsewhere = true }, expecting: .focusChanged)
    }

    @Test(arguments: [2, 3]) func aFieldTurningSecureWhileTheGuardAnswersStopsThePaste(call: Int) async {
        await changedWhileTheGuardAnswers(paste: true, call: call, { $0.secure = true }, expecting: .secureField)
    }

    @Test(arguments: [2, 3]) func aSelectionMovedWhileTheGuardAnswersStopsThePaste(call: Int) async {
        await changedWhileTheGuardAnswers(paste: true, call: call, { $0.selection = FieldRange(location: 3, length: 0) },
                                          expecting: .fieldChanged)
    }

    @Test func focusMovingWhileTheGuardFirstAnswersIsCaughtWithoutAskingItAgain() async {
        let inserter = inserter()
        let captured = await guardedField(inserter)
        field.onGuard = { [field] call in if call == 1 { field.focusedElsewhere = true } }
        #expect(await inserter.insert("X", into: captured) == .notInserted(.focusChanged))
        // The field is matched after the guard's first answer, so the move
        // is seen there and the guard is not asked a second time.
        #expect(field.guardCalls == 1)
        #expect(field.accessibilityWrites == 0)
        #expect(field.text == "abc")
    }

    // Once a write or a key was issued the guard is not asked again: its
    // answer could no longer stop anything, and the results and the
    // clipboard are what they are without a guard.

    @Test func theGuardIsNotAskedWhileAnAcceptedWriteIsWaitedFor() async {
        let inserter = inserter()
        let captured = await guardedField(inserter)
        field.writes = .held
        // The field shows the write a moment after accepting it, while the
        // inserter is reading it back.
        field.landsAfterLengthReads = 5
        #expect(await inserter.insert("X", into: captured) == .inserted(.selectedText, clipboardRestored: nil))
        #expect(field.text == "aXbc")
        #expect(field.guardCallsAtWrites == [2])
        #expect(field.guardCalls == 2)
    }

    @Test func theGuardIsNotAskedAfterAnAcceptedWriteThatNeverShows() async {
        let inserter = inserter()
        let captured = await guardedField(inserter)
        field.writes = .held
        #expect(await inserter.insert("X", into: captured) == .unknown(.writeUnconfirmed))
        #expect(field.guardCallsAtWrites == [2])
        #expect(field.guardCalls == 2)
        #expect(field.keys.isEmpty)
        #expect(field.text == "abc")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
        // The app applies the write after Intention stopped waiting.
        field.land()
        #expect(field.text == "aXbc")
        #expect(field.guardCalls == 2)
    }

    @Test func theGuardIsNotAskedAfterAPasteKeyThatIsNotConfirmed() async {
        _ = inserter()
        let owner = PasteboardOwner(pasteboard: pasteboard, mayRead: { true })
        let inserter = TextInserter(pasteboard: owner)
        let captured = await guardedField(inserter)
        field.writes = .refuse
        field.pastesLand = false
        #expect(await inserter.insert("replacement", into: captured) == .unknown(.writeUnconfirmed))
        // Asked at the start, before the refused write, before the
        // clipboard is borrowed and before the key.
        #expect(field.guardCallsAtWrites == [2])
        #expect(field.guardCallsAtKeys == [4])
        #expect(field.guardCalls == 4)
        // As without a guard: the text stays on the clipboard, which other
        // clipboard writes leave alone.
        #expect(!owner.copy("an older dictation"))
        #expect(pasteboard.string(forType: .string) == "replacement")
    }

    @Test func aReasonTheGuardGivesIsTheInsertionsResult() async {
        let inserter = inserter()
        let captured = await guardedField(inserter)
        field.guardAnswer = { $0 == 1 ? .targetUnresponsive : nil }
        #expect(await inserter.insert("X", into: captured) == .notInserted(.targetUnresponsive))
        field.guardAnswer = { $0 == 3 ? .unreadableField : nil }
        #expect(await inserter.insert("X", into: captured) == .notInserted(.unreadableField))
        #expect(field.guardCalls == 3)
        #expect(field.accessibilityWrites == 0)
        #expect(field.text == "abc")
    }

    // A copy made while the guard answers before the paste key, which can
    // take a while: the clipboard is checked again after it.

    @Test func aCopyMadeWhileTheGuardAnswersBeforeThePasteKeyIsNotPasted() async {
        let (inserter, owner) = ownedInserter()
        inserter.pasteOnly = true
        let captured = await guardedField(inserter)
        let copy = copyWhileHolding("X")
        field.onGuard = { call in if call == 3 { copy() } }
        #expect(await inserter.insert("X", into: captured) == .notInserted(.clipboardBusy))
        #expect(field.guardCalls == 3)
        #expect(field.keys.isEmpty)
        #expect(field.text == "abc")
        #expect(pasteboard.string(forType: .string) == "another copy")
        #expect(!owner.borrowed)
    }

    @Test func aCopyMadeWhileTheGuardAnswersBeforeThePasteKeyIsNotPastedWithoutClipboardAccess() async {
        let (inserter, owner) = ownedInserter(clipboardReadable: false)
        let captured = await guardedField(inserter)
        field.writes = .refuse
        let copy = copyWhileHolding("X")
        field.onGuard = { call in if call == 4 { copy() } }
        #expect(await inserter.insert("X", into: captured) == .notInserted(.clipboardBusy))
        #expect(field.guardCalls == 4)
        #expect(field.keys.isEmpty)
        #expect(field.text == "abc")
        #expect(pasteboard.string(forType: .string) == "another copy")
        #expect(!owner.borrowed)
    }

    @Test func theGuardIsCalledOnTheInsertersAccessibilityThread() async {
        let inserter = inserter()
        let captured = await guardedField(inserter)
        field.writes = .refuse
        #expect(await inserter.insert("X", into: captured) == .inserted(.paste, clipboardRestored: true))
        #expect(field.guardThreads.count == 4)
        #expect(field.guardThreads.map(\.name) == Array(repeating: "co.intention.mac.accessibility", count: 4))
        #expect(field.guardThreads.allSatisfy { !$0.isMainThread })
        // The one thread the inserter's own Accessibility calls ran on.
        #expect(field.secureCheckThreads.count == 1)
        #expect(Set(field.guardThreads) == field.secureCheckThreads)
    }

    // Each comparison that keeps a write out of a field whose text moved
    // while it was observed, pinned on its own. The field is a long run of
    // one character, so a change shows only in the slice or the length
    // that comparison reads. Each slice is changed at both of its ends, so
    // its whole 64 units are compared. The field's length is read when it
    // is observed, again in the recheck right before the write, and then
    // for each readback: the first readback's own, then the unchanged
    // probe's.

    /// 200 "b"s with the caret in the middle: the 64 compared before it
    /// are at 36 to 99, the 64 after it at 100 to 163.
    private func longRun() -> TextInserter {
        let inserter = inserter()
        field.text = String(repeating: "b", count: 200)
        field.selection = FieldRange(location: 100, length: 0)
        return inserter
    }

    /// The 200 "b"s with the one at `place` turned to "c".
    nonisolated private static func longRun(changedAt place: Int) -> String {
        String(repeating: "b", count: place) + "c" + String(repeating: "b", count: 199 - place)
    }

    @Test(arguments: [0, 63]) func textAfterTheCaretChangedAsTheWriteIsConfirmedIsNotConfirmed(placesAfter: Int) async {
        let inserter = longRun()
        // The write lands, and as it is read back a "b" right after the
        // inserted text, or the last of the 64 after it, becomes "c": its
        // place, the text before it and the field's length are all as
        // expected.
        field.onLengthRead = { [field] count in
            if count == 3 {
                field.text = String(repeating: "b", count: 100) + "X" + String(repeating: "b", count: placesAfter) + "c"
                    + String(repeating: "b", count: 99 - placesAfter)
            }
        }
        #expect(await inserter.insert("X") == .unknown(.readbackMismatch))
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
    }

    @Test(arguments: [36, 99]) func textBeforeTheCaretChangedBeforeTheWriteIsNotWrittenTo(place: Int) async {
        let inserter = longRun()
        // In the recheck the first or the last "b" of the 64 before the
        // caret becomes "c".
        field.onLengthRead = { [field] count in if count == 2 { field.text = Self.longRun(changedAt: place) } }
        #expect(await inserter.insert("X") == .notInserted(.fieldChanged))
        #expect(field.accessibilityWrites == 0)
        #expect(field.text == Self.longRun(changedAt: place))
    }

    @Test(arguments: [100, 163]) func textAfterTheCaretChangedBeforeTheWriteIsNotWrittenTo(place: Int) async {
        let inserter = longRun()
        // In the recheck the first or the last "b" of the 64 after the
        // caret becomes "c".
        field.onLengthRead = { [field] count in if count == 2 { field.text = Self.longRun(changedAt: place) } }
        #expect(await inserter.insert("X") == .notInserted(.fieldChanged))
        #expect(field.accessibilityWrites == 0)
        #expect(field.text == Self.longRun(changedAt: place))
    }

    @Test func aFieldThatGrowsOutsideTheComparedContextBeforeTheWriteIsNotWrittenTo() async {
        let inserter = longRun()
        // In the recheck one more "b" arrives at the end, beyond the 64
        // units after the caret: every slice reads as it did, and only the
        // field's length shows it.
        field.onLengthRead = { [field] count in if count == 2 { field.text += "b" } }
        #expect(await inserter.insert("X") == .notInserted(.fieldChanged))
        #expect(field.accessibilityWrites == 0)
        #expect(field.text == String(repeating: "b", count: 201))
    }

    @Test func aFieldThatShrinksOutsideTheComparedContextBeforeTheWriteIsNotWrittenTo() async {
        let inserter = longRun()
        // In the recheck the last "b" goes, beyond the 64 units after the
        // caret: only the field's length shows it.
        field.onLengthRead = { [field] count in if count == 2 { field.text.removeLast() } }
        #expect(await inserter.insert("X") == .notInserted(.fieldChanged))
        #expect(field.accessibilityWrites == 0)
        #expect(field.text == String(repeating: "b", count: 199))
    }

    @Test(arguments: [36, 99]) func anIgnoredWriteBesideTextBeforeTheCaretThatChangedIsNotReadAsIgnored(place: Int) async {
        let inserter = longRun()
        field.writes = .ignore
        // The field does not show the write, and as it is read back the
        // first or the last "b" of the 64 before the caret becomes "c": the
        // field no longer reads as it did, so nothing shows that the write
        // was ignored.
        field.onLengthRead = { [field] count in if count == 3 { field.text = Self.longRun(changedAt: place) } }
        #expect(await inserter.insert("X") == .unknown(.readbackMismatch))
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
    }

    @Test(arguments: [100, 163]) func anIgnoredWriteBesideTextAfterTheCaretThatChangedIsNotReadAsIgnored(place: Int) async {
        let inserter = longRun()
        field.writes = .ignore
        // As above, with the first or the last "b" of the 64 after the
        // caret becoming "c".
        field.onLengthRead = { [field] count in if count == 3 { field.text = Self.longRun(changedAt: place) } }
        #expect(await inserter.insert("X") == .unknown(.readbackMismatch))
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
    }

    @Test func aDocumentFieldWhoseMarkersStopAnsweringBeforeTheWriteIsNotWritten() async {
        let inserter = inserter()
        field.document = true
        // The selection's markers are read for its offsets when the field
        // is observed and in the recheck, and then for the markers
        // themselves, which the write goes to. That last read does not
        // answer.
        field.markerSelectionUnansweredAt = 3
        #expect(await inserter.insert("X") == .notInserted(.fieldChanged))
        #expect(field.markerSelectionReads == [.offsets, .offsets, .markers])
        #expect(field.accessibilityWrites == 0)
        #expect(field.keys.isEmpty)
        #expect(field.text == "abc")
    }
}

extension TextInserterScenarioTests {
    @Test func aTransientFocusedElementFailureGetsOneReadBeforeWriting() async {
        let inserter = inserter()
        field.onFocusRead = {
            MockField.shared.focusFailure = MockField.shared.focusReads == 1 ? .failure : nil
        }
        #expect(await inserter.insert("X") == .inserted(.selectedText, clipboardRestored: nil))
        #expect(field.text == "aXbc")
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
    }

    @Test func repeatedFocusedElementFailuresStopAfterTwoReads() async {
        let inserter = inserter()
        field.focusFailure = .failure
        #expect(await inserter.insert("X") == .notInserted(.noTextField))
        #expect(field.focusReads == 2)
        #expect(field.accessibilityWrites == 0)
        #expect(field.keys.isEmpty)
    }

    @Test func aTargetRereadCannotAdoptAnotherField() async {
        let inserter = inserter()
        field.windowUnanswered = true
        field.onFocusRead = {
            if MockField.shared.focusReads == 2 {
                MockField.shared.windowUnanswered = false
                MockField.shared.focusedElement = 2
            }
        }
        #expect(await inserter.insert("X") == .notInserted(.focusChanged))
        #expect(field.accessibilityWrites == 0)
        #expect(field.keys.isEmpty)
    }

    @Test func aSecureFieldOnTheRereadNeverHasItsTextRead() async {
        let inserter = inserter()
        field.onFocusRead = {
            let f = MockField.shared
            f.focusFailure = f.focusReads == 1 ? .failure : nil
            if f.focusReads == 2 { f.secure = true }
        }
        #expect(await inserter.insert("X") == .notInserted(.secureField))
        #expect(field.textReadsWhileSecure == 0)
        #expect(field.accessibilityWrites == 0)
        #expect(field.keys.isEmpty)
    }

    @Test(arguments: ["Hello world", "Hello\nworld", "Hello\n\nworld", String(repeating: "a", count: 80) + "\n\n" + String(repeating: "a", count: 80)])
    func gmailCanConsumeItsPlaceholderAndCountPastedParagraphs(text: String) async {
        let inserter = blockEditor("\n", FieldRange(location: 0, length: 0))
        field.bundleIdentifier = "com.google.Chrome"
        field.label = "Message Body"
        field.pageURL = "https://mail.google.com/mail/u/0/#inbox"
        field.onKey = { MockField.shared.text = "" }
        #expect(await inserter.insert(text) == .inserted(.paste, clipboardRestored: true))
        #expect(field.text == text)
        #expect(field.keys == ["paste"])
        #expect(field.accessibilityWrites == 0)
    }

    @Test(arguments: ["Hello\nwrong", "Hello\n\nworld extra", "Hello", ""])
    func gmailPlaceholderToleranceDoesNotConfirmChangedOrMissingText(shown: String) async {
        let inserter = blockEditor("\n", FieldRange(location: 0, length: 0))
        field.bundleIdentifier = "com.google.Chrome"
        field.label = "Message Body"
        field.pageURL = "https://mail.google.com/mail/u/0/#inbox"
        field.onEdit = { MockField.shared.text = shown }
        guard case .unknown = await inserter.insert("Hello\n\nworld") else {
            Issue.record("A partial or changed paste must stay uncertain")
            return
        }
        #expect(field.keys == ["paste"])
        #expect(field.accessibilityWrites == 0)
    }

    @Test func anAcceptedUncertainWriteNeverFallsBackOrWritesAgain() async {
        let inserter = inserter()
        field.writes = .held
        #expect(await inserter.insert("one") == .unknown(.writeUnconfirmed))
        #expect(await inserter.insert("two") == .notInserted(.earlierUnsettled))
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
        #expect(field.text == "abc")
    }

    @Test(arguments: [("a\nb", "ab\n"), ("aaaa\naaaa", "aaaaaaa\na")])
    func gmailDoesNotConfirmMovedParagraphBoundaries(text: String, shown: String) async {
        let inserter = blockEditor("\n", FieldRange(location: 0, length: 0))
        field.bundleIdentifier = "com.google.Chrome"
        field.label = "Message Body"
        field.pageURL = "https://mail.google.com/mail/u/0/#inbox"
        field.pastesLand = false
        field.onKey = { MockField.shared.text = shown }
        #expect(await inserter.insert(text) == .unknown(.readbackMismatch))
        #expect(field.keys == ["paste"])
        #expect(field.accessibilityWrites == 0)
    }

    @Test(arguments: ["blocks", "value", "secure"])
    func gmailRequiresIndependentParagraphEvidence(check: String) async {
        let inserter = blockEditor("\n", FieldRange(location: 0, length: 0))
        field.bundleIdentifier = "com.google.Chrome"
        field.label = "Message Body"
        field.pageURL = "https://mail.google.com/mail/u/0/#inbox"
        field.onKey = { MockField.shared.text = "" }
        field.onEdit = {
            let f = MockField.shared
            switch check {
            case "blocks": f.childrenUnanswered = true
            case "value": f.valueUnanswered = true
            default: f.onOtherRead = { MockField.shared.secure = true }
            }
        }
        guard case .unknown = await inserter.insert("a\nb") else { Issue.record("Missing evidence must remain uncertain"); return }
        #expect(field.keys == ["paste"])
        #expect(field.accessibilityWrites == 0)
        #expect(field.textReadsWhileSecure == 0)
    }
}
