import AppKit
import SwiftUI

/// Keeps the person company in System Settings while they switch on one of
/// Intention's permissions. macOS gives an app no way to make the grant itself,
/// so the next best thing is to show which line to turn on.
///
/// How exact that can be depends on what Intention holds. Where to point needs
/// System Settings' contents, which only Accessibility (its element tree)
/// or Screen Recording (its pixels) can see. The window's frame alone comes
/// from the window server's list without any permission.
///
/// - At the first Accessibility request, nothing in the window can be
///   located. While setup wants it, the guide sits under the list with
///   Intention's icon and name, the two things that tell its line apart, and
///   an arrow up into the list. It never points at a switch it has not read.
/// - For Screen Recording, Intention usually holds Accessibility, and the guide
///   runs for one visit: one Intention opens with `open(_:)`, or the one
///   macOS's alert opens after `guideNextVisit()`. Only while the
///   window's title is one macOS gives that page does `SettingsListReader`
///   look for Intention's switch, which the guide then points at with an
///   arrow from a note beside the window, once two reads in a row agree.
///   The arrow follows the window as it moves, and goes the moment the person
///   scrolls, presses the mouse or presses a key, until two new reads
///   agree. When two reads found Intention's line
///   switched off but the arrow cannot be drawn to it, it shows the note
///   instead. On a page it cannot name, after a single read or one cut
///   short, or when the switch is already on or its state is unknown, it
///   shows nothing.
///
/// The guide shows only while System Settings is the app in front, and
/// never takes clicks: the switch it points at is still the person's to
/// press.
@MainActor
final class SettingsGuide {
    private static let settingsApp = "com.apple.systempreferences"

    private let list: GuidedList
    private lazy var reader = SettingsListReader()
    private var screenRecordingTitles: Set<String> = []
    private var panel: NSPanel?
    private var host: NSHostingView<SettingsGuideView>?
    private var shown: SettingsGuideView.Content?
    private var shownLook: Appearance?
    private var timer: Timer?
    private var activation: NSObjectProtocol?
    /// Hears a scroll, a press of the mouse or a key in System Settings
    /// while a Screen Recording visit runs. Which key or where is not read.
    private var disturbance: Any?
    private var wanted = false
    /// Counts the guide's starts and stops in front of System Settings. A
    /// read carries the count from when it began, and one from an earlier
    /// run is dropped.
    private var visit = 0
    /// For Screen Recording: whether System Settings has come forward, and
    /// shown a window, since the visit began. Leaving it, or that window
    /// closing, after that ends the visit.
    private var arrived = false
    private var sawWindow = false
    /// Ends a Screen Recording visit that System Settings never came
    /// forward for.
    private var noShow: Timer?
    private static let arrivalWait: TimeInterval = 60
    /// The latest reading of Intention's line. Nil off the Screen Recording
    /// page or without Accessibility.
    private var observation: SettingsGuideLayout.Observation?

    /// Light or Dark, read each time the guide is drawn.
    private let appearance: @MainActor () -> Appearance

    init(list: GuidedList, appearance: @escaping @MainActor () -> Appearance = { .light }) {
        self.list = list
        self.appearance = appearance
    }

