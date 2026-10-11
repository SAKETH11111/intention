import Foundation

/// The audio of one dictation, held in memory from the first chunk until the
/// dictation ends. Chunks reach the endpoint through it, in order: those
/// recorded before the connection is ready wait here and go out first, and
/// the whole recording can be sent again over a new connection when the
/// first one breaks. Twenty minutes, the endpoint's limit, is about 38 MB.
final class DictationTape: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var stream: DictationStream?
    private var loudest = 0
    private var samples = 0
    private var zeros = 0

    /// Called on the recording thread for each chunk.
    func append(_ chunk: Data) {
        let level = Self.level(of: chunk)
        lock.lock()
        defer { lock.unlock() }
        chunks.append(chunk)
        loudest = max(loudest, level.peak)
        samples += level.samples
        zeros += level.zeros
        stream?.send(chunk)
    }

    /// Sends everything recorded so far to `stream`, then each new chunk as
    /// it arrives.
    func attach(_ stream: DictationStream) {
        lock.lock()
        defer { lock.unlock() }
        chunks.forEach(stream.send)
        self.stream = stream
    }

    var recorded: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return chunks
    }

    /// The loudest sample recorded so far, from 0 to 32768: a level, never
    /// the audio itself.
    var peak: Int {
        lock.lock()
        defer { lock.unlock() }
        return loudest
    }

    /// The share of samples recorded so far that are exactly zero, from 0
    /// to 1; 1 before any. A microphone always hisses a little, so its
    /// samples are rarely exactly zero, though a headset that mutes itself
    /// between words gives runs of them.
    var zeroShare: Double {
        lock.lock()
        defer { lock.unlock() }
        return samples == 0 ? 1 : Double(zeros) / Double(samples)
    }

    /// Seconds of audio recorded.
    var seconds: Double {
        Double(recorded.reduce(0) { $0 + $1.count }) / 2 / SpeechAudioConverter.sampleRate
    }

    private static func level(of chunk: Data) -> (peak: Int, samples: Int, zeros: Int) {
        chunk.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count - 1, by: 2).reduce(into: (peak: 0, samples: 0, zeros: 0)) { level, offset in
                let sample = Int(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self)).magnitude)
                level.peak = max(level.peak, sample)
                level.samples += 1
                if sample == 0 { level.zeros += 1 }
            }
        }
    }
}
