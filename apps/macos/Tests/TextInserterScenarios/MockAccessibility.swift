import AppKit
import ApplicationServices

// A scripted stand-in for the Accessibility layer, compiled with the
// production TextInserter by scripts/test-text-inserter.sh in place of
// AXElement.swift, AXWritingSurface.swift and KeyEvents.swift. Nothing here
// reaches a real app or the person's clipboard: posted keys edit the
// scripted field, and pastes read the test's private pasteboard.

func AXIsProcessTrusted() -> Bool { true }

struct AXFailure: Error, Equatable {
    let code: AXError
    var isTimeout: Bool { code == .cannotComplete }
    var isPermissionDenied: Bool { code == .apiDisabled }
}

/// Snapshot and insertion reads can run on separate Accessibility threads.
/// Protect the fake's shared read counters and collections as real AX would.
@propertyWrapper
final class MockLocked<Value>: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var value: Value
    init(wrappedValue: Value) { value = wrappedValue }
    var wrappedValue: Value {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); defer { lock.unlock() }; value = newValue }
        _modify { lock.lock(); defer { lock.unlock() }; yield &value }
    }
}

/// One text field in another app, as the scenarios script it.
final class MockField: @unchecked Sendable {
    enum Writes {
        /// Applies Accessibility writes at once.
        case apply
        /// Accepts writes and never applies them.
        case ignore
        /// Refuses writes with an error.
        case refuse
        /// Accepts writes and holds them until `land()`, as a busy app that
        /// applies a write after Intention has stopped waiting for it.
        case held
        /// Does not answer a write in time and holds it until `land()`, as
        /// a hung app that applies it once it catches up.
        case unanswered
    }

    nonisolated(unsafe) static var shared = MockField()

    @MockLocked var text = "abc"
    @MockLocked var selection = FieldRange(location: 1, length: 0)
    var focused = true
    /// Which field has focus; changing it is focus moving to another field.
    var focusedElement = 1
    /// Changing it replaces the focused field's Accessibility object without
    /// moving focus, as Chrome sometimes does.
    var objectGeneration = 0
    /// Changing it puts a new page where the web field's page was, as a
    /// reload or another tab does, or as Chrome does when it rebuilds a
    /// page's whole tree for the same document.
    var pageGeneration = 0
    /// Which page the focused web field is in: another value is another
    /// page, such as another tab's, while the first stays open.
    var pageID = -1
    /// Which window has focus, by generation; changing it alone moves focus
    /// to another window, and `closedWindows` says which have closed.
    var windowGeneration = 0
    var closedWindows: Set<Int> = []
    /// No field, page or window answers for its role, as an app too busy to
    /// say whether an object is still there: it is not gone, as a read
    /// that timed out is not, and not there either.
    var identityUnanswered = false
    /// The field's description, which an app reusing one composer across
    /// channels changes with the channel.
    var label = "Message #general"
    var domClassList: [String] = []
    var domClassListUnanswered = false
    var descriptionUnanswered = false
    var windowUnanswered = false
    var focusFailure: AXError?
    /// The field answers for neither its selection nor its text.
    var unreadable = false
    /// Seconds the app takes to answer which element has focus.
    var focusReadDelay: TimeInterval = 0
    /// Another field of the same app has keyboard focus.
    var focusedElsewhere = false
    /// The app does not answer which element has focus in time.
    var focusUnanswered = false
    var web = false
    /// The width every field reports in its frame.
    var frameWidth: CGFloat = 300
    /// The height every field reports in its frame; zero is Gmail's empty
    /// reply body, which reports a width and no height.
    var frameHeight: CGFloat = 40
    /// Set, a web field's page sits in a scroll area with this frame,
    /// between its web area and the window, as a browser's page view does.
    var scrollArea: CGRect?
    /// Set, the frame the window reports.
    var windowFrame: CGRect?
    /// Set, the bounds a field reports for any range of its text, as
    /// Chromium gives a selection's; unset, the attribute is unsupported.
    var rangeBounds: CGRect?
    /// How many times a range's bounds were asked for.
    var rangeBoundsReads = 0
    var rangeBoundsDelay: TimeInterval = 0
    var rangeBoundsTimeouts: [Float?] = []
    /// The top of every field's frame, in Accessibility coordinates; a
    /// scenario changes it as the page scrolls the body.
    var fieldTop: CGFloat = 100
    /// Runs on each read of a frame, with the element's id: a field's own,
    /// the scroll area's (`AXElement.scrollAreaID`) or the window's (0), as
    /// something that happens while the frames are sampled.
    var onFrameRead: (@Sendable (Int) -> Void)?
    /// Every read of a field's own attributes, its frame as "AXFrame",
    /// by the field's id: what a read made for one field may never ask of
    /// another. Reads of which element has focus are not counted.
    private let fieldReadsLock = NSLock()
    private var recordedFieldReads: [Int: [String]] = [:]
    var fieldReads: [Int: [String]] {
        get { fieldReadsLock.withLock { recordedFieldReads } }
        set { fieldReadsLock.withLock { recordedFieldReads = newValue } }
    }

