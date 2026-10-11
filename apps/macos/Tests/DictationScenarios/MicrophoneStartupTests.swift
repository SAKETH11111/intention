import AppKit
import Foundation
import Testing
@testable import Dictation

@MainActor
private final class DeferredMicrophoneHardware: MicrophoneHardware {
    struct Request {
        let audio: @Sendable (Data) -> Void
        let check: @MainActor () -> Void
        let finish: @MainActor (Result<any OpenMicrophone, Error>) -> Void
    }
    var permitted = true
    var requests: [Request] = []
    func inputs() -> AudioInputs { MadeUpInputs.inputs([MadeUpInputs.builtIn], default: MadeUpInputs.builtIn) }
    func open(_ device: AudioInput, audio: @escaping @Sendable (Data) -> Void,
              check: @escaping @MainActor () -> Void) throws -> any OpenMicrophone {
        throw Microphone.Failure.unavailable
    }
    func open(_ device: AudioInput, audio: @escaping @Sendable (Data) -> Void, levels: RecordingLevels?,
              cancellation: MicrophoneOpenCancellation, check: @escaping @MainActor () -> Void,
              completion: @escaping @MainActor (Result<any OpenMicrophone, Error>) -> Void) throws {
        requests.append(Request(audio: audio, check: check, finish: completion))
    }
    func succeed(_ index: Int) -> DeferredMicrophoneInput {
        let input = DeferredMicrophoneInput(audio: requests[index].audio)
        requests[index].finish(.success(input))
        return input
    }
}

@MainActor
private final class DeferredMicrophoneInput: OpenMicrophone {
    let audio: @Sendable (Data) -> Void
    var receivedFrames = false
    var formatChanged = false
    var closed = false
    var completions: [@MainActor () -> Void] = []
    init(audio: @escaping @Sendable (Data) -> Void) { self.audio = audio }
    func close() { closed = true }
    func close(completion: @escaping @MainActor () -> Void) { completions.append(completion) }
    func finishClose(withFrame: Bool) {
        if withFrame {
            receivedFrames = true
            audio(Data(repeating: 0, count: 320))
        }
        closed = true
        let callbacks = completions
        completions = []
        callbacks.forEach { $0() }
    }
}

/// Holds main-actor results while the serial worker continues. It never runs
/// an actor callback on the worker and never blocks the main actor.
private final class StartupMainDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [@MainActor @Sendable () -> Void] = []
    func enqueue(_ action: @escaping @MainActor @Sendable () -> Void) { lock.withLock { actions.append(action) } }
    var count: Int { lock.withLock { actions.count } }
    @MainActor func next() { lock.withLock { actions.removeFirst() }() }
}

private final class StartupNativeState: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    private var buffered: [UInt32: [Data]] = [:]
    private var received: Set<UInt32> = []
    let gate = DispatchSemaphore(value: 0)
    private var entered = false
    var firstEntered: Bool { lock.withLock { entered } }
    var events: [String] { lock.withLock { entries } }
    func note(_ value: String) { lock.withLock { entries.append(value) } }
    func record(_ id: UInt32, _ data: Data) {
        lock.withLock {
            received.insert(id)
            buffered[id, default: []].append(data)
        }
    }
    func receivedFrames(_ id: UInt32) -> Bool { lock.withLock { received.contains(id) } }
    func takeBuffered(_ id: UInt32) -> [Data] { lock.withLock { buffered.removeValue(forKey: id) ?? [] } }
    func open(_ id: UInt32, audio: @escaping @Sendable (Data) -> Void) throws -> any NativeMicrophoneInput {
        note("open.\(id)")
        if id == 1 {
            lock.withLock { entered = true }
            guard gate.wait(timeout: .now() + 5) == .success else { throw Microphone.Failure.unavailable }
        }
        return StartupNativeInput(id: id, owner: self, audio: audio)
    }
}

