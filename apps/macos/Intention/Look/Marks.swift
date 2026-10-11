import SwiftUI

/// The hand, in its three places: the rule drawn under a heading and under
/// the one action, the check drawn as two strokes, and the dot; and the
/// seat button and keycap. Setup drew them first; every Intention window
/// shares them, in the palette of the window they are in (`Palette`).
/// Everything else is exact. Each mark draws once, in 180 ms, as it
/// arrives, and the action's marks again when the pointer reaches them.

// Focus belongs to the Button, rather than the label its visual style
// draws. Rebuild that Button from the primitive configuration so all
// callers keep the same styles and AppKit keeps keyboard activation.
struct InkActionStyle: PrimitiveButtonStyle {
    var delay: Double = 0
    var size: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(InkActionFaceStyle(delay: delay, size: size))
            .keyboardFocusRing(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct QuietLinkStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(QuietLinkFaceStyle())
            .keyboardFocusRing(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

struct SeatButtonStyle: PrimitiveButtonStyle {
    var isChosen = false
    var isSmall = false
    var isDestructive = false
    /// The label alone, with the face, edge and seat faded out
    /// (`SeatButtonFaceStyle.isBare`).
    var isBare = false

    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(SeatButtonFaceStyle(isChosen: isChosen, isSmall: isSmall, isDestructive: isDestructive, isBare: isBare))
            .keyboardFocusRing(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct WordButtonStyle: PrimitiveButtonStyle {
    var size: CGFloat = 13

    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(WordButtonFaceStyle(size: size))
            .keyboardFocusRing(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}

/// A page's heading in the display serif, written on by a soft-edged wipe
/// through its letters, then underlined by one straight line. A new title fades the old
/// one in 0.09 s and writes again.
struct SetupHeading: View {
    let title: String
    /// When the first title starts writing, after the heading appears.
    var delay: Double = 0.45
    /// Setup's pages are 38; a window's heading is 28 to 32.
    var size: CGFloat = 38
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.palette) private var palette
    @State private var shown: String?
    // Written from the start in a still, which may be made before it appears.
    @State private var written: Double = SetupMotion.isStill ? 1 : 0
    @State private var ruled: Double = SetupMotion.isStill ? 1 : 0
    @State private var opacity: Double = 1

    var body: some View {
        Text(shown ?? title)
            .font(SetupStyle.display(size))
            .lineLimit(1)
            // A greeting with a long name shrinks to stay on its line, and
            // only for its width: the face is taller than its line box, so
            // a fitted height would shrink every heading.
            .minimumScaleFactor(0.6)
            .fixedSize(horizontal: false, vertical: true)
            .modifier(Wipe(progress: written))
            // The design's line box, 1.12 of the size; the letters overflow
            // it as they do on the web.
            .frame(height: size * 1.12)
            .background {
                // Measured here rather than kept in state, so the rule is
                // the heading's width from the first frame drawn.
                GeometryReader { proxy in
                    HandRule(width: proxy.size.width + 4)
                        .trim(from: 0, to: ruled)
                        .stroke(palette.ink.opacity(0.55), style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                        .frame(width: proxy.size.width + 4, height: 8)
                        .offset(x: -2, y: proxy.size.height - 8 + 7 * size / 38)
                }
            }
            .opacity(opacity)
            .accessibilityAddTraits(.isHeader)
            .onAppear {
                shown = title
                write(after: delay, length: 0.55)
            }
            .onChange(of: title) { _, next in
                Task { @MainActor in
                    let instant = SetupMotion.isStill || reduceMotion
                    if !instant {
                        withAnimation(.linear(duration: 0.09)) { opacity = 0 }
                        try? await Task.sleep(for: .milliseconds(90))
                    }
                    var none = Transaction()
                    none.disablesAnimations = true
                    withTransaction(none) {
                        shown = next
                        written = 0
                        ruled = 0
                        opacity = 1
                    }
                    write(after: 0, length: 0.48)
                }
            }
    }

    /// Writes the title on in its length's time, then draws the rule.
    private func write(after delay: Double, length most: Double) {
        let text = shown ?? title
        guard !SetupMotion.isStill, !reduceMotion else {
            written = 1
            ruled = 1
            return
        }
        let duration = min(most, 0.2 + 0.026 * Double(text.count))
        withAnimation(SetupMotion.quadInOut(duration).delay(delay)) { written = 1 }
        withAnimation(SetupMotion.quadOut(SetupMotion.draw).delay(delay + duration)) { ruled = 1 }
    }

    /// The wipe: opaque up to 112% of the progress less 12%, clear from
    /// there, so the edge is soft for 12% of the heading's width.
    private struct Wipe: ViewModifier, Animatable {
        var progress: Double
        nonisolated var animatableData: Double {
            get { progress }
            set { progress = newValue }
        }

        func body(content: Content) -> some View {
            let end = progress * 1.12
            content.mask {
                LinearGradient(stops: [.init(color: .black, location: max(0, end - 0.12)), .init(color: .clear, location: max(0.0001, end))],
                               startPoint: .leading, endPoint: .trailing)
            }
        }
    }
}

/// The pen line under a heading: six segments with a seeded waver of
/// plus or minus 0.8 pt, the same line every time.
struct HandRule: Shape {
    let width: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 4))
        path.addLine(to: CGPoint(x: width, y: 4))
        return path
    }
}

/// A done mark: two strokes, the short one in 70 ms, then the long one in
/// 120 ms.
struct DrawnCheck: View {
    var delay: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.palette) private var palette
    // Drawn from the start in a still, which may be made before it appears.
    @State private var short: CGFloat = SetupMotion.isStill ? 1 : 0
    @State private var long: CGFloat = SetupMotion.isStill ? 1 : 0

    var body: some View {
        let style = StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
        ZStack {
            Stroke(part: .short).trim(from: 0, to: short).stroke(palette.done, style: style)
            Stroke(part: .long).trim(from: 0, to: long).stroke(palette.done, style: style)
        }
        .frame(width: 16, height: 14)
        .accessibilityHidden(true)
        .onAppear {
            guard !SetupMotion.isStill, !reduceMotion else {
                short = 1
                long = 1
                return
            }
            withAnimation(SetupMotion.quadOut(0.07).delay(delay)) { short = 1 }
            withAnimation(SetupMotion.quadOut(0.12).delay(delay + 0.07)) { long = 1 }
        }
    }

    private struct Stroke: Shape {
        enum Part { case short, long }
        let part: Part

        func path(in rect: CGRect) -> Path {
            var path = Path()
            switch part {
            case .short:
                path.move(to: CGPoint(x: 2, y: 7.6))
                path.addCurve(to: CGPoint(x: 5.9, y: 11.6), control1: CGPoint(x: 3.6, y: 8.6), control2: CGPoint(x: 4.8, y: 10))
            case .long:
                path.move(to: CGPoint(x: 5.9, y: 11.6))
                path.addCurve(to: CGPoint(x: 14, y: 1.8), control1: CGPoint(x: 7.6, y: 7.6), control2: CGPoint(x: 10.4, y: 4.2))
            }
            return path
        }
    }
}

/// A state said with the drawn check: Allowed, You're in.
struct DoneLine: View {
    let text: String
    var delay: Double = 0
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 7) {
            DrawnCheck(delay: delay)
            Text(text).font(SetupStyle.text(14, .semibold)).foregroundStyle(palette.ink)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The page's one action: the label in the display serif, a rule under it
/// and an arrow beside it, no surface. It fades in over 0.2 s and its marks draw as it arrives: the
/// rule from 0.1 s, the arrow's shaft from 0.28 s and its head from 0.4 s.
/// Under the pointer the rule draws again and the arrow steps 5 to the
/// right; pressed, it sits down a point.
private struct InkActionFaceStyle: ButtonStyle {
    /// When the action arrives, after it appears.
    var delay: Double = 0
    /// Setup's pages are 30; a window's action may be smaller, never under
    /// 24, the display face's least size.
    var size: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        InkAction(label: configuration.label, isPressed: configuration.isPressed, delay: delay, size: size)
    }

    private struct InkAction<Label: View>: View {
        let label: Label
        let isPressed: Bool
        let delay: Double
        let size: CGFloat
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.palette) private var palette
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.stillControlState) private var still
        @State private var shown: Double = 0
        @State private var rule: CGFloat = 0
        @State private var shaft: CGFloat = 0
        @State private var head: CGFloat = 0
        @State private var nudge: CGFloat = 0

        var body: some View {
            let pen = StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
            // A disabled action is ink at 42 percent, the strength for
            // disabled labels, and takes no pointer.
            let ink = isEnabled ? palette.ink : palette.faint
            let pressed = isPressed || still == .pressed
            HStack(spacing: 12) {
                label
                    .font(SetupStyle.display(size))
                    .lineLimit(1)
                    .fixedSize()
                    .background(alignment: .bottom) {
                        CtaRule()
                            .trim(from: 0, to: rule)
                            .stroke(ink, style: pen)
                            .padding(.horizontal, -4)
                            .frame(height: 8)
                            .offset(y: 9)
                    }
                ZStack {
                    CtaArrow(part: .shaft).trim(from: 0, to: shaft).stroke(ink, style: pen)
                    CtaArrow(part: .head).trim(from: 0, to: head).stroke(ink, style: pen)
                }
                .frame(width: 24 * size / 30, height: 15 * size / 30)
                .offset(x: still == .hover ? 5 : nudge)
            }
            .foregroundStyle(ink)
            .padding(EdgeInsets(top: 6, leading: 4, bottom: 12, trailing: 4))
            .contentShape(Rectangle())
            .offset(y: pressed ? 1 : 0)
            .opacity(shown)
            .onAppear(perform: arrive)
            .onHover { inside in
                guard inside, isEnabled, !reduceMotion, !SetupMotion.isStill else { return }
                var none = Transaction()
                none.disablesAnimations = true
                withTransaction(none) { rule = 0 }
                withAnimation(SetupMotion.quadInOut(SetupMotion.draw)) { rule = 1 }
                withAnimation(.spring(duration: 0.26, bounce: 0.45)) { nudge = 5 }
            }
            .onContinuousHover { phase in
                if case .ended = phase, nudge != 0 {
                    withAnimation(reduceMotion ? nil : SetupMotion.quadOut(0.16)) { nudge = 0 }
                }
            }
        }

        private func arrive() {
            guard !SetupMotion.isStill, !reduceMotion else {
                withAnimation(reduceMotion && !SetupMotion.isStill ? .linear(duration: 0.2).delay(delay) : nil) { shown = 1 }
                rule = 1
                shaft = 1
                head = 1
                return
            }
            withAnimation(.linear(duration: 0.2).delay(delay)) { shown = 1 }
            withAnimation(SetupMotion.quadInOut(0.18).delay(delay + 0.1)) { rule = 1 }
            withAnimation(SetupMotion.quadInOut(0.12).delay(delay + 0.28)) { shaft = 1 }
            withAnimation(SetupMotion.cubicOut(0.06).delay(delay + 0.4)) { head = 1 }
        }
    }

