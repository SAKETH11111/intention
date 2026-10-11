import AppKit
@testable import Dictation
import Foundation
import SwiftUI
import Testing

/// The foot mark's windows placed on made-up displays, with a made-up
/// pointer and focused field. The windows are never put on screen.
@MainActor
struct FootPlacementTests {
    /// A laptop screen with a visible Dock, and a larger one to its right
    /// with the Dock hidden.
    static let laptop = FootMark.Screen(
        id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), usable: CGRect(x: 0, y: 80, width: 1440, height: 795))
    static let monitor = FootMark.Screen(
        id: 2, frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), usable: CGRect(x: 1440, y: 0, width: 1920, height: 1055))

    @MainActor
    final class Desk {
        var screens = [FootPlacementTests.laptop, FootPlacementTests.monitor]
        var pointer = CGPoint(x: 700, y: 400)
    }

    static func foot(_ desk: Desk = Desk(), saysWords: Bool = true,
                     noticeWait: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) -> FootMark {
        let foot = FootMark(desktop: .init(screens: { desk.screens }, pointer: { desk.pointer }, showsWindow: false),
                            noticeWait: noticeWait)
        foot.mark.reducesMotion = { false }
        foot.hoverDelay = .zero
        foot.enabled = true
        foot.saysWords = saysWords
        return foot
    }

    /// The pill with its hairline in AppKit screen coordinates, as drawn
    /// y-down round the dot's centre.
    static func glyphOnScreen(_ foot: FootMark) -> CGRect {
        let pill = (foot.mark.glyphDrawing.pill ?? .zero).insetBy(dx: -SunDotView.restEdge, dy: -SunDotView.restEdge)
        let centre = CGPoint(x: foot.panel.frame.minX + FootMark.layout(for: foot.slot).dot.x,
                             y: foot.panel.frame.minY + FootMark.layout(for: foot.slot).dot.y)
        return CGRect(x: centre.x + pill.minX, y: centre.y - pill.maxY, width: pill.width, height: pill.height)
    }

    /// The tooltip in AppKit screen coordinates, from where the mark drew it.
    static func tooltipOnScreen(_ foot: FootMark) -> CGRect? {
        guard let tip = foot.mark.glyphDrawing.tooltip else { return nil }
        let mark = foot.mark.frame
        return CGRect(x: foot.panel.frame.minX + mark.minX + tip.minX, y: foot.panel.frame.minY + mark.maxY - tip.maxY,
                      width: tip.width, height: tip.height)
    }

    private func onLaptop(_ foot: FootMark) -> Bool { foot.panel.frame == FootMark.frame(on: Self.laptop) }
    private func onMonitor(_ foot: FootMark) -> Bool { foot.panel.frame == FootMark.frame(on: Self.monitor) }

    @Test func theFootChangesAppearanceWithoutChangingHoverTargetsOrItsNoticeTimer() async throws {
        let timer = NoticeTimer()
        let foot = Self.foot(noticeWait: timer.wait)
        var look = Appearance.light
        foot.appearance = { MainActor.assertIsolated(); return look }
        foot.hover(true)
        #expect(foot.mark.glyph == SunDotView.Glyph(key: "fn"))
        let frame = foot.panel.frame
        let target = foot.target.frame
        look = .dark
        foot.appearanceChanged()
        #expect(foot.mark.glyph == SunDotView.Glyph(key: "fn"))
        look = .light
        foot.appearanceChanged()
        let elements = foot.target.contentView?.accessibilityChildren() as? [NSAccessibilityElement] ?? []
        look = .dark
        await AppearanceCallbackTests.offMain { foot.appearanceChanged() }
        #expect(await AppearanceCallbackTests.eventually { foot.panel.appearance?.name == .darkAqua })
        #expect(foot.mark.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        #expect(foot.target.appearance?.name == .darkAqua)
        #expect(foot.presentation == .hint)
        #expect(foot.panel.frame == frame)
        #expect(foot.target.frame == target)
        #expect(foot.slipFrame == nil)
        #expect(foot.mark.glyph == SunDotView.Glyph(key: "fn"))
        #expect((foot.target.contentView?.accessibilityChildren() as? [NSAccessibilityElement] ?? []).elementsEqual(elements, by: { $0 === $1 }))
        foot.show(.notice("Synthetic notice"))
        await timer.untilWaiting()
        look = .light
        await AppearanceCallbackTests.postOffMain()
        #expect(foot.panel.appearance?.name == .aqua)
        #expect(foot.mark.slip == FootSlip(text: "Synthetic notice"))
        #expect(timer.asked == [FootMark.noticeShown])
        timer.end()
        await foot.noticeEnds?.value
        #expect(!foot.showsNotice)
        foot.enabled = false
    }

    /// The landing's steps, each released by the check rather than the
    /// clock: the sun comes up with its start ring, swells once with no ring
    /// of its own, and settles to rest.
    @Test(.timeLimit(.minutes(1))) func setupsSunLandsAsTheSunAndSettlesToRest() async throws {
        let timer = NoticeTimer()
        let foot = Self.foot()
        foot.landingWait = timer.wait
        // No time passes for the sun either, so the swell's ring depends on
        // the landing's steps alone, not on how late the runner is.
        foot.mark.now = { 100 }
        #expect(foot.markFrame != nil)
        foot.receiveSun()
        #expect(foot.mark.phase == .listening)
        #expect(foot.state == .resting)
        #expect(foot.mark.ripples == 1)
        for asked in 1...3 {
            // Bounded, so a step that never begins fails rather than hangs.
            try #require(await eventually { timer.asked.count == asked })
            #expect(foot.mark.phase == .listening)
            timer.end()
        }
        #expect(timer.asked == [.milliseconds(400), .milliseconds(100), .milliseconds(120)])
        #expect(await eventually { foot.mark.phase == .resting })
        #expect(foot.mark.ripples == 1)
    }

    @Test func theDotHidesForTheLandingSunAndShowsUnderItOrForADictation() {
        let foot = Self.foot()
        foot.coverForSun(at: CACurrentMediaTime() + 0.2)
        #expect(foot.covered)
        foot.receiveSun()
        #expect(!foot.covered)
        foot.coverForSun()
        foot.state = .listening
        #expect(!foot.covered)
    }

    @Test(.timeLimit(.minutes(1))) func aCoversFallbackLeavesALaterCoverAlone() async throws {
        let foot = Self.foot()
        foot.coverForSun()
        try await Task.sleep(for: .milliseconds(600))
        foot.uncover()
        foot.coverForSun()
        // The first cover's one-second fallback passes with the second
        // cover still in place.
        try await Task.sleep(for: .milliseconds(600))
        #expect(foot.covered)
        #expect(await eventually { !foot.covered })
    }

    @Test func underTheMoonSetupsSunLeavesTheMarkAtRest() {
        let foot = Self.foot()
        foot.sky = .moon
        foot.receiveSun()
        #expect(foot.mark.phase == .resting)
    }

    @Test(.timeLimit(.minutes(1))) func aDictationStartedAsTheSunLandsKeepsTheMark() async throws {
        let foot = Self.foot()
        foot.receiveSun()
        foot.state = .listening
        try await Task.sleep(for: .milliseconds(700))
        #expect(foot.mark.phase == .listening)
    }

    @Test func theDotSitsAtTheBottomCentreAboveTheDockOrTheScreensEdge() {
        // A Dock that stays shown: the listening sun's 26 points above its
        // top, so no ring falls behind it, centred on 720.
        #expect(FootMark.dotCentre(on: Self.laptop) == CGPoint(x: 720, y: 106))
        #expect(FootMark.frame(on: Self.laptop) == CGRect(x: 540, y: 76, width: 360, height: 96))
        // A Dock set to hide, on the left or right, or a full-screen app:
        // 26 points above the screen's edge, centred on 1440 + 960.
        #expect(FootMark.dotCentre(on: Self.monitor) == CGPoint(x: 2400, y: 26))
        // A Dock on the left narrows the usable area: centred on what is left.
        let left = FootMark.Screen(id: 3, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                   usable: CGRect(x: 80, y: 0, width: 1648, height: 1085))
        #expect(FootMark.dotCentre(on: left) == CGPoint(x: 904, y: 26))
        // A hidden Dock for which macOS keeps a 4 point strip at the foot.
        let strip = FootMark.Screen(id: 4, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                    usable: CGRect(x: 0, y: 4, width: 1728, height: 1080))
        #expect(FootMark.dotCentre(on: strip) == CGPoint(x: 864, y: 30))
        // The words go 20 points above the dot.
        #expect(FootMark.wordsBottom(on: Self.laptop) == 126)
    }

    @Test func bothWindowsSitJustBelowTheDock() {
        let foot = Self.foot()
        // The Dock's level is 20, floating panels' 3 and Raycast's 8; a Dock
        // that slides up from hiding covers the foot and its click target.
        #expect(foot.panel.level.rawValue == 19)
        #expect(foot.target.level.rawValue == 19)
        #expect(foot.panel.ignoresMouseEvents)
        #expect(!foot.panel.canBecomeKey && !foot.target.canBecomeKey)
    }

    @Test func theFootStaysOnTheDisplayADictationOpenedItOn() {
        let desk = Desk()
        let foot = Self.foot(desk)
        #expect(onLaptop(foot))
        foot.state = .listening
        desk.pointer = CGPoint(x: 2000, y: 500)
        foot.state = .writing
        #expect(onLaptop(foot))
        foot.state = .notice("Couldn't write it, so I typed what you said")
        #expect(onLaptop(foot))
        foot.state = .resting
        #expect(onLaptop(foot))
        // The next dictation opens where the pointer is.
        foot.state = .listening
        #expect(onMonitor(foot))
        #expect(!foot.panel.isVisible)
    }

    @Test func switchingAppsMovesOnlyAFootAtRest() {
        let desk = Desk()
        let foot = Self.foot(desk)
        let workspace = NSWorkspace.shared.notificationCenter
        foot.state = .listening
        desk.pointer = CGPoint(x: 2000, y: 500)
        workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        #expect(onLaptop(foot))
        foot.state = .resting
        workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        #expect(onMonitor(foot))
    }

    @Test func aDisplayChangeKeepsADictationsFootOnItsDisplayUnlessThatDisplayIsGone() {
        let desk = Desk()
        let foot = Self.foot(desk)
        foot.state = .listening
        desk.pointer = CGPoint(x: 2000, y: 500)
        // The laptop's Dock moves away: same display, placed again lower.
        desk.screens[0].usable = CGRect(x: 0, y: 0, width: 1440, height: 875)
        foot.screensChanged()
        #expect(foot.panel.frame == FootMark.frame(on: desk.screens[0]))
        // The laptop's lid closes: the foot goes where the pointer is.
        desk.screens = [Self.monitor]
        foot.screensChanged()
        #expect(onMonitor(foot))
    }

    @Test func aPointerOnNoDisplayFallsBackToTheFirst() {
        let screens = [Self.laptop, Self.monitor]
        #expect(FootMark.screen(among: screens, pointer: CGPoint(x: -50, y: -50), keeping: nil) == Self.laptop)
        #expect(FootMark.screen(among: screens, pointer: CGPoint(x: 2000, y: 10), keeping: nil) == Self.monitor)
        #expect(FootMark.screen(among: screens, pointer: CGPoint(x: 2000, y: 10), keeping: 1) == Self.laptop)
        #expect(FootMark.screen(among: [Self.monitor], pointer: CGPoint(x: 10, y: 10), keeping: 1) == Self.monitor)
        #expect(FootMark.screen(among: [], pointer: .zero, keeping: nil) == nil)
    }

    @Test(.timeLimit(.minutes(1))) func aNoticeShowsItsWordsAndRestsAfterAWhile() async throws {
        let timer = NoticeTimer()
        let foot = Self.foot(noticeWait: timer.wait)
        var ended = 0
        foot.noticeEnded = { ended += 1 }
        foot.show(.heardNothing)
        #expect(foot.state == .notice("Intention heard nothing from your microphone"))
        #expect(foot.showsNotice)
        #expect(foot.presentation == .notice("Intention heard nothing from your microphone"))
        // Opened from the dot, inside the window, and nothing to click.
        let words = try #require(foot.slipFrame)
        #expect(words.midY == FootMark.dotInWindow.y)
        #expect(foot.mark.slip == FootSlip(text: "Intention heard nothing from your microphone"))
        #expect(words.minX >= 0 && words.maxX <= FootMark.windowSize.width)
        #expect(foot.target.buttons.isEmpty)
        await timer.untilWaiting()
        #expect(timer.asked == [FootMark.noticeShown])
        #expect(ended == 0)
        timer.end()
        await foot.noticeEnds?.value
        #expect(foot.state == .resting)
        #expect(foot.slipFrame == nil)
        #expect(ended == 1)
        // A dictation started meanwhile ends the notice and keeps the foot on it.
        foot.show(.heardNothing)
        foot.state = .listening
        #expect(ended == 2)
        await timer.untilWaiting()
        timer.end()
        await foot.noticeEnds?.value
        #expect(foot.state == .listening)
    }

    /// The app's own wait, on the continuous clock, rests a notice by
    /// itself. How long it took is not checked: a loaded runner can run the
    /// timer late.
    @Test func aNoticeRestsByItselfOnTheContinuousClock() async {
        let foot = Self.foot()
        foot.show(.heardNothing)
        await foot.noticeEnds?.value
        #expect(foot.state == .resting)
    }

    /// With the caret dot shown, the dot says the words beside the caret, so
    /// the foot says none: a notice and the email's words leave it resting
    /// or warm, and the microphone still shows under the pointer.
    @Test func withTheCaretDotShownTheFootSaysNoWordsButTheHint() {
        let foot = Self.foot(saysWords: false)
        foot.state = .notice("Couldn't write it, so I typed what you said")
        #expect(foot.presentation == .rest)
        #expect(foot.slipFrame == nil)
        #expect(foot.mark.phase == .resting)
        foot.state = .working("Writing your email\u{2026}")
        #expect(foot.presentation == .writing)
        #expect(foot.mark.phase == .writing)
        #expect(foot.slipFrame == nil)
        foot.state = .resting
        foot.hover(true)
        #expect(foot.presentation == .hint)
        #expect(foot.slipFrame == nil)
        #expect(foot.mark.glyph == SunDotView.Glyph(key: "fn"))
    }
}