private final class StartupNativeInput: NativeMicrophoneInput, @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    let id: UInt32
    let owner: StartupNativeState
    let audio: @Sendable (Data) -> Void
    var receivedFrames: Bool { owner.receivedFrames(id) }
    var formatChanged: Bool { false }
    init(id: UInt32, owner: StartupNativeState, audio: @escaping @Sendable (Data) -> Void) {
        self.id = id
        self.owner = owner
        self.audio = audio
    }
    func close() {
        let first = lock.withLock {
            guard !closed else { return false }
            closed = true
            return true
        }
        guard first else { return }
        owner.note("close.\(id)")
        owner.takeBuffered(id).forEach(audio)
        owner.note("drain.\(id)")
    }
}

@MainActor
private final class StartupNativeHardware: MicrophoneHardware {
    var permitted = true
    var core: CoreAudioMicrophones
    var next: UInt32 = 0
    init(core: CoreAudioMicrophones) { self.core = core }
    func inputs() -> AudioInputs { MadeUpInputs.inputs([MadeUpInputs.builtIn], default: MadeUpInputs.builtIn) }
    func open(_ device: AudioInput, audio: @escaping @Sendable (Data) -> Void,
              check: @escaping @MainActor () -> Void) throws -> any OpenMicrophone { throw Microphone.Failure.unavailable }
    func open(_ device: AudioInput, audio: @escaping @Sendable (Data) -> Void, levels: RecordingLevels?,
              cancellation: MicrophoneOpenCancellation, check: @escaping @MainActor () -> Void,
              completion: @escaping @MainActor (Result<any OpenMicrophone, Error>) -> Void) throws {
        next += 1
        let synthetic = AudioInput(id: next, uid: device.uid, name: device.name, isBuiltIn: device.isBuiltIn)
        try core.open(synthetic, audio: audio, levels: levels, cancellation: cancellation, check: check, completion: completion)
    }
}

extension DictationScenarioTests {
@MainActor
struct MicrophoneStartupTests {
    private func until(_ predicate: () -> Bool) async {
        for _ in 0..<200 where !predicate() { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate())
    }

    @Test func pendingOpenDoesNotStartTheFirstFrameWatchdog() async throws {
        let hardware = DeferredMicrophoneHardware()
        let source = Microphone(hardware: hardware)
        var waits = 0
        source.firstFrameWait = { _ in waits += 1 }
        try source.start(audio: { _ in }, interrupted: {}, device: { _ in })
        await Task.yield()
        #expect(hardware.requests.count == 1)
        #expect(waits == 0)
        var results: [Bool] = []
        source.stop { results.append($0) }
        #expect(results.isEmpty)
        let retired = hardware.succeed(0)
        #expect(results.isEmpty)
        retired.finishClose(withFrame: false)
        #expect(retired.closed)
        #expect(results == [true])
        #expect(waits == 0)
    }

    @Test(arguments: [false, true])
    func stoppedOpenCannotPublishSuccessFailureAudioOrRecovery(fail: Bool) throws {
        let hardware = DeferredMicrophoneHardware(), old = Collected(), current = Collected()
        let source = Microphone(hardware: hardware)
        var names = 0, failures = 0, interrupted = 0
        let levels = RecordingLevels { _ in }
        try source.start(audio: old.add, levels: levels, interrupted: { interrupted += 1 }, device: { _ in names += 1 },
                         issue: { _ in interrupted += 1 }, failed: { _ in failures += 1 })
        source.stop()
        try source.start(audio: current.add, interrupted: {}, device: { _ in names += 1 })
        if fail { hardware.requests[0].finish(.failure(Microphone.Failure.unavailable)) }
        else {
            let retired = hardware.succeed(0)
            retired.finishClose(withFrame: false)
            #expect(retired.closed)
        }
        hardware.requests[0].audio(Data(repeating: 0, count: 320))
        hardware.requests[0].check()
        #expect(old.chunks.isEmpty)
        #expect(current.chunks.isEmpty)
        #expect(names == 0 && failures == 0 && interrupted == 0)
        #expect(hardware.requests.count == 2)
        source.stop()
    }