    func recordRead(of id: Int, _ attribute: String) {
        guard id > 0 else { return }
        // Separate inserters have separate AX executors but share this fixture.
        fieldReadsLock.withLock { recordedFieldReads[id, default: []].append(attribute) }
    }
    /// The focused element's role in place of a text area's, as a custom
    /// editor, a button or a window answers. A role other than a text
    /// field's, a text area's or a combo box's is not one `surface` admits.
    var role: String?
    /// Whether the field reports its value and its selected text as
    /// settable; false is Terminal's text area, which reports only its
    /// selection range.
    var settable = true
    /// Whether the field's selection can be set; false with `settable`
    /// false is read-only text.
    var rangeSettable = true
    /// A selection write is accepted but has no effect.
    var selectionWritesIgnored = false
    var selectionWrites = 0
    /// Runs after a selection write, for a concurrent edit or focus change.
    var onSelectionWrite: (@Sendable () -> Void)?
    /// Runs while the markers for a caret collapse are made.
    var onCaretMarkersRead: (@Sendable () -> Void)?
    var caretMarkersUnanswered = false
    /// The focused window exposes no text anywhere in it, as an app that
    /// draws its own text does.
    var bareWindow = false
    /// Answers for the scans of the window, one each, before `bareWindow`
    /// answers the rest: a window that gains a text field, or a password
    /// field, while Intention pastes into it.
    var bareAnswers: [Bool] = []
    /// What a window that is not bare holds: a password field, or one
    /// that might be, rather than plain text.
    var secureInWindow = false
    @MockLocked var bareScans = 0
    /// Another app, whose process is launchd's, has keyboard focus and
    /// answers that nothing in it has focus.
    var otherAppFocused = false
    /// The process every field answers it belongs to, a running one with a
    /// start time, as a field of another app does; nil is the test
    /// runner's parent.
    var appPID: pid_t?
    var secure = false
    var secureAfterWrite = false
    var writes = Writes.apply
    /// The field's description after a refused write, as an app reusing the
    /// composer for another channel while Intention turns to pasting.
    var labelAfterRefusal: String?
    /// Whether a posted paste edits the field; false is an app too busy to
    /// read the clipboard yet.
    var pastesLand = true
    /// Moves the selection here on the next length read, as a person moving
    /// the caret while Intention observes the field.
    var moveSelectionOnRead: FieldRange?
    /// A web area that is itself the editable text, as Mail's message body
    /// is: no selection range or character count, an empty value, markers
    /// for its selection and length, and the marker text operation. Its
    /// AXReplaceRangeWithText writes at the start whatever range it is given,
    /// as WebKit's does there.
    var document = false
    /// The text operation selects its range and answers with the text there,
    /// as a WebKit that does not know the operation.
    var textOperationUnknown = false
    /// A Chromium field that starts with an element its tree leaves out,
    /// as Gmail's empty compose body starts with Gemini's hint: the field
    /// reads as its placeholder line break alone, and a replace range at
    /// offset 0 is accepted and lands nowhere, while a paste goes in at the
    /// caret.
    var hiddenPlaceholder = false
    /// A Chromium editor showing a CSS placeholder, as `ce-before` in the
    /// dot fixture: `text` is the generated text, which the field reports
    /// as its value with the caret after it, and its static text lists no
    /// editable ancestor. A replace range is accepted and changes
    /// nothing, and a paste replaces the generated text, as Chromium 156
    /// did (support matrix, October 7, 2026).
    var generatedPlaceholder = false
    /// The walk that tells generated text from the person's does not
    /// answer.
    var generatedUnanswered = false
    /// What a rich editor makes of the text an Accessibility write puts
    /// in, as one that capitalizes a sentence or corrects a word as it
    /// goes; nil leaves it as written. Typing and pastes are not changed.
    var reformat: (@Sendable (String) -> String)?
    /// A web editor that keeps each line in its own block, as Slack's does.
    /// `text` holds a line break between blocks, as the field's value and
    /// character count do, while `selection`, ranged reads and writes take
    /// offsets that leave those breaks out, as Chromium's do.
    var blocks = false
    /// Literal `<br>` offsets inside Chromium blocks, rather than boundaries.
    var literalBlockBreaks: Set<Int> = []
    /// A web editor that keeps each line in its own block, as WebKit shows
    /// one. `text`, the selection, a replace range and the markers hold one
    /// line break between blocks. Ranged reads, the value and the character
    /// count hold two.
    var doubles = false
    /// Line breaks of a WebKit editor that are a `<br>` and so count once
    /// in its ranged reads, value and count, as places in `text`.
    var singleBreaks: Set<Int> = []
    /// A WebKit editor that keeps each line in its own block and counts
    /// the break between two the same way everywhere, as one whose lines
    /// are plain `div` elements does. It is WebKit's in what it offers.
    var lines = false
    /// A WebKit field of one block whose counts all agree, such as a text
    /// area. It is WebKit's in what it offers.
    var webKitPlain = false
    /// A replace range writes text that starts with a line break with one
    /// break more, an empty line before the text, as WebKit's editable
    /// elements and editors do.
    var leadingBreakAddsLine = false
    /// The range a WebKit field gives for its own text ends at the caret,
    /// as it stays after an edit that split or joined the field's blocks.
    var ownEndAtCaret = false
    /// The range a WebKit field gives for its own text ends at this place
    /// in `text`, as it ends before an image in the field's last block,
    /// while every other read is right.
    var ownEnd: Int?
    /// The range of the field's last descendant ends this many units
    /// short of its text.
    var lastEndShortBy = 0
    /// The field's last block ends in an image with alt text: one unit
    /// more by the markers, U+FFFC in their text, after the end of the
    /// field's own range, and nothing in any other read.
    var trailingAttachment = false
    /// U+E000 in a WebKit editor's `text` is an image with alt text, as
    /// the WebKit host measured one: one unit by the markers' lengths and
    /// U+FFFC in their text, and nothing in the selection, a replace range,
    /// the ranged reads, the value and the count. A replace range whose
    /// start sits at the image lands before it, and one that ends after the
    /// text following it removes it, as WebKit's did. A U+FFFC in `text`
    /// is one typed as text, which every read holds.
    static let image: UInt16 = 0xE000
    var hasImages: Bool { text.utf16.contains(Self.image) }
    /// A list in a WebKit editor: the label its markers read in front of a
    /// line of `text`, by the line's place among the lines. A label has no
    /// length and no offset in any read; only the markers' text holds it.
    var listLabels: [Int: String] = [:]
    /// The range a WebKit field gives for its own text ends this many
    /// units before the end of `text`, as it ends before a `<br>` that
    /// stands in front of a trailing image.
    var ownEndShortBy = 0
    /// The range of the field's last block, or its children, do not answer.
    var lastBlockMarkersUnanswered = false
    var lastBlockChildrenUnanswered = false
    /// The field's whole text by its markers does not answer.
    var wholeTextUnanswered = false
    /// More text in the field's whole text by its markers than their length
    /// counts, as WebKit reads a list's bullets.
    var wholeTextExtra = ""
    /// Runs when the range the field gives for its own text is read.
    var onWholeMarkersRead: (@Sendable () -> Void)?
    /// Runs when a web field's text is read by markers.
    var onMarkerTextRead: (@Sendable () -> Void)?
    /// The field's character count, or its length by markers, does not
    /// answer.
    var countUnanswered = false
    /// The independent value corroboration does not answer.
    var valueUnanswered = false
    var markerLengthUnanswered = false
    /// The field does not answer for the parameterized attributes it
    /// offers.
    var namesUnanswered = false
    /// It does not answer for them this many times, and then does.
    var namesUnansweredTimes = 0
    /// The ranged read named by `failingRead` goes unanswered in time,
    /// where it otherwise fails as a range outside the text does.
    var failingReadTimesOut = false
    /// Applies a held write on this many length reads from now, as an app
    /// that shows a write while Intention is still polling for it.
    var landsAfterLengthReads: Int?
    /// Runs right after a held write lands, as an edit the person makes in
    /// the same moment.
    var onLand: (@Sendable () -> Void)?
    /// A range whose ranged read fails.
    var failingRead: FieldRange?
    /// Runs on each read of the field's length, with how many there have
    /// been, as something that happens while Intention observes the field.
    var onLengthRead: (@Sendable (Int) -> Void)?
    @MockLocked var lengthReads = 0
    /// Runs when the selection's markers are read.
    var onSelectionMarkersRead: (@Sendable () -> Void)?
    /// The field's children do not answer.
    var childrenUnanswered = false
    /// Runs when the ranged read named by `failingRead` fails, and on each
    /// check of whether the field is secure.
    var onFailedRead: (@Sendable () -> Void)?
    var onSecureCheck: (@Sendable () -> Void)?
    /// What the next checks of whether the field is secure answer, in
    /// order, before they answer `secure` again: nil is a walk of the field
    /// and its ancestors that did not answer, as a subrole read that timed
    /// out does.
    var secureAnswers: [Bool?] = []
    /// Reads of which element has focus so far, and what runs as each is
    /// read, such as focus moving.
    @MockLocked var focusReads = 0
    var onFocusRead: (@Sendable () -> Void)?
    /// Runs as a dictation notes the focused field
    /// (`FieldAccess.focusedField`), which first asks the app to build its
    /// accessibility tree.
    var onFieldNoted: (@Sendable () -> Void)?
    /// Runs when the field's placeholder is read, the last of its labels and
    /// so the last read of the check right before a write or the paste key.
    var onPlaceholderRead: (@Sendable () -> Void)?
    /// The field does not answer what its selection is, by its range or by
    /// its markers.
    var selectionUnanswered = false
    /// The read of the selection's markers, counted from one, that does
    /// not answer, as a WebKit field whose markers stop answering for a
    /// moment.
    var markerSelectionUnansweredAt: Int?
    /// A read of the selection's markers: for the selection's offsets, as
    /// the field's state is read, or for the markers themselves, as the
    /// text operation is written at them.
    enum MarkerSelectionRead { case offsets, markers }
    /// Each read of the selection's markers, in order.
    @MockLocked var markerSelectionReads: [MarkerSelectionRead] = []
    /// The app accepts posted keys and has not handled them yet.
    var keysPending = false
    /// Runs when a key is posted.
    var onKey: (@Sendable () -> Void)?
    /// Pasted text that starts with a line break gets a paragraph break
    /// before it as well, as Chromium pastes it into a block editor.
    var pasteAddsParagraphBreak = false
    var pasteboard: NSPasteboard?
    /// How many reads of anything beyond the focused field, its window's
    /// identity aside: an email's text is read from the field alone, never
    /// from a window's other controls, and the compose scenarios count on
    /// it. Telling a Gmail body reads three things beyond the field: the
    /// element above it, that it is a web area, and the page's address.
    /// Telling Mail's reads the window's role and children, and the role
    /// and identifier of each element on the way to its To field: four in
    /// the default window.
    @MockLocked var readsBeyondField = 0
    /// An element of the field's window other than the field, as the walk
    /// that tells Mail's compose window reads it.
    struct WindowElement {
        var role: String
        var identifier: String?
        var children: [WindowElement] = []
        /// What a header field holds, as Mail's To or Subject field gives
        /// it for its value; nil is a field that does not answer for one.
        var value: String?
        /// It does not answer for its role.
        var roleUnanswered = false
        /// How long each read of it takes, as an app that is slow to answer.
        var readDelay: TimeInterval = 0
    }
    /// The window's children, before the field itself, which is the last
    /// of them. By default a Mail compose window as the walk sees it: a To
    /// field, a text field identified "Mail.toField" as the `mail`
    /// insertion scene found it in a new message.
    var windowElements = [WindowElement(role: kAXTextFieldRole, identifier: "Mail.toField")]
    /// The window does not answer for its children.
    var windowChildrenUnanswered = false
    /// Every attribute read of the window's other elements, in order.
    @MockLocked var windowElementReads: [String] = []

