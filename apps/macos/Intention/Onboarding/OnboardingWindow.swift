import AppKit
import SwiftUI

/// The setup window. It is opened at launch while setup is unfinished and
/// from the menu bar item afterwards. Intention has no Dock icon otherwise, so
/// it takes one while this window is open, where the person can find it
/// again after System Settings or the browser has covered it, and the
/// window comes back to the front by itself when a grant or a consent lands.
/// While a mail connection waits on the browser the window floats above
/// it, so the three clicks it lists stay in view beside the consent page.
/// When setup ends the window lifts its sun out, fades, and the sun flies
/// down into the foot mark (`SetupFlight`).
@MainActor
final class OnboardingWindow: NSObject, NSWindowDelegate {
    private let model: OnboardingModel
    private var window: NSWindow?
    private let guide = SettingsGuide(list: .accessibility)
    private var check: Timer?
    private let flight = SetupFlight()
    /// Where the sun lands as setup ends, from the app, which owns the foot
    /// mark: nil while the mark does not show, and then the window only
    /// fades.
    private let landing: @MainActor () -> SetupLanding?

    init(model: OnboardingModel, landing: @escaping @MainActor () -> SetupLanding? = { nil }) {
        self.model = model
        self.landing = landing
        super.init()
        model.returned = { [weak self] in self?.bringForward() }
    }

    /// Whether setup's window is the one taking the keyboard, which it can
    /// be only while it is open and Intention is the app in front.
    var isKey: Bool { window?.isKeyWindow == true }
    var isVisible: Bool { window?.isVisible == true && (window?.alphaValue ?? 0) > 0 }

    func show() {
        if window == nil {
            SetupStyle.registerFonts()
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: OnboardingView.size),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.identifier = NSUserInterfaceItemIdentifier("intention.onboarding")
            window.title = "Set Up Intention"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            // The end belongs to this window: a view left over from one that
            // closed must not end a window opened since, as mail reopened
            // from Settings is.
            let content = NSHostingView(rootView: OnboardingView(model: model) { [weak self, weak window] sun in
                guard let self, let window else { return }
                self.end(lifting: sun, from: window)
            })
            // The window keeps its size; the view fills it.
            content.sizingOptions = []
            window.contentView = content
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.appearance = NSAppearance(named: .aqua)
            window.delegate = self
            // The initialiser adds a title bar's height above the content
            // it is given; the content here runs under the title bar, so
            // the window is the page's size and no taller.
            window.setFrame(CGRect(origin: window.frame.origin, size: OnboardingView.size), display: false)
            window.center()
            self.window = window
            model.mailAnchor = window
        }
        model.windowShown()
        #if DEBUG
        if OnboardingFixture.isDemo {
            // Behind the desktop picture: drawn and animated like any
            // window, and recordable by its number, yet never seen.
            window?.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
            window?.ignoresMouseEvents = true
            // It never has the keyboard, so the practice fields are told
            // to draw the caret and dot they would have.
            FirstDictationField.still = true
            // On the sharpest display, so the recording has the most pixels.
            if let screen = NSScreen.screens.max(by: { $0.backingScaleFactor < $1.backingScaleFactor }) {
                window?.setFrameOrigin(CGPoint(x: screen.frame.midX - OnboardingView.size.width / 2,
                                               y: screen.frame.midY - OnboardingView.size.height / 2))
            }
            window?.orderFrontRegardless()
            return
        }
        #endif
        if let window { DockActivationController.shared.willOpen(window) }
        // It opens as macOS zooms a window in; the view scales its content
        // from 95.5% meanwhile.
        if let window, !window.isVisible {
            window.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.32
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.215, 0.61, 0.355, 1)
                window.animator().alphaValue = 1
            }
        }
        bringForward()
        window?.makeKeyAndOrderFront(nil)
        // While Accessibility has been asked for and is not in yet, the
        // guide waits at the System Settings window; while the browser has
        // the mail consent, the window floats above it.
        check = check ?? Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let model = self.model
                self.guide.update(isWanted: model.step == .permissions && model.asked.contains(.accessibility)
                    && !model.granted.contains(.accessibility))
                let level: NSWindow.Level = model.isAwaitingMail ? .floating : .normal
                if self.window?.level != level { self.window?.level = level }
            }
        }
    }

    private func bringForward() {
        guard let window else { return }
        // Ordering front puts the window on top even when macOS declines to
        // activate Intention over the app the person is in. Activation follows
        // a moment later, once the Dock icon set in `show` has taken effect.
        // A plain `activate()` is only a request, which macOS refused when
        // setup was opened from a shell, so this one insists: the person
        // either just opened Intention or just finished something setup sent
        // them to do.
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            // Closed in that moment: nothing is brought back.
            guard self?.window === window else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Setup is done and the light has gathered in the sun, at `sun` in the
    /// window: the sun lifts out and flies to the foot mark while the window
    /// fades over 0.32 s and closes. Under Reduce Motion, with no mark to
    /// land in, or with no sun to lift, the window only fades.
    private func end(lifting sun: CGRect?, from window: NSWindow) {
        guard self.window === window else { return }
        guard window.isVisible else { return window.close() }
        let frame = window.frame
        if let sun, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let landing = landing() {
            let onScreen = CGRect(x: frame.minX + sun.minX, y: frame.maxY - sun.maxY, width: sun.width, height: sun.height)
            flight.fly(SetupPainting.Art.sun, from: onScreen, to: landing)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0.085, 0.68, 0.53)
            window.animator().alphaValue = 0
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(330))
            guard self?.window === window else { return }
            window.close()
        }
    }

    func windowWillClose(_ notification: Notification) {
        model.windowClosed()
        window = nil
        check?.invalidate()
        check = nil
        guide.update(isWanted: false)
    }
}
