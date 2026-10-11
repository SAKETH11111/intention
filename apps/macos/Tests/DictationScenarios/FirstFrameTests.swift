import AppKit
import Foundation
import Testing
@testable import Dictation

@MainActor
final class FrameWait {
    private var pending: [CheckedContinuation<Void, Never>] = []
    var count: Int { pending.count }
    func wait() async { await withCheckedContinuation { pending.append($0) } }
    func advance() { if !pending.isEmpty { pending.removeFirst().resume() } }
}

private final class FrameReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var received = false
    func mark() { lock.withLock { received = true } }
    var value: Bool { lock.withLock { received } }
}

private final class FrameTaskLifetime: Sendable {
    private let completed: FrameReceipt
    init(completed: FrameReceipt) { self.completed = completed }
    deinit { completed.mark() }
}

private enum FrameTaskContext {
    // An unstructured task inherits this value until it and its descendants
    // finish. Construct it inside withValue so the test retains no token
    // after that scope. Deinit signals through the thread-safe receipt.
    @TaskLocal static var lifetime: FrameTaskLifetime?
}

@MainActor
final class FirstFrameDevice: OpenMicrophone {
    nonisolated private let receipt = FrameReceipt()
    nonisolated private let audio: @Sendable (Data) -> Void
    var receivedFrames: Bool { receipt.value }
    var formatChanged = false
    var closed = false
    var frameOnClose = false
    let check: @MainActor () -> Void
    init(audio: @escaping @Sendable (Data) -> Void, check: @escaping @MainActor () -> Void) {
        self.audio = audio
        self.check = check
    }
    nonisolated func receive(silent: Bool = true) {
        receipt.mark()
        audio(Data(repeating: silent ? 0 : 1, count: SpeechAudioConverter.chunkBytes))
    }
    func close() {
        if frameOnClose { receive() }
        closed = true
    }
}

@MainActor
final class FirstFrameHardware: MicrophoneHardware {
    var permitted = true
    var refusesOpening = false
    var devices: [FirstFrameDevice] = []
    func inputs() -> AudioInputs { MadeUpInputs.inputs([MadeUpInputs.builtIn], default: MadeUpInputs.builtIn) }
    func open(_ device: AudioInput, audio: @escaping @Sendable (Data) -> Void,
              check: @escaping @MainActor () -> Void) throws -> any OpenMicrophone {
        if refusesOpening { throw Microphone.Failure.unavailable }
        let input = FirstFrameDevice(audio: audio, check: check)
        devices.append(input)
        return input
    }
}

@MainActor
struct FirstFrameTests {
    private func until(_ predicate: () -> Bool) async {
        for _ in 0..<100 where !predicate() { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate())
    }

