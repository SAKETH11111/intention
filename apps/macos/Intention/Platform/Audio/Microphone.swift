import AVFoundation
import AudioToolbox
import CoreAudio
import os

/// Records one dictation at a time from the input `MicrophoneChoice` picks
/// for the person's setting, the built-in microphone unless they chose
/// otherwise. A recording keeps its device while that device can record,
/// and moves, onto the same dictation, only when it cannot. With inputs
/// listed but none that can hear, as a MacBook's own microphone alone
/// behind a closed lid, it opens nothing and records nothing.
/// The device is open only between `start` and `stop`, so macOS shows its
/// microphone indicator only while the person is dictating. Audio is never
/// written to disk here.
///
/// The input device is opened on its own, through an input-only HAL unit.
/// AVAudioEngine's input node instead records through a private aggregate of
/// the default input and the default output, clocked by the output and run
/// at one sample rate for both. With a Bluetooth headset as both, the first
/// alpha recorded next to nothing but digital silence (October 6, 2026; see
/// the recording contract).
@MainActor
final class Microphone: SpeechAudioSource {
    enum Failure: Error {
        case permissionDenied
        /// No input device, or it would not start.
        case unavailable
        /// Inputs are listed but none can hear. `start` records nothing
        /// then, rather than throwing it.
        case nothingHears
    }

    static var permission: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    /// Asks macOS for the microphone the first time; afterwards it answers
    /// at once with the person's earlier choice.
    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Immediate reopens before recovery waits, so a flapping route cannot
    /// spin the main actor. Recovery continues until the person stops.
    static let reopens = 3

    /// The person's choice, read each time a device is opened.
    private let preference: @MainActor () -> MicrophonePreference
    private let hardware: any MicrophoneHardware
    private var input: (any OpenMicrophone)?
    private var opening: MicrophoneOpening?
    /// The device `input` records from.
    private var device: AudioInput?
    /// Each open attempt owns its callbacks, including a pending native open.
    private var opened = 0
    private var delivery: MicrophoneDelivery?
    private var recording: Recording?
    private var recovery: Task<Void, Never>?
    private var firstFrameTask: Task<Void, Never>?
    private(set) var neverStarted = false
    static let firstFrameDeadline: Duration = .seconds(1)
    var firstFrameWait: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    /// How recovery waits between tries, a second each; the checks drive it
    /// themselves rather than race the clock.
    var recoveryWait: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    init(preference: @escaping @MainActor () -> MicrophonePreference = { .builtIn },
         hardware: any MicrophoneHardware = CoreAudioMicrophones()) {
        self.preference = preference
        self.hardware = hardware
    }

    func start(audio: @escaping @Sendable (Data) -> Void, interrupted: @escaping @MainActor () -> Void,
               device named: @escaping @MainActor (String) -> Void) throws {
        try start(audio: audio, levels: nil, interrupted: interrupted, named: named)
    }

    func start(audio: @escaping @Sendable (Data) -> Void, levels: RecordingLevels,
               interrupted: @escaping @MainActor () -> Void, device named: @escaping @MainActor (String) -> Void) throws {
        try start(audio: audio, levels: levels, interrupted: interrupted, named: named)
    }

    func start(audio: @escaping @Sendable (Data) -> Void, levels: RecordingLevels,
               interrupted: @escaping @MainActor () -> Void, device: @escaping @MainActor (String) -> Void,
               issue: @escaping @MainActor (CaptureIssue) -> Void) throws {
        try start(audio: audio, levels: levels, interrupted: interrupted, named: device, issue: issue)
    }

    func start(audio: @escaping @Sendable (Data) -> Void, levels: RecordingLevels,
               interrupted: @escaping @MainActor () -> Void, device: @escaping @MainActor (String) -> Void,
               issue: @escaping @MainActor (CaptureIssue) -> Void,
               failed: @escaping @MainActor (Error) -> Void) throws {
        try start(audio: audio, levels: levels, interrupted: interrupted, named: device, issue: issue, failed: failed)
    }

    private func start(audio: @escaping @Sendable (Data) -> Void, levels: RecordingLevels?,
                       interrupted: @escaping @MainActor () -> Void, named: @escaping @MainActor (String) -> Void,
                       issue: @escaping @MainActor (CaptureIssue) -> Void = { _ in },
                       failed: @escaping @MainActor (Error) -> Void = { _ in }) throws {
        stop()
        guard hardware.permitted else { throw Failure.permissionDenied }
        neverStarted = false
        let recording = Recording(audio: audio, levels: levels, interrupted: interrupted, named: named, issue: issue)
        self.recording = recording
        // Existing fake sources still fail inline. Native failures arrive later,
        // through the same recording's callback, after returning the main actor.
        var starting = true
        var immediateError: Error?
        open(recording) { [weak self] result in
            guard let self, self.recording === recording else { return }
            guard case let .failure(error) = result else { return }
            if error as? Failure == .nothingHears {
                AppLog.dictation("microphone.nothingHears")
                self.recover(recording)
            } else {
                self.stop()
                if starting { immediateError = error } else { failed(error) }
            }
        }
        starting = false
        if let immediateError { throw immediateError }
    }