    @Test func anOldCloseCompletesOnceWithItsOwnFinalFrameAfterANewRecordingBegins() throws {
        let hardware = DeferredMicrophoneHardware(), old = Collected(), current = Collected()
        let source = Microphone(hardware: hardware)
        try source.start(audio: old.add, interrupted: {}, device: { _ in })
        let first = hardware.succeed(0)
        var results: [Bool] = []
        source.stop { results.append($0) }
        #expect(results.isEmpty)
        try source.start(audio: current.add, interrupted: {}, device: { _ in })
        first.finishClose(withFrame: true)
        first.finishClose(withFrame: false)
        #expect(results == [false])
        #expect(old.chunks.count == 1)
        #expect(current.chunks.isEmpty)
        #expect(!source.neverStarted)
        source.stop { results.append($0) }
        #expect(results == [false])
        let replacement = hardware.succeed(1)
        #expect(results == [false])
        replacement.finishClose(withFrame: false)
        #expect(results == [false, true])
    }

    @Test func stopDuringAWatchdogCloseWaitsForItsFinalDrain() async throws {
        let hardware = DeferredMicrophoneHardware(), wait = FrameWait(), chunks = Collected()
        let source = Microphone(hardware: hardware)
        source.firstFrameWait = { _ in await wait.wait() }
        try source.start(audio: chunks.add, interrupted: {}, device: { _ in })
        let first = hardware.succeed(0)
        await until { wait.count == 1 }
        wait.advance()
        await until { first.completions.count == 1 }
        var stopped: [Bool] = []
        source.stop { stopped.append($0) }
        #expect(stopped.isEmpty)
        first.finishClose(withFrame: true)
        #expect(stopped == [false])
        #expect(chunks.chunks.count == 1)
        #expect(hardware.requests.count == 1)
    }

    @Test func blockedNativeOpenRetiresBeforeReplacementEvenWithDelayedMainDelivery() async throws {
        let state = StartupNativeState(), main = StartupMainDelivery()
        let queue = DispatchQueue(label: "intention.tests.microphone.startup")
        var core = CoreAudioMicrophones()
        core.execute = { @Sendable job in queue.async(execute: job) }
        core.deliver = main.enqueue
        core.makeInput = { @Sendable id, audio, _, _ in try state.open(id, audio: audio) }
        let hardware = StartupNativeHardware(core: core), source = Microphone(hardware: hardware)
        let old = Collected(), current = Collected()
        var names = 0, waits = 0
        let wait = FrameWait()
        source.firstFrameWait = { _ in waits += 1; await wait.wait() }
        try source.start(audio: old.add, interrupted: {}, device: { _ in names += 1 })
        await until { state.firstEntered }
        #expect(waits == 0)
        var stopped: [Bool] = []
        source.stop { stopped.append($0) }
        try source.start(audio: current.add, interrupted: {}, device: { _ in names += 1 })
        #expect(stopped.isEmpty)
        state.gate.signal()
        await until { main.count == 2 }
        #expect(state.events == ["open.1", "close.1", "drain.1", "open.2"])
        #expect(names == 0 && waits == 0)
        main.next() // Retired result cannot publish anything.
        main.next() // The second recording alone becomes live.
        await until { main.count == 1 }
        main.next() // The retired open has acknowledged its close.
        #expect(stopped == [true])
        await until { waits == 1 }
        #expect(names == 1)
        #expect(old.chunks.isEmpty && current.chunks.isEmpty)
        state.record(2, Data(repeating: 0, count: 320))
        source.stop { stopped.append($0) }
        await until { main.count == 1 }
        #expect(stopped == [true])
        main.next()
        #expect(stopped == [true, false])
        #expect(current.chunks.count == 1)
        #expect(state.events.filter { $0 == "close.1" }.count == 1)
        wait.advance()
    }