    func windowElement(_ path: [Int]) -> WindowElement {
        var element = windowElements[path[0]]
        for index in path.dropFirst() { element = element.children[index] }
        return element
    }
    /// The address of the page a web field is in, which the web area above
    /// the field gives as its AXURL; nil is a web area that does not
    /// answer for it. A document field is the web area itself and is in
    /// no page.
    var pageURL: String?
    /// With a value, the web field's page is a frame inside another page:
    /// the web area above the field sits in a second web area, with this
    /// address, before the window. Telling the body must take the nearest.
    var outerPageURL: String?
    /// The web area right above the field does not answer for its role.
    var webAreaRoleUnanswered = false
    /// A container's role gives a generic failure during admission and
    /// the page walk. The secure walk permits that ancestor's failure.
    var containerRoleFails = false
    /// The app that owns the field, by bundle identifier: Mail unless a
    /// scenario says otherwise.
    var bundleIdentifier: String? = "com.apple.mail"
    /// A held write, as the ranged offsets or the place in `text` it was
    /// given.
    private enum Place {
        case offsets(FieldRange)
        case text(NSRange)
    }

    private var pending: (Place, String)?

    /// What a scenario's guard (`FocusedField.stillCurrent`) answers on each
    /// call, counted from one. Nil is "still the compose I captured".
    var guardAnswer: @Sendable (Int) -> EditReason? = { _ in nil }
    /// Runs while the guard is being called, with how many calls there have
    /// been, as something that happens while the caller's check is reading.
    var onGuard: (@Sendable (Int) -> Void)?
    @MockLocked var guardCalls = 0
    /// The thread of each guard call, and of each check of whether the
    /// field is secure, which the inserter makes on its executor.
    @MockLocked var guardThreads: [Thread] = []
    @MockLocked var secureCheckThreads: Set<Thread> = []
    /// How many guard calls there had been when each Accessibility write
    /// was issued and when each key was posted.
    var guardCallsAtWrites: [Int] = []
    var guardCallsAtKeys: [Int] = []

    @MockLocked var textReadsWhileSecure = 0
    /// Reads of the field's text so far, and what runs as each is
    /// answered, such as the field turning secure.
    @MockLocked var textReads = 0
    var onTextRead: (@Sendable () -> Void)?
    /// Ranged reads spanning the field's whole text, as the body read of a
    /// document field makes one; the inserter's own reads stop at
    /// `FieldEdit.contextLength` around the caret, so in a longer field
    /// only the body read counts here.
    @MockLocked var wholeTextReads = 0
    /// Reads of the field's length while it is secure: its character
    /// count, its length by markers, its marker ranges and the lengths
    /// between markers. Then the reads of that kind so far, and what runs
    /// as each is answered.
    @MockLocked var measuresWhileSecure = 0
    @MockLocked var measures = 0
    var onMeasure: (@Sendable () -> Void)?
    /// Accessibility writes and posted keys while the field is secure, and
    /// what runs right after each write or key has had its effect.
    var editsWhileSecure = 0
    var onEdit: (@Sendable () -> Void)?
    /// Runs on each other Accessibility read of the field or of focus: its
    /// role, labels, selection, selection markers, children, frame and
    /// settable attributes, and which element has focus.
    var onOtherRead: (@Sendable () -> Void)?
    /// The field does not offer ranged reads of its text, so it is read by
    /// its value, as a native field without `AXStringForRange` is.
    var rangedReadsOffered = true
    var accessibilityWrites = 0
    var replaceRangeWrites = 0
    var keys: [String] = []

    static func reset() {
        shared = MockField()
        AppLog.reset()
    }

    // The block model, as observed in Chromium. `text` is what the person
    // sees, one line break between lines. The first break of a run is a
    // paragraph break, which ranged offsets leave out. Each break after it
    // is an empty paragraph, which they count as one line break, as they do
    // a break the text starts with. The value and character count show a
    // run as one break fewer, and at least one.