    private func awaitRetirement(_ completed: FrameReceipt) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !completed.value && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(completed.value, "The cancelled microphone task or an inherited recovery task did not finish after its wait resumed")
    }

    @Test func aSuccessfulHALStartWithoutFramesRestartsExactlyOnce() async throws {
        let hardware = FirstFrameHardware(), wait = FrameWait()
        let microphone = Microphone(hardware: hardware)
        microphone.firstFrameWait = { _ in await wait.wait() }
        var issues: [CaptureIssue] = []
        let levels = RecordingLevels { _ in }
        try microphone.start(audio: { _ in }, levels: levels, interrupted: {}, device: { _ in }, issue: { issues.append($0) })
        await until { wait.count == 1 }
        wait.advance()
        await until { hardware.devices.count == 2 && wait.count == 1 }
        #expect(hardware.devices[0].closed)
        #expect(issues == [.restarting])
        wait.advance()
        await until { issues.count == 2 }
        #expect(issues == [.restarting, .neverStarted])
        #expect(hardware.devices.count == 2)
        #expect(hardware.devices[1].closed)
        microphone.stop()
        #expect(microphone.neverStarted)
        levels.close()
    }

    @Test func zeroValuedFramesFromABackgroundQueueAreSilenceAndNeedNoRestart() async throws {
        let hardware = FirstFrameHardware(), wait = FrameWait()
        let microphone = Microphone(hardware: hardware)
        microphone.firstFrameWait = { _ in await wait.wait() }
        let chunks = Collected()
        try microphone.start(audio: chunks.add, interrupted: {}, device: { _ in })
        await until { wait.count == 1 }
        let device = hardware.devices[0]
        await DictationScenarioTests.offMain { device.receive() }
        wait.advance()
        await Task.yield()
        microphone.stop()
        #expect(!microphone.neverStarted)
        #expect(hardware.devices.count == 1)
        #expect(chunks.chunks == [Data(repeating: 0, count: SpeechAudioConverter.chunkBytes)])
    }

    @Test func firstFramesAfterRestartRecoverTheSameRecording() async throws {
        let hardware = FirstFrameHardware(), wait = FrameWait()
        let microphone = Microphone(hardware: hardware)
        microphone.firstFrameWait = { _ in await wait.wait() }
        var names = 0
        try microphone.start(audio: { _ in }, interrupted: {}, device: { _ in names += 1 })
        await until { wait.count == 1 }
        wait.advance()
        await until { hardware.devices.count == 2 && wait.count == 1 }
        hardware.devices[1].receive()
        wait.advance()
        await until { names == 3 }
        microphone.stop()
        #expect(!microphone.neverStarted)
        #expect(hardware.devices.count == 2)
    }

    @Test func stoppedWatchdogCannotReopenTheNextRecording() async throws {
        let hardware = FirstFrameHardware(), wait = FrameWait()
        let microphone = Microphone(hardware: hardware)
        microphone.firstFrameWait = { _ in await wait.wait() }
        try microphone.start(audio: { _ in }, interrupted: {}, device: { _ in })
        await until { wait.count == 1 }
        microphone.stop()
        try microphone.start(audio: { _ in }, interrupted: {}, device: { _ in })
        await until { wait.count == 2 }
        wait.advance()
        await Task.yield()
        #expect(hardware.devices.count == 2)
        hardware.devices[1].receive()
        wait.advance()
        await Task.yield()
        microphone.stop()
        #expect(!microphone.neverStarted)
    }

    @Test func aPartialFrameDeliveredOnCloseKeepsTheRecordingRunning() async throws {
        let hardware = FirstFrameHardware(), wait = FrameWait()
        let microphone = Microphone(hardware: hardware)
        microphone.firstFrameWait = { _ in await wait.wait() }
        try microphone.start(audio: { _ in }, interrupted: {}, device: { _ in })
        await until { wait.count == 1 }
        hardware.devices[0].frameOnClose = true
        wait.advance()
        await until { hardware.devices[0].closed }
        #expect(hardware.devices.count == 2)
        #expect(!hardware.devices[1].closed)
        microphone.stop()
        #expect(!microphone.neverStarted)
    }

    @Test func replacementInputIsWatchedAfterEarlierFrames() async throws {
        let hardware = StandInHardware(MadeUpInputs.inputs([MadeUpInputs.builtIn], default: MadeUpInputs.builtIn))
        let wait = FrameWait()
        let microphone = Microphone(hardware: hardware)
        microphone.firstFrameWait = { _ in await wait.wait() }
        var names = 0
        try microphone.start(audio: { _ in }, interrupted: {}, device: { _ in names += 1 })
        defer { microphone.stop() }

        await until { wait.count == 1 }
        hardware.current?.speak()
        wait.advance()
        await until { names == 2 }

        hardware.current?.formatChanged = true
        hardware.current?.check()
        #expect(hardware.opened.count == 2)

        // The replacement HAL unit opened successfully but sends no frames.
        // Earlier audio must not exempt this input from the startup deadline.
        for _ in 0..<100 where wait.count == 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(wait.count == 1, "The replacement input must have its own first-frame deadline")
        guard wait.count == 1 else { return }
        wait.advance()
        await until { hardware.opened.count == 3 && wait.count == 1 }
        #expect(!microphone.neverStarted)

        hardware.current?.speak()
        wait.advance()
        await until { names == 5 }
    }

    @Test func repeatedCloseTimeFramesUseBoundedReopensThenDelayedRecovery() async throws {
        let hardware = FirstFrameHardware(), wait = FrameWait(), recovery = FrameWait()
        let microphone = Microphone(hardware: hardware)
        microphone.firstFrameWait = { _ in await wait.wait() }
        microphone.recoveryWait = { _ in await recovery.wait() }
        let chunks = Collected()
        var interruptions = 0
        var names = 0
        try microphone.start(audio: chunks.add, interrupted: { interruptions += 1 }, device: { _ in names += 1 })
        defer { microphone.stop() }

        // Each unit has no frames at its deadline but drains one on close.
        // Three immediate reopens are allowed before the existing recovery wait.
        for index in 0..<4 {
            await until { hardware.devices.count == index + 1 && wait.count == 1 }
            hardware.devices[index].frameOnClose = true
            wait.advance()
            await until { hardware.devices[index].closed }
            #expect(chunks.chunks.count == index + 1)
        }
        await until { recovery.count == 1 }
        #expect(interruptions == 1)
        #expect(hardware.devices.count == 4)
        #expect(hardware.devices.allSatisfy { $0.closed })
        #expect(wait.count == 0)
        #expect(!microphone.neverStarted)
        #expect(chunks.chunks == Array(repeating: Data(repeating: 0, count: SpeechAudioConverter.chunkBytes), count: 4))

        recovery.advance()
        await until { hardware.devices.count == 5 && wait.count == 1 }
        let replacement = hardware.devices[4]
        await DictationScenarioTests.offMain { replacement.receive(silent: false) }
        wait.advance()
        await until { names == 6 }
        #expect(!replacement.closed)
        #expect(hardware.devices.count == 5)
        microphone.stop()
        #expect(!microphone.neverStarted)
        #expect(chunks.chunks == Array(repeating: Data(repeating: 0, count: SpeechAudioConverter.chunkBytes), count: 4)
            + [Data(repeating: 1, count: SpeechAudioConverter.chunkBytes)])
    }

    @Test func lateFramesFromTheClosedInputDoNotExemptItsReplacement() async throws {
        let hardware = FirstFrameHardware(), wait = FrameWait(), recovery = FrameWait()
        let microphone = Microphone(hardware: hardware)
        microphone.firstFrameWait = { _ in await wait.wait() }
        microphone.recoveryWait = { _ in await recovery.wait() }
        let chunks = Collected()
        let levels = RecordingLevels { _ in }
        var issues: [CaptureIssue] = []
        var interruptions = 0
        try microphone.start(audio: chunks.add, levels: levels, interrupted: { interruptions += 1 }, device: { _ in }, issue: { issues.append($0) })
        defer { microphone.stop(); levels.close() }

        await until { wait.count == 1 }
        hardware.devices[0].frameOnClose = true
        wait.advance()
        await until { hardware.devices.count == 2 && wait.count == 1 }
        #expect(issues.isEmpty)
        #expect(chunks.chunks.count == 1)

        wait.advance()
        await until { hardware.devices.count == 3 && wait.count == 1 }
        #expect(issues == [.restarting])
        wait.advance()
        await until { recovery.count == 1 }
        #expect(interruptions == 1)
        #expect(issues == [.restarting])
        #expect(hardware.devices.count == 3)
        #expect(hardware.devices.allSatisfy { $0.closed })
        #expect(wait.count == 0)
        #expect(!microphone.neverStarted)
        microphone.stop()
        recovery.advance()
        #expect(!microphone.neverStarted)
        #expect(chunks.chunks == [Data(repeating: 0, count: SpeechAudioConverter.chunkBytes)])
    }

    @Test(arguments: [false, true])
    func replacementFramesIncludingSilencePreventAnotherRestart(silent: Bool) async throws {
        let hardware = FirstFrameHardware(), wait = FrameWait()
        let microphone = Microphone(hardware: hardware)
        microphone.firstFrameWait = { _ in await wait.wait() }
        let chunks = Collected()
        var names = 0
        try microphone.start(audio: chunks.add, interrupted: {}, device: { _ in names += 1 })
        defer { microphone.stop() }
        await until { wait.count == 1 }
        hardware.devices[0].receive(silent: false)
        wait.advance()
        await until { names == 2 }

        hardware.devices[0].formatChanged = true
        hardware.devices[0].check()
        await until { hardware.devices.count == 2 && wait.count == 1 }
        let replacement = hardware.devices[1]
        await DictationScenarioTests.offMain { replacement.receive(silent: silent) }
        wait.advance()
        await until { names == 4 }
        #expect(hardware.devices.count == 2)
        #expect(!replacement.closed)
        #expect(chunks.chunks == [Data(repeating: 1, count: SpeechAudioConverter.chunkBytes),
                                 Data(repeating: silent ? 0 : 1, count: SpeechAudioConverter.chunkBytes)])
        microphone.stop()
        #expect(!microphone.neverStarted)
    }

    @Test func earlierSuccessfulAudioDoesNotResetTheRecordingRetryLimit() async throws {
        let hardware = FirstFrameHardware(), wait = FrameWait(), recovery = FrameWait()
        let microphone = Microphone(hardware: hardware)
        microphone.firstFrameWait = { _ in await wait.wait() }
        microphone.recoveryWait = { _ in await recovery.wait() }
        let levels = RecordingLevels { _ in }
        var issues: [CaptureIssue] = []
        var names = 0
        var interruptions = 0
        try microphone.start(audio: { _ in }, levels: levels, interrupted: { interruptions += 1 }, device: { _ in names += 1 }, issue: { issues.append($0) })
        defer { microphone.stop(); levels.close() }
        await until { wait.count == 1 }
        wait.advance()
        await until { hardware.devices.count == 2 && wait.count == 1 }
        #expect(issues == [.restarting])
        hardware.devices[1].receive()
        wait.advance()
        await until { names == 3 }

        hardware.devices[1].formatChanged = true
        hardware.devices[1].check()
        await until { hardware.devices.count == 3 && wait.count == 1 }
        wait.advance()
        await until { recovery.count == 1 }
        #expect(issues == [.restarting])
        #expect(interruptions == 1)
        #expect(hardware.devices.count == 3)
        #expect(hardware.devices[2].closed)
        #expect(wait.count == 0)
        #expect(!microphone.neverStarted)

        // Delayed recovery does not grant another immediate first-frame retry.
        recovery.advance()
        await until { hardware.devices.count == 4 && wait.count == 1 }
        wait.advance()
        await until { recovery.count == 1 }
        #expect(interruptions == 2)
        #expect(issues == [.restarting])
        #expect(hardware.devices.count == 4)
        #expect(hardware.devices[3].closed)
        microphone.stop()
        recovery.advance()
        #expect(!microphone.neverStarted)
    }

    @Test(arguments: [false, true])
    func aFailedFirstFrameRetryIsTerminalOnlyWithoutEarlierAudio(receivedEarlierFrames: Bool) async throws {
        let hardware = FirstFrameHardware(), wait = FrameWait(), recovery = FrameWait()
        let microphone = Microphone(hardware: hardware)
        microphone.firstFrameWait = { _ in await wait.wait() }
        microphone.recoveryWait = { _ in await recovery.wait() }
        let chunks = Collected(), levels = RecordingLevels { _ in }
        var names = 0
        var interruptions = 0
        var issues: [CaptureIssue] = []
        try microphone.start(audio: chunks.add, levels: levels, interrupted: { interruptions += 1 },
                             device: { _ in names += 1 }, issue: { issues.append($0) })
        defer { microphone.stop(); levels.close() }
        await until { wait.count == 1 }
        if receivedEarlierFrames {
            hardware.devices[0].receive(silent: false)
            wait.advance()
            await until { names == 2 }
            hardware.devices[0].formatChanged = true
            hardware.devices[0].check()
            await until { hardware.devices.count == 2 && wait.count == 1 }
        }
        hardware.refusesOpening = true
        wait.advance()
        if receivedEarlierFrames {
            await until { recovery.count == 1 }
            #expect(interruptions == 1)
            #expect(issues.isEmpty)
            #expect(!microphone.neverStarted)
            #expect(chunks.chunks == [Data(repeating: 1, count: SpeechAudioConverter.chunkBytes)])
        } else {
            await until { issues == [.neverStarted] }
            #expect(interruptions == 0)
            #expect(recovery.count == 0)
            #expect(microphone.neverStarted)
            #expect(chunks.chunks.isEmpty)
        }
        #expect(hardware.devices.allSatisfy { $0.closed })
        #expect(hardware.devices.count == (receivedEarlierFrames ? 2 : 1))
        microphone.stop()
        recovery.advance()
        #expect(microphone.neverStarted == !receivedEarlierFrames)
    }

    @Test(arguments: [false, true])
    func stoppingDuringFirstFrameRecoveryCannotReopenOrAffectTheNextRecording(supersede: Bool) async throws {
        let hardware = FirstFrameHardware(), wait = FrameWait(), recovery = FrameWait()
        let microphone = Microphone(hardware: hardware)
        microphone.firstFrameWait = { _ in await wait.wait() }
        microphone.recoveryWait = { _ in await recovery.wait() }
        var names = 0
        var interruptions = 0
        try microphone.start(audio: { _ in }, interrupted: { interruptions += 1 }, device: { _ in names += 1 })
        defer { microphone.stop() }
        await until { wait.count == 1 }
        hardware.devices[0].receive()
        wait.advance()
        await until { names == 2 }
        let retired = FrameReceipt()
        FrameTaskContext.$lifetime.withValue(FrameTaskLifetime(completed: retired)) {
            hardware.devices[0].formatChanged = true
            hardware.devices[0].check()
        }
        await until { hardware.devices.count == 2 && wait.count == 1 }
        wait.advance()
        await until { hardware.devices.count == 3 && wait.count == 1 }
        wait.advance()
        await until { recovery.count == 1 }
        #expect(interruptions == 1)
        #expect(!retired.value)
        microphone.stop()
        #expect(!microphone.neverStarted)
        #expect(!retired.value, "The cancelled recovery must retain its task lifetime while its wait is blocked")
        if supersede {
            try microphone.start(audio: { _ in }, interrupted: { interruptions += 1 }, device: { _ in names += 1 })
            await until { hardware.devices.count == 4 && wait.count == 1 }
        }
        recovery.advance()
        await awaitRetirement(retired)
        #expect(hardware.devices.count == (supersede ? 4 : 3))
        #expect(interruptions == 1)
        #expect(hardware.devices[2].closed)
        if supersede {
            #expect(!hardware.devices[3].closed)
            hardware.devices[3].receive()
            wait.advance()
            await until { names == 6 }
            microphone.stop()
            #expect(!microphone.neverStarted)
        }
    }

    @Test(arguments: [false, true])
    func aStoppedReplacementDeadlineCannotReopenOrAffectTheNextRecording(supersede: Bool) async throws {
        let hardware = FirstFrameHardware(), wait = FrameWait()
        let microphone = Microphone(hardware: hardware)
        microphone.firstFrameWait = { _ in await wait.wait() }
        var names = 0
        try microphone.start(audio: { _ in }, interrupted: {}, device: { _ in names += 1 })
        defer { microphone.stop() }
        await until { wait.count == 1 }
        hardware.devices[0].receive()
        wait.advance()
        await until { names == 2 }
        let retired = FrameReceipt()
        FrameTaskContext.$lifetime.withValue(FrameTaskLifetime(completed: retired)) {
            hardware.devices[0].formatChanged = true
            hardware.devices[0].check()
        }
        await until { hardware.devices.count == 2 && wait.count == 1 }
        #expect(!retired.value)
        microphone.stop()
        #expect(!microphone.neverStarted)
        #expect(!retired.value, "The cancelled watchdog must retain its task lifetime while its wait is blocked")

        if supersede {
            try microphone.start(audio: { _ in }, interrupted: {}, device: { _ in names += 1 })
            await until { wait.count == 2 }
        }
        wait.advance()
        await awaitRetirement(retired)
        #expect(hardware.devices.count == (supersede ? 3 : 2))
        #expect(hardware.devices[1].closed)
        if supersede {
            #expect(!hardware.devices[2].closed)
            hardware.devices[2].receive()
            wait.advance()
            await until { names == 5 }
            #expect(hardware.devices.count == 3)
            #expect(!microphone.neverStarted)
        }
    }
}

