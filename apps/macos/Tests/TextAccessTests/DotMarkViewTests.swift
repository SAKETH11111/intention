import AppKit
@testable import Intention
import Testing

/// The dot's color at rest, from the field's ink or from none.
@MainActor
struct DotMarkViewTests {
    @Test func theFieldsOwnInkIsDrawnAtSixTenths() {
        let ink = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1)
        let resting = DotMarkView.resting(ink: ink)
        #expect(abs(resting.alphaComponent - 0.6) < 0.001)
        #expect(abs(resting.redComponent - 0.1) < 0.001 && abs(resting.blueComponent - 0.3) < 0.001)
    }

    /// An empty field before anything is typed has no ink: the dot must
    /// still be seen on a white page and on a dark one.
    @Test func withNoInkTheDotIsAMidGreyAtFullStrength() {
        let resting = DotMarkView.resting(ink: nil).usingColorSpace(.genericGamma22Gray)
        #expect(resting?.alphaComponent == 1)
        #expect(resting.map { abs($0.whiteComponent - 0.5) < 0.01 } == true)
    }

    /// The very first placement after launch, with no ink, must not leave
    /// the layer's own black fill in place.
    @Test func aFreshMarkPlacedWithNoInkIsFilledMidGrey() {
        let view = DotMarkView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        view.place(diameter: 12, ink: nil, center: CGPoint(x: 50, y: 50))
        // The resting grey is a calibrated white, gamma 2.2; the same space
        // reads it back as it was set.
        let fill = view.currentFill.flatMap { NSColor(cgColor: $0) }?.usingColorSpace(.genericGamma22Gray)
        #expect(fill != nil)
        #expect(fill.map { abs($0.whiteComponent - 0.5) < 0.02 && $0.alphaComponent == 1 } == true)
    }
}

/// The focused field's frame the caret dot hands the foot mark, in AppKit
/// coordinates on a made-up 900 point tall primary screen.
struct FootFieldFrameTests {
    private let height: CGFloat = 900

    @Test func anOrdinaryFieldIsHandedOverAsItIs() {
        let observation = CaretTracker.Observation(reading: .init(caret: CGRect(x: 40, y: 800, width: 1, height: 18),
                                                                  field: CGRect(x: 24, y: 790, width: 1392, height: 36)),
                                                   generation: 0, startedAt: .now)
        #expect(CaretDotController.fieldFrame(of: observation, primaryHeight: height) == CGRect(x: 24, y: 74, width: 1392, height: 36))
    }

    /// Monaco keeps focus in a control a point wide at the caret: the
    /// editor's window stands in for it, so the foot keeps clear of an
    /// editor that reaches the foot of the screen.
    @Test func aControlAPointWideStandsInForItsWindow() {
        let element = AXElement.application(getpid())
        let window = CGRect(x: 0, y: 25, width: 1440, height: 875)
        var observation = CaretTracker.Observation(reading: .init(caret: CGRect(x: 60, y: 200, width: 1, height: 18),
                                                                  field: CGRect(x: 60, y: 200, width: 1, height: 18)),
                                                   generation: 0, startedAt: .now)
        observation.visualTarget = VisualCaretTarget(pid: getpid(), element: element, window: element,
                                                     field: CGRect(x: 60, y: 200, width: 1, height: 18), windowFrame: window, selection: nil)
        #expect(CaretDotController.fieldFrame(of: observation, primaryHeight: height) == CGRect(x: 0, y: 0, width: 1440, height: 875))
        // With no window known, the control is all there is.
        observation.visualTarget = nil
        #expect(CaretDotController.fieldFrame(of: observation, primaryHeight: height) == CGRect(x: 60, y: 682, width: 1, height: 18))
    }
}