    /// Shows the Accessibility guide while `isWanted` holds, and takes it
    /// away when not.
    func update(isWanted: Bool) {
        guard isWanted != wanted else { return }
        wanted = isWanted
        if isWanted {
            // Follows the window only while System Settings is in front;
            // otherwise nothing runs but this observer.
            activation = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.follow() }
            }
            follow()
        } else {
            if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
            activation = nil
            noShow?.invalidate()
            noShow = nil
            stop()
        }
    }

    /// Opens `url`, a System Settings page, and guides that one visit.
    /// Without Accessibility nothing could be pointed at, so the page is
    /// only opened.
    func open(_ url: URL) {
        guideNextVisit()
        NSWorkspace.shared.open(url)
    }

    /// Guides the next visit to System Settings without opening it, for
    /// when macOS's permission alert is in front and its button opens the
    /// page. Nothing runs until System Settings comes forward. When it
    /// never does, because the person pressed Deny or left the alert
    /// alone, the visit ends after `arrivalWait`, so the guide does not
    /// wake at a later trip to System Settings made for something else.
    func guideNextVisit() {
        update(isWanted: false)
        guard AXIsProcessTrusted() else { return }
        arrived = false
        sawWindow = false
        update(isWanted: true)
        noShow = Timer.scheduledTimer(withTimeInterval: Self.arrivalWait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.arrived else { return }
                self.update(isWanted: false)
            }
        }
    }

    private var settingsIsFront: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.settingsApp
    }

    private func follow() {
        guard wanted else { return stop() }
        if settingsIsFront {
            arrived = true
            guard timer == nil else { return }
            visit += 1
            if list == .screenRecording { screenRecordingTitles = SettingsPageTitles.load() }
            timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            if list == .screenRecording {
                // Any of these can move the list under the arrow before the
                // next read shows it has moved.
                disturbance = NSEvent.addGlobalMonitorForEvents(
                    matching: [.scrollWheel, .leftMouseDown, .leftMouseDragged, .keyDown]
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.disturbed() }
                }
            }
            tick()
        } else {
            stop()
            if list == .screenRecording, arrived { update(isWanted: false) }
        }
    }

    private func stop() {
        if timer != nil { visit += 1 }
        timer?.invalidate()
        timer = nil
        if let disturbance { NSEvent.removeMonitor(disturbance) }
        disturbance = nil
        observation = nil
        hide()
    }

    /// The person scrolled, pressed the mouse or pressed a key, so the list
    /// may no longer be where it was read. The mark goes at once, a read
    /// already running is dropped as one from an earlier run is, and
    /// nothing is drawn again until two new reads agree.
    private func disturbed() {
        guard timer != nil else { return }
        visit += 1
        observation = nil
        hide()
    }

    private func tick() {
        guard settingsIsFront, let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.settingsApp).first else {
            return hide()
        }
        guard let window = Self.settingsWindow(pid: app.processIdentifier) else {
            // The window the visit reached has closed.
            if list == .screenRecording, sawWindow { return update(isWanted: false) }
            return hide()
        }
        sawWindow = true
        // A copy that cannot tell its line from another copy's reads
        // nothing, and so shows nothing.
        if list == .screenRecording, let names = Self.names {
            let visit = visit
            let pid = app.processIdentifier
            let began = ContinuousClock.now
            reader.read(pid: pid, pages: screenRecordingTitles, names: names) { [weak self] reading in
                guard let self, SettingsGuideLayout.accepts(visit: visit, currentVisit: self.visit, windowBefore: window,
                                                            windowAfter: Self.settingsWindow(pid: pid)) else { return }
                // Switched on: the visit has done its job.
                if reading == .alreadyOn { return self.update(isWanted: false) }
                self.observation = SettingsGuideLayout.observe(reading, window: window, at: began, after: self.observation)
                self.place(window: window)
            }
        }
        place(window: window)
    }

    /// `window` in window server coordinates.
    private func place(window: CGRect) {
        guard let mainHeight = NSScreen.screens.first?.frame.height else { return hide() }
        let frame = SettingsList.appKitFrame(window, mainDisplayHeight: mainHeight)
        let screen = NSScreen.screens.max {
            $0.frame.intersection(frame).width * $0.frame.intersection(frame).height
                < $1.frame.intersection(frame).width * $1.frame.intersection(frame).height
        }?.visibleFrame ?? frame
        switch SettingsGuideLayout.mark(for: list, observation: observation, window: window, now: .now, mainDisplayHeight: mainHeight) {
        case .none:
            hide()
        case .list:
            show(.list, at: SettingsGuideLayout.listPanel(window: frame, screen: screen))
        case let .row(toggle):
            let row = SettingsGuideLayout.row(toggle: toggle, window: frame, screen: screen)
            show(.row(row), at: row.panel)
        }
    }

    private func show(_ content: SettingsGuideView.Content, at frame: CGRect) {
        let panel = panel ?? makePanel()
        self.panel = panel
        // Redraws only when the drawing changes; following a moving window
        // only moves the panel.
        let look = appearance()
        if content != shown || look != shownLook {
            host?.rootView = SettingsGuideView(content: content, look: look)
            panel.appearance = look.nsAppearance
            shown = content
            shownLook = look
        }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        guard !panel.isVisible else { return }
        // A short fade in, once, so the guide arrives rather than blinks.
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = still ? 1 : 0
        panel.orderFrontRegardless()
        if !still {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                panel.animator().alphaValue = 1
            }
        }
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The view draws its own shadow, under the note only.
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let content = NSHostingView(rootView: SettingsGuideView(content: .list))
        content.sizingOptions = []
        panel.contentView = content
        host = content
        return panel
    }

    /// The names System Settings may list this copy under, or nil when it
    /// cannot tell its line from another copy's; see
    /// `SettingsGuideLayout.ownNames`.
    private static let names: [String]? = {
        let info = Bundle.main.infoDictionary
        return SettingsGuideLayout.ownNames(bundleIdentifier: Bundle.main.bundleIdentifier,
                                            candidates: [Bundle.main.bundleURL.deletingPathExtension().lastPathComponent,
                                                         info?["CFBundleDisplayName"] as? String, info?["CFBundleName"] as? String])
    }()

    /// The System Settings window's frame in window server coordinates,
    /// measured from the top left of the main display.
    static func settingsWindow(pid: pid_t) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] else {
            return nil
        }
        let frames = windows.compactMap { window -> CGRect? in
            guard window[kCGWindowOwnerPID] as? pid_t == pid, window[kCGWindowLayer] as? Int == 0,
                  let bounds = window[kCGWindowBounds] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width >= 320, frame.height >= 240 else { return nil }
            return frame
        }
        return frames.max { $0.width * $0.height < $1.width * $1.height }
    }
}