extension DictationScenarioTests {
    @Test func replacementExhaustionReconnectsAndReleasesEarlierAudio() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let hardware = FirstFrameHardware(), wait = FrameWait(), recovery = FrameWait()
        let microphone = Microphone(hardware: hardware)
        microphone.firstFrameWait = { _ in await wait.wait() }
        microphone.recoveryWait = { _ in await recovery.wait() }
        let dictation = controller(server.endpoint, source: microphone)
        defer { dictation.escapePressed(); microphone.stop(); recovery.advance() }
        var issues: [String?] = []
        dictation.recordingIssueChanged = { issues.append($0) }

        // A confirmed hold bypasses gesture timing without posting a key.
        dictation.holdBegan(confirmed: true)
        #expect(await eventually { hardware.devices.count == 1 && wait.count == 1 })
        let first = try #require(hardware.devices.first)
        await Self.offMain { first.receive(silent: false) }
        wait.advance()
        #expect(await eventually { wait.count == 0 })
        first.formatChanged = true
        first.check()
        #expect(await eventually { hardware.devices.count == 2 && wait.count == 1 })
        wait.advance()
        #expect(await eventually { hardware.devices.count == 3 && wait.count == 1 })
        wait.advance()
        #expect(await eventually { recovery.count == 1 })
        #expect(dictation.phase == .recording)
        #expect(dictation.recordingIssue == "Reconnecting microphone…")
        #expect(dictation.problem == .microphoneUnavailable)
        #expect(!issues.contains("Microphone didn't start. Try again."))
        #expect(!microphone.neverStarted)
        #expect(field.text == "abc")
        #expect(field.accessibilityWrites == 0)
        #expect(field.keys.isEmpty)
        #expect(dictation.history.entries.isEmpty)
        #expect(await eventually { server.connections.first?.frames == 1 })
        #expect(server.connections.first?.stopFrames == nil)

