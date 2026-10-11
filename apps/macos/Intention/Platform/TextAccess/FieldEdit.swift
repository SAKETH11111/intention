import Foundation

// Pure rules for checking an edit in another app's field. Accessibility
// reports ranges in UTF-16 code units, so every offset and length here is
// UTF-16.

/// The selection and the minimum surrounding text needed to recheck an
/// edit. Other apps expose no revision counter, so this is compared field by
/// field before every write. A match is not atomic with the other app, which
/// can still change afterwards.
struct FieldState: Equatable, Sendable {
    var selection: FieldRange
    var selectedText: String
    /// Up to `FieldEdit.contextLength` units ending at the selection.
    var before: String
    /// Up to `FieldEdit.contextLength` units starting after the selection.
    var after: String
    /// Total UTF-16 length of the field, in the offsets its selection and
    /// ranged reads take.
    var length: Int
    /// The field's character count where it differs from `length`. Chromium
    /// counts the break between two block paragraphs in a field's value and
    /// character count, and leaves it out of the offsets its selection,
    /// ranged reads and text markers take. A field of several such
    /// paragraphs is longer by its count than by its offsets.
    var characters: Int?
    /// The field holds more than one block paragraph. `characters` shows
    /// the break between two of them, but not beside an empty paragraph:
    /// one between two others reads as a single line break by the count and
    /// by the offsets alike, as a line break in a text area does.
    var blockParagraphs = false
    /// The field's ranged reads, value and character count hold the break
    /// between two block paragraphs twice, as WebKit's do, while its
    /// selection, its replace range and its text markers hold it once. Its
    /// text is then read whole through its markers, in the offsets the
    /// selection takes, and a replace range goes where the selection is.
    var breaksDoubled = false
    /// The field is WebKit's and its text was measured past the end of its
    /// own marker range, to its last descendant's; see
    /// `FieldAccess.webKitText`. Such a field takes the paste route.
    var pastOwnRange = false
    /// The field is WebKit's and its text by markers held the labels of a
    /// list's items, which were taken out; see
    /// `FieldEdit.aligned`. It takes the paste route: WebKit's
    /// replace range beside an image in a list item wrote on the wrong
    /// side of it or deleted it, and no read shows an image without alt
    /// text.
    var listLabels = false
    /// The run of line breaks that ends the field's text by markers, kept
    /// for a WebKit field whose end rests on the range it gives for its own
    /// text alone, with no list labels; see `TextReader.webKitLengths`.
    /// Its length alone cannot say where such a field ends: a range one
    /// break short inside that run passes the run-by-run rule, so a readback
    /// must find the run the insertion leaves there
    /// (`EditFacts.lastRunAfter`). Nil for any other field.
    var lastRun: Int?
    /// The run of line breaks that ends the field's text, wherever that
    /// text was read whole by its markers, however its end was found; nil
    /// where it was not. See `FieldEdit.sameState`.
    var endingRun: Int?

    /// The whole field holds only line breaks, or nothing: the text read
    /// around the selection is all of it. See `FieldEdit.isBlank`.
    var blank: Bool {
        let whole = before + selectedText + after
        return whole.utf16.count == length && FieldEdit.isBlank(whole)
    }
}

/// What an insertion is expected to change, kept in memory only while the
/// insertion is confirmed.
struct EditFacts: Equatable, Sendable {
    /// Where the inserted text sits once written.
    var range: FieldRange
    var insertedText: String
    /// The selected text the insertion replaced; empty at a caret.
    var originalText: String
    var before: String
    var after: String
    var lengthBefore: Int
    var lengthAfter: Int
    /// The field's character count before the insertion; see
    /// `FieldState.characters`.
    var charactersBefore: Int
    /// For each run of line breaks in the inserted text, whether the field's
    /// offsets leave one of them out. Chromium does for breaks that became
    /// paragraph breaks: one break between two paragraphs reads as nothing,
    /// and each empty line after it as one line break. `range` and
    /// `lengthAfter` are shorter by one for each run marked here, and the
    /// text reads back as `readText`. Empty where every break is counted.
    var leftOut: [Bool] = []
    /// The whole field held only line breaks, or nothing. See
    /// `FieldEdit.isBlank`.
    var blankBefore: Bool
    /// See `FieldState.lastRun`.
    var lastRunBefore: Int?

    init(replacing state: FieldState, with text: String) {
        range = FieldRange(location: state.selection.location, length: text.utf16.count)
        insertedText = text
        originalText = state.selectedText
        before = state.before
        after = state.after
        lengthBefore = state.length
        lengthAfter = state.length - state.selection.length + text.utf16.count
        charactersBefore = state.characters ?? state.length
        blankBefore = state.blank
        lastRunBefore = state.lastRun
    }

