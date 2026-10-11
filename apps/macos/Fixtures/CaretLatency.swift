import AppKit
import CoreMedia
import ScreenCaptureKit

/// Measures, at the display's frame rate, how long the painted dot trails
/// the painted caret. It records only the owned fixture window and the
/// candidate's dot surface, analyses each frame in memory with the
/// independent oracle, and keeps positions and times only.
final class CaretLatencyRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    struct Sample: Codable {
        let time: Double
        let caretX: Double?
        let caretTop: Double?
        let dotX: Double?
    }

    struct KeyResult: Codable {
        let key: String
        let sentAt: Double
        /// First frame showing the caret at its new position.
        let caretMovedAt: Double?
        /// First frame, at or after that, with the dot centred on it.
        let dotCaughtUpAt: Double?
        /// The caret was undrawn in at least half the frames before the next
        /// key, as a blink leaves it. Only such a deletion may go unmeasured.
        var caretHidden = false
        var lagMilliseconds: Double? {
            guard let caretMovedAt, let dotCaughtUpAt else { return nil }
            return (dotCaughtUpAt - caretMovedAt) * 1000
        }
    }

    private let queue = DispatchQueue(label: "caret.latency")
    private let lock = NSLock()
    private var samples: [Sample] = []
    private let stream: SCStream
    private let scale: CGFloat
    private let allowed: CGRect
    private let dark: Bool
    /// Host-clock seconds minus system uptime, to put frame times on the
    /// same clock as key events.
    private let offset: Double

    @MainActor
    init(filter: SCContentFilter, sourceRect: CGRect, allowedCaret: CGRect, dark: Bool) async throws {
        scale = CGFloat(filter.pointPixelScale)
        allowed = allowedCaret
        self.dark = dark
        offset = CMClockGetTime(CMClockGetHostTimeClock()).seconds - ProcessInfo.processInfo.systemUptime
        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = Int(sourceRect.width * scale)
        config.height = Int(sourceRect.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.capturesAudio = false
        config.queueDepth = 8
        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        super.init()
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        // BGRA: the oracle's colour tests are symmetric in red and blue.
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { target in
            for row in 0..<height {
                memcpy(target.baseAddress! + row * width * 4, base + row * rowBytes, width * 4)
            }
        }
        let stem = CaretPixelOracle.locate(pixels, width: width, height: height, scale: scale, dark: dark, allowedCaret: allowed).caret
        let dot = stem.flatMap { Self.dot(in: pixels, width: width, height: height, scale: scale, dark: dark, above: $0) }
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds - offset
        let entry = Sample(time: time, caretX: stem.map { Double($0.midX) }, caretTop: stem.map { Double($0.minY) },
                           dotX: dot.map { Double($0.midX) })
        lock.withLock { samples.append(entry) }
    }

    /// The dot in one frame, without a dot-free reference: non-green ink
    /// above the stem, with field borders (long horizontal runs) removed and
    /// the thin gap they leave bridged, as one round component.
    static func dot(in pixels: [UInt8], width: Int, height: Int, scale: CGFloat, dark: Bool, above stem: CGRect) -> CGRect? {
        var mask = [Bool](repeating: false, count: width * height)
        for i in mask.indices {
            let p = i * 4
            let r = Int(pixels[p]), g = Int(pixels[p + 1]), b = Int(pixels[p + 2])
            let green = g - r > 45 && g - b > 45
            // The dot is the text colour at 60% opacity; light text makes a
            // light dot, so any clear departure from the background counts.
            let ink = dark ? min(r, g, b) > 70 : max(r, g, b) < 225
            mask[i] = ink && !green
        }
        let minimumRun = Int(30 * scale)
        var removed: [Int] = []
        for y in 0..<height {
            var x = 0
            while x < width {
                guard mask[y * width + x] else { x += 1; continue }
                var end = x
                while end < width, mask[y * width + end] { end += 1 }
                if end - x >= minimumRun { for fill in x..<end { mask[y * width + fill] = false; removed.append(y * width + fill) } }
                x = end
            }
        }
        // Restore the border pixels the dot covers: those with dot ink
        // directly above and below. The rest of the border stays removed.
        var bridged = mask
        for i in removed {
            let y = i / width
            if y > 0, y < height - 1, mask[i - width], mask[i + width] { bridged[i] = true }
        }
        var seen = [Bool](repeating: false, count: width * height)
        var found: [CGRect] = []
        for start in bridged.indices where bridged[start] && !seen[start] {
            var queue = [start], index = 0
            seen[start] = true
            var minX = width, minY = height, maxX = 0, maxY = 0
            while index < queue.count {
                let p = queue[index]; index += 1
                let x = p % width, y = p / width
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && nx < width && ny >= 0 && ny < height {
                    let n = ny * width + nx
                    if bridged[n], !seen[n] { seen[n] = true; queue.append(n) }
                }
            }
            let rect = CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                              width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
            if rect.width >= 5, rect.width <= 20, rect.height >= 5, rect.height <= 20, abs(rect.width - rect.height) < 3,
               rect.maxY <= stem.minY + 1, stem.minY - rect.maxY < 32, abs(rect.midX - stem.midX) < 32 { found.append(rect) }
        }
        return found.count == 1 ? found[0] : nil
    }

    func stop() async -> [Sample] {
        try? await stream.stopCapture()
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        return lock.withLock { samples.sorted { $0.time < $1.time } }
    }

    /// Per key: when the caret first shows its new position, and when the
    /// dot is first centred over it (within one point). Frames without a
    /// visible caret, such as blink-off frames, are skipped.
    static func analyse(_ samples: [Sample], keys: [(name: String, sentAt: Double)]) -> [KeyResult] {
        var results: [KeyResult] = []
        for (index, key) in keys.enumerated() {
            let end = index + 1 < keys.count ? keys[index + 1].sentAt : key.sentAt + 1
            let before = samples.last { $0.time < key.sentAt && $0.caretX != nil }?.caretX
            let frames = samples.filter { $0.time >= key.sentAt && $0.time < end }
            let window = frames.filter { $0.caretX != nil }
            guard let moved = window.first(where: { before == nil || abs(($0.caretX ?? 0) - before!) > 0.75 }) else {
                results.append(.init(key: key.name, sentAt: key.sentAt, caretMovedAt: nil, dotCaughtUpAt: nil,
                                     caretHidden: !frames.isEmpty && (frames.count - window.count) * 2 >= frames.count))
                continue
            }
            let target = moved.caretX!
            let caught = window.first { $0.time >= moved.time && abs(($0.caretX ?? 0) - target) <= 0.75
                && $0.dotX.map { abs($0 - target) <= 1 } == true }
            results.append(.init(key: key.name, sentAt: key.sentAt, caretMovedAt: moved.time, dotCaughtUpAt: caught?.time))
        }
        return results
    }
}