        dictation.holdEnded()
        recovery.advance()
        await idle(dictation)
        #expect(dictation.recordingIssue == nil)
        #expect(!microphone.neverStarted)
        #expect(field.text == "aHello.bc")
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
        #expect(dictation.history.entries.count == 1)
        #expect(dictation.history.entries.first?.outcome == .inserted)
        #expect(server.connections.count == 1)
        let connection = try #require(server.connections.first)
        #expect(connection.frames == 1)
        #expect(connection.stopFrames == 1)
        #expect(connection.audio == Data(repeating: 1, count: SpeechAudioConverter.chunkBytes))
        #expect(!connection.cancelled)
    }

    @Test func noFramesAndSilentFramesHaveDifferentFinalNotices() async throws {
        for receives in [false, true] {
            let server = try await ScriptedEndpoint([.answer(transcript: "", text: "")])
            defer { server.stop() }
            let hardware = FirstFrameHardware()
            let microphone = Microphone(hardware: hardware)
            let dictation = controller(server.endpoint, source: microphone)
            var empty: DictationController.EmptyResult?
            dictation.silent = { empty = $0 }
            dictation.toggle()
            if receives { hardware.devices.first?.receive() }
            dictation.toggle()
            await idle(dictation)
            #expect(empty?.silence == (receives ? .microphone : .neverStarted))
            #expect(empty.map(FootState.words(for:)) == (receives ? "No sound from MacBook Pro Microphone" : "Microphone didn't start. Try again."))
            #expect(MockField.shared.accessibilityWrites == 0)
            #expect(MockField.shared.keys.isEmpty)
        }
    }

    @Test func anUncertainDictationShowsTheWarningWithoutAnotherWrite() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        MockField.shared.writes = .held
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(dictation.history.entries.first?.outcome == .uncertain)
        #expect(dictation.notice == .insertionUncertain)
        #expect(MockField.shared.accessibilityWrites == 1)
        #expect(MockField.shared.keys.isEmpty)
        let row = try #require(dictation.history.sections(matching: "", now: Date(), calendar: .current).first?.rows.first)
        let shown = RowPresentation(row)
        #expect(row.state == .uncertain)
        #expect(shown.status == "May have gone in. Check before pasting again")
        #expect(shown.actions == [.copy])
    }
}
