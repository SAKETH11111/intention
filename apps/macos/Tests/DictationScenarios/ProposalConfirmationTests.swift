import AppKit
@testable import Dictation
import Testing

extension DictationScenarioTests {
    private func body(_ text: String, at caret: Int? = nil) {
        MockField.shared.text = text
        MockField.shared.selection = FieldRange(location: caret ?? text.utf16.count, length: 0)
    }

    private func selectReply(_ p: Proposals) async throws {
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { p.card.confirmingReplacement }
    }

    @Test(arguments: ["unchanged", "selection", "body"])
    func aLongReplyConfirmsWithoutItsFirstLineButRequiresTheExactSelection(change: String) async throws {
        let (p, outcomes) = await shownProposal()
        let typed = String(repeating: "A long reply paragraph.\n", count: 40)
        body(typed)
        MockField.shared.scrollArea = CGRect(x: 0, y: 150, width: 1440, height: 710)
        p.controller.observe(p.observation(edit: 1))
        try await selectReply(p)
        #expect(MockField.shared.selection == FieldRange(location: 0, length: typed.utf16.count))
        let snapshots = p.reader.snapshotsCompleted
        p.controller.observe(p.unplaced(edit: 2))
        await until { p.reader.snapshotsCompleted > snapshots }
        try await Task.sleep(for: .milliseconds(20))
        #expect(p.card.confirmingReplacement)
        #expect(p.tab != nil)
        // Change without a tracker notice, so second Tab must reread it.
        if change == "selection" { MockField.shared.selection = FieldRange(location: 0, length: 2) }
        if change == "body" { MockField.shared.text = typed.replacingOccurrences(of: "long", with: "tall") }
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { outcomes.list == [.inserted] || !outcomes.refused.isEmpty }
        if change == "unchanged" {
            #expect(outcomes.list == [.inserted])
            #expect(outcomes.refused.isEmpty)
            #expect(MockField.shared.text == proposalDraft)
            #expect(p.route.accepted.count == 1)
        } else {
            #expect(outcomes.list.isEmpty)
            #expect(!outcomes.refused.isEmpty)
            #expect(p.route.accepted.isEmpty)
            #expect(MockField.shared.text != proposalDraft)
        }
        p.controller.reset()
    }

    @Test func accessibilityAcceptRecognizesItsOwnSelectionNotice() async throws {
        let (p, outcomes) = await shownProposal()
        body("My reply\n", at: 3)
        let reads = p.reader.bodyReads
        p.reader.beforeAnswer = { number in
            guard number == reads + 2 else { return }
            p.controller.observe(p.observation(edit: 1))
        }
        p.card.accepted()
        await until { p.card.confirmingReplacement }
        p.card.accepted()
        await until { outcomes.list == [.inserted] || !outcomes.refused.isEmpty }
        #expect(outcomes.list == [.inserted])
        #expect(outcomes.refused.isEmpty)
        #expect(MockField.shared.text == proposalDraft)
    }