    @Test(arguments: [false, true])
    func capturedBufferSurvivesReleaseBeforeNativeSuccessDelivery(silent: Bool) async throws {
        let state = StartupNativeState(), main = StartupMainDelivery()
        let queue = DispatchQueue(label: "intention.tests.microphone.captured-start")
        var core = CoreAudioMicrophones()
        core.execute = { @Sendable job in queue.async(execute: job) }
        core.deliver = main.enqueue
        core.makeInput = { @Sendable id, audio, _, _ in try state.open(id, audio: audio) }
        let hardware = StartupNativeHardware(core: core), source = Microphone(hardware: hardware)
        let old = DictationTape(), current = DictationTape(), wait = FrameWait()
        source.firstFrameWait = { _ in await wait.wait() }
        var names = 0, failures = 0, stopped: [Bool] = []
        // Start is complete on the worker, with a short captured buffer still
        // waiting for close to emit PCM. Its main-actor result is held back.
        state.gate.signal()
        try source.start(audio: old.append, interrupted: {}, device: { _ in names += 1 })
        await until { main.count == 1 }
        try #require(main.count == 1)
        let partial = Data(repeating: silent ? 0 : 32, count: 320)
        state.record(1, partial)
        #expect(old.recorded.isEmpty)
        source.stop { stopped.append($0) }
        #expect(stopped.isEmpty)
        let levels = RecordingLevels { _ in }
        try source.start(audio: current.append, levels: levels, interrupted: {}, device: { _ in names += 1 },
                         issue: { _ in failures += 1 }, failed: { _ in failures += 1 })
        await until { main.count == 2 }
        try #require(main.count == 2)
        #expect(state.events == ["open.1", "close.1", "drain.1", "open.2"])
        #expect(old.recorded == [partial])
        #expect(current.recorded.isEmpty)
        #expect(names == 0 && failures == 0 && stopped.isEmpty)
        main.next()
        main.next()
        await until { main.count == 1 }
        main.next()
        #expect(stopped == [false])
        #expect(names == 1 && failures == 0)
        #expect(old.recorded == [partial] && current.recorded.isEmpty)
        source.stop { stopped.append($0) }
        await until { main.count == 1 }
        main.next()
        #expect(stopped == [false, true])
        #expect(state.events.filter { $0 == "close.1" }.count == 1)
        wait.advance()
    }
}

}

@MainActor
private final class DrainingSpeechSource: SpeechAudioSource {
    struct Run {
        let audio: @Sendable (Data) -> Void
        let named: @MainActor (String) -> Void
        let failed: @MainActor (Error) -> Void
    }
    var runs: [Run] = []
    var stops: [@MainActor (Bool) -> Void] = []
    var running = false
    func start(audio: @escaping @Sendable (Data) -> Void, interrupted: @escaping @MainActor () -> Void,
               device: @escaping @MainActor (String) -> Void) throws {
        running = true
        runs.append(Run(audio: audio, named: device, failed: { _ in }))
    }
    func start(audio: @escaping @Sendable (Data) -> Void, levels: RecordingLevels,
               interrupted: @escaping @MainActor () -> Void, device: @escaping @MainActor (String) -> Void,
               issue: @escaping @MainActor (CaptureIssue) -> Void, failed: @escaping @MainActor (Error) -> Void) throws {
        running = true
        runs.append(Run(audio: audio, named: device, failed: failed))
    }
    func stop() { running = false }
    func stop(completion: @escaping @MainActor (Bool) -> Void) {
        running = false
        stops.append(completion)
    }
}

/// Deliberately returns even after task cancellation, like an already-completing
/// provider. The controller must recheck session ownership after the await.
@MainActor
private final class StartupPreparationGate: SpeechCredentials, DictationVocabulary {
    let stage: String
    var waiting = false
    var returnedWhileCancelled = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(stage: String) { self.stage = stage }
    private func wait(at stage: String) async {
        guard self.stage == stage else { return }
        waiting = true
        await withCheckedContinuation { continuation = $0 }
        returnedWhileCancelled = Task.isCancelled
    }
    func release() { continuation?.resume(); continuation = nil }
    func grant() async throws -> String {
        await wait(at: "grant")
        return ScriptedEndpoint.grant
    }
    func words(register: String, before: String?) async -> PersonalWords {
        await wait(at: "vocabulary")
        return .empty
    }
    func refused(_ grant: String) async {}
    func reset() async {}
}

@MainActor
private final class StartupPhases {
    struct Notification: Equatable {
        let phase: DictationController.Phase
        let busy: Bool
    }
    var displayed: [DictationController.Phase] = []
    var notifications: [Notification] = []
    var idleBusy: [Bool] { notifications.filter { $0.phase == .idle }.map(\.busy) }

