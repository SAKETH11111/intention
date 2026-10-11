#if DEBUG
import AVFoundation

/// Plays a recording into dictation in place of the microphone, at speaking
/// pace, so dictation can be checked end to end with known audio and no
/// microphone. Debug builds use it when launched with
/// `--dictation-audio <file>`. The recording plays from its start each time
/// dictation starts; once it ends, nothing more is sent until the stop.
@MainActor
final class RecordingPlayback: SpeechAudioSource {
    private let chunks: [Data]
    private var timer: DispatchSourceTimer?
    private var levelTimer: DispatchSourceTimer?
    private var playing: Playing?

    init(url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let converter = SpeechAudioConverter(from: file.processingFormat) else { throw Microphone.Failure.unavailable }
        try file.read(into: buffer)
        chunks = converter.convert(buffer) + (converter.finish().map { [$0] } ?? [])
    }

    /// How long the recording plays.
    var duration: Duration { .milliseconds(100 * chunks.count) }

    /// A recording names no device, so a dictation from it says what the
    /// microphone's would without one.
    func start(audio: @escaping @Sendable (Data) -> Void, interrupted: @escaping @MainActor () -> Void,
               device: @escaping @MainActor (String) -> Void) throws {
        start(audio: audio, levels: nil)
    }

    func start(audio: @escaping @Sendable (Data) -> Void, levels: RecordingLevels,
               interrupted: @escaping @MainActor () -> Void, device: @escaping @MainActor (String) -> Void) throws {
        start(audio: audio, levels: levels)
    }

    private func start(audio: @escaping @Sendable (Data) -> Void, levels: RecordingLevels?) {
        stop()
        let playing = Playing(chunks: chunks, audio: audio, levels: levels)
        let queue = DispatchQueue(label: "co.intention.mac.playback")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // One chunk is 100 ms of audio.
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100), leeway: .milliseconds(2))
        timer.setEventHandler { @Sendable in playing.next() }
        timer.resume()
        self.timer = timer
        self.playing = playing
        if levels != nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(2))
            timer.setEventHandler { @Sendable in playing.nextLevel() }
            timer.resume()
            levelTimer = timer
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        levelTimer?.cancel()
        levelTimer = nil
        playing?.close()
        playing = nil
    }
}

final class Playing: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: @Sendable () -> UInt64
    private let chunks: [Data]
    private let audio: @Sendable (Data) -> Void
    private let levels: RecordingLevels?
    private var index = 0
    private var levelIndex = 0
    private var levelOffset = 0
    private let startedAt: UInt64
    private var levelWindows: UInt64 = 0
    private var closed = false

    init(chunks: [Data], audio: @escaping @Sendable (Data) -> Void, levels: RecordingLevels?,
         clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.clock = clock
        startedAt = clock()
        self.chunks = chunks
        self.audio = audio
        self.levels = levels
    }

    func next() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        let now = clock()
        guard now >= startedAt else { return }
        let due = min(chunks.count, Int((now - startedAt) / 100_000_000))
        while index < due {
            audio(chunks[index])
            index += 1
        }
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    func nextLevel() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, let levels else { return }
        let now = clock()
        guard now >= startedAt else { return }
        // Audio and levels share a clock origin. Missing a callback never
        // leaves either cursor playing an earlier part of the recording.
        let due = (now - startedAt) / 20_000_000
        while levelWindows < due, levelIndex < chunks.count {
            var pcm = Data()
            while pcm.count < 640, levelIndex < chunks.count {
                let chunk = chunks[levelIndex]
                // Converter chunks may be slices whose startIndex is not zero.
                let samples = chunk.dropFirst(levelOffset).prefix(640 - pcm.count)
                pcm.append(samples)
                levelOffset += samples.count
                if levelOffset == chunk.count {
                    levelIndex += 1
                    levelOffset = 0
                }
            }
            levels.receive(SpeechLevel.of(pcm), seconds: 0.020)
            levelWindows += 1
        }
        if levelWindows < due {
            levels.receive(0, seconds: Double(due - levelWindows) * 0.020)
            levelWindows = due
        }
    }
}
#endif
