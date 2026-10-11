// AppKit rather than Foundation: the Command Line Tools cannot load the
// overlay that importing Foundation beside Testing asks for.
import AppKit
@testable import Onboarding
import Testing

/// How the System Settings guide finds Intention's line and where it draws,
/// from frames made up to look like System Settings' permission lists. No
/// System Settings, Accessibility or window is used.
@Suite
struct SettingsGuideTests {
    /// A list drawn like macOS 27's: lines 44 points tall from y 200, names
    /// at x 260 and switches at x 640, inside a window at (100, 80) that
    /// shows y 120 to 520 of its scroll area. Window server coordinates.
    private static let window = CGRect(x: 100, y: 80, width: 715, height: 480)
    private static let visible = CGRect(x: 100, y: 120, width: 715, height: 400)

    private static func label(line: Int, clip: CGRect = visible) -> SettingsNode {
        SettingsNode(kind: .intentionLabel, frame: CGRect(x: 260, y: 212 + CGFloat(line) * 44, width: 46, height: 16), clip: clip)
    }

    private static func toggle(line: Int, isOn: Bool? = false, isIntention: Bool = false, clip: CGRect = visible) -> SettingsNode {
        SettingsNode(kind: .toggle(isOn: isOn, isIntention: isIntention), frame: switchFrame(line: line), clip: clip)
    }

    private static func switchFrame(line: Int) -> CGRect {
        CGRect(x: 640, y: 210 + CGFloat(line) * 44, width: 32, height: 19)
    }

    /// Five lines, every switch off, Intention's label on `line` only.
    private static func list(intentionAt line: Int, clip: CGRect = visible) -> [SettingsNode] {
        (0..<5).map { toggle(line: $0, clip: clip) } + [label(line: line, clip: clip)]
    }

    @Test func findsTheSwitchOnTheLineThatSaysIntention() {
        let reading = SettingsList.locate(Self.list(intentionAt: 2))
        #expect(reading == .row(toggle: Self.switchFrame(line: 2), label: Self.label(line: 2).frame))
    }

    @Test func aSwitchTitledIntentionNeedsNoLabel() {
        let nodes = (0..<5).map { Self.toggle(line: $0, isIntention: $0 == 3) }
        #expect(SettingsList.locate(nodes) == .row(toggle: Self.switchFrame(line: 3), label: Self.switchFrame(line: 3)))
    }

    @Test func aLabelPairsWithTheNearestSwitchToItsRightOnly() {
        // A second switch further right on the same line, and one to the
        // label's left, are not Intention's.
        let far = SettingsNode(kind: .toggle(isOn: false, isIntention: false), frame: Self.switchFrame(line: 1).offsetBy(dx: 60, dy: 0),
                               clip: Self.visible)
        let left = SettingsNode(kind: .toggle(isOn: false, isIntention: false), frame: CGRect(x: 200, y: 254, width: 32, height: 19),
                                clip: Self.visible)
        let reading = SettingsList.locate([left, far, Self.toggle(line: 1), Self.label(line: 1)])
        #expect(reading == .row(toggle: Self.switchFrame(line: 1), label: Self.label(line: 1).frame))
    }

    @Test func aLabelWithNoSwitchOnItsLineIsNotListed() {
        let nodes = [Self.toggle(line: 0), Self.toggle(line: 4), Self.label(line: 2)]
        #expect(SettingsList.locate(nodes) == .notListed)
        #expect(SettingsList.locate((0..<5).map { Self.toggle(line: $0) }) == .notListed)
    }

    @Test func twoLinesNamedIntentionAreNotGuessedBetween() {
        let nodes = Self.list(intentionAt: 1) + [Self.label(line: 3)]
        #expect(SettingsList.locate(nodes) == .ambiguous)
    }