    /// The action's rule: one straight line across the label's width.
    private struct CtaRule: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }

    /// A plain arrow, in a 22 by 14 box drawn at 24 by 15.
    private struct CtaArrow: Shape {
        enum Part { case shaft, head }
        let part: Part

        func path(in rect: CGRect) -> Path {
            let sx = rect.width / 22, sy = rect.height / 14
            let p = { (x: CGFloat, y: CGFloat) in CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
            var path = Path()
            switch part {
            case .shaft:
                path.move(to: p(1.5, 7))
                path.addLine(to: p(19.5, 7))
            case .head:
                path.move(to: p(14.5, 2.5))
                path.addLine(to: p(19.5, 7))
                path.addLine(to: p(14.5, 11.5))
            }
            return path
        }
    }
}

/// A way out that does not compete with the page's action: a few words in
/// the ink at 76%, no box.
private struct QuietLinkFaceStyle: ButtonStyle {
    @Environment(\.palette) private var palette
    @Environment(\.stillControlState) private var still

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed || still == .pressed
        // Pressed, the words turn full ink and sit down half a point; text
        // never fades below the readable strengths.
        return configuration.label
            .font(SetupStyle.text(14, .semibold))
            .foregroundStyle(pressed ? palette.ink : palette.lead)
            .padding(.vertical, 8)
            .padding(.horizontal, 2)
            .offset(y: pressed ? 0.5 : 0)
            .contentShape(Rectangle())
    }
}

