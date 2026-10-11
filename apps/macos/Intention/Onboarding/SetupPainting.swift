import AppKit
import SwiftUI

/// Where the painting stands and how much light it has: the state the setup
/// window's walk and its two passages of light animate. Every field is a
/// number SwiftUI interpolates, so the painting holds no timing of its own.
struct SetupLight: Equatable {
    /// How far along the painting the view has walked, in the far layer's
    /// points.
    var walk: CGFloat = 0
    /// How much of the pre-dawn veil is left, from 0 to 1.
    var dusk: Double = 0.9
    /// First light along the ridge, from the first dictation on.
    var first: Double = 0
    /// The sun clearing the ridge, from the first email on.
    var rise: Double = 0
    /// The risen sun's wash in the sky.
    var wash: Double = 0
    /// The risen sun's light on everything, and how far down it has come.
    var warm: Double = 0
    var beam: Double = 0
    /// The sun gathering its light as setup ends, from 1 to 1.12.
    var glow: Double = 1

    /// Where each page stands along the painting and how much of the blue
    /// hour is left there; first light and the sunrise take the rest away.
    static func at(_ page: SetupPage) -> (walk: CGFloat, dusk: Double) {
        switch page {
        case .signIn: (0, 0.9)
        case .mail: (330, 0.85)
        case .permissions: (520, 0.8)
        case .shortcut: (700, 0.75)
        case .tryIt: (880, 0.7)
        case .reply: (1182, 0.32)
        case .openAtLogin: (1182, 0)
        }
    }
}

/// The pages the window shows, in order. Done shows whichever page ended
/// setup until the window closes.
enum SetupPage: Int, Comparable {
    case signIn, mail, permissions, shortcut, tryIt, reply, openAtLogin

    init?(_ step: OnboardingModel.Step) {
        switch step {
        case .signIn: self = .signIn
        case .permissions: self = .permissions
        case .shortcut: self = .shortcut
        case .tryIt: self = .tryIt
        case .mail: self = .mail
        case .reply: self = .reply
        case .openAtLogin: self = .openAtLogin
        case .done: return nil
        }
    }

    static func < (left: SetupPage, right: SetupPage) -> Bool { left.rawValue < right.rawValue }
}

/// The painting behind every page, edge to edge under the title bar, in
/// layers that walk at their own speeds: the sky at 0.6 of the walk, the
/// hills with the light and the sun at the walk's own pace, and the foreground
/// band in front at 1.8 of it. Over them lie the pre-dawn veil, the desk the
/// foreground softens into under the actions, and the risen sun's warmth. The
/// sun is the foot mark's own disc, so the object that rises is the
/// one that flies to the foot when setup ends.
struct SetupPainting: View {
    let light: SetupLight
    /// Hidden while the sun flies out of the window as setup ends.
    var sunLifted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Painting pixels to far-layer points: the panorama is drawn 900 tall.
    static let k: CGFloat = 900 / 1188
    /// The far layer's top, above the window, so the hills sit just above
    /// the sheet and the sun rises in the open sky under the lead.
    static let farTop: CGFloat = -250
    static let farSize = CGSize(width: 1818, height: 900)
    /// The sun's diameter, with its bloom.
    static let disc: CGFloat = 92
    /// Where the sun stands in the far layer, and the ridge under it.
    static let sunX: CGFloat = 1917 * k
    static let ridge: CGFloat = 773 * k
    /// The front layer's file starts at this row of the panorama; the sky
    /// above it is the sky layer's.
    private static let frontTop: CGFloat = 720

    /// The sun's centre in the far layer: hidden behind the ridge at 0, its
    /// lower edge clear of the hills at 1.
    static func sunCentre(rise: Double) -> CGPoint {
        let r = disc * 0.35
        let hidden = ridge + r + 4, up = ridge - r - 16
        return CGPoint(x: sunX, y: hidden + (up - hidden) * rise)
    }

    /// The sun's frame in the window, from its top left.
    static func sunFrame(_ light: SetupLight) -> CGRect {
        let centre = sunCentre(rise: light.rise)
        return CGRect(x: centre.x - light.walk - disc / 2, y: farTop + centre.y - disc / 2, width: disc, height: disc)
    }

