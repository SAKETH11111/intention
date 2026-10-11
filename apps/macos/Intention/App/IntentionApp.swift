#if !OFFSCREEN_RENDER
import AppKit
import SwiftUI

@main
struct IntentionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // Rendering lives in a separately linked, guarded executable. Refuse
        // old invocations before SwiftUI can request the app model or a scene.
        if RenderArguments.requiresRenderWorker(CommandLine.arguments,
                                                renderGuard: ProcessInfo.processInfo.environment["INTENTION_RENDER_GUARD"]) {
            fatalError("Use scripts/app-shots.sh for guarded off-screen renders")
        }
        MenuBarPosition.seedIfNeeded()
    }

    var body: some Scene {
        // Intention's window, Home with Settings over it, is AppKit's
        // (`MainWindow`), opened from the menu and the popups through
        // `AppModel.open`, so this is the only scene.
        MenuBarExtra {
            MenuContent(model: delegate.model)
        } label: {
            MenuBarLabel(model: delegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    lazy var model = AppModel()

    func applicationWillFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // Permission diagnostics must not start tracking or acquire the app's
        // single-instance lock. This also works beside an existing instance.
        DevelopmentCommands.checkCaretPermissions(arguments: CommandLine.arguments)
        DevelopmentCommands.checkTelemetry(arguments: CommandLine.arguments)
        DevelopmentCommands.checkDictationStream(arguments: CommandLine.arguments)
        CaretFixtureMode.armDeadline()
        #endif
        let identifier = Bundle.main.bundleIdentifier ?? "co.intention.mac"
        guard SingleInstance.acquire(bundleIdentifier: identifier) else {
            AppLog.event("Another instance is running; exiting")
            exit(0)
        }
        Telemetry.start()
    }

    // AppKit sends open-untitled on an initial Finder/Spotlight launch and
    // reopen to an existing process, including a click on its Dock icon.
    nonisolated func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        MainWindowReopening.request { [weak self] in
            let event = NSAppleEventManager.shared().currentAppleEvent
            let atLogin = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
            guard let self, MainWindowReopening.shouldOpenAtLaunch(
                atLogin: atLogin, opensSetup: self.model.opensSetupAtLaunch,
                isTestHost: NSClassFromString("XCTestCase") != nil, arguments: CommandLine.arguments) else { return }
            self.model.open(.history)
        }
        return true
    }

    nonisolated func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowReopening.request { [weak self] in
            guard MainWindowReopening.shouldHandleReopen(isTestHost: NSClassFromString("XCTestCase") != nil,
                                                        arguments: CommandLine.arguments) else { return }
            self?.model.open(.history)
        }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            let saved = await model.dictation.prepareToQuit()
            await Task.detached(priority: .utility) { DiagnosticEvents.shared.flush() }.value
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DockActivationController.shared.start()
        if model.opensSetupAtLaunch { model.showSetup() }
        #if DEBUG
        Task {
            await model.onboarding.signInFromFileIfRequested(arguments: CommandLine.arguments)
            if CommandLine.arguments.contains("--show-setup") || !model.onboarding.isFinished {
                model.showSetup()
            }
        }
        CaretFixtureMode.acknowledgeReady()
        InsertionChecks.runIfRequested(arguments: CommandLine.arguments, model: model)
        #endif
    }
}

/// The mark, with its dot in the recording red while dictation records, as
/// a fallback for fields where the caret dot cannot be shown, and in the
/// warm attention colour when a dictation was not inserted and the main
/// window has not been opened since.
private struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let dictation = model.dictation
        let dot: NSColor? = dictation.phase == .recording ? OwnHandMark.recording
            : dictation.history.needsAttention ? OwnHandMark.attention : nil
        Image(nsImage: OwnHandMark.menuBarImage(dot: dot))
    }
}

private struct MenuContent: View {
    let model: AppModel

