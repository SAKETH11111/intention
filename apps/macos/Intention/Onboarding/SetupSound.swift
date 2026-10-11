import AudioToolbox
import Foundation

/// Setup's two sounds: a code accepted, and the first words landing.
///
/// They are played as interface sound effects, so the Mac's own "Play
/// user interface sound effects" setting silences them for anyone who
/// keeps that off, and they follow the alert volume. Nothing else in setup
/// makes a sound.
@MainActor
enum SetupSound: String {
    case accepted = "SetupAccepted"
    case landed = "SetupLanded"

    private static var loaded: [SetupSound: SystemSoundID] = [:]

    @discardableResult
    func play() -> Bool {
        #if DEBUG
        // A recording has no sound of its own; the demo says when each
        // would have played, so the video can be given them afterwards.
        if OnboardingFixture.isDemo {
            FileHandle.standardError.write(Data("sound \(rawValue) \(ProcessInfo.processInfo.systemUptime)\n".utf8))
            return false
        }
        #endif
        guard !ProcessSafety.isSilent else { return false }
        if Self.loaded[self] == nil, let url = Bundle.main.url(forResource: rawValue, withExtension: "caf") {
            var id: SystemSoundID = 0
            if AudioServicesCreateSystemSoundID(url as CFURL, &id) == kAudioServicesNoError { Self.loaded[self] = id }
        }
        guard let id = Self.loaded[self] else { return false }
        SoundOutput.playSystemSound(id)
        return true
    }
}