    /// The run of line breaks that ends the field's text once the
    /// insertion lands, for a field whose `lastRunBefore` is known.
    ///
    /// The field's end is uncertain only inside that run, since a range
    /// that stops before a character fails the run-by-run rule. Where text
    /// other than line breaks stays between the selection and the run, the
    /// run is the same after the insertion, so a range that ended one break
    /// short while the field was observed and came right by the readback,
    /// which grows the field by one as an inserted character would, shows
    /// one break more there. Where the selection ends in the run or right
    /// before it, the run becomes the inserted text's own last breaks and
    /// the breaks that followed the selection.
    ///
    /// Nil where the run cannot tell: where the inserted text and the
    /// selected text differ only in line breaks at their ends, the field
    /// with the insertion reads, by its length, its compared slices and
    /// this run, exactly as the field without it whose range ends that many
    /// breaks further on or back, so the plain readback leaves such an
    /// insertion unconfirmed. The reading with paragraph breaks left out
    /// (`reading(leftOut:)`), inherited from `main`, is an exception: it can
    /// take a trailing break out of the inserted text until it reads as the
    /// selected text, which this does not count as differing, so an ignored
    /// replacement of "X" by "X\n" can still read as landed through it.
    var lastRunAfter: Int? {
        guard let before = lastRunBefore else { return nil }
        let selectionEnd = range.location + originalText.utf16.count
        if selectionEnd < lengthBefore - before { return before }
        let newline: UInt16 = 10
        let written = Array(readText.utf16), replaced = Array(originalText.utf16)
        func trimmed(_ units: [UInt16]) -> ArraySlice<UInt16> {
            units[..<(units.lastIndex(where: { $0 != newline }).map { $0 + 1 } ?? 0)]
        }
        guard written == replaced || trimmed(written) != trimmed(replaced),
              let lastText = written.lastIndex(where: { $0 != newline }) else { return nil }
        return written.count - 1 - lastText + lengthBefore - selectionEnd
    }

    /// The inserted lines became paragraphs whose breaks the field's offsets
    /// leave out.
    var blocks: Bool { leftOut.contains(true) }

    /// The inserted text as the field's ranged reads return it.
    var readText: String { blocks ? FieldEdit.leavingOut(leftOut, from: insertedText) : insertedText }

    /// These facts for a field that reads the inserted text back with one
    /// line break missing from the runs marked in `leftOut`.
    func reading(leftOut: [Bool]) -> EditFacts {
        var facts = self
        facts.leftOut = leftOut
        let length = facts.readText.utf16.count
        facts.lengthAfter += length - facts.range.length
        facts.range.length = length
        return facts
    }

    /// These facts for a field whose offsets leave one break out of every
    /// run of line breaks in the inserted text.
    func leavingOutLineBreaks() -> EditFacts {
        reading(leftOut: FieldEdit.breakRuns(insertedText).map { _ in true })
    }

    /// Breaks the offsets leave out that the character count still holds:
    /// a single break between two paragraphs. Where an empty line follows,
    /// the count drops the break too.
    var breaksUncounted: Int {
        zip(FieldEdit.breakRuns(insertedText), leftOut).filter { $0 == 1 && $1 }.count
    }

    /// The first existing blank break in an untouched Outlook body was a
    /// placeholder consumed by the paste. This is one exact
    /// alternate shape, restricted further by the provider's field identity.
    /// Trailing inserted breaks merge with the existing run, so this rule
    /// cannot account for them without hiding a missing blank line.
    func withOutlookBlankParagraph() -> EditFacts? {
        guard blankBefore, range.location == 0, originalText.isEmpty, before.isEmpty,
              let first = insertedText.first, !first.isNewline,
              let last = insertedText.last, !last.isNewline,
              !insertedText.contains("\r"),
              (1...2).contains(lengthBefore), after == String(repeating: "\n", count: lengthBefore),
              charactersBefore == lengthBefore else { return nil }
        var facts = self
        facts.after.removeFirst()
        facts.lengthAfter -= 1
        return facts
    }

    /// Gmail's initial single break can disappear when pasted text becomes
    /// block paragraphs. Do not consume a break supplied by the person.
    func withConsumedGmailPlaceholder() -> EditFacts? {
        guard lengthBefore == 1, let facts = withOutlookBlankParagraph(), facts.after.isEmpty else { return nil }
        return facts
    }