    /// Retry a refused device once using the same selection rule as before.
    private func open(_ recording: Recording, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        guard self.recording === recording else { return completion(.failure(CancellationError())) }
        let preference = preference()
        do {
            let device = try choose(preference, from: hardware.inputs())
            open(device, recording) { [weak self] result in
                guard let self, self.recording === recording else { return completion(.failure(CancellationError())) }
                guard case let .failure(error) = result else { return completion(result) }
                guard recording.reopened < Self.reopens else { return completion(.failure(error)) }
                AppLog.dictation("microphone.notOpened")
                do {
                    var inputs = self.hardware.inputs()
                    inputs.devices.removeAll { $0.id == device.id }
                    let next = try self.choose(preference, from: inputs)
                    recording.reopened += 1
                    self.open(next, recording, completion: completion)
                } catch { completion(.failure(error)) }
            }
        } catch { completion(.failure(error)) }
    }

    private func choose(_ preference: MicrophonePreference, from inputs: AudioInputs) throws -> AudioInput {
        let pick = MicrophoneChoice.pick(preference, from: inputs)
        guard let device = pick.device else { throw inputs.devices.isEmpty ? Failure.unavailable : Failure.nothingHears }
        if let fallback = pick.fallback { AppLog.dictation("microphone.fallback.\(fallback.name)") }
        return device
    }

    private func open(_ device: AudioInput, _ recording: Recording,
                      completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        opened += 1
        let number = opened
        recording.attemptedInput = true
        let delivery = MicrophoneDelivery(audio: recording.audio) { [weak self, weak recording] time in
            guard let self, let recording, self.recording === recording, self.opened == number else { return }
            guard !recording.reportedFirstFrame else { return }
            recording.reportedFirstFrame = true
            AppLog.pressStage("firstDeliveredPCM", at: time, since: recording.startedAt)
        }
        self.delivery = delivery
        let opening = MicrophoneOpening(delivery: delivery)
        self.opening = opening
        do {
            try hardware.open(device, audio: delivery.receive, levels: recording.levels, cancellation: delivery.cancellation, check: { [weak self] in
                guard let self, self.recording === recording, self.opened == number else { return }
                self.check(recording)
            }, completion: { [weak self] result in
                if opening.finishIfCancelled(result) {
                    completion(.failure(CancellationError()))
                    return
                }
                guard let self, self.recording === recording, self.opened == number else {
                    if case let .success(input) = result { input.close { delivery.retire() } }
                    else { delivery.retire() }
                    completion(.failure(CancellationError()))
                    return
                }
                self.opening = nil
                switch result {
                case let .success(input):
                    self.input = input
                    self.device = device
                    AppLog.pressStage("microphoneStarted", at: input.startedAt ?? ProcessInfo.processInfo.systemUptime, since: recording.startedAt)
                    recording.named(device.name)
                    guard self.recording === recording, self.opened == number else {
                        return completion(.failure(CancellationError()))
                    }
                    // The native open is complete. Time spent waiting in the
                    // executor is never counted as a missing first frame.
                    self.watchFirstFrame(recording, opened: number)
                    completion(.success(()))
                case let .failure(error):
                    delivery.retire()
                    self.delivery = nil
                    completion(.failure(error))
                }
            })
        } catch {
            self.opening = nil
            delivery.retire()
            self.delivery = nil
            completion(.failure(error))
        }
    }

