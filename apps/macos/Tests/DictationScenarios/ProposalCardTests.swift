import AppKit
@testable import Dictation
import SwiftUI
import Testing

/// The reply proposal's card placed at made-up carets on made-up screens,
/// pressed as VoiceOver would,
/// with its windows kept off screen. Every name and message is invented.
@MainActor
@Suite(.serialized)
struct ProposalCardTests {
    /// A laptop's visible frame below the menu bar and above a shown Dock.
    private static let laptop = CGRect(x: 0, y: 80, width: 1440, height: 795)
    private static let draft = """
        Hi Priya,

        Harbor Hall sounds right: a ten-minute walk for everyone and room for 40. What does it cost for the evening?

        Sam
        """

    private struct Lights {
        let screen = NotificationCenter()
        let workspace = NotificationCenter()
    }

    private func card(_ lights: Lights = Lights()) -> ProposalCard {
        let card = ProposalCard(screenEvents: lights.screen, workspaceEvents: lights.workspace)
        card.showsWindow = false
        card.reduceMotion = { true }
        return card
    }

    private func anchor(_ x: CGFloat, _ y: CGFloat, body: CGFloat = 640, screen: CGRect = laptop) -> ProposalCard.Anchor {
        ProposalCard.Anchor(textOrigin: CGPoint(x: x, y: y), bodyWidth: body, screen: screen)
    }

