import CoreAudio
import Foundation
@testable import Dictation
import Testing

/// Made-up inputs, with the numbers and identifiers Core Audio gives such
/// devices: a MacBook's own microphone, AirPods, a USB microphone and an
/// external display's microphone. No test here opens a device.
enum MadeUpInputs {
    static let builtIn = AudioInput(id: 77, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", isBuiltIn: true)
    static let airPods = AudioInput(id: 91, uid: "00-11-22-33-44-55:input", name: "AirPods Pro", isBuiltIn: false)
    static let usb = AudioInput(id: 93, uid: "AppleUSBAudioEngine:Made Up:USB Microphone:1:1", name: "USB Microphone", isBuiltIn: false)
    static let display = AudioInput(id: 95, uid: "AppleUSBAudioEngine:Made Up:Display Audio:2:1", name: "Display Microphone", isBuiltIn: false)

    static func inputs(_ devices: [AudioInput], default systemDefault: AudioInput?, lidClosed: Bool = false) -> AudioInputs {
        AudioInputs(devices: devices, systemDefault: systemDefault?.id, lidClosed: lidClosed)
    }
}

/// Stands in for Core Audio: a list of inputs the test changes, and
/// devices that hand on chunks named after them when told to.
@MainActor
final class StandInHardware: MicrophoneHardware {
    var now: AudioInputs
    var permitted = true
    /// Runs as each device opens, before it is looked for in `now`: a test
    /// takes a device off the list here to have it go away while it opens.
    var opening: @MainActor (AudioInput) -> Void = { _ in }
    /// Devices that will not open though listed, as one Core Audio still
    /// lists for a moment after it went away.
    var refused: Set<UInt32> = []
    /// Whether each device, once open, asks for a check on the main queue,
    /// as Core Audio's does for a change that landed before its listeners.
    var checksOnceOpen = false
    /// Every device opened, in order.
    private(set) var opened: [AudioInput] = []
    private(set) var current: StandInDevice?

    init(_ now: AudioInputs) {
        self.now = now
    }

    func inputs() -> AudioInputs { now }

    func open(_ device: AudioInput, audio: @escaping @Sendable (Data) -> Void,
              check: @escaping @MainActor () -> Void) throws -> any OpenMicrophone {
        opening(device)
        guard now.devices.contains(device), !refused.contains(device.id) else { throw Microphone.Failure.unavailable }
        let input = StandInDevice(device: device, audio: audio, check: check)
        opened.append(device)
        current = input
        if checksOnceOpen { Task { check() } }
        return input
    }

    /// The inputs change, and the open device's listeners fire, as Core
    /// Audio's and the lid's would.
    func change(_ change: (inout AudioInputs) -> Void) {
        change(&now)
        current?.check()
    }
}

@MainActor
final class StandInDevice: OpenMicrophone {
    let device: AudioInput
    let check: @MainActor () -> Void
    private let audio: @Sendable (Data) -> Void
    private var said = 0
    var formatChanged = false
    private(set) var closed = false
    private(set) var receivedFrames = false

    init(device: AudioInput, audio: @escaping @Sendable (Data) -> Void, check: @escaping @MainActor () -> Void) {
        self.device = device
        self.audio = audio
        self.check = check
    }

    /// A chunk of speech, named after the device and its place.
    func speak() {
        receivedFrames = true
        said += 1
        audio(Data("\(device.name) \(said)".utf8))
    }

    /// The last partial chunk goes out as the device closes.
    func close() {
        guard !closed else { return }
        closed = true
        audio(Data("\(device.name) end".utf8))
    }
}

/// Which microphone a dictation records from, and what a change of inputs
/// does to one that is recording.
@MainActor
struct MicrophoneChoiceTests {
    private typealias Inputs = MadeUpInputs

    private func chosen(_ preference: MicrophonePreference, _ inputs: AudioInputs) -> String? {
        MicrophoneChoice.pick(preference, from: inputs).device?.name
    }

