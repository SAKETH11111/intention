import CoreGraphics
@testable import Intention
import Testing

struct BlinkCaretDetectorTests {
    private func frame(_ rectangles: [CGRect] = [], width: Int = 120, height: Int = 90) -> BlinkCaretDetector.Frame {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for rect in rectangles {
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = 10 }
                }
            }
        }
        return .init(width: width, height: height, pixels: pixels)
    }

    // Sample at 5 Hz, with independent expected coordinates. A stationary
    // placeholder stays visible throughout, even when it resembles text.
    private func acquire(_ detector: inout BlinkCaretDetector, caret: CGRect, scale: CGFloat = 1,
                         extra: [CGRect] = []) -> CGRect? {
        var result: CGRect?
        for i in 0...10 {
            let on = (i / 3).isMultiple(of: 2)
            result = detector.observe(frame((on ? [caret] : []) + extra), scale: scale, time: Double(i) * 0.2)
            if i < 10 { #expect(result == nil) }
        }
        return result
    }

    /// A sampled fade resembling the native recording: a long on plateau,
    /// several partially transparent frames, then a short off plateau.
    private func fadedFrame(_ opacity: Double, extra: [CGRect] = []) -> BlinkCaretDetector.Frame {
        let input = frame(extra)
        var pixels = input.pixels
        for y in 30..<52 {
            for x in 31..<34 {
                let coverage = x == 32 ? 1.0 : 0.65
                let value = UInt8((255 - 235 * opacity * coverage).rounded())
                for channel in 0..<3 { pixels[(y * input.width + x) * 4 + channel] = value }
            }
        }
        return .init(width: input.width, height: input.height, pixels: pixels)
    }

    @Test func fadingCaretRequiresThreeSettledAlternatingTransitions() {
        let opacity = [0.0, 0.2, 0.5, 1, 1, 1, 1, 1, 1, 1, 0.8, 0.55, 0, 0, 0]
        var detector = BlinkCaretDetector()
        var first: Int?
        for i in 0..<60 {
            let result = detector.observe(fadedFrame(opacity[i % opacity.count]), scale: 1, time: Double(i) / 15)
            if let result {
                first = first ?? i
                #expect(result == CGRect(x: 31, y: 30, width: 3, height: 22))
            }
            if i < 28 { #expect(result == nil) }
        }
        #expect(first == 28)
    }

    @Test func oneFadeAndAStaticGlyphNeverBecomeBlinkEvidence() {
        var detector = BlinkCaretDetector()
        let glyph = CGRect(x: 75, y: 30, width: 2, height: 22)
        for i in 0..<60 {
            let opacity = max(0, 1 - Double(i) / 8)
            #expect(detector.observe(fadedFrame(opacity, extra: [glyph]), scale: 1, time: Double(i) / 15) == nil)
        }
    }

    @Test func redrawOutsideFadingStemImmediatelyInvalidatesEvidence() {
        let opacity = [0.0, 0.2, 0.5, 1, 1, 1, 1, 1, 1, 1, 0.8, 0.55, 0, 0, 0]
        var detector = BlinkCaretDetector()
        var result: CGRect?
        for i in 0..<45 {
            result = detector.observe(fadedFrame(opacity[i % opacity.count]), scale: 1, time: Double(i) / 15)
        }
        #expect(result != nil)
        let changedGlyph = CGRect(x: 75, y: 30, width: 2, height: 22)
        #expect(detector.observe(fadedFrame(0.2, extra: [changedGlyph]), scale: 1, time: 3) == nil)
        #expect(detector.observe(fadedFrame(0.5), scale: 1, time: 3.066) == nil)
    }

    @Test func firstFocusPlaceholderUsesPaintedCaretAndTop() {
        var detector = BlinkCaretDetector()
        let caret = CGRect(x: 11, y: 37, width: 1, height: 18)
        let result = acquire(&detector, caret: caret, extra: [CGRect(x: 20, y: 36, width: 70, height: 19)])
        #expect(result == caret)
        #expect(result?.midX == 11.5)
        #expect(result?.minY == 37)
        #expect((detector.ink?.red ?? 1) < 0.1)
    }

    @Test func retinaCoordinatesPreserveHalfPointCentre() {
        var detector = BlinkCaretDetector()
        let result = acquire(&detector, caret: CGRect(x: 21, y: 20, width: 2, height: 36), scale: 2)
        #expect(result?.midX == 22)
        #expect(result.map { $0.midX / 2 } == 11)
    }

    @Test func blinkingTerminalBlockUsesItsPaintedCentre() {
        var detector = BlinkCaretDetector()
        let block = CGRect(x: 23, y: 30, width: 9, height: 18)
        #expect(acquire(&detector, caret: block) == block)
    }

    @Test func adjacentDarkGlyphsDoNotTurnTheDotWhite() {
        var detector = BlinkCaretDetector()
        let caret = CGRect(x: 30, y: 30, width: 2, height: 18)
        let neighbours = [CGRect(x: 28, y: 32, width: 2, height: 13), CGRect(x: 32, y: 32, width: 2, height: 13)]
        #expect(acquire(&detector, caret: caret, extra: neighbours) == caret)
        #expect((detector.ink?.red ?? 1) < 0.1)
    }

    @Test func lightCaretOnDarkFieldSuppliesLightInk() {
        var detector = BlinkCaretDetector()
        let caret = CGRect(x: 11, y: 30, width: 2, height: 18)
        for i in 0...10 {
            let input = frame((i / 3).isMultiple(of: 2) ? [caret] : [])
            let inverted = input.pixels.enumerated().map { index, value in index % 4 == 3 ? value : 255 - value }
            _ = detector.observe(.init(width: input.width, height: input.height, pixels: inverted), scale: 1, time: Double(i) * 0.2)
        }
        #expect((detector.ink?.red ?? 0) > 0.9)
    }

    @Test func multipleBlinkingRegionsAreAmbiguous() {
        var detector = BlinkCaretDetector()
        for i in 0...12 {
            let rects = (i / 3).isMultiple(of: 2) ? [CGRect(x: 10, y: 20, width: 1, height: 18), CGRect(x: 40, y: 20, width: 1, height: 18)] : []
            #expect(detector.observe(frame(rects), scale: 1, time: Double(i) * 0.2) == nil)
        }
    }

    @Test func movementAndTextRedrawDiscardTheOldPosition() {
        var detector = BlinkCaretDetector()
        let old = CGRect(x: 10, y: 20, width: 1, height: 18)
        #expect(acquire(&detector, caret: old) == old)
        #expect(detector.observe(frame([CGRect(x: 60, y: 20, width: 1, height: 18)]), scale: 1, time: 2.2) == nil)
        #expect(detector.observe(frame([CGRect(x: 40, y: 20, width: 40, height: 18)]), scale: 1, time: 2.4) == nil)
    }

    @Test func steadyCaretAndStoppedBlinkStayHidden() {
        var detector = BlinkCaretDetector()
        let caret = CGRect(x: 10, y: 20, width: 1, height: 18)
        for i in 0..<20 {
            #expect(detector.observe(frame([caret]), scale: 1, time: Double(i) * 0.2) == nil)
        }
        detector.reset()
        #expect(acquire(&detector, caret: caret) == caret)
        for i in 11...15 { _ = detector.observe(frame(), scale: 1, time: Double(i) * 0.2) }
        #expect(detector.observe(frame(), scale: 1, time: 3.2) == nil)
    }

    @Test func pausedSamplingAndExplicitInvalidationRequireNewEvidence() {
        var detector = BlinkCaretDetector()
        let caret = CGRect(x: 10, y: 20, width: 1, height: 18)
        #expect(acquire(&detector, caret: caret) == caret)
        #expect(detector.observe(frame([caret]), scale: 1, time: 4) == nil)
        detector.reset()
        #expect(detector.observe(frame([caret]), scale: 1, time: 4.2) == nil)
    }

    @Test func clippedWideAndShortShapesStayHidden() {
        for caret in [CGRect(x: 0, y: 20, width: 1, height: 18), CGRect(x: 10, y: 20, width: 30, height: 18), CGRect(x: 10, y: 20, width: 1, height: 3)] {
            var detector = BlinkCaretDetector()
            #expect(acquire(&detector, caret: caret) == nil)
        }
    }

    // A single frame of an empty field: the field's border, a placeholder
    // shorter than the line, and the caret spanning it.
    private func emptyField(caret: Bool = true, placeholder: [CGRect] = [CGRect(x: 36, y: 34, width: 6, height: 13), CGRect(x: 45, y: 36, width: 2, height: 11)]) -> BlinkCaretDetector.Frame {
        let border = [CGRect(x: 0, y: 0, width: 120, height: 1), CGRect(x: 0, y: 89, width: 120, height: 1),
                      CGRect(x: 0, y: 0, width: 1, height: 90), CGRect(x: 119, y: 0, width: 1, height: 90)]
        return frame(border + placeholder + (caret ? [CGRect(x: 33, y: 30, width: 2, height: 22)] : []))
    }

    @Test func anEmptyFieldsCaretIsItsOnlyFullLineStroke() {
        #expect(BlinkCaretDetector.solidCaret(in: emptyField(), scale: 1) == CGRect(x: 33, y: 30, width: 2, height: 22))
        #expect(BlinkCaretDetector.solidCaret(in: emptyField(placeholder: []), scale: 1) == CGRect(x: 33, y: 30, width: 2, height: 22))
    }

    @Test func aCaretAtTheFieldsEdgeIsFoundButAFullHeightBorderIsNot() {
        // A composer whose frame starts at its text: the caret is column 0.
        let composer = frame([CGRect(x: 0, y: 2, width: 1, height: 17), CGRect(x: 5, y: 6, width: 6, height: 10)], width: 200, height: 20)
        #expect(BlinkCaretDetector.solidCaret(in: composer, scale: 1) == CGRect(x: 0, y: 2, width: 1, height: 17))
        let bordered = frame([CGRect(x: 0, y: 0, width: 1, height: 20), CGRect(x: 14, y: 2, width: 2, height: 16)], width: 200, height: 20)
        #expect(BlinkCaretDetector.solidCaret(in: bordered, scale: 1) == CGRect(x: 14, y: 2, width: 2, height: 16))
    }

    @Test func aOneLineFieldsCaretMaySpanTheWholeCrop() {
        // A composer cropped to its 20-point line: the caret touches both edges.
        let crop = frame([CGRect(x: 30, y: 0, width: 2, height: 20), CGRect(x: 36, y: 5, width: 6, height: 11)], width: 120, height: 20)
        #expect(BlinkCaretDetector.solidCaret(in: crop, scale: 1) == CGRect(x: 30, y: 0, width: 2, height: 20))
        // In a tall field the same edge-to-edge stroke would be a divider.
        #expect(BlinkCaretDetector.solidCaret(in: frame([CGRect(x: 40, y: 0, width: 1, height: 30)]), scale: 1) == nil)
    }

    @Test func windowCornersAtATallFieldsEdgeDoNotHideItsCaret() {
        // Terminal's text area reaches the window's rounded bottom corners,
        // whose dark pixels form strokes almost as tall as the cursor.
        let corners = [CGRect(x: 0, y: 101, width: 1, height: 19), CGRect(x: 199, y: 101, width: 1, height: 19)]
        let terminal = frame(corners + [CGRect(x: 43, y: 40, width: 1, height: 22), CGRect(x: 8, y: 10, width: 6, height: 14)], width: 200, height: 120)
        #expect(BlinkCaretDetector.solidCaret(in: terminal, scale: 1) == CGRect(x: 43, y: 40, width: 1, height: 22))
        // Without a caret, the corners are never taken for one.
        #expect(BlinkCaretDetector.solidCaret(in: frame(corners, width: 200, height: 120), scale: 1) == nil)
    }

    @Test func aBandAcrossAnInputBoxFindsTheCaretBesideTheBoxSide() {
        // A band around a click in an app without accessible text crosses
        // the input box: its side spans the band, the caret does not.
        let side = CGRect(x: 20, y: 0, width: 1, height: 72)
        let band = frame([side, CGRect(x: 60, y: 28, width: 2, height: 17), CGRect(x: 66, y: 32, width: 6, height: 12)], width: 300, height: 72)
        #expect(BlinkCaretDetector.solidCaret(in: band, scale: 1) == CGRect(x: 60, y: 28, width: 2, height: 17))
        // So is a side that reaches only one edge of the band.
        let clipped = frame([CGRect(x: 20, y: 19, width: 1, height: 65), CGRect(x: 60, y: 28, width: 2, height: 17)], width: 300, height: 84)
        #expect(BlinkCaretDetector.solidCaret(in: clipped, scale: 1) == CGRect(x: 60, y: 28, width: 2, height: 17))
        // A box side taller than any caret is ignored too.
        let tall = frame([CGRect(x: 20, y: 5, width: 1, height: 95), CGRect(x: 60, y: 40, width: 2, height: 17)], width: 300, height: 120)
        #expect(BlinkCaretDetector.solidCaret(in: tall, scale: 1) == CGRect(x: 60, y: 40, width: 2, height: 17))
    }

    @Test func aTypedFieldsCaretIsTallerThanItsGlyphs() {
        // Ascender and descender glyph columns stay shorter than the line.
        let text = [CGRect(x: 36, y: 33, width: 2, height: 14), CGRect(x: 41, y: 36, width: 5, height: 11),
                    CGRect(x: 49, y: 36, width: 2, height: 15), CGRect(x: 54, y: 33, width: 2, height: 14)]
        let typed = frame(text + [CGRect(x: 60, y: 30, width: 2, height: 22)])
        #expect(BlinkCaretDetector.solidCaret(in: typed, scale: 1) == CGRect(x: 60, y: 30, width: 2, height: 22))
        #expect(BlinkCaretDetector.solidCaret(in: frame(text), scale: 1) == nil)
    }

    @Test func placeholderGlyphsAndBordersAreNeverAnEmptyFieldsCaret() {
        #expect(BlinkCaretDetector.solidCaret(in: emptyField(caret: false), scale: 1) == nil)
        // Two equally tall strokes are ambiguous.
        let twin = [CGRect(x: 60, y: 30, width: 2, height: 22)]
        #expect(BlinkCaretDetector.solidCaret(in: emptyField(placeholder: twin), scale: 1) == nil)
        // A stroke through the field's edge is part of a border.
        #expect(BlinkCaretDetector.solidCaret(in: frame([CGRect(x: 40, y: 0, width: 1, height: 30)]), scale: 1) == nil)
    }

    @Test func aSeededCaretStaysSolidUntilItStartsBlinking() {
        var detector = BlinkCaretDetector()
        let caret = CGRect(x: 33, y: 30, width: 2, height: 22)
        detector.seed(caret, in: emptyField(), time: 0)
        // Solid for 1.2 seconds after input, sampled every 50 ms.
        for step in 1...24 {
            #expect(detector.observe(emptyField(), scale: 1, time: Double(step) / 20) == caret)
        }
        // A caret that never blinks is kept only up to the seeded hold.
        _ = detector.observe(emptyField(), scale: 1, time: 1.3)
        var time = 1.3
        while time < BlinkCaretDetector.seededHold - 0.1 {
            time += 0.05
            #expect(detector.observe(emptyField(), scale: 1, time: time) == caret)
        }
        #expect(detector.observe(emptyField(), scale: 1, time: BlinkCaretDetector.seededHold + 0.05) == nil)
    }

    @Test func aSeededCaretSurvivesItsBlinkAndYieldsToOtherChanges() {
        var detector = BlinkCaretDetector()
        let caret = CGRect(x: 33, y: 30, width: 2, height: 22)
        detector.seed(caret, in: emptyField(), time: 0)
        #expect(!detector.confirmed)
        // Sampled at 10 Hz through two half-second blink phases.
        for step in 1...14 {
            let on = (step / 5).isMultiple(of: 2)
            #expect(detector.observe(emptyField(caret: on), scale: 1, time: Double(step) / 10) == caret)
            if step == 4 { #expect(!detector.confirmed) }
        }
        // Its blink confirmed the one-frame seed.
        #expect(detector.confirmed)
        let typed = emptyField(placeholder: [CGRect(x: 70, y: 34, width: 6, height: 13)])
        #expect(detector.observe(typed, scale: 1, time: 1.5) == nil)
        #expect(!detector.hasCandidate)
    }
}