/// A small control on a sheet: the seat button, a flat paper face on a
/// seat of darker ink, 32 tall, or 28 for a row's own action. Under the
/// pointer the face lifts half a point; pressed, it drops onto the seat in
/// 90 ms. A chosen one, as a picked language is, has an ink face; a
/// destructive one, as Clear history is, is drawn in the alert colour and
/// fills with it while pressed.
private struct SeatButtonFaceStyle: ButtonStyle {
    var isChosen = false
    var isSmall = false
    var isDestructive = false
    /// No face, edge or seat, only the label, as a popup's Copy is once it
    /// has copied: the drawn check and the word. The same button stays
    /// underneath, so VoiceOver keeps hold of it.
    var isBare = false

    func makeBody(configuration: Configuration) -> some View {
        Seat(label: configuration.label, isPressed: configuration.isPressed, isChosen: isChosen, isSmall: isSmall,
             isDestructive: isDestructive, isBare: isBare)
    }

    private struct Seat<Label: View>: View {
        let label: Label
        let isPressed: Bool
        let isChosen: Bool
        let isSmall: Bool
        let isDestructive: Bool
        let isBare: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.palette) private var palette
        @Environment(\.stillControlState) private var still
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
            let isPressed = self.isPressed || still == .pressed
            let lifted = (hovering || still == .hover) && !isPressed && isEnabled
            let seat: CGFloat = isSmall ? 1.5 : 2
            // A disabled primary is a well with a quiet label, as the
            // spec's; any other disabled face stays paper.
            let face = isChosen ? (!isEnabled ? palette.well : lifted ? palette.actionHover : palette.action)
                : isDestructive && isPressed ? palette.alert
                : lifted ? palette.paperButtonHover : palette.paperButton
            let text = isChosen ? palette.actionText : isDestructive ? (isPressed ? palette.sheet : palette.alert) : palette.ink
            let edge = isChosen ? palette.action : isDestructive ? palette.alert : palette.controlEdge
            let drawn: Double = isBare ? 0 : 1
            label
                .font(SetupStyle.text(isSmall ? 12.5 : 13.5, .semibold))
                .foregroundStyle(isEnabled ? text : palette.faint)
                .lineLimit(1)
                .padding(.horizontal, isBare ? 4 : isSmall ? 11 : 14)
                .frame(height: isSmall ? 28 : 32)
                .background(face.opacity(drawn), in: shape)
                .overlay(shape.strokeBorder(isEnabled ? edge : palette.edge, lineWidth: 0.5).opacity(drawn))
                .background(shape.fill(isChosen ? palette.actionSeat : isDestructive ? palette.alert : palette.paperSeat)
                    .offset(y: isPressed || !isEnabled ? 0 : seat).opacity(drawn))
                .offset(y: isBare ? 0 : isPressed ? seat : lifted ? -0.5 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.09), value: isPressed)
                .onHover { hovering = $0 }
                .contentShape(shape)
        }
    }
}