    /// Independent value and block-start expectations for the Outlook
    /// alternate. A paragraph's first break is absent from ranged offsets;
    /// the value keeps it, except that a run of empty paragraphs loses one.
    /// Literal line breaks keep every unit and create no block child.
    var outlookParagraphEvidence: (value: String, starts: [Int]) {
        let runs = FieldEdit.breakRuns(insertedText)
        let blockRuns = runs.enumerated().map { index, count in
            (count: count, block: index < leftOut.count && leftOut[index])
        }
        let value = FieldEdit.leavingOut(blockRuns.map { $0.block && $0.count > 1 }, from: insertedText)
            + String(repeating: "\n", count: lengthBefore - 1)
        var starts = [0], offset = 0, run = -1, inRun = false
        for character in insertedText {
            if character.isNewline {
                if !inRun { run += 1 }
                let block = run < blockRuns.count && blockRuns[run].block
                if !block || inRun { offset += character.utf16.count }
                if block { starts.append(offset) }
                inRun = true
            } else {
                offset += character.utf16.count
                inRun = false
            }
        }
        // A second initial break survives inside a trailing empty block.
        // Its literal br counts in ranged text; its block starts before it.
        if lengthBefore == 2 {
            starts.append(offset)
        }
        return (value, starts)
    }

    /// How much of a field's text a readback reads whole, enough to judge a
    /// field that was blank before the insertion.
    var wholeLimit: Int { blankBefore ? insertedText.utf16.count + 2 : 0 }

    var beforeRange: FieldRange { FieldRange(location: range.location - before.utf16.count, length: before.utf16.count) }
    var afterRange: FieldRange { FieldRange(location: range.upperBound, length: after.utf16.count) }
}

/// What a rich editor may make of text written into it and still show that
/// text, for telling a write that landed in another form from one still on
/// its way. Editors change case, curl quotes, collapse or add spaces, turn
/// markdown into formatting and correct a word as text goes in; they keep
/// its letters and digits, but for a correction. So the text shown for a
/// write is compared with it by its letters and digits alone, case folded,
/// with a small allowance (`FieldEdit.letters`, `allowance`).
struct Reformatting: Sendable {
    /// The written text's letters and digits, case folded.
    let letters: [Character]
    /// How many edits to those letters and digits an editor's correction
    /// may make, one for every eight original letters and digits, at most
    /// eight. Writes with fewer than eight letters and digits get no
    /// allowance, even when folding expands them. An unrelated one-letter
    /// edit could otherwise stand in for a pending short write. An edit
    /// is a letter added, dropped or changed, or two neighbours swapped.
    let allowance: Int
    /// How many UTF-16 units shorter than the written text the text shown
    /// for it may be: its spaces, punctuation and markup, which an editor
    /// can drop or turn into formatting, case-folding contractions, and
    /// two for each edit the allowance takes.
    let shorter: Int
    /// How many units longer it may be: four, for apostrophes and spaces an
    /// editor adds, as in "dont" becoming "don't", case-folding
    /// expansions, and two for each edit.
    let longer: Int

    init(_ written: String) {
        letters = FieldEdit.letters(written)
        let originalLetters = written.filter(FieldEdit.isLetter).count
        allowance = min(8, originalLetters / 8)
        let letterUnits = written.reduce(0) { $0 + (FieldEdit.isLetter($1) ? $1.utf16.count : 0) }
        let foldedUnits = letters.reduce(0) { $0 + $1.utf16.count }
        // Full Unicode case folding can expand one unit into three, as
        // the ffi ligature does. A shown form can contract those units
        // again. These bounds permit both, without relaxing the letters
        // comparison that must still establish the write's words.
        shorter = written.utf16.count - min(letterUnits, (foldedUnits + 2) / 3) + 2 * allowance
        longer = 4 + max(0, foldedUnits - letterUnits) + 2 * allowance
    }

    /// Whether `shown` is the written text, in another form or as written.
    func shows(_ shown: String) -> Bool {
        let other = FieldEdit.letters(shown)
        return FieldEdit.distances(letters, toPrefixesOf: other, limit: allowance)[other.count] <= allowance
    }

    /// Whether the written letters can be told from a corrected selection.
    /// Use ordinary Levenshtein distance, without swaps, beyond four times
    /// the landing allowance. Each landing edit costs at most two ordinary
    /// edits, including a swap. If both texts could reach the same shown
    /// letters within the allowance, the triangle inequality would bound
    /// their ordinary distance by four times it. Require strictly more.
    /// The landing distance's restricted swaps lack that inequality (CA,
    /// AC, ABC), so twice its allowance alone would not prove separation.
    /// Both comparisons use folded letters, including sharp s and ligature
    /// expansions, but the allowance still counts original letters.
    func differs(from other: String) -> Bool {
        guard !letters.isEmpty else { return false }
        let other = FieldEdit.letters(other), limit = 4 * allowance
        return FieldEdit.distances(letters, toPrefixesOf: other, limit: limit, allowingSwaps: false)[other.count] > limit
    }

    /// The places in `read`, as UTF-16 offsets from its start at the edges
    /// of its characters, where the text before the place shows the
    /// written text (`shows`).
    func places(in read: String) -> [Int] {
        var units = 0, found: [Character] = [], ends = [(units: 0, letters: 0)]
        for character in read {
            if FieldEdit.isLetter(character) { found += FieldEdit.folded(character) }
            units += character.utf16.count
            ends.append((units, found.count))
        }
        let distances = FieldEdit.distances(letters, toPrefixesOf: found, limit: allowance)
        return ends.filter { distances[$0.letters] <= allowance }.map(\.units)
    }
}