/// The focused-field rule: the foot paints only where it cannot touch the
/// focused field, and the caret dot carries the red where it does not.
@MainActor
struct FootFieldRuleTests {
    /// A Mac with the Dock at the bottom, its top at 80.
    private let screen = FootPlacementTests.laptop

    @Test func aFieldClearOfTheFootLeavesItPainting() {
        // No field, a window high on the screen, one on another display,
        // and one beside the foot's column.
        #expect(FootMark.isClear(of: nil, on: screen))
        #expect(FootMark.isClear(of: CGRect(x: 200, y: 300, width: 900, height: 400), on: screen))
        #expect(FootMark.isClear(of: CGRect(x: 1600, y: 0, width: 900, height: 60), on: screen))
        #expect(FootMark.isClear(of: CGRect(x: 0, y: 82, width: 500, height: 200), on: screen))
        // Exactly 52 points free between the Dock's top and the field less 8:
        // the listening sun's whole 26 points each side of its centre.
        #expect(FootMark.isClear(of: CGRect(x: 200, y: 140, width: 900, height: 400), on: screen))
    }

    @Test func aComposerAtTheFootLeavesNothingPainted() {
        // Messages or Slack full screen: the composer 6 points above the Dock.
        #expect(!FootMark.isClear(of: CGRect(x: 24, y: 86, width: 1392, height: 36), on: screen))
        // One point short of the room the foot needs.
        #expect(!FootMark.isClear(of: CGRect(x: 200, y: 139, width: 900, height: 400), on: screen))
        // A full-screen app with no Dock: its composer near the screen's edge.
        let fullScreen = FootMark.Screen(id: 5, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                         usable: CGRect(x: 0, y: 0, width: 1440, height: 900))
        #expect(!FootMark.isClear(of: CGRect(x: 0, y: 20, width: 1440, height: 36), on: fullScreen))
        #expect(!FootMark.isClear(of: CGRect(x: 0, y: 59, width: 1440, height: 36), on: fullScreen))
        #expect(FootMark.isClear(of: CGRect(x: 0, y: 60, width: 1440, height: 36), on: fullScreen))
    }

    @Test func theFootHidesWhileTheFieldReachesItAndTellsTheCaretDot() {
        let foot = FootPlacementTests.foot()
        var painting: [Bool] = []
        foot.carriesRedChanged = { painting.append($0) }
        #expect(foot.painting)
        #expect(foot.carriesRed)
        #expect(foot.markFrame != nil)
        foot.focusedField = CGRect(x: 24, y: 86, width: 1392, height: 36)
        #expect(!foot.painting)
        #expect(foot.markFrame == nil)
        #expect(foot.target.buttons.isEmpty)
        // No mark and no hint while hidden.
        foot.hover(true)
        #expect(foot.target.buttons.isEmpty)
        foot.focusedField = CGRect(x: 200, y: 300, width: 900, height: 400)
        #expect(foot.painting)
        #expect(painting == [false, true])
    }

    /// A field beside the foot's column clears the dot but not a long
    /// notice's slip: the dot paints, and the slip stays closed.
    @Test func aSlipThatWouldReachTheFieldStaysClosed() throws {
        let foot = FootPlacementTests.foot()
        foot.state = .notice("Intention heard nothing from your microphone")
        let slip = try #require(foot.slipFrame).offsetBy(dx: foot.panel.frame.minX, dy: foot.panel.frame.minY)
        // Where the dot rests, not where the open slip has moved it.
        let rest = foot.panel.frame.minX + FootMark.dotInWindow.x
        #expect(slip.maxX > rest + FootMark.column + FootMark.margin)
        foot.focusedField = CGRect(x: rest + FootMark.column, y: 60, width: 400, height: 400)
        #expect(foot.painting)
        #expect(foot.slipFrame == nil)
        #expect(foot.mark.slip == nil)
        // Just past the paper, the float's shadow would still reach it.
        foot.focusedField = CGRect(x: slip.maxX + FootMark.margin + 1, y: 60, width: 400, height: 400)
        #expect(foot.slipFrame == nil)
        // The field moves clear of the shadow too: the slip opens again.
        foot.focusedField = CGRect(x: slip.maxX + FootSlip.shadowReach + FootMark.margin + 1, y: 60, width: 400, height: 400)
        #expect(foot.slipFrame != nil)
    }