/// What a `SettingsGuide` panel draws, in Intention's paper and ink, Light or
/// Dark as Settings has it; setup's guide is always Light. Off screen it
/// draws the same, for `./dev mac-onboarding-shots`.
struct SettingsGuideView: View {
    enum Content: Equatable {
        case list
        case row(SettingsGuideLayout.Row)
    }

    let content: Content
    var look: Appearance = .light

    var body: some View {
        Group {
            switch content {
            case .list: ListNote()
            case let .row(row): RowMark(row: row)
            }
        }
        .appearance(look)
    }

    /// Intention's line as it looks in the list, with its icon, name and a
    /// switch that is off, and an arrow up into the list from that switch.
    private struct ListNote: View {
        @Environment(\.palette) private var palette

        var body: some View {
            let size = SettingsGuideLayout.listSize
            let arrowX = size.width - SettingsGuideLayout.listArrowInset
            ZStack(alignment: .bottom) {
                GuideArrow(from: CGPoint(x: arrowX, y: 32), to: CGPoint(x: arrowX, y: 4))
                HStack(spacing: 12) {
                    Image(nsImage: SetupStyle.image("AppIcon", "icns"))
                        .resizable()
                        .frame(width: 36, height: 36)
                        .accessibilityHidden(true)
                    Note(title: "Turn on Intention", detail: "Find this icon in the list above")
                    Spacer(minLength: 0)
                    OffSwitch()
                }
                .padding(.leading, 14)
                .padding(.trailing, SettingsGuideLayout.listArrowInset - 16 - 12)
                .frame(height: 64)
                .paper(radius: 10, floats: true)
                .padding(.horizontal, 12)
                .padding(.bottom, 8 + SettingsGuideLayout.shadowRoom)
            }
            .frame(width: size.width, height: size.height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Turn on Intention in the list above")
        }
    }

