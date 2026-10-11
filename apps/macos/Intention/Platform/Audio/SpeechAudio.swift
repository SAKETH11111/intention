import AVFoundation

/// Converts whatever the input device records into the dictation endpoint's
/// format, 16 kHz mono 16-bit little-endian PCM, and cuts it into 100 ms
/// chunks. Used from one audio thread at a time; `Microphone` serializes it.
final class SpeechAudioConverter {
    static let sampleRate = 16_000.0
    /// 100 ms of audio: small enough that the endpoint hears speech as it
    /// happens, large enough not to flood the socket with messages.
    static let chunkBytes = 3_200
    static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!

    private let converter: AVAudioConverter
    private var pending = Data()

    init?(from input: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: input, to: Self.format) else { return nil }
        // Mix every channel into the one sent, rather than keep only the first.
        converter.downmix = true
        self.converter = converter
    }

    /// Converts one recorded buffer and returns the whole chunks now ready.
    /// The resampler holds back the last few tens of milliseconds until more
    /// audio arrives or `finish` drains it.
    func convert(_ buffer: AVAudioPCMBuffer) -> [Data] {
        guard buffer.frameLength > 0 else { return [] }
        let ratio = Self.sampleRate / buffer.format.sampleRate
        run(capacity: AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64, input: buffer)
        return takeChunks()
    }

    /// Everything left once recording stops, including what the resampler
    /// held back, so the last word is not clipped. The converter is spent
    /// afterwards.
    func finish() -> Data? {
        run(capacity: 4_096, input: nil)
        defer { pending.removeAll() }
        return pending.isEmpty ? nil : pending
    }

    /// One pass of the converter over `input`, or with nil to the end of
    /// the stream, appending what comes out to `pending`.
    private func run(capacity: AVAudioFrameCount, input buffer: AVAudioPCMBuffer?) {
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return }
        // The converter calls back synchronously, on this thread, before
        // `convert` returns.
        nonisolated(unsafe) var supplied = false
        nonisolated(unsafe) let input = buffer
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard let input else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, let samples = output.int16ChannelData else { return }
        pending.append(Data(bytes: samples[0], count: Int(output.frameLength) * 2))
    }

    private func takeChunks() -> [Data] {
        var chunks: [Data] = []
        while pending.count >= Self.chunkBytes {
            chunks.append(pending.prefix(Self.chunkBytes))
            pending.removeFirst(Self.chunkBytes)
        }
        return chunks
    }
}

/// Where a dictation's audio comes from: the microphone, or in Debug builds
/// a recording played at speaking pace.
enum CaptureIssue: Sendable, Equatable {
    case restarting, neverStarted
}

@MainActor
protocol SpeechAudioSource: AnyObject {
    /// The last completed stop's result. Use stop(completion:) when a
    /// later recording could start before native close finishes.
    var neverStarted: Bool { get }
    /// Starts recording. `audio` receives 16 kHz mono PCM chunks on a
    /// background thread, in order. `interrupted` runs on the main actor
    /// when the device goes away mid-recording, after the audio so far.
    /// `device` runs on the main actor with the name of each input opened
    /// for this recording, the first and any it moves to, so the person
    /// can be told which microphone a dictation that heard nothing used.
    /// The name can identify the person ("Alex's AirPods"): it is for
    /// their own notice and history on this Mac, never a log line or a
    /// request.
    func start(audio: @escaping @Sendable (Data) -> Void, interrupted: @escaping @MainActor () -> Void,
               device: @escaping @MainActor (String) -> Void) throws
    /// Starts with a separate live meter, without changing speech chunks.
    func start(audio: @escaping @Sendable (Data) -> Void, levels: RecordingLevels,
               interrupted: @escaping @MainActor () -> Void, device: @escaping @MainActor (String) -> Void) throws
    func start(audio: @escaping @Sendable (Data) -> Void, levels: RecordingLevels,
               interrupted: @escaping @MainActor () -> Void, device: @escaping @MainActor (String) -> Void,
               issue: @escaping @MainActor (CaptureIssue) -> Void) throws
    /// Native startup may finish after this returns. Its failure belongs to
    /// this recording alone. Synchronous sources keep throwing inline.
    func start(audio: @escaping @Sendable (Data) -> Void, levels: RecordingLevels,
               interrupted: @escaping @MainActor () -> Void, device: @escaping @MainActor (String) -> Void,
               issue: @escaping @MainActor (CaptureIssue) -> Void, failed: @escaping @MainActor (Error) -> Void) throws
    /// Completion follows the final PCM drain and carries this recording's
    /// result even if another recording has already started.
    func stop(completion: @escaping @MainActor (Bool) -> Void)
    /// Requests stop. Native close finishes asynchronously. Call the
    /// completion form before processing or retaining final audio.
    func stop()
}

extension SpeechAudioSource {
    func start(audio: @escaping @Sendable (Data) -> Void, levels: RecordingLevels,
               interrupted: @escaping @MainActor () -> Void, device: @escaping @MainActor (String) -> Void,
               issue: @escaping @MainActor (CaptureIssue) -> Void, failed: @escaping @MainActor (Error) -> Void) throws {
        try start(audio: audio, levels: levels, interrupted: interrupted, device: device, issue: issue)
    }
    func stop(completion: @escaping @MainActor (Bool) -> Void) {
        stop()
        completion(neverStarted)
    }

    var neverStarted: Bool { false }

    func start(audio: @escaping @Sendable (Data) -> Void, levels: RecordingLevels,
               interrupted: @escaping @MainActor () -> Void, device: @escaping @MainActor (String) -> Void,
               issue: @escaping @MainActor (CaptureIssue) -> Void) throws {
        try start(audio: audio, levels: levels, interrupted: interrupted, device: device)
    }
    /// Scripted and fixture sources keep their audio contract and also feed
    /// the 20 ms meter. Native sources override this to meter before chunking.
    func start(audio: @escaping @Sendable (Data) -> Void, levels: RecordingLevels,
               interrupted: @escaping @MainActor () -> Void, device: @escaping @MainActor (String) -> Void) throws {
        try start(audio: { @Sendable chunk in
            audio(chunk)
            levels.enqueue(chunk)
        }, interrupted: interrupted, device: device)
    }
}