    /// A Dock set to hide that the pointer may have brought up over the
    /// sun: the caret dot carries the red until the pointer leaves, read on
    /// the next chunk of the voice.
    @Test func aDockThatMayCoverTheSunPutsTheRedBackOnTheCaretDot() {
        let desk = FootPlacementTests.Desk()
        desk.screens = [FootPlacementTests.monitor]
        desk.pointer = CGPoint(x: 2400, y: 40)
        let foot = FootPlacementTests.foot(desk)
        var clock = ContinuousClock.now
        foot.now = { clock }
        var carries: [Bool] = []
        foot.carriesRedChanged = { carries.append($0) }
        foot.state = .listening
        #expect(foot.painting)
        #expect(!foot.carriesRed)
        // The pointer leaves; the Dock may still be sliding down.
        desk.pointer = CGPoint(x: 2400, y: 600)
        clock += .milliseconds(500)
        foot.level = 0.2
        #expect(!foot.carriesRed)
        clock += FootMark.dockHides
        foot.level = 0.3
        #expect(foot.carriesRed)
        #expect(carries == [true])
        // A Dock that stays shown takes room of its own and never covers it.
        #expect(!FootMark.dockMayCover(on: FootPlacementTests.laptop, pointer: CGPoint(x: 720, y: 20)))
        #expect(FootMark.dockMayCover(on: FootPlacementTests.monitor, pointer: CGPoint(x: 2400, y: 20)))
        #expect(!FootMark.dockMayCover(on: FootPlacementTests.monitor, pointer: CGPoint(x: 700, y: 20)))
    }

    @Test func theCaretDotStaysInkWhileTheFootsSunIsRed() {
        #expect(DictationIndicators.dotLook(phase: .recording, proposal: .idle, footCarriesRed: true) == .heard)
        #expect(DictationIndicators.dotLook(phase: .recording, proposal: .idle, footCarriesRed: false) == .recording)
        // Only a recording: the pulse and rest are the same either way.
        #expect(DictationIndicators.dotLook(phase: .processing, proposal: .idle, footCarriesRed: true) == .working)
        #expect(DictationIndicators.dotLook(phase: .idle, proposal: .idle, footCarriesRed: true) == .resting)
        // Full ink, with no halo.
        let dot = DotMarkView()
        dot.look = .heard
        #expect(dot.currentFill == DotMarkView.proposed(ink: nil).cgColor)
    }

    /// Under the pointer the dot turns into the microphone, with no word and
    /// no key, and while listening shows only the sun; it waits `hoverDelay`
    /// before turning, so a pointer passing over it does not.
    @Test(.timeLimit(.minutes(1))) func theDotTurnsIntoTheMicrophoneOnlyOnceThePointerRests() async throws {
        let foot = FootPlacementTests.foot()
        foot.hoverDelay = .milliseconds(150)
        foot.hover(true)
        #expect(foot.mark.glyph == nil)
        foot.hover(false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(foot.mark.glyph == nil)
        foot.hover(true)
        #expect(await eventually { foot.mark.glyph != nil })
        #expect(foot.mark.glyph == SunDotView.Glyph(key: "fn"))
        #expect(foot.mark.slip == nil)
        foot.state = .listening
        #expect(foot.mark.glyph == nil)
        #expect(foot.mark.slip == nil)
        #expect(foot.mark.phase == .listening)
        foot.hover(false)
        foot.hover(true)
        #expect(foot.presentation == .listening)
        #expect(foot.mark.glyph == nil)
    }

    /// The listening sun is its own stop button: a click stops the
    /// dictation and VoiceOver calls it Stop dictating, with Cancel
    /// dictation beside it. A reconnecting microphone still takes the
    /// slip's words over the sun.
    @Test func theListeningSunStopsAndAReconnectingMicrophoneOpensTheSlip() throws {
        let foot = FootPlacementTests.foot()
        var actions: [FootAction] = []
        foot.onAction = { actions.append($0) }
        foot.state = .listening
        foot.hover(true)
        #expect(foot.mark.slip == nil)
        let sun = try #require(foot.markFrame)
        foot.target.click(at: CGPoint(x: sun.midX - foot.target.frame.minX, y: sun.midY - foot.target.frame.minY))
        #expect(actions == [.done])
        #expect(foot.target.buttons.map(\.name) == ["Stop dictating"])
        foot.recordingIssue = "Reconnecting microphone\u{2026}"
        #expect(foot.mark.slip == FootSlip(text: "Reconnecting microphone\u{2026}"))
    }

    /// The email being written is the warm sun's to say, with no slip, and
    /// the working sun shows nothing under the pointer: a click on it does
    /// nothing and VoiceOver offers no button there. The click target stays
    /// on the dot's square.
    @Test(arguments: [false, true])
    func theWorkingSunShowsNothingAndAClickOnItDoesNothing(_ still: Bool) throws {
        let foot = FootPlacementTests.foot()
        foot.mark.reducesMotion = { still }
        var actions: [FootAction] = []
        foot.onAction = { actions.append($0) }
        foot.state = .working("Writing your email\u{2026}")
        #expect(foot.presentation == .writing)
        #expect(foot.slipFrame == nil)
        #expect(foot.mark.slip == nil)
        let square = try #require(foot.markFrame)
        #expect(foot.target.frame == square.integral)
        foot.hover(true)
        #expect(foot.presentation == .writing)
        #expect(foot.mark.glyph == nil)
        foot.target.click(at: CGPoint(x: square.midX - foot.target.frame.minX, y: square.midY - foot.target.frame.minY))
        foot.target.click(at: CGPoint(x: square.midX - foot.target.frame.minX, y: square.midY - foot.target.frame.minY))
        #expect(foot.presentation == .writing)
        #expect(foot.mark.glyph == nil)
        #expect(foot.target.frame == square.integral)
        #expect(foot.target.buttons.isEmpty)
        #expect(actions.isEmpty)
    }

    /// A pointer that rests on the foot just as a field hides it has left
    /// it: the slip does not open behind the field, nor once the field goes.
    @Test(.timeLimit(.minutes(1))) func aHoverPendingWhenTheFootHidesNeverOpens() async throws {
        let foot = FootPlacementTests.foot()
        foot.hoverDelay = .milliseconds(150)
        foot.hover(true)
        foot.focusedField = CGRect(x: 200, y: 80, width: 900, height: 400)
        #expect(!foot.painting)
        try await Task.sleep(for: .milliseconds(400))
        foot.focusedField = nil
        #expect(foot.painting)
        #expect(foot.mark.slip == nil)
        #expect(foot.presentation == .rest)
    }

    /// A slip that opens with no pointer over it, for a microphone
    /// reconnecting, moves the sun to its end; the
    /// click target, VoiceOver's button and a popup's anchor go with it, and
    /// keep the sun while the slip closes, with or without Reduce Motion.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func anAutomaticSlipKeepsTheMovedSunClickable(_ still: Bool) async throws {
        let opens: [(String, @MainActor (FootMark) -> Void, @MainActor (FootMark) -> Void)] = [
            ("reconnecting", { $0.state = .listening; $0.recordingIssue = "Reconnecting microphone\u{2026}" }, { $0.recordingIssue = nil }),
        ]
        for (name, open, close) in opens {
            let foot = FootPlacementTests.foot()
            foot.mark.reducesMotion = { still }
            var actions: [FootAction] = []
            foot.onAction = { actions.append($0) }
            open(foot)
            let slip = try #require(foot.slipFrame, "\(name)")
            let inWindow = foot.mark.convert(foot.mark.dotCentre, to: foot.panel.contentView)
            let sun = CGPoint(x: inWindow.x + foot.panel.frame.minX, y: inWindow.y + foot.panel.frame.minY)
            #expect(sun.x < foot.panel.frame.minX + FootMark.dotInWindow.x - FootMark.reach / 2, "\(name): the sun has moved")
            #expect(foot.target.frame.contains(sun), "\(name)")
            #expect(foot.target.frame.contains(slip.offsetBy(dx: foot.panel.frame.minX, dy: foot.panel.frame.minY).integral), "\(name)")
            #expect(foot.target.buttons.first?.frame.contains(sun) == true, "\(name)")
            #expect(try #require(foot.markFrame).midX == sun.x, "\(name)")
            // Closing, the sun keeps its clicks until it is home.
            close(foot)
            #expect(foot.slipFrame == nil, "\(name)")
            #expect(foot.target.frame.contains(sun), "\(name)")
            let rest = try #require(foot.markFrame)
            #expect(await eventually { foot.target.frame == rest.integral }, "\(name)")
            // Open again, a click on the moved sun is a click on the foot,
            // which stops the dictation.
            open(foot)
            foot.target.click(at: CGPoint(x: sun.x - foot.target.frame.minX, y: sun.y - foot.target.frame.minY))
            #expect(actions == [.done])
        }
    }

    private func click(_ foot: FootMark) {
        foot.target.click(at: CGPoint(x: foot.target.frame.width / 2, y: foot.target.frame.height / 2))
    }