/// Text read around a range after a write. Nil parts could not be read.
struct Readback: Equatable, Sendable {
    var length: Int?
    var text: String?
    var before: String?
    var after: String?
    /// The field's whole text, read only for short fields that were blank.
    var whole: String?
    /// The field's character count where it differs from `length`; see
    /// `FieldState.characters`.
    var characters: Int?
    /// The run of line breaks that ends the field's text, read only for a
    /// field whose `EditFacts.lastRunAfter` is known; see
    /// `FieldState.lastRun`.
    var lastRun: Int?
}

enum ReadbackVerdict: Equatable, Sendable {
    /// The field shows exactly the expected result.
    case expected
    /// The field still shows the state before the write.
    case unchanged
    /// Anything else, including a partial read.
    case differs
}

enum FieldEdit {
    /// Surrounding context kept on each side of the selection.
    static let contextLength = 64

    /// Whether `text` is worth writing. Text made only of spaces and line
    /// breaks is refused: a chat field can read a lone newline as Return and
    /// send.
    static func insertable(_ text: String) -> Bool {
        !text.allSatisfy { $0.isWhitespace || $0.isNewline }
    }

    /// `text` with the one space it needs after `before`, by the rule the
    /// server spaces dictation with (`spaced` in
    /// the speech cleanup contract): after a word or a
    /// sentence's end it starts with a space; at the start of a field,
    /// after a space or a line break, or opening with closing punctuation
    /// or a line break, it does not.
    static func spaced(_ text: String, after before: String) -> String {
        let bare = text.drop { $0 == " " }
        guard let first = bare.first, let last = before.last, !last.isWhitespace, !".,;:!?)]}'\"%\n".contains(first) else {
            return String(bare)
        }
        return " " + bare
    }

    /// `text` with each run of line breaks, and the spaces and tabs around
    /// it, as one space, for a terminal. Other spaces stay, the one that
    /// starts a continuation among them.
    static func oneLine(_ text: String) -> String {
        text.replacing(/(?:[ \t]*\R)+[ \t]*/, with: " ")
    }