/// The key to hold, drawn as its cap: a paper face on a 3 pt seat, radius 9.
/// Held, it turns to ink and drops onto the seat. A small one stands in the
/// last page's recap.
struct SetupKeycap: View {
    let label: String
    var isDown = false
    var small = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.palette) private var palette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        let seat: CGFloat = small ? 2 : 3
        ZStack(alignment: .bottomLeading) {
            shape.fill(palette.paperSeat).offset(y: isDown ? 0 : seat)
            shape.fill(isDown ? palette.action : palette.paperButton)
            shape.strokeBorder(isDown ? palette.action : palette.controlEdge, lineWidth: 0.5)
            Text(label)
                .font(SetupStyle.text(small ? 12 : 14, .semibold))
                .foregroundStyle(isDown ? palette.actionText : palette.ink)
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, small ? 6 : 8)
                .padding(.trailing, small ? 6 : 8)
                .padding(.bottom, small ? 5 : 7)
            if !small, label == "fn" {
                Globe()
                    .stroke(isDown ? palette.actionText : palette.ink, lineWidth: 1.2)
                    .opacity(0.7)
                    .frame(width: 11, height: 11)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(7)
            }
        }
        .frame(minWidth: small ? 38 : 52)
        .frame(height: small ? 32 : 44)
        .fixedSize(horizontal: true, vertical: false)
        .offset(y: isDown ? seat : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.09), value: isDown)
        .accessibilityHidden(true)
    }

    /// The globe printed on the fn key.
    private struct Globe: Shape {
        func path(in rect: CGRect) -> Path {
            let s = rect.width / 12
            let p = { (x: CGFloat, y: CGFloat) in CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
            var path = Path(ellipseIn: CGRect(x: rect.minX + s, y: rect.minY + s, width: 10 * s, height: 10 * s))
            path.move(to: p(1, 6))
            path.addLine(to: p(11, 6))
            path.move(to: p(6, 1))
            path.addCurve(to: p(6, 11), control1: p(4.2, 2.6), control2: p(4.2, 9.4))
            path.move(to: p(6, 1))
            path.addCurve(to: p(6, 11), control1: p(7.8, 2.6), control2: p(7.8, 9.4))
            return path
        }
    }
}