    /// The click target is the dot's square at rest and grows to the pill
    /// while the pill shows, so a click anywhere on the pill dictates; the
    /// tooltip above it takes no clicks, and the target is the square again
    /// once the pill folds.
    @Test(.timeLimit(.minutes(1))) func theTargetCoversTheDotAndThePill() async throws {
        let foot = FootPlacementTests.foot()
        foot.mark.reducesMotion = { false }
        let dot = try #require(foot.markFrame)
        #expect(foot.target.frame == dot.integral)
        #expect(dot.width == FootMark.reach && dot.midX == 720 && dot.midY == 106)
        foot.hover(true)
        #expect(foot.mark.glyph == SunDotView.Glyph(key: "fn"))
        #expect(foot.markFrame == dot)
        #expect(foot.target.frame.contains(dot))
        #expect(foot.target.frame.contains(FootPlacementTests.glyphOnScreen(foot)))
        let tip = try #require(FootPlacementTests.tooltipOnScreen(foot))
        #expect(!foot.target.frame.intersects(tip))
        let withPill = foot.target.frame
        foot.hover(false)
        #expect(await AppearanceCallbackTests.eventually { foot.mark.glyph == nil })
        // The folding pill keeps its clicks until it is the dot again.
        #expect(foot.target.frame == withPill)
        #expect(await AppearanceCallbackTests.eventually { foot.target.frame == dot.integral })
        foot.hover(true)
        // A notice has nothing to click, so nothing takes the mouse.
        foot.show(.notice("Pasted it, which replaced what you'd copied"))
        #expect(foot.target.buttons.isEmpty)
    }

    /// Reduce Motion turned on while the pill folds ends the fold at once,
    /// and the target is the dot's square again with it.
    @Test(.timeLimit(.minutes(1))) func reduceMotionMidFoldGivesBackTheSquare() async throws {
        var still = false
        let foot = FootPlacementTests.foot()
        foot.mark.reducesMotion = { still }
        let dot = try #require(foot.markFrame)
        foot.hover(true)
        let withPill = foot.target.frame
        #expect(withPill.height > dot.height)
        foot.hover(false)
        #expect(await AppearanceCallbackTests.eventually { foot.mark.glyph == nil })
        #expect(foot.target.frame == withPill)
        still = true
        foot.mark.displayOptionsChanged()
        #expect(!foot.mark.glyphDrawing.shown)
        #expect(foot.target.frame == dot.integral)
    }

    @Test func aClickOnTheDotShowsTheHintAClickOnTheHintStartsAndOneOnTheSunEnds() {
        let foot = FootPlacementTests.foot()
        var actions: [FootAction] = []
        foot.onAction = { actions.append($0) }
        click(foot)
        #expect(actions.isEmpty)
        #expect(foot.presentation == .hint)
        click(foot)
        #expect(actions == [.start])
        foot.state = .listening
        click(foot)
        #expect(actions == [.start, .done])
        // Working, the warm sun says so and a click on it does nothing;
        // once the text is in, a click on the dot shows the microphone again.
        foot.state = .writing
        #expect(foot.presentation == .writing)
        click(foot)
        #expect(foot.presentation == .writing)
        #expect(actions == [.start, .done])
        foot.state = .resting
        click(foot)
        #expect(foot.presentation == .hint)
        click(foot)
        #expect(actions == [.start, .done, .start])
        #expect(!foot.target.isKeyWindow)
    }

    @Test func theMicrophoneShowsUnderThePointerAtRestOnlyAndGoesAMomentAfterIt() async {
        let foot = FootPlacementTests.foot()
        #expect(foot.presentation == .rest)
        foot.hover(true)
        #expect(foot.presentation == .hint)
        // The pointer leaves and comes back within the grace: it stays.
        foot.hover(false)
        foot.hover(true)
        try? await Task.sleep(for: FootMark.hoverGrace + .milliseconds(150))
        #expect(foot.presentation == .hint)
        foot.hover(false)
        let deadline = ContinuousClock.now + FootMark.hoverGrace + .seconds(3)
        while foot.presentation != .rest, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(foot.presentation == .rest)
        // Listening, the sun shows nothing more under the pointer.
        foot.state = .listening
        #expect(foot.presentation == .listening)
        foot.hover(true)
        #expect(foot.presentation == .listening)
        #expect(foot.slipFrame == nil)
        #expect(foot.mark.glyph == nil)
        // Nor does the warm sun while the text is on its way.
        foot.state = .writing
        #expect(foot.presentation == .writing)
        foot.hover(true)
        #expect(foot.presentation == .writing)
        #expect(foot.mark.glyph == nil)
    }

    @Test func hidingTheFootForgetsTheHintAndShowingItAsksThePointerAgain() {
        let desk = FootPlacementTests.Desk()
        let foot = FootPlacementTests.foot(desk)
        foot.hover(true)
        #expect(foot.presentation == .hint)
        foot.enabled = false
        desk.pointer = CGPoint(x: 100, y: 600)
        foot.enabled = true
        #expect(foot.presentation == .rest)
        desk.pointer = CGPoint(x: foot.target.frame.midX, y: foot.target.frame.midY)
        foot.enabled = false
        foot.enabled = true
        #expect(foot.presentation == .hint)
    }

    /// A pointer still over the foot when a recording stops sees the warm
    /// sun while the text goes in, then the microphone once it has, and the
    /// first click starts the next dictation.
    @Test func aPointerStillOverTheFootWhenARecordingStopsSeesTheSunThenTheMicrophone() {
        let desk = FootPlacementTests.Desk()
        let foot = FootPlacementTests.foot(desk)
        var actions: [FootAction] = []
        foot.onAction = { actions.append($0) }
        foot.state = .listening
        desk.pointer = CGPoint(x: foot.target.frame.midX, y: foot.target.frame.midY)
        foot.state = .writing
        #expect(foot.presentation == .writing)
        #expect(foot.mark.glyph == nil)
        foot.state = .resting
        #expect(foot.presentation == .hint)
        #expect(foot.mark.glyph == SunDotView.Glyph(key: "fn"))
        click(foot)
        #expect(actions == [.start])
    }

    /// The click path the pill's cancel and done buttons served: the
    /// microphone starts a dictation and a click on the sun finishes it,
    /// under the pointer or not, with nothing more shown. Escape cancels;
    /// see `escapeCancelsADictationStartedFromTheFoot`.
    @Test func aClickedDictationEndsWithAClickOnTheSun() async throws {
        let desk = FootPlacementTests.Desk()
        let foot = FootPlacementTests.foot(desk)
        var actions: [FootAction] = []
        foot.onAction = { actions.append($0) }
        desk.pointer = CGPoint(x: foot.target.frame.midX, y: foot.target.frame.midY)
        foot.hover(true)
        click(foot)
        #expect(actions == [.start])
        foot.state = .listening
        #expect(foot.presentation == .listening)
        #expect(foot.slipFrame == nil)
        #expect(foot.target.buttons.map(\.name) == ["Stop dictating"])
        click(foot)
        #expect(actions == [.start, .done])
        // Away from the pointer, the bare sun takes the same click.
        desk.pointer = CGPoint(x: 100, y: 600)
        foot.hover(false)
        let deadline = ContinuousClock.now + FootMark.hoverGrace + .seconds(3)
        while foot.presentation != .listening, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(foot.presentation == .listening)
        #expect(foot.slipFrame == nil)
        click(foot)
        #expect(actions == [.start, .done, .done])
    }

    /// A placement that moves the slip into the field, as a Dock that
    /// starts staying shown does, closes it there and then.
    @Test func aPlacementThatMovesTheSlipIntoTheFieldClosesIt() throws {
        let desk = FootPlacementTests.Desk()
        desk.screens = [FootMark.Screen(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                        usable: CGRect(x: 0, y: 0, width: 1440, height: 875))]
        let foot = FootPlacementTests.foot(desk)
        foot.state = .notice("Intention heard nothing from your microphone")
        // Beside the column, clear above the slip and its shadow at the
        // screen's edge, and in their way once the Dock lifts the foot.
        foot.focusedField = CGRect(x: 720 + FootMark.column, y: 80, width: 400, height: 400)
        #expect(foot.slipFrame != nil)
        desk.screens[0].usable = CGRect(x: 0, y: 80, width: 1440, height: 795)
        foot.screensChanged()
        #expect(foot.painting)
        #expect(foot.slipFrame == nil)
        #expect(foot.mark.slip == nil)
    }