    // MARK: - The rule

    @Test func theBuiltInMicrophoneIsChosenWhenAirPodsAreTheDefault() {
        let inputs = Inputs.inputs([Inputs.builtIn, Inputs.airPods], default: Inputs.airPods)
        #expect(chosen(.builtIn, inputs) == "MacBook Pro Microphone")
    }

    /// Lid closed on an external display: Core Audio may still list the
    /// built-in microphone, which hears nothing then.
    @Test func withTheLidClosedTheSystemDefaultIsChosen() {
        let display = Inputs.inputs([Inputs.builtIn, Inputs.display], default: Inputs.display, lidClosed: true)
        #expect(chosen(.builtIn, display) == "Display Microphone")
        let airPods = Inputs.inputs([Inputs.builtIn, Inputs.airPods, Inputs.display], default: Inputs.airPods, lidClosed: true)
        #expect(chosen(.builtIn, airPods) == "AirPods Pro")
        // The same when Core Audio stops listing the built-in microphone.
        #expect(chosen(.builtIn, Inputs.inputs([Inputs.airPods], default: Inputs.airPods, lidClosed: true)) == "AirPods Pro")
    }

    /// With the lid closed and the cut-off microphone still the default,
    /// another input that can hear is used if there is one, whatever the
    /// choice; with none, nothing is chosen, since a recording would only
    /// move off the cut-off microphone again.
    @Test func withTheLidClosedTheCutOffMicrophoneIsNeverChosen() {
        let usb = Inputs.inputs([Inputs.builtIn, Inputs.usb], default: Inputs.builtIn, lidClosed: true)
        let alone = Inputs.inputs([Inputs.builtIn], default: Inputs.builtIn, lidClosed: true)
        let missing = MicrophonePreference.device(uid: Inputs.airPods.uid, name: "AirPods Pro")
        for preference in [MicrophonePreference.builtIn, .systemDefault, missing] {
            #expect(chosen(preference, usb) == "USB Microphone")
            #expect(chosen(preference, alone) == nil)
        }
        #expect(MicrophoneChoice.pick(.systemDefault, from: usb).fallback == .lidClosed)
    }

    @Test func aMacWithoutABuiltInMicrophoneUsesTheSystemDefault() {
        let desktop = Inputs.inputs([Inputs.usb, Inputs.airPods], default: Inputs.usb)
        #expect(chosen(.builtIn, desktop) == "USB Microphone")
        #expect(chosen(.builtIn, Inputs.inputs([Inputs.usb, Inputs.airPods], default: Inputs.airPods)) == "AirPods Pro")
        #expect(chosen(.builtIn, Inputs.inputs([], default: nil)) == nil)
    }

    @Test func openingTheLidAgainChoosesTheBuiltInMicrophone() {
        var inputs = Inputs.inputs([Inputs.builtIn, Inputs.airPods], default: Inputs.airPods, lidClosed: true)
        #expect(chosen(.builtIn, inputs) == "AirPods Pro")
        inputs.lidClosed = false
        #expect(chosen(.builtIn, inputs) == "MacBook Pro Microphone")
    }

    @Test func theSettingsChoiceIsRespected() {
        let inputs = Inputs.inputs([Inputs.builtIn, Inputs.airPods, Inputs.usb], default: Inputs.airPods)
        #expect(chosen(.systemDefault, inputs) == "AirPods Pro")
        #expect(chosen(.device(uid: Inputs.usb.uid, name: "USB Microphone"), inputs) == "USB Microphone")
        // A device that is not connected falls back as the built-in choice does.
        let unplugged = Inputs.inputs([Inputs.builtIn, Inputs.airPods], default: Inputs.airPods)
        #expect(chosen(.device(uid: Inputs.usb.uid, name: "USB Microphone"), unplugged) == "MacBook Pro Microphone")
        let lidClosed = Inputs.inputs([Inputs.builtIn, Inputs.airPods], default: Inputs.airPods, lidClosed: true)
        #expect(chosen(.device(uid: Inputs.usb.uid, name: "USB Microphone"), lidClosed) == "AirPods Pro")
        // The device is known by its identifier, whatever it is called now.
        #expect(chosen(.device(uid: Inputs.usb.uid, name: "Old name"), inputs) == "USB Microphone")
    }

