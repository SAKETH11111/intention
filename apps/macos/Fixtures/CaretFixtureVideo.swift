#if DEBUG
import AppKit
import AVFoundation

/// Records only images already captured and validated by the fixture runner.
/// This type has no screen, input, Accessibility or app-activation capability.
/// Original sample timestamps preserve gaps instead of speeding up the demo.
@MainActor
final class CaretFixtureVideo {
    enum Failure: Error { case dimensions, writer, buffer, backpressure, encoding(String), timestamps([Double]) }
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let width: Int
    private let height: Int
    private(set) var times: [Double] = []

    init(url: URL, image: CGImage) throws {
        width = (image.width + 1) / 2 * 2
        height = (image.height + 1) / 2 * 2
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(2_000_000, width * height * 12),
                                              AVVideoAllowFrameReorderingKey: false],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ])
        guard writer.canAdd(input) else { throw Failure.writer }
        writer.add(input)
        guard writer.startWriting() else { throw Failure.writer }
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ image: CGImage, time: Double, validate: () -> Bool) throws {
        guard image.width <= width, image.height <= height,
              image.width >= width - 1, image.height >= height - 1,
              time.isFinite, time >= 0, times.last.map({ time > $0 }) ?? true else { throw Failure.dimensions }
        // Never queue a delayed screenshot for later acceptance after focus loss.
        guard input.isReadyForMoreMediaData else { throw Failure.backpressure }
        guard let pool = adaptor.pixelBufferPool else { throw Failure.buffer }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { throw Failure.buffer }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        else { throw Failure.buffer }
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: height - image.height, width: image.width, height: image.height))
        guard validate() else { throw Failure.writer }
        guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(seconds: time, preferredTimescale: 60_000)) else {
            throw Failure.encoding(writer.error?.localizedDescription ?? "append failed")
        }
        times.append(time)
    }

    func finish() async throws {
        if let last = times.last { writer.endSession(atSourceTime: CMTime(seconds: last + 1.0 / 30, preferredTimescale: 60_000)) }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure.encoding(writer.error?.localizedDescription ?? "finish failed") }
    }

    /// Generated pixels only. Checks encoding, timestamps and denial before
    /// accepting any image; this is never presented as live app evidence.
    static func selfCheck(at url: URL) async throws {
        guard let context = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8,
                                      bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.buffer }
        context.setFillColor(NSColor.green.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        guard let image = context.makeImage() else { throw Failure.buffer }
        let video = try CaretFixtureVideo(url: url, image: image)
        do {
            try video.append(image, time: 0, validate: { false })
            throw Failure.buffer
        } catch Failure.writer {}
        guard video.times.isEmpty else { throw Failure.writer }
        let expected = [0.0, 0.2, 0.65, 1.0]
        for time in expected {
            try video.append(image, time: time, validate: { true })
            try await Task.sleep(for: .milliseconds(30))
        }
        try await video.finish()
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.writer }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        guard reader.startReading() else { throw Failure.writer }
        var actual: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            actual.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
        }
        actual.sort()
        guard reader.status == .completed, actual.count == expected.count,
              zip(actual, expected).allSatisfy({ abs($0 - $1) < 0.001 }) else { throw Failure.timestamps(actual) }
    }
}

#endif