    @Test func voiceOverFindsDictateAndWhileListeningStopDictatingWithCancelBeside() throws {
        let foot = FootPlacementTests.foot()
        var actions: [FootAction] = []
        foot.onAction = { actions.append($0) }
        func buttons() throws -> [NSAccessibilityElement] {
            let view = try #require(foot.target.contentView)
            return (view.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
        }
        #expect(try buttons().map { $0.accessibilityLabel() } == ["Dictate"])
        #expect(try buttons().map { $0.accessibilityHelp() } == ["fn"])
        // A new key reaches the element VoiceOver already has.
        let kept = try #require(try buttons().first)
        foot.keyName = { "Right Option" }
        foot.hover(true)
        #expect(try buttons().first === kept)
        #expect(kept.accessibilityHelp() == "Right Option")
        foot.hover(false)
        #expect(try buttons().allSatisfy { $0.accessibilityRole() == .button })
        _ = try buttons().first?.accessibilityPerformPress()
        foot.state = .listening
        let done = try #require(try buttons().first)
        #expect(done.accessibilityLabel() == "Stop dictating")
        let cancel = try #require(done.accessibilityCustomActions()?.first)
        #expect(cancel.name == "Cancel dictation")
        _ = done.accessibilityPerformPress()
        _ = (cancel.target as? NSObject)?.perform(cancel.selector, with: cancel)
        #expect(actions == [.start, .done, .cancel])
        foot.state = .writing
        #expect(try buttons().isEmpty)
        // Replaced: the old Done and its Cancel press nothing.
        #expect(!done.accessibilityPerformPress())
        foot.enabled = false
        #expect(try buttons().isEmpty)
        #expect(actions == [.start, .done, .cancel])
    }

    /// Accessibility may press from any queue: Done and Cancel dictation
    /// reach the main actor there, without a trap, and a button replaced
    /// meanwhile presses nothing.
    @Test(.timeLimit(.minutes(1))) func voiceOversPressesFromABackgroundQueueReachTheMainActor() async throws {
        let foot = FootPlacementTests.foot()
        var actions: [FootAction] = []
        foot.state = .listening
        let view = try #require(foot.target.contentView)
        let done = try #require(view.accessibilityChildren()?.first as? NSAccessibilityElement)
        let cancel = try #require(done.accessibilityCustomActions()?.first)
        final class Sent: @unchecked Sendable {
            let done: NSAccessibilityElement
            let cancel: NSAccessibilityCustomAction
            init(_ done: NSAccessibilityElement, _ cancel: NSAccessibilityCustomAction) { self.done = done; self.cancel = cancel }
        }
        let sent = Sent(done, cancel)
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            foot.onAction = { action in
                MainActor.assertIsolated()
                actions.append(action)
                if actions.count == 2 { finished.resume() }
            }
            DispatchQueue.global().async {
                _ = sent.done.accessibilityPerformPress()
                _ = (sent.cancel.target as? NSObject)?.perform(sent.cancel.selector, with: sent.cancel)
            }
        }
        #expect(actions == [.done, .cancel])
        // Replaced by the working foot's Dictate: a late press is dropped.
        foot.state = .writing
        DispatchQueue.global().async { _ = sent.done.accessibilityPerformPress() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(actions == [.done, .cancel])
    }

    @Test func aButtonVoiceOverKeptStillPressesAfterTheFootIsPlacedAgain() throws {
        let desk = FootPlacementTests.Desk()
        let foot = FootPlacementTests.foot(desk)
        var actions: [FootAction] = []
        foot.onAction = { actions.append($0) }
        foot.state = .listening
        let view = try #require(foot.target.contentView)
        let done = try #require(view.accessibilityChildren()?.first as? NSAccessibilityElement)
        let before = done.accessibilityFrame()
        desk.screens[0].usable = CGRect(x: 0, y: 120, width: 1440, height: 755)
        foot.screensChanged()
        #expect(view.accessibilityChildren()?.first as? NSAccessibilityElement === done)
        #expect(done.accessibilityFrame() != before)
        #expect(done.accessibilityPerformPress())
        #expect(actions == [.done])
    }
}

/// The sun dot's states and what runs in each: nothing at rest, the voice
/// and a breath in silence while listening, the breath while writing.
@MainActor
struct SunDotTests {
    private func mark(still: Bool = false) -> SunDotView {
        let mark = SunDotView(frame: CGRect(x: 0, y: 0, width: SunDotView.side, height: SunDotView.side))
        mark.reducesMotion = { still }
        return mark
    }

    /// The microphone fits the 26-point envelope at 14.5 by 18 points or
    /// so, with the capsule 7 by 11 and its corners half its width, and
    /// its straight edges on whole pixels: at 2x every edge of the capsule,
    /// the stem and the foot, at 1x the capsule's and one edge of the stem
    /// and of the foot, since a pen of 1.5 pixels has one soft side.
    @Test(arguments: [CGFloat(1), 2])
    func theMicrophoneFitsTheEnvelopeOnWholePixels(_ scale: CGFloat) {
        let shape = MicGlyph.shape(scale: scale)
        let bounds = shape.bounds
        let envelope = SunDotView.envelope
        #expect(bounds.minX >= -envelope && bounds.maxX <= envelope && bounds.minY >= -envelope && bounds.maxY <= envelope)
        #expect(abs(bounds.width - 14.5) <= 0.5 && abs(bounds.height - 18) <= 0.5)
        #expect(shape.head.size == CGSize(width: 7, height: 11))
        func whole(_ value: CGFloat) -> Bool { (value * scale).rounded() == value * scale }
        #expect(whole(shape.head.minX) && whole(shape.head.maxX) && whole(shape.head.minY) && whole(shape.head.maxY))
        let half = MicGlyph.pen / 2
        #expect(whole(shape.foot.left.y - half))
        #expect(whole(shape.stem.top.x - half))
        if scale == 2 { #expect(whole(shape.foot.left.y + half) && whole(shape.stem.top.x + half)) }
        // The stem stands on the foot, under the cradle's bottom, and
        // within a quarter point of the capsule's middle.
        #expect(shape.stem.bottom.y == shape.foot.left.y)
        #expect(shape.stem.top.y == shape.cradleCentre.y + MicGlyph.cradleRadius)
        #expect(abs(shape.stem.top.x - shape.head.midX) <= 0.25)
        // The cradle leaves the same gap under the capsule as beside it.
        let side = MicGlyph.cradleRadius - half - shape.head.width / 2
        let under = shape.cradleCentre.y + MicGlyph.cradleRadius - half - shape.head.maxY
        #expect(side == under)
    }

    /// Under the pointer the dot's own circle grows into the 24 by 34 pill,
    /// centred on it, with the capsule and the strokes drawing in after it
    /// and the tooltip set to show; the dot gives way to the pill and comes
    /// back when it folds.
    @Test(.timeLimit(.minutes(1))) func theDotsCircleGrowsIntoThePillAndComesBack() async throws {
        let mark = mark()
        #expect(mark.restShown)
        mark.glyph = SunDotView.Glyph(key: "fn")
        #expect(mark.glyphDrawing.shown)
        #expect(!mark.restShown)
        let pill = CGRect(x: -12, y: -17, width: 24, height: 34)
        let morph = try #require(mark.pillMorph)
        #expect(morph.from == CGRect(x: -SunDotView.restWidth / 2, y: -SunDotView.restWidth / 2,
                                     width: SunDotView.restWidth, height: SunDotView.restWidth))
        #expect(morph.to == pill)
        #expect(mark.glyphDrawing.pill == pill)
        #expect(mark.glyphDrawing.head == mark.glyphDrawing.shape.head)
        #expect(mark.glyphDrawing.strokes == [1, 1, 1])
        #expect(mark.glyphDrawing.tooltip != nil)
        mark.glyph = nil
        #expect(try #require(mark.pillMorph).to.width == SunDotView.restWidth)
        #expect(mark.glyphDrawing.shown)
        #expect(mark.glyphDrawing.tooltip == nil)
        #expect(await eventually { !mark.glyphDrawing.shown && mark.restShown })
        #expect(mark.glyphDrawing.strokes == [0, 0, 0])
    }

    /// The pill with its hairline stays inside the 26-point envelope round
    /// the dot, so it stands no lower than the dot's floor allows, and the
    /// microphone sits in its middle.
    @Test func thePillStaysInsideTheEnvelope() throws {
        let mark = mark(still: true)
        mark.glyph = SunDotView.Glyph(key: "fn")
        let pill = try #require(mark.glyphDrawing.pill).insetBy(dx: -SunDotView.restEdge, dy: -SunDotView.restEdge)
        let envelope = SunDotView.envelope
        #expect(pill.minX >= -envelope && pill.maxX <= envelope && pill.minY >= -envelope && pill.maxY <= envelope)
        let glyph = mark.glyphDrawing.shape.bounds
        #expect(abs(glyph.midX) <= 0.5 && abs(glyph.midY) <= 0.5)
        #expect(pill.contains(glyph))
    }

    /// The tooltip reads Dictate and then a cap for each key of the chosen
    /// shortcut, one for fn or a single modifier and two for Control +
    /// Option, 4 points apart as Settings shows them, at the slip's height.
    @Test func theTooltipDrawsDictateAndACapForEachKey() {
        let fn = FootSlip.tooltipWords("fn", dark: false, scale: 2)
        let option = FootSlip.tooltipWords("right option", dark: false, scale: 2)
        let both = FootSlip.tooltipWords("Control + Option", dark: false, scale: 2)
        let control = FootSlip.tooltipWords("Control", dark: false, scale: 2)
        let alone = FootSlip.tooltipWords("Option", dark: false, scale: 2)
        #expect(fn.image != nil && both.image != nil)
        #expect(fn.size.height == FootSlip.height && both.size.height == FootSlip.height)
        #expect(option.size.width > fn.size.width)
        // The word and its gap, counted once in each width.
        let words = control.size.width + 4 + alone.size.width - both.size.width
        #expect(words > 40 && words < 64)
    }

