import AppKit
import ScreenCaptureKit
import VideoToolbox

/// The only screenshot entry point for caret detection. The crop is supplied
/// to ScreenCaptureKit before capture, using a display filter restricted to the target window.
@MainActor
enum FieldScreenshot {
    enum Failure: Error { case denied, invalidBounds, staleFrame, invalidDimensions }
    struct Sample: Sendable {
        let image: CGImage
        let origin: CGPoint
        let scale: CGFloat
        let capturedAt: TimeInterval

        /// The part of the sample inside `rect` (global points), on whole
        /// pixels; nil when they do not overlap.
        func cropped(to rect: CGRect) -> Sample? {
            let pixels = CGRect(x: ((rect.minX - origin.x) * scale).rounded(.down), y: ((rect.minY - origin.y) * scale).rounded(.down),
                                width: (rect.width * scale).rounded(.up), height: (rect.height * scale).rounded(.up))
                .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard !pixels.isNull, pixels.width >= 8, pixels.height >= 8, let part = image.cropping(to: pixels) else { return nil }
            return Sample(image: part, origin: CGPoint(x: origin.x + pixels.minX / scale, y: origin.y + pixels.minY / scale),
                          scale: scale, capturedAt: capturedAt)
        }
    }

    static func frontWindowID(for pid: pid_t, frame: CGRect) -> CGWindowID? {
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return nil }
        // Window Server returns front-to-back order. Choose the foremost normal
        // window matching the focused window's process and exact frame.
        for info in windows {
            if (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
               (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
               let bounds = info[kCGWindowBounds as String] as? [String: NSNumber],
               CGRect(dictionaryRepresentation: bounds as CFDictionary) == frame {
                return (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            }
        }
        return nil
    }

    /// The field inside the display, shrunk to native pixel boundaries so
    /// ScreenCaptureKit never scales a fractional crop, and capped at two
    /// million pixels. Display-local points.
    static func crop(field: CGRect, window: SCWindow, display: SCDisplay, scale: CGFloat) -> CGRect? {
        guard scale.isFinite, scale >= 1, window.frame.contains(field), display.frame.contains(field) else { return nil }
        let local = field.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        let left = ceil(local.minX * scale), top = ceil(local.minY * scale)
        let right = floor(local.maxX * scale), bottom = floor(local.maxY * scale)
        guard left.isFinite, top.isFinite, right.isFinite, bottom.isFinite,
              right - left >= 1, bottom - top >= 1,
              right - left <= 4096, bottom - top <= 4096,
              (right - left) * (bottom - top) <= 2_000_000 else { return nil }
        return CGRect(x: left / scale, y: top / scale, width: (right - left) / scale, height: (bottom - top) / scale)
    }

    static func capture(window: SCWindow, display: SCDisplay, field: CGRect,
                        validate: @MainActor () async -> Bool) async throws -> Sample {
        // Display-bound composition includes Chrome's separately drawn omnibox
        // child surface. Only this window and its children are admitted.
        let filter = SCContentFilter(display: display, including: [window])
        let scale = CGFloat(filter.pointPixelScale)
        guard let crop = crop(field: field, window: window, display: display, scale: scale) else { throw Failure.invalidBounds }
        let config = SCStreamConfiguration()
        config.captureResolution = .best
        config.scalesToFit = true
        config.sourceRect = crop
        config.width = Int((crop.width * scale).rounded())
        config.height = Int((crop.height * scale).rounded())
        config.showsCursor = false
        config.capturesAudio = false
        config.ignoreShadowsDisplay = true
        guard await validate(), CGPreflightScreenCaptureAccess(),
              let pid = window.owningApplication?.processID,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              frontWindowID(for: pid, frame: window.frame) == window.windowID
        else { throw Failure.denied }
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let capturedAt = ProcessInfo.processInfo.systemUptime
        guard capturedAt - requestedAt < 0.35 else { throw Failure.staleFrame }
        guard await validate() else { throw Failure.denied }
        guard ProcessInfo.processInfo.systemUptime - capturedAt < 0.25 else { throw Failure.staleFrame }
        guard image.width == config.width, image.height == config.height else { throw Failure.invalidDimensions }
        return Sample(image: image, origin: CGPoint(x: display.frame.minX + crop.minX, y: display.frame.minY + crop.minY), scale: scale, capturedAt: capturedAt)
    }
}

/// A continuous capture of one field crop inside one window, for fields
/// whose caret only pixels can place. Complete frames are handed on as
/// images. The window server sends nothing while pixels are unchanged, so
/// the last image repeats with a new time every 50 ms; blink evidence needs
/// samples closer together than a blink phase. A stream the system stops
/// repeats nothing and reports through `onStop`.
final class FieldStream: NSObject, SCStreamOutput, @unchecked Sendable {
    private let stream: SCStream
    private let queue = DispatchQueue(label: "caret.field-stream")
    private let origin: CGPoint
    private let scale: CGFloat
    private let onSample: @Sendable (FieldScreenshot.Sample) -> Void
    private var last: (image: CGImage, time: TimeInterval)?
    private var repeater: DispatchSourceTimer?
    /// Set on the queue by `stop` or a system stop; a start that finishes
    /// afterwards stops the capture it began.
    private var stopped = false
    private let watcher = StopWatcher()

    @MainActor
    init(window: SCWindow, display: SCDisplay, field: CGRect, onSample: @escaping @Sendable (FieldScreenshot.Sample) -> Void,
         onStop: @escaping @Sendable () -> Void) throws {
        let filter = SCContentFilter(display: display, including: [window])
        let scale = CGFloat(filter.pointPixelScale)
        guard let crop = FieldScreenshot.crop(field: field, window: window, display: display, scale: scale) else { throw FieldScreenshot.Failure.invalidBounds }
        let config = SCStreamConfiguration()
        config.captureResolution = .best
        config.scalesToFit = true
        config.sourceRect = crop
        config.width = Int((crop.width * scale).rounded())
        config.height = Int((crop.height * scale).rounded())
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        // Up to three frames are held at once (the repeated one, the one
        // waiting and the one being analysed); the rest keep the pool free.
        config.queueDepth = 6
        config.showsCursor = false
        config.capturesAudio = false
        config.ignoreShadowsDisplay = true
        self.scale = scale
        origin = CGPoint(x: display.frame.minX + crop.minX, y: display.frame.minY + crop.minY)
        self.onSample = onSample
        stream = SCStream(filter: filter, configuration: config, delegate: watcher)
        super.init()
        let queue = queue
        watcher.onStop = { [weak self] in
            queue.async {
                self?.halt()
                onStop()
            }
        }
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    }

    func start() async throws {
        try await stream.startCapture()
        // A stop that arrived while starting found nothing to stop.
        guard !queue.sync(execute: { stopped }) else {
            try? await stream.stopCapture()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.repeatLast() }
        queue.async {
            if self.stopped { timer.cancel() } else { self.repeater = timer }
            timer.resume()
        }
    }

    func stop() {
        queue.async { self.halt() }
        stream.stopCapture { _ in }
    }

    private func halt() {
        stopped = true
        repeater?.cancel()
        repeater = nil
        last = nil
    }

    private func repeatLast() {
        let now = ProcessInfo.processInfo.systemUptime
        guard !stopped, let last, now - last.time >= 0.045 else { return }
        self.last = (last.image, now)
        onSample(.init(image: last.image, origin: origin, scale: scale, capturedAt: now))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !stopped, type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        switch status {
        case .complete:
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
            guard let image else { return }
            last = (image, now)
            onSample(.init(image: image, origin: origin, scale: scale, capturedAt: now))
        case .idle:
            repeatLast()
        default:
            return
        }
    }
}

/// Serial pixel processing stays off the main actor. Generation changes
/// discard retained samples before a new field can contribute evidence.
actor BlinkCaretWorker {
    private var generation = -1
    private var detector = BlinkCaretDetector()
    private var currentInk: BlinkCaretDetector.RGB?
    private var context: (anchors: [CaretSearchAnchor], origin: CGPoint, scale: CGFloat)?

    /// The bounding box, in global points, of what changed between two
    /// samples of the same crop; nil when nothing did.
    func changedRect(from before: FieldScreenshot.Sample, to after: FieldScreenshot.Sample) -> CGRect? {
        guard before.origin == after.origin, before.scale == after.scale,
              let a = Self.frame(before.image), let b = Self.frame(after.image), a.width == b.width, a.height == b.height else { return nil }
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<a.height {
            for x in 0..<a.width {
                let i = (y * a.width + x) * 4
                if max(abs(Int(a.pixels[i]) - Int(b.pixels[i])), abs(Int(a.pixels[i + 1]) - Int(b.pixels[i + 1])),
                       abs(Int(a.pixels[i + 2]) - Int(b.pixels[i + 2]))) >= 40 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= 0 else { return nil }
        let scale = after.scale
        return CGRect(x: after.origin.x + CGFloat(minX) / scale, y: after.origin.y + CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    func reset(generation: Int) {
        guard generation >= self.generation else { return }
        self.generation = generation
        detector.reset()
        currentInk = nil
        context = nil
    }

    func observe(_ sample: FieldScreenshot.Sample, generation: Int, time: TimeInterval, anchors: [CaretSearchAnchor] = [],
                 solidSince: TimeInterval? = nil) -> CGRect? {
        guard generation >= self.generation else { return nil }
        if generation != self.generation { reset(generation: generation) }
        guard let frame = Self.frame(sample.image) else { reset(generation: generation); return nil }
        if let context, context.anchors != anchors || context.origin != sample.origin || context.scale != sample.scale {
            // Equal-sized crops can still refer to different screen pixels.
            detector.reset()
        }
        context = (anchors, sample.origin, sample.scale)
        // A static stem beside an AX anchor is indistinguishable from a
        // glyph, so temporal evidence authorizes this fallback. The exception
        // is the solid-caret interval after focus or input, when the caret is
        // drawn and is the one stroke spanning the whole line; glyphs are
        // shorter.
        var rect = detector.observe(frame, scale: sample.scale, time: time)
        if rect == nil, !detector.hasCandidate, let solidSince,
           time - solidSince >= 0, time - solidSince <= BlinkCaretDetector.solidCaretInterval,
           let stroke = BlinkCaretDetector.solidCaret(in: frame, scale: sample.scale) {
            detector.seed(stroke, in: frame, time: time)
            rect = stroke
        }
        currentInk = rect == nil ? nil : detector.ink
        guard let rect else { return nil }
        return CGRect(x: sample.origin.x + rect.midX / sample.scale,
                      y: sample.origin.y + rect.minY / sample.scale,
                      width: 0, height: rect.height / sample.scale)
    }

    /// Whether the last returned caret was confirmed by blinking.
    func confirmed(generation: Int) -> Bool {
        generation == self.generation && detector.confirmed
    }

    func ink(generation: Int) -> BlinkCaretDetector.RGB? {
        generation == self.generation ? currentInk : nil
    }

    private static func frame(_ image: CGImage) -> BlinkCaretDetector.Frame? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? .init(width: width, height: height, pixels: pixels) : nil
    }
}

/// Reports a stream the system stopped, such as when its window closed or
/// the permission was withdrawn.
private final class StopWatcher: NSObject, SCStreamDelegate, @unchecked Sendable {
    var onStop: (@Sendable () -> Void)?

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onStop?()
    }
}