    /// HAL start success says nothing about whether buffers arrive. Watch
    /// each input, including all-zero buffers, with one immediate no-frame
    /// retry per recording. Earlier inputs cannot satisfy its deadline.
    private func watchFirstFrame(_ recording: Recording, opened number: Int) {
        firstFrameTask?.cancel()
        let wait = firstFrameWait
        firstFrameTask = Task { [weak self] in
            await wait(Self.firstFrameDeadline)
            guard !Task.isCancelled, let self, self.recording === recording,
                  self.opened == number, let input = self.input else { return }
            if input.receivedFrames {
                recording.receivedFrames = true
                self.firstFrameTask = nil
                if let device = self.device { recording.named(device.name) }
                return
            }
            self.closeInput(recording) { [weak self] in
                guard let self, self.recording === recording else { return }
                // The final drain may deliver this input's first frame.
                if input.receivedFrames {
                    // A unit that only delivers on close still needs a bound on
                    // immediate reopens, just like a changing input route.
                    recording.reopened += 1
                    guard recording.reopened <= Self.reopens else {
                        self.recover(recording)
                        return
                    }
                    self.open(recording) { [weak self] result in
                        if case .failure = result { self?.recover(recording) }
                    }
                    return
                }
                guard !recording.retriedFirstFrame else { return self.firstFrameFailed(recording) }
                recording.retriedFirstFrame = true
                AppLog.dictation("microphone.firstFrame.retry")
                self.open(recording) { [weak self] result in
                    guard let self, self.recording === recording else { return }
                    switch result {
                    case .success: recording.issue(.restarting)
                    case .failure: self.firstFrameFailed(recording)
                    }
                }
            }
        }
    }

    private func firstFrameFailed(_ recording: Recording) {
        guard self.recording === recording else { return }
        // Earlier audio remains usable when a replacement fails to start.
        guard !recording.receivedFrames else {
            recover(recording)
            return
        }
        neverStarted = true
        recording.issue(.neverStarted)
        AppLog.dictation("microphone.firstFrame.failed")
    }

    private func check(_ recording: Recording) {
        guard self.recording === recording, let input, let device,
              MicrophoneChoice.mustMove(recording: device, formatChanged: input.formatChanged, in: hardware.inputs()) else { return }
        closeInput(recording) { [weak self] in
            guard let self, self.recording === recording else { return }
            recording.reopened += 1
            guard recording.reopened <= Self.reopens else { return self.recover(recording) }
            self.open(recording) { [weak self] result in
                guard let self, self.recording === recording else { return }
                switch result {
                case .success: AppLog.dictation("microphone.reopened")
                case .failure: self.recover(recording)
                }
            }
        }
    }

    private func recover(_ recording: Recording) {
        guard self.recording === recording, recovery == nil else { return }
        AppLog.dictation("microphone.recovering")
        recording.interrupted()
        guard self.recording === recording else { return }
        let wait = recoveryWait
        recovery = Task { [weak self] in
            while !Task.isCancelled {
                await wait(.seconds(1))
                guard !Task.isCancelled, let self, self.recording === recording else { return }
                recording.reopened = 0
                let recovered = await withCheckedContinuation { continuation in
                    self.open(recording) { result in continuation.resume(returning: (try? result.get()) != nil) }
                }
                guard !Task.isCancelled, self.recording === recording else { return }
                if recovered {
                    self.recovery = nil
                    AppLog.dictation("microphone.recovered")
                    return
                }
            }
        }
    }

    func stop() { stop { _ in } }

    func stop(completion: @escaping @MainActor (Bool) -> Void) {
        guard let recording else { return completion(neverStarted) }
        self.recording = nil
        recording.levels?.close()
        recovery?.cancel()
        recovery = nil
        let stopNumber = opened + 1
        closeInput(recording) { [weak self] in
            let neverStarted = recording.attemptedInput && !recording.receivedFrames
            // A later recording or stop owns the compatibility property.
            if self?.opened == stopNumber, self?.recording == nil { self?.neverStarted = neverStarted }
            completion(neverStarted)
        }
    }

    private func closeInput(_ recording: Recording, completion: @escaping @MainActor () -> Void) {
        opened += 1
        firstFrameTask?.cancel()
        firstFrameTask = nil
        let input = input
        let opening = opening
        let delivery = delivery
        self.input = nil
        self.opening = nil
        self.delivery = nil
        device = nil
        guard input != nil || opening != nil else {
            if recording.closing > 0 { recording.afterClose.append(completion) }
            else { completion() }
            return
        }
        recording.closing += 1
        var completed = false
        let closed: @MainActor (Bool) -> Void = { receivedFrames in
            guard !completed else { return }
            completed = true
            recording.receivedFrames = recording.receivedFrames || receivedFrames
            delivery?.retire()
            recording.closing -= 1
            completion()
            if recording.closing == 0 {
                let waiting = recording.afterClose
                recording.afterClose = []
                waiting.forEach { $0() }
            }
        }
        if let input { input.close { closed(input.receivedFrames) } }
        else { opening?.cancel(completion: closed) }
    }
}

/// A successful native start may still be waiting for main-actor delivery.
/// Keep its recording's audio gate until close acknowledges the final drain.
@MainActor
private final class MicrophoneOpening {
    private let delivery: MicrophoneDelivery
    private var onClose: (@MainActor (Bool) -> Void)?

