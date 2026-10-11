import AppKit
import Testing
@testable import Dictation

@MainActor
struct FnFootTests {
    @Test func inputProblemUsesTheSlipWithEitherIndicatorAndYieldsToRecording() {
        let foot = FootMark()
        foot.saysWords = false
        foot.inputProblem = "Can't hear fn, quit and reopen Intention"
        #expect(foot.presentation == .notice("Can't hear fn, quit and reopen Intention"))
        var starts = 0
        foot.onAction = { if $0 == .start { starts += 1 } }
        foot.press()
        #expect(starts == 1)
        foot.state = .listening
        #expect(foot.presentation == .listening)
        foot.state = .resting
        #expect(foot.presentation == .notice("Can't hear fn, quit and reopen Intention"))
        foot.inputProblem = nil
        #expect(foot.presentation == .rest)
    }

    /// A press too short to dictate shows the same pill and tooltip as the
    /// pointer does, with the chosen key's caps, with either indicator.
    @Test func shortHoldHintIsThePillWithTheKeysTooltip() {
        let foot = FootMark()
        foot.saysWords = false
        foot.keyName = { "Right Option" }
        foot.showKeyHint()
        #expect(foot.presentation == .keyHint)
        #expect(foot.mark.glyph == SunDotView.Glyph(key: "Right Option"))
        #expect(foot.mark.slip == nil)
        foot.state = .listening
        #expect(foot.presentation == .listening)
        #expect(foot.mark.glyph == nil)
        foot.state = .resting
        #expect(foot.presentation == .rest)
    }

    /// The key hint lasts two seconds, long enough to read the key, then the
    /// dot is back.
    @Test(.timeLimit(.minutes(1))) func theKeyHintLastsTwoSeconds() async {
        let timer = NoticeTimer()
        let foot = FootMark(noticeWait: timer.wait)
        foot.saysWords = false
        foot.showKeyHint()
        #expect(foot.mark.glyph == SunDotView.Glyph(key: "fn"))
        await timer.untilWaiting()
        #expect(timer.asked == [FootMark.keyHintShown])
        #expect(FootMark.keyHintShown == .seconds(2))
        timer.end()
        #expect(await AppearanceCallbackTests.eventually { foot.presentation == .rest })
        #expect(foot.mark.glyph == nil)
    }

    /// Where the tooltip and its float would touch the focused field, the
    /// pill shows without it, and a tooltip already up goes at once rather
    /// than fading over the field.
    @Test(.timeLimit(.minutes(1))) func thePillLeavesOutTheTooltipNearTheFocusedField() async throws {
        let foot = FootPlacementTests.foot(saysWords: false)
        foot.mark.reducesMotion = { false }
        foot.showKeyHint()
        #expect(foot.mark.glyph == SunDotView.Glyph(key: "fn"))
        #expect(foot.mark.tooltipFading)
        // Past the tooltip's fade in, which ends 400 ms after the pill starts.
        try await Task.sleep(for: .milliseconds(500))
        let tip = foot.tooltipFrame("fn").offsetBy(dx: foot.panel.frame.minX, dy: foot.panel.frame.minY)
        foot.focusedField = CGRect(x: -1000, y: tip.maxY + FootSlip.shadowReach + FootMark.margin - 1, width: 3000, height: 40)
        #expect(foot.mark.glyph == SunDotView.Glyph(key: "fn", tooltip: false))
        #expect(!foot.mark.tooltipFading)
        #expect(foot.mark.glyphDrawing.tooltip == nil)
        foot.focusedField = CGRect(x: -1000, y: tip.maxY + FootSlip.shadowReach + FootMark.margin + 1, width: 3000, height: 40)
        #expect(foot.mark.glyph == SunDotView.Glyph(key: "fn"))
    }

    /// A field moving under the tooltip while it fades out with the folding
    /// pill takes it away at once; the glyph, nil before and after, cannot.
    @Test(.timeLimit(.minutes(1))) func aFieldUnderTheTooltipMidFoldTakesItAtOnce() async throws {
        let foot = FootPlacementTests.foot(saysWords: false)
        foot.mark.reducesMotion = { false }
        foot.showKeyHint()
        // Past the tooltip's fade in, which ends 400 ms after the pill starts.
        try await Task.sleep(for: .milliseconds(500))
        #expect(foot.mark.glyphDrawing.tooltip != nil)
        let tip = foot.tooltipFrame("fn").offsetBy(dx: foot.panel.frame.minX, dy: foot.panel.frame.minY)
        foot.state = .listening
        #expect(foot.mark.glyph == nil)
        #expect(foot.mark.tooltipFading)
        foot.focusedField = CGRect(x: -1000, y: tip.maxY + FootSlip.shadowReach + FootMark.margin - 1, width: 3000, height: 40)
        #expect(!foot.mark.tooltipFading)
        #expect(foot.mark.tooltipShowing == nil)
    }
}