    /// Whether each unit of `text` has a place in ranged offsets.
    private var counted: [Bool] { counted(attachments: false) }

    /// Whether each unit of `text` has a place in the markers' lengths,
    /// which count an image with alt text.
    private var markerCounted: [Bool] { counted(attachments: true) }

    private func counted(attachments: Bool) -> [Bool] {
        var counted: [Bool] = []
        var afterBreak = false
        for (index, unit) in text.utf16.enumerated() {
            counted.append(!(blocks && unit == 10 && !afterBreak && index > 0 && !literalBlockBreaks.contains(index)) && (attachments || unit != Self.image))
            afterBreak = unit == 10
        }
        return counted
    }

    /// The text as ranged reads address it.
    var ranged: String {
        String(utf16CodeUnits: zip(Array(text.utf16), counted).filter(\.1).map(\.0), count: counted.filter { $0 }.count)
    }

    /// The text as the field's value shows it.
    var value: String {
        if doubles {
            var units: [UInt16] = []
            for (index, unit) in text.utf16.enumerated() {
                if unit == Self.image { continue }
                units.append(unit)
                if unit == 10, !singleBreaks.contains(index) { units.append(unit) }
            }
            return String(decoding: units, as: UTF16.self)
        }
        guard blocks else { return text }
        var value = ""
        var run = 0
        for character in text + "\u{0}" {
            if character == "\n" {
                run += 1
            } else {
                value += String(repeating: "\n", count: run == 0 ? 0 : max(1, run - 1))
                run = 0
                if character != "\u{0}" { value.append(character) }
            }
        }
        return value
    }

    /// The ranged offset of a place in `text`.
    func offset(of index: Int) -> Int { counted[..<index].filter { $0 }.count }

    /// The offset of a place in `text` as the markers measure it.
    func markerOffset(of index: Int) -> Int { markerCounted[..<index].filter { $0 }.count }

    /// The text between two places in `text`, as the markers read it: a
    /// list's labels in front of the lines that start in it.
    func markerText(from start: Int, to end: Int) -> String {
        var units: [UInt16] = []
        var line = 0
        let textUnits = Array(text.utf16)
        for (index, (unit, counted)) in zip(textUnits, markerCounted).enumerated() {
            if index >= start, index < end, index == 0 || textUnits[index - 1] == 10, let label = listLabels[line] {
                units += label.utf16
            }
            if index >= start, index < end, counted { units.append(unit == Self.image ? 0xFFFC : unit) }
            if unit == 10 { line += 1 }
        }
        return String(utf16CodeUnits: units, count: units.count)
    }

    /// Where a ranged offset sits in `text`: before or after a paragraph
    /// break there.
    func index(_ offset: Int, afterBreak: Bool) -> Int {
        let counted = counted
        var index = 0, seen = 0
        while index < counted.count, seen < offset {
            if counted[index] { seen += 1 }
            index += 1
        }
        if afterBreak, index < counted.count, !counted[index] { index += 1 }
        return index
    }

    /// A selection made by offsets has both ends after a paragraph break at
    /// that offset; one the person makes can have either before it.
    var startAfterBreak = true
    var endAfterBreak = true

    /// Where the selection sits in `text`.
    var selected: NSRange {
        guard blocks || hasImages else { return NSRange(location: selection.location, length: selection.length) }
        let start = index(selection.location, afterBreak: startAfterBreak)
        return NSRange(location: start, length: max(0, index(selection.upperBound, afterBreak: endAfterBreak) - start))
    }

    /// Puts the selection at places in `text`.
    func select(from start: Int, to end: Int) {
        selection = FieldRange(location: offset(of: start), length: offset(of: end) - offset(of: start))
        startAfterBreak = index(selection.location, afterBreak: true) == start
        endAfterBreak = index(selection.upperBound, afterBreak: true) == end
    }

    /// Replaces a range of ranged offsets, starting after a paragraph break
    /// at its start and ending before one at its end.
    func apply(_ value: String, at range: FieldRange) {
        guard blocks || hasImages else {
            moveSingleBreaks(NSRange(location: range.location, length: range.length), value)
            text = (text as NSString).replacingCharacters(in: NSRange(location: range.location, length: range.length), with: value)
            selection = FieldRange(location: range.location + value.utf16.count, length: 0)
            return
        }
        let start = index(range.location, afterBreak: true)
        replace(NSRange(location: start, length: max(0, index(range.upperBound, afterBreak: false) - start)), with: value)
    }

    /// Replaces the selection, as a key does.
    func type(_ value: String) {
        if blocks || hasImages { replace(selected, with: value) } else { apply(value, at: selection) }
    }

    /// Replaces a range of `text` and leaves the caret after the new text.
    func replace(_ range: NSRange, with value: String) {
        moveSingleBreaks(range, value)
        text = (text as NSString).replacingCharacters(in: range, with: value)
        let caret = range.location + value.utf16.count
        select(from: caret, to: caret)
    }

    /// `<br>` breaks move with the text around them when `range` of
    /// `text` becomes `value`.
    private func moveSingleBreaks(_ range: NSRange, _ value: String) {
        let delta = value.utf16.count - range.length
        singleBreaks = Set(singleBreaks.compactMap { place in
            place < range.location ? place : place < range.location + range.length ? nil : place + delta
        })
    }

    /// Applies a held write.
    func land() {
        if let (place, value) = pending {
            pending = nil
            put(value, at: place)
            onLand?()
        }
    }

    private func put(_ value: String, at place: Place) {
        let value = reformat?(value) ?? value
        switch place {
        case let .offsets(range): apply(value, at: range)
        case let .text(range): replace(range, with: value)
        }
    }

    func write(_ value: String, at range: FieldRange) -> AXError { write(value, at: .offsets(range)) }

    /// A write at ranged offsets the app reports done and never shows.
    func writeNowhere(_ value: String, at range: FieldRange) -> AXError { write(value, at: .offsets(range), lands: false) }

    /// A write at a place in `text`, as a block editor's replace range
    /// counts it.
    func write(_ value: String, in range: NSRange) -> AXError { write(value, at: .text(range)) }

    /// `lands` false is a write the app reports done and never shows, as a
    /// replace range into an element the tree leaves out.
    private func write(_ value: String, at place: Place, lands: Bool = true) -> AXError {
        if secure { editsWhileSecure += 1 }
        accessibilityWrites += 1
        guardCallsAtWrites.append(guardCalls)
        defer {
            if secureAfterWrite { secure = true }
            onEdit?()
        }
        switch writes {
        case .apply: if lands { put(value, at: place) }
        case .ignore: break
        case .refuse:
            if let next = labelAfterRefusal { label = next }
            return .failure
        case .held: pending = (place, value)
        case .unanswered:
            pending = (place, value)
            return .cannotComplete
        }
        return .success
    }

    func readText() {
        if secure { textReadsWhileSecure += 1 }
        textReads += 1
        onTextRead?()
    }

