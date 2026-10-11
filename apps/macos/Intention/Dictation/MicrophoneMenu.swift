import Foundation
import Observation

/// An open input exposes only its latest RMS, never samples or a recording.
@MainActor
protocol MicrophoneMeterInput: AnyObject {
    func rms() -> Double?
    func stop()
    /// False once the input has stopped by itself, as when it could not
    /// start again after its format changed.
    var isRunning: Bool { get }
}

extension MicrophoneMeterInput {
    var isRunning: Bool { true }
}

@MainActor
protocol MicrophoneMeterEngine {
    func isBluetooth(_ device: AudioInput) -> Bool
    func isMeterable(_ device: AudioInput) -> Bool
    func open(_ device: AudioInput) -> (any MicrophoneMeterInput)?
}

/// The picker and foot menu share choices and levels, with no view lifetime
/// implied. The caller follows inputs while visible and stops metering on close
/// or app deactivation. Starting never asks for microphone permission.
@MainActor
@Observable
final class MicrophoneMenu {
    struct Row: Identifiable, Equatable {
        enum ID: Hashable { case builtIn, systemDefault, device(String) }
        enum Quiet: Equatable { case bluetooth, notConnected, lidClosed, notAllowed, unavailable }
        let id: ID
        let preference: MicrophonePreference
        let title: String
        let detail: String?
        let quiet: Quiet?
        let isChosen: Bool
        let isRecommended: Bool
        let canHear: Bool
        let level: Double?
    }

    private(set) var inputs: AudioInputs
    private(set) var isMetering = false
    private(set) var isRecording = false
    private var levels: [String: Double] = [:]
    @ObservationIgnored private let preference: @MainActor () -> MicrophonePreference
    @ObservationIgnored private let save: @MainActor (MicrophonePreference) -> Void
    @ObservationIgnored private let authorized: @MainActor () -> Bool
    @ObservationIgnored private let engine: any MicrophoneMeterEngine
    @ObservationIgnored private var opened: [String: (AudioInput, any MicrophoneMeterInput)] = [:]
    private var failed: [String: AudioInput] = [:]
    @ObservationIgnored private var followers: [String: LevelFollower] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var scopes: Set<UUID> = []
    @ObservationIgnored private var explicitlyStarted = false
    @ObservationIgnored private var lastPoll = Date()

    init(inputs: AudioInputs, engine: any MicrophoneMeterEngine,
         authorized: @escaping @MainActor () -> Bool,
         preference: @escaping @MainActor () -> MicrophonePreference,
         choose: @escaping @MainActor (MicrophonePreference) -> Void) {
        self.inputs = inputs
        self.engine = engine
        self.authorized = authorized
        self.preference = preference
        self.save = choose
    }

    var rows: [Row] {
        let chosen = preference()
        return MicrophoneOptions.options(for: chosen, in: inputs).map { option in
            let device: AudioInput?
            let id: Row.ID
            let detail: String?
            switch option.preference {
            case .builtIn:
                id = .builtIn
                device = inputs.devices.first { $0.isBuiltIn && $0.id == inputs.systemDefault }
                    ?? inputs.devices.first { $0.isBuiltIn }
                detail = inputs.lidClosed && device != nil ? "Off while the lid is closed" : device?.name
            case .systemDefault:
                id = .systemDefault
                device = inputs.devices.first { $0.id == inputs.systemDefault }
                detail = device.map { "Follows macOS: \($0.name)" } ?? "Follows macOS"
            case let .device(uid, _):
                id = .device(uid)
                device = inputs.devices.first { $0.uid == uid }
                detail = device == nil ? "Not connected" : nil
            }
            let hears = device.map { !($0.isBuiltIn && inputs.lidClosed) } ?? false
            let quiet = quietReason(for: device)
            return Row(id: id, preference: option.preference, title: option.title, detail: detail, quiet: quiet,
                       isChosen: option.preference == chosen, isRecommended: option.preference == .builtIn,
                       canHear: hears, level: quiet == nil ? device.flatMap { levels[$0.uid] } : nil)
        }
    }

