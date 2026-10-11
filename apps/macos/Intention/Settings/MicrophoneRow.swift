import AppKit
import SwiftUI

/// The Microphone line of Settings' General card, and the list it unfolds:
/// every input, the built-in microphone recommended, the chosen one checked,
/// and beside each input that has a live stream the resting dot, swelling
/// with what it hears. The list unfolds inside the card, and the streams
/// run only while it is open (`MicrophoneMenu.metering`); opening it never
/// asks macOS for the microphone. What the rows are and which can be heard
/// is `MicrophoneMenu`'s, which the foot dot's menu shares.
struct MicrophoneRow: View {
    let menu: MicrophoneMenu
    /// Follows the inputs while the line shows; Settings hands it the app's
    /// `AudioInputWatch`.
    var follow: () async -> Void = {}
    /// Whether the list is unfolded. Settings holds it, since the pane is
    /// drawn again inside a scroll view when the open list makes it too
    /// tall, and that copy must show the list open too.
    @Binding var isOpen: Bool
    /// A Settings render keeps the list open whatever Intention's activation.
    var staysOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            SettingsLine(title: "Microphone", detail: "System default uses the one macOS is using.",
                         note: menu.note ?? Self.missingNote(in: menu)) {
                Button { fold(!isOpen) } label: {
                    PopUpLabel(title: Self.name(menu.label), isOpen: isOpen)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .keyboardFocusRing(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityLabel("Microphone")
                .accessibilityValue(menu.label)
                .accessibilityAddTraits(isOpen ? .isSelected : [])
                .accessibilityHint(isOpen ? "Hides the microphones" : "Shows the microphones")
            }
            if isOpen {
                VStack(spacing: 0) {
                    ForEach(Array(menu.rows.enumerated()), id: \.element.id) { index, row in
                        OptionLine(row: row) {
                            menu.choose(row.preference)
                            fold(false)
                        }
                        .modifier(StillRow(index: index))
                    }
                }
                .padding(.bottom, 4)
                .transition(.opacity)
                // The streams, only while the list is open.
                .task { await menu.metering() }
            }
        }
        .task { await follow() }
        // Nothing listens while Intention is behind another app.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if !staysOpen { fold(false) }
        }
    }

    /// Unfolds or folds the list: the card grows in 200 ms and the lines
    /// below move down; under Reduce Motion it appears in place, fading in
    /// 120 ms.
    private func fold(_ open: Bool) {
        guard open != isOpen else { return }
        // Folding closes every input now; the list's task, cancelled when
        // the list has gone, only cleans up after.
        if !open { menu.stopMetering() }
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.2)) {
            isOpen = open
        }
    }

    /// One input: the drawn check when chosen, its name, a line where one
    /// says something (why it has no dot included), and its dot.
    private struct OptionLine: View {
        let row: MicrophoneMenu.Row
        let choose: () -> Void
        @Environment(\.palette) private var palette
        @Environment(\.stillControlState) private var still
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        var body: some View {
            let detail = MicrophoneRow.detail(for: row)
            let lit = hovering || still == .hover
            Button(action: choose) {
                HStack(spacing: 10) {
                    ZStack {
                        if row.isChosen { DrawnCheck() }
                    }
                    .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(MicrophoneRow.title(for: row))
                            .font(SetupStyle.text(14, .semibold))
                            .foregroundStyle(palette.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let detail {
                            Text(detail)
                                .font(SetupStyle.text(13))
                                .foregroundStyle(palette.lead)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    LevelDot(level: row.level)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .frame(minHeight: 44)
                // The row under the pointer takes the well's tone across the
                // card, in and out in 90 ms.
                .background(lit ? palette.well : .clear)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.09), value: lit)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Inside the row, which spans the card: outside it the card's
            // edge would cut the ring.
            .keyboardFocusRing(RoundedRectangle(cornerRadius: 8, style: .continuous).inset(by: 7))
            .onHover { hovering = $0 }
            .overlay(alignment: .top) { SettingsRule() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(([MicrophoneRow.title(for: row)] + [detail].compactMap { $0 }).joined(separator: ", "))
            .accessibilityAddTraits(row.isChosen ? [.isButton, .isSelected] : .isButton)
        }
    }

    /// The folded button's words: the chosen input's name alone; the line
    /// says when it is not connected.
    static func name(_ label: String) -> String {
        label.replacingOccurrences(of: " (not connected)", with: "")
    }

    /// When the chosen input is not connected, which microphone dictation
    /// uses in its place (`MicrophoneChoice.pick`), as the line's warm note.
    static func missingNote(in menu: MicrophoneMenu) -> String? {
        guard let chosen = menu.rows.first(where: \.isChosen), chosen.quiet == .notConnected else { return nil }
        let pick = MicrophoneChoice.pick(chosen.preference, from: menu.inputs)
        guard let used = pick.device else { return "Not connected." }
        return used.isBuiltIn ? "Not connected, so the built-in microphone is used." : "Not connected, so \(used.name) is used."
    }

    /// The input's name, without what the menu put after it: the second
    /// line says it here.
    static func title(for row: MicrophoneMenu.Row) -> String {
        row.title.replacingOccurrences(of: " (recommended)", with: "").replacingOccurrences(of: " (not connected)", with: "")
    }

    /// What a row's second line says: "Recommended" for the built-in
    /// microphone, which device the system default follows, and why there
    /// is no dot when there is none. Nil when there is nothing to say.
    static func detail(for row: MicrophoneMenu.Row) -> String? {
        var parts: [String] = []
        if row.isRecommended { parts.append("Recommended") }
        if case .systemDefault = row.id, let detail = row.detail { parts.append(detail) }
        if let quiet = row.quiet { parts.append(words(for: quiet)) }
        return parts.isEmpty ? nil : parts.joined(separator: ". ")
    }

    static func words(for quiet: MicrophoneMenu.Row.Quiet) -> String {
        switch quiet {
        case .notConnected: "Not connected"
        case .lidClosed: "Off while the lid is closed"
        // Opening it would switch the headset to call quality.
        case .bluetooth: "Bluetooth, so no level is shown"
        case .notAllowed: "Its level shows once you allow the microphone"
        case .unavailable: "Its level can't be shown"
        }
    }

    typealias Option = MicrophoneOptions.Option
    static func options(for chosen: MicrophonePreference, in inputs: AudioInputs) -> [Option] {
        MicrophoneOptions.options(for: chosen, in: inputs)
    }
    static func label(for chosen: MicrophonePreference, in inputs: AudioInputs) -> String {
        MicrophoneOptions.label(for: chosen, in: inputs)
    }
    static func note(for chosen: MicrophonePreference, in inputs: AudioInputs) -> String? {
        MicrophoneOptions.note(for: chosen, in: inputs)
    }
}

/// A Settings render can put one row of the open list, rather than every
/// control at once, in a passing state: `--microphones-still hover|focused`
/// with `--microphones-still-row <index>`.
private struct StillRow: ViewModifier {
    let index: Int

    func body(content: Content) -> some View {
        #if DEBUG
        if let still = Self.requested {
            content.environment(\.stillControlState, still.row == index ? still.state : nil)
        } else {
            content
        }
        #else
        content
        #endif
    }

    #if DEBUG
    private static var requested: (state: StillControlState, row: Int)? {
        let arguments = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), arguments.indices.contains(i + 1) else { return nil }
            return arguments[i + 1]
        }
        let state: StillControlState? = switch value("--microphones-still") {
        case "hover": .hover
        case "focused": .focused
        case "pressed": .pressed
        default: nil
        }
        guard let state, let row = value("--microphones-still-row").flatMap(Int.init) else { return nil }
        return (state, row)
    }
    #endif
}
