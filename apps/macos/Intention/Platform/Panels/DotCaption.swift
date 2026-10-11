import AppKit
import SwiftUI

/// A few words beside the dot, for what the dot alone cannot say: that
/// Intention is writing the person's email while they wait, that it typed
/// their words instead when it could not, and, until the first email, which
/// key to hold in an email body (`EmailHint`). Shown only in those moments;
/// an ordinary dictation shows nothing but the dot. The window never takes
/// focus or a click, and nothing is read from the field to place it: the
/// dot's own position is enough.
@MainActor
final class DotCaption {
    /// Room between the dot and the words.
    nonisolated static let gap: CGFloat = 8
    /// Transparent room around the label for its float, inside the
    /// window, so the float is not cut off at its edge.
    nonisolated static let shadowRoom: CGFloat = OverApp.floatRoom
    /// The room the label is placed with, kept from before the float, so it
    /// keeps its place beside the dot and on the screen.
    nonisolated static let placedRoom: CGFloat = 10
    /// Light or Dark, as chosen in Settings, read when the words change.
    var appearance: () -> Appearance = { Appearance.current }
    nonisolated(unsafe) private var appearanceObserver: NSObjectProtocol?

    private let panel: NSPanel
    private let host: NSHostingView<DotCaptionView>
    private var text: String?
    private var shownAppearance: Appearance = .light

    init() {
        SetupStyle.registerFonts()
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // Beside the dot, at its level: above floating panels, below menus.
        panel.level = .statusBar
        #if DEBUG
        panel.title = "dot caption"
        #endif
        host = NSHostingView(rootView: DotCaptionView(text: ""))
        host.sizingOptions = []
        panel.contentView = host
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
        guard let text else { return }
        shownAppearance = appearance()
        panel.appearance = shownAppearance.nsAppearance
        host.rootView = DotCaptionView(text: text, appearance: shownAppearance)
    }

    var window: NSPanel { panel }
    var showsWindow = true

    /// Shows `text` beside `dot`, to its right and centred on it, or to
    /// its left when the right would run off `screen`; nil hides. `dot` is
    /// in AppKit screen coordinates, as the dot controller places it.
    func show(_ text: String?, beside dot: DotPlacement.Dot, on screen: NSScreen) {
        show(text, beside: dot, on: screen.visibleFrame)
    }

    func show(_ text: String?, beside dot: DotPlacement.Dot, on usable: CGRect) {
        show(text, at: { Self.frame(of: $0, beside: dot, on: usable) })
    }

    /// Without a drawn dot, the label stands where the dot would: its left
    /// edge at the dot's and its foot on the dot's foot, so it sits above
    /// the caret's line rather than over it.
    func show(_ text: String?, alignedWith dot: DotPlacement.Dot, on usable: CGRect) {
        show(text, at: { Self.frame(of: $0, alignedWith: dot, on: usable) })
    }

    private func show(_ text: String?, at place: (CGSize) -> CGRect) {
        guard let text else { return hide() }
        let appearance = appearance()
        panel.appearance = appearance.nsAppearance
        if text != self.text || appearance != shownAppearance {
            self.text = text
            shownAppearance = appearance
            host.rootView = DotCaptionView(text: text, appearance: appearance)
        }
        let size = host.fittingSize
        let frame = place(size)
        if panel.frame != frame {
            panel.setFrame(frame, display: false)
            host.frame = CGRect(origin: .zero, size: frame.size)
        }
        if showsWindow, !panel.isVisible { panel.orderFrontRegardless() }
    }

    static func frame(of size: CGSize, beside dot: DotPlacement.Dot, on usable: CGRect) -> CGRect {
        // Placed as before the float needed more room: by a box with
        // `placedRoom` around the label, which then grows to the window by
        // the float's extra room on every side, so the label lands where it
        // always did.
        let extra = Self.shadowRoom - Self.placedRoom
        let placed = CGSize(width: size.width - 2 * extra, height: size.height - 2 * extra)
        var origin = CGPoint(x: dot.center.x + dot.diameter / 2 + Self.gap - Self.placedRoom, y: dot.center.y - placed.height / 2)
        if origin.x + placed.width - Self.placedRoom > usable.maxX {
            origin.x = dot.center.x - dot.diameter / 2 - Self.gap + Self.placedRoom - placed.width
        }
        origin.x = max(usable.minX - Self.placedRoom, origin.x)
        origin.y = min(max(usable.minY, origin.y), usable.maxY - placed.height)
        // Rounded where main rounded, before the whole extra room is taken
        // off, so a half point rounds the same way it always did.
        return CGRect(x: origin.x.rounded() - extra, y: origin.y.rounded() - extra, width: size.width.rounded(.up), height: size.height.rounded(.up))
    }

    static func frame(of size: CGSize, alignedWith dot: DotPlacement.Dot, on usable: CGRect) -> CGRect {
        let label = CGSize(width: size.width - 2 * shadowRoom, height: size.height - 2 * shadowRoom)
        let x = min(max(dot.center.x - dot.diameter / 2, usable.minX), max(usable.minX, usable.maxX - label.width))
        let y = min(max(dot.center.y - dot.diameter / 2, usable.minY), max(usable.minY, usable.maxY - label.height))
        return CGRect(x: x.rounded() - shadowRoom, y: y.rounded() - shadowRoom,
                      width: size.width.rounded(.up), height: size.height.rounded(.up))
    }

    func hide() {
        guard panel.isVisible || text != nil else { return }
        text = nil
        panel.orderOut(nil)
    }
}

/// The words themselves on the over-app paper: DM Sans 13/600 in ink, one
/// line, on a label's corners with the half-point edge and the one float.
/// Nothing in it moves; the dot beside it carries the pulse.
struct DotCaptionView: View {
    /// The label's height, without the float's room.
    static let height: CGFloat = 28

    let text: String
    var appearance: Appearance = .light

    var body: some View {
        Words(text: text)
            .paper(radius: OverApp.labelRadius, floats: true)
            .padding(DotCaption.shadowRoom)
            .appearance(appearance)
            .fixedSize()
    }

    private struct Words: View {
        let text: String
        @Environment(\.palette) private var palette

        var body: some View {
            Text(text)
                .font(SetupStyle.text(13, .semibold))
                .foregroundStyle(palette.ink)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: DotCaptionView.height)
        }
    }
}
