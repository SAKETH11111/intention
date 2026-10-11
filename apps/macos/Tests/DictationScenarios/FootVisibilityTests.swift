import AppKit
@testable import Dictation
import Testing

/// The resting foot dot must be found at a glance on any desktop: its solid
/// ink and the hairline of the other tone round it together stand at least
/// 3:1, the contrast a graphic needs, against every desktop luminance from
/// black to white, by day and by night.
@MainActor
struct FootVisibilityTests {
    /// WCAG relative luminance of an sRGB colour, opaque.
    private func luminance(_ colour: NSColor) -> Double {
        let c = colour.usingColorSpace(.sRGB)!
        func linear(_ v: CGFloat) -> Double {
            let v = Double(v)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
    }

    private func contrast(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func theDotOrItsHairlineStandsOutOnEveryDesktop(appearance: NSAppearance.Name) throws {
        let mark = SunDotView(frame: CGRect(x: 0, y: 0, width: SunDotView.side, height: SunDotView.side))
        mark.appearance = NSAppearance(named: appearance)
        #expect(mark.restInk.alphaComponent == 1)
        #expect(mark.restEdgeInk.alphaComponent == 1)
        // Both tones are drawn, the hairline's fill and the dot over it, as
        // one appearance's pair.
        let drawn = mark.restTones
        #expect([false, true].contains { dark in
            drawn.edge == OwnHandMark.restEdgeInk(dark: dark).cgColor && drawn.core == OwnHandMark.restInk(dark: dark).cgColor
        })
        let ink = luminance(mark.restInk), edge = luminance(mark.restEdgeInk)
        for step in 0...100 {
            let desktop = Double(step) / 100
            #expect(max(contrast(ink, desktop), contrast(edge, desktop)) >= 3, "desktop luminance \(desktop)")
        }
    }

    /// As a dictation's sun settles, the hairline fades in over its last
    /// 110 ms rather than arriving in one frame; under Reduce Motion it is
    /// simply there.
    @Test(arguments: [false, true])
    func theHairlineGrowsInAsTheSunSettles(still: Bool) {
        let mark = SunDotView(frame: CGRect(x: 0, y: 0, width: SunDotView.side, height: SunDotView.side))
        mark.reducesMotion = { still }
        mark.phase = .listening
        #expect(!mark.isFadingEdgeIn)
        mark.phase = .resting
        #expect(mark.isFadingEdgeIn == !still)
    }

    /// Setup's moon hands over to the mark: the hairline fades in round the
    /// moon's settled disc.
    @Test func theHairlineGrowsInWhenSetupsMoonHandsOver() {
        let foot = FootPlacementTests.foot()
        foot.coverForSun()
        foot.uncover()
        #expect(foot.mark.isFadingEdgeIn)
    }
}