    /// Text as every check here compares it. Web editors write a
    /// non-breaking space where two spaces meet, including the space before
    /// an insertion, so U+00A0 and U+0020 compare equal. Nothing else is
    /// normalized.
    static func comparable(_ text: String?) -> String? {
        text?.replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private static func matches(_ readback: String?, _ expected: String) -> Bool {
        comparable(readback) == comparable(expected)
    }

    /// Whether a character counts as a letter or digit when written text is
    /// compared with what an editor shows for it (`Reformatting`).
    static func isLetter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    /// A character under Unicode case folding, including expansions such
    /// as sharp s to ss. A fixed locale keeps comparisons independent of
    /// the person's regional settings; accents remain significant.
    static func folded(_ character: Character) -> String {
        String(character).folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// The letters and digits of `text`, case folded, in order: what an
    /// editor that reformats text keeps of it. Spaces, punctuation, quotes,
    /// the characters of markup and an emoji a shortcode became are left
    /// out.
    static func letters(_ text: String) -> [Character] {
        text.filter(isLetter).flatMap { folded($0) }
    }

    /// The edit distance from `a` to each prefix of `b`, by the prefix's
    /// length: the fewest characters added, dropped or changed, or pairs of
    /// neighbours swapped, that turn `a` into it. Anything more than
    /// `limit` reads `limit` + 1. Only prefixes within `limit` of `a`'s
    /// length can be that close, so only they are worked out, and the work
    /// grows with `a`'s length times `limit`.
    /// With `allowingSwaps` false this is ordinary Levenshtein distance,
    /// whose triangle inequality `Reformatting.differs` needs.
    static func distances(_ a: [Character], toPrefixesOf b: [Character], limit: Int, allowingSwaps: Bool = true) -> [Int] {
        let far = limit + 1, n = a.count
        var result = [Int](repeating: far, count: b.count + 1)
        // A `b` shorter than `a` by more than the limit has no prefix that
        // close.
        guard n - limit <= b.count else { return result }
        let m = min(b.count, n + limit)
        // The rows for a[..<i], a[..<i - 1] and a[..<i - 2], each holding
        // the distances to b[..<j] for j within `limit` of i, with the cell
        // on each side of that band set to `far` for the next row to read.
        var rows = [[Int]](repeating: [Int](repeating: far, count: m + 2), count: 3)
        for j in 0...min(m, limit) { rows[0][j] = j }
        if n > 0 {
            for i in 1...n {
                let (row, previous, earlier) = (i % 3, (i + 2) % 3, (i + 1) % 3)
                let low = max(0, i - limit), high = min(m, i + limit)
                if low > 0 { rows[row][low - 1] = far }
                rows[row][high + 1] = far
                for j in low...high {
                    guard j > 0 else {
                        rows[row][0] = i
                        continue
                    }
                    var distance = min(rows[previous][j] + 1, rows[row][j - 1] + 1,
                                       rows[previous][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                    if allowingSwaps, i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                        distance = min(distance, rows[earlier][j - 2] + 1)
                    }
                    rows[row][j] = min(distance, far)
                }
            }
        }
        for j in max(0, n - limit)...min(m, n + limit) { result[j] = rows[n % 3][j] }
        return result
    }

    /// The lengths of the runs of line breaks in `text`, in order.
    static func breakRuns(_ text: String) -> [Int] {
        text.split(omittingEmptySubsequences: true, whereSeparator: { !$0.isNewline }).map(\.count)
    }

    /// `text` with one line break taken out of each run marked in `leftOut`.
    static func leavingOut(_ leftOut: [Bool], from text: String) -> String {
        var result = ""
        var run = -1
        var inRun = false
        for character in text {
            if character.isNewline, !inRun {
                run += 1
                inRun = true
                if run < leftOut.count, leftOut[run] { continue }
            } else if !character.isNewline {
                inRun = false
            }
            result.append(character)
        }
        return result
    }

    /// Whether `ranged`, a WebKit field's ranged reads over its whole
    /// count, is `byMarkers`, its text by markers, with some of its line
    /// breaks counted twice. WebKit's ranged reads count the break between
    /// two paragraphs twice and a `<br>` once, so in a paragraph holding a
    /// `<br>` the two kinds meet in one run: "Alpha\\nBravo\\nCharlie" by
    /// markers read as "Alpha\\nBravo\\n\\nCharlie". Every other character
    /// must be the same and in the same order, and each run of m line
    /// breaks by markers must face a run of m to 2m. A marker range that
    /// stops before a character leaves that character facing nothing. One
    /// that stops inside the last run of breaks passes, since an empty last
    /// paragraph reads one break longer by ranged reads as well; with
    /// `lastRunExact` the run that ends the text must face exactly m, which
    /// refuses that.
    ///
    /// An image with alt text is U+FFFC in the text by markers and nothing
    /// in the ranged reads, so that character is left out of both before
    /// they are compared: `<p>Alpha</p><p>BravoDelta</p><p><img alt></p>`
    /// reads "Alpha\nBravoDelta\n\u{FFFC}" by markers and
    /// "Alpha\n\nBravoDelta\n\n" by ranged reads.
    static func breaksCountedTwice(byMarkers: String, ranged: String, lastRunExact: Bool = false) -> Bool {
        let attachment: UInt16 = 0xFFFC
        let markers = byMarkers.utf16.filter { $0 != attachment }, read = ranged.utf16.filter { $0 != attachment }
        let newline: UInt16 = 10
        var i = 0, j = 0
        while i < markers.count || j < read.count {
            guard i < markers.count, j < read.count else { return false }
            if markers[i] != newline {
                guard read[j] == markers[i] else { return false }
                i += 1
                j += 1
                continue
            }
            let m = markers[i...].prefix(while: { $0 == newline }).count
            let n = read[j...].prefix(while: { $0 == newline }).count
            guard m <= n, n <= 2 * m, !lastRunExact || i + m < markers.count || n == m else { return false }
            i += m
            j += n
        }
        return true
    }

    /// A WebKit field's text by its markers set against its ranged reads
    /// over the whole count; see `aligned`.
    struct Alignment: Equatable {
        /// The text by markers with any list labels taken out. It keeps
        /// every image, so it is as long as the markers measure.
        var text: String
        /// Where in `text` the markers hold an image that the ranged reads
        /// leave out, as UTF-16 offsets.
        var images: [Int]
        /// A list label was taken out.
        var labels: Bool

        /// `text` without its images, in the offsets the selection takes.
        var selectionText: String {
            let skipped = Set(images)
            let units = text.utf16.enumerated().filter { !skipped.contains($0.offset) }.map(\.element)
            return String(utf16CodeUnits: units, count: units.count)
        }
    }

    /// How many ways of lining up a WebKit field's two texts `aligned`
    /// follows at once before it gives up. Text without images or typed
    /// U+FFFC has one; a line of images beside empty or typed lines can
    /// open a second, which the runs of breaks close within a few lines.
    static let maxAlignmentPlaces = 32

    /// `byMarkers`, a WebKit field's text by its markers, set against
    /// `ranged`, its ranged reads over the whole count, or nil where the two
    /// cannot be lined up. Two things in the markers' text are in no other
    /// read.
    ///
    /// A list item that starts with text has its label in front, "• " or
    /// "1. ", which has no length and no offset:
    /// `<p>Start.</p><ul><li>One</li><li>Two</li></ul><p>End.</p>` reads
    /// "Start.\n• One\n• Two\nEnd." by markers, 23 units, while the
    /// markers measure it as 19, the selection's offsets skip the labels and
    /// the ranged reads hold none: "Start.\n\nOne\nTwo\n\nEnd.".
    ///
    /// An image with alt text is U+FFFC and one unit of the markers'
    /// lengths, and has no offset in the selection or the ranged reads. A
    /// U+FFFC typed as text is the same character, and every read holds it.
    ///
    /// So the two texts are taken line by line, a line being what lies
    /// between two runs of line breaks. Each line by markers is either its
    /// line by ranged reads with a label in front and U+FFFC added
    /// anywhere, and with nothing else, or a line of images alone, which
    /// the ranged reads leave out with the breaks on each side of it run
    /// together: `<p>BravoDelta</p><p><img alt="Picture"></p><p><br></p>`
    /// reads "BravoDelta\n\u{FFFC}\n\n" by markers and "BravoDelta\n\n\n\n\n"
    /// by ranged reads. Each run of m breaks by markers between two lines
    /// kept, with those of the lines left out between them, must face a
    /// run of m to 2m, as in `breaksCountedTwice`, which is what tells
    /// a typed U+FFFC alone on a line from an image alone on the next. A
    /// U+FFFC is an image only where the ranged reads do not hold it; of
    /// two in one line that could each be the one they hold, which is kept
    /// makes no difference to the text. A label holds no U+FFFC, so an item
    /// that starts with an image has none. Where the texts can be lined up
    /// in more than one way across lines, or in none, the answer is nil.
    /// Every character kept is one the ranged reads hold or an image, and
    /// nothing the ranged reads hold is taken out.
    ///
    /// The ways are followed a marker line at a time and a way is dropped as
    /// soon as the breaks and lines left on both sides cannot meet: alone on
    /// lines of one U+FFFC, typed or images, the ways would otherwise stay
    /// apart to the end and grow with the square of the lines, and their
    /// work with the cube. More than `maxAlignmentPlaces` at once is nil, so
    /// the work grows with the text.
    static func aligned(byMarkers: String, ranged: String) -> Alignment? {
        let attachment: UInt16 = 0xFFFC, newline: UInt16 = 10
        /// The lines of `text` and the lengths of the runs of line breaks
        /// between them, one line more than runs; a line can be empty.
        func lines(_ text: String) -> (lines: [[UInt16]], runs: [Int]) {
            var lines: [[UInt16]] = [[]], runs: [Int] = []
            var inRun = false
            for unit in text.utf16 {
                if unit == newline {
                    if !inRun { runs.append(0) }
                    runs[runs.count - 1] += 1
                } else {
                    if inRun { lines.append([]) }
                    lines[lines.count - 1].append(unit)
                }
                inRun = unit == newline
            }
            if inRun { lines.append([]) }
            return (lines, runs)
        }
        /// `line` by markers as `other` by ranged reads with a label in
        /// front and U+FFFC added: the label's length and where in `line`
        /// the added ones are. From the end, a unit that matches is the
        /// ranged reads' own and of the rest only U+FFFC may be extra; where
        /// neither holds, the ranged line must be used up, and what is left
        /// in front is the label.
        func match(_ line: [UInt16], _ other: [UInt16]) -> (label: Int, images: [Int])? {
            var i = line.count - 1, j = other.count - 1
            var images: [Int] = []
            while i >= 0 {
                if j >= 0, line[i] == other[j] {
                    j -= 1
                } else if line[i] == attachment {
                    images.append(i)
                } else {
                    break
                }
                i -= 1
            }
            guard j < 0, !line[..<(i + 1)].contains(attachment) else { return nil }
            return (i + 1, images.reversed())
        }
        let markers = lines(byMarkers), read = lines(ranged)
        let count = read.lines.count, last = markers.lines.count - 1
        // What is left to line up after a marker line, to cut short a way
        // that cannot reach the end. Every break by markers belongs to the
        // run facing the next ranged line kept, which holds m to 2m of them,
        // so from ranged line r on the markers need at least `least[r]` and
        // at most `most[r]` more breaks; `rest[k]` is how many follow line
        // k. Lines other than images must each meet a ranged line, and no
        // marker line meets more than one.
        var least = Array(repeating: 0, count: count + 1), most = least
        for r in stride(from: count - 1, through: 0, by: -1) {
            let run = r > 0 ? read.runs[r - 1] : 0
            least[r] = least[r + 1] + (run + 1) / 2
            most[r] = most[r + 1] + run
        }
        let imagesAlone = markers.lines.map { !$0.isEmpty && $0.allSatisfy { $0 == attachment } }
        var rest = Array(repeating: 0, count: last + 1), rigid = rest
        for k in stride(from: last - 1, through: 0, by: -1) {
            rest[k] = rest[k + 1] + (k + 1 < markers.runs.count ? markers.runs[k + 1] : 0)
            rigid[k] = rigid[k + 1] + (imagesAlone[k + 1] ? 0 : 1)
        }
        /// How far the ranged lines are used, and the breaks by markers
        /// since the last line kept.
        struct Place: Equatable { var read: Int, breaks: Int }
        /// A place reached after a marker line: by how many ways, at most
        /// two, from which place after the line before and whether this
        /// line was kept.
        struct Reached { var place: Place, ways: Int, from: Int, kept: Bool }
        var steps: [[Reached]] = []
        var places = [Reached(place: Place(read: 0, breaks: 0), ways: 1, from: -1, kept: false)]
        for (index, line) in markers.lines.enumerated() {
            let after = index < markers.runs.count ? markers.runs[index] : 0
            var reached: [Reached] = []
            func reach(_ place: Place, from: Int, ways: Int, kept: Bool) {
                let r = place.read, b = place.breaks
                guard r == 0 ? b == 0 : r == count || b <= read.runs[r - 1],
                      least[r] <= b + rest[index], b + rest[index] <= most[r],
                      r + rigid[index] <= count, r + last - index >= count
                else { return }
                if let seen = reached.firstIndex(where: { $0.place == place }) {
                    reached[seen].ways = min(2, reached[seen].ways + ways)
                } else {
                    reached.append(Reached(place: place, ways: ways, from: from, kept: kept))
                }
            }
            for (from, entry) in places.enumerated() {
                let place = entry.place
                if place.read < count, match(line, read.lines[place.read]) != nil {
                    let fits = place.read == 0
                        ? place.breaks == 0
                        : place.breaks <= read.runs[place.read - 1] && read.runs[place.read - 1] <= 2 * place.breaks
                    if fits { reach(Place(read: place.read + 1, breaks: after), from: from, ways: entry.ways, kept: true) }
                }
                if imagesAlone[index] {
                    reach(Place(read: place.read, breaks: place.breaks + after), from: from, ways: entry.ways, kept: false)
                }
            }
            // Ways that stay apart this long are refused, which bounds the
            // work by the length of the text.
            guard !reached.isEmpty, reached.count <= maxAlignmentPlaces else { return nil }
            steps.append(reached)
            places = reached
        }
        guard let end = places.firstIndex(where: { $0.place == Place(read: count, breaks: 0) }), places[end].ways == 1 else { return nil }
        var chosen: [Reached] = []
        var at = end
        for reached in steps.reversed() {
            chosen.append(reached[at])
            at = reached[at].from
        }
        var kept: [UInt16] = [], images: [Int] = [], labels = false
        for (index, (line, step)) in zip(markers.lines, chosen.reversed()).enumerated() {
            if step.kept {
                guard let found = match(line, read.lines[step.place.read - 1]) else { return nil }
                labels = labels || found.label > 0
                images += found.images.map { kept.count + $0 - found.label }
                kept += line.dropFirst(found.label)
            } else {
                images += line.indices.map { kept.count + $0 }
                kept += line
            }
            if index < markers.runs.count { kept += Array(repeating: newline, count: markers.runs[index]) }
        }
        return Alignment(text: String(utf16CodeUnits: kept, count: kept.count), images: images, labels: labels)
    }

    /// For each run of line breaks in `text`, whether `read` holds one break
    /// fewer there. Nil unless `read` is `text` with nothing else changed.
    static func breaksLeftOut(of text: String, in read: String) -> [Bool]? {
        let expected = Array(comparable(text) ?? text), shown = Array(comparable(read) ?? read)
        var leftOut: [Bool] = []
        var i = 0, j = 0
        while i < expected.count {
            guard expected[i].isNewline else {
                guard j < shown.count, shown[j] == expected[i] else { return nil }
                i += 1
                j += 1
                continue
            }
            let breaks = expected[i...].prefix(while: \.isNewline).count
            let shownBreaks = shown[j...].prefix(while: \.isNewline).count
            guard shownBreaks == breaks || shownBreaks == breaks - 1 else { return nil }
            leftOut.append(shownBreaks < breaks)
            i += breaks
            j += shownBreaks
        }
        return j == shown.count ? leftOut : nil
    }

    /// Whether a readback of the inserted range shows the inserted text as
    /// the field's offsets read it.
    private static func showsInserted(_ readback: String?, facts: EditFacts) -> Bool {
        matches(readback, facts.readText)
    }

    /// Rich editors keep a placeholder line break in an empty field and drop
    /// or restore it as text comes and goes, so a field holding only line
    /// breaks counts as empty when an insertion is checked.
    static func isBlank(_ text: String) -> Bool {
        text.allSatisfy(\.isNewline)
    }

    /// Whether a field that was blank shows only the inserted text, alone or
    /// with the editor's placeholder break kept after it. Nothing else is
    /// excused.
    private static func blankShowsInsertion(_ readback: Readback, facts: EditFacts) -> Bool {
        guard facts.blankBefore, showsInserted(readback.text, facts: facts), countsAsInserted(readback, facts: facts),
              let whole = comparable(readback.whole),
              let text = comparable(facts.readText) else { return false }
        return whole == text || whole == text + "\n"
    }

    /// The inserted text, its context and the field's length, exactly.
    private static func exactlyInserted(_ readback: Readback, facts: EditFacts) -> Bool {
        readback.length == facts.lengthAfter && showsInserted(readback.text, facts: facts)
            && matches(readback.before, facts.before) && matches(readback.after, facts.after)
            && countsAsInserted(readback, facts: facts) && endsAsInserted(readback, facts: facts)
    }

    /// Whether a field whose end rested on WebKit's range for its own text
    /// ends in the run of line breaks the insertion leaves there; see
    /// `EditFacts.lastRunAfter`. Any other field passes. The run is needed
    /// however the readback measured the field: a field whose reads all
    /// agree, such as one `div` for each line, reads as breaks counted twice
    /// when its range ends one break short, and is measured by its count
    /// once the range comes right.
    private static func endsAsInserted(_ readback: Readback, facts: EditFacts) -> Bool {
        guard facts.lastRunBefore != nil else { return true }
        guard let expected = facts.lastRunAfter, let shown = readback.lastRun else { return false }
        return shown == expected
    }

    /// Whether the paragraph breaks the field's offsets leave out are those
    /// the insertion accounts for: as many as before, plus the inserted
    /// text's own. One more is a break the person added in the same moment,
    /// which shows nowhere else. A blank field's placeholder break is a
    /// character its offsets count, so it does not enter here. A replaced
    /// selection may have taken breaks with it.
    private static func countsAsInserted(_ readback: Readback, facts: EditFacts) -> Bool {
        guard let length = readback.length else { return false }
        let leftOut = (readback.characters ?? length) - length
        let accounted = facts.charactersBefore - facts.lengthBefore + facts.breaksUncounted
        return facts.originalText.isEmpty ? leftOut == accounted : leftOut <= accounted
    }

    /// Whether `a`, read now, is `b` as it was observed. Where `b` kept the
    /// run of line breaks that ends the field (`FieldState.lastRun`) and
    /// `a` was read whole by its markers, `a` must end in the same run
    /// (`FieldState.endingRun`): text beyond the compared context can change
    /// without changing the field's length, as a distant "\n\n" at its end
    /// becoming "X\n", and the insertion's readback is held against the
    /// run observed. A field that has to be read past its own range by now
    /// is still compared; one measured by its count is not, as on `main`,
    /// and its readback reads its end instead.
    static func sameState(_ a: FieldState, _ b: FieldState) -> Bool {
        a.selection == b.selection && a.length == b.length && a.characters == b.characters
            && comparable(a.selectedText) == comparable(b.selectedText)
            && comparable(a.before) == comparable(b.before)
            && comparable(a.after) == comparable(b.after)
            && (b.lastRun == nil || a.endingRun == nil || a.endingRun == b.lastRun)
    }

    /// The same text with the selection collapsed to its end. Derive the
    /// caret's context from the already-read selection and context, in the
    /// same UTF-16 units as a field read, without reading any more text.
    static func afterCollapsing(_ state: FieldState) -> FieldState {
        var collapsed = state
        let before = (state.before + state.selectedText) as NSString
        collapsed.before = before.substring(from: max(0, before.length - contextLength))
        collapsed.selection = FieldRange(location: state.selection.upperBound, length: 0)
        collapsed.selectedText = ""
        return collapsed
    }

    static func beforeRange(for selection: FieldRange) -> FieldRange {
        let start = max(0, selection.location - contextLength)
        return FieldRange(location: start, length: selection.location - start)
    }

    static func afterRange(for selection: FieldRange, length: Int) -> FieldRange {
        FieldRange(location: selection.upperBound, length: max(0, min(contextLength, length - selection.upperBound)))
    }

    /// Classifies a readback taken after writing `facts.insertedText`.
    /// `unchangedProbe` is the same field read at the original selection.
    static func verifyInsertion(_ readback: Readback, unchangedProbe: Readback, facts: EditFacts) -> ReadbackVerdict {
        if exactlyInserted(readback, facts: facts) || blankShowsInsertion(readback, facts: facts) { return .expected }
        if unchangedProbe.length == facts.lengthBefore, matches(unchangedProbe.text, facts.originalText),
           matches(unchangedProbe.before, facts.before), matches(unchangedProbe.after, facts.after) {
            return .unchanged
        }
        return .differs
    }
}
