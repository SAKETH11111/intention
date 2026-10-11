import AppKit
import CoreText
import SwiftUI

/// Intention's look: a plain dawn gradient behind the pages, Instrument Serif
/// for headings, DM Sans for everything read or pressed, and ink on paper. Always the day's colours: dark is only ever chosen, never
/// automatic.
///
/// The finish follows the conventions of a well-made Mac tool: surfaces are
/// told apart by a hairline and a soft, low shadow rather than a heavy
/// drop; controls share a few heights; secondary text is the ink at a
/// fixed strength; a key reads as a keycap chip; and motion is short, with
/// one easing, and stops when its job is done.
enum SetupStyle {
    static let paper = Color(red: 0.976, green: 0.980, blue: 0.969)
    static let ink = Color(red: 0.125, green: 0.165, blue: 0.180)
    static let line = Color(red: 0.855, green: 0.871, blue: 0.875)
    /// For a problem the person has to act on: a red dark enough to read on
    /// paper.
    static let alert = Color(red: 0.68, green: 0.27, blue: 0.18)
    /// The ink for text that supports the line above it.
    static let secondary = ink.opacity(0.64)
    /// The ink for a hint the person reads once, such as a placeholder.
    static let faint = ink.opacity(0.42)
    /// A hairline round a surface, so it is told apart by an edge, not by
    /// weight.
    static let hairline = ink.opacity(0.10)
    /// The fill of a chip: a keycap, a state, a label.
    static let chip = ink.opacity(0.07)
    /// A pale sky blue, for what is chosen and for a label that
    /// marks a kind, such as the main window's Email tag and its Settings
    /// selection.
    static let accent = Color(red: 0.859, green: 0.902, blue: 0.937)
    /// The sheet's corners.
    static let sheetRadius: CGFloat = 16

    /// Motion: the one easing and its two lengths, for a control changing
    /// and a page turning. Both are skipped under Reduce Motion by the
    /// views that use them.
    static let quick = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.16)
    static let turn = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.24)

    /// Instrument Serif is a display face: short headings, 18 pt and up.
    static func display(_ size: CGFloat) -> Font {
        .custom("Instrument Serif", fixedSize: size)
    }

    static func text(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .custom("DM Sans", fixedSize: size).weight(weight)
    }

    static func image(_ name: String, _ type: String) -> NSImage {
        Bundle.main.url(forResource: name, withExtension: type).flatMap(NSImage.init(contentsOf:)) ?? NSImage()
    }

    /// Makes the two bundled typefaces available to this process. Call once
    /// before the window is built.
    static func registerFonts() {
        for name in ["InstrumentSerif-Regular", "DM-Sans"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

extension SetupStyle {
    // The setup window's own tokens, from the shared Intention UI spec
    // (intention-ui.css). Setup is always the day: dark is only ever chosen in
    // Settings, which nobody has reached before setup.

    /// The desk the background softens into under the actions.
    static let ground = Color(hex: 0xEEEBE1)
    /// One step below the page, as the invite code's cells are.
    static let well = Color(hex: 0xE4E1D6)
    /// The ink for a lead or a quiet link.
    static let lead = ink.opacity(0.76)
    /// The drawn check's colour.
    static let done = Color(hex: 0x2E7550)
    /// The one small warm mark before a line that needs doing.
    static let attention = Color(hex: 0xE0784F)
    /// The field the person speaks into, and its edge.
    static let field = Color(hex: 0xEFECE3)
    static let fieldEdge = ink.opacity(0.55)
    /// The seat button's face under the pointer, and its seat.
    static let paperHover = Color(hex: 0xF1F1EB)
    static let seat = ink.opacity(0.30)
    /// The rule between rows, a sheet's edge and a control's edge.
    static let rule = ink.opacity(0.14)
    static let edge = ink.opacity(0.26)
    static let controlEdge = ink.opacity(0.46)
}

/// The setup window's motion, with the design's numbers (the onboarding
/// design's build spec and its scene sources). Every curve is one of GSAP's,
/// as the design was timed with them. Each animation has an end: only the
/// caret dot's breath and the "Connecting" dot repeat, and only while
/// Intention works.
enum SetupMotion {
    /// Set while stills are drawn: every beat lands at once in its end state.
    nonisolated(unsafe) static var isStill = false

    /// GSAP's power1 and power2, out, in and in-out.
    static func quadOut(_ duration: Double) -> Animation { .timingCurve(0.25, 0.46, 0.45, 0.94, duration: duration) }
    static func cubicOut(_ duration: Double) -> Animation { .timingCurve(0.215, 0.61, 0.355, 1, duration: duration) }
    static func quadInOut(_ duration: Double) -> Animation { .timingCurve(0.455, 0.03, 0.515, 0.955, duration: duration) }
    static func quadIn(_ duration: Double) -> Animation { .timingCurve(0.55, 0.085, 0.68, 0.53, duration: duration) }
    /// The walk between pages: 1.25 s, ease-in-out.
    static let walk = Animation.timingCurve(0.45, 0, 0.55, 1, duration: 1.25)
    /// A drawn mark: a rule, a check, an arrow.
    static let draw: Double = 0.18

    /// How long `count` words take to land in a field: each fades in and
    /// rises over 0.22 s, 0.042 s after the one before.
    static func landing(words count: Int) -> Double {
        count > 0 ? Double(count - 1) * 0.042 + 0.22 : 0
    }
}
