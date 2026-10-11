import AVFoundation
import Foundation
@testable import Dictation
import Testing

struct LevelFollowerTests {
    @Test func aStepReachesMostOfItsLevelWithinFiftyMilliseconds() {
        var follower = LevelFollower()
        let loud = SpeechLevel.of(DictationScenarioTests.tone(amplitude: 16_000).prefix(640))
        #expect(loud == 1)
        #expect(follower.advance(to: loud, seconds: 0.020) > 0.48)
        #expect(follower.advance(to: loud, seconds: 0.020) > 0.73)
        #expect(follower.advance(to: loud, seconds: 0.010) > 0.81)
    }

    @Test func releaseDecaysOverTwoHundredMillisecondsAndSilenceSettlesAtZero() {
        var follower = LevelFollower()
        _ = follower.advance(to: 1, seconds: 1)
        for _ in 0..<10 { _ = follower.advance(to: SpeechLevel.of(Data(count: 640)), seconds: 0.020) }
        #expect(abs(follower.value - exp(-1)) < 0.001)
        for _ in 0..<60 { _ = follower.advance(to: 0, seconds: 0.020) }
        #expect(follower.value == 0)
        #expect(follower.advance(to: 0, seconds: 0.020) == 0)
    }

    @Test func theEnvelopeDependsOnElapsedTimeRatherThanTickCount() {
        var whole = LevelFollower(), divided = LevelFollower()
        _ = whole.advance(to: 0.8, seconds: 0.060)
        for _ in 0..<3 { _ = divided.advance(to: 0.8, seconds: 0.020) }
        #expect(abs(whole.value - divided.value) < 1e-12)
        #expect(SpeechLevel.of(rms: 0) == 0)
        #expect(SpeechLevel.of(rms: .nan) == 0)
        #expect(SpeechLevel.of(rms: 0.5) == 1)
    }
}

@MainActor
struct RecordingLevelsTests {
    @Test func backgroundUpdatesCoalesceWhileTheMainActorIsBusy() async {
        var heard: [(Double, Bool)] = []
        let levels = RecordingLevels { heard.append(($0, Thread.isMainThread)) }
        defer { levels.close() }
        // Keep this actor occupied while the producer floods the meter.
        // No actor-isolated closure may run on the producer's queue.
        DispatchQueue(label: "co.intention.tests.levelProducer").sync { @Sendable in
            for _ in 0..<1_000 { levels.receive(1, seconds: 0.020) }
            levels.receive(0, seconds: 0.200)
        }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(heard.count == 1)
        #expect(heard.first?.1 == true)
        #expect(heard.first.map { abs($0.0 - exp(-1)) < 0.001 } == true)
    }

    @Test func closingInvalidatesPendingAndFutureCallbacks() async {
        var heard: [Double] = []
        let levels = RecordingLevels { heard.append($0) }
        DispatchQueue(label: "co.intention.tests.levelProducer").sync { @Sendable in
            levels.receive(1, seconds: 0.020)
        }
        levels.close()
        levels.receive(1, seconds: 1)
        levels.enqueue(DictationScenarioTests.tone(amplitude: 16_000))
        try? await Task.sleep(for: .milliseconds(60))
        #expect(heard.isEmpty)
    }