    // MARK: - Recording through a change

    private func spoken(_ collected: Collected) -> [String] {
        collected.chunks.map { String(decoding: $0, as: UTF8.self) }
    }

    /// AirPods connect mid-dictation and macOS makes them the default
    /// input: the recording stays on the built-in microphone, nothing it
    /// heard is lost, and the next dictation starts there too.
    @Test func theDefaultTurningToAirPodsWhileRecordingKeepsTheBuiltInMicrophone() throws {
        let hardware = StandInHardware(Inputs.inputs([Inputs.builtIn], default: Inputs.builtIn))
        let microphone = Microphone(preference: { .builtIn }, hardware: hardware)
        let collected = Collected()
        let interruptions = Heard()
        try microphone.start(audio: { collected.add($0) }, interrupted: { interruptions.calls += 1 }, device: { _ in })
        hardware.current?.speak()
        hardware.change { $0 = Inputs.inputs([Inputs.builtIn, Inputs.airPods], default: Inputs.airPods) }
        hardware.current?.speak()
        microphone.stop()
        #expect(hardware.opened.map(\.name) == ["MacBook Pro Microphone"])
        #expect(spoken(collected) == ["MacBook Pro Microphone 1", "MacBook Pro Microphone 2", "MacBook Pro Microphone end"])
        #expect(interruptions.calls == 0)

        try microphone.start(audio: { _ in }, interrupted: {}, device: { _ in })
        #expect(hardware.opened.map(\.name) == ["MacBook Pro Microphone", "MacBook Pro Microphone"])
        microphone.stop()
    }

    @Test func theDefaultTurningToAirPodsBetweenRecordingsLeavesTheNextOnTheBuiltInMicrophone() throws {
        let hardware = StandInHardware(Inputs.inputs([Inputs.builtIn], default: Inputs.builtIn))
        let microphone = Microphone(preference: { .builtIn }, hardware: hardware)
        try microphone.start(audio: { _ in }, interrupted: {}, device: { _ in })
        microphone.stop()
        hardware.now = Inputs.inputs([Inputs.builtIn, Inputs.airPods], default: Inputs.airPods)
        try microphone.start(audio: { _ in }, interrupted: {}, device: { _ in })
        microphone.stop()
        #expect(hardware.opened.map(\.name) == ["MacBook Pro Microphone", "MacBook Pro Microphone"])
    }

    /// Closing the lid cuts the built-in microphone off, so the recording
    /// moves to the system default onto the same dictation: what the
    /// built-in microphone heard goes out first, then the new device's.
    @Test func closingTheLidWhileRecordingMovesToTheSystemDefaultWithoutLosingAudio() throws {
        let hardware = StandInHardware(Inputs.inputs([Inputs.builtIn, Inputs.airPods], default: Inputs.airPods))
        let microphone = Microphone(preference: { .builtIn }, hardware: hardware)
        let collected = Collected()
        let interruptions = Heard()
        try microphone.start(audio: { collected.add($0) }, interrupted: { interruptions.calls += 1 }, device: { _ in })
        let builtIn = try #require(hardware.current)
        builtIn.speak()
        hardware.change { $0.lidClosed = true }
        #expect(builtIn.closed)
        hardware.current?.speak()
        microphone.stop()
        #expect(hardware.opened.map(\.name) == ["MacBook Pro Microphone", "AirPods Pro"])
        #expect(spoken(collected) == ["MacBook Pro Microphone 1", "MacBook Pro Microphone end", "AirPods Pro 1", "AirPods Pro end"])
        #expect(interruptions.calls == 0)
    }

