import CoreGraphics
import Foundation
@testable import Intention
import Testing

struct BlinkCaretWorkerTests {
    private let caret = CGRect(x: 10, y: 30, width: 2, height: 20)
    private let glyph = CGRect(x: 90, y: 30, width: 2, height: 20)
    private let anchor = CaretSearchAnchor(bounds: CGRect(x: 91, y: 30, width: 0, height: 20), source: .textRange)

    private func sample(_ rects: [CGRect], time: Double, origin: CGPoint = .zero, scale: CGFloat = 1) -> FieldScreenshot.Sample {
        let width = 120, height = 90
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for rect in rects {
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    for c in 0..<3 { bytes[(y * width + x) * 4 + c] = 10 }
                }
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intention: .defaultIntention)!
        return .init(image: image, origin: origin, scale: scale, capturedAt: time)
    }

    private func acquire(_ worker: BlinkCaretWorker, origin: CGPoint = .zero) async -> CGRect? {
        var result: CGRect?
        for i in 0...10 {
            let on = (i / 3).isMultiple(of: 2)
            let time = Double(i) * 0.2
            result = await worker.observe(sample((on ? [caret] : []) + [glyph], time: time, origin: origin),
                                          generation: 1, time: time, anchors: [anchor])
            if i < 10 { #expect(result == nil) }
        }
        return result
    }

    @Test func inaccurateNativeRangeMustNotAuthorizeAStaticGlyph() async {
        for source: CaretSearchAnchor.Source in [.textRange, .textMarker] {
            let worker = BlinkCaretWorker()
            let incorrect = CaretSearchAnchor(bounds: anchor.bounds, source: source)
            for i in 0..<20 {
                let time = Double(i) * 0.2
                #expect(await worker.observe(sample([glyph], time: time), generation: 1, time: time, anchors: [incorrect]) == nil)
                #expect(await worker.ink(generation: 1) == nil)
            }
        }
    }

    @Test func blinkFindsPaintedCaretDespiteWrongAnchorAndStaticGlyph() async {
        let worker = BlinkCaretWorker()
        #expect(await acquire(worker) == CGRect(x: 11, y: 30, width: 0, height: 20))
        #expect(await worker.ink(generation: 1) != nil)
    }

    @Test func translatedCropCannotReuseEarlierPixelCoordinates() async {
        let worker = BlinkCaretWorker()
        #expect(await acquire(worker) != nil)
        #expect(await worker.observe(sample([caret, glyph], time: 2.2, origin: CGPoint(x: 1, y: 0)),
                                     generation: 1, time: 2.2, anchors: [anchor]) == nil)
        #expect(await worker.ink(generation: 1) == nil)
    }

    @Test func changedScaleOrAnchorRequiresNewEvidence() async {
        for changeScale in [true, false] {
            let worker = BlinkCaretWorker()
            #expect(await acquire(worker) != nil)
            let changed = CaretSearchAnchor(bounds: anchor.bounds.offsetBy(dx: 1, dy: 0), source: .textRange)
            #expect(await worker.observe(sample([caret, glyph], time: 2.2, scale: changeScale ? 2 : 1),
                                         generation: 1, time: 2.2, anchors: changeScale ? [anchor] : [changed]) == nil)
        }
    }

    @Test func newGenerationRejectsLateFramesAndRetainedInk() async {
        let worker = BlinkCaretWorker()
        #expect(await acquire(worker) != nil)
        await worker.reset(generation: 2)
        #expect(await worker.observe(sample([caret, glyph], time: 2.2), generation: 1, time: 2.2, anchors: [anchor]) == nil)
        #expect(await worker.ink(generation: 2) == nil)
        #expect(await worker.observe(sample([caret, glyph], time: 2.4), generation: 2, time: 2.4, anchors: [anchor]) == nil)
    }

    @Test func screenOriginIsAppliedAfterPixelMeasurement() async {
        let worker = BlinkCaretWorker()
        #expect(await acquire(worker, origin: CGPoint(x: 101.5, y: 203.5)) == CGRect(x: 112.5, y: 233.5, width: 0, height: 20))
    }
}
