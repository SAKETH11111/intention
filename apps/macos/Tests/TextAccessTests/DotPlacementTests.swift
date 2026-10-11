import CoreGraphics
@testable import Intention
import Testing

struct DotPlacementTests {
    /// From 20 points up the dot is the mark's own; below, a circle
    /// (`OwnHandMark.handFrom`).
    @Test func largeDotIsTheMarksOwnDotNotACircle() {
        let shape = OwnHandMark.dot(diameter: 24)
        let bounds = shape.path.boundingBoxOfPath
        #expect(abs(shape.size.width - 24) < 0.001)
        // The asset's dot is a pebble slightly wider than tall.
        #expect(abs(bounds.width / bounds.height - 1.052) < 0.01)
        // About 2.5% of its box differs from the ellipse with the same
        // bounds; a circle drawn in its place would differ by nothing.
        let ellipse = CGPath(ellipseIn: bounds, transform: nil)
        var differing = 0
        for i in 0..<100 {
            for j in 0..<100 {
                let point = CGPoint(x: bounds.minX + (CGFloat(i) + 0.5) * bounds.width / 100,
                                    y: bounds.minY + (CGFloat(j) + 0.5) * bounds.height / 100)
                if shape.path.contains(point) != ellipse.contains(point) { differing += 1 }
            }
        }
        #expect(differing > 150)
    }

    @Test func accessibilityRectsFlipAgainstThePrimaryDisplay() {
        let rect = DotPlacement.appKitRect(fromAccessibility: CGRect(x: 100, y: 50, width: 2, height: 18), primaryScreenHeight: 900)
        #expect(rect == CGRect(x: 100, y: 832, width: 2, height: 18))
    }

    @Test func dotSitsCentredOverTheCaret() {
        // A 16 pt caret, as Chromium reports for 14 pt text, whose AppKit
        // span is 584 to 600.
        let line = CGRect(x: 400, y: 584, width: 0, height: 16)
        let dot = DotPlacement.dot(aboveCaret: line)
        #expect(dot.diameter == 12)
        // Centred on the caret drawn at x = 400.
        #expect(dot.center.x == 400)
        #expect(abs((dot.center.y - dot.diameter / 2) - (600 + 16 * 0.2)) < 0.001)
    }

    @Test func dotKeepsItsSizeInASingleLineField() {
        // A 17 pt caret in a 30 pt input: 6 pt between the caret's top and
        // the field's top edge.
        let line = CGRect(x: 400, y: 587, width: 0, height: 17)
        let field = CGRect(x: 380, y: 581, width: 300, height: 30)
        let dot = DotPlacement.dot(aboveCaret: line, in: field)
        #expect(dot.diameter == DotPlacement.dotDiameter(forCaretHeight: 17))
        // It tucks to a sliver of air above the caret instead.
        #expect(abs((dot.center.y - dot.diameter / 2) - (604 + 1.5)) < 0.001)
        let roomy = DotPlacement.dot(aboveCaret: line, in: CGRect(x: 380, y: 400, width: 300, height: 400))
        #expect(roomy == DotPlacement.dot(aboveCaret: line))
    }

    @Test func dotSizeStaysWithinReadableBounds() {
        #expect(DotPlacement.dotDiameter(forCaretHeight: 6) == 8)
        #expect(DotPlacement.dotDiameter(forCaretHeight: 80) == 16)
    }

    @Test func dotGapStaysWithinOneToFivePointsAtEveryTextSize() {
        for height in [CGFloat(4), 8, 18, 26, 40, 80, 160] {
            let line = CGRect(x: 400.25, y: 300, width: 1, height: height)
            for field in [CGRect?.none, CGRect(x: 380, y: 290, width: 400, height: height + 16),
                          CGRect(x: 380, y: 100, width: 400, height: 600)] {
                let dot = DotPlacement.dot(aboveCaret: line, in: field)
                let gap = dot.center.y - dot.diameter / 2 - line.maxY
                #expect(gap >= 1 && gap <= 5)
                #expect(dot.center.x == line.midX)
            }
        }
    }
}