    init(delivery: MicrophoneDelivery) { self.delivery = delivery }

    func cancel(completion: @escaping @MainActor (Bool) -> Void) {
        onClose = completion
        delivery.cancellation.cancel()
    }

    func finishIfCancelled(_ result: Result<any OpenMicrophone, Error>) -> Bool {
        guard let onClose else { return false }
        self.onClose = nil
        switch result {
        case let .success(input): input.close { onClose(input.receivedFrames) }
        case .failure: onClose(false)
        }
        return true
    }
}

@MainActor
private final class Recording {
    let audio: @Sendable (Data) -> Void
    let levels: RecordingLevels?
    let interrupted: @MainActor () -> Void
    let named: @MainActor (String) -> Void
    let issue: @MainActor (CaptureIssue) -> Void
    let startedAt = ProcessInfo.processInfo.systemUptime
    var attemptedInput = false
    var receivedFrames = false
    var reportedFirstFrame = false
    var retriedFirstFrame = false
    var reopened = 0
    var closing = 0
    var afterClose: [@MainActor () -> Void] = []

    init(audio: @escaping @Sendable (Data) -> Void, levels: RecordingLevels?,
         interrupted: @escaping @MainActor () -> Void, named: @escaping @MainActor (String) -> Void,
         issue: @escaping @MainActor (CaptureIssue) -> Void) {
        self.audio = audio
        self.levels = levels
        self.interrupted = interrupted
        self.named = named
        self.issue = issue
    }
}

/// An open attempt's off-actor delivery gate. Retirement and delivery are
/// ordered by this lock; no stale attempt can feed its replacement's tape.
private final class MicrophoneDelivery: @unchecked Sendable {
    let cancellation = MicrophoneOpenCancellation()
    private let lock = NSLock()
    private var active = true
    private var first = true
    private let audio: @Sendable (Data) -> Void
    private let firstFrame: @Sendable @MainActor (TimeInterval) -> Void

    init(audio: @escaping @Sendable (Data) -> Void, firstFrame: @escaping @Sendable @MainActor (TimeInterval) -> Void) {
        self.audio = audio
        self.firstFrame = firstFrame
    }

    func receive(_ data: Data) {
        let time: TimeInterval? = lock.withLock {
            guard active else { return nil }
            audio(data)
            guard first else { return nil }
            first = false
            return ProcessInfo.processInfo.systemUptime
        }
        if let time {
            let report = firstFrame
            DispatchQueue.main.async { @Sendable in report(time) }
        }
    }

    func retire() {
        lock.withLock { active = false }
        cancellation.cancel()
    }
}

/// Retirement can arrive while native open is blocked. Install its close job
/// before enqueueing open, so a newer recording cannot overtake that close.
final class MicrophoneOpenCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var action: (@Sendable () -> Void)?
    var isCancelled: Bool { lock.withLock { cancelled } }
    func whenCancelled(_ action: @escaping @Sendable () -> Void) {
        let run = lock.withLock {
            if cancelled { return true }
            self.action = action
            return false
        }
        if run { action() }
    }
    func cancel() {
        let action = lock.withLock {
            cancelled = true
            let action = self.action
            self.action = nil
            return action
        }
        action?()
    }
}

/// What `Microphone` needs from the Mac: Core Audio in the app, and in
/// the tests a stand-in that opens no device.
@MainActor
protocol MicrophoneHardware {
    /// Whether macOS lets Intention record.
    var permitted: Bool { get }
    /// The inputs as they are now, read without opening any.
    func inputs() -> AudioInputs
    /// Opens `device` and starts recording from it. `audio` receives 16 kHz
    /// mono chunks off the main actor, in order. `check` runs on the main
    /// actor when something changed that may move the recording: the
    /// device's state, format or input sources, the list of devices, the
    /// default input or the lid.
    func open(_ device: AudioInput, audio: @escaping @Sendable (Data) -> Void,
              check: @escaping @MainActor () -> Void) throws -> any OpenMicrophone
    func open(_ device: AudioInput, audio: @escaping @Sendable (Data) -> Void, levels: RecordingLevels?,
              check: @escaping @MainActor () -> Void) throws -> any OpenMicrophone
    func open(_ device: AudioInput, audio: @escaping @Sendable (Data) -> Void, levels: RecordingLevels?,
              cancellation: MicrophoneOpenCancellation, check: @escaping @MainActor () -> Void,
              completion: @escaping @MainActor (Result<any OpenMicrophone, Error>) -> Void) throws
}

