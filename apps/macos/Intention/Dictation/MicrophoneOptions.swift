import Foundation

/// Words shared by the Settings picker and the foot menu.
enum MicrophoneOptions {
    /// What the menu's button says: the chosen option, without the advice
    /// the menu gives beside the built-in microphone.
    static func label(for chosen: MicrophonePreference, in inputs: AudioInputs) -> String {
        let title = options(for: chosen, in: inputs).first { $0.preference == chosen }?.title ?? "System default"
        return title.replacingOccurrences(of: " (recommended)", with: "")
    }

    struct Option: Equatable {
        let title: String
        let preference: MicrophonePreference
    }

    /// The built-in microphone and the system default, then every other
    /// input by name, and a chosen device that is not connected, so the
    /// menu still shows the choice.
    static func options(for chosen: MicrophonePreference, in inputs: AudioInputs) -> [Option] {
        var options = [Option(title: "Built-in microphone (recommended)", preference: .builtIn),
                       Option(title: "System default", preference: .systemDefault)]
        let primary = inputs.devices.first { $0.isBuiltIn && $0.id == inputs.systemDefault }
            ?? inputs.devices.first { $0.isBuiltIn }
        var chosenListed = false
        for device in inputs.devices {
            // The recommended option already names the primary built-in input.
            // Keep other built-in inputs and an explicitly saved primary device.
            let explicitlyChosen: Bool
            if case let .device(uid, _) = chosen { explicitlyChosen = uid == device.uid }
            else { explicitlyChosen = false }
            if device == primary && !explicitlyChosen { continue }
            // A device renamed since it was chosen is still the one chosen.
            if case let .device(uid, _) = chosen, uid == device.uid {
                chosenListed = true
                options.append(Option(title: device.name, preference: chosen))
            } else {
                options.append(Option(title: device.name, preference: .device(uid: device.uid, name: device.name)))
            }
        }
        if case let .device(_, name) = chosen, !chosenListed {
            options.append(Option(title: "\(name) (not connected)", preference: chosen))
        }
        return options
    }

    /// A line only when no microphone can record, since a dictation would
    /// then hear nothing: none is connected, or the lid is closed on the
    /// only one. Otherwise the menu says enough, a device chosen by name
    /// that is away included.
    static func note(for preference: MicrophonePreference, in inputs: AudioInputs) -> String? {
        guard MicrophoneChoice.pick(preference, from: inputs).device == nil else { return nil }
        // Inputs listed and none chosen: only the lid stops one hearing.
        return inputs.devices.isEmpty ? "No microphone is connected."
            : "The built-in microphone is off while the lid is closed. Open the lid or connect a microphone."
    }
}