    init(_ dictation: DictationController) {
        dictation.phaseChanged = { [weak self, weak dictation] phase in
            guard let self, let dictation else { return }
            notifications.append(Notification(phase: phase, busy: dictation.isBusy))
            if displayed.last != phase { displayed.append(phase) }
        }
    }
}

extension DictationScenarioTests.MicrophoneStartupTests {
    private func controller(_ source: any SpeechAudioSource, endpoint: DictationEndpoint? = nil,
                            vocabulary: any DictationVocabulary = EmptyVocabulary()) -> DictationController {
        MockField.reset()
        let pasteboard = NSPasteboard(name: .init("co.intention.startup-tests.\(UUID().uuidString)"))
        MockField.shared.pasteboard = pasteboard
        let endpoint = endpoint ?? DictationEndpoint(url: URL(string: "ws://127.0.0.1:1/unused")!, credentials: FeedbackNoCredentials())
        let controller = DictationController(inserter: TextInserter(pasteboard: PasteboardOwner(pasteboard: pasteboard, mayRead: { true })),
                                            history: DictationHistory(file: nil), endpoint: endpoint, source: source, vocabulary: vocabulary)
        controller.frontmostBundle = { nil }
        return controller
    }

    @Test func processingUsesTheFinalDrainBeforeDecidingSilence() async {
        let source = DrainingSpeechSource()
        let dictation = self.controller(source)
        let phases = StartupPhases(dictation)
        dictation.toggle()
        dictation.toggle()
        await Task.yield()
        #expect(dictation.phase == .processing)
        #expect(dictation.isBusy)
        #expect(phases.displayed == [.recording, .processing])
        #expect(dictation.history.entries.isEmpty)
        // This speech exists only in close's final drain. Deciding silence
        // before completion would discard it and omit the failed retry.
        source.runs[0].audio(Data(repeating: 32, count: 3_200))
        source.stops[0](false)
        await until { dictation.phase == .idle }
        #expect(phases.displayed == [.recording, .processing, .idle])
        #expect(phases.notifications.map(\.phase) == phases.displayed)
        #expect(phases.idleBusy == [false])
        #expect(!dictation.isBusy)
        #expect(dictation.history.entries.count == 1)
        #expect(dictation.history.entries.first?.outcome == .failed)
    }

    @Test func cancellingInlineAudioDrainNeverShowsProcessing() async {
        let source = ScriptedSource(chunks: 0)
        let dictation = controller(source)
        let phases = StartupPhases(dictation)
        dictation.toggle()
        let preparation = dictation.preparationForTesting().task
        dictation.cancel()
        #expect(phases.displayed == [.recording, .idle])
        #expect(phases.notifications.map(\.phase) == phases.displayed)
        #expect(phases.idleBusy == [false])
        #expect(!dictation.isBusy)
        #expect(!source.running)
        #expect(dictation.history.entries.isEmpty)
        await preparation?.value
    }

    @Test func cancellingDelayedAudioDrainHidesOnlyItsPresentation() async throws {
        let source = DrainingSpeechSource()
        let dictation = controller(source)
        let phases = StartupPhases(dictation)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let written = Collected()
        let archive = InteractionArchive(directory: folder, write: { @Sendable data, url in
            if url.pathExtension == "body" { written.add(data) }
            try InteractionArchive.writePrivately(data, url)
        }) { @Sendable _, _, _ in 204 }
        archive.bind(key: "synthetic-startup-key")
        dictation.archive = archive
        dictation.toggle()
        let preparation = dictation.preparationForTesting().task
        let initialAudio = Data(repeating: 32, count: 320)
        let finalAudio = Data(repeating: 48, count: 640)
        source.runs[0].audio(initialAudio)
        dictation.cancel()
        #expect(phases.displayed == [.recording, .idle])
        #expect(phases.idleBusy == [true])
        #expect(dictation.isBusy)
        #expect(!source.running)
        #expect(source.stops.count == 1)
        // The cancelled session still owns its final drain despite being hidden.
        #expect(dictation.preparationForTesting().task != nil)
        #expect(await archive.flush())
        #expect(written.chunks.isEmpty)
        source.runs[0].audio(finalAudio)
        source.stops[0](false)
        #expect(dictation.preparationForTesting().task == nil)
        #expect(phases.displayed == [.recording, .idle])
        #expect(phases.notifications.map(\.phase) == [.recording, .idle, .idle])
        #expect(phases.idleBusy == [true, false])
        #expect(!dictation.isBusy)
        #expect(dictation.history.entries.isEmpty)
        // The quiet notification follows retention enqueue. Its disk barrier
        // proves that enqueue contains the final drain as well as earlier PCM.
        #expect(await archive.flush())
        await preparation?.value
        #expect(written.chunks.count == 1)
        let bytes = try #require(written.chunks.first)
        try #require(bytes.count >= 4)
        let metadataLength = bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        try #require(4 + metadataLength <= bytes.count)
        #expect(Data(bytes.dropFirst(4 + metadataLength)) == initialAudio + finalAudio)
    }

