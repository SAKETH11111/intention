import SwiftUI

/// The spec's switch (step 2's components): a rounded-rectangle track,
/// 36 by 22, with a square-cornered knob; a well with an edge when off,
/// ink when on (the moonlit sky by night). While the pointer is down the
/// knob stretches toward where it will go, then springs across. It draws
/// the same whether its window is in front or not, as the system's switch,
/// which takes the accent colour and greys behind other windows, does not.
/// To VoiceOver it is a switch with its title and On or Off, and Space
/// presses it.
struct IntentionSwitch: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: { EmptyView() }
            .buttonStyle(Track(isOn: isOn))
            .keyboardFocusRing(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(isOn ? "On" : "Off")
            .accessibilityAddTraits(.isToggle)
    }

    private struct Track: ButtonStyle {
        let isOn: Bool

        func makeBody(configuration: Configuration) -> some View {
            Face(isOn: isOn, isPressed: configuration.isPressed)
        }
    }

    private struct Face: View {
        let isOn: Bool
        let isPressed: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.palette) private var palette
        @Environment(\.stillControlState) private var still
        @State private var hovering = false

        var body: some View {
            let isPressed = self.isPressed || still == .pressed
            let lit = hovering || still == .hover
            let track = RoundedRectangle(cornerRadius: 6, style: .continuous)
            let knob = RoundedRectangle(cornerRadius: 4, style: .continuous)
            let on = palette.isNight ? palette.skyInk : palette.ink
            let knobOn = palette.isNight ? palette.well : palette.sheet
            let knobOff = palette.isNight ? palette.ink : palette.sheet
            track
                .fill(isOn ? on : palette.well)
                .overlay(track.strokeBorder(isOn ? .clear : palette.controlEdge, lineWidth: 0.5))
                .frame(width: 36, height: 22)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    knob
                        .fill(isOn ? knobOn : knobOff)
                        .overlay(knob.strokeBorder(isOn ? .clear : palette.ink.opacity(0.30), lineWidth: 0.5))
                        .shadow(color: .black.opacity(isOn ? 0 : 0.18), radius: 0.5, y: 1)
                        .frame(width: isPressed ? 21 : 16, height: 16)
                        .padding(3)
                }
                .background {
                    // The pointer's ring, three points round the track.
                    track.inset(by: -3).fill(palette.ink.opacity(lit && isEnabled ? 0.07 : 0))
                }
                .animation(reduceMotion ? nil : .spring(duration: 0.22, bounce: 0.3), value: isOn)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.09), value: isPressed)
                .opacity(isEnabled ? 1 : 0.42)
                .contentShape(track)
                .onHover { hovering = $0 }
        }
    }
}

/// The spec's segmented control, for two or three choices: a quiet well,
/// the chosen segment a raised paper cap on its 1.5-point seat that moves
/// to the one pressed. Each segment is a button VoiceOver reads as
/// selected or not, inside a group named `title`. A segment shows its
/// label in words unless `face` draws something else for it, such as a
/// glyph; the label stays its name to VoiceOver either way.
struct IntentionSegments<Value: Hashable, Face: View>: View {
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    @ViewBuilder let face: (Value, String) -> Face
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.palette) private var palette
    @Namespace private var cap

    var body: some View {
        let well = RoundedRectangle(cornerRadius: 8, style: .continuous)
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let chosen = option.value == selection
                Button {
                    withAnimation(reduceMotion ? nil : .spring(duration: 0.2, bounce: 0.15)) { selection = option.value }
                } label: {
                    face(option.value, option.label)
                }
                .buttonStyle(Segment(isChosen: chosen, cap: cap))
                .keyboardFocusRing(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(2)
        .padding(.bottom, 1.5)
        .background(palette.well, in: well)
        .overlay(well.strokeBorder(palette.rule, lineWidth: 0.5))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private struct Segment: ButtonStyle {
        let isChosen: Bool
        let cap: Namespace.ID

        func makeBody(configuration: Configuration) -> some View {
            Label(label: configuration.label, isChosen: isChosen, cap: cap)
        }
    }

    private struct Label<Content: View>: View {
        let label: Content
        let isChosen: Bool
        let cap: Namespace.ID
        @Environment(\.palette) private var palette
        @Environment(\.stillControlState) private var still
        @State private var hovering = false

        var body: some View {
            let lit = hovering || (still == .hover && !isChosen)
            let face = RoundedRectangle(cornerRadius: 6, style: .continuous)
            label
                .font(SetupStyle.text(12.5, .semibold))
                .foregroundStyle(isChosen || lit ? palette.ink : palette.lead)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minWidth: 52)
                .frame(height: 26)
                .background {
                    if isChosen {
                        face.fill(palette.paperButton)
                            .overlay(face.strokeBorder(palette.controlEdge, lineWidth: 0.5))
                            .background(face.fill(palette.paperSeat).offset(y: 1.5))
                            .matchedGeometryEffect(id: "cap", in: cap)
                    } else if lit {
                        face.fill(palette.ink.opacity(0.06))
                    }
                }
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

extension IntentionSegments where Face == Text {
    init(title: String, selection: Binding<Value>, options: [(value: Value, label: String)]) {
        self.init(title: title, selection: selection, options: options) { _, label in Text(label) }
    }
}