extension MicrophoneHardware {
    func open(_ device: AudioInput, audio: @escaping @Sendable (Data) -> Void, levels: RecordingLevels?,
              cancellation: MicrophoneOpenCancellation, check: @escaping @MainActor () -> Void,
              completion: @escaping @MainActor (Result<any OpenMicrophone, Error>) -> Void) throws {
        completion(.success(try open(device, audio: audio, levels: levels, check: check)))
    }

    func open(_ device: AudioInput, audio: @escaping @Sendable (Data) -> Void, levels: RecordingLevels?,
              check: @escaping @MainActor () -> Void) throws -> any OpenMicrophone {
        try open(device, audio: { @Sendable chunk in
            audio(chunk)
            levels?.enqueue(chunk)
        }, check: check)
    }
}

/// One device open for recording.
@MainActor
protocol OpenMicrophone: AnyObject {
    /// Native open completion, captured on the worker before main delivery.
    var startedAt: TimeInterval? { get }
    /// At least one input buffer reached the conversion queue, even if silent.
    var receivedFrames: Bool { get }
    /// Its sample rate or input channels are no longer those it opened with.
    var formatChanged: Bool { get }
    /// Requests close. Native handles close asynchronously; completion
    /// follows every PCM chunk, including the last partial one.
    func close()
    func close(completion: @escaping @MainActor () -> Void)
}

extension OpenMicrophone {
    var startedAt: TimeInterval? { nil }
    func close(completion: @escaping @MainActor () -> Void) {
        close()
        completion()
    }
}

/// The Mac's inputs through Core Audio.
struct CoreAudioMicrophones: MicrophoneHardware {
    var execute: @Sendable (@escaping @Sendable () -> Void) -> Void = MicrophoneExecutor.run
    var deliver: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void = { @Sendable action in
        DispatchQueue.main.async(execute: action)
    }
    var makeInput: @Sendable (AudioDeviceID, @escaping @Sendable (Data) -> Void, RecordingLevels?, Int) throws -> any NativeMicrophoneInput = { @Sendable in
        try InputDevice($0, audio: $1, levels: $2, notice: $3)
    }
    var permitted: Bool { Microphone.permission == .authorized }

    func inputs() -> AudioInputs {
        AudioHardware.inputs()
    }

    // The native adapter requires completion-based startup. The old entry
    // point remains only for synchronous stand-ins that implement the protocol.
    func open(_ device: AudioInput, audio: @escaping @Sendable (Data) -> Void,
              check: @escaping @MainActor () -> Void) throws -> any OpenMicrophone {
        throw Microphone.Failure.unavailable
    }

    func open(_ device: AudioInput, audio: @escaping @Sendable (Data) -> Void, levels: RecordingLevels?,
              cancellation: MicrophoneOpenCancellation, check: @escaping @MainActor () -> Void,
              completion: @escaping @MainActor (Result<any OpenMicrophone, Error>) -> Void) throws {
        let number = DeviceNotices.add(check)
        let request = NativeMicrophoneRequest()
        let execute = execute, deliver = deliver, makeInput = makeInput
        cancellation.whenCancelled { @Sendable in
            execute { @Sendable in request.close() }
        }
        execute { @Sendable in
            let result = Result {
                guard !cancellation.isCancelled else { throw CancellationError() }
                let input = try makeInput(device.id, audio, levels, number)
                request.input = input
                // Even a cancelled start owns any frames captured before
                // close. Return its receipt after draining on this executor.
                if cancellation.isCancelled { request.close() }
                return input
            }
            let startedAt = ProcessInfo.processInfo.systemUptime
            deliver { @Sendable in
                switch result {
                case let .success(input):
                    completion(.success(NativeOpenMicrophone(input, request: request, startedAt: startedAt, notice: number, execute: execute, deliver: deliver)))
                    DeviceNotices.noticed(number)
                case let .failure(error):
                    DeviceNotices.remove(number)
                    completion(.failure(error))
                }
            }
        }
    }
}

/// Every native open, close and final drain uses this executor. Main-actor
/// callers enqueue work and never synchronously wait for the audio driver.
enum MicrophoneExecutor {
    private static let queue = DispatchQueue(label: "co.intention.microphone", qos: .userInitiated)
    static func run(_ work: @escaping @Sendable () -> Void) { queue.async(execute: work) }
}

/// The worker-only native handle. Tests replace HAL with a synthetic handle
/// while keeping the real executor and cancellation boundary.
protocol NativeMicrophoneInput: AnyObject, Sendable {
    var receivedFrames: Bool { get }
    var formatChanged: Bool { get }
    func close()
}

/// Accessed only on the owned serial executor, including cancellation during open.
private final class NativeMicrophoneRequest: @unchecked Sendable {
    var input: (any NativeMicrophoneInput)?
    func close() { input?.close(); input = nil }
}