    /// The longest shortcut's tooltip fits the foot's window at every slot,
    /// one cap per key, the modifiers by their symbols where their names
    /// would not fit.
    @Test(arguments: FootSlot.allCases)
    func theLongestShortcutsTooltipFitsTheWindow(_ slot: FootSlot) {
        let room = FootMark.tooltipRoom(for: slot)
        let fitting = room.maxX - room.minX - 2 * SunDotView.tooltipPadding
        let longest = FootSlip.tooltipWords("Control + Option + Shift + Command", dark: false, scale: 2, fitting: fitting)
        #expect(longest.size.width <= fitting)
        // Four caps of at least 20 points, 4 apart, after the word.
        let words = FootSlip.tooltipWords("Control", dark: false, scale: 2).size.width
            - FootSlip.tooltipWords("Control + Option", dark: false, scale: 2).size.width
            + FootSlip.tooltipWords("Option", dark: false, scale: 2).size.width + 4
        #expect(longest.size.width >= words + 4 * 20 + 3 * 4)
        // A short one keeps its names.
        #expect(FootSlip.tooltipWords("Control + Option", dark: false, scale: 2, fitting: fitting).size
                == FootSlip.tooltipWords("Control + Option", dark: false, scale: 2).size)
    }

    /// Reduce Motion turned on while the pill grows or folds settles it at
    /// once: grown, it is whole; folding, the dot is back.
    @Test func reduceMotionTurnedOnMidMorphSettlesTheGlyph() async {
        var still = false
        let mark = SunDotView(frame: CGRect(x: 0, y: 0, width: SunDotView.side, height: SunDotView.side))
        mark.reducesMotion = { still }
        mark.glyph = SunDotView.Glyph(key: "fn")
        #expect(mark.isAnimating)
        still = true
        // Called off the main thread, as the notification center may.
        nonisolated(unsafe) let view = mark
        await AppearanceCallbackTests.offMain { view.displayOptionsChanged() }
        #expect(await eventually { !mark.isAnimating })
        #expect(mark.glyphDrawing.shown && mark.glyphDrawing.strokes == [1, 1, 1])
        #expect(mark.glyphDrawing.tooltip != nil)
        still = false
        mark.glyph = nil
        // Folding: the glyph is gone but the pill still shows over the dot.
        // Read from the model, since an off-screen layer can drop the fold's
        // animations at the transaction's commit.
        #expect(mark.glyphDrawing.shown && !mark.restShown)
        still = true
        mark.displayOptionsChanged()
        #expect(!mark.isAnimating)
        #expect(!mark.glyphDrawing.shown && mark.restShown)
        #expect(mark.glyphDrawing.tooltip == nil)
    }

    /// The display's scale changing while the pill grows puts the capsule
    /// on the new pixels.
    @Test func aScaleChangeMidMorphPutsTheCapsuleOnTheNewPixels() {
        let mark = mark()
        mark.glyph = SunDotView.Glyph(key: "fn")
        mark.backingScale = 1
        #expect(mark.glyphDrawing.head == MicGlyph.shape(scale: 1).head)
        #expect(MicGlyph.shape(scale: 1).head != MicGlyph.shape(scale: 2).head)
    }

    /// Under Reduce Motion the pill and the dot swap, with nothing moving,
    /// and the tooltip shows or goes with the pill.
    @Test func underReduceMotionThePillAndTheDotSwap() {
        let mark = mark(still: true)
        mark.glyph = SunDotView.Glyph(key: "fn")
        #expect(mark.glyphDrawing.shown && !mark.restShown)
        #expect(mark.pillMorph == nil)
        #expect(mark.glyphDrawing.strokes == [1, 1, 1])
        #expect(mark.glyphDrawing.tooltip != nil)
        mark.glyph = SunDotView.Glyph(key: "fn", tooltip: false)
        #expect(mark.glyphDrawing.shown && mark.glyphDrawing.tooltip == nil)
        mark.glyph = nil
        #expect(!mark.glyphDrawing.shown && mark.restShown)
        #expect(mark.glyphDrawing.tooltip == nil)
    }

    /// The tooltip stands 6 points above the pill, centred over it where
    /// there is room and held inside its room where there is not, as at a
    /// side slot. A dot taken in the hand drops the pill at once.
    @Test(arguments: [-CGFloat.infinity, CGFloat(4)])
    func theTooltipStandsAboveThePillInsideItsRoom(_ left: CGFloat) throws {
        let mark = mark(still: true)
        mark.tooltipRoom = (left, .infinity)
        mark.glyph = SunDotView.Glyph(key: "fn")
        let tip = try #require(mark.glyphDrawing.tooltip)
        let centre = mark.glyphCentre
        #expect(tip.height == SunDotView.tooltipHeight)
        #expect(abs(centre.y - SunDotView.pillSize.height / 2 - SunDotView.tooltipGap - tip.maxY) <= 0.5)
        if left.isFinite {
            #expect(abs(tip.minX - left) <= 0.5 && tip.midX > centre.x)
        } else {
            #expect(abs(tip.midX - centre.x) <= 0.5)
        }
        mark.tooltipRoom = (-.infinity, centre.x + 4)
        let moved = try #require(mark.glyphDrawing.tooltip)
        #expect(abs(moved.maxX - (centre.x + 4)) <= 0.5)
        mark.closeSlipAtOnce()
        #expect(mark.glyph == nil)
        #expect(!mark.glyphDrawing.shown && mark.restShown)
        #expect(mark.glyphDrawing.tooltip == nil)
    }

    @Test func nothingRunsAtRestAndEachBreathRunsOnlyInItsPhase() {
        let mark = mark()
        #expect(!mark.isAnimating)
        mark.phase = .listening
        #expect(mark.isBreathingInSilence)
        #expect(!mark.isBreathing)
        mark.phase = .writing
        #expect(mark.isBreathing)
        #expect(!mark.isBreathingInSilence)
        mark.phase = .resting
        #expect(!mark.isBreathing)
        #expect(!mark.isBreathingInSilence)
        mark.phase = .writing
        mark.phase = .listening
        #expect(!mark.isBreathing)
        #expect(mark.isBreathingInSilence)
    }

    /// The whole listening sun, its loudest bloom and its last ring, fits
    /// between the foot's floor and the lowest focused field the foot still
    /// paints under, less the field's margin: 26 points each side of its
    /// centre, which rests 26 above the floor and needs 52 clear.
    @Test func theListeningSunFitsBetweenTheFloorAndTheField() {
        #expect(SunDotView.reach > 25 && SunDotView.reach <= 26)
        #expect(FootMark.aboveDock == 26 && FootMark.aboveEdge == 26)
        #expect(FootMark.clearance == 52)
        // Below the centre: never past the Dock's top or the screen's edge.
        #expect(FootMark.aboveDock - SunDotView.reach >= 0)
        // Above it: never into a field starting where the foot still paints.
        let lowestField = FootMark.clearance + FootMark.margin - FootMark.aboveEdge
        #expect(SunDotView.reach <= lowestField - FootMark.margin)
        // And inside the foot's window, below and above.
        #expect(SunDotView.reach <= FootMark.dotInWindow.y)
    }

    /// The slip opens evenly round where the dot rests at the bottom, and
    /// along the foot toward the screen's middle at a side, the dot's room at
    /// its outer end.
    @Test func theSlipOpensFromTheCentreOrTowardTheMiddle() throws {
        let mark = mark()
        let centre = CGPoint(x: mark.bounds.midX, y: mark.bounds.midY)
        let slip = FootSlip(text: "Dictate", key: "fn")
        mark.slip = slip
        let middle = try #require(mark.slipFrame)
        #expect(middle.midX == centre.x && middle.midY == centre.y)
        #expect(middle.height == FootSlip.height && middle.width > FootSlip.height * 2)
        mark.slip = nil
        #expect(mark.slipFrame == nil)
        mark.opening = .rightward
        mark.slip = slip
        #expect(try #require(mark.slipFrame).minX == centre.x - FootSlip.dotRoom / 2)
        mark.opening = .leftward
        #expect(try #require(mark.slipFrame).maxX == centre.x + FootSlip.dotRoom / 2)
    }

    /// The dot stays in the open slip, at its left end at the bottom and
    /// the left slot and at its right end at the right slot, and is back at
    /// its resting centre once the slip closes.
    @Test func theDotSitsAtTheSlipsEndCountedFromItsSlot() throws {
        let mark = mark()
        let home = CGPoint(x: mark.bounds.midX, y: mark.bounds.midY)
        mark.slip = FootSlip(text: "Dictate", key: "fn")
        var frame = try #require(mark.slipFrame)
        #expect(mark.dotCentre == CGPoint(x: frame.minX + FootSlip.dotRoom / 2, y: home.y))
        mark.opening = .leftward
        frame = try #require(mark.slipFrame)
        #expect(mark.dotCentre == CGPoint(x: frame.maxX - FootSlip.dotRoom / 2, y: home.y))
        #expect(mark.dotCentre.x == home.x)
        mark.opening = .rightward
        #expect(mark.dotCentre.x == home.x)
        mark.slip = nil
        #expect(mark.dotCentre == home)
    }

    /// Laid out again with the slip open, as when its window first shows,
    /// the dot stays at the slip's end: a frame set on the moved face would
    /// pull it back to the middle, over the words.
    @Test func layoutKeepsTheDotAtTheSlipsEnd() throws {
        let mark = mark(still: true)
        let centre = CGPoint(x: mark.bounds.midX, y: mark.bounds.midY)
        mark.slip = FootSlip(text: "Dictate", key: "fn")
        let end = try #require(mark.slipFrame).minX + FootSlip.dotRoom / 2
        mark.layout()
        #expect(mark.facePosition == centre)
        #expect(mark.facePosition.x + mark.faceOffset.x == end)
    }

    /// A notice longer than the foot's window takes the widest slip and
    /// its words end in an ellipsis, drawn to the slip's own width.
    @Test func aLongNoticeTakesTheWidestSlip() throws {
        let slip = FootSlip(text: String(repeating: "A notice far too long for the foot ", count: 4))
        #expect(slip.size == CGSize(width: FootSlip.widest, height: FootSlip.height))
        let image = try #require(slip.image(dark: false, opening: .centre, scale: 2))
        let words = slip.wordsFrame(in: CGRect(origin: .zero, size: slip.size), opening: .centre)
        #expect(CGFloat(image.width) == words.width * 2)
    }

    /// The longest key Settings allows, while hands-free, fits the slip
    /// whole: long names are drawn as the modifiers' symbols.
    @Test func theLongestShortcutFitsAHandsFreeSlip() {
        let slip = FootSlip(text: "Done", key: "Control + Option + Shift + Command", then: (key: "esc", words: "cancels"))
        #expect(slip.size.width < FootSlip.widest)
        let short = FootSlip(text: "Done", key: "fn", then: (key: "esc", words: "cancels"))
        #expect(slip.size.width - short.size.width < 80)
    }

    /// Under Increase Contrast the keycap's and the paper's edges are raised.
    @Test func increaseContrastRaisesTheSlipsEdges() {
        let plain = FootSlip.colours(dark: false)
        let raised = FootSlip.colours(dark: false, contrast: true)
        #expect(raised.capEdge.alphaComponent == 0.7 && plain.capEdge.alphaComponent < 0.5)
        #expect(raised.edge.alphaComponent > plain.edge.alphaComponent)
    }

    /// Closing under Reduce Motion, the slip fades out whole, words and all,
    /// with the dot still at its end, never on the fading words; then the
    /// dot cuts home.
    @Test(.timeLimit(.minutes(1))) func underReduceMotionTheSlipFadesOutWithItsWords() async {
        let mark = mark(still: true)
        mark.slip = FootSlip(text: "Dictate", key: "fn")
        let end = mark.faceOffset
        #expect(end.x < 0)
        mark.slip = nil
        #expect(mark.slipWordsShow)
        #expect(mark.isAnimating)
        #expect(!mark.isMorphing)
        #expect(mark.faceOffset == end)
        #expect(await eventually { mark.faceOffset == .zero })
    }

    @Test func theSlipMorphsAndUnderReduceMotionCrossFades() {
        let moving = mark()
        moving.slip = FootSlip(text: "Dictate")
        #expect(moving.isMorphing)
        moving.slip = nil
        #expect(moving.isMorphing)
        let still = mark(still: true)
        still.slip = FootSlip(text: "Dictate")
        #expect(!still.isMorphing)
        #expect(still.slipFrame != nil)
        still.slip = nil
        #expect(!still.isMorphing)
    }

    @Test func theStartSendsOneRippleAndALouderSoundAnother() {
        var clock = 100.0
        let mark = mark()
        mark.now = { clock }
        mark.level = 0.9
        #expect(mark.ripples == 0)
        mark.phase = .listening
        #expect(mark.ripples == 1)
        // A word straight after the start is too soon for its own ring.
        clock += 0.2
        mark.level = 0.8
        #expect(mark.ripples == 1)
        clock += 1
        mark.level = 0
        clock += 1
        mark.level = 0.8
        #expect(mark.ripples == 2)
        mark.phase = .writing
        clock += 1
        mark.level = 0
        clock += 1
        mark.level = 0.9
        #expect(mark.ripples == 2)
    }

    @Test func reduceMotionShowsTheSteadyRingAndMovesNothing() {
        let mark = mark(still: true)
        mark.phase = .listening
        #expect(mark.showsSteadyRing)
        #expect(!mark.isAnimating)
        mark.level = 0.9
        #expect(!mark.isAnimating)
        #expect(mark.ripples == 0)
        mark.phase = .writing
        #expect(!mark.showsSteadyRing)
        #expect(!mark.isAnimating)
        #expect(!mark.isBreathing)
        mark.phase = .resting
        #expect(!mark.isAnimating)
    }

    /// Increase Contrast turned on while the pill shows redraws its tooltip
    /// with the stronger edge, and off again brings the usual one back.
    @Test func increaseContrastRedrawsTheTooltip() throws {
        var contrast = false
        let mark = SunDotView(frame: CGRect(x: 0, y: 0, width: SunDotView.side, height: SunDotView.side))
        mark.reducesMotion = { true }
        mark.increasesContrast = { contrast }
        mark.appearance = NSAppearance(named: .aqua)
        mark.glyph = SunDotView.Glyph(key: "fn")
        let usual = try #require(FootSlip.colours(dark: false).edge.usingColorSpace(.sRGB)?.cgColor)
        let strong = try #require(FootSlip.colours(dark: false, contrast: true).edge.usingColorSpace(.sRGB)?.cgColor)
        func edge() -> CGColor? { mark.tooltipEdge?.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intention: .defaultIntention, options: nil) }
        #expect(edge() == usual)
        contrast = true
        mark.displayOptionsChanged()
        #expect(edge() == strong)
        contrast = false
        mark.displayOptionsChanged()
        #expect(edge() == usual)
    }

    /// Reduce Motion turned on while listening stops the breath and shows
    /// the ring; turned off, the breath comes back and the ring goes.
    @Test func reduceMotionTurnedOnWhileListeningShowsTheRing() {
        var still = false
        let mark = SunDotView(frame: CGRect(x: 0, y: 0, width: SunDotView.side, height: SunDotView.side))
        mark.reducesMotion = { still }
        mark.phase = .listening
        #expect(mark.isBreathingInSilence)
        #expect(!mark.showsSteadyRing)
        still = true
        mark.displayOptionsChanged()
        #expect(!mark.isAnimating)
        #expect(mark.showsSteadyRing)
        still = false
        mark.displayOptionsChanged()
        #expect(mark.isBreathingInSilence)
        #expect(!mark.showsSteadyRing)
    }

    /// Reduce Motion turned on while Intention writes stops the breath at once,
    /// and off again brings it back. The notice may come on any queue.
    @Test(.timeLimit(.minutes(1))) func reduceMotionTurnedOnMidWriteStopsTheBreath() async {
        final class Still: @unchecked Sendable { var on = false }
        let still = Still()
        let mark = SunDotView(frame: CGRect(x: 0, y: 0, width: SunDotView.side, height: SunDotView.side))
        mark.reducesMotion = { still.on }
        mark.phase = .writing
        #expect(mark.isBreathing)
        still.on = true
        DispatchQueue.global().async { mark.displayOptionsChanged() }
        let deadline = ContinuousClock.now + .seconds(5)
        while mark.isBreathing, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(!mark.isBreathing)
        #expect(!mark.isAnimating)
        still.on = false
        mark.displayOptionsChanged()
        #expect(mark.isBreathing)
    }

    /// The pill is one flat colour under its tooltip, day and night: the
    /// tooltip's float falls under the pill, never across it.
    @Test func thePillIsFlatUnderItsTooltip() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let mark = SunDotView(frame: CGRect(x: 0, y: 0, width: SunDotView.side, height: SunDotView.side))
            mark.reducesMotion = { true }
            mark.appearance = NSAppearance(named: name)
            mark.glyph = SunDotView.Glyph(key: "fn")
            #expect(mark.glyphDrawing.tooltip != nil)
            let side = Int(SunDotView.side)
            let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            // Into the context as the view draws, y growing down.
            context.translateBy(x: 0, y: CGFloat(side))
            context.scaleBy(x: 1, y: -1)
            try #require(mark.layer).render(in: context)
            let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            let ink = try #require(mark.restInk.usingColorSpace(.sRGB))
            // A column inside the pill, clear of the microphone and the
            // corners, from near its top to near its foot.
            let x = Int(mark.glyphCentre.x) - 10
            for y in (Int(mark.glyphCentre.y) - 12)...(Int(mark.glyphCentre.y) + 12) {
                let at = (y * side + x) * 4
                for (channel, value) in [ink.redComponent, ink.greenComponent, ink.blueComponent].enumerated() {
                    #expect(abs(Int(pixels[at + channel]) - Int((value * 255).rounded())) <= 2, "\(name.rawValue) at y \(y)")
                }
            }
        }
    }

    @Test func theFootTurnsTheSkyOnlyWhileItRests() {
        let foot = FootPlacementTests.foot()
        foot.sky = .moon
        #expect(foot.mark.sky == .moon)
        foot.state = .listening
        foot.sky = .sun
        #expect(foot.mark.sky == .moon)
        foot.state = .writing
        #expect(foot.mark.sky == .moon)
        foot.state = .resting
        #expect(foot.mark.sky == .sun)
    }
}