    func measure() {
        if secure { measuresWhileSecure += 1 }
        measures += 1
        onMeasure?()
    }

    /// The guard a scenario attaches to its `FocusedField`.
    func stillCurrent() -> EditReason? {
        guardCalls += 1
        guardThreads.append(Thread.current)
        onGuard?(guardCalls)
        return guardAnswer(guardCalls)
    }
}

struct AXElement: @unchecked Sendable {
    func domClasses() -> Set<String>? { Set(field.domClassList) }
    let ref: AXUIElement
    /// The field that had focus when this element was read.
    var id = MockField.shared.focusedElement
    var generation = MockField.shared.objectGeneration
    /// A line of a block editor, as one of the field's children.
    var block: Int?
    /// The web area a web field sits in: the page, between the field and
    /// the window.
    var webArea = false
    /// One of the window's other elements, by its place in
    /// `MockField.windowElements`.
    var path: [Int]?
    private var field: MockField { .shared }

    static let replaceRangeWithText = "AXReplaceRangeWithText"
    static let textOperation = "AXTextOperation"
    static let rangedLengthReads: Set<String> = ["AXTextMarkerRangeForUIElement", "AXLengthForTextMarkerRange"]
    static let markerEditing: Set<String> = [
        textOperation, "AXTextMarkerForIndex", "AXIndexForTextMarker", "AXStringForTextMarkerRange",
        kAXStringForRangeParameterizedAttribute,
    ]

    /// Every field is the system-wide element except the other app's element
    /// that `focusedElsewhere` puts focus in; fields of the one app differ by
    /// `id`, and a replaced object by `generation`.
    func sameElement(as other: AXElement) -> Bool {
        CFEqual(ref, other.ref) && id == other.id && generation == other.generation && path == other.path
    }

    /// A replaced object is gone, a replaced page and a closed window;
    /// another field is not, nor anything that does not answer.
    var isGone: Bool {
        if MockField.shared.identityUnanswered { return false }
        if webArea { return generation != MockField.shared.pageGeneration }
        if id == 0, path == nil { return MockField.shared.closedWindows.contains(generation) }
        return path == nil && generation != MockField.shared.objectGeneration
    }

    /// As `isGone` tells it, and nil for an element that does not answer.
    var stillThere: Bool? {
        MockField.shared.identityUnanswered ? nil : !isGone
    }

    /// The test runner's parent, or `MockField.appPID`: another process
    /// that is running and has a start time.
    func pid() -> pid_t? { CFEqual(ref, AXUIElementCreateApplication(1)) ? 1 : field.appPID ?? getppid() }

    /// Every app is the one system-wide element here.
    static func application(_ pid: pid_t) -> AXElement { AXElement(ref: AXUIElementCreateSystemWide()) }

    /// Each field has its own place on screen, and the page's scroll area
    /// and the window theirs when a scenario gives them one.
    func frame() -> Result<CGRect, AXFailure> {
        field.onOtherRead?()
        if !webArea, path == nil { field.recordRead(of: id, "AXFrame") }
        field.onFrameRead?(webArea ? -1 : id)
        if id == Self.scrollAreaID, let area = field.scrollArea { return .success(area) }
        if id == 0, !webArea, path == nil, let window = field.windowFrame { return .success(window) }
        return .success(CGRect(x: CGFloat(100 * id), y: field.fieldTop, width: field.frameWidth, height: field.frameHeight))
    }

    func bounds(for range: FieldRange, timeout: Float? = nil) -> Result<CGRect, AXFailure> {
        field.rangeBoundsReads += 1
        field.rangeBoundsTimeouts.append(timeout)
        if field.rangeBoundsDelay > 0 {
            let limit = Double(timeout ?? AccessibilityExecutor.messagingTimeout)
            Thread.sleep(forTimeInterval: min(field.rangeBoundsDelay, limit))
            if field.rangeBoundsDelay >= limit { return .failure(AXFailure(code: .cannotComplete)) }
        }
        return field.rangeBounds.map { .success($0) } ?? .failure(AXFailure(code: .attributeUnsupported))
    }

    /// The page's scroll area, when `MockField.scrollArea` gives it one.
    static let scrollAreaID = -4

    /// Any element but the focused field is beyond what an email's body
    /// read may read.
    private var beyondField: Bool { id != field.focusedElement }

    func element(_ attribute: String) -> Result<AXElement, AXFailure> {
        if ![kAXFocusedUIElementAttribute, kAXFocusedApplicationAttribute, kAXFocusedWindowAttribute].contains(attribute),
           !webArea, path == nil {
            field.recordRead(of: id, attribute)
        }
        if attribute == kAXParentAttribute {
            field.readsBeyondField += 1
            if id == 0 { return .failure(AXFailure(code: .noValue)) }
            // A web field sits in its page's web area, which sits in the
            // window, or in an outer page's web area when the page is a
            // frame; a document field is the web area itself.
            if field.web, !field.document, !webArea, id != Self.scrollAreaID {
                return .success(AXElement(ref: ref, id: -1, generation: 0, webArea: true))
            }
            if webArea, id == -1, field.outerPageURL != nil { return .success(AXElement(ref: ref, id: -2, generation: 0, webArea: true)) }
            if webArea, field.scrollArea != nil { return .success(AXElement(ref: ref, id: Self.scrollAreaID, generation: 0)) }
            return .success(AXElement(ref: ref, id: 0, generation: field.windowGeneration))
        }
        field.onOtherRead?()
        if attribute == kAXFocusedUIElementAttribute {
            field.focusReads += 1
            field.onFocusRead?()
        }
        if attribute == kAXFocusedUIElementAttribute, field.focusReadDelay > 0 { Thread.sleep(forTimeInterval: field.focusReadDelay) }
        if attribute == kAXFocusedUIElementAttribute, let failure = field.focusFailure { return .failure(AXFailure(code: failure)) }
        if attribute == kAXFocusedUIElementAttribute, field.focusUnanswered { return .failure(AXFailure(code: .cannotComplete)) }
        if attribute == kAXFocusedUIElementAttribute, !field.focused || field.otherAppFocused { return .failure(AXFailure(code: .noValue)) }
        if attribute == kAXFocusedApplicationAttribute, field.otherAppFocused { return .success(AXElement(ref: AXUIElementCreateApplication(1))) }
        if attribute == kAXFocusedUIElementAttribute, field.focusedElsewhere {
            return .success(AXElement(ref: AXUIElementCreateApplication(getppid())))
        }
        // Every field shares one window.
        if attribute == kAXWindowAttribute || attribute == kAXFocusedWindowAttribute {
            if field.windowUnanswered { return .failure(AXFailure(code: .cannotComplete)) }
            return .success(AXElement(ref: ref, id: 0, generation: field.windowGeneration))
        }
        return .success(AXElement(ref: ref))
    }

    func isSettable(_ attribute: String) -> Bool {
        field.onOtherRead?()
        return attribute == kAXSelectedTextRangeAttribute ? field.rangeSettable : field.settable
    }