@MainActor
private final class NativeOpenMicrophone: OpenMicrophone {
    private let input: any NativeMicrophoneInput
    private let request: NativeMicrophoneRequest
    private let execute: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let deliver: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    let startedAt: TimeInterval?
    private let notice: Int
    init(_ input: any NativeMicrophoneInput, request: NativeMicrophoneRequest, startedAt: TimeInterval, notice: Int,
         execute: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void,
         deliver: @escaping @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void) {
        self.input = input
        self.request = request
        self.startedAt = startedAt
        self.notice = notice
        self.execute = execute
        self.deliver = deliver
    }
    var receivedFrames: Bool { input.receivedFrames }
    var formatChanged: Bool { input.formatChanged }
    func close() { close {} }
    func close(completion: @escaping @MainActor () -> Void) {
        let request = request, notice = notice, deliver = deliver
        execute { @Sendable in
            request.close()
            deliver { @Sendable in
                DeviceNotices.remove(notice)
                completion()
            }
        }
    }
}

/// One open input device: an input-only HAL unit bound to it, the ring that
/// carries its audio off the device's I/O thread, the queue that converts
/// it, and the listeners that ask `Microphone` whether to move when
/// something about the inputs changes.
private final class InputDevice: NativeMicrophoneInput, @unchecked Sendable {
    /// The largest buffer the device may hand over at once; devices use a
    /// few hundred frames.
    private static let largestBuffer = 4_096

    private let device: AudioDeviceID
    /// Its listeners' number in `DeviceNotices`.
    private let number: Int
    /// The device's sample rate and input channels when it opened.
    private let opened: (rate: Double?, channels: UInt32)
    private let channels: Int
    private let unit: AudioUnit
    /// Where the unit renders each channel, and where they are mixed to
    /// one; both written on the device's I/O thread only.
    private let rendered: UnsafeMutableAudioBufferListPointer
    private let mixed: UnsafeMutablePointer<Float>
    private let drain: Drain
    private var ring: SampleRing { drain.ring }
    private var listeners: PropertyListeners
    private var lid: LidListener?
    private var closed = false
    var receivedFrames: Bool { drain.framesReceived }

    /// Opens and starts `device`. `check` runs on the main actor once it
    /// has started, and whenever the default input, the list of devices,
    /// this device's state, sample rate, channels or input sources, or the
    /// lid changes.
    init(_ device: AudioDeviceID, audio: @escaping @Sendable (Data) -> Void, levels: RecordingLevels? = nil,
         notice: Int) throws {
        guard let unit = AudioHardware.inputUnit(for: device) else { throw Microphone.Failure.unavailable }
        var deviceFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        // The unit hands over the device's own rate, since it does not
        // resample input; every channel is kept and mixed to one here.
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &deviceFormat, &size) == noErr,
              deviceFormat.mSampleRate > 0, deviceFormat.mChannelsPerFrame > 0,
              let drain = Drain(sampleRate: deviceFormat.mSampleRate, levels: levels, audio: audio) else {
            AudioComponentInstanceDispose(unit)
            throw Microphone.Failure.unavailable
        }
        self.device = device
        self.unit = unit
        opened = (AudioHardware.sampleRate(of: device), AudioHardware.inputChannels(of: device))
        channels = Int(deviceFormat.mChannelsPerFrame)
        rendered = AudioBufferList.allocate(maximumBuffers: channels)
        for index in 0..<channels {
            rendered[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0,
                                          mData: UnsafeMutableRawPointer.allocate(byteCount: Self.largestBuffer * 4, alignment: 16))
        }
        mixed = .allocate(capacity: Self.largestBuffer)
        self.drain = drain
        // The handler holds nothing of this device: `Microphone` tells a
        // check from a device it has closed or replaced by itself.
        number = notice
        listeners = PropertyListeners(number: number)