/// A key named in a line of words, such as a card's "Tab" and "fn": the
/// keycap's construction at 18 points, a paper cap on a 1.5-point seat, or
/// a solid ink one for the key that acts.
struct InlineKeycap: View {
    let label: String
    var isSolid = false
    @Environment(\.palette) private var palette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        Text(label)
            .font(SetupStyle.text(11.5, .semibold))
            .foregroundStyle(isSolid ? palette.actionText : palette.ink)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .frame(minWidth: 20)
            .frame(height: 18)
            .background(isSolid ? palette.action : palette.paperButton, in: shape)
            .overlay(shape.strokeBorder(isSolid ? palette.action : palette.controlEdge, lineWidth: 0.5))
            .background(shape.fill(isSolid ? palette.actionSeat : palette.paperSeat).offset(y: 1.5))
            .padding(.bottom, 1.5)
            .accessibilityHidden(true)
    }
}

/// A word that does something: DM Sans 600 in
/// ink among quieter words, with a hand-drawn rule that draws on under it
/// in 180 ms while the pointer is on it. History's Copy, Retry and Switch
/// mic, and Settings' Check for updates, are these.
private struct WordButtonFaceStyle: ButtonStyle {
    var size: CGFloat = 13

    func makeBody(configuration: Configuration) -> some View {
        Word(label: configuration.label, isPressed: configuration.isPressed, size: size)
    }

    private struct Word<Label: View>: View {
        let label: Label
        let isPressed: Bool
        let size: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.palette) private var palette
        @Environment(\.stillControlState) private var still
        @State private var ruled: CGFloat = 0

        var body: some View {
            let pressed = isPressed || still == .pressed
            let ruledNow = still == .hover || pressed ? 1 : ruled
            label
                .font(SetupStyle.text(size, .semibold))
                .foregroundStyle(isEnabled ? palette.ink : palette.faint)
                .lineLimit(1)
                .padding(.bottom, 3)
                .background(alignment: .bottom) {
                    WordRule()
                        .trim(from: 0, to: ruledNow)
                        .stroke(palette.ink.opacity(0.9), style: StrokeStyle(lineWidth: pressed ? 1.6 : 1.2, lineCap: .round, lineJoin: .round))
                        .frame(height: 4)
                        .offset(y: 2)
                }
                // Pressed, the word sits down onto its rule; it never fades.
                .offset(y: pressed ? 0.5 : 0)
                .contentShape(Rectangle())
                .onHover { inside in
                    let shown: CGFloat = inside && isEnabled ? 1 : 0
                    withAnimation(reduceMotion || SetupMotion.isStill ? nil : SetupMotion.quadOut(inside ? SetupMotion.draw : 0.12)) {
                        ruled = shown
                    }
                }
        }
    }

    /// The rule under a word: a gentle waver across its width.
    private struct WordRule: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY + 0.4))
            path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.midY), control: CGPoint(x: rect.minX + rect.width * 0.25, y: rect.midY - 0.8))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY - 0.2), control: CGPoint(x: rect.minX + rect.width * 0.75, y: rect.midY + 0.8))
            return path
        }
    }
}

