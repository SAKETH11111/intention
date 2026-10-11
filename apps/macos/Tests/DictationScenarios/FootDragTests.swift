import AppKit
@testable import Dictation
import Foundation
import Testing

/// Moving the foot dot: a press and drag on its click target, delivered as
/// the window would deliver it, the slot it lands in on each display, the
/// click that a small wobble stays, VoiceOver's moves and Settings' choice.
/// The windows are never put on screen. The feet here run under Reduce
/// Motion, so the dot lands at once; one check runs the spring itself, which
/// off screen lands by its clock.
@MainActor
struct FootDragTests {
    /// The laptop of `FootPlacementTests`: 1440 by 900, a Dock that stays
    /// shown 80 points tall at the bottom and the menu bar's 25 at the top.
    /// The dot rests 26 above the Dock, the listening sun's envelope, at
    /// (720, 106); at the right, 26 from the edge at the usable area's
    /// middle height, 80 + 795 / 2 rounded, (1414, 478); at the left, (26, 478).
    static let laptop = FootMark.Screen(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                        usable: CGRect(x: 0, y: 80, width: 1440, height: 795), key: "laptop")
    /// A monitor to its right with no Dock: its left slot is 1440 + 26 at
    /// 1055 / 2 rounded, (1466, 528).
    static let monitor = FootMark.Screen(id: 2, frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
                                         usable: CGRect(x: 1440, y: 0, width: 1920, height: 1055), key: "monitor")

    /// A foot whose choices are kept here, by display key, as Preferences
    /// keeps them.
    @MainActor
    final class Choices {
        var everywhere = FootSlot.bottom
        var byDisplay: [String: FootSlot] = [:]
        var chosen: [String] = []
    }

    static func foot(_ choices: Choices, screens: [FootMark.Screen] = [laptop, monitor],
                     pointer: CGPoint = CGPoint(x: 700, y: 400)) -> FootMark {
        let foot = FootMark(desktop: .init(screens: { screens }, pointer: { pointer }, showsWindow: false))
        foot.slotFor = { choices.byDisplay[$0.key] ?? choices.everywhere }
        foot.chose = { slot, screen, _ in
            choices.byDisplay[screen.key] = slot
            choices.chosen.append("\(slot.rawValue) on \(screen.key)")
        }
        foot.mark.reducesMotion = { true }
        foot.enabled = true
        return foot
    }