    var body: some View {
        // Signing out returns setup to its first step, so for a signed-out
        // Mac this item is the way back to dictating, and says so. A key the
        // keychain would not give up reads as signed out too, but its way
        // back is the retry below, not a new sign-in.
        if !model.onboarding.isFinished {
            let signIn = model.dictation.problem == .signedOut && !model.onboarding.isKeyUnreadable
            Button(signIn ? "Sign in to dictate…" : "Finish setting up…") { model.showSetup() }
        }
        // The keychain would not give up the key: macOS asked and was told
        // no, usually after an update. Said in words, with the way back,
        // instead of dictation quietly having no account. A menu draws a
        // line it cannot press in grey, so what to read is in the item that
        // acts, here and below.
        if model.onboarding.isKeyUnreadable {
            Button("Dictation is off: try again, then click Always Allow") { model.retryKeyRead() }
        }
        // Offered beside setup too: the dot works without signing in, and
        // someone who closed setup still needs a way to allow it.
        if !model.permission.isGranted {
            Button("Allow Accessibility…") { model.permission.request() }
        }
        // Shown once a paste has replaced the person's clipboard, since
        // macOS asks before Intention reads it until the person allows it.
        let offersClipboard = model.dictation.pasteReplacedClipboard && !model.clipboard.mayReadOtherApps
        if offersClipboard {
            Button("Allow the clipboard…") { model.allowClipboard() }
        }
        if !model.onboarding.isFinished || !model.permission.isGranted || offersClipboard || model.onboarding.isKeyUnreadable {
            Divider()
        }
        // What Intention has read of the person's sent mail, or that it is
        // ready to write as them; it opens History, which shows the same,
        // with a bar when the total is known. A menu draws a line it cannot
        // press in grey, so it is a button.
        if let learning = model.learningProgress.label {
            Button([learning, model.learningProgress.detail].compactMap { $0 }.joined(separator: ". ")) { model.open(.history) }
            Divider()
        }
        DictationMenu(dictation: model.dictation, key: model.preferences.dictationKey, indicator: model.preferences.indicator,
                      openSettings: { model.open(.settings) }) {
            model.open(.history)
        }
        WritingMenu(writer: model.writer) { model.mainWindow.show(settings: .email) }
        Divider()
        #if DEBUG
        Button("Insert sample text") { model.insertSampleText() }
        if let outcome = model.lastEditOutcome {
            Text(outcome)
        }
        Divider()
        #endif
        if model.updater.isActive {
            Button("Check for updates…") { model.updater.checkForUpdates() }
        }
        // The report is made before its window opens, so it names the app
        // the person was using rather than Intention.
        Button("Reporting unavailable in demo") {}.disabled(true)
        Button("Settings…") { model.open(.settings) }
        // Hidden from its own menu: the way back before the hour is up.
        if model.footHiddenUntil != nil {
            Button("Show the dot again") { model.showFootAgain() }
        }
        Divider()
        Button("Quit Intention") { NSApp.terminate(nil) }
    }
}

/// Why words dictated into an email are typed rather than written, when
/// the server has said writing is off. Dictation's own lines cover a build
/// without a server and a signed-out Mac.
private struct WritingMenu: View {
    let writer: EmailWriter
    /// Settings' Email section, where the switch says the same.
    let openEmailSettings: () -> Void

    var body: some View {
        if writer.isEnabled, case .unavailable? = writer.availability {
            Button("Writing emails is off on Intention's server…", action: openEmailSettings)
        }
    }
}

private struct DictationMenu: View {
    let dictation: DictationController
    let key: HoldKey.Key
    let indicator: IndicatorStyle
    /// Settings' first section, which holds the Microphone menu.
    let openSettings: () -> Void
    let openHistory: () -> Void

    var body: some View {
        switch dictation.phase {
        case .recording:
            Button("Stop dictation") { dictation.toggle() }
            Button("Cancel dictation") { dictation.cancel() }
        // What is under way is said in the item that stops it.
        case .processing:
            Button("Cancel dictation while it finishes") { dictation.cancel() }
        case .writingEmail:
            Button("Cancel dictation while the email is written") { dictation.cancel() }
        case .idle where dictation.problem == nil:
            // Ready: an ordinary item that starts a dictation, as a click on
            // the dot does, and names the key for next time.
            Button("Start dictation, or hold \(key.title)") { dictation.toggle() }
        case .idle:
            Text("Dictate: click the dot or hold \(key.title)")
        }
        switch dictation.problem {
        case .notConfigured?:
            // Only a development build has no server, and there is nothing
            // to do from here.
            Text("Dictation is off: this build has no dictation server")
        case .signedOut?:
            // Said by "Sign in to dictate…" above.
            EmptyView()
        case .microphoneDenied?:
            Button("Allow the microphone…") { SettingsSheet.openMicrophonePrivacy() }
        case .microphoneUnavailable?:
            Button("No microphone could be opened: choose one…", action: openSettings)
        case nil:
            EmptyView()
        }
        Button(dictation.history.needsAttention ? "Dictation history (not inserted)…" : "Dictation history…", action: openHistory)
    }
}

#endif