    @Test func theDrainMetersTwentyMillisecondsBeforeASpeechChunkExists() async throws {
        let audio = Collected()
        var heard: [Double] = []
        let levels = RecordingLevels { heard.append($0) }
        let drain = try #require(Drain(sampleRate: 16_000, levels: levels) { audio.add($0) })
        let samples = [Float](repeating: 0.5, count: 320)
        samples.withUnsafeBufferPointer { drain.ring.write($0.baseAddress!, $0.count) }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { @Sendable in
                drain.run()
                done.resume()
            }
        }
        // Hold the producer at this tick so a busy main actor cannot
        // correctly coalesce the short pulse away before this assertion.
        try await Task.sleep(for: .milliseconds(20))
        #expect(audio.chunks.isEmpty)
        #expect(heard.max().map { $0 > 0.4 } == true)
        levels.close()
        let stoppedCount = heard.count
        drain.stop()
        try await Task.sleep(for: .milliseconds(40))
        #expect(heard.count == stoppedCount)
        #expect(audio.chunks.reduce(0) { $0 + $1.count } == 640)
    }

    @Test func emptyDrainTicksPreserveTheLevelAndBuffersAdvanceByTheirSampleDuration() async throws {
        var heard: [Double] = []
        let levels = RecordingLevels { heard.append($0) }
        defer { levels.close() }
        let drain = try #require(Drain(sampleRate: 16_000, levels: levels) { _ in })
        defer { drain.stop() }
        let loud = [Float](repeating: 0.5, count: 512)
        loud.withUnsafeBufferPointer { drain.ring.write($0.baseAddress!, $0.count) }
        drain.run()
        #expect(await eventually { !heard.isEmpty })
        let first = try #require(heard.last)
        #expect(abs(first - (1 - exp(-0.032 / 0.030))) < 1e-9)
        // A 32 ms device buffer leaves some 20 ms drain ticks empty.
        // Follow that gap with more speech before yielding the main actor.
        drain.run()
        loud.withUnsafeBufferPointer { drain.ring.write($0.baseAddress!, $0.count) }
        drain.run()
        #expect(await eventually { heard.count >= 2 })
        #expect(heard.last.map { abs($0 - (1 - exp(-0.064 / 0.030))) < 1e-9 } == true)
        // Recorded zeros still release over the samples' duration.
        let silence = [Float](repeating: 0, count: 3_200)
        silence.withUnsafeBufferPointer { drain.ring.write($0.baseAddress!, $0.count) }
        drain.run()
        #expect(await eventually { heard.count >= 3 })
        #expect(heard.last.map { abs($0 - (1 - exp(-0.064 / 0.030)) * exp(-1)) < 1e-9 } == true)
    }

    @Test func chunkMeterCatchesUpAfterMissedTicksAndKeepsFractionalTime() async throws {
        let clock = MeterClock()
        var heard: [Double] = []
        let levels = RecordingLevels(clock: { clock.now }) { heard.append($0) }
        defer { levels.close() }
        // Bypass the real timer with a clock that has not advanced yet.
        levels.enqueue(DictationScenarioTests.tone(amplitude: 16_000))
        clock.now = 95_000_000
        levels.tick()
        #expect(await eventually { !heard.isEmpty })
        #expect(heard.last.map { abs($0 - (1 - exp(-0.080 / 0.030))) < 1e-9 } == true)
        clock.now = 100_000_000
        levels.tick()
        #expect(await eventually { heard.last.map { abs($0 - (1 - exp(-0.100 / 0.030))) < 1e-9 } == true })
        clock.now = 300_000_000
        levels.tick()
        #expect(await eventually { heard.last.map { abs($0 - (1 - exp(-0.100 / 0.030)) * exp(-1)) < 1e-9 } == true })
    }

    @Test func playbackLevelsCatchUpToTheAudioPositionAfterMissedTicks() async throws {
        let clock = MeterClock()
        let audio = Collected()
        var heard: [Double] = []
        let levels = RecordingLevels { heard.append($0) }
        defer { levels.close() }
        let loud = DictationScenarioTests.tone(amplitude: 16_000)
        // Preserve slice indices as converter chunks do.
        let silence = Data(count: 3_202).dropFirst(2)
        let playing = Playing(chunks: [silence, loud, silence], audio: { audio.add($0) },
                              levels: levels, clock: { clock.now })
        defer { playing.close() }
        clock.now = 100_000_000
        playing.next()
        clock.now = 200_000_000
        playing.next()
        playing.nextLevel()
        #expect(await eventually { !heard.isEmpty })
        #expect(audio.chunks == [silence, loud])
        #expect(heard.last.map { abs($0 - (1 - exp(-0.100 / 0.030))) < 1e-9 } == true)
        clock.now = 300_000_000
        playing.next()
        playing.nextLevel()
        #expect(await eventually { heard.last.map { abs($0 - (1 - exp(-0.100 / 0.030)) * exp(-0.100 / 0.200)) < 1e-9 } == true })
        #expect(audio.chunks == [silence, loud, silence])
    }

    @Test func meteringPreservesEveryAudioByteAndTapeDiagnostic() throws {
        let plainAudio = Collected(), meteredAudio = Collected()
        let levels = RecordingLevels { _ in }
        defer { levels.close() }
        let plain = try #require(Drain(sampleRate: 48_000) { plainAudio.add($0) })
        let metered = try #require(Drain(sampleRate: 48_000, levels: levels) { meteredAudio.add($0) })
        for tick in 0..<50 {
            let samples = (0..<960).map { frame -> Float in
                tick % 7 == 0 ? 0 : 0.5 * sin(2 * .pi * 440 * Float(tick * 960 + frame) / 48_000)
            }
            samples.withUnsafeBufferPointer {
                plain.ring.write($0.baseAddress!, $0.count)
                metered.ring.write($0.baseAddress!, $0.count)
            }
            plain.run()
            metered.run()
        }
        plain.stop()
        metered.stop()
        #expect(meteredAudio.chunks == plainAudio.chunks)
        let plainTape = DictationTape(), meteredTape = DictationTape()
        plainAudio.chunks.forEach(plainTape.append)
        meteredAudio.chunks.forEach(meteredTape.append)
        #expect(meteredTape.peak == plainTape.peak)
        #expect(meteredTape.zeroShare == plainTape.zeroShare)
        #expect(meteredTape.seconds == plainTape.seconds)
    }

    @Test func playbackMetersItsSamplesAndKeepsItsHundredMillisecondChunks() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = SpeechAudioConverter.format
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                      commonFormat: .pcmFormatInt16, interleaved: true)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000))
            buffer.frameLength = 32_000
            for index in 0..<32_000 { buffer.int16ChannelData![0][index] = index < 1_600 ? 0 : 16_000 }
            try file.write(from: buffer)
        }
        let playback = try RecordingPlayback(url: url)
        let audio = Collected()
        var heard: [Double] = []
        let levels = RecordingLevels { heard.append($0) }
        try playback.start(audio: { @Sendable in audio.add($0) }, levels: levels,
                           interrupted: {}, device: { _ in })
        let deadline = ContinuousClock.now + .seconds(3)
        while heard.max() ?? 0 < 0.9, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        levels.close()
        playback.stop()
        let stoppedCount = heard.count
        #expect(heard.max().map { $0 > 0.9 } == true)
        #expect((1...20).contains(audio.chunks.count))
        #expect(audio.chunks.allSatisfy { $0.count == 3_200 })
        try await Task.sleep(for: .milliseconds(60))
        #expect(heard.count == stoppedCount)
    }
}

private final class MeterClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: UInt64 = 0
    var now: UInt64 {
        get { lock.withLock { time } }
        set { lock.withLock { time = newValue } }
    }
}