/// A small drawn chevron, for a picker and for a row that opens something;
/// never the system's disclosure. It takes the colour of the text round it.
struct DrawnChevron: View {
    enum Direction { case down, right }
    var direction: Direction = .down

    var body: some View {
        Chevron()
            .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            .frame(width: 8, height: 5)
            .rotationEffect(.degrees(direction == .right ? -90 : 0))
            .frame(width: 9, height: 9)
            .accessibilityHidden(true)
    }

    private struct Chevron: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.maxY), control: CGPoint(x: rect.midX * 0.55, y: rect.midY + 0.6))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.midX * 1.45, y: rect.midY + 0.4))
            return path
        }
    }
}

/// The one small warm mark before a line that needs doing: the mark's
/// i's dot, as setup draws it, in the attention colour.
struct AttentionMark: View {
    var diameter: CGFloat = 6
    @Environment(\.palette) private var palette

    var body: some View {
        Path(OwnHandMark.dot(diameter: diameter).path)
            .fill(palette.attention)
            .frame(width: diameter, height: diameter)
            .accessibilityHidden(true)
    }
}

/// A problem the person has to act on: the warm mark, then the line in the
/// alert colour.
struct ProblemLine: View {
    let text: String
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            AttentionMark()
            Text(text)
                .font(SetupStyle.text(13))
                .lineSpacing(2)
                .foregroundStyle(palette.alert)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// The spec's field: a well, radius 7, with a half-point edge at 26
    /// percent, that turns to paper with a one-point ink edge while it has
    /// the keyboard. Put it on a plain `TextField` or `TextEditor`, with the
    /// field's own focus state.
    func wellField(isFocused: Bool, height: CGFloat? = 34) -> some View {
        modifier(WellField(isFocused: isFocused, height: height))
    }
}

private struct WellField: ViewModifier {
    let isFocused: Bool
    let height: CGFloat?
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        content
            .padding(.horizontal, 12)
            .frame(height: height)
            .background(isFocused ? palette.sheet : palette.well, in: shape)
            .overlay(shape.strokeBorder(isFocused ? palette.ink : palette.edge, lineWidth: isFocused ? 1 : 0.5))
    }
}

extension View {
    /// Paper: a sheet lying on the desk (radius 14), or a card on a sheet
    /// (radius 10), with a half-point edge and no shadow. By night the
    /// paper is the moonlit navy with a paper rim along its top edge.
    /// `floats` gives a surface over another window or app the spec's one
    /// float instead. `fill` replaces the paper, as the Settings sheet's
    /// desk does.
    func paper(radius: CGFloat = 14, floats: Bool = false, fill: Color? = nil) -> some View {
        modifier(Paper(radius: radius, floats: floats, fill: fill))
    }
}