    @Test func cancellingAnAlreadyStoppedDrainEndsItsProcessingPresentation() async {
        let source = DrainingSpeechSource()
        let dictation = controller(source)
        let phases = StartupPhases(dictation)
        dictation.toggle()
        let preparation = dictation.preparationForTesting().task
        dictation.toggle()
        #expect(phases.displayed == [.recording, .processing])
        dictation.cancel()
        #expect(phases.displayed == [.recording, .processing, .idle])
        #expect(phases.idleBusy == [true])
        #expect(dictation.isBusy)
        #expect(source.stops.count == 1)
        source.stops[0](true)
        #expect(phases.displayed == [.recording, .processing, .idle])
        #expect(phases.notifications.map(\.phase) == [.recording, .processing, .idle, .idle])
        #expect(phases.idleBusy == [true, false])
        #expect(!dictation.isBusy)
        #expect(dictation.history.entries.isEmpty)
        await preparation?.value
    }

    @Test func cancelledDrainKeepsEarlierProcessingVisible() async {
        let source = DrainingSpeechSource()
        let dictation = controller(source)
        let phases = StartupPhases(dictation)
        dictation.toggle()
        dictation.toggle()
        dictation.toggle()
        let replacementPreparation = dictation.preparationForTesting().task
        dictation.cancel()
        #expect(phases.displayed == [.recording, .processing, .recording, .processing])
        #expect(dictation.isBusy)
        #expect(source.stops.count == 2)
        source.stops[1](true)
        #expect(dictation.phase == .processing)
        #expect(dictation.isBusy)
        #expect(phases.idleBusy.isEmpty)
        source.runs[0].audio(Data(repeating: 32, count: 3_200))
        source.stops[0](false)
        await until { dictation.phase == .idle }
        #expect(phases.displayed == [.recording, .processing, .recording, .processing, .idle])
        #expect(phases.notifications.map(\.phase) == phases.displayed)
        #expect(phases.idleBusy == [false])
        #expect(!dictation.isBusy)
        #expect(dictation.history.entries.count == 1)
        await replacementPreparation?.value
    }