    /// Opening the lid while recording on AirPods leaves the recording
    /// where it is, since AirPods still hear; the next dictation is back
    /// on the built-in microphone.
    @Test func openingTheLidWhileRecordingKeepsTheDeviceUntilTheDictationEnds() throws {
        let hardware = StandInHardware(Inputs.inputs([Inputs.builtIn, Inputs.airPods], default: Inputs.airPods, lidClosed: true))
        let microphone = Microphone(preference: { .builtIn }, hardware: hardware)
        let collected = Collected()
        try microphone.start(audio: { collected.add($0) }, interrupted: {}, device: { _ in })
        hardware.current?.speak()
        hardware.change { $0.lidClosed = false }
        hardware.current?.speak()
        microphone.stop()
        #expect(spoken(collected) == ["AirPods Pro 1", "AirPods Pro 2", "AirPods Pro end"])
        try microphone.start(audio: { _ in }, interrupted: {}, device: { _ in })
        microphone.stop()
        #expect(hardware.opened.map(\.name) == ["AirPods Pro", "MacBook Pro Microphone"])
    }

    /// The device recording goes away: the recording moves to what the
    /// rule picks then, after what the old one heard.
    @Test func aDeviceThatGoesAwayWhileRecordingMovesTheRecording() throws {
        let hardware = StandInHardware(Inputs.inputs([Inputs.builtIn, Inputs.usb], default: Inputs.usb))
        let microphone = Microphone(preference: { .device(uid: Inputs.usb.uid, name: "USB Microphone") }, hardware: hardware)
        let collected = Collected()
        try microphone.start(audio: { collected.add($0) }, interrupted: {}, device: { _ in })
        hardware.current?.speak()
        hardware.change { $0 = Inputs.inputs([Inputs.builtIn], default: Inputs.builtIn) }
        hardware.current?.speak()
        microphone.stop()
        #expect(spoken(collected) == ["USB Microphone 1", "USB Microphone end", "MacBook Pro Microphone 1", "MacBook Pro Microphone end"])
    }

    /// Each device a recording opens is named to dictation as it opens,
    /// the one it moves to included, so a dictation that heard nothing can
    /// say which microphone it ended on. The lid closing on the only
    /// microphone opens nothing and names nothing.
    @Test func eachDeviceARecordingOpensIsNamedAsItOpens() throws {
        let hardware = StandInHardware(Inputs.inputs([Inputs.builtIn, Inputs.usb], default: Inputs.usb))
        let microphone = Microphone(preference: { .device(uid: Inputs.usb.uid, name: "USB Microphone") }, hardware: hardware)
        var named: [String] = []
        try microphone.start(audio: { _ in }, interrupted: {}, device: { named.append($0) })
        #expect(named == ["USB Microphone"])
        hardware.change { $0 = Inputs.inputs([Inputs.builtIn], default: Inputs.builtIn) }
        #expect(named == ["USB Microphone", "MacBook Pro Microphone"])
        microphone.stop()

        let closed = StandInHardware(Inputs.inputs([Inputs.builtIn], default: Inputs.builtIn, lidClosed: true))
        var none: [String] = []
        try Microphone(preference: { .builtIn }, hardware: closed).start(audio: { _ in }, interrupted: {}, device: { none.append($0) })
        #expect(none.isEmpty)
    }