    private func centre(_ foot: FootMark) -> CGPoint? {
        foot.markFrame.map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    @Test func aDragPastTheThresholdLandsInTheNearestSlotAndThatDisplayKeepsIt() throws {
        let choices = Choices()
        let foot = Self.foot(choices)
        var actions: [FootAction] = []
        foot.onAction = { actions.append($0) }
        #expect(centre(foot) == CGPoint(x: 720, y: 106))
        foot.target.press(at: CGPoint(x: 720, y: 106), moves: [CGPoint(x: 760, y: 140), CGPoint(x: 1200, y: 420), CGPoint(x: 1380, y: 470)],
                          checking: { #expect(foot.showsSlots) })
        #expect(!foot.showsSlots)
        #expect(choices.chosen == ["right on laptop"])
        #expect(foot.slot == .right)
        #expect(centre(foot) == CGPoint(x: 1414, y: 478))
        #expect(foot.target.frame == CGRect(x: 1398, y: 462, width: 32, height: 32))
        #expect(actions.isEmpty)
    }

    @Test func letGoOverTheNextDisplayItLandsThereAndOnlyThatDisplayChanges() {
        let choices = Choices()
        let foot = Self.foot(choices)
        foot.target.press(at: CGPoint(x: 720, y: 106), moves: [CGPoint(x: 1300, y: 300), CGPoint(x: 1480, y: 560)])
        #expect(choices.chosen == ["left on monitor"])
        #expect(centre(foot) == CGPoint(x: 1466, y: 528))
        #expect(choices.byDisplay["laptop"] == nil)
    }

    @Test func aThrowCarriesTheDotTowardTheEdgeItWasThrownAt() {
        let choices = Choices()
        let foot = Self.foot(choices)
        // Let go just right of the middle, still moving fast to the left.
        foot.target.press(at: CGPoint(x: 720, y: 106), moves: [CGPoint(x: 760, y: 400), CGPoint(x: 740, y: 420)],
                          last: CGPoint(x: 500, y: 430), lastAfter: 0.05)
        #expect(choices.chosen == ["left on laptop"])
        #expect(centre(foot) == CGPoint(x: 26, y: 478))
    }

    @Test func aWobbleUnderTheThresholdIsStillAClick() {
        let choices = Choices()
        let foot = Self.foot(choices)
        var actions: [FootAction] = []
        foot.onAction = { actions.append($0) }
        // A first click on the bare dot shows the hint, a second starts.
        foot.target.press(at: CGPoint(x: 720, y: 106), moves: [CGPoint(x: 722, y: 108)])
        #expect(foot.presentation == .hint)
        foot.target.press(at: CGPoint(x: 721, y: 107), moves: [])
        #expect(actions == [.start])
        #expect(choices.chosen.isEmpty)
    }

    @Test func duringADictationAPressThatMovesIsNeitherADragNorAClick() {
        let choices = Choices()
        let foot = Self.foot(choices)
        var actions: [FootAction] = []
        foot.onAction = { actions.append($0) }
        foot.state = .listening
        foot.target.press(at: CGPoint(x: 720, y: 106), moves: [CGPoint(x: 900, y: 300), CGPoint(x: 1380, y: 470)],
                          checking: { #expect(!foot.showsSlots) })
        #expect(actions.isEmpty)
        #expect(choices.chosen.isEmpty)
        #expect(foot.slot == .bottom)
    }

    @Test func hidingTheFootMidDragDropsTheDragWithNoChoice() {
        let choices = Choices()
        let foot = Self.foot(choices)
        foot.target.press(at: CGPoint(x: 720, y: 106), moves: [CGPoint(x: 900, y: 300)], checking: {
            #expect(foot.showsSlots)
            foot.enabled = false
            #expect(!foot.showsSlots)
        })
        #expect(choices.chosen.isEmpty)
        foot.enabled = true
        #expect(centre(foot) == CGPoint(x: 720, y: 106))
    }

    /// A dot taken in the hand during the key hint drops the microphone
    /// and its caps, which stay gone once it lands.
    @Test func takingTheDotDuringTheKeyHintDropsIt() {
        let choices = Choices()
        let foot = Self.foot(choices)
        foot.showKeyHint()
        #expect(foot.presentation == .keyHint)
        #expect(foot.mark.glyph != nil)
        foot.target.press(at: CGPoint(x: 720, y: 106), moves: [CGPoint(x: 900, y: 300)], checking: {
            #expect(foot.isMoving)
            #expect(foot.mark.glyph == nil)
            #expect(foot.presentation != .keyHint)
        })
        #expect(foot.mark.glyph == nil)
        #expect(foot.presentation != .keyHint)
    }

    /// At a side the pill stands where the dot stands, nothing opens
    /// outward, and the click target holds the whole pill; the tooltip
    /// stands above it, inside the screen.
    @Test func atASideThePillStandsWhereTheDotStandsAndTakesTheClicks() throws {
        let choices = Choices()
        choices.everywhere = .left
        let foot = Self.foot(choices)
        #expect(foot.mark.opening == .rightward)
        let left = try #require(foot.markFrame)
        foot.hover(true, at: true)
        #expect(foot.mark.glyph == SunDotView.Glyph(key: "fn"))
        #expect(foot.slipFrame == nil)
        #expect(foot.markFrame == left)
        #expect(foot.target.frame.contains(left))
        #expect(foot.target.frame.contains(FootPlacementTests.glyphOnScreen(foot)))
        choices.everywhere = .right
        foot.slotsChanged()
        #expect(foot.mark.opening == .leftward)
        // The dot left the pointer behind; pointed at again where it is now.
        let right = try #require(foot.markFrame)
        foot.hover(true, at: true)
        #expect(foot.mark.glyph == SunDotView.Glyph(key: "fn"))
        #expect(foot.slipFrame == nil)
        #expect(foot.markFrame == right)
        #expect(foot.target.frame.contains(right))
        #expect(foot.target.frame.contains(FootPlacementTests.glyphOnScreen(foot)))
        #expect(foot.target.frame.contains(CGPoint(x: 1414, y: 478)))
        // The key hint's tooltip stands above the pill, held inside the
        // screen's right edge.
        foot.hover(false)
        foot.showKeyHint()
        let tip = try #require(FootPlacementTests.tooltipOnScreen(foot))
        let pill = FootPlacementTests.glyphOnScreen(foot)
        #expect(abs(tip.minY - pill.maxY - (SunDotView.tooltipGap - SunDotView.restEdge)) <= 0.5)
        #expect(tip.maxX <= foot.panel.frame.maxX - 8 && tip.maxX <= 1440)
        #expect(tip.midX < pill.midX)
        choices.everywhere = .bottom
        foot.slotsChanged()
        #expect(foot.mark.opening == .centre)
    }

    /// While listening a drag is refused, and a press that wobbles past the
    /// threshold but is let go over the sun is still Done.
    @Test func whileListeningAWobbleOverTheSunIsStillDone() {
        let choices = Choices()
        let foot = Self.foot(choices)
        var actions: [FootAction] = []
        foot.onAction = { actions.append($0) }
        foot.state = .listening
        foot.target.press(at: CGPoint(x: 720, y: 106), moves: [CGPoint(x: 726, y: 106)])
        #expect(actions == [.done])
        #expect(choices.chosen.isEmpty)
    }

    /// Taken 15 points right of its centre and let go 8 points onto the
    /// monitor, the dot itself is still over the laptop: the pointer's
    /// display decides, so it lands on the monitor's left slot.
    @Test func aDotTakenOffCentreLandsOnTheDisplayUnderThePointer() {
        let choices = Choices()
        let foot = Self.foot(choices)
        foot.target.press(at: CGPoint(x: 735, y: 106), moves: [CGPoint(x: 1200, y: 400), CGPoint(x: 1448, y: 500)])
        #expect(choices.chosen == ["left on monitor"])
        #expect(centre(foot) == CGPoint(x: 1466, y: 528))
    }

    /// A dictation started with the dot in the hand drops the drag: the
    /// slots go, nothing is chosen, and the foot offers Done where it rests.
    @Test func aDictationStartedMidDragDropsTheDrag() {
        let choices = Choices()
        let foot = Self.foot(choices)
        foot.target.press(at: CGPoint(x: 720, y: 106), moves: [CGPoint(x: 900, y: 300)], checking: {
            #expect(foot.showsSlots)
            foot.state = .listening
            #expect(!foot.showsSlots)
            #expect(!foot.isMoving)
        })
        #expect(choices.chosen.isEmpty)
        #expect(centre(foot) == CGPoint(x: 720, y: 106))
        #expect(foot.target.buttons.map(\.name) == ["Stop dictating"])
    }

    /// A display change mid-drag drops it, so no move is left waiting on a
    /// display that may be gone.
    @Test func aDisplayChangeMidDragDropsTheDrag() {
        let choices = Choices()
        let foot = Self.foot(choices)
        foot.target.press(at: CGPoint(x: 720, y: 106), moves: [CGPoint(x: 900, y: 300)], checking: {
            foot.screensChanged()
            #expect(!foot.isMoving)
        })
        #expect(choices.chosen.isEmpty)
        #expect(centre(foot) == CGPoint(x: 720, y: 106))
    }

    /// Through the app's own Preferences: a drag on the monitor leaves the
    /// laptop's dot where it was, though the latest choice becomes what
    /// Settings shows and what a new display starts from.
    @Test func aDragOnOneDisplayNeverMovesTheDotOnAnother() {
        let name = "FootDragTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = Preferences(defaults: defaults)
        let foot = FootMark(desktop: .init(screens: { [Self.laptop, Self.monitor] }, pointer: { CGPoint(x: 700, y: 400) }, showsWindow: false))
        foot.slotFor = { preferences.dotPosition(onDisplay: $0.key) }
        foot.chose = { slot, screen, connected in preferences.chooseDotPosition(slot, onDisplay: screen.key, keeping: connected.map(\.key)) }
        foot.enabled = true
        foot.target.press(at: CGPoint(x: 720, y: 106), moves: [CGPoint(x: 1600, y: 300), CGPoint(x: 3300, y: 540)])
        #expect(preferences.dotPosition(onDisplay: "monitor") == .right)
        #expect(preferences.dotPosition(onDisplay: "laptop") == .bottom)
        #expect(preferences.dotPosition == .right)
        #expect(preferences.dotPosition(onDisplay: "projector") == .right)
    }

    /// With motion on, the dot springs into its slot: the foot is moving and
    /// takes no placement until the spring lands, then rests in the slot with
    /// its click target there. Settings choosing another slot meanwhile turns
    /// the spring toward it.
    @Test(.timeLimit(.minutes(1))) func theSpringLandsInTheSlotAndSettingsCanTurnIt() async {
        let choices = Choices()
        let foot = Self.foot(choices)
        foot.mark.reducesMotion = { false }
        foot.target.press(at: CGPoint(x: 720, y: 106), moves: [CGPoint(x: 1200, y: 420), CGPoint(x: 1380, y: 470)])
        #expect(foot.isMoving)
        #expect(choices.chosen == ["right on laptop"])
        choices.everywhere = .left
        choices.byDisplay = [:]
        foot.slotsChanged()
        #expect(foot.isMoving)
        #expect(foot.slot == .left)
        let deadline = ContinuousClock.now + .seconds(5)
        while foot.isMoving, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(!foot.isMoving)
        #expect(centre(foot) == CGPoint(x: 26, y: 478))
        #expect(foot.target.frame == CGRect(x: 10, y: 462, width: 32, height: 32))
    }

    /// Where the dot is drawn on screen: its resting centre moved by the face's
    /// glide into an open slip.
    private func drawnCentre(_ foot: FootMark) -> CGPoint {
        let local = CGPoint(x: foot.mark.bounds.midX + foot.mark.faceOffset.x, y: foot.mark.bounds.midY + foot.mark.faceOffset.y)
        let inWindow = foot.mark.convert(local, to: foot.panel.contentView)
        return CGPoint(x: foot.panel.frame.minX + inWindow.x, y: foot.panel.frame.minY + inWindow.y)
    }

    /// The polish gate's probe: with the hint open, the drawn dot sits at
    /// the slip's end, away from where it rests at the bottom. Taken there,
    /// it stays under the pointer as the slip closes, with motion and under
    /// Reduce Motion, at every slot.
    @Test(.timeLimit(.minutes(1)), arguments: [FootSlot.bottom, .left, .right], [false, true])
    func theDrawnDotStaysUnderThePointerAsTheSlipCloses(slot: FootSlot, still: Bool) async throws {
        let choices = Choices()
        choices.everywhere = slot
        let foot = Self.foot(choices)
        defer { foot.enabled = false }
        foot.mark.reducesMotion = { still }
        foot.hover(true, at: true)
        try await Task.sleep(for: .milliseconds(650))
        let before = try #require(foot.markFrame)
        let grab = CGPoint(x: before.midX, y: before.midY)
        #expect(drawnCentre(foot) == grab)
        #expect(foot.beginDrag(at: grab))
        let moved = CGPoint(x: grab.x + 100, y: grab.y + 80)
        foot.dragMoved(to: moved)
        try await Task.sleep(for: .milliseconds(650))
        let drawn = drawnCentre(foot)
        #expect(abs(drawn.x - moved.x) < 0.5)
        #expect(abs(drawn.y - moved.y) < 0.5)
    }

    /// The nearest a spring brings the dot to its slot's edge, along
    /// `outward`, sampled every 9600th of a second, finer than the bound's
    /// own search, so a peak between its samples shows.
    private func farthest(_ spring: FootSpring, past rest: CGPoint, toward outward: CGVector) -> CGFloat {
        stride(from: 0.0, through: 1.5, by: 1.0 / 9600).map { t -> CGFloat in
            let here = spring.position(at: t)
            return (here.x - rest.x) * outward.dx + (here.y - rest.y) * outward.dy
        }.max() ?? 0
    }

    /// A hard throw at the left slot, 26 from the edge, swings at most 7.6
    /// past it, so the held dot's edge, hairline included, stays 8 clear of
    /// the screen's; the throw is only slowed toward the edge, and the dot
    /// still rests there.
    @Test func aHardThrowNeverSwingsTheDotIntoTheEdge() {
        let rest = CGPoint(x: 26, y: 478)
        let free = FootSpring(from: CGPoint(x: 300, y: 478), to: rest, velocity: CGVector(dx: -2400, dy: 0))
        #expect(farthest(free, past: rest, toward: CGVector(dx: -1, dy: 0)) > 7.6)
        let bounded = FootSpring.bounded(from: CGPoint(x: 300, y: 478), to: rest, velocity: CGVector(dx: -2400, dy: 0),
                                         outward: CGVector(dx: -1, dy: 0))
        let swing = farthest(bounded, past: rest, toward: CGVector(dx: -1, dy: 0))
        #expect(swing <= 7.6 + 1e-9)
        #expect(swing > 5)
        #expect(bounded.settled(at: 1.5))
        #expect(abs(bounded.position(at: 1.5).x - 26) < 0.35)
    }

    /// From across the screen with no throw at all, the spring alone would
    /// swing past the bound; the dot is held there and springs home.
    @Test func aLongDropIsHeldAtTheBound() {
        let rest = CGPoint(x: 720, y: 106)
        let bounded = FootSpring.bounded(from: CGPoint(x: 720, y: 880), to: rest, velocity: .zero, outward: CGVector(dx: 0, dy: -1))
        #expect(farthest(bounded, past: rest, toward: CGVector(dx: 0, dy: -1)) <= 7.6 + 1e-9)
        #expect(abs(bounded.position(at: 1.5).y - 106) < 0.35)
    }

    /// The polish gate's case: the long drop's peak falls between the
    /// bound's samples, where a 60 Hz display offset by 0.0161667 s lands.
    /// At that phase, and at others, no frame goes past the bound.
    @Test func noFramePhaseFindsTheDotPastTheBound() {
        let rest = CGPoint(x: 720, y: 106)
        let bounded = FootSpring.bounded(from: CGPoint(x: 720, y: 880), to: rest, velocity: .zero, outward: CGVector(dx: 0, dy: -1))
        #expect(rest.y - bounded.position(at: 0.1495).y <= 7.6)
        #expect(rest.y - bounded.position(at: 0.14995).y <= 7.6)
        for phase in [0, 0.016166667, 0.0005, 0.0011, 0.0083] {
            for frame in 0..<90 {
                let t = phase + Double(frame) / 60
                #expect(rest.y - bounded.position(at: t).y <= 7.6 + 1e-9)
            }
        }
        let thrown = FootSpring.bounded(from: CGPoint(x: 300, y: 478), to: CGPoint(x: 26, y: 478), velocity: CGVector(dx: -2400, dy: 0),
                                        outward: CGVector(dx: -1, dy: 0))
        for phase in [0, 0.016166667, 0.0005, 0.0011, 0.0083] {
            for frame in 0..<90 {
                #expect(26 - thrown.position(at: phase + Double(frame) / 60).x <= 7.6 + 1e-9)
            }
        }
    }

    /// The bound is the drawn dot's, not a number kept apart from it: 7.6
    /// for 26 from the floor, 8 clear and the 16 point dot with its
    /// hairline held at 1.3. And on throws to every slot, the held dot as the
    /// view draws it, its whole box round the farthest swing, stays 8 points
    /// from the edge.
    @Test func theHeldDotAsDrawnStaysEightPointsFromTheEdge() {
        #expect(abs(FootSpring.overshoot - 7.6) < 1e-9)
        let drawn = OwnHandMark.dot(diameter: SunDotView.restWidth + 2 * SunDotView.restEdge).path.boundingBox
        let reach = max(drawn.width, drawn.height) / 2 * SunDotView.liftScale
        let cases: [(from: CGPoint, rest: CGPoint, velocity: CGVector, outward: CGVector)] = [
            (CGPoint(x: 300, y: 478), CGPoint(x: 26, y: 478), CGVector(dx: -2400, dy: 0), CGVector(dx: -1, dy: 0)),
            (CGPoint(x: 1100, y: 470), CGPoint(x: 1414, y: 478), CGVector(dx: 2400, dy: 300), CGVector(dx: 1, dy: 0)),
            (CGPoint(x: 720, y: 880), CGPoint(x: 720, y: 106), CGVector(dx: 0, dy: -2400), CGVector(dx: 0, dy: -1)),
        ]
        for one in cases {
            let spring = FootSpring.bounded(from: one.from, to: one.rest, velocity: one.velocity, outward: one.outward)
            let swing = farthest(spring, past: one.rest, toward: one.outward)
            #expect(26 - swing - reach >= 8 - 1e-9)
        }
    }

    /// A gentle throw is left as it is.
    @Test func aGentleThrowIsUntouched() {
        let rest = CGPoint(x: 1414, y: 478)
        let gentle = FootSpring.bounded(from: CGPoint(x: 1340, y: 500), to: rest, velocity: CGVector(dx: 300, dy: -120), outward: CGVector(dx: 1, dy: 0))
        let free = FootSpring(from: CGPoint(x: 1340, y: 500), to: rest, velocity: CGVector(dx: 300, dy: -120))
        for t in stride(from: 0.0, through: 1.0, by: 0.05) { #expect(gentle.position(at: t) == free.position(at: t)) }
    }

    /// A glide whose view is on no display, whose display link never fires,
    /// still ends by the clock, where it was going.
    @Test(.timeLimit(.minutes(1))) func aGlideOffEveryDisplayStillLands() async {
        let glide = FootGlide()
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        var applied: [CGPoint] = []
        var ended = false
        glide.start(FootSpring(from: .zero, to: CGPoint(x: 100, y: 40), velocity: .zero), on: view,
                    apply: { applied.append($0) }, done: { ended = true })
        #expect(glide.isRunning)
        let deadline = ContinuousClock.now + .seconds(4)
        while !ended, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(ended)
        #expect(!glide.isRunning)
        #expect(applied.last == CGPoint(x: 100, y: 40))
    }

    @Test func atASideTheFocusedFieldAlongThatEdgeHidesItAndOneAtTheFootDoesNot() {
        let choices = Choices()
        choices.everywhere = .left
        let foot = Self.foot(choices)
        // A chat composer along the foot is clear of a dot at the left.
        foot.focusedField = CGRect(x: 0, y: 90, width: 1440, height: 40)
        #expect(foot.painting)
        // A sidebar's search field reaching the left edge at the middle is not.
        foot.focusedField = CGRect(x: 0, y: 440, width: 300, height: 30)
        #expect(!foot.painting)
        #expect(foot.markFrame == nil)
        // Above the left slot's band it is clear again.
        foot.focusedField = CGRect(x: 0, y: 700, width: 300, height: 30)
        #expect(foot.painting)
    }

    @Test func voiceOverOffersTheOtherSlotsAtRestAndMovesTheDot() throws {
        let choices = Choices()
        let foot = Self.foot(choices)
        func dictate() throws -> NSAccessibilityElement {
            let view = try #require(foot.target.contentView)
            return try #require((view.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }.first)
        }
        let actions = try dictate().accessibilityCustomActions() ?? []
        #expect(actions.map(\.name) == ["Move dot to the left", "Move dot to the right"])
        let left = try #require(actions.first)
        _ = (left.target as? NSObject)?.perform(left.selector, with: left)
        #expect(choices.chosen == ["left on laptop"])
        #expect(centre(foot) == CGPoint(x: 26, y: 478))
        #expect(try dictate().accessibilityCustomActions()?.map(\.name) == ["Move dot to the bottom", "Move dot to the right"])
        foot.state = .listening
        #expect(try dictate().accessibilityCustomActions()?.map(\.name) == ["Cancel dictation"])
    }

    @Test func settingsMovesTheDotWhereverItIs() {
        let choices = Choices()
        let foot = Self.foot(choices)
        choices.everywhere = .right
        foot.slotsChanged()
        #expect(foot.slot == .right)
        #expect(centre(foot) == CGPoint(x: 1414, y: 478))
        #expect(choices.chosen.isEmpty)
    }

    /// With the Dock shown at the left, the left slot sits 26 points beside
    /// it, 72 + 26, as the bottom one sits above a Dock at the bottom.
    @Test func withTheDockAtTheLeftTheLeftSlotSitsBesideIt() {
        let choices = Choices()
        choices.everywhere = .left
        let dockLeft = FootMark.Screen(id: 3, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                       usable: CGRect(x: 72, y: 0, width: 1368, height: 875), key: "dock-left")
        let foot = Self.foot(choices, screens: [dockLeft])
        #expect(centre(foot) == CGPoint(x: 98, y: 438))
    }
}

extension FootTargetWindow {
    /// A press at `start`, drags through `moves` 40 ms apart, and a release
    /// at the last point after the pointer has rested there, delivered to
    /// the view the window would give them, in AppKit screen coordinates.
    /// `last`, when given, is one more drag `lastAfter` seconds after the
    /// others, released at once, for a throw. `checking` runs before the
    /// release.
    func press(at start: CGPoint, moves: [CGPoint], last: CGPoint? = nil, lastAfter: TimeInterval = 0.04,
               checking: () -> Void = {}) {
        guard let view = contentView else { return }
        var time = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: point.x - frame.minX, y: point.y - frame.minY), modifierFlags: [],
                               timestamp: time, windowNumber: windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                               pressure: type == .leftMouseUp ? 0 : 1)!
        }
        view.mouseDown(with: event(.leftMouseDown, start))
        var at = start
        for point in moves {
            time += 0.04
            at = point
            view.mouseDragged(with: event(.leftMouseDragged, point))
        }
        if let last {
            time += lastAfter
            at = last
            view.mouseDragged(with: event(.leftMouseDragged, last))
        } else {
            // Resting before the release: no throw.
            time += 0.2
            if !moves.isEmpty { view.mouseDragged(with: event(.leftMouseDragged, at)) }
        }
        checking()
        view.mouseUp(with: event(.leftMouseUp, at))
    }
}