/// The sun by day and the moon by night, on the Mac's own clock.
@MainActor
struct SkyClockTests {
    nonisolated private static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    nonisolated private static func date(_ text: String, _ zone: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        formatter.timeZone = TimeZone(identifier: zone)!
        return formatter.date(from: text)!
    }

    @Test func theSunRisesAtSixAndSetsAtSeven() {
        let zone = "America/Los_Angeles"
        let calendar = Self.calendar(zone)
        #expect(SkyClock.sky(at: Self.date("2036-10-10T05:59:59", zone), in: calendar) == .moon)
        #expect(SkyClock.sky(at: Self.date("2036-10-10T06:00:00", zone), in: calendar) == .sun)
        #expect(SkyClock.sky(at: Self.date("2036-10-10T18:59:59", zone), in: calendar) == .sun)
        #expect(SkyClock.sky(at: Self.date("2036-10-10T19:00:00", zone), in: calendar) == .moon)
        #expect(SkyClock.sky(at: Self.date("2036-10-10T00:30:00", zone), in: calendar) == .moon)
    }

    @Test func theNextWakeIsTheNextSixOrSeven() {
        let zone = "Europe/London"
        let calendar = Self.calendar(zone)
        #expect(SkyClock.nextChange(after: Self.date("2036-10-10T10:00:00", zone), in: calendar) == Self.date("2036-10-10T19:00:00", zone))
        #expect(SkyClock.nextChange(after: Self.date("2036-10-10T20:00:00", zone), in: calendar) == Self.date("2036-10-11T06:00:00", zone))
        #expect(SkyClock.nextChange(after: Self.date("2036-10-10T03:00:00", zone), in: calendar) == Self.date("2036-10-10T06:00:00", zone))
        // Exactly at a boundary, the next one.
        #expect(SkyClock.nextChange(after: Self.date("2036-10-10T06:00:00", zone), in: calendar) == Self.date("2036-10-10T19:00:00", zone))
        // The night the clocks go back is still one wake at 6:00.
        #expect(SkyClock.nextChange(after: Self.date("2036-10-26T00:30:00", zone), in: calendar) == Self.date("2036-10-26T06:00:00", zone))
    }