    var body: some View {
        let size = OnboardingView.size
        ZStack(alignment: .topLeading) {
            // The sky, at 0.7 of the far layer's scale, anchored so its
            // horizon row stays on the ridge.
            Image(nsImage: Art.sky)
                .resizable()
                .frame(width: Self.farSize.width * 0.7, height: Self.farSize.height * 0.7)
                .offset(x: -light.walk * 0.6, y: -75)
            far
            meadow
            // The pre-dawn veil, pale by day.
            LinearGradient(stops: [.init(color: Color(hex: 0xD3DCEC), location: 0), .init(color: Color(hex: 0xDCE2EE), location: 0.45),
                                   .init(color: Color(hex: 0xE4E6EC), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .blendMode(.multiply)
                .opacity(light.dusk)
            // The desk under the actions.
            LinearGradient(stops: [.init(color: SetupStyle.ground.opacity(0), location: 0),
                                   .init(color: SetupStyle.ground.opacity(0.7), location: 0.45),
                                   .init(color: SetupStyle.ground, location: 0.78)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: size.width, height: 150)
                .offset(y: size.height - 150)
            WarmLight(beam: light.beam)
                .blendMode(.softLight)
                .opacity(light.warm)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The far layer: the light and the sun behind the hills, the hills in
    /// front of them, all at the walk's own pace.
    private var far: some View {
        let k = Self.k
        let centre = Self.sunCentre(rise: light.rise)
        let risen = Self.sunCentre(rise: 1).y
        // Under Reduce Motion the light changes by crossfade only.
        let still = reduceMotion
        return ZStack(alignment: .topLeading) {
            // First light sits on the ridge a little left of where the sun
            // will rise, so it is inside the window on the dictation page,
            // and grows in from the right, where the walk is going.
            Image(nsImage: Art.firstLight)
                .resizable()
                .frame(width: 900, height: 230)
                .scaleEffect(x: still ? 1 : 0.45 + 0.55 * light.first, y: still ? 1 : 0.8 + 0.2 * light.first,
                             anchor: UnitPoint(x: 1, y: 0.6))
                .blendMode(.multiply)
                .opacity(light.first * 0.62)
                .offset(x: 1390 - 450, y: Self.ridge - 150)
            Image(nsImage: Art.wash)
                .resizable()
                .frame(width: 440, height: 440)
                .scaleEffect(still ? 1 : 0.7 + 0.3 * min(1, light.wash * 1.3))
                .blendMode(.multiply)
                .opacity(light.wash * 0.5)
                .offset(x: Self.sunX - 220, y: risen - 220)
            Image(nsImage: Art.sun)
                .resizable()
                .frame(width: Self.disc, height: Self.disc)
                .brightness((light.glow - 1) * 0.5)
                .saturation(1 + (light.glow - 1) * 0.42)
                .opacity(sunLifted ? 0 : 1)
                .offset(x: Self.sunX - Self.disc / 2, y: centre.y - Self.disc / 2)
            Image(nsImage: Art.front)
                .resizable()
                .frame(width: Self.farSize.width, height: (1188 - Self.frontTop) * k)
                .offset(y: Self.frontTop * k)
        }
        .frame(width: Self.farSize.width, height: Self.farSize.height, alignment: .topLeading)
        .offset(x: -light.walk, y: Self.farTop)
    }

    /// The foreground band: the panorama's foot at 1.14 of its scale, its
    /// top 46 points faded into the hills.
    private var meadow: some View {
        Image(nsImage: Art.meadow)
            .resizable()
            .frame(width: 2727, height: 240 * 1350 / 1188)
            .frame(width: 2727, height: 270, alignment: .bottom)
            .clipped()
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 46.0 / 270)],
                                 startPoint: .top, endPoint: .bottom))
            .offset(x: -light.walk * 1.8, y: OnboardingView.size.height - 270)
    }

    /// The risen sun's light, from above the sheet, coming down as it
    /// rises: an ellipse 1.2 of the window wide and 0.7 of it tall whose
    /// centre moves from 34% to 64% of the window's height.
    private struct WarmLight: View, Animatable {
        var beam: Double

        nonisolated var animatableData: Double {
            get { beam }
            set { beam = newValue }
        }

        var body: some View {
            let size = OnboardingView.size
            let colour = Color(.sRGB, red: 1, green: 196 / 255, blue: 140 / 255)
            EllipticalGradient(stops: [.init(color: colour.opacity(0.75), location: 0), .init(color: colour.opacity(0.25), location: 0.55),
                                       .init(color: colour.opacity(0), location: 0.8)])
                .frame(width: size.width * 2.4, height: size.height * 1.4)
                .position(x: size.width / 2, y: size.height * (0.34 + 0.30 * beam))
                .frame(width: size.width, height: size.height)
        }
    }

    /// The background's layers, loaded once: drawn as one panorama, the
    /// sky left open and the bands given an alpha edge, so
    /// the sun can rise behind them.
    @MainActor
    enum Art {
        static let sky = image("SetupSky")
        static let front = image("SetupFront")
        static let meadow = image("SetupMeadow")
        static let firstLight = image("SetupFirstLight")
        static let wash = image("SetupSunWash")
        /// The foot mark's gradient sun at the window's size.
        static let sun = image("SetupSun")

        private static func image(_ name: String) -> NSImage { SetupStyle.image(name, "webp") }
    }
}