    @Test func theSameAccessibilityElementSelectsThenInsertsTheDraft() async throws {
        let card = ProposalCard(screenEvents: NotificationCenter(), workspaceEvents: NotificationCenter())
        card.showsWindow = false
        card.reduceMotion = { true }
        let p = await proposals(nil, route: ScriptedRoute(text: proposalDraft), presenter: card)
        let outcomes = Outcomes()
        p.controller.ended = { outcome, _ in outcomes.list.append(outcome) }
        p.controller.observe(p.observation())
        await until { card.isShown }
        body("My reply\n", at: 3)
        let button = try #require(card.target.contentView?.accessibilityChildren()?
            .compactMap { $0 as? NSAccessibilityElement }.first { $0.accessibilityRole() == .button })
        #expect(button.accessibilityPerformPress())
        await until { card.confirmingReplacement }
        #expect(MockField.shared.text == "My reply\n")
        #expect(p.route.accepted.isEmpty)
        #expect(button.accessibilityPerformPress())
        await until { outcomes.list == [.inserted] }
        #expect(MockField.shared.text == proposalDraft)
        #expect(p.route.accepted.count == 1)
    }

    @Test func typingInAnotherFieldKeepsTheHiddenReplyForReturn() async throws {
        let (p, outcomes) = await shownProposal()
        p.focusSearch(focus: 2)
        let reads = p.reader.bodyReads
        await p.pressKey()
        #expect(p.reader.bodyReads == reads)
        p.focusReply(focus: 3)
        await until { p.card.isShown }
        #expect(p.route.created.count == 1)
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { outcomes.list == [.inserted] }
    }

    @Test func typingBeforeATrailingLayoutBreakKeepsTheProposal() async throws {
        let (p, outcomes) = await shownProposal(configure: { $0.blocks = true })
        MockField.shared.text = "ab\n\ncd\nef\n"
        MockField.shared.selection = FieldRange(location: 7, length: 0)
        p.controller.observe(p.observation(edit: 1))
        await p.pressKey()
        MockField.shared.text = "ab\n\ncd\nefg\n"
        MockField.shared.selection = FieldRange(location: 8, length: 0)
        p.controller.observe(p.observation(edit: 2))
        #expect(p.card.isShown)
        try await selectReply(p)
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { outcomes.list == [.inserted] }
        #expect(MockField.shared.text == proposalDraft)
    }

    @Test(arguments: [false, true])
    func twoTabsConfirmTheWholeBodyIncludingClipboardFallback(paste: Bool) async throws {
        let (p, outcomes) = await shownProposal(configure: { if paste { $0.settable = false } })
        body("Hello Priya\n", at: 4)
        p.controller.observe(p.observation(edit: 1))
        try await selectReply(p)
        #expect(MockField.shared.text == "Hello Priya\n")
        #expect(MockField.shared.selection == FieldRange(location: 0, length: 12))
        #expect(p.route.accepted.isEmpty)
        #expect(outcomes.list.isEmpty)
        var acceptingReads = 0
        var fieldAtHide: [String] = []
        p.card.hiding = { fieldAtHide.append(MockField.shared.text) }
        p.reader.beforeAnswer = { _ in
            guard p.controller.isAccepting else { return }
            acceptingReads += 1
            #expect(p.card.isShown)
            #expect(!p.card.acceptsInput)
            #expect(MockField.shared.text == "Hello Priya\n")
        }
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { outcomes.list == [.inserted] }
        #expect(MockField.shared.text == "Hey Priya, Harbor Hall fits what we need. Can you ask what they'd charge?")
        #expect(p.route.accepted.count == 1)
        #expect(acceptingReads > 0)
        #expect(!p.card.isShown)
        #expect(fieldAtHide == [proposalDraft])
    }

    @Test(arguments: [false, true])
    func emptyBodyUsesOneTabIncludingClipboardFallback(paste: Bool) async throws {
        let (p, outcomes) = await shownProposal(configure: { if paste { $0.settable = false } })
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { outcomes.list == [.inserted] }
        #expect(MockField.shared.text == "Hey Priya, Harbor Hall fits what we need. Can you ask what they'd charge?\n")
        #expect(!p.card.confirmingReplacement)
    }

    @Test(arguments: ["typing", "editor", "paste", "selection", "collapse", "click"])
    func changesCancelVisibleReplacementConsent(change: String) async throws {
        let (p, outcomes) = await shownProposal()
        body("My reply\n")
        try await selectReply(p)
        switch change {
        case "typing": await p.pressKey(); body("My reply!\n")
        case "editor": body("My corrected reply\n")
        case "paste": body("Pasted reply\n")
        case "selection": MockField.shared.selection = FieldRange(location: 0, length: 2)
        case "collapse": MockField.shared.selection = FieldRange(location: 3, length: 0)
        case "click": p.hold.received(.init(kind: .mouseDown))
        default: Issue.record("Unexpected change")
        }
        p.controller.observe(p.observation(edit: 1))
        await until { !p.card.confirmingReplacement }
        #expect(p.card.isShown)
        #expect(outcomes.list.isEmpty)
        #expect(p.route.accepted.isEmpty)
        let expected = ["typing": "My reply!\n", "editor": "My corrected reply\n", "paste": "Pasted reply\n"]
        #expect(MockField.shared.text == expected[change, default: "My reply\n"])
        if change == "click" { #expect(MockField.shared.selection == FieldRange(location: 0, length: 9)) }
        if change == "collapse" { #expect(MockField.shared.selection == FieldRange(location: 3, length: 0)) }
    }

    @Test(arguments: ["body", "selection", "thread", "element"], ["tab", "accessibility"])
    func unreportedChangeBetweenConfirmationPressesRefusesWithoutReplacing(change: String, way: String) async throws {
        let (p, outcomes) = await shownProposal()
        body("My reply\n")
        try await selectReply(p)
        switch change {
        case "body": MockField.shared.text = "My paste\n" // same length and whole selection
        case "selection": MockField.shared.selection = FieldRange(location: 3, length: 0)
        case "thread": p.reader.threadID = "18c2f4a9d0e1b3ff"
        case "element": MockField.shared.focusedElement = 2
        default: Issue.record("Unexpected change")
        }
        if way == "accessibility" { p.card.accepted() }
        else { p.controller.tabTaken(generation: try #require(p.tab)) }
        await until { !p.controller.isAccepting }
        #expect(!p.card.confirmingReplacement)
        #expect(MockField.shared.text == (change == "body" ? "My paste\n" : "My reply\n"))
        #expect(p.route.accepted.isEmpty)
        #expect(outcomes.list.isEmpty)
    }

    @Test func escapeDismissesWithoutRestoringTheSelection() async throws {
        let (p, outcomes) = await shownProposal()
        body("My reply\n")
        try await selectReply(p)
        p.pressEscape()
        #expect(outcomes.list == [.dismissed])
        #expect(!p.card.isShown)
        #expect(MockField.shared.text == "My reply\n")
        #expect(MockField.shared.selection == FieldRange(location: 0, length: 9))
    }

    @Test func heldAndQueuedTabsCannotSkipConfirmationOrReachTheEditor() async throws {
        let (p, outcomes) = await shownProposal()
        body("My reply\n")
        let generation = try #require(p.tab)
        var tabs = TakenTabs()
        tabs.generation = generation
        func send(_ down: Bool, repeatKey: Bool = false) {
            let result = tabs.decide(down ? .keyDown(keyCode: 48, flags: 0, isRepeat: repeatKey) : .keyUp(keyCode: 48))
            #expect(result.drops)
            p.hold.tapInput(.init(kind: down ? .keyDown : .keyUp, keyCode: 48, isRepeat: repeatKey, proposalTab: result.drops), tabTaken: result.taken)
        }
        send(true)
        for _ in 0..<5 { send(true, repeatKey: true) }
        // A duplicate delivery while the selection read is pending is ignored too.
        p.controller.tabTaken(generation: generation)
        await until { p.card.confirmingReplacement }
        #expect(MockField.shared.text == "My reply\n")
        #expect(outcomes.list.isEmpty)
        #expect(p.route.accepted.isEmpty)
        for _ in 0..<5 { send(true, repeatKey: true) }
        #expect(p.card.confirmingReplacement)
        send(false)
        send(true)
        send(false)
        await until { outcomes.list == [.inserted] }
    }

    @Test(arguments: [0, 3, 8])
    func editsAnywhereKeepTheCardWithoutAttribution(caret: Int) async throws {
        let (p, outcomes) = await shownProposal()
        body("My reply\n", at: caret)
        p.controller.observe(p.observation(edit: 1))
        await p.pressKey()
        body("Edited reply\n", at: caret)
        p.controller.observe(p.observation(edit: 2))
        #expect(p.card.isShown)
        #expect(outcomes.list.isEmpty)
        try await selectReply(p)
        #expect(MockField.shared.text == "Edited reply\n")
    }
    /// Where a reply body sits for a confirmation, in Accessibility
    /// coordinates on the scripted 1440 by 900 screen, whose visible frame
    /// ends 40 points above its foot, and whether Accessibility gives the
    /// selection's bounds.
    struct BodySpot: Sendable, CustomTestStringConvertible {
        let name: String
        let top: CGFloat
        let height: CGFloat
        let selectionBounds: Bool
        var testDescription: String { name }
    }

    nonisolated static let bodySpots = [
        BodySpot(name: "top", top: 90, height: 180, selectionBounds: true),
        BodySpot(name: "middle", top: 300, height: 180, selectionBounds: true),
        BodySpot(name: "bottom", top: 640, height: 180, selectionBounds: true),
        BodySpot(name: "long", top: 300, height: 2000, selectionBounds: true),
        BodySpot(name: "no selection bounds", top: 300, height: 180, selectionBounds: false),
    ]

    /// The card leaves the selection in view while the second Tab waits,
    /// moving takes nothing from the confirmation, and the second Tab
    /// still replaces the selection.
    @Test(arguments: bodySpots)
    func theConfirmingCardLeavesTheSelectionInView(spot: BodySpot) async throws {
        let card = ProposalCard(screenEvents: NotificationCenter(), workspaceEvents: NotificationCenter())
        card.showsWindow = false
        card.reduceMotion = { true }
        let p = await proposals(nil, route: ScriptedRoute(text: proposalDraft), presenter: card) {
            $0.frameWidth = 640
            $0.frameHeight = 180
            $0.fieldTop = 280
        }
        let outcomes = Outcomes()
        p.controller.ended = { outcome, _ in outcomes.list.append(outcome) }
        p.controller.notInserted = { outcomes.refused.append(($0, $1)) }
        p.controller.observe(p.observation())
        await until { card.isShown }
        let atCaret = try #require(card.frame)
        let typed = "Sounds good, I'll check with the team\n"
        body(typed)
        // The body moves where the scenario puts it, as Gmail lays a
        // reply out, and the selection's lines, 20 points in from each
        // side and 10 from the top, when Accessibility gives them.
        MockField.shared.fieldTop = spot.top
        MockField.shared.frameHeight = spot.height
        let bodyFrame = CGRect(x: 100, y: spot.top, width: 640, height: spot.height)
        let bounds = CGRect(x: 120, y: spot.top + 10, width: 600, height: spot.height - 20)
        MockField.shared.rangeBounds = spot.selectionBounds ? bounds : nil
        p.controller.observe(p.observation(edit: 1))
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { card.confirmingReplacement }
        // As the tracker reports a whole-body selection: no caret.
        p.controller.observe(p.unplaced(edit: 2))
        try await Task.sleep(for: .milliseconds(20))
        #expect(MockField.shared.rangeBoundsReads > 0)

        // The selection in AppKit coordinates, cut to the scroll area
        // (Accessibility y 80 to 860) and the window (25 to 900).
        let selected = (spot.selectionBounds ? bounds : bodyFrame).intersection(CGRect(x: 0, y: 80, width: 1440, height: 780))
        let shown = CGRect(x: selected.minX, y: 900 - selected.maxY, width: selected.width, height: selected.height)
        let frame = try #require(card.frame)
        #expect(!frame.intersects(shown))
        #expect(CGRect(x: 0, y: 0, width: 1440, height: 860).contains(frame))
        if spot.height < 1000 {
            #expect(!frame.intersects(CGRect(x: 100, y: 900 - spot.top - spot.height, width: 640, height: spot.height)))
        }
        #expect(frame != atCaret)

        // Nothing was taken from the confirmation by the move.
        #expect(card.confirmingReplacement)
        #expect(card.current?.keys == "Tab again to replace what's selected")
        #expect(MockField.shared.selection == FieldRange(location: 0, length: typed.utf16.count))
        #expect(p.tab != nil)
        #expect(outcomes.list.isEmpty)
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { outcomes.list == [.inserted] }
        #expect(MockField.shared.text == proposalDraft)
        #expect(outcomes.refused.isEmpty)
    }

    @Test(arguments: [false, true])
    func noRoomEndsConfirmationWithoutChangingTheSelection(selectionBounds: Bool) async throws {
        let card = ProposalCard(screenEvents: NotificationCenter(), workspaceEvents: NotificationCenter())
        card.showsWindow = false
        card.reduceMotion = { true }
        let p = await proposals(nil, route: ScriptedRoute(text: proposalDraft), presenter: card) {
            // Every visible point to the right of x 100 is selected. The
            // remaining strip is narrower than any readable card.
            $0.frameWidth = 1340
            $0.frameHeight = 860
            $0.fieldTop = 40
            $0.scrollArea = CGRect(x: 0, y: 40, width: 1440, height: 860)
            $0.windowFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
            $0.rangeBounds = selectionBounds ? CGRect(x: 100, y: 40, width: 1340, height: 860) : nil
        }
        let outcomes = Outcomes()
        p.controller.ended = { outcome, _ in outcomes.list.append(outcome) }
        p.controller.notInserted = { outcomes.refused.append(($0, $1)) }
        p.controller.observe(p.observation())
        await until { card.isShown }
        let atCaret = try #require(card.frame)
        let typed = "My whole reply stays selected\n"
        body(typed, at: 3)
        p.controller.observe(p.observation(edit: 1))
        let firstTab = try #require(p.tab)
        let takenBefore = p.taken.value.count
        p.controller.tabTaken(generation: firstTab)
        await until { p.taken.value.count > takenBefore }
        #expect(p.taken.value[takenBefore] == nil)
        #expect(!card.confirmingReplacement)
        #expect(card.keepClear == nil)
        #expect(card.current?.keys == "Tab to use this hold fn and say what to change or type your own")
        #expect(card.frame == atCaret)
        #expect(p.controller.isShown)
        #expect(MockField.shared.selection == FieldRange(location: 0, length: typed.utf16.count))
        #expect(MockField.shared.text == typed)
        #expect(MockField.shared.keys.isEmpty)
        #expect(p.route.accepted.isEmpty)
        #expect(outcomes.list.isEmpty && outcomes.refused.isEmpty)

        let nextTab = try #require(p.tab)
        #expect(nextTab != firstTab)
        let reads = p.reader.bodyReads
        // A second press already queued for the ended confirmation is inert.
        p.controller.tabTaken(generation: firstTab)
        #expect(p.reader.bodyReads == reads)
        #expect(p.route.accepted.isEmpty)
        // A fresh Tab retries placement. Still no room, still no replacement.
        p.controller.tabTaken(generation: nextTab)
        await until { p.tab != nextTab }
        #expect(!card.confirmingReplacement)
        #expect(card.frame == atCaret)
        #expect(MockField.shared.text == typed)
        #expect(MockField.shared.selection == FieldRange(location: 0, length: typed.utf16.count))
        #expect(p.route.accepted.isEmpty)

        // Once the body has room again, one new press only confirms. The
        // following press is required to replace the still-selected body.
        MockField.shared.fieldTop = 280
        MockField.shared.frameHeight = 180
        MockField.shared.frameWidth = 640
        MockField.shared.rangeBounds = selectionBounds ? CGRect(x: 120, y: 290, width: 600, height: 160) : nil
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { card.confirmingReplacement }
        #expect(MockField.shared.text == typed)
        #expect(p.route.accepted.isEmpty)
        let confirming = try #require(card.frame)
        #expect(!confirming.intersects(CGRect(x: 100, y: 440, width: 640, height: 180)))
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { outcomes.list == [.inserted] }
        #expect(MockField.shared.text == proposalDraft)
        #expect(p.route.accepted.count == 1)
        #expect(outcomes.refused.isEmpty)
        p.controller.reset()
    }

    /// Typing cancels the confirmation as before, and the card goes back
    /// to its place at the caret.
    @Test func typingDuringConfirmationReturnsTheCardToItsPlace() async throws {
        let card = ProposalCard(screenEvents: NotificationCenter(), workspaceEvents: NotificationCenter())
        card.showsWindow = false
        card.reduceMotion = { true }
        let p = await proposals(nil, route: ScriptedRoute(text: proposalDraft), presenter: card) {
            $0.frameWidth = 640
            $0.frameHeight = 180
            $0.fieldTop = 280
        }
        p.controller.observe(p.observation())
        await until { card.isShown }
        let atCaret = try #require(card.frame)
        body("My reply\n", at: 3)
        p.controller.observe(p.observation(edit: 1))
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { card.confirmingReplacement }
        #expect(card.frame != atCaret)
        await p.pressKey()
        #expect(!card.confirmingReplacement)
        #expect(card.keepClear == nil)
        #expect(card.frame == atCaret)
        #expect(MockField.shared.selection == FieldRange(location: 0, length: 9))
    }

    @Test func scrollingEndsConfirmationAndTheNextTabOnlySelects() async throws {
        let (p, card, outcomes) = try await realCardProposal()
        let typed = "My reply\n"
        body(typed, at: 3)
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { card.confirmingReplacement }
        let confirmationTab = try #require(p.tab)
        let takenBefore = p.taken.value.count
        let oldFrame = try #require(card.frame)
        // The selected body scrolls into the card's former screen position.
        let scrolled = CGRect(x: oldFrame.minX, y: 900 - oldFrame.maxY,
                              width: oldFrame.width, height: oldFrame.height)
        MockField.shared.fieldTop = scrolled.minY
        MockField.shared.rangeBounds = scrolled
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                        wheelCount: 1, wheel1: 100, wheel2: 0, wheel3: 0))
        let scroll = try #require(NSEvent(cgEvent: event))
        // Exercise the same conversion and background delivery as the event tap.
        if let input = HoldKey.Monitored(scroll) {
            await Self.offMain { p.hold.tapInput(input, tabTaken: nil) }
        }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(!card.confirmingReplacement)
        #expect(card.keepClear == nil)
        #expect(p.taken.value.dropFirst(takenBefore).contains { $0 == nil })
        #expect(p.tab != confirmationTab)
        #expect(MockField.shared.text == typed)
        #expect(MockField.shared.selection == FieldRange(location: 0, length: typed.utf16.count))
        // An already queued second Tab cannot replace, and a fresh Tab only selects.
        p.controller.tabTaken(generation: confirmationTab)
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { card.confirmingReplacement }
        #expect(MockField.shared.text == typed)
        #expect(p.route.accepted.isEmpty)
        #expect(outcomes.list.isEmpty && outcomes.refused.isEmpty)
        p.controller.reset()
    }

    @Test(arguments: [false, true])
    func aFreshTabStartsConfirmationWhileARetiredSelectionCheckWaits(staleGeometry: Bool) async throws {
        let (p, card, outcomes) = try await realCardProposal()
        body("My reply\n", at: 3)
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { card.confirmingReplacement }
        let oldTab = try #require(p.tab)
        let bounds = MockField.shared.rangeBounds
        if staleGeometry { MockField.shared.rangeBounds = CGRect(x: 100, y: 140, width: 90, height: 40) }
        let oldRead = p.reader.bodyReads + 1
        var releaseOld: CheckedContinuation<Void, Never>?
        p.reader.beforeAnswer = { number in
            guard number == oldRead else { return }
            await withCheckedContinuation { releaseOld = $0 }
        }
        p.controller.observe(p.observation(edit: 1))
        await until { releaseOld != nil }
        defer { releaseOld?.resume() }
        MockField.shared.rangeBounds = bounds

        p.hold.received(.init(kind: .scroll))
        #expect(!card.confirmingReplacement)
        let freshTab = try #require(p.tab)
        #expect(freshTab != oldTab)
        p.controller.tabTaken(generation: freshTab)
        await until { card.confirmingReplacement }
        #expect(card.confirmingReplacement)
        #expect(MockField.shared.selection == FieldRange(location: 0, length: 9))

        let frame = card.frame, clear = card.keepClear, tab = p.tab
        let snapshots = p.reader.snapshotsCompleted
        releaseOld?.resume()
        releaseOld = nil
        await until { p.reader.snapshotsCompleted > snapshots }
        // Let the controller consume the retired result, too.
        try await Task.sleep(for: .milliseconds(20))
        #expect(card.confirmingReplacement)
        #expect(card.frame == frame)
        #expect(card.keepClear == clear)
        #expect(p.tab == tab)
        #expect(MockField.shared.text == "My reply\n")
        #expect(MockField.shared.selection == FieldRange(location: 0, length: 9))
        #expect(outcomes.list.isEmpty && outcomes.refused.isEmpty)
        #expect(p.route.accepted.isEmpty)
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { outcomes.list == [.inserted] }
        #expect(MockField.shared.text == proposalDraft)
    }

    @Test func aRetiredCheckCannotReleaseTheNewConfirmationsPendingCheck() async throws {
        let (p, card, outcomes) = try await realCardProposal()
        body("My reply\n", at: 3)
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { card.confirmingReplacement }
        let oldRead = p.reader.bodyReads + 1
        var releaseOld: CheckedContinuation<Void, Never>?
        var releaseNew: CheckedContinuation<Void, Never>?
        p.reader.beforeAnswer = { number in
            guard number == oldRead else { return }
            await withCheckedContinuation { releaseOld = $0 }
        }
        p.controller.observe(p.observation(edit: 1))
        await until { releaseOld != nil }
        defer { releaseOld?.resume(); releaseNew?.resume() }
        p.hold.received(.init(kind: .scroll))
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { card.confirmingReplacement }
        let newRead = p.reader.bodyReads + 1
        p.reader.beforeAnswer = { number in
            guard number == newRead else { return }
            await withCheckedContinuation { releaseNew = $0 }
        }
        p.controller.observe(p.observation(edit: 2))
        await until { releaseNew != nil }
        let snapshots = p.reader.snapshotsCompleted
        releaseOld?.resume()
        releaseOld = nil
        await until { p.reader.snapshotsCompleted > snapshots }
        try await Task.sleep(for: .milliseconds(20))
        p.controller.tabTaken(generation: try #require(p.tab))
        #expect(!p.controller.isAccepting)
        #expect(card.confirmingReplacement)
        #expect(p.reader.bodyReads == newRead)
        #expect(p.route.accepted.isEmpty)
        releaseNew?.resume()
        releaseNew = nil
        await until { p.reader.snapshotsCompleted > snapshots + 1 }
        try await Task.sleep(for: .milliseconds(20))
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { outcomes.list == [.inserted] }
        #expect(MockField.shared.text == proposalDraft)
    }

    @Test(arguments: ["body", "layout"])
    func changedGeometryEndsConfirmationBeforeTheNextTab(change: String) async throws {
        let (p, card, _) = try await realCardProposal()
        body("My reply\n", at: 3)
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { card.confirmingReplacement }
        let oldTab = try #require(p.tab)
        if change == "body" {
            var moved = p.observation()
            moved.field?.origin.y += 100
            p.controller.observe(moved)
        } else {
            p.controller.confirmationGeometryChanged()
        }
        #expect(!card.confirmingReplacement)
        #expect(p.tab != oldTab)
        #expect(MockField.shared.selection == FieldRange(location: 0, length: 9))
        p.controller.tabTaken(generation: oldTab)
        #expect(p.route.accepted.isEmpty)
        #expect(MockField.shared.text == "My reply\n")
        p.controller.reset()
    }

    @Test func aSelectionFrameChangeInAnEditNoticeEndsConfirmation() async throws {
        let (p, card, _) = try await realCardProposal()
        body("My reply\n", at: 3)
        MockField.shared.rangeBounds = CGRect(x: 100, y: 100, width: 90, height: 40)
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { card.confirmingReplacement }
        let oldTab = try #require(p.tab)
        MockField.shared.rangeBounds = CGRect(x: 100, y: 140, width: 90, height: 40)
        p.controller.observe(p.observation(edit: 1))
        await until { !card.confirmingReplacement }
        #expect(p.tab != oldTab)
        #expect(MockField.shared.selection == FieldRange(location: 0, length: 9))
        p.controller.tabTaken(generation: oldTab)
        #expect(p.route.accepted.isEmpty)
        p.controller.reset()
    }

    @Test func aSlowOptionalSelectionBoundsReadDoesNotDelayConfirmation() async throws {
        let (p, card, _) = try await realCardProposal()
        body("My reply\n", at: 3)
        MockField.shared.rangeBoundsDelay = 1
        let start = ContinuousClock.now
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { card.confirmingReplacement }
        #expect(start.duration(to: .now) < .milliseconds(250))
        #expect(MockField.shared.rangeBoundsTimeouts == [0.1])
        #expect(card.keepClear?.body == card.keepClear?.selection)
        #expect(MockField.shared.text == "My reply\n")
        p.controller.reset()
    }

    private func realCardProposal() async throws -> (Proposals, ProposalCard, Outcomes) {
        let card = ProposalCard(screenEvents: NotificationCenter(), workspaceEvents: NotificationCenter())
        card.showsWindow = false
        card.reduceMotion = { true }
        let p = await proposals(nil, route: ScriptedRoute(text: proposalDraft), presenter: card)
        let outcomes = Outcomes()
        p.controller.ended = { outcome, _ in outcomes.list.append(outcome) }
        p.controller.notInserted = { outcomes.refused.append(($0, $1)) }
        p.controller.observe(p.observation())
        await until { card.isShown }
        return (p, card, outcomes)
    }

    private func accessibilityPress(_ card: ProposalCard) throws {
        let view = try #require(card.target.contentView)
        let button = try #require((view.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
            .first { $0.accessibilityRole() == .button })
        #expect(button.accessibilityPerformPress())
    }

    /// Deliver the actual AppKit card event and tap copy in either order.
    /// The tap is queued from a background thread, as in production.
    private func clickCard(_ p: Proposals, _ card: ProposalCard, count: Int, tapFirst: Bool) async throws {
        let view = try #require(card.target.contentView)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
            location: CGPoint(x: card.target.frame.width / 2, y: card.target.frame.height / 2),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: card.target.windowNumber,
            context: nil, eventNumber: count, clickCount: count, pressure: 1))
        let input = try #require(HoldKey.Monitored(event))
        if !tapFirst { view.mouseDown(with: event) }
        await Self.offMain { p.hold.tapInput(input, tabTaken: nil) }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        if tapFirst { view.mouseDown(with: event) }
    }

    @Test(arguments: [false, true])
    func cardClickCancelsConfirmationWithoutReplacing(tapFirst: Bool) async throws {
        let (p, card, outcomes) = try await realCardProposal()
        var accepts = 0
        let accessibilityAction = card.accepted
        card.accepted = { accepts += 1; accessibilityAction() }
        body("My reply\n", at: 3)
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { card.confirmingReplacement }
        try await clickCard(p, card, count: 1, tapFirst: tapFirst)
        #expect(!card.confirmingReplacement)
        #expect(card.current?.keys == "Tab to use this hold fn and say what to change or type your own")
        #expect(MockField.shared.text == "My reply\n")
        #expect(MockField.shared.selection == FieldRange(location: 0, length: 9))
        #expect(accepts == 0)
        #expect(p.route.accepted.isEmpty)
        #expect(outcomes.list.isEmpty)
        #expect(card.isShown)
    }

    @Test(arguments: [false, true])
    func cardClickWithoutConfirmationDoesNothingToEmptyOrTypedBody(nonempty: Bool) async throws {
        let (p, card, outcomes) = try await realCardProposal()
        var accepts = 0
        let accessibilityAction = card.accepted
        card.accepted = { accepts += 1; accessibilityAction() }
        if nonempty { body("My reply\n", at: 3) }
        let text = MockField.shared.text, selection = MockField.shared.selection
        try await clickCard(p, card, count: 1, tapFirst: true)
        #expect(MockField.shared.text == text)
        #expect(MockField.shared.selection == selection)
        #expect(!card.confirmingReplacement)
        #expect(accepts == 0)
        #expect(p.route.accepted.isEmpty)
        #expect(outcomes.list.isEmpty)
    }

    @Test(arguments: [false, true])
    func doubleClickOnCardReplacesNothing(tapFirst: Bool) async throws {
        let (p, card, outcomes) = try await realCardProposal()
        var accepts = 0
        let accessibilityAction = card.accepted
        card.accepted = { accepts += 1; accessibilityAction() }
        body("My reply\n")
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { card.confirmingReplacement }
        try await clickCard(p, card, count: 1, tapFirst: tapFirst)
        try await clickCard(p, card, count: 2, tapFirst: tapFirst)
        #expect(!card.confirmingReplacement)
        #expect(MockField.shared.text == "My reply\n")
        #expect(MockField.shared.selection == FieldRange(location: 0, length: 9))
        #expect(accepts == 0)
        #expect(p.route.accepted.isEmpty)
        #expect(outcomes.list.isEmpty)
    }

    @Test(arguments: [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown])
    func outsideCardClickCancelsAndLeavesTheSelection(type: NSEvent.EventType) async throws {
        let (p, outcomes) = await shownProposal()
        body("My reply\n")
        try await selectReply(p)
        let event = try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: 10, y: 10),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let input = try #require(HoldKey.Monitored(event))
        await Self.offMain { p.hold.tapInput(input, tabTaken: nil) }
        await until { !p.card.confirmingReplacement }
        #expect(MockField.shared.text == "My reply\n")
        #expect(MockField.shared.selection == FieldRange(location: 0, length: 9))
        #expect(p.route.accepted.isEmpty)
        #expect(outcomes.list.isEmpty)
    }

    @Test(arguments: [false, true], [false, true])
    func accessibilityPressUsesOneStageForEmptyAndTwoForTypedBody(nonempty: Bool, paste: Bool) async throws {
        let (p, card, outcomes) = try await realCardProposal()
        if paste { MockField.shared.settable = false }
        if nonempty { body("My reply\n", at: 3) }
        try accessibilityPress(card)
        if nonempty {
            await until { card.confirmingReplacement }
            #expect(card.current?.keys == "Tab again to replace what's selected")
            #expect(MockField.shared.text == "My reply\n")
            #expect(MockField.shared.selection == FieldRange(location: 0, length: 9))
            #expect(p.route.accepted.isEmpty)
            #expect(outcomes.list.isEmpty)
            try accessibilityPress(card)
        }
        await until { outcomes.list == [.inserted] || !outcomes.refused.isEmpty }
        #expect(outcomes.list == [.inserted])
        #expect(outcomes.refused.isEmpty)
        #expect(MockField.shared.text == proposalDraft + (nonempty ? "" : "\n"))
        #expect(p.route.accepted.count == 1)
    }

    @Test(arguments: [false, true])
    func voiceOverActivationKeyAndAXPressConfirmInEitherOrder(keyFirst: Bool) async throws {
        let (p, card, outcomes) = try await realCardProposal()
        p.controller.voiceOverEnabled = { true }
        body("My reply\n", at: 3)
        func key() async {
            await Self.offMain {
                p.hold.tapInput(.init(kind: .keyDown, keyCode: 49,
                    flags: NSEvent.ModifierFlags([.control, .option]).rawValue), tabTaken: nil)
            }
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
        if keyFirst { await key() }
        try accessibilityPress(card)
        if !keyFirst { await key() }
        await until { card.confirmingReplacement }
        #expect(MockField.shared.text == "My reply\n")
        #expect(p.route.accepted.isEmpty)
        p.route.hold(.accept)
        if keyFirst { await key() }
        try accessibilityPress(card)
        await p.route.whileHeld {
            if !keyFirst { await key() }
        }
        await until { outcomes.list == [.inserted] }
        #expect(MockField.shared.text == proposalDraft)
        #expect(outcomes.refused.isEmpty)
    }

    @Test(arguments: [false, true])
    func spaceWithoutVoiceOverActivationCancelsConsent(voiceOver: Bool) async throws {
        let (p, outcomes) = await shownProposal()
        p.controller.voiceOverEnabled = { voiceOver }
        body("My reply\n")
        try await selectReply(p)
        await p.pressKey(49, flags: voiceOver ? [] : [.control, .option])
        #expect(!p.card.confirmingReplacement)
        #expect(p.route.accepted.isEmpty)
        #expect(outcomes.list.isEmpty)
        #expect(MockField.shared.text == "My reply\n")
    }

    @Test func aDisabledTapCancelsConfirmationAndTheNextTabOnlySelects() async throws {
        let (p, outcomes) = await shownProposal()
        body("My reply\n")
        try await selectReply(p)
        await Self.offMain { p.hold.tapWasDisabled() }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(!p.card.confirmingReplacement)
        #expect(MockField.shared.selection == FieldRange(location: 0, length: 9))
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { p.card.confirmingReplacement || !outcomes.list.isEmpty }
        #expect(p.card.confirmingReplacement)
        #expect(MockField.shared.text == "My reply\n")
        #expect(p.route.accepted.isEmpty)
        #expect(outcomes.list.isEmpty)
    }

    @Test(arguments: [false, true])
    func mouseDownOrLostTapCancelsAcceptanceAfterTheCardHasHidden(lostTap: Bool) async throws {
        let (p, outcomes) = await shownProposal()
        body("My reply\n")
        try await selectReply(p)
        p.route.hold(.accept)
        p.controller.tabTaken(generation: try #require(p.tab))
        await p.route.whileHeld {
            await Self.offMain {
                if lostTap { p.hold.tapWasDisabled() }
                else { p.hold.tapInput(.init(kind: .mouseDown), tabTaken: nil) }
            }
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
        await until { !p.controller.isAccepting }
        #expect(MockField.shared.text == "My reply\n")
        #expect(MockField.shared.selection == FieldRange(location: 0, length: 9))
        #expect(outcomes.list.isEmpty)
        #expect(!outcomes.refused.isEmpty)
    }

    @Test(arguments: [false, true])
    func anEditWhileTheSecondTabWaitsForTheServerIsPreserved(paste: Bool) async throws {
        let (p, outcomes) = await shownProposal(configure: { if paste { $0.settable = false } })
        body("My reply\n")
        try await selectReply(p)
        p.route.hold(.accept)
        p.controller.tabTaken(generation: try #require(p.tab))
        await p.route.whileHeld {
            self.body("New text\n")
            p.controller.observe(p.observation(edit: 1))
        }
        await until { !p.controller.isAccepting }
        #expect(MockField.shared.text == "New text\n")
        #expect(!p.card.confirmingReplacement)
        #expect(outcomes.refused.count == 1)
    }

    @Test func typingWhileTheFirstSelectionReadWaitsCancelsItsWrite() async throws {
        let (p, outcomes) = await shownProposal()
        body("My reply\n")
        let reads = p.reader.bodyReads
        p.reader.beforeAnswer = { number in
            guard number == reads + 1 else { return }
            await p.pressKey()
            self.body("New text\n")
        }
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { p.reader.bodyReads > reads }
        try await Task.sleep(for: .milliseconds(40))
        #expect(!p.card.confirmingReplacement)
        #expect(MockField.shared.text == "New text\n")
        #expect(MockField.shared.selection == FieldRange(location: 9, length: 0))
        #expect(outcomes.list.isEmpty)
    }

    @Test(arguments: [false, true])
    func clickOrLostTapCancelsTabWaitingForGeometry(lostTap: Bool) async throws {
        let p = await proposals(nil, route: ScriptedRoute(text: proposalDraft))
        p.controller.observe(p.unplaced())
        await until { p.card.isShown }
        p.reader.holdingCandidates = true
        p.controller.observe(p.unplaced())
        await until { p.reader.heldCandidateCount == 1 }
        p.controller.tabTaken(generation: try #require(p.tab))
        if lostTap {
            await Self.offMain { p.hold.tapWasDisabled() }
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        } else {
            p.hold.received(.init(kind: .mouseDown))
        }
        p.reader.releaseCandidates()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(MockField.shared.text == "\n")
        #expect(p.route.accepted.isEmpty)
        #expect(!p.card.confirmingReplacement)
        #expect(p.card.isShown)
    }

    @Test func anExactBodyChangeAfterTheLastReplyReadStillRefuses() async throws {
        let (p, outcomes) = await shownProposal()
        body("My reply\n")
        try await selectReply(p)
        let reads = p.reader.bodyReads
        p.reader.beforeAnswer = { number in
            if number == reads + 2 { MockField.shared.text = "My reply\r" }
        }
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { !p.controller.isAccepting }
        #expect(MockField.shared.text == "My reply\r")
        #expect(!p.card.confirmingReplacement)
        #expect(outcomes.list.isEmpty)
    }

    @Test func selectionValidationReadsIndependentlyOfInsertion() async throws {
        let (p, _) = await shownProposal()
        body("My reply\n")
        try await selectReply(p)
        let unblock = DispatchSemaphore(value: 0)
        #expect(p.reader.inserter.submit { _ = unblock.wait(timeout: .now() + 3) })
        defer { unblock.signal() }
        MockField.shared.text = "My paste\n"
        p.controller.observe(p.observation(edit: 1))
        await until({ !p.card.confirmingReplacement }, within: .seconds(1))
        #expect(MockField.shared.text == "My paste\n")
        #expect(p.route.accepted.isEmpty)
    }

    @Test func overlappingSelectionChecksKeepTheFinalWriteClosedUntilAllFinish() {
        let latch = AcceptLatch()
        let check = ReplyProposalController.acceptCheck(latch: latch, deadline: .now + .seconds(5))
        latch.beginSelectionCheck()
        latch.beginSelectionCheck()
        #expect(check() == .composeChanged)
        latch.endSelectionCheck()
        #expect(check() == .composeChanged)
        latch.endSelectionCheck()
        #expect(check() == nil)
    }

}
