import AppKit
@testable import Intention
import Testing

@MainActor
@Suite(.serialized)
struct PreferencesTests {
    private func defaults() -> UserDefaults {
        let name = "PreferencesTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func findingTheCaretOnScreenKeepsASavedOptOutAndALaunchCanSayOtherwise() {
        let store = defaults()
        #expect(Preferences(defaults: store, arguments: ["Intention"]).visualCaretEnabled)
        // An opt-out the removed Settings switch saved still stands.
        store.set(false, forKey: "visualCaretEnabled")
        #expect(!Preferences(defaults: store, arguments: ["Intention"]).visualCaretEnabled)
        #expect(!Preferences(defaults: store, arguments: ["Intention", "-visualCaretEnabled", "NO"]).visualCaretEnabled)
        #expect(Preferences(defaults: store, arguments: ["Intention", "-visualCaretEnabled", "YES"]).visualCaretEnabled)
        // A flag with no value says nothing, so the saved choice stands.
        #expect(!Preferences(defaults: store, arguments: ["Intention", "-visualCaretEnabled"]).visualCaretEnabled)
        #expect(!Preferences(defaults: store, arguments: ["Intention", "-visualCaretEnabled", "--caret-permissions", "out.json"]).visualCaretEnabled)
        #expect(Preferences(defaults: store, arguments: ["Intention", "-visualCaretEnabled", "true"]).visualCaretEnabled)
    }

    @Test func appearanceDefaultsToLightPersistsDarkAndRejectsUnknownValues() {
        let store = defaults()
        let preferences = Preferences(defaults: store)
        #expect(preferences.appearance == .light)
        preferences.appearance = .dark
        #expect(store.string(forKey: "appearance") == "dark")
        #expect(Preferences(defaults: store).appearance == .dark)
        store.set("system", forKey: "appearance")
        #expect(Preferences(defaults: store).appearance == .light)
    }

    @Test func appearanceChangesNotifyAfterUpdatingTheAppKitPalette() {
        @MainActor final class Changes {
            var appearances: [Appearance] = []
            var palettes: [Palette] = []
        }
        let previous = Appearance.current
        defer { Appearance.current = previous }
        Appearance.current = .light
        let changes = Changes()
        let observer = NotificationCenter.default.addObserver(forName: .intentionAppearanceChanged, object: nil, queue: .main) { @Sendable _ in
            MainActor.assumeIsolated {
                changes.appearances.append(Appearance.current)
                changes.palettes.append(Palette.current)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        Appearance.current = .dark
        Appearance.current = .dark
        Appearance.current = .light
        #expect(changes.appearances == [.dark, .light])
        #expect(changes.palettes == [.night, .day])
    }

    @Test func appearanceWindowCallbackCanArriveOnABackgroundQueue() async {
        let previous = Appearance.current
        defer { Appearance.current = previous }
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        Appearance.current = .dark
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { @Sendable in
                MainWindow.updateAppearance(of: window)
                DispatchQueue.main.async { done.resume() }
            }
        }
        #expect(window.appearance?.name == .darkAqua)
        #expect(Palette.current == .night)
    }

    @Test func writingEmailsIsOnUntilTurnedOff() {
        let store = defaults()
        #expect(Preferences(defaults: store).writesEmails)
        Preferences(defaults: store).writesEmails = false
        #expect(!Preferences(defaults: store).writesEmails)
    }

    @Test func screenRecordingIsRequestedOnlyOnce() {
        let store = defaults()
        let first = Preferences(defaults: store)
        #expect(!first.screenRecordingRequested)
        first.screenRecordingRequested = true
        #expect(Preferences(defaults: store).screenRecordingRequested)
    }

    @Test func aYesFromOutsideApplicationsWaitsAcrossLaunches() {
        let store = defaults()
        let first = Preferences(defaults: store)
        #expect(!first.loginItemPending)
        first.loginItemPending = true
        #expect(Preferences(defaults: store).loginItemPending)
        // The flag the first alpha kept after registering itself grants nothing.
        let earlier = defaults()
        earlier.set(true, forKey: "loginItemRegistered")
        #expect(!Preferences(defaults: earlier).loginItemPending)
    }

    @Test func loginItemsAreOnlyForCopiesInApplications() {
        let home = URL(fileURLWithPath: "/tmp/demo-home")
        func stable(_ path: String) -> Bool {
            LoginItem.isStable(bundle: URL(fileURLWithPath: path), home: home)
        }
        #expect(stable("/Applications/Intention.app"))
        #expect(stable("/tmp/demo-home/Applications/Intention.app"))
        #expect(stable("/Applications/Tools/Intention.app"))
        #expect(!stable("/tmp/demo-home/Downloads/Intention.app"))
        #expect(!stable("/Volumes/Intention/Intention.app"))
        #expect(!stable("/private/var/folders/x/AppTranslocation/1/d/Intention.app"))
        #expect(!stable("/Applications Backup/Intention.app"))
        #expect(!stable("/tmp/other-home/Applications/Intention.app"))
    }
}
