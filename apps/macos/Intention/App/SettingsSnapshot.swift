#if OFFSCREEN_RENDER
import AppKit
import SwiftUI

/// `--settings-snapshot <file.png> [--settings-section <name>]
/// [--settings-height <points>]` draws the Settings sheet on one section,
/// General unless another is named (email, system, account or data), to a
/// PNG off screen and quits. It is drawn at the sheet's width, 780 points,
/// and its own height or the one given, so two revisions compare at one
/// size. Run with `--onboarding-fixture` so
/// the model touches no keychain or network. Settings read this Mac's
/// grants, and the preferences passed as `-dictationKey <name>`,
/// `-indicator dot|pill` (`pill` hides the caret dot), `-appearance light|dark`
/// and `-microphone builtIn|systemDefault` stay in
/// this process. The Microphone row lists `inputs`, made up, in place of
/// this Mac's. `--settings-window <width>x<height>` draws it over Home in
/// the main window at that size instead, with made-up history behind it.
/// `--still-state hover|pressed|focused` draws every control in it in
/// that state, as the pointer or the keyboard would leave it.
/// `--settings-foot-hidden` draws it with the foot dot hidden from its menu
/// for the next hour. `--settings-recording listening|held|refused` draws the
/// dictation key's field recording: before any key, with Control and Option
/// held, or after a letter was pressed. It is drawn from made-up input and
/// takes none of the trigger's events.
///
/// It draws once the app has finished launching. Drawn any earlier, in
/// `applicationWillFinishLaunching` as the other development renders are,
/// a segmented control under SwiftUI's app lifecycle shows no selected
/// segment at all (seen on macOS 27.2 with a throwaway app that drew the
/// same form at both moments). The switches draw with their knobs off
/// whatever their state at either moment, shown or not.
@MainActor
enum SettingsSnapshot {
    /// Whether this launch is a render, so the model starts no indicator,
    /// takes no single-instance lock, starts no tracking, and nothing
    /// appears on screen.
    static var isRequested: Bool {
        ["--settings-snapshot", "--home-snapshot", "--controls-snapshot", "--foot-menu-snapshot", "--foot-menu-mock"].contains(where: CommandLine.arguments.contains)
    }

    /// Put fixture preferences in the argument domain before Preferences
    /// reads them. Rendering never saves these choices for a later launch.
    static func configurePreferencesIfRequested() {
        guard isRequested, OnboardingFixture.isRequested else { return }
        let arguments = CommandLine.arguments
        var domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        if let languages = value(after: "--settings-languages", in: arguments) {
            domain["dictationLanguages"] = languages.split(separator: ",").map(String.init)
        }
        if value(after: "--settings-microphone", in: arguments) == "disconnected" {
            domain["microphone"] = "device"
            domain["microphoneDevice"] = "synthetic-disconnected-podcast-microphone"
            domain["microphoneName"] = "Alex's very long USB podcasting microphone"
        }
        // The foot dot hidden from its menu for the next hour, so System's
        // Dot position line says until when and offers Show it now.
        if arguments.contains("--settings-foot-hidden") {
            domain["footHiddenUntil"] = Date().addingTimeInterval(3600)
        }
        UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    }

    static func renderIfRequested(arguments: [String], model: AppModel) {
        OffscreenRenderGuard.requireInstalled()
        guard let path = value(after: "--settings-snapshot", in: arguments) else { return }
        let height = value(after: "--settings-height", in: arguments).flatMap(Double.init).map { CGFloat($0) }
        if let state = value(after: "--settings-recording", in: arguments) {
            let held: [HoldKey.Recorded] = [.modifiers(keyCode: HoldKey.Modifier.leftControl.keyCode, flags: [.control, NSEvent.ModifierFlags(rawValue: 0x1)]),
                                            .modifiers(keyCode: HoldKey.Modifier.leftOption.keyCode, flags: [.control, .option, NSEvent.ModifierFlags(rawValue: 0x21)])]
            model.keyRecorder.preview(state == "held" ? held : state == "refused" ? [.key(keyCode: 0)] : [])
        }
        var failed: Bool?
        Task {
            do {
                try await render(model, to: URL(fileURLWithPath: path), height: height)
                failed = false
            } catch {
                failed = true
            }
        }
        while failed == nil { RunLoop.current.run(mode: .default, before: .now + 0.02) }
        exit(failed == true ? 1 : 0)
    }

    private static func render(_ model: AppModel, to file: URL, height: CGFloat?) async throws {
        // Pinned to the top, so a shorter revision drawn at a taller height
        // lines up with the other row for row.
        // Every mark lands in its end state: a still has no time to draw on.
        SetupMotion.isStill = true
        let section = value(after: "--settings-section", in: CommandLine.arguments).flatMap(SettingsSection.init(rawValue:)) ?? .general
        let host: NSHostingView<AnyView>
        let size: CGSize
        if let window = value(after: "--settings-window", in: CommandLine.arguments)?.split(separator: "x").compactMap({ Double($0) }),
           window.count == 2 {
            // Over Home in the main window at that size, as a person sees
            // it, with made-up history behind it.
            let state = MainWindowState()
            state.settings = section
            host = NSHostingView(rootView: AnyView(MainWindowView(model: model, state: state, history: HomeSnapshot.sample())
                .environment(\.stillControlState, StillControlState.requested)))
            size = CGSize(width: window[0], height: window[1])
        } else {
            host = NSHostingView(rootView: AnyView(SettingsSheet(model: model, section: .constant(section), done: {})
                .frame(maxHeight: .infinity, alignment: .top)
                .appearance(model.preferences.appearance)
                .environment(\.stillControlState, StillControlState.requested)))
            size = CGSize(width: SettingsSheet.width, height: height ?? host.fittingSize.height.rounded(.up))
        }
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = model.preferences.appearance.nsAppearance
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Let SwiftUI settle its first layout before drawing.
        try await Task.sleep(for: .milliseconds(400))
        if OnboardingFixture.settingsMail == "stale" {
            // The read Settings would make five seconds later, which fails.
            await model.onboarding.refreshMail()
            try await Task.sleep(for: .milliseconds(200))
        }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: file)
    }

    /// A MacBook's own microphone and AirPods, which macOS made the default
    /// input when they connected.
    static let inputs = AudioInputs(
        devices: [AudioInput(id: 1, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", isBuiltIn: true),
                  AudioInput(id: 2, uid: "00-00-00-00-00-00:input", name: "AirPods Pro", isBuiltIn: false),
                  AudioInput(id: 3, uid: "AppleUSBAudioEngine:Studio:1", name: "Studio USB Microphone", isBuiltIn: false)],
        systemDefault: 2, lidClosed: false)

    /// Levels for the made-up inputs, so the open Microphone list draws two
    /// live dots at different strengths. The AirPods are Bluetooth and never
    /// opened; nothing real is.
    struct Meter: MicrophoneMeterEngine {
        func isBluetooth(_ device: AudioInput) -> Bool { device.uid.hasSuffix(":input") }
        func isMeterable(_ device: AudioInput) -> Bool { !isBluetooth(device) }
        func open(_ device: AudioInput) -> (any MicrophoneMeterInput)? {
            Input(level: device.isBuiltIn ? 0.09 : 0.012)
        }
    }

    @MainActor
    private final class Input: MicrophoneMeterInput {
        let level: Double
        init(level: Double) { self.level = level }
        func rms() -> Double? { level }
        func stop() {}
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
#endif