    @Test(arguments: [false, true])
    func cancellationDuringDrainDoesNotStopOrFailTheNewRecording(oldDrainsFirst: Bool) async {
        let source = DrainingSpeechSource()
        let current = controller(source)
        let phases = StartupPhases(current)
        current.toggle()
        let oldPreparation = current.preparationForTesting().task
        current.toggle()
        current.cancel()
        current.toggle()
        let newPreparation = current.preparationForTesting().task
        #expect(phases.displayed == [.recording, .processing, .idle, .recording])
        #expect(source.running)
        #expect(source.stops.count == 1)
        // Retired source callbacks arrive after the next recording starts.
        source.runs[0].named("Synthetic old input")
        source.runs[0].failed(Microphone.Failure.unavailable)
        source.runs[0].audio(Data(repeating: 0, count: 320))
        if oldDrainsFirst {
            source.stops[0](false)
            source.stops[0](false) // Duplicate completion cannot finalize twice.
        }
        #expect(current.phase == .recording)
        #expect(current.problem == nil)
        #expect(source.running)
        #expect(source.stops.count == 1)
        #expect(current.history.entries.isEmpty)
        #expect(phases.notifications.map(\.phase) == [.recording, .processing, .idle, .recording])
        #expect(current.isBusy)
        current.cancel()
        #expect(phases.displayed == [.recording, .processing, .idle, .recording, .idle])
        #expect(phases.idleBusy == [true, true])
        #expect(current.isBusy)
        #expect(source.stops.count == 2)
        source.stops[1](true)
        if !oldDrainsFirst {
            #expect(current.isBusy)
            #expect(phases.idleBusy == [true, true])
            source.stops[0](false)
            source.stops[0](false)
        }
        #expect(!current.isBusy)
        #expect(phases.displayed == [.recording, .processing, .idle, .recording, .idle])
        #expect(phases.notifications.map(\.phase) == [.recording, .processing, .idle, .recording, .idle, .idle])
        #expect(phases.idleBusy == [true, true, false])
        #expect(current.history.entries.isEmpty)
        await oldPreparation?.value
        await newPreparation?.value
    }

    @Test(arguments: ["grant", "vocabulary"])
    func cancelledPreparationCannotConnectWhileFinalAudioDrains(stage: String) async throws {
        let server = try await ScriptedEndpoint([.silent])
        defer { server.stop() }
        let source = DrainingSpeechSource(), gate = StartupPreparationGate(stage: stage)
        let endpoint = DictationEndpoint(url: server.endpoint.url, credentials: gate)
        let dictation = controller(source, endpoint: endpoint, vocabulary: gate)
        dictation.toggle()
        await until { gate.waiting }
        try #require(gate.waiting)
        let preparation = try #require(dictation.preparationForTesting().task)
        source.runs[0].audio(Data(repeating: 32, count: 320))
        dictation.cancel()
        #expect(source.stops.count == 1)
        #expect(dictation.preparationForTesting().task != nil)
        gate.release()
        await preparation.value
        #expect(gate.returnedWhileCancelled)
        // The cancelled session still owns its final audio. Inspect actual
        // attachment after preparation, before allowing close to finish.
        #expect(dictation.preparationForTesting().stream == nil)
        #expect(server.connections.isEmpty)
        #expect(server.presented.isEmpty)
        source.runs[0].audio(Data(repeating: 32, count: 320))
        source.stops[0](false)
        await until { dictation.phase == .idle }
        #expect(server.connections.isEmpty)
    }

    @Test func asynchronousStartupFailureCancelsItsConnectedStreamOnly() async throws {
        let server = try await ScriptedEndpoint([.silent])
        defer { server.stop() }
        let source = DrainingSpeechSource()
        let dictation = controller(source, endpoint: server.endpoint)
        dictation.toggle()
        source.runs[0].audio(Data(repeating: 32, count: 320))
        let preparation = try #require(dictation.preparationForTesting().task)
        await preparation.value
        await until { server.connections.count == 1 && !server.connections[0].start.isEmpty }
        try #require(server.connections.count == 1)
        #expect(dictation.preparationForTesting().stream != nil)
        source.running = false
        source.runs[0].failed(Microphone.Failure.unavailable)
        #expect(dictation.phase == .idle)
        #expect(dictation.problem == .microphoneUnavailable)
        dictation.toggle()
        let replacementPreparation = dictation.preparationForTesting().task
        source.runs[1].audio(Data(repeating: 48, count: 320))
        await until { server.connections.count == 2 && !server.connections[1].start.isEmpty && server.connections[0].cancelled }
        try #require(server.connections.count == 2)
        source.runs[0].failed(Microphone.Failure.unavailable)
        #expect(dictation.phase == .recording)
        #expect(dictation.problem == nil)
        #expect(source.running)
        #expect(!server.connections[1].cancelled)
        #expect(source.stops.isEmpty)
        dictation.cancel()
        #expect(source.stops.count == 1)
        source.stops[0](false)
        await until { dictation.phase == .idle }
        await replacementPreparation?.value
    }
}