        var client = AudioStreamBasicDescription(
            mSampleRate: deviceFormat.mSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: deviceFormat.mChannelsPerFrame,
            mBitsPerChannel: 32, mReserved: 0)
        var largest = UInt32(Self.largestBuffer)
        var callback = AURenderCallbackStruct(inputProc: deviceInput, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        let configured = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client,
                                              UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr
            && AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &largest,
                                    UInt32(MemoryLayout<UInt32>.size)) == noErr
            && AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback,
                                    UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr
            && AudioUnitInitialize(unit) == noErr
        // Listening starts before the device does, so a change while it
        // starts is not missed; one check once it runs covers a change
        // that landed before the listeners.
        if configured {
            for (object, property) in AudioHardware.watchedWhileRecording(device) { listeners.listen(to: object, property) }
            lid = LidListener(number: number)
        }
        guard configured, AudioOutputUnitStart(unit) == noErr else {
            close()
            throw Microphone.Failure.unavailable
        }
        drain.start()
        AppLog.dictation("microphone.opened.\(AudioHardware.transport(of: device)).\(Int(deviceFormat.mSampleRate))")
    }

    deinit {
        if !closed { close() }
        for index in 0..<channels { rendered[index].mData?.deallocate() }
        free(rendered.unsafeMutablePointer)
        mixed.deallocate()
    }

    /// Whether the device's sample rate or channels changed since it
    /// opened. The listeners also fire for changes that leave both as they
    /// were, such as a headset's microphone starting.
    var formatChanged: Bool {
        AudioHardware.sampleRate(of: device) != opened.rate || AudioHardware.inputChannels(of: device) != opened.channels
    }

    /// Stops the device and hands every chunk, the last partial one
    /// included, to `audio` before it returns.
    func close() {
        guard !closed else { return }
        closed = true
        listeners.removeAll()
        lid?.remove()
        // Once the unit has stopped, nothing more is written to the ring;
        // what is in it is converted before the converter is drained.
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        drain.stop()
    }

    /// On the device's I/O thread: renders what the device recorded, mixes
    /// it to one channel and writes it to the ring. Nothing here allocates
    /// or waits.
    fileprivate func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ time: UnsafePointer<AudioTimeStamp>,
                            _ frames: UInt32) -> OSStatus {
        let count = Int(frames)
        guard count <= Self.largestBuffer else { return kAudioUnitErr_TooManyFramesToProcess }
        for index in 0..<channels { rendered[index].mDataByteSize = frames * 4 }
        let status = AudioUnitRender(unit, flags, time, 1, frames, rendered.unsafeMutablePointer)
        guard status == noErr else { return status }
        if channels == 1 {
            ring.write(rendered[0].mData!.assumingMemoryBound(to: Float.self), count)
        } else {
            ChannelMix.average(rendered, frames: count, into: mixed)
            ring.write(mixed, count)
        }
        return noErr
    }
}

/// The unit's input callback, which pulls the recorded frames.
private let deviceInput: AURenderCallback = { owner, flags, time, _, frames, _ in
    Unmanaged<InputDevice>.fromOpaque(owner).takeUnretainedValue().render(flags, time, frames)
}

/// Mono samples on their way from the device's I/O thread to the queue, in
/// memory allocated before the device starts. One thread writes and one
/// reads. The lock guards only where the samples start and how many there
/// are; samples are copied outside it, into space the reader does not read
/// or out of space the writer does not write. The writer only ever tries the
/// lock, once before copying and once after, so the I/O thread never waits:
/// a write that finds the ring full, because the queue fell two seconds
/// behind, or the lock taken, which the reader holds for a few integer
/// operations, is dropped and counted.
final class SampleRing: @unchecked Sendable {
    private let samples: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var start = 0
    private var count = 0
    /// Written by the writer alone, outside the lock.
    private var droppedFrames = 0

    init(capacity: Int) {
        self.capacity = capacity
        samples = .allocate(capacity: capacity)
        samples.initialize(repeating: 0, count: capacity)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        samples.deallocate()
        lock.deallocate()
    }

    /// On the I/O thread. The reader only ever frees space, so the space
    /// found free stays free while it is filled.
    func write(_ source: UnsafePointer<Float>, _ frames: Int) {
        guard os_unfair_lock_trylock(lock) else {
            droppedFrames += frames
            return
        }
        let end = (start + count) % capacity
        let free = capacity - count
        os_unfair_lock_unlock(lock)
        guard free >= frames else {
            droppedFrames += frames
            return
        }
        let first = min(frames, capacity - end)
        (samples + end).update(from: source, count: first)
        if frames > first { samples.update(from: source + first, count: frames - first) }
        guard os_unfair_lock_trylock(lock) else {
            droppedFrames += frames
            return
        }
        count += frames
        os_unfair_lock_unlock(lock)
    }

    /// Moves as many samples as fit into `buffer`; false when there were
    /// none. The writer only ever adds after them, so they stay as they are
    /// while they are copied.
    func read(into buffer: AVAudioPCMBuffer) -> Bool {
        os_unfair_lock_lock(lock)
        let (from, available) = (start, count)
        os_unfair_lock_unlock(lock)
        let frames = min(available, Int(buffer.frameCapacity))
        guard frames > 0, let destination = buffer.floatChannelData?[0] else { return false }
        let first = min(frames, capacity - from)
        destination.update(from: samples + from, count: first)
        if frames > first { (destination + first).update(from: samples, count: frames - first) }
        buffer.frameLength = AVAudioFrameCount(frames)
        os_unfair_lock_lock(lock)
        start = (start + frames) % capacity
        count -= frames
        os_unfair_lock_unlock(lock)
        return true
    }