    /// A device that goes away while it is being opened, as a USB
    /// microphone pulled out just as a format change reopens it: the inputs
    /// are read again, and the recording goes on, onto the same dictation,
    /// on the device the rule picks then, after what the old one heard.
    @Test func aDeviceThatGoesAwayWhileItOpensIsPassedOver() throws {
        let hardware = StandInHardware(Inputs.inputs([Inputs.builtIn, Inputs.usb], default: Inputs.usb))
        let microphone = Microphone(preference: { .device(uid: Inputs.usb.uid, name: "USB Microphone") }, hardware: hardware)
        let collected = Collected()
        let interruptions = Heard()
        try microphone.start(audio: { collected.add($0) }, interrupted: { interruptions.calls += 1 }, device: { _ in })
        let usb = try #require(hardware.current)
        usb.speak()
        hardware.opening = { [unowned hardware] device in
            if device == Inputs.usb { hardware.now = Inputs.inputs([Inputs.builtIn], default: Inputs.builtIn) }
        }
        usb.formatChanged = true
        usb.check()
        hardware.current?.speak()
        microphone.stop()
        #expect(interruptions.calls == 0)
        #expect(hardware.opened.map(\.name) == ["USB Microphone", "MacBook Pro Microphone"])
        #expect(spoken(collected) == ["USB Microphone 1", "USB Microphone end", "MacBook Pro Microphone 1", "MacBook Pro Microphone end"])
    }

    /// A device that will not open while Core Audio still lists it, here
    /// as a dictation starts, is left out of the second choice, so the
    /// dictation records from AirPods instead of not starting.
    @Test func aDeviceStillListedAfterItWouldNotOpenIsLeftOut() throws {
        let hardware = StandInHardware(Inputs.inputs([Inputs.builtIn, Inputs.airPods], default: Inputs.airPods))
        hardware.refused = [Inputs.builtIn.id]
        let microphone = Microphone(preference: { .builtIn }, hardware: hardware)
        try microphone.start(audio: { _ in }, interrupted: {}, device: { _ in })
        #expect(hardware.opened.map(\.name) == ["AirPods Pro"])
        microphone.stop()
    }

    /// The second choice is tried once and counts as a move: when it will
    /// not open either, or the dictation has already moved as often as it
    /// may, the dictation ends with what was recorded.
    @Test func theSecondChoiceIsTriedOnceAndCountsAsAMove() throws {
        // Neither the USB microphone nor the built-in one opens; AirPods,
        // which would, are not tried.
        let hardware = StandInHardware(Inputs.inputs([Inputs.builtIn, Inputs.usb, Inputs.airPods], default: Inputs.airPods))
        let microphone = Microphone(preference: { .device(uid: Inputs.usb.uid, name: "USB Microphone") }, hardware: hardware)
        let collected = Collected()
        let interruptions = Heard()
        try microphone.start(audio: { collected.add($0) }, interrupted: { interruptions.calls += 1 }, device: { _ in })
        hardware.current?.speak()
        hardware.refused = [Inputs.usb.id, Inputs.builtIn.id]
        hardware.current?.formatChanged = true
        hardware.current?.check()
        #expect(interruptions.calls == 1)
        #expect(hardware.opened.map(\.name) == ["USB Microphone"])
        #expect(spoken(collected) == ["USB Microphone 1", "USB Microphone end"])

        // The last move allowed finds its device will not open: nothing
        // more is tried.
        let again = StandInHardware(Inputs.inputs([Inputs.builtIn, Inputs.usb], default: Inputs.usb))
        let second = Microphone(preference: { .device(uid: Inputs.usb.uid, name: "USB Microphone") }, hardware: again)
        let ended = Heard()
        try second.start(audio: { _ in }, interrupted: { ended.calls += 1 }, device: { _ in })
        for _ in 1..<Microphone.reopens {
            again.current?.formatChanged = true
            again.current?.check()
        }
        again.refused = [Inputs.usb.id]
        again.current?.formatChanged = true
        again.current?.check()
        #expect(ended.calls == 1)
        #expect(again.opened.map(\.name) == Array(repeating: "USB Microphone", count: Microphone.reopens))
    }