    @Test func linesThatAreAlreadyOnNeedNothing() {
        #expect(SettingsList.locate([Self.toggle(line: 1, isOn: true), Self.label(line: 1)]) == .alreadyOn)
        let both = [Self.toggle(line: 1, isOn: true), Self.label(line: 1), Self.toggle(line: 3, isOn: true), Self.label(line: 3)]
        #expect(SettingsList.locate(both) == .alreadyOn)
        // One of two copies off is still a guess.
        let one = [Self.toggle(line: 1, isOn: true), Self.label(line: 1), Self.toggle(line: 3), Self.label(line: 3)]
        #expect(SettingsList.locate(one) == .ambiguous)
    }

    @Test func aSwitchWhoseStateCannotBeReadIsNeverShownAsOff() {
        let nodes = [Self.toggle(line: 2, isOn: nil), Self.label(line: 2)]
        #expect(SettingsList.locate(nodes) == .unreadable)
        // Beside a copy that is on, still unknown rather than ambiguous.
        let two = nodes + [Self.toggle(line: 4, isOn: true), Self.label(line: 4)]
        #expect(SettingsList.locate(two) == .unreadable)
        #expect(Self.mark(.unreadable) == .none)
    }

    @Test func onlyLabelsOnALineWithASwitchAreRead() {
        let switches = (0..<3).map { Self.switchFrame(line: $0) }
        #expect(SettingsList.isBesideSwitch(Self.label(line: 1).frame, toggles: switches))
        // A heading above the list, a label on a line with no switch, and a
        // label to the right of the switch are left unread.
        #expect(!SettingsList.isBesideSwitch(CGRect(x: 260, y: 160, width: 200, height: 20), toggles: switches))
        #expect(!SettingsList.isBesideSwitch(Self.label(line: 4).frame, toggles: switches))
        #expect(!SettingsList.isBesideSwitch(CGRect(x: 700, y: 256, width: 60, height: 16), toggles: switches))
        #expect(!SettingsList.isBesideSwitch(Self.label(line: 1).frame, toggles: []))
    }

    @Test func aReadCutShortShowsNothing() {
        // It did not learn whether Intention's switch is on, and the note says
        // to turn it on.
        #expect(Self.mark(.incomplete) == SettingsGuideLayout.Mark.none)
    }

    // MARK: Which page and which copy

    private static let screenRecordingTitle = "Screen & System Audio Recording"

