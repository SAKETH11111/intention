import AppKit
@testable import Dictation
import Testing

/// The resting foot dot is a true circle with an even hairline, drawn at the
/// size it shows: at rest, held and at the end of an open slip, so it is
/// rasterized at the display's own pixels and never resampled.
@MainActor
struct FootDotCrispTests {
    /// Whether `path` is the circle with its bounds, sampled on a grid.
    private func isCircle(_ path: CGPath?) -> Bool {
        guard let path else { return false }
        let box = path.boundingBoxOfPath
        guard abs(box.width - box.height) < 1e-6 else { return false }
        let circle = CGPath(ellipseIn: box, transform: nil)
        for i in 0..<60 {
            for j in 0..<60 {
                let point = CGPoint(x: box.minX + (CGFloat(i) + 0.5) * box.width / 60, y: box.minY + (CGFloat(j) + 0.5) * box.height / 60)
                if path.contains(point) != circle.contains(point) { return false }
            }
        }
        return true
    }

    private func mark() -> SunDotView {
        let mark = SunDotView(frame: CGRect(x: 0, y: 0, width: 240, height: SunDotView.side))
        mark.reducesMotion = { false }
        return mark
    }

    @Test func theRestingDotIsATrueCircleInAnEvenHairline() throws {
        let drawn = mark().restDrawing
        #expect(isCircle(drawn.core))
        #expect(isCircle(drawn.edge))
        let core = try #require(drawn.core).boundingBoxOfPath, edge = try #require(drawn.edge).boundingBoxOfPath
        #expect(abs(core.width - SunDotView.restWidth) < 1e-6)
        // The same 1.5 points on every side: concentric, and 3 points wider.
        #expect(abs(core.midX - edge.midX) < 1e-6 && abs(core.midY - edge.midY) < 1e-6)
        #expect(abs(edge.width - core.width - 2 * 1.5) < 1e-6)
        #expect(OwnHandMark.restEdge == 1.5)
        #expect(drawn.scale == 1)
    }

    /// Held, the circles themselves are 1.3 times as wide, and every step
    /// of the spring there is a circle drawn at its size, with nothing over
    /// the dot scaling it.
    @Test func theHeldDotIsDrawnAtItsSizeAtEveryStep() throws {
        let mark = mark()
        mark.lifted = true
        let drawn = mark.restDrawing
        #expect(drawn.scale == 1)
        let core = try #require(drawn.core).boundingBoxOfPath
        #expect(abs(core.width - SunDotView.restWidth * SunDotView.liftScale) < 1e-6)
        let steps = mark.liftSteps
        #expect(steps.count > 20)
        #expect(steps.allSatisfy(isCircle))
        let widths = steps.map { $0.boundingBoxOfPath.width }
        #expect(abs((widths.first ?? 0) - SunDotView.restWidth) < 1e-6)
        #expect(abs((widths.last ?? 0) - SunDotView.restWidth * SunDotView.liftScale) < 1e-6)
        // The spring overshoots a little, as the hand's spring does, and no more.
        #expect((widths.max() ?? 0) > SunDotView.restWidth * SunDotView.liftScale)
        #expect((widths.max() ?? 0) < SunDotView.restWidth * SunDotView.liftScale * 1.05)
        mark.lifted = false
        #expect(abs((mark.restDrawing.core?.boundingBoxOfPath.width ?? 0) - SunDotView.restWidth) < 1e-6)
    }

    /// The dot's centre sits on a pixel corner at 1x and 2x, at rest and at
    /// the end of an open slip, so its edge anti-aliases evenly all round;
    /// in the slip it is drawn at its own size too.
    @Test(arguments: [CGFloat(1), 2])
    func theDotSitsOnThePixelGrid(scale: CGFloat) {
        let mark = SunDotView(frame: CGRect(x: 0.3, y: 0, width: 241, height: 57))
        mark.reducesMotion = { true }
        mark.backingScale = scale
        // On the grid of the window, not of the view, whose origin is off it.
        func onGrid(_ local: CGPoint) -> Bool {
            let point = mark.convert(local, to: nil)
            return abs((point.x * scale).rounded() - point.x * scale) < 1e-6 && abs((point.y * scale).rounded() - point.y * scale) < 1e-6
        }
        #expect(onGrid(mark.restDrawing.centre))
        for text in ["Dictate", "Dictat", "Hold fn to dictate anywhere"] {
            mark.slip = FootSlip(text: text, key: "fn")
            #expect(onGrid(mark.restDrawing.centre), "\(text)")
            #expect(mark.restDrawing.scale == 1)
        }
    }

    /// A change of display while the slip closes under Reduce Motion leaves
    /// the dot at the slip's end until the fade is over, never on the fading
    /// words; with the slip open the dot moves onto the new pixels.
    @Test(.timeLimit(.minutes(1))) func aChangeOfDisplayKeepsTheSlipsMotion() async {
        let mark = SunDotView(frame: CGRect(x: 0.3, y: 0, width: 241, height: 57))
        mark.reducesMotion = { true }
        mark.slip = FootSlip(text: "Dictate", key: "fn")
        mark.backingScale = 1
        let centre = mark.convert(mark.restDrawing.centre, to: nil)
        #expect(centre.x == centre.x.rounded() && centre.y == centre.y.rounded())
        let end = mark.faceOffset
        mark.slip = nil
        mark.backingScale = 2
        #expect(mark.faceOffset == end)
        #expect(await AppearanceCallbackTests.eventually { mark.faceOffset == .zero })
    }

    /// A change of display while the dot glides into an open slip lets the
    /// glide run on, and the slip's end lands on the new pixels.
    @Test func aChangeOfDisplayLetsTheGlideRunOn() {
        let mark = SunDotView(frame: CGRect(x: 0.3, y: 0, width: 241, height: 57))
        mark.reducesMotion = { false }
        mark.slip = FootSlip(text: "Dictate", key: "fn")
        #expect(mark.isGliding)
        mark.backingScale = 1
        #expect(mark.isGliding)
        let centre = mark.convert(mark.restDrawing.centre, to: nil)
        #expect(centre.x == centre.x.rounded() && centre.y == centre.y.rounded())
    }

    /// Below 20 points every dot is a circle; from 20 up the mark keeps the
    /// hand's own dot.
    @Test func smallDotsAreCirclesAndLargeOnesKeepTheHand() {
        for diameter in [CGFloat(6), 11, 13, 16.9, 19.9] {
            #expect(isCircle(OwnHandMark.dot(diameter: diameter).path), "\(diameter)")
        }
        #expect(!isCircle(OwnHandMark.dot(diameter: OwnHandMark.handFrom).path))
    }
}
