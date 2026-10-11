import AppKit
@testable import Dictation
import Testing

/// The level a dictation's log line gives its recording: a fixed name from
/// the loudest sample and the share of exact zeros the tape counted as the
/// audio arrived, never the audio.
struct DictationLevelTests {
    private static func name(_ chunks: [[Int16]]) -> String {
        let tape = DictationTape()
        for samples in chunks { tape.append(samples.withUnsafeBytes { Data($0) }) }
        return DictationController.levelName(peak: tape.peak, zeroShare: tape.zeroShare)
    }

    @Test func namesHowLoudTheRecordingWasAndHowMuchOfItWasExactlyZero() {
        #expect(Self.name([]) == "level.silent.zeros.most")
        #expect(Self.name([Array(repeating: 0, count: 1600)]) == "level.silent.zeros.most")
        // Hiss just under -60 dBFS is still no sound.
        #expect(Self.name([[32, -32, 5, -7]]) == "level.silent.zeros.few")
        #expect(Self.name([[33, -12, 4, -9]]) == "level.faint.zeros.few")
        #expect(Self.name([[-1036, 300, -20, 15]]) == "level.sound.zeros.few")
        // Int16.min has no positive counterpart and still counts as loud.
        #expect(Self.name([[Int16.min, 1, 2, 3]]) == "level.sound.zeros.few")
        // Intention 0.1.0 recorded a Bluetooth headset 93% zero with fragments between.
        #expect(Self.name([Array(repeating: 0, count: 93) + Array(repeating: 2000, count: 7)]) == "level.sound.zeros.most")
        #expect(Self.name([Array(repeating: 0, count: 30) + Array(repeating: 2000, count: 70)]) == "level.sound.zeros.some")
    }

    @Test func countsEveryChunk() {
        #expect(Self.name([[0, 0], [2000]]) == "level.sound.zeros.some")
        #expect(Self.name([Array(repeating: 0, count: 9), Array(repeating: 0, count: 9) + [2000]]) == "level.sound.zeros.most")
    }
}