    /// The page a web field is in, or a document field itself; none for a
    /// native field.
    func nearestWebArea() -> AXElement? {
        field.onOtherRead?()
        guard field.web || field.document, !field.webAreaRoleUnanswered, !field.containerRoleFails else { return nil }
        return field.document ? self : AXElement(ref: ref, id: field.pageID, generation: field.pageGeneration, webArea: true)
    }

    /// Whether the field's text is all generated, as a CSS placeholder's
    /// is; nil is a walk that does not answer.
    func generatedText() -> Bool? {
        field.onOtherRead?()
        return field.generatedUnanswered ? nil : field.generatedPlaceholder
    }

    /// One block for each paragraph of a block editor, an empty one
    /// included; none in any other field.
    func blockChildren() -> Int? {
        field.onOtherRead?()
        if field.childrenUnanswered { return nil }
        guard field.blocks || field.doubles || field.lines else { return 0 }
        return field.text == "\n" ? 1 : field.text.split(separator: "\n", omittingEmptySubsequences: false).count - field.literalBlockBreaks.count
    }

    func blockStarts(expectedLength: Int) -> [Int]? {
        field.onOtherRead?()
        guard !field.childrenUnanswered, !field.markerLengthUnanswered,
              field.ranged.utf16.count == expectedLength, field.blocks else { return nil }
        var starts = [0]
        for (index, unit) in field.text.utf16.enumerated() where unit == 10 && !field.literalBlockBreaks.contains(index) {
            starts.append(field.offset(of: index + 1))
        }
        return starts
    }

    func parameterizedNames() -> Set<String>? {
        if field.namesUnanswered { return nil }
        if field.namesUnansweredTimes > 0 {
            field.namesUnansweredTimes -= 1
            return nil
        }
        if field.document {
            return Self.markerEditing.union([Self.replaceRangeWithText])
        }
        var names: Set<String> = field.rangedReadsOffered ? [kAXStringForRangeParameterizedAttribute] : []
        if field.web { names.formUnion(Self.rangedLengthReads.union([Self.replaceRangeWithText])) }
        // WebKit's fields offer the text operation; Chromium's do not.
        if field.doubles || field.lines || field.webKitPlain { names.insert(Self.textOperation) }
        return names
    }

    func range(_ attribute: String) -> Result<FieldRange, AXFailure> {
        field.onOtherRead?()
        if field.unreadable { return .failure(AXFailure(code: .noValue)) }
        if field.selectionUnanswered { return .failure(AXFailure(code: .cannotComplete)) }
        return field.document ? .failure(AXFailure(code: .attributeUnsupported)) : .success(field.selection)
    }

    func int(_ attribute: String) -> Result<Int, AXFailure> {
        field.measure()
        if field.countUnanswered { return .failure(AXFailure(code: .cannotComplete)) }
        return field.document ? .failure(AXFailure(code: .attributeUnsupported)) : .success(length())
    }


    private func length() -> Int {
        field.lengthReads += 1
        field.onLengthRead?(field.lengthReads)
        if let moved = field.moveSelectionOnRead {
            field.moveSelectionOnRead = nil
            field.selection = moved
        }
        if let reads = field.landsAfterLengthReads {
            field.landsAfterLengthReads = reads > 1 ? reads - 1 : nil
            if reads <= 1 { field.land() }
        }
        return field.value.utf16.count
    }

    func string(for range: FieldRange) -> Result<String, AXFailure> {
        field.readText()
        // Where breaks read doubled, ranged reads take the value's offsets.
        let text = (field.doubles ? field.value : field.ranged) as NSString
        if range.location == 0, range.length == text.length { field.wholeTextReads += 1 }
        guard range != field.failingRead, range.location >= 0, range.upperBound <= text.length else {
            if range == field.failingRead { field.onFailedRead?() }
            return .failure(AXFailure(code: range == field.failingRead && field.failingReadTimesOut ? .cannotComplete : .illegalArgument))
        }
        return .success(text.substring(with: NSRange(location: range.location, length: range.length)))
    }

    func rangedLength() -> Int? {
        field.measure()
        return field.web && !field.markerLengthUnanswered ? field.ranged.utf16.count : nil
    }

    /// The field's own marker range, which ends at the caret where
    /// `ownEndAtCaret` says so, or a line's range for one of its blocks.
    func textMarkers() -> AXTextMarkerRange? {
        field.measure()
        guard field.web, !field.document else { return nil }
        if let block {
            let lines = field.text.components(separatedBy: "\n")
            let start = lines[..<block].reduce(0) { $0 + $1.utf16.count + 1 }
            let last = block == lines.count - 1
            if last, field.lastBlockMarkersUnanswered { return nil }
            let end = start + lines[block].utf16.count - (last ? field.lastEndShortBy : 0) + (last && field.trailingAttachment ? 1 : 0)
            return AXTextMarkerRangeCreate(nil, Self.marker(start), Self.marker(end))
        }
        guard !field.markerLengthUnanswered else { return nil }
        field.onWholeMarkersRead?()
        let end = field.ownEndAtCaret ? field.selected.location : field.ownEnd ?? field.text.utf16.count - field.ownEndShortBy
        return AXTextMarkerRangeCreate(nil, Self.marker(0), Self.marker(end))
    }

    /// One child for each line of a WebKit block editor, with no children
    /// of its own; none in any other field.
    func children() -> Result<[AXElement], AXFailure> {
        field.onOtherRead?()
        if beyondField { field.readsBeyondField += 1 }
        if let path {
            field.windowElementReads.append(kAXChildrenAttribute)
            Thread.sleep(forTimeInterval: field.windowElement(path).readDelay)
            return .success(field.windowElement(path).children.indices.map { AXElement(ref: ref, id: -3, generation: 0, path: path + [$0]) })
        }
        // The window: its other elements, then the field.
        if id == 0, !webArea {
            if field.windowChildrenUnanswered { return .failure(AXFailure(code: .cannotComplete)) }
            return .success(field.windowElements.indices.map { AXElement(ref: ref, id: -3, generation: 0, path: [$0]) } + [AXElement(ref: ref)])
        }
        if let block {
            let last = block == field.text.components(separatedBy: "\n").count - 1
            return last && field.lastBlockChildrenUnanswered ? .failure(AXFailure(code: .cannotComplete)) : .success([])
        }
        if field.childrenUnanswered { return .failure(AXFailure(code: .cannotComplete)) }
        guard field.doubles || field.lines else { return .success([]) }
        return .success(field.text.components(separatedBy: "\n").indices.map { AXElement(ref: ref, id: id, generation: generation, block: $0) })
    }

