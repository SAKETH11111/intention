import CoreAudio
import Foundation
@testable import Dictation
import Testing

/// The Microphone choice in Settings: where it is saved, what it starts
/// as, what the row offers and says, and the row following the inputs.
@MainActor
struct MicrophoneSettingsTests {
    private typealias Inputs = MadeUpInputs

    private func defaults() -> UserDefaults {
        let name = "MicrophoneSettingsTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func theBuiltInMicrophoneIsTheStartForFreshAndExistingSettings() {
        #expect(Preferences(defaults: defaults()).microphone == .builtIn)
        // A Mac that used Intention before this choice existed has other
        // settings saved and none for the microphone.
        let existing = defaults()
        existing.set("pill", forKey: "indicator")
        existing.set("rightOption", forKey: "dictationKey")
        existing.set(false, forKey: "writesEmails")
        existing.set(["en", "es"], forKey: "dictationLanguages")
        #expect(Preferences(defaults: existing).microphone == .builtIn)
        // Something this build does not know reads as the start too.
        existing.set("loudest", forKey: "microphone")
        #expect(Preferences(defaults: existing).microphone == .builtIn)
        existing.set("device", forKey: "microphone")
        #expect(Preferences(defaults: existing).microphone == .builtIn)
    }

    @Test func theChoiceIsSavedAndADeviceByItsIdentifier() {
        let store = defaults()
        Preferences(defaults: store).microphone = .systemDefault
        #expect(Preferences(defaults: store).microphone == .systemDefault)
        Preferences(defaults: store).microphone = .device(uid: Inputs.usb.uid, name: "USB Microphone")
        #expect(Preferences(defaults: store).microphone == .device(uid: Inputs.usb.uid, name: "USB Microphone"))
        #expect(store.string(forKey: "microphoneDevice") == Inputs.usb.uid)
        Preferences(defaults: store).microphone = .builtIn
        #expect(Preferences(defaults: store).microphone == .builtIn)
        #expect(store.string(forKey: "microphoneDevice") == nil)
    }

    @Test func aFallbackSaysWhy() {
        let lidClosed = Inputs.inputs([Inputs.builtIn, Inputs.airPods], default: Inputs.airPods, lidClosed: true)
        #expect(MicrophoneChoice.pick(.builtIn, from: lidClosed).fallback == .lidClosed)
        let desktop = Inputs.inputs([Inputs.usb], default: Inputs.usb)
        #expect(MicrophoneChoice.pick(.builtIn, from: desktop).fallback == .noBuiltIn)
        let unplugged = Inputs.inputs([Inputs.builtIn, Inputs.airPods], default: Inputs.airPods)
        let missing = MicrophoneChoice.pick(.device(uid: Inputs.usb.uid, name: "USB Microphone"), from: unplugged)
        #expect(missing == MicrophoneChoice.Pick(device: Inputs.builtIn, fallback: .missing(name: "USB Microphone")))
        let everything = Inputs.inputs([Inputs.builtIn, Inputs.airPods, Inputs.usb], default: Inputs.airPods)
        #expect(MicrophoneChoice.pick(.builtIn, from: everything).fallback == nil)
        #expect(MicrophoneChoice.pick(.systemDefault, from: everything).fallback == nil)
        #expect(MicrophoneChoice.pick(.device(uid: Inputs.usb.uid, name: "USB Microphone"), from: everything).fallback == nil)
    }

    @Test func theRowOffersTheBuiltInMicrophoneTheDefaultAndEachDevice() {
        let inputs = Inputs.inputs([Inputs.builtIn, Inputs.airPods, Inputs.usb], default: Inputs.airPods)
        let options = MicrophoneRow.options(for: .builtIn, in: inputs)
        #expect(options.map(\.title) == ["Built-in microphone (recommended)", "System default", "AirPods Pro", "USB Microphone"])
        #expect(options[3].preference == .device(uid: Inputs.usb.uid, name: "USB Microphone"))
        // A saved device that is not connected stays chosen, and says so.
        let saved = MicrophonePreference.device(uid: Inputs.display.uid, name: "Display Microphone")
        let unplugged = MicrophoneRow.options(for: saved, in: inputs)
        #expect(unplugged.last == MicrophoneRow.Option(title: "Display Microphone (not connected)", preference: saved))
        // A device renamed since it was chosen is still the one chosen.
        let renamed = MicrophonePreference.device(uid: Inputs.usb.uid, name: "Old name")
        #expect(MicrophoneRow.options(for: renamed, in: inputs).filter { $0.preference == renamed }.map(\.title) == ["USB Microphone"])
    }