    /// Frames dropped; read once the writer has stopped.
    var dropped: Int { droppedFrames }
}

/// Mixes a device's channels to one, on its I/O thread.
enum ChannelMix {
    /// Writes the mean of `channels`' first `frames` samples to `mixed`.
    static func average(_ channels: UnsafeMutableAudioBufferListPointer, frames: Int, into mixed: UnsafeMutablePointer<Float>) {
        mixed.update(from: channels[0].mData!.assumingMemoryBound(to: Float.self), count: frames)
        for index in 1..<channels.count {
            let channel = channels[index].mData!.assumingMemoryBound(to: Float.self)
            for frame in 0..<frames { mixed[frame] += channel[frame] }
        }
        let scale = 1 / Float(channels.count)
        for frame in 0..<frames { mixed[frame] *= scale }
    }
}

/// The queue's side of a recording: a ring of mono samples at `sampleRate`,
/// two seconds long, that its own queue empties through the converter every
/// 20 ms, and at the end drains the converter, after which anything left is
/// dropped rather than sent after the last chunk.
///
/// The timer's handler and the final drain run on that queue, never on an
/// actor, so they are formed here, outside any actor, and marked
/// `@Sendable`. Formed in the main-actor `InputDevice.init`, the handler
/// inherited the main actor's isolation, and Swift 6's check of it stopped
/// the app the first time it ran on this queue (October 6, 2026).
final class Drain: @unchecked Sendable {
    /// The largest run of samples converted at once.
    static let batch: AVAudioFrameCount = 4_096
    let ring: SampleRing
    private let buffer: AVAudioPCMBuffer
    private let tap: Tap
    private let levels: RecordingLevels?
    private let queue = DispatchQueue(label: "co.intention.mac.microphone")
    /// Set by `start` and cleared by `stop`, both on the caller's thread.
    private var timer: DispatchSourceTimer?
    private let receiptLock = NSLock()
    private var received = false
    var framesReceived: Bool { receiptLock.withLock { received } }

    init?(sampleRate: Double, levels: RecordingLevels? = nil, audio: @escaping @Sendable (Data) -> Void) {
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = SpeechAudioConverter(from: mono),
              let buffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: Self.batch) else { return nil }
        ring = SampleRing(capacity: max(Int(sampleRate) * 2, Int(Self.batch)))
        self.buffer = buffer
        self.levels = levels
        tap = Tap(converter: converter, audio: audio)
    }

    /// Starts emptying the ring every 20 ms on the drain's queue.
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(5))
        timer.setEventHandler { @Sendable [self] in run() }
        timer.resume()
        self.timer = timer
    }

    /// Stops the timer, converts what is left in the ring and drains the
    /// converter; every chunk has gone to `audio` when this returns. Call it
    /// once the ring's writer has stopped.
    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync { @Sendable [self] in
            run()
            tap.close()
            if ring.dropped > 0 { AppLog.dictation("microphone.overflow") }
        }
    }

    /// Empties the ring through the converter, on the drain's queue.
    func run() {
        var sum = 0.0
        var count = 0
        while ring.read(into: buffer) {
            receiptLock.withLock { received = true }
            if levels != nil, let samples = buffer.floatChannelData?[0] {
                for index in 0..<Int(buffer.frameLength) {
                    let sample = Double(samples[index])
                    sum += sample * sample
                }
                count += Int(buffer.frameLength)
            }
            tap.receive(buffer)
        }
        if let levels, count > 0 {
            // An empty drain tick says nothing about what the device heard.
            // Buffer duration keeps attack and release independent of its cadence.
            levels.receive(SpeechLevel.of(rms: (sum / Double(count)).squareRoot()),
                           seconds: Double(count) / buffer.format.sampleRate)
        }
    }
}


/// The conversion queue's end of `Microphone`. A buffer that arrives after
/// recording stops is dropped rather than sent after the last chunk.
private final class Tap: @unchecked Sendable {
    private let lock = NSLock()
    private let converter: SpeechAudioConverter
    private let audio: @Sendable (Data) -> Void
    private var closed = false

    init(converter: SpeechAudioConverter, audio: @escaping @Sendable (Data) -> Void) {
        self.converter = converter
        self.audio = audio
    }

    func receive(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        converter.convert(buffer).forEach(audio)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        converter.finish().map(audio)
    }
}