    /// Describe whether this device could show a level, even while the picker is folded.
    private func quietReason(for device: AudioInput?) -> Row.Quiet? {
        guard let device else { return .notConnected }
        if device.isBuiltIn && inputs.lidClosed { return .lidClosed }
        if engine.isBluetooth(device) { return .bluetooth }
        guard authorized() else { return .notAllowed }
        guard engine.isMeterable(device), failed[device.uid] != device else { return .unavailable }
        return nil
    }

    var label: String { MicrophoneOptions.label(for: preference(), in: inputs) }
    var note: String? { MicrophoneOptions.note(for: preference(), in: inputs) }

    func choose(_ preference: MicrophonePreference) { save(preference) }

    func updateInputs(_ inputs: AudioInputs) {
        if inputs != self.inputs { failed.removeAll() }
        self.inputs = inputs
        reconcile()
    }

    /// Called synchronously before dictation opens its source, and after it
    /// closes. Keeping the request active lets the visible picker resume.
    func setRecording(_ recording: Bool) {
        isRecording = recording
        reconcile()
    }

    func startMetering() {
        explicitlyStarted = true
        beginMetering()
    }

    private func beginMetering() {
        guard !isMetering else { return }
        failed.removeAll()
        isMetering = true
        generation += 1
        lastPoll = Date()
        reconcile()
        let callback = timerCallback()
        let timer = Timer(timeInterval: 1.0 / 15, repeats: true) { @Sendable _ in callback() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Use as a view task when cancellation should own the meter lifetime.
    func metering() async {
        guard !Task.isCancelled else { return }
        let scope = UUID()
        scopes.insert(scope)
        beginMetering()
        defer {
            if scopes.remove(scope) != nil && scopes.isEmpty && !explicitlyStarted { endMetering() }
        }
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(60)) }
    }

    isolated deinit {
        timer?.invalidate()
        for (_, input) in opened.values { input.stop() }
    }

    func stopMetering() {
        explicitlyStarted = false
        scopes.removeAll()
        endMetering()
    }

    private func endMetering() {
        isMetering = false
        generation += 1
        timer?.invalidate()
        timer = nil
        closeInputs()
    }

    /// Also used by callback tests: a stale queued tick cannot reopen inputs.
    func timerCallback() -> @Sendable () -> Void {
        let generation = generation
        return { @Sendable [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation, self.isMetering else { return }
                self.poll()
            }
        }
    }

    func poll() {
        reconcile()
        let now = Date()
        let elapsed = max(0, now.timeIntervalSince(lastPoll))
        lastPoll = now
        for (uid, (device, input)) in opened {
            guard input.isRunning else {
                // It stopped and could not start again: the row says its
                // level can't be shown, and the next opening retries it.
                input.stop()
                opened[uid] = nil
                failed[uid] = device
                levels[uid] = nil
                followers[uid] = nil
                continue
            }
            guard let rms = input.rms() else {
                levels[uid] = nil
                followers[uid] = nil
                continue
            }
            var follower = followers[uid] ?? LevelFollower()
            levels[uid] = follower.advance(to: SpeechLevel.of(rms: rms), seconds: elapsed)
            followers[uid] = follower
        }
    }

    private func reconcile() {
        guard isMetering, !isRecording, authorized() else { closeInputs(); return }
        let available = inputs.devices.filter {
            !($0.isBuiltIn && inputs.lidClosed) && engine.isMeterable($0)
        }
        for (uid, (device, input)) in opened where !available.contains(device) {
            input.stop()
            opened[uid] = nil
            followers[uid] = nil
            levels[uid] = nil
        }
        for device in available where opened[device.uid] == nil && failed[device.uid] != device {
            if let input = engine.open(device) { opened[device.uid] = (device, input) }
            else { failed[device.uid] = device }
        }
    }

    private func closeInputs() {
        for (_, input) in opened.values { input.stop() }
        opened.removeAll()
        // Keep known failures visible when folded; a new session retries them.
        followers.removeAll()
        levels.removeAll()
    }
}