    @Test func startingSchedulesOneWakeAtTheNextBoundary() {
        let zone = "Asia/Kolkata"
        let now = Self.date("2036-10-10T18:30:00", zone)
        let clock = SkyClock(now: { now }, calendar: { Self.calendar(zone) })
        #expect(clock.sky == .sun)
        clock.start()
        #expect(clock.nextWake == Self.date("2036-10-10T19:00:00", zone))
    }

    /// The clock, time zone and wake notices can come on any queue: the
    /// sky turns on the main actor, without a trap. The made-up dates are
    /// years ahead, so no real wake fires during the check.
    @Test(.timeLimit(.minutes(1))) func aClockChangeFromABackgroundQueueTurnsTheSkyOnTheMainActor() async {
        final class Now: @unchecked Sendable {
            var date = Date()
        }
        let zone = "America/New_York"
        let now = Now()
        now.date = Self.date("2036-10-10T12:00:00", zone)
        let clock = SkyClock(now: { now.date }, calendar: { Self.calendar(zone) })
        clock.start()
        var turned: [SunDotView.Sky] = []
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            clock.changed = { sky in
                MainActor.assertIsolated()
                turned.append(sky)
                if turned.count == 1 { done.resume() }
            }
            // The Mac's clock is set to the evening, as after a time zone change.
            now.date = Self.date("2036-10-10T21:00:00", zone)
            DispatchQueue.global().async { clock.clockMayHaveChanged() }
        }
        #expect(turned == [.moon])
        #expect(clock.nextWake == Self.date("2036-10-11T06:00:00", zone))
    }
}

/// How loud a chunk of speech is shown, from its samples.
struct SpeechLevelTests {
    @Test func silenceIsNothingCloseSpeechIsFullAndQuietRoomNoiseIsNearlyNothing() {
        #expect(SpeechLevel.of(Data()) == 0)
        #expect(SpeechLevel.of(Data(count: 3_200)) == 0)
        #expect(SpeechLevel.of(DictationScenarioTests.tone(amplitude: 16_000)) == 1)
        #expect(SpeechLevel.of(DictationScenarioTests.tone(amplitude: 20)) < 0.05)
        // About -30 dBFS, ordinary speech at arm's length, sits in the middle.
        let middle = SpeechLevel.of(DictationScenarioTests.tone(amplitude: 32_768 * 0.0447))
        #expect(middle > 0.45 && middle < 0.7)
    }
}

extension NSWindow {
    /// A mouse down and up at `point`, in the window's own coordinates,
    /// delivered as `NSWindow.sendEvent` delivers a click to a window on
    /// screen: to the view the window's frame view hit-tests there, which
    /// has to take the first click, since the foot's window never becomes
    /// key. `sendEvent` itself drops mouse events for a window that is not
    /// on screen, which this one never is. Returns the view that took the
    /// click, or nil when none of the content's views is hit and only
    /// AppKit's frame view is, whose handling of a click is AppKit's own.
    @discardableResult
    func click(at point: CGPoint) -> NSView? {
        guard let content = contentView, let hit = (content.superview ?? content).hitTest(point),
              hit.isDescendant(of: content) else { return nil }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1,
                                                 pressure: type == .leftMouseDown ? 1 : 0) else { return nil }
            if type == .leftMouseDown {
                guard hit.acceptsFirstMouse(for: event) else { return nil }
                hit.mouseDown(with: event)
            } else {
                hit.mouseUp(with: event)
            }
        }
        return hit
    }
}

/// A notice's wait that the check ends by hand, in place of the seconds
/// the app waits, so whether the notice has rested never depends on how
/// promptly a loaded runner fires a timer. A wait the foot cancels stays
/// unanswered until `end`, which ends nothing, as a cancelled sleep would.
@MainActor
final class NoticeTimer {
    /// The durations the foot asked to wait, oldest first.
    private(set) var asked: [Duration] = []
    private var waits: [CheckedContinuation<Void, Error>] = []
    private var watchers: [UUID: AsyncStream<Void>.Continuation] = [:]

    func wait(_ duration: Duration) async throws {
        asked.append(duration)
        try await withCheckedThrowingContinuation { continuation in
            waits.append(continuation)
            watchers.values.forEach { $0.yield() }
        }
    }

    /// Returns once this many waits have begun and not yet been ended.
    func untilWaiting(count: Int = 1) async {
        guard waits.count < count else { return }
        let id = UUID()
        let (changes, change) = AsyncStream<Void>.makeStream()
        watchers[id] = change
        defer {
            watchers[id] = nil
            change.finish()
        }
        // Each observer has its own stream; cancellation ends its iteration
        // without leaving a checked continuation suspended in the runner.
        for await _ in changes {
            if waits.count >= count { return }
        }
    }

    /// Ends every wait begun so far, as their time passing would.
    func end() {
        let ending = waits
        waits = []
        ending.forEach { $0.resume() }
    }
}

@MainActor
struct NoticeTimerTests {
    @Test func cancellingARegistrationWaitDoesNotNeedATimerToArrive() async {
        let timer = NoticeTimer()
        let (started, start) = AsyncStream<Void>.makeStream()
        let task = Task {
            start.yield()
            await timer.untilWaiting(count: 2)
            return Task.isCancelled
        }
        for await _ in started { break }
        task.cancel()
        #expect(await task.value)
    }
}

/// What the voice does to the listening sun, played through `SunVoice` at
/// fifty levels a second.
struct SunVoiceTests {
    /// Plays `levels`, one every 20 ms from `start`, and returns the last look.
    private func play(_ voice: inout SunVoice, _ levels: [Double], from start: Double = 0) -> [SunVoice.Look] {
        levels.enumerated().map { voice.hear($1, at: start + Double($0) * 0.02) }
    }

    @Test func silenceLeavesTheSunAtItsSizeWithAFaintGlow() {
        var voice = SunVoice()
        let look = play(&voice, Array(repeating: 0, count: 50)).last
        #expect(look == SunVoice.look(0))
        #expect(look?.disc == 1)
        #expect((look?.glow ?? 0) > 0.3)
    }

    @Test func speechGrowsTheDiscAndTheDipsBetweenSyllablesShow() {
        var voice = SunVoice()
        let loud = play(&voice, Array(repeating: 0.78, count: 25)).last
        #expect((loud?.disc ?? 0) > 1.45)
        // The follower holds a 60 ms gap near 0.48, high on the level's own
        // scale; against the voice's peak it reads clearly smaller.
        let dip = play(&voice, [0.48], from: 0.5).last
        #expect((dip?.disc ?? 2) < 1.25)
        #expect((dip?.halo ?? 2) < (loud?.halo ?? 0))
    }

    @Test func aQuietVoiceStillMovesTheSun() {
        var voice = SunVoice()
        let quiet = play(&voice, Array(repeating: 0.35, count: 25)).last
        #expect((quiet?.disc ?? 0) > 1.25)
    }

    @Test func steadySpeechSendsARingAPhraseNotASyllable() {
        var voice = SunVoice()
        // Syllables every 200 ms for two seconds, then a pause and a phrase.
        let syllables = (0..<100).map { $0 % 10 < 6 ? 0.75 : 0.55 }
        let first = play(&voice, syllables).filter(\.ripple).count
        #expect(first == 1)
        let pause = play(&voice, Array(repeating: 0, count: 40), from: 2)
        #expect(pause.filter(\.ripple).isEmpty)
        let phrase = play(&voice, Array(repeating: 0.75, count: 10), from: 2.8)
        #expect(phrase.filter(\.ripple).count == 1)
    }
}