    /// A note beside Intention's own switch, with an arrow to it.
    private struct RowMark: View {
        let row: SettingsGuideLayout.Row
        @Environment(\.palette) private var palette

        var body: some View {
            ZStack(alignment: .topLeading) {
                GuideArrow(from: row.arrowFrom, to: row.arrowTo)
                HStack(spacing: 11) {
                    Image(nsImage: SetupStyle.image("AppIcon", "icns"))
                        .resizable()
                        .frame(width: 30, height: 30)
                        .accessibilityHidden(true)
                    Note(title: "Turn this one on", detail: "Intention\u{2019}s switch")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 13)
                .frame(width: row.callout.width, height: row.callout.height)
                .paper(radius: 10, floats: true)
                .offset(x: row.callout.minX, y: row.callout.minY)
            }
            .frame(width: row.panel.width, height: row.panel.height, alignment: .topLeading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Turn on Intention\u{2019}s switch")
        }
    }

    /// The note's two lines: what to do, and where.
    private struct Note: View {
        let title: String
        let detail: String
        @Environment(\.palette) private var palette

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SetupStyle.text(14, .semibold))
                    .foregroundStyle(palette.ink)
                Text(detail)
                    .font(SetupStyle.text(13))
                    .foregroundStyle(palette.lead)
            }
        }
    }

    /// System Settings' own switch, drawn off as macOS draws it, a grey
    /// capsule with a white knob, at setup's hint's size: the control the
    /// person must find in the list, so it pictures that control rather
    /// than Intention's own switch.
    private struct OffSwitch: View {
        @Environment(\.palette) private var palette

        var body: some View {
            Capsule()
                .fill(palette.isNight ? Color.white.opacity(0.18) : Color.black.opacity(0.1))
                .frame(width: 32, height: 19)
                .overlay(alignment: .leading) {
                    Circle()
                        .fill(palette.isNight ? Color(white: 0.85) : .white)
                        .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
                        .frame(width: 15, height: 15)
                        .padding(2)
                }
                .fixedSize()
                .accessibilityHidden(true)
        }
    }
}

/// An ink arrow drawn by the hand's pen, round caps, on a paper halo so it
/// reads over light and dark pages, in the day's ink, since it lies on
/// System Settings, not on Intention's paper: the
/// hand's pen, 1.8 points, drawn on once in 180 ms as the guide arrives.
private struct GuideArrow: View {
    let from: CGPoint
    let to: CGPoint
    private let palette = Palette.day
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn: CGFloat = 0

    var body: some View {
        ZStack {
            Pen(from: from, to: to).trim(from: 0, to: drawn)
                .stroke(palette.overPaper, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            Pen(from: from, to: to).trim(from: 0, to: drawn)
                .stroke(palette.ink, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
        .onAppear {
            guard !SetupMotion.isStill, !reduceMotion else { return drawn = 1 }
            withAnimation(SetupMotion.quadOut(SetupMotion.draw).delay(0.12)) { drawn = 1 }
        }
    }

    /// The shaft with a slight bow, as a pen draws a straight line, then
    /// the two strokes of the head.
    private struct Pen: Shape {
        let from: CGPoint
        let to: CGPoint

        func path(in rect: CGRect) -> Path {
            let angle = atan2(to.y - from.y, to.x - from.x)
            let length = hypot(to.x - from.x, to.y - from.y)
            let bow = min(2, length * 0.05)
            let middle = CGPoint(x: (from.x + to.x) / 2 - sin(angle) * bow, y: (from.y + to.y) / 2 + cos(angle) * bow)
            var path = Path()
            path.move(to: from)
            path.addQuadCurve(to: to, control: middle)
            for (side, reach) in [(-1.0, 9.0), (1.0, 10.0)] {
                path.move(to: to)
                path.addLine(to: CGPoint(x: to.x - reach * cos(angle + side * .pi / 5.2), y: to.y - reach * sin(angle + side * .pi / 5.2)))
            }
            return path
        }
    }
}
