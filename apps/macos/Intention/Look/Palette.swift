import AppKit
import SwiftUI

/// Intention's colours for one appearance, from the shared spec
/// (intention-ui.css): paper on a cream desk by day, moonlit navy by night.
/// A view reads them as `@Environment(\.palette)`; a window sets them once
/// at its root with `.appearance(_:)`. Day is the default everywhere, and
/// setup is always day.
struct Palette: Equatable, Sendable {
    /// AppKit panels read the appearance mirrored by the app model.
    @MainActor static var current: Palette { Appearance.current.palette }

    let isNight: Bool
    /// The desk a window's page lies on.
    let ground: Color
    /// A sheet of paper on the desk.
    let sheet: Color
    /// One step below the page: fields, the segmented control's well.
    let well: Color
    let ink: Color
    /// The ink at 76 percent, for a lead or a quiet link.
    let lead: Color
    /// The ink at 70 percent, the quietest text a person must read:
    /// captions, labels, placeholders. 64 failed AA on the day surfaces.
    let secondary: Color
    /// The ink at 42 percent, for strokes, chevrons and disabled labels
    /// only, never text a person must read.
    let faint: Color
    /// The rule between rows, a sheet's edge and a control's edge.
    let rule: Color
    let edge: Color
    let controlEdge: Color
    /// What is chosen, and its ink.
    let sky: Color
    let skyInk: Color
    /// The drawn check's colour.
    let done: Color
    /// The one small warm mark before a line that needs doing.
    let attention: Color
    let red: Color
    /// For a problem the person has to act on.
    let alert: Color
    /// The primary seat button: its face, lettering, face under the
    /// pointer and seat.
    let action: Color
    let actionText: Color
    let actionHover: Color
    let actionSeat: Color
    /// A paper seat button: its face, face under the pointer and seat.
    let paperButton: Color
    let paperButtonHover: Color
    let paperSeat: Color
    /// The keyboard focus ring.
    let ring: Color
    /// A surface over another app, and its half-point edge.
    let overPaper: Color
    let overEdge: Color

    static let day = Palette(
        isNight: false,
        ground: Color(hex: 0xEEEBE1), sheet: Color(hex: 0xF9FAF7), well: Color(hex: 0xE4E1D6),
        ink: dayInk, lead: dayInk.opacity(0.76), secondary: dayInk.opacity(0.70), faint: dayInk.opacity(0.42),
        rule: dayInk.opacity(0.14), edge: dayInk.opacity(0.26), controlEdge: dayInk.opacity(0.46),
        sky: Color(hex: 0xC7DEEC), skyInk: Color(hex: 0x2F6E99), done: Color(hex: 0x2E7550),
        attention: Color(hex: 0xE0784F), red: Color(hex: 0xDB4036), alert: Color(hex: 0xAD452E),
        action: dayInk, actionText: Color(hex: 0xF9FAF7), actionHover: Color(hex: 0x2C3A40), actionSeat: dayInk.opacity(0.42),
        paperButton: Color(hex: 0xF9FAF7), paperButtonHover: Color(hex: 0xF1F1EB), paperSeat: dayInk.opacity(0.30),
        ring: Color(hex: 0x3F7AA5), overPaper: Color(hex: 0xF9FAF7), overEdge: dayInk.opacity(0.22))

    static let night = Palette(
        isNight: true,
        ground: Color(hex: 0x141F40), sheet: Color(hex: 0x1E2E5C), well: Color(hex: 0x0E1633),
        ink: nightInk, lead: nightInk.opacity(0.76), secondary: nightInk.opacity(0.70), faint: nightInk.opacity(0.42),
        rule: nightInk.opacity(0.16), edge: nightInk.opacity(0.32), controlEdge: nightInk.opacity(0.50),
        sky: Color(hex: 0x9CC8E8).opacity(0.28), skyInk: Color(hex: 0x9CC8E8), done: Color(hex: 0x8FD3A6),
        attention: Color(hex: 0xF2D9A0), red: Color(hex: 0xF06B55), alert: Color(hex: 0xEE9B86),
        action: nightInk, actionText: Color(hex: 0x141F40), actionHover: Color(hex: 0xFFFFFF), actionSeat: Color(hex: 0x8E97A8),
        paperButton: Color(hex: 0x2B3E74), paperButtonHover: Color(hex: 0x34488A), paperSeat: Color(hex: 0x060B1F),
        ring: Color(hex: 0x9CC8E8), overPaper: Color(hex: 0x1E2E5C), overEdge: nightInk.opacity(0.42))

    private static let dayInk = Color(hex: 0x202A2E)
    private static let nightInk = Color(hex: 0xEEEFE9)

    /// Under Increase Contrast the quieter inks and the rules are raised,
    /// where they would otherwise fade into the paper.
    func contrasted(_ contrast: ColorSchemeContrast) -> Palette {
        guard contrast == .increased else { return self }
        return Palette(isNight: isNight, ground: ground, sheet: sheet, well: well, ink: ink,
                       lead: ink.opacity(0.9), secondary: ink.opacity(0.86), faint: ink.opacity(0.74),
                       rule: ink.opacity(0.34), edge: ink.opacity(0.5), controlEdge: ink.opacity(0.7),
                       sky: sky, skyInk: skyInk, done: done, attention: attention, red: red, alert: alert,
                       action: action, actionText: actionText, actionHover: actionHover, actionSeat: actionSeat,
                       paperButton: paperButton, paperButtonHover: paperButtonHover, paperSeat: paperSeat,
                       ring: ring, overPaper: overPaper, overEdge: ink.opacity(0.5))
    }
}

/// Light or Dark, as chosen in Settings. Light is the default and Dark is
/// only ever chosen: never from the system's setting or the clock.
enum Appearance: String, CaseIterable, Identifiable, Sendable {
    case light, dark

    /// A mirror of Preferences.appearance, initialized and updated by AppModel.
    @MainActor static var current: Appearance = .light {
        didSet {
            guard current != oldValue else { return }
            NotificationCenter.default.post(name: .intentionAppearanceChanged, object: nil)
        }
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var palette: Palette { self == .dark ? .night : .day }

    var colorScheme: ColorScheme { self == .dark ? .dark : .light }

    /// For a window or panel, so the system's own parts in it, such as
    /// menus, alerts and the scroll bar, match.
    var nsAppearance: NSAppearance? { NSAppearance(named: self == .dark ? .darkAqua : .aqua) }
}

extension Notification.Name {
    /// Posted on the main actor after Appearance.current changes.
    static let intentionAppearanceChanged = Notification.Name("intentionAppearanceChanged")
}

extension Color {
    /// A colour from its sRGB hex, as the spec writes them.
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

extension EnvironmentValues {
    @Entry var palette: Palette = .day
}

extension View {
    /// Draws this view and everything in it in `appearance`'s colours,
    /// raised under Increase Contrast.
    func appearance(_ appearance: Appearance) -> some View {
        modifier(AppearanceScope(appearance: appearance))
    }
}

private struct AppearanceScope: ViewModifier {
    let appearance: Appearance
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .environment(\.palette, appearance.palette.contrasted(contrast))
            .environment(\.colorScheme, appearance.colorScheme)
    }
}