    /// With the lid closed and only the built-in microphone listed, no
    /// input can hear, whatever the choice: nothing opens, so the cut-off
    /// microphone is not opened and moved off three times. The dictation
    /// records nothing until the person stops it, and ends as one that
    /// heard nothing.
    @Test func withOnlyTheCutOffMicrophoneNothingOpens() async throws {
        let missing = MicrophonePreference.device(uid: Inputs.usb.uid, name: "USB Microphone")
        for preference in [MicrophonePreference.builtIn, .systemDefault, missing] {
            let hardware = StandInHardware(Inputs.inputs([Inputs.builtIn], default: Inputs.builtIn, lidClosed: true))
            hardware.checksOnceOpen = true
            let microphone = Microphone(preference: { preference }, hardware: hardware)
            let collected = Collected()
            let interruptions = Heard()
            try microphone.start(audio: { collected.add($0) }, interrupted: { interruptions.calls += 1 }, device: { _ in })
            // Long enough for the checks an open device asks for to run.
            try await Task.sleep(for: .milliseconds(100))
            #expect(hardware.opened.map(\.name) == [])
            #expect(interruptions.calls == 1)
            microphone.stop()
            #expect(collected.chunks.isEmpty)
        }
    }

    /// A device whose format keeps changing reopens three times at most,
    /// then the dictation ends with what was recorded.
    @Test func aDeviceThatKeepsChangingPausesForRecovery() throws {
        let hardware = StandInHardware(Inputs.inputs([Inputs.builtIn], default: Inputs.builtIn))
        let microphone = Microphone(preference: { .builtIn }, hardware: hardware)
        let interruptions = Heard()
        try microphone.start(audio: { _ in }, interrupted: { interruptions.calls += 1 }, device: { _ in })
        for _ in 0...Microphone.reopens {
            hardware.current?.formatChanged = true
            hardware.current?.check()
        }
        #expect(hardware.opened.count == Microphone.reopens + 1)
        #expect(interruptions.calls == 1)
    }

    /// A check that comes from a device already replaced or closed, as a
    /// listener's call still on its way does, moves nothing.
    @Test func aCheckFromAnOldDeviceDoesNothing() throws {
        let hardware = StandInHardware(Inputs.inputs([Inputs.builtIn, Inputs.airPods], default: Inputs.airPods))
        let microphone = Microphone(preference: { .builtIn }, hardware: hardware)
        try microphone.start(audio: { _ in }, interrupted: {}, device: { _ in })
        let first = try #require(hardware.current)
        microphone.stop()
        hardware.now.lidClosed = true
        first.check()
        #expect(hardware.opened.count == 1)
    }

    // MARK: - Listeners

    /// Core Audio calls its property listener, and IOKit the lid's, on
    /// threads of their own. Each reaches its handler on the main actor;
    /// a handler that ran on the calling queue would trap here under the
    /// actor data-race checks this suite is built with.
    @Test func listenerCallbacksReachTheMainActorFromABackgroundQueue() async throws {
        let heard = Heard()
        let number = DeviceNotices.add {
            heard.calls += 1
            heard.allOnMain = heard.allOnMain && Thread.isMainThread
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                let refcon = UnsafeMutableRawPointer(bitPattern: number)
                var property = AudioHardware.address(kAudioHardwarePropertyDefaultInputDevice)
                _ = audioPropertyChanged(AudioHardware.system, 1, &property, refcon)
                lidChanged(refcon, 0, clamshellStateChange, nil)
                // Other power-management messages, such as one about sleep,
                // are not the lid.
                lidChanged(refcon, 0, 0xE000_0280, nil)
                done.resume()
            }
        }
        #expect(await eventually { heard.calls == 2 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(heard.calls == 2)
        #expect(heard.allOnMain)
        DeviceNotices.remove(number)
    }

