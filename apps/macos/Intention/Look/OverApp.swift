import SwiftUI

/// The numbers shared by everything Intention draws over another app: the
/// reply card at the caret, the popup that says why text did not go in, the
/// words beside the dot. Their material is the shared floating paper,
/// `.paper(radius:floats: true)`: flat paper, a half-point ink edge and the
/// one float, navy by night. No gradient, no inset highlight, no
/// capsule.
enum OverApp {
    /// A popup's and the card's corners.
    static let radius: CGFloat = 10
    /// A one-line label's corners, short enough that it never reads as a
    /// capsule.
    static let labelRadius: CGFloat = 8
    /// Transparent room the float needs around a surface inside its
    /// window, so its far shadow, 32 points of blur 16 below by night,
    /// fades out before the window's edge instead of being cut there.
    static let floatRoom: CGFloat = 32
    /// The spec's motion for a surface arriving and leaving: arrive 280 ms
    /// rising 8 points with the ease-out, leave 160 ms.
    static let arrive = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.28)
    static let rise: CGFloat = 8
}

/// The caret dot at rest, as a still mark inside a surface or a line of
/// text, drawn as the foot mark's resting dot is: a true circle in solid ink
/// inside an even hairline of the other tone (`OwnHandMark.restingDot`,
/// `restInk`, `restEdgeInk`), by day or by night as the palette is. It takes
/// the dot's own `diameter` in layout and its hairline draws outside it, so
/// the dot sits where the grey one did.
struct RestingDot: View {
    var diameter: CGFloat = 8
    @Environment(\.palette) private var palette

    var body: some View {
        let shape = OwnHandMark.restingDot(diameter: diameter, centre: CGPoint(x: diameter / 2, y: diameter / 2))
        ZStack {
            Path(shape.edge).fill(Color(nsColor: OwnHandMark.restEdgeInk(dark: palette.isNight)))
            Path(shape.core).fill(Color(nsColor: OwnHandMark.restInk(dark: palette.isNight)))
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}