    @Test func onlyTheScreenRecordingPageIsRead() {
        // Intention off on the Microphone page, as when its microphone was
        // refused: the reader does not look, and the guide shows nothing,
        // since a note here would ask for the microphone's switch.
        let microphone = Self.scripted(["Notes", "Intention", "Zoom"], title: "Microphone")
        let off = Self.read(microphone.window)
        #expect(off == nil)
        #expect(Self.markAfterTwoReads(off) == SettingsGuideLayout.Mark.none)
        // The same list under either title macOS gives Screen Recording.
        for title in ["Screen & System Audio Recording", "Screen Recording"] {
            let page = Self.scripted(["Notes", "Intention", "Zoom"], title: title)
            #expect(Self.read(page.window) == .row(toggle: CGRect(x: 640, y: 254, width: 32, height: 19),
                                                   label: CGRect(x: 260, y: 256, width: 46, height: 16)))
        }
        // A window without a readable title is not taken for the page.
        #expect(Self.read(Self.scripted(["Intention"], title: nil).window) == nil)
    }

    @Test func aPageChangedDuringTheReadGivesNoReading() {
        // The person moves to Microphone, which lists Intention too, while the
        // Screen Recording list is being walked: the first line answers,
        // and the window is on the other page by the time the walk ends.
        let page = Self.scripted(["Notes", "Intention", "Zoom"])
        page.lines[0].line.whenRead = { page.window.title = "Microphone" }
        #expect(Self.read(page.window) == nil)
        // The same when the walk was cut short on the way.
        let cut = Self.scripted(["Notes", "Intention", "Zoom"])
        cut.lines[0].line.whenRead = { cut.window.title = "Microphone" }
        cut.lines[2].line.unanswered = true
        #expect(Self.read(cut.window) == nil)
    }

    @Test func onlyTheReleaseLooksForItsOwnLine() {
        // A development copy is Intention.app too, so the list can show it
        // under the release's name: it never looks for a line.
        #expect(SettingsGuideLayout.ownNames(bundleIdentifier: "co.intention.mac",
                                             candidates: ["Intention", "Intention Dev", "Intention"]) == nil)
        #expect(SettingsGuideLayout.ownNames(bundleIdentifier: nil, candidates: ["Intention"]) == nil)
        #expect(SettingsGuideLayout.ownNames(bundleIdentifier: "co.intention.mac", candidates: ["Intention", "Intention", nil, ""])
            == ["Intention"])
    }

    // MARK: Which reads count

    @Test func aReadFromAnEarlierVisitIsDropped() {
        #expect(SettingsGuideLayout.accepts(visit: 3, currentVisit: 3, windowBefore: Self.window, windowAfter: Self.window))
        #expect(!SettingsGuideLayout.accepts(visit: 2, currentVisit: 3, windowBefore: Self.window, windowAfter: Self.window))
    }

    @Test func aReadDuringADragIsDropped() {
        let dragged = Self.window.offsetBy(dx: 12, dy: 0)
        #expect(!SettingsGuideLayout.accepts(visit: 1, currentVisit: 1, windowBefore: Self.window, windowAfter: dragged))
        #expect(!SettingsGuideLayout.accepts(visit: 1, currentVisit: 1, windowBefore: Self.window, windowAfter: nil))
    }

    @Test func aLineScrolledMostlyOutOfViewIsReportedAsSuch() {
        // Line 7's switch runs from y 518 to 537; the scroll area ends at 520.
        let nodes = Self.list(intentionAt: 7) + [Self.toggle(line: 7)]
        #expect(SettingsList.locate(nodes) == .scrolledAway)
        // Twelve of its nineteen points showing is in view.
        let clip = CGRect(x: 100, y: 120, width: 715, height: 410)
        #expect(SettingsList.locate([Self.toggle(line: 7, clip: clip), Self.label(line: 7, clip: clip)])
            == .row(toggle: Self.switchFrame(line: 7), label: Self.label(line: 7).frame))
    }

    @Test func namesMatchWholeIgnoringCaseAndSpaces() {
        #expect(SettingsList.isIntention(" intention\n", names: ["Intention"]))
        #expect(!SettingsList.isIntention("Intention Dev", names: ["Intention"]))
        #expect(SettingsList.isIntention("Intention Dev", names: ["Intention", "Intention Dev"]))
        #expect(!SettingsList.isIntention("", names: [""]))
    }

    @Test func windowServerFramesTurnIntoAppKitFrames() {
        let frame = SettingsList.appKitFrame(CGRect(x: 10, y: 100, width: 50, height: 20), mainDisplayHeight: 900)
        #expect(frame == CGRect(x: 10, y: 780, width: 50, height: 20))
    }

    // MARK: Which mark

    private static let start = ContinuousClock.now
    private static let line1 = SettingsListReading.row(toggle: CGRect(x: 640, y: 254, width: 32, height: 19),
                                                       label: CGRect(x: 260, y: 256, width: 46, height: 16))

    /// The mark for one reading, found twice in a row, drawn at once in the
    /// window it was read in.
    private static func mark(_ reading: SettingsListReading?) -> SettingsGuideLayout.Mark {
        markAfterTwoReads(reading)
    }

    private static func markAfterTwoReads(_ reading: SettingsListReading?, window: CGRect = window) -> SettingsGuideLayout.Mark {
        let first = SettingsGuideLayout.observe(reading, window: window, at: start, after: nil)
        let second = SettingsGuideLayout.observe(reading, window: window, at: start + .milliseconds(150), after: first)
        return SettingsGuideLayout.mark(for: .screenRecording, observation: second, window: window, now: start + .milliseconds(200),
                                        mainDisplayHeight: 900)
    }

    @Test func withNoReadingOnlyTheAccessibilityRequestShowsItsNote() {
        // The first Accessibility request never reads, and setup has just
        // opened its page.
        #expect(SettingsGuideLayout.mark(for: .accessibility, observation: nil, window: Self.window, now: Self.start,
                                         mainDisplayHeight: 900) == .list)
        // A Screen Recording visit with no reading may be on another
        // permission's list, where the note would point at the wrong thing.
        #expect(SettingsGuideLayout.mark(for: .screenRecording, observation: nil, window: Self.window, now: Self.start,
                                         mainDisplayHeight: 900) == SettingsGuideLayout.Mark.none)
    }

    @Test func onlyAnOffSwitchFoundTwiceIsRinged() {
        // Line 1's switch at (640, 254) flips to AppKit: 900 - 254 - 19 = 627.
        #expect(Self.mark(Self.line1) == .row(toggle: CGRect(x: 640, y: 627, width: 32, height: 19)))
        for reading in [SettingsListReading.notListed, .alreadyOn, .unreadable, .incomplete] {
            #expect(Self.mark(reading) == .none)
        }
        for reading in [SettingsListReading.ambiguous, .scrolledAway] {
            #expect(Self.mark(reading) == .list)
        }
    }

    @Test func nothingIsDrawnUntilTwoReadsAgree() {
        let nothing = SettingsGuideLayout.Mark.none
        let first = SettingsGuideLayout.observe(Self.line1, window: Self.window, at: Self.start, after: nil)
        #expect(SettingsGuideLayout.mark(for: .screenRecording, observation: first, window: Self.window, now: Self.start,
                                         mainDisplayHeight: 900) == nothing)
        // The list scrolled 44 points between reads: the switch is elsewhere,
        // so neither place is ringed.
        let scrolled = SettingsListReading.row(toggle: CGRect(x: 640, y: 210, width: 32, height: 19),
                                               label: CGRect(x: 260, y: 212, width: 46, height: 16))
        let second = SettingsGuideLayout.observe(scrolled, window: Self.window, at: Self.start + .milliseconds(150), after: first)
        #expect(SettingsGuideLayout.mark(for: .screenRecording, observation: second, window: Self.window,
                                         now: Self.start + .milliseconds(150), mainDisplayHeight: 900) == nothing)
        // A read off the page in between breaks the run too.
        let off = SettingsGuideLayout.observe(nil, window: Self.window, at: Self.start + .milliseconds(300), after: second)
        let back = SettingsGuideLayout.observe(scrolled, window: Self.window, at: Self.start + .milliseconds(450), after: off)
        #expect(SettingsGuideLayout.mark(for: .screenRecording, observation: back, window: Self.window,
                                         now: Self.start + .milliseconds(450), mainDisplayHeight: 900) == nothing)
        // The note waits for a second read as the ring does: one read that
        // found two lines, as a page caught changing might, shows nothing.
        let two = SettingsGuideLayout.observe(.ambiguous, window: Self.window, at: Self.start, after: nil)
        #expect(SettingsGuideLayout.mark(for: .screenRecording, observation: two, window: Self.window, now: Self.start,
                                         mainDisplayHeight: 900) == nothing)
        let again = SettingsGuideLayout.observe(.ambiguous, window: Self.window, at: Self.start + .milliseconds(150), after: two)
        #expect(SettingsGuideLayout.mark(for: .screenRecording, observation: again, window: Self.window,
                                         now: Self.start + .milliseconds(150), mainDisplayHeight: 900) == .list)
    }

    @Test func aReadingThatIsNotFollowedExpires() {
        let first = SettingsGuideLayout.observe(Self.line1, window: Self.window, at: Self.start, after: nil)
        let second = SettingsGuideLayout.observe(Self.line1, window: Self.window, at: Self.start + .milliseconds(150), after: first)
        let ring = SettingsGuideLayout.Mark.row(toggle: CGRect(x: 640, y: 627, width: 32, height: 19))
        #expect(SettingsGuideLayout.mark(for: .screenRecording, observation: second, window: Self.window, now: Self.start + .milliseconds(1100),
                                         mainDisplayHeight: 900) == ring)
        // No read has landed for 1.2 seconds since that one began, as when
        // reads are slow or dropped: the list may have scrolled since, or
        // the person may have left the page.
        #expect(SettingsGuideLayout.mark(for: .screenRecording, observation: second, window: Self.window,
                                         now: Self.start + .milliseconds(1350), mainDisplayHeight: 900) == SettingsGuideLayout.Mark.none)
    }

    @Test func theRingFollowsAWindowMovedSinceTheRead() {
        let moved = Self.window.offsetBy(dx: 40, dy: -30)
        let first = SettingsGuideLayout.observe(Self.line1, window: Self.window, at: Self.start, after: nil)
        let second = SettingsGuideLayout.observe(Self.line1, window: Self.window, at: Self.start + .milliseconds(150), after: first)
        let mark = SettingsGuideLayout.mark(for: .screenRecording, observation: second, window: moved,
                                            now: Self.start + .milliseconds(200), mainDisplayHeight: 900)
        // Line 1's switch at (640, 254) moves to (680, 224), then flips to
        // AppKit: 900 - 224 - 19 = 657.
        #expect(mark == .row(toggle: CGRect(x: 680, y: 657, width: 32, height: 19)))
        // Read again after the move, the same line in the same place in the
        // window still counts as found twice.
        let after = SettingsListReading.row(toggle: CGRect(x: 680, y: 224, width: 32, height: 19),
                                            label: CGRect(x: 300, y: 226, width: 46, height: 16))
        let third = SettingsGuideLayout.observe(after, window: moved, at: Self.start + .milliseconds(300), after: second)
        #expect(SettingsGuideLayout.mark(for: .screenRecording, observation: third, window: moved, now: Self.start + .milliseconds(300), mainDisplayHeight: 900)
            == .row(toggle: CGRect(x: 680, y: 657, width: 32, height: 19)))
    }

    @Test func aRingIsNotCarriedIntoAResizedWindow() {
        // 100 points wider: the list's column may have moved with the edge.
        let wider = CGRect(x: 100, y: 80, width: 815, height: 480)
        let first = SettingsGuideLayout.observe(Self.line1, window: Self.window, at: Self.start, after: nil)
        let second = SettingsGuideLayout.observe(Self.line1, window: Self.window, at: Self.start + .milliseconds(150), after: first)
        #expect(SettingsGuideLayout.mark(for: .screenRecording, observation: second, window: wider, now: Self.start + .milliseconds(200), mainDisplayHeight: 900)
            == .list)
    }

    // MARK: Reading a scripted Settings window

    private static func read(_ window: MockElement) -> SettingsListReading? {
        SettingsListReader.reading(of: AXElement(ref: window.ref),
                                   pages: ["Screen & System Audio Recording", "Screen Recording"], names: ["Intention"])
    }

    @Test func twoReadableLinesNamedIntentionAreAmbiguous() {
        #expect(Self.read(Self.scripted(["Notes", "Intention", "Zoom", "Intention"]).window) == .ambiguous)
    }

    @Test func aLineThatDoesNotAnswerLeavesTheReadIncomplete() {
        let list = Self.scripted(["Notes", "Intention", "Zoom", "Intention"])
        list.lines[3].line.unanswered = true
        #expect(Self.read(list.window) == .incomplete)
    }

    @Test func aNameThatDoesNotAnswerLeavesTheReadIncomplete() {
        let list = Self.scripted(["Notes", "Intention", "Zoom", "Intention"])
        list.lines[3].label.failing[kAXValueAttribute] = .cannotComplete
        #expect(Self.read(list.window) == .incomplete)
    }

    @Test func aListWhoseLinesDoNotAnswerLeavesTheReadIncomplete() {
        let list = Self.scripted(["Notes", "Intention"])
        list.scroll.failing[kAXChildrenAttribute] = .cannotComplete
        #expect(Self.read(list.window) == .incomplete)
    }

    @Test func aSwitchThatDoesNotAnswerLeavesTheReadIncomplete() {
        // One that cannot be placed.
        let placed = Self.scripted(["Notes", "Intention", "Zoom", "Intention"])
        placed.lines[3].toggle.failing[kAXPositionAttribute] = .cannotComplete
        #expect(Self.read(placed.window) == .incomplete)
        // One whose own title, which could say Intention, times out.
        let titled = Self.scripted(["Notes", "Intention", "Zoom"])
        titled.lines[2].toggle.failing[kAXTitleAttribute] = .cannotComplete
        #expect(Self.read(titled.window) == .incomplete)
        // One whose state is unknown.
        let state = Self.scripted(["Notes", "Intention"])
        state.lines[1].toggle.failing[kAXValueAttribute] = .cannotComplete
        #expect(Self.read(state.window) == .incomplete)
    }

    /// The scripted page built as System Settings builds it on macOS 27.2:
    /// the lines inside an outline, and beside it the sidebar, an outline
    /// too, which is the one System Settings names.
    private static func outlined(_ names: [String])
        -> (window: MockElement, sidebar: MockElement, list: MockElement, lines: [(line: MockElement, label: MockElement, toggle: MockElement)]) {
        let page = scripted(names)
        let list = MockElement(kAXOutlineRole, frame: visible, children: page.lines.map(\.line))
        page.scroll.children = [list]
        let sidebar = MockElement(kAXOutlineRole, frame: CGRect(x: 100, y: 120, width: 140, height: 400),
                                  children: [MockElement(kAXRowRole, frame: CGRect(x: 100, y: 120, width: 140, height: 28))])
        sidebar.identifier = "com.apple.settings.sidebar.collectionView"
        page.window.children.insert(sidebar, at: 0)
        return (page.window, sidebar, list, page.lines)
    }

    private static func gone() -> MockElement {
        let element = MockElement(kAXCellRole, frame: nil)
        element.gone = true
        return element
    }

    private static let line1Row = SettingsListReading.row(toggle: CGRect(x: 640, y: 254, width: 32, height: 19),
                                                          label: CGRect(x: 260, y: 256, width: 46, height: 16))

    @Test func aSidebarCellThatIsNotThereIsPassedOver() {
        // System Settings' sidebar lists cells that answer "no such
        // element". They are not lines, and the page is still read whole.
        let page = Self.outlined(["Notes", "Intention", "Zoom"])
        #expect(Self.read(page.window) == Self.line1Row)
        page.sidebar.children[0].children = [Self.gone()]
        #expect(Self.read(page.window) == Self.line1Row)
        // One that is there and does not answer in time still cuts the read short.
        page.sidebar.children[0].children[0].gone = false
        page.sidebar.children[0].children[0].unanswered = true
        #expect(Self.read(page.window) == .incomplete)
    }

    @Test func onlyTheNamedSidebarIsPassedOver() {
        // The same missing cell in an outline System Settings does not name
        // as its sidebar, or names something else, cuts the read short: it
        // could be a second list of apps.
        // Only the whole identifier counts: not part of it, not one that
        // contains it, and not a different case.
        for name in [nil, "com.apple.settings.other", "Sidebar", "com.apple.settings.sidebar", "sidebar",
                     "com.apple.settings.sidebar.collectionView.cell", "com.apple.settings.Sidebar.collectionView"] {
            let page = Self.outlined(["Notes", "Intention", "Zoom"])
            page.sidebar.identifier = name
            page.sidebar.children[0].children = [Self.gone()]
            #expect(Self.read(page.window) == .incomplete, "\(name ?? "no name")")
        }
        // Being described as the sidebar is not being named as it.
        let described = Self.outlined(["Notes", "Intention", "Zoom"])
        described.sidebar.identifier = nil
        described.sidebar.summary = "Sidebar"
        described.sidebar.children[0].children = [Self.gone()]
        #expect(Self.read(described.window) == .incomplete)
        // And a sidebar whose name fails to answer is not taken for one.
        let page = Self.outlined(["Notes", "Intention", "Zoom"])
        page.sidebar.failing[kAXIdentifierAttribute] = .cannotComplete
        #expect(Self.read(page.window) == Self.line1Row)
        page.sidebar.children[0].children = [Self.gone()]
        #expect(Self.read(page.window) == .incomplete)
    }

    @Test func aLineOfTheListThatIsNotThereCutsTheReadShort() {
        // Two lines named Intention, the first off and the second on. The
        // second is replaced while the read runs: its parent still lists
        // the old row, which answers that it is not there, and the row now
        // in its place goes unread. One readable line named Intention is not
        // proof that there is only one.
        let page = Self.outlined(["Notes", "Intention", "Zoom", "Intention"])
        page.lines[3].toggle.isOn = 1
        #expect(Self.read(page.window) == .ambiguous)
        page.lines[3].line.gone = true
        #expect(Self.read(page.window) == .incomplete)
        // The same for a missing cell inside a line.
        let cell = Self.outlined(["Notes", "Intention", "Zoom"])
        cell.lines[2].line.children.append(Self.gone())
        #expect(Self.read(cell.window) == .incomplete)
    }

    @Test func aMissingLineInAListOfItsOwnCutsTheReadShort() {
        // The second line named Intention sits in an outline nested in the
        // first line's list, and in a list beside it, and is not there.
        // Neither list holds a switch that was read, and neither is the
        // sidebar.
        let nested = Self.outlined(["Notes", "Intention", "Zoom"])
        nested.list.children.append(MockElement(kAXOutlineRole, frame: CGRect(x: 240, y: 332, width: 560, height: 44),
                                                children: [Self.gone()]))
        #expect(Self.read(nested.window) == .incomplete)
        let beside = Self.outlined(["Notes", "Intention", "Zoom"])
        beside.window.children.append(MockElement(kAXOutlineRole, frame: CGRect(x: 240, y: 560, width: 560, height: 44),
                                                  children: [Self.gone()]))
        #expect(Self.read(beside.window) == .incomplete)
    }

    @Test func anElementThatIsNotThereOutsideAnyListCutsTheReadShort() {
        let page = Self.outlined(["Notes", "Intention", "Zoom"])
        page.window.children.append(Self.gone())
        #expect(Self.read(page.window) == .incomplete)
    }

    @Test func whatAnElementLacksIsNotAFailure() {
        // A label with no text and switches with no title, as most are.
        let list = Self.scripted(["Notes", "Intention", "Zoom"])
        list.lines[0].label.text = nil
        list.lines[2].label.failing[kAXValueAttribute] = .attributeUnsupported
        #expect(Self.read(list.window) == .row(toggle: CGRect(x: 640, y: 254, width: 32, height: 19),
                                               label: CGRect(x: 260, y: 256, width: 46, height: 16)))
    }

    /// A Settings window scripted like the frames above, titled `title`:
    /// one line per name, each a row holding the name's label and a switch
    /// that is off, inside a scroll area showing `visible`.
    private static func scripted(_ names: [String], title: String? = screenRecordingTitle)
        -> (window: MockElement, scroll: MockElement, lines: [(line: MockElement, label: MockElement, toggle: MockElement)]) {
        let lines = names.enumerated().map { index, name in
            let label = MockElement(kAXStaticTextRole, frame: Self.label(line: index).frame, text: name)
            let toggle = MockElement(kAXCheckBoxRole, frame: Self.switchFrame(line: index), isOn: 0)
            let line = MockElement(kAXRowRole, frame: CGRect(x: 240, y: 200 + CGFloat(index) * 44, width: 560, height: 44),
                                   children: [label, toggle])
            return (line: line, label: label, toggle: toggle)
        }
        let scroll = MockElement(kAXScrollAreaRole, frame: visible, children: lines.map(\.line))
        return (MockElement(kAXWindowRole, frame: window, children: [scroll], title: title), scroll, lines)
    }

    // MARK: Where it draws (AppKit screen coordinates from here on)

    private static let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)

    @Test func theNoteSitsUnderTheWindowAlignedWithItsSwitches() {
        let window = CGRect(x: 300, y: 200, width: 715, height: 500)
        let panel = SettingsGuideLayout.listPanel(window: window, screen: Self.screen)
        #expect(panel.maxY <= window.minY)
        // The arrow, 38 points in from the note's right edge, is then 48
        // points inside the window's: the middle of a 36 point switch that
        // ends 30 points inside it.
        #expect(panel.maxX == window.maxX - 10)
    }

    @Test func theNoteMovesInsideAWindowThatReachesTheFootOfTheScreen() {
        let window = CGRect(x: 300, y: 20, width: 715, height: 700)
        let panel = SettingsGuideLayout.listPanel(window: window, screen: Self.screen)
        #expect(window.contains(panel))
    }

    @Test func theRingSurroundsTheSwitchAndTheNoteStandsRightOfTheWindow() {
        let window = CGRect(x: 300, y: 200, width: 715, height: 500)
        let toggle = CGRect(x: 950, y: 480, width: 32, height: 19)
        let row = SettingsGuideLayout.row(toggle: toggle, window: window, screen: Self.screen)
        let ring = Self.onScreen(row.ring, in: row.panel)
        #expect(ring.contains(toggle))
        #expect(ring.width < toggle.width + 20)
        let callout = Self.onScreen(row.callout, in: row.panel)
        #expect(callout.minX > window.maxX)
        #expect(Self.screen.contains(row.panel))
        // The arrow ends just past the ring, level with the switch.
        let tip = Self.onScreen(row.arrowTo, in: row.panel)
        #expect(tip.x > ring.maxX && tip.x < ring.maxX + 10)
        #expect(tip.y == toggle.midY)
    }

    @Test func atTheScreensRightEdgeTheNoteGoesUnderTheLineWithoutCoveringIt() {
        let window = CGRect(x: 720, y: 200, width: 715, height: 500)
        let toggle = CGRect(x: window.maxX - 66, y: 560, width: 32, height: 19)
        let row = SettingsGuideLayout.row(toggle: toggle, window: window, screen: Self.screen)
        let ring = Self.onScreen(row.ring, in: row.panel)
        let callout = Self.onScreen(row.callout, in: row.panel)
        #expect(callout.maxY < ring.minY)
        #expect(window.contains(callout))
        #expect(Self.screen.contains(row.panel))
        let tip = Self.onScreen(row.arrowTo, in: row.panel)
        #expect(tip.x == toggle.midX && tip.y < ring.minY)
    }

    @Test func nearTheWindowsFootTheNoteGoesAboveTheLine() {
        let window = CGRect(x: 720, y: 200, width: 715, height: 500)
        let toggle = CGRect(x: window.maxX - 66, y: 230, width: 32, height: 19)
        let row = SettingsGuideLayout.row(toggle: toggle, window: window, screen: Self.screen)
        let ring = Self.onScreen(row.ring, in: row.panel)
        let callout = Self.onScreen(row.callout, in: row.panel)
        #expect(callout.minY > ring.maxY)
        #expect(!callout.intersects(ring))
    }

    /// Turns a frame measured from the panel's top left back into screen
    /// coordinates.
    private static func onScreen(_ rect: CGRect, in panel: CGRect) -> CGRect {
        CGRect(x: panel.minX + rect.minX, y: panel.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func onScreen(_ point: CGPoint, in panel: CGRect) -> CGPoint {
        CGPoint(x: panel.minX + point.x, y: panel.maxY - point.y)
    }
}
