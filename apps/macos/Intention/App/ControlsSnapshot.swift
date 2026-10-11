#if OFFSCREEN_RENDER
import AppKit
import SwiftUI

/// `--controls-snapshot <file.png>` draws every shared control in each of
/// its states, at rest, under the pointer, pressed, with keyboard focus
/// and disabled, by day and by night, to one PNG, and quits. The passing
/// states are drawn through `StillControlState`, as the styles draw the
/// real ones; nothing is clicked or focused.
@MainActor
enum ControlsSnapshot {
    static func renderIfRequested(arguments: [String]) {
        OffscreenRenderGuard.requireInstalled()
        guard let index = arguments.firstIndex(of: "--controls-snapshot"), arguments.indices.contains(index + 1) else { return }
        SetupStyle.registerFonts()
        SetupMotion.isStill = true
        let board = HStack(alignment: .top, spacing: 0) {
            Board().appearance(.light)
            Board().appearance(.dark)
        }
        let host = NSHostingView(rootView: board.fixedSize())
        let size = host.fittingSize
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: .now + 0.6)
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        exit((try? png.write(to: URL(fileURLWithPath: arguments[index + 1]))) == nil ? 1 : 0)
    }

    private enum Shown: String, CaseIterable {
        case rest, hover, pressed, focused, disabled

        var still: StillControlState? {
            switch self {
            case .hover: .hover
            case .pressed: .pressed
            case .focused: .focused
            case .rest, .disabled: nil
            }
        }
    }

    private struct Board: View {
        @Environment(\.palette) private var palette

        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 0) {
                    Text("").frame(width: 150, alignment: .leading)
                    ForEach(Shown.allCases, id: \.self) { shown in
                        Text(shown.rawValue.uppercased())
                            .font(SetupStyle.text(11, .semibold)).tracking(0.88)
                            .foregroundStyle(palette.secondary)
                            .frame(width: 170, alignment: .leading)
                    }
                }
                row("Ink action") { Button("Done") {}.buttonStyle(InkActionStyle(size: 26)) }
                row("Seat") { Button("Open Settings") {}.buttonStyle(SeatButtonStyle()) }
                row("Seat, small") { Button("Reconnect") {}.buttonStyle(SeatButtonStyle(isSmall: true)) }
                row("Seat, primary") { Button("Settings") {}.buttonStyle(SeatButtonStyle(isChosen: true, isSmall: true)) }
                row("Seat, destructive") { Button("Clear history\u{2026}") {}.buttonStyle(SeatButtonStyle(isSmall: true, isDestructive: true)) }
                row("Word") { Button("Check for updates") {}.buttonStyle(WordButtonStyle()) }
                row("Quiet link") { Button("Not now") {}.buttonStyle(QuietLinkStyle()) }
                row("Switch, off") { IntentionSwitch(title: "Off", isOn: .constant(false)) }
                row("Switch, on") { IntentionSwitch(title: "On", isOn: .constant(true)) }
                row("Segments") {
                    IntentionSegments(title: "Appearance", selection: .constant(Appearance.light), options: Appearance.allCases.map { ($0, $0.title) })
                }
                // With the ring Settings' microphone menu carries.
                row("Picker") {
                    PopUpLabel(title: "Built-in microphone")
                        .keyboardFocusRing(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                row("Field") { FieldSample() }
            }
            .padding(28)
            .background(palette.sheet)
        }

        private func row<Content: View>(_ name: String, @ViewBuilder _ control: @escaping () -> Content) -> some View {
            HStack(spacing: 0) {
                Text(name)
                    .font(SetupStyle.text(13, .semibold))
                    .foregroundStyle(palette.ink)
                    .frame(width: 150, alignment: .leading)
                ForEach(Shown.allCases, id: \.self) { shown in
                    control()
                        .environment(\.stillControlState, shown.still)
                        .disabled(shown == .disabled)
                        .frame(width: 170, height: 44, alignment: .leading)
                }
            }
        }
    }

    /// The well field at rest, and as it has the keyboard under "focused".
    private struct FieldSample: View {
        @Environment(\.stillControlState) private var still
        @Environment(\.palette) private var palette

        var body: some View {
            Text("Search")
                .font(SetupStyle.text(14))
                .foregroundStyle(palette.secondary)
                .frame(width: 140, alignment: .leading)
                .wellField(isFocused: still == .focused)
        }
    }
}
#endif