private struct Paper: ViewModifier {
    let radius: CGFloat
    let floats: Bool
    let fill: Color?
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(fill ?? (floats ? palette.overPaper : palette.sheet))
            // Clipped, so a band at a surface's foot keeps its corners.
            .clipShape(shape)
            .overlay {
                if palette.isNight, !floats {
                    // The rim: a hair of paper along the top edge, fading
                    // down the sides.
                    shape.strokeBorder(LinearGradient(colors: [palette.ink.opacity(0.12), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.08)),
                                       lineWidth: 1)
                }
            }
            .overlay(shape.strokeBorder(floats ? palette.overEdge : palette.edge, lineWidth: 0.5))
            .background { if floats { float(shape) } }
    }

    /// The float, two shadows of the surface's
    /// own shape. CSS's negative spread has no SwiftUI shadow, so the far
    /// one is the shape inset by its spread, moved down and blurred, which
    /// is what the spread draws.
    private func float(_ shape: RoundedRectangle) -> some View {
        // Day: 0 2px 2px -1px ink 8%, 0 12px 24px -12px ink 35%.
        // Night: 0 2px 2px -1px black 40%, 0 16px 32px -12px #020814 80%.
        let ink = Color(hex: 0x202A2E)
        let near = palette.isNight ? Color.black.opacity(0.4) : ink.opacity(0.08)
        let far = palette.isNight ? Color(hex: 0x020814).opacity(0.8) : ink.opacity(0.35)
        let farDrop: CGFloat = palette.isNight ? 16 : 12
        let farBlur: CGFloat = palette.isNight ? 32 : 24
        return ZStack {
            shape.fill(near).padding(1).offset(y: 2).blur(radius: 1)
            RoundedRectangle(cornerRadius: max(0, radius - 6), style: .continuous)
                .fill(far).padding(12).offset(y: farDrop).blur(radius: farBlur / 2)
        }
        .allowsHitTesting(false)
    }
}

extension View {
    /// The spec's keyboard focus ring: the ring colour at 2 points, 3
    /// points outside `shape`, while this control has keyboard focus, in
    /// place of the system's. macOS gives a button keyboard focus only from
    /// the keyboard, so a click never draws it.
    func keyboardFocusRing<S: InsettableShape>(_ shape: S) -> some View {
        modifier(KeyboardFocusRing(shape: shape))
    }
}

private struct KeyboardFocusRing<S: InsettableShape>: ViewModifier {
    let shape: S
    @FocusState private var isFocused: Bool
    @Environment(\.stillControlState) private var still
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .focusEffectDisabled()
            .overlay {
                if isFocused || still == .focused {
                    shape.inset(by: -5).strokeBorder(palette.ring, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// A control's passing state, for a still that has to show it: under the
/// pointer, pressed, or with keyboard focus. Only Debug renders set it;
/// the shared styles draw it as they would the real state.
enum StillControlState: Sendable {
    case hover, pressed, focused
}

extension EnvironmentValues {
    @Entry var stillControlState: StillControlState?
}

/// The hand's cross, two strokes, to remove something or close: pen 1.8
/// with round caps, as the drawn check.
struct DrawnCross: View {
    var size: CGFloat = 10

    var body: some View {
        Strokes()
            .stroke(style: StrokeStyle(lineWidth: 1.8 * max(1, size / 12), lineCap: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    /// Two strokes as a pen makes them: the first longer and bowed, the
    /// second crossing it a little off centre.
    private struct Strokes: Shape {
        func path(in rect: CGRect) -> Path {
            let p = { (x: CGFloat, y: CGFloat) in CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
            var path = Path()
            path.move(to: p(0.04, 0.06))
            path.addCurve(to: p(0.97, 0.95), control1: p(0.36, 0.3), control2: p(0.62, 0.7))
            path.move(to: p(0.9, 0.02))
            path.addCurve(to: p(0.06, 0.9), control1: p(0.66, 0.36), control2: p(0.4, 0.58))
            return path
        }
    }
}

/// The resting dot as a level meter: 8 points at the rule's strength when
/// quiet, swelling to 14 points at full ink with the level, rising in 60 ms
/// and falling over 240 ms, so a word lands and fades as it does at the
/// foot of the screen. Nil draws nothing: no stream, no dot.
struct LevelDot: View {
    let level: Double?
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Double = 0

    var body: some View {
        Group {
            if level != nil {
                // Drawn at its full 14 points and scaled, so the swell and
                // the ink animate between frames.
                Path(OwnHandMark.dot(diameter: 14).path)
                    .fill(palette.ink)
                    .frame(width: 14, height: 14)
                    .opacity(0.42 + 0.58 * shown)
                    .scaleEffect((8 + 6 * shown) / 14)
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
        .onChange(of: level, initial: true) { old, new in
            let target = min(1, max(0, new ?? 0))
            guard !reduceMotion, !SetupMotion.isStill else {
                shown = target
                return
            }
            withAnimation(.easeOut(duration: target > shown ? 0.06 : 0.24)) { shown = target }
        }
    }
}
