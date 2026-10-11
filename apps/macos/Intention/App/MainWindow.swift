import AppKit
import SwiftUI

/// Intention's one window: Home, with Settings as a sheet over it. The menu
/// bar item opens it (`AppModel.open`), as do the not-inserted popup's
/// Retry and Switch mic. It is built once and kept, closed or open, so it
/// comes back as it was left. Opening it clears the menu bar item's
/// "not inserted" mark, as opening the old history window did.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
    let state = MainWindowState()
    /// The app model owns this window and lives as long as the app.
    private unowned let model: AppModel
    private var window: NSWindow?
    private let presentation = MainWindowPresentation()
    nonisolated(unsafe) private var appearanceObserver: NSObjectProtocol?

    deinit {
        if let appearanceObserver { NotificationCenter.default.removeObserver(appearanceObserver) }
    }

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    /// Brings the window forward on Home, or with Settings over it on
    /// `settings`'s section. Asking for Home closes the sheet.
    func show(settings section: SettingsSection? = nil) {
        let window = prepare()
        state.settings = section
        model.dictation.history.needsAttention = false
        presentation.show(window)
    }

    /// The window, built the first time it is asked for, and not shown.
    /// A fixture takes it from here to draw it where no one sees it.
    func prepare() -> NSWindow {
        if let window { return window }
        SetupStyle.registerFonts()
        let window = KeyWindow(contentRect: CGRect(origin: .zero, size: HomeStyle.windowSize),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                               backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("intention.main")
        window.title = "Intention"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // An empty toolbar gives the title bar its taller, unified height,
        // so the window's buttons line up with the wordmark and Settings.
        window.toolbar = NSToolbar(identifier: "intention.main")
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentMinSize = HomeStyle.minimumSize
        window.appearance = Appearance.current.nsAppearance
        appearanceObserver = NotificationCenter.default.addObserver(forName: .intentionAppearanceChanged, object: nil, queue: .main) { @Sendable [weak window] _ in
            guard let window else { return }
            Self.updateAppearance(of: window)
        }
        let content = NSHostingView(rootView: MainWindowView(model: model, state: state))
        content.sizingOptions = []
        window.contentView = content
        window.delegate = self
        window.setFrame(CGRect(origin: window.frame.origin, size: HomeStyle.windowSize), display: false)
        window.center()
        window.setFrameAutosaveName("Intention main window")
        self.window = window
        return window
    }

    /// Framework callbacks may arrive off the main actor, even when an
    /// observer requests the main queue.
    nonisolated static func updateAppearance(of window: NSWindow) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak window] in
                if let window { updateAppearance(of: window) }
            }
            return
        }
        MainActor.assumeIsolated { window.appearance = Appearance.current.nsAppearance }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.dictation.history.needsAttention = false
    }

    func windowWillClose(_ notification: Notification) {
        presentation.cancel()
        state.windowWillClose(notification)
    }
}

/// Home, and Settings over it with the window blurred and dimmed behind.
/// What the rows and the sheet ask for goes to the app model.
struct MainWindowView: View {
    let model: AppModel
    @Bindable var state: MainWindowState
    /// The history Home shows: the app's own, or a render's made-up one.
    var history: DictationHistory?
    @State private var problem: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let settingsShown = state.settings != nil
        ZStack(alignment: .top) {
            HomeView(history: history ?? model.dictation.history, state: state,
                     keyName: FirstDictation.keycap(model.preferences.dictationKey),
                     retryEnabled: model.dictation.phase == .idle,
                     act: act, openSettings: { state.settings = .general },
                     learningLabel: model.learningProgress.label, learningFraction: model.learningProgress.fraction, learningDetail: model.learningProgress.detail)
                .compositingGroup()
                .blur(radius: settingsShown ? 3 : 0, opaque: true)
                .disabled(settingsShown)
                .accessibilityHidden(settingsShown)
            if let section = state.settings {
                (model.preferences.appearance == .dark ? Color(hex: 0x020814).opacity(0.4) : SetupStyle.ink.opacity(0.14))
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                    .transition(.opacity)
                SettingsSheet(model: model, section: Binding(get: { section }, set: { state.settings = $0 }),
                              done: { state.settings = nil })
                    .padding(.top, 116)
                    .padding(.bottom, 24)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .animation(reduceMotion ? nil : SetupStyle.turn, value: settingsShown)
        // Settings closing, or the window with it, stops the microphone
        // streams at once, not when the list's task ends after the sheet's
        // animation.
        .onChange(of: settingsShown) { _, shown in
            if !shown { model.microphoneMenu.stopMetering() }
        }
        .ignoresSafeArea()
        .appearance(model.preferences.appearance)
        .alert(problem ?? "", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        }
    }

    private func act(_ row: HistoryRow, _ action: RowPresentation.Action) {
        switch action {
        case .copy:
            if !model.copy(row) { problem = "The text could not be copied." }
        case .retry:
            model.retry(row)
        case .switchMicrophone:
            model.switchMicrophone()
        }
    }
}