    @Test func theRowSpeaksOnlyWhenNoMicrophoneCanRecord() {
        let usb = MicrophonePreference.device(uid: Inputs.usb.uid, name: "USB Microphone")
        func note(_ preference: MicrophonePreference, _ inputs: AudioInputs) -> String? {
            MicrophoneRow.note(for: preference, in: inputs)
        }
        // The menu says enough whenever some microphone can record: the
        // choice, a fallback for the lid or a Mac without one, and a chosen
        // device that is away, which the menu marks as not connected.
        let airPods = Inputs.inputs([Inputs.builtIn, Inputs.airPods], default: Inputs.airPods)
        #expect(note(.builtIn, airPods) == nil)
        #expect(note(.systemDefault, airPods) == nil)
        #expect(note(usb, Inputs.inputs([Inputs.builtIn, Inputs.usb], default: Inputs.builtIn)) == nil)
        #expect(note(usb, airPods) == nil)
        #expect(note(.builtIn, Inputs.inputs([Inputs.builtIn, Inputs.airPods], default: Inputs.airPods, lidClosed: true)) == nil)
        #expect(note(.systemDefault, Inputs.inputs([Inputs.builtIn, Inputs.usb], default: Inputs.builtIn, lidClosed: true)) == nil)
        #expect(note(.builtIn, Inputs.inputs([Inputs.usb], default: Inputs.usb)) == nil)
        // Nothing else to record from with the lid closed, whatever the choice.
        let alone = Inputs.inputs([Inputs.builtIn], default: Inputs.builtIn, lidClosed: true)
        for preference in [MicrophonePreference.builtIn, .systemDefault, usb] {
            #expect(note(preference, alone) == "The built-in microphone is off while the lid is closed. Open the lid or connect a microphone.")
        }
        #expect(note(.builtIn, .none) == "No microphone is connected.")
    }

    /// A recording keeps its device when the inputs or the choice change,
    /// so the row names no device a recording could contradict. A dictation
    /// starts on AirPods with the lid closed, and the lid opens: the
    /// recording stays on AirPods, and the row shows no line.
    @Test func theRowStaysTrueWhileADictationRecordsElsewhere() throws {
        let hardware = StandInHardware(Inputs.inputs([Inputs.builtIn, Inputs.airPods], default: Inputs.airPods, lidClosed: true))
        let chosen = Chosen(.builtIn)
        let microphone = Microphone(preference: { chosen.preference }, hardware: hardware)
        try microphone.start(audio: { _ in }, interrupted: {}, device: { _ in })
        hardware.change { $0.lidClosed = false }
        #expect(hardware.current?.device == Inputs.airPods)
        #expect(MicrophoneRow.note(for: chosen.preference, in: hardware.now) == nil)
        microphone.stop()

        // The choice changes while a dictation records on the built-in
        // microphone: still no line.
        try microphone.start(audio: { _ in }, interrupted: {}, device: { _ in })
        chosen.preference = .systemDefault
        hardware.change { _ in }
        #expect(hardware.current?.device == Inputs.builtIn)
        #expect(MicrophoneRow.note(for: chosen.preference, in: hardware.now) == nil)
        microphone.stop()
    }

    /// Settings follows the inputs while it shows: a listener's call from
    /// Core Audio's thread reads them again on the main actor, and leaving
    /// stops listening.
    @Test func theRowFollowsTheInputsFromABackgroundQueue() async throws {
        let source = Source(Inputs.inputs([Inputs.builtIn], default: Inputs.builtIn))
        let watch = AudioInputWatch(read: { source.now })
        let following = Task { await watch.follow() }
        #expect(await eventually { watch.listening != nil })
        #expect(watch.inputs == source.now)
        source.now = Inputs.inputs([Inputs.builtIn, Inputs.airPods], default: Inputs.airPods)
        let number = try #require(watch.listening)
        DispatchQueue.global().async {
            var property = AudioHardware.address(kAudioHardwarePropertyDefaultInputDevice)
            _ = audioPropertyChanged(AudioHardware.system, 1, &property, UnsafeMutableRawPointer(bitPattern: number))
        }
        #expect(await eventually { watch.inputs.systemDefault == Inputs.airPods.id })
        // The lid's notice is read the same way.
        source.now.lidClosed = true
        DispatchQueue.global().async { lidChanged(UnsafeMutableRawPointer(bitPattern: number), 0, clamshellStateChange, nil) }
        #expect(await eventually { watch.inputs.lidClosed })
        following.cancel()
        await following.value
        #expect(watch.listening == nil)
    }
}

@MainActor
private final class Chosen {
    var preference: MicrophonePreference
    init(_ preference: MicrophonePreference) { self.preference = preference }
}

@MainActor
private final class Source {
    var now: AudioInputs
    init(_ now: AudioInputs) { self.now = now }
}