    func string(_ attribute: String) -> Result<String, AXFailure> {
        if !webArea, path == nil { field.recordRead(of: id, attribute) }
        if beyondField { field.readsBeyondField += 1 }
        if [kAXRoleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute].contains(attribute) { field.onOtherRead?() }
        if attribute == kAXRoleAttribute, webArea, id == -1, field.webAreaRoleUnanswered { return .failure(AXFailure(code: .cannotComplete)) }
        if let path {
            field.windowElementReads.append(attribute)
            let element = field.windowElement(path)
            Thread.sleep(forTimeInterval: element.readDelay)
            switch attribute {
            case kAXRoleAttribute: return element.roleUnanswered ? .failure(AXFailure(code: .cannotComplete)) : .success(element.role)
            case kAXIdentifierAttribute: return element.identifier.map { .success($0) } ?? .failure(AXFailure(code: .noValue))
            case kAXValueAttribute:
                if field.secure { field.textReadsWhileSecure += 1 }
                return element.value.map { .success($0) } ?? .failure(AXFailure(code: .noValue))
            default: return .failure(AXFailure(code: .attributeUnsupported))
            }
        }
        if attribute == kAXRoleAttribute, id == 0, !webArea { return .success(kAXWindowRole) }
        if attribute == kAXRoleAttribute, id == Self.scrollAreaID { return .success(kAXScrollAreaRole) }
        if attribute == kAXRoleAttribute { return .success(field.role ?? (field.document || webArea ? "AXWebArea" : kAXTextAreaRole)) }
        if attribute == kAXIdentifierAttribute { return .failure(AXFailure(code: .noValue)) }
        if attribute == kAXSelectedTextAttribute {
            field.readText()
            return .success((field.ranged as NSString).substring(with: NSRange(location: field.selection.location, length: field.selection.length)))
        }
        if attribute == kAXDescriptionAttribute {
            return field.descriptionUnanswered ? .failure(AXFailure(code: .cannotComplete)) : .success(field.label)
        }
        if attribute == kAXPlaceholderValueAttribute {
            field.onPlaceholderRead?()
            return .failure(AXFailure(code: .noValue))
        }
        // No element here has a subrole or a title; the walk around an
        // email's body asks every element for both.
        if attribute == kAXSubroleAttribute || attribute == kAXTitleAttribute { return .failure(AXFailure(code: .noValue)) }
        field.readText()
        if attribute == kAXValueAttribute, field.valueUnanswered { return .failure(AXFailure(code: .cannotComplete)) }
        return .success(field.document ? "" : field.value)
    }

    func setString(_ attribute: String, _ string: String) -> AXError { field.write(string, at: field.selection) }

    /// Several text attributes, each read as `string` reads it, in one call,
    /// as one message to the app.
    func values(_ attributes: [String]) -> Result<[Result<CFTypeRef, AXFailure>], AXFailure> {
        .success(attributes.map { string($0).map { $0 as CFString } })
    }

    func replace(_ range: FieldRange, with text: String) -> AXError {
        field.replaceRangeWrites += 1
        if field.document { return field.write(text, at: FieldRange(location: 0, length: 0)) }
        // Offset 0 lands in the element the tree leaves out: accepted, nothing shown.
        if field.hiddenPlaceholder, range.location == 0 { return field.writeNowhere(text, at: range) }
        if field.generatedPlaceholder { return field.writeNowhere(text, at: range) }
        if field.leadingBreakAddsLine, text.hasPrefix("\n") { return field.write("\n" + text, at: range) }
        if field.hasImages {
            let start = field.index(range.location, afterBreak: false)
            return field.write(text, in: NSRange(location: start, length: max(0, field.index(range.upperBound, afterBreak: false) - start)))
        }
        guard field.blocks else { return field.write(text, at: range) }
        // Chromium counts a paragraph break as two characters here, so a
        // range after one lands before its place.
        func index(_ position: Int) -> Int {
            var counted = 0, index = 0
            for unit in field.text.utf16 {
                let width = unit == 10 ? 2 : 1
                if counted + width > position { break }
                counted += width
                index += 1
            }
            return index
        }
        let start = index(range.location)
        return field.write(text, in: NSRange(location: start, length: max(0, index(range.upperBound) - start)))
    }

    func setRange(_ attribute: String, _ range: FieldRange) -> AXError {
        field.selection = range
        field.startAfterBreak = true
        field.endAfterBreak = true
        return .success
    }

    func setValue(_ attribute: String, _ value: CFTypeRef) -> AXError {
        if attribute == "AXManualAccessibility" { field.onFieldNoted?() }
        guard field.document, attribute == "AXSelectedTextMarkerRange" else { return .attributeUnsupported }
        field.selectionWrites += 1
        if field.secure { field.editsWhileSecure += 1 }
        if !field.selectionWritesIgnored { field.selection = Self.range(value as! AXTextMarkerRange) }
        field.onSelectionWrite?()
        return .success
    }

    func value(_ attribute: String) -> Result<CFTypeRef, AXFailure> {
        if !webArea, path == nil { field.recordRead(of: id, attribute) }
        field.onOtherRead?()
        if attribute == "AXDOMClassList" {
            return field.domClassListUnanswered ? .failure(AXFailure(code: .cannotComplete)) : .success(field.domClassList as CFArray)
        }
        if beyondField { field.readsBeyondField += 1 }
        if path != nil {
            field.windowElementReads.append(attribute)
            return .failure(AXFailure(code: .attributeUnsupported))
        }
        if webArea, attribute == kAXURLAttribute {
            let address = id == -2 ? field.outerPageURL : field.pageURL
            guard let url = address.flatMap(URL.init(string:)) else { return .failure(AXFailure(code: .noValue)) }
            return .success(url as CFURL)
        }
        if webArea { return .failure(AXFailure(code: .attributeUnsupported)) }
        guard field.document, attribute == "AXSelectedTextMarkerRange" else { return .failure(AXFailure(code: .attributeUnsupported)) }
        field.onSelectionMarkersRead?()
        guard markerSelectionAnswers(.markers) else { return .failure(AXFailure(code: .cannotComplete)) }
        return .success(Self.markerRange(field.selection))
    }

    /// Records a read of the selection's markers, which both the selection
    /// read and the read of its markers for a write are, and says whether
    /// it answers.
    private func markerSelectionAnswers(_ read: MockField.MarkerSelectionRead) -> Bool {
        field.markerSelectionReads.append(read)
        return !field.selectionUnanswered && field.markerSelectionReads.count != field.markerSelectionUnansweredAt
    }

    // Text markers. Their bytes are UTF-16 offsets: in a document field
    // offsets of its text, in another web field places in `text`, which a
    // WebKit field's markers read with each line break once.

    static func marker(_ index: Int) -> AXTextMarker {
        var bytes = UInt16(index)
        return withUnsafeBytes(of: &bytes) { AXTextMarkerCreate(nil, $0.bindMemory(to: UInt8.self).baseAddress!, 2) }
    }

    func index(of marker: AXTextMarker) -> Int? { field.document ? Self.offset(marker) : nil }

    func markers(for range: FieldRange) -> AXTextMarkerRange? {
        field.onCaretMarkersRead?()
        return field.document && !field.caretMarkersUnanswered ? Self.markerRange(range) : nil
    }

