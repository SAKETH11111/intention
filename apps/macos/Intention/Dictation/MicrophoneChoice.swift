import Foundation

/// One input device as Core Audio lists it, read without opening it.
struct AudioInput: Equatable, Sendable {
    /// Core Audio's number for the device, good until it goes away.
    let id: UInt32
    /// Core Audio's name for the device that stays the same across launches
    /// and reconnections, which a saved choice is kept by.
    let uid: String
    let name: String
    /// Inside the Mac, as a MacBook's or an iMac's own microphone is.
    let isBuiltIn: Bool
}

/// The inputs at one moment: the devices that can record, the one chosen
/// in System Settings, and whether a MacBook's lid is closed.
struct AudioInputs: Equatable, Sendable {
    /// Devices with an input that is alive and has something to record from.
    var devices: [AudioInput]
    /// The system default input's number, nil when there is none.
    var systemDefault: UInt32?
    /// A MacBook's lid is closed, as when it runs on an external display.
    var lidClosed: Bool

    static let none = AudioInputs(devices: [], systemDefault: nil, lidClosed: false)
}

/// The microphone the person chose in Settings.
enum MicrophonePreference: Hashable, Sendable {
    /// The Mac's own microphone, the default for everyone, as Wispr Flow
    /// recommends: macOS makes AirPods or another headset the default input
    /// when it connects, and its microphone is made for calls.
    case builtIn
    case systemDefault
    /// One device by its Core Audio UID, with the name it had when chosen,
    /// to say which device is missing when it is not connected.
    case device(uid: String, name: String)
}

/// Which input a dictation records from, and when a recording moves to
/// another. The built-in microphone unless the person chose otherwise; the
/// system default input when there is no built-in microphone that hears,
/// as on a desktop Mac or a MacBook with its lid closed. Apple notebooks
/// cut the microphone off in hardware while the lid is closed, and Core
/// Audio may go on listing it, so the lid decides, not the list alone.
/// Nothing is picked that cannot hear, whatever the choice: a recording
/// would only move off it again.
enum MicrophoneChoice {
    struct Pick: Equatable {
        /// What to open; nil when nothing can record.
        let device: AudioInput?
        /// Why `device` is not what was chosen, when it is not.
        let fallback: Fallback?
    }

    enum Fallback: Equatable {
        /// The lid is closed, so the built-in microphone hears nothing.
        case lidClosed
        /// The Mac has none, as a Mac mini or a Mac Studio.
        case noBuiltIn
        /// The device chosen by name is not connected.
        case missing(name: String)

        /// A fixed name for the log.
        var name: String {
            switch self {
            case .lidClosed: "lidClosed"
            case .noBuiltIn: "noBuiltIn"
            case .missing: "missing"
            }
        }
    }

    static func pick(_ preference: MicrophonePreference, from inputs: AudioInputs) -> Pick {
        switch preference {
        case .systemDefault:
            let chosen = systemDefault(in: inputs)
            if let chosen, hears(chosen, in: inputs) { return Pick(device: chosen, fallback: nil) }
            // Only a built-in microphone behind a closed lid cannot hear.
            return Pick(device: fallback(in: inputs), fallback: chosen == nil ? nil : .lidClosed)
        case .builtIn:
            // The default first, for a Mac that lists more than one.
            let builtIn = inputs.devices.filter { $0.isBuiltIn && hears($0, in: inputs) }
            if let device = builtIn.first(where: { $0.id == inputs.systemDefault }) ?? builtIn.first {
                return Pick(device: device, fallback: nil)
            }
            return Pick(device: fallback(in: inputs), fallback: inputs.lidClosed ? .lidClosed : .noBuiltIn)
        case let .device(uid, name):
            if let device = inputs.devices.first(where: { $0.uid == uid }), hears(device, in: inputs) {
                return Pick(device: device, fallback: nil)
            }
            return Pick(device: pick(.builtIn, from: inputs).device, fallback: .missing(name: name))
        }
    }

    /// Whether a recording on `recording` moves, which happens only when
    /// that device can no longer record: it went away, the lid closed on
    /// the built-in microphone, or its format changed and it must be opened
    /// again anyway. A move loses what is said while the next device opens,
    /// up to a second for a Bluetooth headset, so a better choice that
    /// appears mid-dictation, such as the lid opening, the chosen device
    /// connecting or a new default input, waits for the next dictation.
    static func mustMove(recording: AudioInput, formatChanged: Bool, in inputs: AudioInputs) -> Bool {
        formatChanged || !hears(recording, in: inputs)
            || !inputs.devices.contains { $0.id == recording.id && $0.uid == recording.uid }
    }

    /// Whether `device` can hear the person: anything but a built-in
    /// microphone behind a closed lid.
    private static func hears(_ device: AudioInput, in inputs: AudioInputs) -> Bool {
        !(device.isBuiltIn && inputs.lidClosed)
    }

    private static func systemDefault(in inputs: AudioInputs) -> AudioInput? {
        inputs.devices.first { $0.id == inputs.systemDefault }
    }

    /// The system default input, unless it is a built-in microphone behind
    /// a closed lid, then the first other input that can hear; nil when
    /// none can, as with the lid closed on a MacBook's only microphone.
    private static func fallback(in inputs: AudioInputs) -> AudioInput? {
        if let device = systemDefault(in: inputs), hears(device, in: inputs) { return device }
        return inputs.devices.first { hears($0, in: inputs) }
    }
}