    /// A recording listens for every change that can take its device off
    /// the inputs, its input sources among them: Core Audio goes on listing
    /// a device whose sources are gone, with its rate and channels as they
    /// were, and `AudioHardware.inputs()` drops it, so without that
    /// listener the recording would stay on a device that records nothing.
    /// Each listener's call from Core Audio's thread reaches the recording's
    /// check on the main actor.
    @Test func aRecordingHearsItsDeviceLoseItsInputSources() async throws {
        let device: AudioDeviceID = 77
        let watched = AudioHardware.watchedWhileRecording(device)
        #expect(watched.contains {
            $0.object == device && $0.property.mSelector == kAudioDevicePropertyDataSources
                && $0.property.mScope == kAudioObjectPropertyScopeInput
        })
        let heard = Heard()
        let number = DeviceNotices.add {
            heard.calls += 1
            heard.allOnMain = heard.allOnMain && Thread.isMainThread
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                for (object, property) in watched {
                    var property = property
                    _ = audioPropertyChanged(object, 1, &property, UnsafeMutableRawPointer(bitPattern: number))
                }
                done.resume()
            }
        }
        #expect(await eventually { heard.calls == watched.count })
        #expect(heard.allOnMain)
        DeviceNotices.remove(number)
    }

    /// A listener's call that arrives after its listener was removed finds
    /// nothing to run.
    @Test func aCallForARemovedListenerDoesNothing() async throws {
        let heard = Heard()
        let number = DeviceNotices.add { heard.calls += 1 }
        DeviceNotices.remove(number)
        DispatchQueue.global().async {
            var property = AudioHardware.address(kAudioDevicePropertyDeviceIsAlive)
            _ = audioPropertyChanged(77, 1, &property, UnsafeMutableRawPointer(bitPattern: number))
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(heard.calls == 0)
    }

    /// IOKit takes the lid listener on any Mac, with no permission, and
    /// lets it go again.
    @Test func theLidListenerRegistersAndIsRemoved() {
        let lid = LidListener(number: 1)
        #expect(lid.isListening)
        lid.remove()
        #expect(!lid.isListening)
    }
}

@MainActor
final class Heard {
    var calls = 0
    var allOnMain = true
}

/// Whether `condition` holds within two seconds.
@MainActor
func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

extension MicrophoneChoiceTests {
    @Test func aFlappingRouteRecoversAfterItsImmediateReopensWithoutEndingTheSession() async throws {
        let hardware = StandInHardware(Inputs.inputs([Inputs.builtIn], default: Inputs.builtIn))
        let microphone = Microphone(preference: { .builtIn }, hardware: hardware)
        // Recovery's second between tries, passed at once: the reopen waits
        // on the recovery task, never on the clock.
        microphone.recoveryWait = { _ in await Task.yield() }
        let interruptions = Heard()
        let collected = Collected()
        try microphone.start(audio: { collected.add($0) }, interrupted: { interruptions.calls += 1 }, device: { _ in })
        defer { microphone.stop() }
        for _ in 0...Microphone.reopens {
            hardware.current?.speak()
            hardware.current?.formatChanged = true
            hardware.current?.check()
        }
        #expect(interruptions.calls == 1)
        #expect(await eventually { hardware.opened.count == Microphone.reopens + 2 })
        hardware.current?.speak()
        #expect(spoken(collected).last == "MacBook Pro Microphone 1")
    }

    @Test func stoppingWhileTheMicrophoneRecoversNeverReopensIt() async throws {
        let hardware = StandInHardware(Inputs.inputs([Inputs.builtIn], default: Inputs.builtIn))
        let microphone = Microphone(preference: { .builtIn }, hardware: hardware)
        try microphone.start(audio: { _ in }, interrupted: {}, device: { _ in })
        hardware.refused = [Inputs.builtIn.id]
        hardware.current?.formatChanged = true
        hardware.current?.check()
        let opened = hardware.opened.count
        microphone.stop()
        hardware.refused = []
        try await Task.sleep(for: .milliseconds(1100))
        #expect(hardware.opened.count == opened)
    }
}