    func offsets(of markers: AXTextMarkerRange) -> FieldRange? {
        field.onOtherRead?()
        return field.document ? Self.range(markers) : nil
    }

    func markerSelection() -> Result<FieldRange, AXFailure> {
        field.onOtherRead?()
        guard field.document else { return .failure(AXFailure(code: .attributeUnsupported)) }
        return markerSelectionAnswers(.offsets) ? .success(field.selection) : .failure(AXFailure(code: .cannotComplete))
    }

    func markerLength() -> Int? {
        field.measure()
        return field.document && !field.markerLengthUnanswered ? length() : nil
    }

    func length(from start: AXTextMarker, to end: AXTextMarker) -> Int? {
        field.measure()
        guard field.web, !field.document else { return nil }
        // A trailing attachment is one place past the end of `text`.
        let units = field.text.utf16.count
        func offset(_ marker: AXTextMarker) -> Int {
            let index = Self.offset(marker)
            return field.markerOffset(of: min(index, units)) + max(0, index - units)
        }
        return offset(end) - offset(start)
    }

    /// A web field's markers read its text in the offsets its selection
    /// takes, a list's bullets included where they reach its end.
    func string(for markers: AXTextMarkerRange) -> Result<String, AXFailure> {
        guard field.web, !field.document else { return .failure(AXFailure(code: .attributeUnsupported)) }
        field.readText()
        field.onMarkerTextRead?()
        if field.wholeTextUnanswered { return .failure(AXFailure(code: .cannotComplete)) }
        let range = Self.range(markers)
        let units = field.text.utf16.count
        let extra = range.upperBound == units ? field.wholeTextExtra : range.upperBound > units ? "\u{FFFC}" : ""
        return .success(field.markerText(from: range.location, to: min(range.upperBound, units)) + extra)
    }

    func replace(_ markers: AXTextMarkerRange, with text: String) -> AXError {
        let range = Self.range(markers)
        if field.textOperationUnknown {
            field.selection = range
            return .failure
        }
        let before = field.text.utf16.count
        let code = field.write(text, at: range)
        // WebKit selects the actual replacement, including reformatting.
        if code == .success, field.writes == .apply, range.length > 0 {
            field.selection = FieldRange(location: range.location, length: field.text.utf16.count - before + range.length)
        }
        return code
    }

    /// A marker range whose bytes are the range's offsets, so two ranges are
    /// equal exactly when their offsets are.
    static func markerRange(_ range: FieldRange) -> AXTextMarkerRange {
        AXTextMarkerRangeCreate(nil, marker(range.location), marker(range.upperBound))
    }

    static func offset(_ marker: AXTextMarker) -> Int {
        Int(UnsafeRawPointer(AXTextMarkerGetBytePtr(marker)).loadUnaligned(as: UInt16.self))
    }

    static func range(_ markers: AXTextMarkerRange) -> FieldRange {
        let start = offset(AXTextMarkerRangeCopyStartMarker(markers))
        return FieldRange(location: start, length: offset(AXTextMarkerRangeCopyEndMarker(markers)) - start)
    }
}

enum AXWritingSurface {
    enum Admission { case allowed, secure, unsupported }

    static func surface(_ focused: AXElement, pid: pid_t, editableDocument: Bool = false) -> (admission: Admission, web: Bool) {
        let field = MockField.shared
        if field.secure { return (.secure, field.web) }
        if field.containerRoleFails { return (.unsupported, false) }
        if let role = field.role, ![kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXWebArea"].contains(role) {
            return (.unsupported, field.web)
        }
        return (field.document && !editableDocument ? .unsupported : .allowed, field.web || field.document)
    }

    static func exposure(of window: AXElement, stopAtText: Bool = false) -> WritingSurfacePolicy.Exposure {
        let field = MockField.shared
        field.bareScans += 1
        let bare = field.bareAnswers.isEmpty ? field.bareWindow : field.bareAnswers.removeFirst()
        return bare ? .nothing : field.secureInWindow ? .secure : .text
    }

    static func secureAncestry(_ focused: AXElement, window: AXElement) -> Bool? {
        MockField.shared.secureCheckThreads.insert(Thread.current)
        MockField.shared.onSecureCheck?()
        if !MockField.shared.secureAnswers.isEmpty { return MockField.shared.secureAnswers.removeFirst() }
        return MockField.shared.secure
    }
}

enum KeyEvents {
    enum Key {
        case paste(CGKeyCode)
    }

    static func post(_ key: Key, to pid: pid_t) -> Bool {
        let field = MockField.shared
        if field.secure { field.editsWhileSecure += 1 }
        defer { field.onEdit?() }
        field.guardCallsAtKeys.append(field.guardCalls)
        field.onKey?()
        if field.keysPending {
            field.keys.append("pending")
            return true
        }
        field.keys.append("paste")
        if field.pastesLand, let text = field.pasteboard?.string(forType: .string) {
            // The editor's own text takes the place of its placeholder.
            if field.generatedPlaceholder {
                field.generatedPlaceholder = false
                field.text = ""
                field.selection = FieldRange(location: 0, length: 0)
            }
            field.type(field.pasteAddsParagraphBreak && text.hasPrefix("\n") ? "\n" + text : text)
        }
        return true
    }

    @MainActor static func pasteKeyCode() -> CGKeyCode { 9 }
}

/// Stands in for the app's log. Dictation's lines are kept, from any
/// thread, so a check can read every line a dictation wrote.
enum AppLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var logged: [String] = []
    static let dictationLines = LoggedLines()

    /// The insertion outcomes logged so far, in order, for the scenarios to
    /// read; `reset` empties it.
    static var edits: [String] {
        lock.withLock { logged }
    }

    static func reset() {
        lock.withLock { logged = [] }
    }

    static func edit(_ outcome: String, since start: ContinuousClock.Instant) {
        lock.withLock { logged.append(outcome) }
    }
    static func pressStage(_ stage: String, at time: TimeInterval, since start: TimeInterval) {}
    static func dictation(_ outcome: String) { dictationLines.add("dictation \(outcome)") }
    @TaskLocal static var composeLines: LoggedLines?
    // Accessibility dispatch callbacks do not inherit Swift task-local values.
    static let unscopedComposeLines = LoggedLines()
    static func compose(_ outcome: String, attempt: Int? = nil) {
        (composeLines ?? unscopedComposeLines).add(attempt.map { "\(outcome) attempt=\($0)" } ?? outcome)
    }
    static func event(_ message: StaticString) {}
}

final class LoggedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

/// Stands in for AppKit's, which the dictation's field read asks for the
/// app's bundle identifier.
struct NSRunningApplication {
    init?(processIdentifier: pid_t) {}
    var isTerminated: Bool { false }
    var bundleIdentifier: String? { MockField.shared.bundleIdentifier }
}

/// The dot renderer's Debug capture hook records no real window in scenarios.
enum CaretFixtureMode {
    static func dotDraw(frame: CGRect, center: CGPoint) {}
}
