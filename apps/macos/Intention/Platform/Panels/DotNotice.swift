import AppKit
import SwiftUI

/// Words for the dot, which has none of its own, after a dictation that went
/// nowhere: a paper label with the notice, just
/// right of the dot, or above the foot mark on the screen under the pointer
/// when the dot is not shown. It never takes focus or a click, draws
/// nothing that moves, and goes away after `FootMark.noticeShown` or when
/// the next dictation starts. A
/// hint, such as a reply proposal's "Nothing to reply to", shows for
/// `hintShown` and then fades out once over `fadeOut`, or simply goes under
/// reduced motion. A locked screen or sleeping display ends it, and a
/// notice that arrives meanwhile is not shown.
@MainActor
final class DotNotice {
    /// Space between the dot's click target and the capsule.
    static let gap: CGFloat = 4
    /// How long a hint stays before it fades.
    static let hintShown: Duration = .milliseconds(2500)
    /// How long a hint takes to fade out.
    static let fadeOut: TimeInterval = 0.3

    /// Runs when a notice that was shown goes away.
    var ended: () -> Void = {}
    /// Light or Dark, as chosen in Settings, read when a notice shows.
    var appearance: () -> Appearance = { Appearance.current }
    nonisolated(unsafe) private var appearanceObserver: NSObjectProtocol?
    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private var hides: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var locked = false
    private var screensAsleep = false

    init(showsWindow: Bool = true) {
        self.showsWindow = showsWindow
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // The caret dot's level.
        panel.level = .statusBar
        #if DEBUG
        panel.title = "dot notice surface"
        #endif
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [
            distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.locked = true
                    self?.hide()
                }
            },
            distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.locked = false }
            },
            workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.screensAsleep = true
                    self?.hide()
                }
            },
            workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensAsleep = false }
            },
        ]
        appearanceObserver = NotificationCenter.default.addObserver(forName: .intentionAppearanceChanged, object: nil, queue: .main) { @Sendable [weak self] _ in
            self?.appearanceChanged()
        }
    }

    deinit {
        if let appearanceObserver { NotificationCenter.default.removeObserver(appearanceObserver) }
    }

    /// A framework callback may arrive off the main actor, including in tests.
    nonisolated func appearanceChanged() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.redrawAppearance() }
            return
        }
        MainActor.assumeIsolated { redrawAppearance() }
    }

    private func redrawAppearance() {
        guard isShown else { return }
        panel.appearance = appearance().nsAppearance
        redraw?()
    }

    var window: NSPanel { panel }
    var showsWindow = true
    private(set) var current: String?
    private var redraw: (() -> Void)?

    /// Whether a notice is on screen.
    var isShown: Bool { current != nil }

    /// Shows `notice` beside `mark`, the dot's click target in screen
    /// coordinates, or at the foot of the screen when it is nil, for
    /// `duration`; nil stays until hidden explicitly. With `fades`, a timed
    /// notice then fades out instead of going at once.
    func show(_ notice: FootState, beside mark: CGRect?, for duration: Duration? = FootMark.noticeShown, fades: Bool = false) {
        guard !locked, !screensAsleep else { return }
        hides?.cancel()
        // Stops a fade still running for the notice before.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        guard case let .notice(words) = notice else { return }
        current = words
        panel.appearance = appearance().nsAppearance
        let host = NSHostingView(rootView: NoticeCapsule(words: words, appearance: appearance()).padding(NoticeCapsule.shadowRoom))
        redraw = { [weak self, weak host] in
            guard let self else { return }
            host?.rootView = NoticeCapsule(words: words, appearance: self.appearance()).padding(NoticeCapsule.shadowRoom)
        }
        let size = host.fittingSize
        host.frame = CGRect(origin: .zero, size: size)
        panel.contentView = host
        // Placed as before the float needed more room, by a box with
        // `placedRoom` around the label that then grows by the extra room.
        let extra = NoticeCapsule.shadowRoom - NoticeCapsule.placedRoom
        let placed = Self.origin(of: CGSize(width: size.width - 2 * extra, height: size.height - 2 * extra), beside: mark,
                                 screens: NSScreen.screens.map(FootMark.Screen.init), pointer: NSEvent.mouseLocation,
                                 fallback: NSScreen.main.map(FootMark.Screen.init))
        panel.setFrame(CGRect(origin: CGPoint(x: placed.x - extra, y: placed.y - extra), size: size), display: true)
        if showsWindow { panel.orderFrontRegardless() }
        guard let duration else { hides = nil; return }
        hides = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            if fades, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                // Returns once the fade ends, or once a new notice stops it.
                await NSAnimationContext.runAnimationGroup { context in
                    context.duration = Self.fadeOut
                    self.panel.animator().alphaValue = 0
                }
                guard !Task.isCancelled else { return }
            }
            self.hide()
        }
    }

    func hide() {
        hides?.cancel()
        hides = nil
        guard isShown else { return }
        current = nil
        redraw = nil
        panel.contentView = nil
        panel.orderOut(nil)
        panel.alphaValue = 1
        ended()
    }

    /// Right of the dot, centred on it, or left of it where the right would
    /// leave its screen, and kept within the screen's height; without a dot,
    /// centred where the foot mark's words go on the screen the pointer is
    /// on, clear of its dot.
    static func origin(of size: CGSize, beside mark: CGRect?, screens: [FootMark.Screen], pointer: CGPoint, fallback: FootMark.Screen? = nil) -> CGPoint {
        if let mark, let usable = screens.first(where: { $0.frame.intersects(mark) })?.usable {
            let y = min(max(mark.midY - size.height / 2, usable.minY), usable.maxY - size.height)
            let right = mark.maxX + gap - NoticeCapsule.placedRoom
            if right + size.width <= usable.maxX { return CGPoint(x: right, y: y) }
            return CGPoint(x: mark.minX - gap + NoticeCapsule.placedRoom - size.width, y: y)
        }
        guard let foot = screens.first(where: { $0.frame.contains(pointer) }) ?? fallback ?? screens.first else { return .zero }
        return CGPoint(x: (foot.usable.midX - size.width / 2).rounded(), y: FootMark.wordsBottom(on: foot) - NoticeCapsule.placedRoom)
    }
}

/// A notice on the over-app paper: the words alone in DM Sans 13/600 ink,
/// one line, on a label with the half-point edge and the one float on a
/// label's corners, beside the caret dot or above the foot dot. At the foot
/// it is the material the foot dot's own slip opens into (`FootSlip`). The
/// caret dot or the foot mark beside it is the only dot. Unlike the foot's
/// slip, whose click target names its buttons, VoiceOver reads it.
struct NoticeCapsule: View {
    /// Transparent room around the label for its float.
    static let shadowRoom: CGFloat = OverApp.floatRoom
    /// The room `DotNotice` places the label with, from before the float.
    static let placedRoom: CGFloat = 12

    let words: String
    var appearance: Appearance = .light

    var body: some View {
        Words(words: words)
            .paper(radius: OverApp.labelRadius, floats: true)
            .appearance(appearance)
            .fixedSize()
    }

    private struct Words: View {
        let words: String
        @Environment(\.palette) private var palette

        var body: some View {
            Text(words)
                .font(SetupStyle.text(13, .semibold))
                .foregroundStyle(palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 13)
                .frame(height: 32)
                .frame(maxWidth: 360)
        }
    }
}
