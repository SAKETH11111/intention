import AppKit
import SwiftUI

/// Content-sized windows must not ask AppKit to resize them from a hosting
/// controller's preferredContentSize during an update-constraints pass.
/// Measure once before presentation, then apply geometry changes next turn.
@MainActor
enum FittedWindow {
    static func install<Content: View>(_ content: Content, in window: NSWindow, width: CGFloat) {
        let sizing = Size(window: window, width: width)
        let host = NSHostingController(rootView: content
            .fixedSize(horizontal: true, vertical: true)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { sizing.request($0) })
        host.sizingOptions = []
        window.contentViewController = host
        sizing.apply(host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)))
    }

    @MainActor
    private final class Size {
        weak var window: NSWindow?
        let width: CGFloat
        private var pending: CGSize?
        private var scheduled = false

        init(window: NSWindow, width: CGFloat) {
            self.window = window
            self.width = width
        }

        func request(_ size: CGSize) {
            pending = size
            guard !scheduled else { return }
            scheduled = true
            // Geometry is reported during SwiftUI layout. Resizing here
            // would invalidate that same pass; coalesce it onto the next one.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                if let size = self.pending {
                    self.pending = nil
                    self.apply(size)
                }
            }
        }

        func apply(_ size: CGSize) {
            guard let window, size.height.isFinite, size.height > 0 else { return }
            // AppKit rounds window frames. Compare the rounded content size
            // so a fractional text height cannot keep requesting a resize.
            let fitted = CGSize(width: width, height: ceil(size.height))
            guard window.contentRect(forFrameRect: window.frame).size != fitted else { return }
            window.setContentSize(fitted)
        }
    }
}

/// Draws the window in Settings' Light or Dark, following a change while it
/// is open, so the window's own parts, its buttons and the desk behind the
/// page, match.
struct WindowLook: ViewModifier {
    let appearance: @MainActor () -> Appearance
    weak var window: NSWindow?
    @State private var look: Appearance?

    func body(content: Content) -> some View {
        let look = look ?? appearance()
        content
            .appearance(look)
            .onChange(of: look, initial: true) { _, look in
                window?.appearance = look.nsAppearance
                window?.backgroundColor = NSColor(look.palette.ground)
            }
            .onReceive(NotificationCenter.default.publisher(for: .intentionAppearanceChanged)) { _ in
                self.look = appearance()
            }
    }
}

/// The working breath before a line that says Intention is at work, such as
/// "Sending…": the mark's dot in ink, between full and 30 percent every
/// 0.45 s, as setup's connecting dot breathes, only while it shows. Still
/// under Reduce Motion.
struct WorkingDot: View {
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var low = false

    var body: some View {
        Path(OwnHandMark.dot(diameter: 7).path)
            .fill(palette.ink)
            .frame(width: 7, height: 7)
            .opacity(low ? 0.3 : 1)
            .accessibilityHidden(true)
            .onAppear { breathe(!reduceMotion) }
            .onChange(of: reduceMotion) { _, still in breathe(!still) }
    }

    private func breathe(_ on: Bool) {
        guard on, !SetupMotion.isStill else {
            var stop = Transaction()
            stop.disablesAnimations = true
            withTransaction(stop) { low = false }
            return
        }
        withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) { low = true }
    }
}