    /// Calls `body` on a background queue while the main thread waits for
    /// it, so a press it sends to the main queue has not run when this
    /// returns, and the check can change the card before it does.
    private static func offMainWhileMainWaits(_ body: @escaping @Sendable () -> Void) {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            body()
            done.signal()
        }
        done.wait()
    }

    /// Hands a value that is not `Sendable`, such as an accessibility
    /// element or an event, to a background queue, as AppKit holds one
    /// there.
    private final class Held<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private static func offMain(_ body: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                body()
                done.resume()
            }
        }
    }

    private func elements(_ card: ProposalCard) throws -> [NSAccessibilityElement] {
        let view = try #require(card.target.contentView)
        return (view.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
    }

    @Test func aShownCardChangesAppearanceWithoutMovingOrReplacingVoiceOverElements() async throws {
        let card = card()
        var look = Appearance.light
        card.appearance = { MainActor.assertIsolated(); return look }
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, 600)))
        card.confirmingReplacement = true
        card.acceptsInput = false
        let host = try #require(card.panel.contentView as? NSHostingView<ProposalCardView>)
        let elements = try elements(card)
        let targetFrame = card.target.frame
        let frame = card.panel.frame
        let measurements = card.measurements
        let placements = card.placements
        look = .dark
        await Self.offMain { card.appearanceChanged() }
        #expect(await eventually { host.rootView.appearance == .dark })
        #expect(card.panel.appearance?.name == .darkAqua)
        #expect(card.target.appearance?.name == .darkAqua)
        #expect(card.panel.contentView === host)
        #expect(!host.rootView.fades)
        #expect(host.rootView.confirmingReplacement)
        #expect(card.panel.frame == frame)
        #expect(card.target.frame == targetFrame)
        #expect(card.current?.text == Self.draft)
        #expect(card.confirmingReplacement)
        #expect(!card.acceptsInput)
        #expect(card.measurements == measurements)
        #expect(card.placements == placements)
        #expect(try self.elements(card).elementsEqual(elements, by: { $0 === $1 }))
        look = .light
        await AppearanceCallbackTests.postOffMain()
        #expect(host.rootView.appearance == .light)
        card.hide()
        await AppearanceCallbackTests.postOffMain()
        #expect(!card.holdsContent)
    }

    @Test func showingTheSameCardAfterDarkWasChosenDrawsItDarkWithoutANotice() throws {
        // The polish audit's probe: the same text, key and anchor shown again
        // after the appearance changed, with no notification in between,
        // must not keep the card in the old appearance; nor a moved one.
        let card = card()
        var look = Appearance.light
        card.appearance = { look }
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, 600)))
        let host = try #require(card.panel.contentView as? NSHostingView<ProposalCardView>)
        #expect(host.rootView.appearance == .light)
        let elements = try elements(card)
        let placements = card.placements
        look = .dark
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, 600)))
        #expect(host.rootView.appearance == .dark)
        #expect(card.panel.contentView === host)
        #expect(!host.rootView.fades)
        #expect(card.placements == placements)
        look = .light
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, 640)))
        #expect(host.rootView.appearance == .light)
        #expect(card.panel.contentView === host)
        #expect(try self.elements(card).elementsEqual(elements, by: { $0 === $1 }))
    }

    @Test func confirmationChangesOnlyTheExistingRowAndReturnsToNormal() throws {
        let card = card()
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, 600)))
        let normal = try #require(card.current).keys
        card.confirmingReplacement = true
        #expect(card.current?.text == Self.draft)
        #expect(card.current?.keys == "Tab again to replace what's selected")
        #expect(card.isShown)
        card.confirmingReplacement = false
        #expect(card.current?.keys == normal)
        #expect(card.current?.text == Self.draft)
    }

    @Test func voiceOverPressesTheSameButtonThroughConfirmation() throws {
        let card = card()
        var accepted = 0
        card.accepted = {
            accepted += 1
            card.confirmingReplacement = accepted == 1
        }
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, 600)))
        let button = try #require(elements(card).first { $0.accessibilityRole() == .button })
        #expect(button.accessibilityPerformPress())
        #expect(card.confirmingReplacement)
        #expect(button.accessibilityLabel() == "Tab again to replace what's selected")
        #expect(button.accessibilityHelp() == nil)
        #expect(try elements(card).contains { $0 === button })
        #expect(button.accessibilityPerformPress())
        #expect(accepted == 2)
        #expect(!card.confirmingReplacement)
        #expect(button.accessibilityLabel() == "Use this draft")
        #expect(button.accessibilityHelp() == "Tab to use this hold fn and say what to change or type your own")
        #expect(try elements(card).contains { $0 === button })
    }

    // MARK: - Placement

    @Test func aCardCoveringTheCaretHidesItsDotAndLeavingRestoresIt() throws {
        let card = card()
        let caret = CGRect(x: 500, y: 583, width: 1.5, height: 17)
        var dotShown = true
        var frames: [CGRect?] = []
        card.frameChanged = { sheet in
            frames.append(sheet)
            dotShown = !DotPlacement.caretCovered(caret, by: sheet)
        }
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, 600)))
        #expect(!dotShown)
        #expect(card.frame?.contains(caret) == true)
        // A card beside the caret leaves it visible, even while shown.
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(700, 600)))
        #expect(dotShown)
        #expect(card.isShown)
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, 600)))
        #expect(!dotShown)
        card.hide()
        #expect(dotShown)
        #expect(frames.count == 4)
        #expect(frames.last! == nil)
    }

    @Test func onlyTheVisibleSheetCoversTheCaretIncludingPartialOverlap() {
        let caret = CGRect(x: 500, y: 583, width: 1.5, height: 17)
        #expect(DotPlacement.caretCovered(caret, by: CGRect(x: 490, y: 590, width: 100, height: 50)))
        #expect(!DotPlacement.caretCovered(caret, by: CGRect(x: 502, y: 580, width: 100, height: 50)))
        #expect(!DotPlacement.caretCovered(caret, by: nil))
        // An above-caret placement's shadow can reach the caret without
        // its sheet covering it.
        #expect(!DotPlacement.caretCovered(caret, by: CGRect(x: 486, y: 606, width: 478, height: 100)))
    }

    /// Confirmation placement for a sheet 478 points wide at a 450-point
    /// column, 140 tall there and taller as its column narrows, around
    /// made-up bodies and selections. Every expected frame is written out:
    /// below the body its top is 8 points under the body's bottom edge,
    /// beside it 8 points from its side with the tops level, above it 8
    /// points over its top, and none touches the selection.
    @Test func aConfirmationKeepsTheCardOffTheSelectionWhereverTheBodyIs() throws {
        let height = { (column: CGFloat) in (140 * 450 / column).rounded(.up) }
        func place(body: CGRect, selection: CGRect? = nil, on screen: CGRect = Self.laptop) -> (sheet: CGRect, textWidth: CGFloat)? {
            ProposalCard.confirmationPlacement(textWidth: 450, keepClear: ProposalCard.KeepClear(body: body, selection: selection ?? body),
                                               screen: screen, height: height)
        }
        func check(_ body: CGRect, selection: CGRect? = nil, on screen: CGRect = Self.laptop, _ expected: CGRect, column: CGFloat = 450,
                   coversBody: Bool = false) throws {
            let placed = try #require(place(body: body, selection: selection, on: screen))
            #expect(placed.sheet == expected)
            #expect(placed.textWidth == column)
            #expect(!placed.sheet.intersects(selection ?? body))
            #expect(placed.sheet.intersects(body) == coversBody)
            #expect(screen.contains(placed.sheet))
        }
        // The laptop's visible frame runs from x 0 to 1440 and y 80 to 875.
        // A body near the top, its selection a part of it: below the body.
        try check(CGRect(x: 300, y: 700, width: 640, height: 120), selection: CGRect(x: 300, y: 760, width: 600, height: 60),
                  CGRect(x: 286, y: 552, width: 478, height: 140))
        // In the middle: below.
        try check(CGRect(x: 300, y: 400, width: 640, height: 200), CGRect(x: 286, y: 252, width: 478, height: 140))
        // At the foot with room to its right: beside, tops level.
        try check(CGRect(x: 300, y: 100, width: 640, height: 200), CGRect(x: 948, y: 160, width: 478, height: 140))
        // At the foot and nearly as wide as the screen: above.
        try check(CGRect(x: 100, y: 100, width: 1200, height: 200), CGRect(x: 86, y: 308, width: 478, height: 140))
        // A long body running off the screen's foot, its selection cut to
        // the scroll area: beside what shows of it.
        try check(CGRect(x: 300, y: -1500, width: 640, height: 2200), selection: CGRect(x: 300, y: 120, width: 640, height: 580),
                  CGRect(x: 948, y: 560, width: 478, height: 140))
        // A long body as wide as the page, from near the top past the
        // foot, its scroll area ending at y 300: nothing clears the whole
        // body, so the card goes under what shows of the selection, over
        // the page below its scroll area.
        try check(CGRect(x: 40, y: -1500, width: 1360, height: 2320), selection: CGRect(x: 40, y: 300, width: 1360, height: 520),
                  CGRect(x: 26, y: 152, width: 478, height: 140), coversBody: true)

        // A screen to the left of the main one, from x -1280 to 0 and y
        // 200 to 900, a body at its foot: beside it, the column narrowed
        // to the 292 points left on its right, and on that screen.
        try check(CGRect(x: -1200, y: 220, width: 900, height: 150), on: CGRect(x: -1280, y: 200, width: 1280, height: 700),
                  CGRect(x: -292, y: 200, width: 292, height: 239), column: 264)
        // A screen above and right of the main one: below.
        try check(CGRect(x: 1600, y: 1700, width: 900, height: 240), on: CGRect(x: 1440, y: 900, width: 1920, height: 1055),
                  CGRect(x: 1586, y: 1552, width: 478, height: 140))

        // A selection on another screen cannot be confirmed here.
        #expect(place(body: CGRect(x: 2000, y: 300, width: 600, height: 200)) == nil)
        // Only 140 points remain beside the selection, too narrow for a
        // card. Confirmation must not cover even part of the selection.
        let wide = CGRect(x: 0, y: 80, width: 1300, height: 795)
        #expect(place(body: wide) == nil)
        #expect(place(body: Self.laptop) == nil)
    }

    @Test func aShownCardMovesOffTheSelectionForConfirmationAndBackAfter() throws {
        let card = card()
        // The caret on the last line of a body near the foot.
        let body = CGRect(x: 486, y: 200, width: 640, height: 420)
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, 600)))
        let atCaret = try #require(card.frame)
        #expect(atCaret.intersects(body))
        card.keepClear = ProposalCard.KeepClear(body: body, selection: body)
        card.confirmingReplacement = true
        let confirming = try #require(card.frame)
        #expect(!confirming.intersects(body))
        #expect(Self.laptop.contains(confirming))
        #expect(card.current?.keys == "Tab again to replace what's selected")
        // Shown again at the same anchor, as each observation does, it stays.
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, 600)))
        #expect(card.frame == confirming)
        card.confirmingReplacement = false
        card.keepClear = nil
        #expect(card.frame == atCaret)
    }

    @Test func theFirstLineStartsAtTheCaretAndTheRestRunsDown() throws {
        let card = card()
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, 600)))
        let frame = try #require(card.frame)
        // The padding hangs outside the caret: the sheet's top left is 14
        // points left of the caret and 9 above its top.
        #expect(frame.minX == 486)
        #expect(frame.maxY == 609)
        #expect(frame.width == 478)
        #expect(frame.height > 60)
        #expect(Self.laptop.contains(frame))
        // The drawing window holds the sheet and its transparent float room.
        #expect(card.panel.frame == frame.insetBy(dx: -ProposalCard.shadowRoom, dy: -ProposalCard.shadowRoom))
        #expect(card.current?.text == Self.draft)
    }

    @Test func aCardThatWouldPassTheScreensFootOpensAboveTheCaret() throws {
        let card = card()
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, 140)))
        let frame = try #require(card.frame)
        // The sheet's bottom edge, padding included, sits six points above
        // the caret's top.
        #expect(frame.minY == 146)
        #expect(frame.maxY <= Self.laptop.maxY)
        #expect(frame.minX == 486)
    }

    @Test func aCardThatFitsNeitherWayIsNotShownAndOneShownBeforeGoes() throws {
        let card = card()
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, 600)))
        let height = try #require(card.frame?.height)
        // A screen a little shorter than the card, with the caret in its middle.
        let short = CGRect(x: 0, y: 0, width: 1440, height: height - 10)
        #expect(!card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, short.midY, screen: short)))
        #expect(!card.isShown)
        #expect(card.frame == nil)
        #expect(card.current == nil)
        #expect(!card.holdsContent)
        // The refused draft's measurement is gone too, as it is when a card
        // that was never shown is hidden.
        #expect(!card.holdsMeasurement)
        let fresh = self.card()
        #expect(!fresh.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, short.midY, screen: short)))
        fresh.hide()
        #expect(!fresh.holdsMeasurement)
    }

    /// A sheet 478 by 140 points, placed by geometry alone. Every expected
    /// frame is written out: below the caret its top is 9 points above the
    /// caret's top, above the caret its bottom is 6 points above it, and
    /// the whole sheet must lie inside the visible frame or there is none.
    @Test func placementKeepsTheWholeSheetInsideTheVisibleFrameAtBothEdges() {
        let size = CGSize(width: 478, height: 140)
        func place(_ x: CGFloat, _ y: CGFloat, on screen: CGRect, size: CGSize = size) -> CGRect? {
            ProposalCard.placement(of: size, at: ProposalCard.Anchor(textOrigin: CGPoint(x: x, y: y), bodyWidth: 600, screen: screen))
        }
        // The laptop's visible frame runs from y 80 to 875.
        let laptop = Self.laptop
        #expect(place(500, 600, on: laptop) == CGRect(x: 486, y: 469, width: 478, height: 140))
        // At the foot: below fits down to a bottom edge of exactly 80.
        #expect(place(500, 211, on: laptop) == CGRect(x: 486, y: 80, width: 478, height: 140))
        // A point lower it would pass the foot, so it opens above.
        #expect(place(500, 210, on: laptop) == CGRect(x: 486, y: 216, width: 478, height: 140))
        #expect(place(500, 80, on: laptop) == CGRect(x: 486, y: 86, width: 478, height: 140))
        // Above fits down to a caret 6 points under the frame's foot, and no lower.
        #expect(place(500, 74, on: laptop) == CGRect(x: 486, y: 80, width: 478, height: 140))
        #expect(place(500, 73, on: laptop) == nil)
        // At the top: below fits up to a top edge of exactly 875.
        #expect(place(500, 866, on: laptop) == CGRect(x: 486, y: 735, width: 478, height: 140))
        // Higher, below passes the top and above passes it further: none.
        #expect(place(500, 867, on: laptop) == nil)
        #expect(place(500, 874, on: laptop) == nil)

        // A screen to the left of the main one, its visible frame from
        // x -1280 to 0 and y 200 to 900.
        let left = CGRect(x: -1280, y: 200, width: 1280, height: 700)
        #expect(place(-1270, 500, on: left) == CGRect(x: -1280, y: 369, width: 478, height: 140))
        #expect(place(-10, 500, on: left) == CGRect(x: -478, y: 369, width: 478, height: 140))
        #expect(place(-1000, 331, on: left) == CGRect(x: -1014, y: 200, width: 478, height: 140))
        #expect(place(-1000, 330, on: left) == CGRect(x: -1014, y: 336, width: 478, height: 140))
        #expect(place(-1000, 194, on: left) == CGRect(x: -1014, y: 200, width: 478, height: 140))
        #expect(place(-1000, 193, on: left) == nil)
        #expect(place(-1000, 891, on: left) == CGRect(x: -1014, y: 760, width: 478, height: 140))
        #expect(place(-1000, 892, on: left) == nil)

        // A screen above and right of the main one, both origins nonzero.
        let upper = CGRect(x: 1440, y: 900, width: 1920, height: 1055)
        #expect(place(3350, 1500, on: upper) == CGRect(x: 2882, y: 1369, width: 478, height: 140))
        #expect(place(2000, 1030, on: upper) == CGRect(x: 1986, y: 1036, width: 478, height: 140))
        #expect(place(2000, 894, on: upper) == CGRect(x: 1986, y: 900, width: 478, height: 140))
        #expect(place(2000, 893, on: upper) == nil)

        // A sheet taller than the visible frame fits nowhere on it.
        let tall = CGSize(width: 478, height: 800)
        for y: CGFloat in [80, 300, 500, 875] {
            #expect(place(500, y, on: laptop, size: tall) == nil)
        }
        // One exactly as tall fits only with its first line at the very top.
        let exact = CGSize(width: 478, height: 795)
        #expect(place(500, 866, on: laptop, size: exact) == CGRect(x: 486, y: 80, width: 478, height: 795))
        #expect(place(500, 865, on: laptop, size: exact) == nil)
        // One wider than its screen is refused.
        #expect(place(10, 300, on: CGRect(x: 0, y: 0, width: 480, height: 800), size: CGSize(width: 500, height: 60)) == nil)
    }

    @Test func theCardNeverLeavesItsScreenSideways() throws {
        let card = card()
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(1400, 600)))
        #expect(try #require(card.frame).maxX == Self.laptop.maxX)
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(4, 600)))
        #expect(try #require(card.frame).minX == Self.laptop.minX)
    }

    @Test func theTextColumnIsAtMost450PointsAndNeverWiderThanTheBody() throws {
        let card = card()
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(300, 600, body: 1100)))
        #expect(try #require(card.frame).width == 478)
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(300, 600, body: 330)))
        #expect(try #require(card.frame).width == 330)
        // A narrower card is taller, its text wrapping more.
        let narrowHeight = try #require(card.frame).height
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(300, 600, body: 1100)))
        #expect(try #require(card.frame).height < narrowHeight)
        // Too narrow to read in: nothing.
        #expect(!card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(300, 600, body: 200)))
        #expect(!card.isShown)
        #expect(ProposalCard.textWidth(for: anchor(0, 0, body: 2000)) == 450)
        #expect(ProposalCard.textWidth(for: anchor(0, 0, body: 300)) == 272)
        #expect(ProposalCard.textWidth(for: anchor(0, 0, body: 227)) == nil)
    }

    /// The text column is at least 200 points, so a body narrower than 228
    /// gets no card, and at 228 the longest trigger Settings can record
    /// still fits its key row inside the sheet.
    @Test func aBodyOf228PointsIsTheNarrowestThatGetsACardEvenWithTheLongestKeyName() throws {
        #expect(ProposalCard.textWidth(for: anchor(0, 0, body: 228)) == 200)
        #expect(ProposalCard.textWidth(for: anchor(0, 0, body: 227.5)) == nil)
        // A screen narrower than 228 gets none either.
        #expect(ProposalCard.textWidth(for: anchor(0, 0, body: 640, screen: CGRect(x: 0, y: 80, width: 227, height: 795))) == nil)
        // Fn is refused in a combination, so four keys without it is the longest name.
        let longest = HoldKey.Key.combination([.control, .option, .shift, .command]).title
        #expect(longest == "Control + Option + Shift + Command")
        let card = card()
        #expect(!card.show(text: Self.draft, dictationKeyName: longest, at: anchor(400, 600, body: 227)))
        #expect(card.show(text: Self.draft, dictationKeyName: longest, at: anchor(400, 600, body: 228)))
        let frame = try #require(card.frame)
        #expect(frame.width == 228)
        #expect(card.current?.keys == "Tab to use this hold Control + Option + Shift + Command and say what to change or type your own")
        // Every piece of the key row is no wider than the 200-point column,
        // so the row wraps between them and nothing spills out of the sheet.
        for piece in [AnyView(ProposalCardView.UseButton(withWords: true)), AnyView(ProposalCardView.KeyName(label: longest).font(ProposalCardView.KeyRow.font)),
                      AnyView(ProposalCardView.MicGlyph()),
                      AnyView(Text("and say what to change").font(SetupStyle.text(11.5, .medium))),
                      AnyView(Text("or type your own").font(SetupStyle.text(11.5, .medium)))] {
            #expect(NSHostingView(rootView: piece).fittingSize.width <= 200)
        }
        // The Tab button's target stays inside the sheet, less its 4 and 3 point outset.
        #expect(frame.contains(card.target.frame.insetBy(dx: 4, dy: 3)))
    }

    @Test func aRealConfirmationFitsAtTheMinimumColumnWithoutCoveringTheSelection() throws {
        let card = card()
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 1200)
        // Neither above nor below has room. Only a 228-point sheet fits
        // on the right, including its two 14-point side paddings.
        let selection = CGRect(x: 0, y: 0, width: 764, height: 1200)
        let draft = "Hi Priya,\n\nThursday works. I'll check with the team and get back to you.\n\nThanks,\nSam"
        #expect(card.show(text: draft, dictationKeyName: "fn", at: anchor(20, 800, screen: screen)))
        #expect(card.beginConfirmation(keeping: .init(body: selection, selection: selection)))
        let frame = try #require(card.frame)
        #expect(frame.width == 228)
        #expect(!frame.intersects(selection))
        #expect(screen.contains(frame))
        // Measure the production view, including the full confirmation
        // row, independently from ProposalCard's manual height calculation.
        let rendered = NSHostingView(rootView: ProposalCardView(
            paragraphs: ProposalCard.paragraphs(of: draft), keyName: "fn", textWidth: 200,
            fades: false, confirmingReplacement: true)).fittingSize
        #expect(rendered.width == frame.width + 2 * ProposalCard.shadowRoom)
        #expect(rendered.height <= frame.height + 2 * ProposalCard.shadowRoom + 1)
        let row = NSHostingView(rootView: ProposalCardView.KeyRow(keyName: "fn", confirmingReplacement: true)
            .frame(width: 200)).fittingSize
        #expect(row.width == 200)
        #expect(row.height > 0)
        #expect(frame.contains(card.target.frame.insetBy(dx: 4, dy: 3)))
    }

    @Test func blankLinesSeparateParagraphsAndASingleBreakStaysInOne() {
        #expect(ProposalCard.paragraphs(of: "Hi Priya,\n\nThursday works.\n\nThanks,\nSam\n") == ["Hi Priya,", "Thursday works.", "Thanks,\nSam"])
        #expect(ProposalCard.paragraphs(of: "\n\n  \nOne line.\n \n\n") == ["One line."])
        #expect(ProposalCard.paragraphs(of: "") == [])
    }

    // MARK: - The key row

    @Test func theKeyRowNamesThePersonsOwnDictationKey() throws {
        let card = card()
        for name in ["fn", "right option", "Control+Option"] {
            #expect(card.show(text: Self.draft, dictationKeyName: name, at: anchor(400, 600)))
            #expect(card.current?.keys == "Tab to use this hold \(name) and say what to change or type your own")
            // The Tab button stays at the row's start whatever the key's name.
            let frame = try #require(card.frame)
            #expect(card.target.frame.minX < frame.minX + 14)
            #expect(card.target.frame.minY < frame.minY + 9 + 20)
        }
        // A long key name in a narrow field wraps the row rather than leaving the card.
        #expect(card.show(text: Self.draft, dictationKeyName: "Control + Option + Command", at: anchor(400, 600, body: 240)))
        let narrow = try #require(card.frame)
        #expect(narrow.width == 240)
        #expect(narrow.contains(card.target.frame.insetBy(dx: 4, dy: 3)))
    }

    @Test func theMeasuredTabHintIsTheDrawnOne() {
        // VoiceOver's press is placed from the Tab key measured on its own,
        // so it must carry the row's font rather than inherit one.
        for withWords in [false, true] {
            let alone = NSHostingView(rootView: ProposalCardView.UseButton(withWords: withWords)).fittingSize
            let inRow = NSHostingView(rootView: ProposalCardView.UseButton(withWords: withWords).font(ProposalCardView.KeyRow.font)).fittingSize
            let elsewhere = NSHostingView(rootView: ProposalCardView.UseButton(withWords: withWords).font(.system(size: 30))).fittingSize
            #expect(alone == inRow)
            #expect(alone == elsewhere)
        }
    }

    @Test func theKeysAreWordsOnTheFirstCardOnly() throws {
        let card = card()
        var shown = 0
        card.keyWordsDue = { shown == 0 }
        card.keyWordsShown = { shown += 1 }
        let keys = "Tab to use this hold fn and say what to change or type your own"
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(400, 600)))
        #expect(card.keyWords)
        #expect(shown == 1)
        let inWords = try #require(card.frame)
        // The same draft moved or redrawn keeps the words it arrived with.
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(400, 640)))
        #expect(card.keyWords)
        #expect(try #require(card.frame).size == inWords.size)
        // The next draft shows the keys as pictures, on a row no taller,
        // and VoiceOver still hears them in words.
        #expect(card.show(text: Self.draft + " See you then.", dictationKeyName: "fn", at: anchor(400, 600)))
        #expect(!card.keyWords)
        #expect(shown == 1)
        #expect(try #require(card.frame).height <= inWords.height)
        #expect(card.current?.keys == keys)
        let button = try #require(elements(card).first { $0.accessibilityRole() == .button })
        #expect(button.accessibilityLabel() == "Use this draft")
        #expect(button.accessibilityHelp() == keys)
        // A confirmation keeps its words whichever row it replaces.
        card.confirmingReplacement = true
        #expect(card.current?.keys == "Tab again to replace what's selected")
    }

    @Test func aFirstCardBackAfterAHideKeepsItsWordsUntilAnotherDraft() {
        let card = card()
        var shown = 0
        card.keyWordsDue = { shown == 0 }
        card.keyWordsShown = { shown += 1 }
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(400, 600)))
        #expect(card.keyWords)
        // Hidden as when the body scrolls away, it keeps nothing of the
        // text, and the same draft comes back in words.
        card.hide()
        #expect(!card.holdsContent)
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(400, 600)))
        #expect(card.keyWords)
        #expect(shown == 1)
        // A field too narrow for a card hides it the same way.
        #expect(!card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(400, 600, body: 227)))
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(400, 600)))
        #expect(card.keyWords)
        // A different draft shows pictures, and the first one, back after
        // it, no longer says its words.
        #expect(card.show(text: Self.draft + " See you then.", dictationKeyName: "fn", at: anchor(400, 600)))
        #expect(!card.keyWords)
        card.hide()
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(400, 600)))
        #expect(!card.keyWords)
        #expect(shown == 1)
    }

    @Test func aFirstCardBackFromAConfirmationWithNoRoomKeepsItsWords() throws {
        let card = card()
        var shown = 0
        card.keyWordsDue = { shown == 0 }
        card.keyWordsShown = { shown += 1 }
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 1200)
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(20, 800, screen: screen)))
        #expect(card.keyWords)
        // A selection covering the whole screen leaves no room for the
        // confirmation, so the card returns to its place as it was.
        let began = card.beginConfirmation(keeping: .init(body: screen, selection: screen))
        #expect(!began)
        #expect(card.isShown)
        #expect(!card.confirmingReplacement)
        #expect(card.keyWords)
        #expect(shown == 1)
    }

    // MARK: - Accessibility and mouse input

    @Test func mouseInputNeverRunsAcceptance() throws {
        let card = card()
        var accepted = 0
        card.accepted = { accepted += 1 }
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, 600)))
        let frame = try #require(card.frame)
        // The drawing passes mouse events through. The Accessibility
        // target absorbs a click without running acceptance.
        #expect(card.panel.ignoresMouseEvents)
        #expect(!card.target.ignoresMouseEvents)
        #expect(!card.panel.canBecomeKey && !card.panel.canBecomeMain)
        #expect(!card.target.canBecomeKey && !card.target.canBecomeMain)
        // The target is the button's corner of the sheet, not its text.
        #expect(frame.insetBy(dx: -4, dy: -3).contains(card.target.frame))
        #expect(card.target.frame.width < 120 && card.target.frame.height < 30)
        let text = CGPoint(x: frame.minX + 60, y: frame.maxY - 14)
        #expect(!card.target.frame.contains(text))
        // A non-key Accessibility window no longer accepts the first mouse.
        #expect(card.target.click(at: CGPoint(x: card.target.frame.width / 2, y: card.target.frame.height / 2)) == nil)
        #expect(accepted == 0)
        #expect(!card.target.isKeyWindow)
        // The card stays; ending it is the controller's.
        #expect(card.isShown)
    }

    @Test func whileADictationRecordsTheButtonAndVoiceOverDoNothing() throws {
        let card = card()
        var accepted = 0
        card.accepted = { accepted += 1 }
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, 600)))
        card.acceptsInput = false
        card.target.click(at: CGPoint(x: card.target.frame.width / 2, y: card.target.frame.height / 2))
        let button = try #require(elements(card).first { $0.accessibilityRole() == .button })
        #expect(!button.accessibilityPerformPress())
        #expect(accepted == 0)
        #expect(card.isShown)
        card.acceptsInput = true
        #expect(button.accessibilityPerformPress())
        #expect(accepted == 1)
    }

    /// The dot shares `.statusBar` with the popup and its notices; the card
    /// sits one level below, so the dot is drawn on the card's top edge
    /// rather than behind it.
    @Test func theCardSitsOneLevelBelowTheDotSoTheDotIsDrawnOnItsEdge() {
        let card = card()
        #expect(card.panel.level.rawValue == NSWindow.Level.statusBar.rawValue - 1)
        #expect(card.target.level == card.panel.level)
    }

    @Test func voiceOverReadsTheDraftAndPressesTheButtonButNotOneKeptFromBefore() throws {
        let card = card()
        var accepted = 0
        card.accepted = { accepted += 1 }
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, 600)))
        let first = try elements(card)
        #expect(first.count == 2)
        let text = try #require(first.first { $0.accessibilityRole() == .staticText })
        #expect(text.accessibilityValue() as? String == Self.draft)
        let button = try #require(first.first { $0.accessibilityRole() == .button })
        #expect(button.accessibilityLabel() == "Use this draft")
        #expect(button.accessibilityFrame().intersects(card.target.frame))
        #expect(!text.accessibilityPerformPress())
        #expect(button.accessibilityPerformPress())
        #expect(accepted == 1)
        // A new draft replaces the elements; the kept button presses nothing.
        #expect(card.show(text: "Thursday works.", dictationKeyName: "fn", at: anchor(500, 600)))
        #expect(!button.accessibilityPerformPress())
        #expect(accepted == 1)
        let second = try #require(elements(card).first { $0.accessibilityRole() == .button })
        #expect(second.accessibilityPerformPress())
        #expect(accepted == 2)
        // Once hidden, nothing presses and the clicks do nothing.
        card.hide()
        #expect(!second.accessibilityPerformPress())
        #expect(try elements(card).isEmpty)
        #expect(!card.press())
        #expect(accepted == 2)
    }

    @Test func theSameCardMovedKeepsTheButtonVoiceOverHoldsAndMovesItsTarget() throws {
        let card = card()
        var accepted = 0
        card.accepted = { accepted += 1 }
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, 600)))
        let button = try #require(elements(card).first { $0.accessibilityRole() == .button })
        let before = card.target.frame
        // The body scrolled forty points up the screen.
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, 640)))
        #expect(card.target.frame == before.offsetBy(dx: 0, dy: 40))
        #expect(card.panel.frame == (try #require(card.frame)).insetBy(dx: -ProposalCard.shadowRoom, dy: -ProposalCard.shadowRoom))
        #expect(button.accessibilityFrame().intersects(card.target.frame))
        #expect(button.accessibilityPerformPress())
        #expect(accepted == 1)
    }

    @Test func aRepeatedShowWithTheSameInputsMeasuresOnceAndMovesNothing() throws {
        let card = card()
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, 600)))
        #expect(card.measurements == 1)
        #expect(card.placements == 1)
        let panel = card.panel.frame, target = card.target.frame, sheet = try #require(card.frame)
        // The controller hands the same card on every observation of a
        // caret that has not moved.
        for _ in 0..<30 {
            #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, 600)))
        }
        #expect(card.measurements == 1)
        #expect(card.placements == 1)
        #expect(card.panel.frame == panel)
        #expect(card.target.frame == target)
        #expect(card.frame == sheet)
        // Moved, it is placed again from the same measurement.
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, 640)))
        #expect(card.measurements == 1)
        #expect(card.placements == 2)
        #expect(card.frame == sheet.offsetBy(dx: 0, dy: 40))
        // Another key name, another text or another column width is
        // measured again.
        #expect(card.show(text: Self.draft, dictationKeyName: "Right Option", at: anchor(500, 640)))
        #expect(card.measurements == 2)
        #expect(card.show(text: "Sounds good, Thursday works.", dictationKeyName: "Right Option", at: anchor(500, 640)))
        #expect(card.measurements == 3)
        #expect(card.show(text: "Sounds good, Thursday works.", dictationKeyName: "Right Option", at: anchor(500, 640, body: 400)))
        #expect(card.measurements == 4)
        #expect(card.placements == 5)
        // Hidden, it keeps no measurement of the text and measures again.
        card.hide()
        #expect(card.show(text: "Sounds good, Thursday works.", dictationKeyName: "Right Option", at: anchor(500, 640, body: 400)))
        #expect(card.measurements == 5)
        #expect(card.placements == 6)
    }

    // MARK: - Windows

    @Test func keptOffScreenNeitherWindowIsShown() {
        let card = card()
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, 600)))
        #expect(card.isShown)
        #expect(!card.panel.isVisible)
        #expect(!card.target.isVisible)
        #expect(card.panel.level == ProposalCardPanel.cardLevel && card.target.level == ProposalCardPanel.cardLevel)
        #expect(card.panel.collectionBehavior.contains(.canJoinAllSpaces))
    }

    @Test func aHiddenCardKeepsNothingOfTheText() {
        let card = card()
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, 600)))
        #expect(card.holdsContent)
        card.hide()
        #expect(!card.holdsContent)
        #expect(card.current == nil)
        #expect(card.frame == nil)
        // Hiding twice is harmless.
        card.hide()
        #expect(!card.isShown)
    }

    @Test func lockingTheScreenOrSleepingTheDisplaysHidesItUntilTheyAreBack() async {
        let lights = Lights()
        let card = card(lights)
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, 600)))
        lights.screen.post(name: .init("com.apple.screenIsLocked"), object: nil)
        #expect(!card.isShown)
        #expect(!card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, 600)))
        lights.screen.post(name: .init("com.apple.screenIsUnlocked"), object: nil)
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, 600)))
        lights.workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        #expect(!card.isShown)
        #expect(!card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, 600)))
        lights.workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, 600)))
    }

    @Test func everyLockAndSleepIsReportedWhetherOrNotACardShows() async {
        let lights = Lights()
        let card = card(lights)
        var reported = 0
        card.screenLockedOrAsleep = { reported += 1 }
        // No card: an accept under way has already hidden it.
        lights.screen.post(name: .init("com.apple.screenIsLocked"), object: nil)
        #expect(reported == 1)
        lights.screen.post(name: .init("com.apple.screenIsUnlocked"), object: nil)
        lights.workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        #expect(reported == 2)
        lights.workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        #expect(reported == 2)
        // A shown card hides first, then reports.
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, 600)))
        var shownWhenReported: Bool?
        card.screenLockedOrAsleep = { shownWhenReported = card.isShown }
        lights.screen.post(name: .init("com.apple.screenIsLocked"), object: nil)
        #expect(shownWhenReported == false)
    }

    // MARK: - Callbacks from other queues

    @Test func aLockPostedFromABackgroundQueueReachesTheCardOnTheMainActor() async {
        let lights = Lights()
        let card = card(lights)
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, 600)))
        await Self.offMain { lights.screen.post(name: .init("com.apple.screenIsLocked"), object: nil) }
        #expect(await eventually { !card.isShown })
        await Self.offMain { lights.screen.post(name: .init("com.apple.screenIsUnlocked"), object: nil) }
        #expect(await eventually { card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, 600)) })
        await Self.offMain { lights.workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil) }
        #expect(await eventually { !card.isShown })
    }

    @Test func aSleepPostedFromABackgroundQueueWithNoCardIsReportedOnTheMainActor() async {
        let lights = Lights()
        let card = card(lights)
        var reported = 0
        card.screenLockedOrAsleep = { reported += 1 }
        await Self.offMain { lights.workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil) }
        #expect(await eventually { reported == 1 })
        await Self.offMain { lights.screen.post(name: .init("com.apple.screenIsLocked"), object: nil) }
        #expect(await eventually { reported == 2 })
    }

    @Test func voiceOversPressFromABackgroundQueueReachesTheCardOnTheMainActor() async throws {
        let card = card()
        var accepted = 0
        card.accepted = { accepted += 1 }
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, 600)))
        let button = Held(try #require(elements(card).first { $0.accessibilityRole() == .button }))
        let text = Held(try #require(elements(card).first { $0.accessibilityRole() == .staticText }))
        let sent = Collected()
        await Self.offMain {
            sent.add(button.value.accessibilityPerformPress())
            sent.add(text.value.accessibilityPerformPress())
        }
        // The button's press was sent and the text has none.
        #expect(sent.all == [true, false])
        #expect(await eventually { accepted == 1 })
        // While a dictation records, a press from another queue does nothing.
        card.acceptsInput = false
        Self.offMainWhileMainWaits { _ = button.value.accessibilityPerformPress() }
        await Self.offMain {}
        #expect(accepted == 1)
        card.acceptsInput = true
    }

    @Test func aPressVoiceOverQueuedForAButtonReplacedOrHiddenBeforeItRunsPressesNothing() async throws {
        let card = card()
        var accepted = 0
        card.accepted = { accepted += 1 }
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, 600)))
        let kept = Held(try #require(elements(card).first { $0.accessibilityRole() == .button }))
        // The press is queued from another queue, and a new draft replaces
        // the card's elements before the main queue runs it.
        Self.offMainWhileMainWaits { _ = kept.value.accessibilityPerformPress() }
        #expect(card.show(text: "Thursday works.", dictationKeyName: "fn", at: anchor(500, 600)))
        await Self.offMain {}
        try? await Task.sleep(for: .milliseconds(20))
        #expect(accepted == 0)
        // The same with the card hidden before the queued press runs.
        let current = Held(try #require(elements(card).first { $0.accessibilityRole() == .button }))
        Self.offMainWhileMainWaits { _ = current.value.accessibilityPerformPress() }
        card.hide()
        await Self.offMain {}
        try? await Task.sleep(for: .milliseconds(20))
        #expect(accepted == 0)
        // Shown again, the button of the moment presses.
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, 600)))
        let shown = Held(try #require(elements(card).first { $0.accessibilityRole() == .button }))
        Self.offMainWhileMainWaits { _ = shown.value.accessibilityPerformPress() }
        #expect(await eventually { accepted == 1 })
    }

    /// Answers collected from a background queue.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Bool] = []
        func add(_ value: Bool) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }
        var all: [Bool] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    @Test func theScreenHandlerCalledOffTheMainThreadHopsToTheMainActor() async {
        let card = card()
        #expect(card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, 600)))
        await Self.offMain { card.screen(.asleep) }
        #expect(await eventually { !card.isShown })
        await Self.offMain { card.screen(.awake) }
        #expect(await eventually { card.show(text: Self.draft, dictationKeyName: "fn", at: anchor(500, 600)) })
    }
}
