import AppKit
import SwiftUI

// The entry point of the small bundle scripts/card-shots.sh builds: the
// reply proposal's card from its own sources, without the rest of the app.
// `--card-snapshots <directory>` draws it at the caret of a synthetic reply
// body, with the dot on its corner, at three field widths and once under
// reduced motion, then quits. Every name and message is invented, nothing
// is read from any app, and no window takes the keyboard or is seen.
@main
struct CardShots: GuardedRender {
    @MainActor
    static func render() {
        _ = NSApplication.shared
        let arguments = CommandLine.arguments
        SetupStyle.registerFonts()
        guard let index = arguments.firstIndex(of: "--card-snapshots"), arguments.indices.contains(index + 1) else { exit(2) }
        var failed: Bool?
        Task {
            do {
                try await render(to: URL(fileURLWithPath: arguments[index + 1]))
                failed = false
            } catch {
                FileHandle.standardError.write(Data("card snapshots failed: \(error)\n".utf8))
                failed = true
            }
        }
        while failed == nil { RunLoop.current.run(mode: .default, before: .now + 0.02) }
        exit(failed == true ? 1 : 0)
    }

    static let draft = """
        Hi Priya,

        Harbor Hall sounds right: a ten-minute walk from the office and room for all 40 of us. Before we hold it, what does it cost for the evening? Friday works for the deposit.

        Thanks,
        Sam
        """

    @MainActor
    private static func render(to directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if CommandLine.arguments.contains("--layout-proof") {
            for appearance in [Appearance.light, .dark] {
                for scale: CGFloat in [1, 2] {
                    let scene = Scene(field: 228, textWidth: 200, fades: false,
                                      keyName: "Control + Option + Shift + Command", appearance: appearance,
                                      draft: "Hi Priya,\n\nThursday works for me.\n\nSam")
                    let size = NSHostingView(rootView: scene).fittingSize
                    try await save(scene, size: size, scale: scale,
                                   to: directory.appendingPathComponent("card-keycap-\(appearance == .light ? "light" : "night")-\(Int(scale))x.png"))
                }
            }
            return
        }
        // A wide Gmail body, a narrower window, and a narrow one where the
        // key row wraps.
        let shots: [(String, CGFloat, Bool)] = [
            ("card-wide", 640, true), ("card-medium", 380, true), ("card-narrow", 250, true), ("card-reduced-motion", 640, false),
        ]
        for (name, body, fades) in shots {
            let anchor = ProposalCard.Anchor(textOrigin: .zero, bodyWidth: body,
                                             screen: CGRect(x: 0, y: 0, width: 4000, height: 4000))
            guard let width = ProposalCard.textWidth(for: anchor) else { throw CocoaError(.fileWriteUnknown) }
            let scene = Scene(field: body, textWidth: width, fades: fades)
            let size = NSHostingView(rootView: scene).fittingSize
            try await save(scene, size: CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up)),
                           to: directory.appendingPathComponent("\(name).png"))
        }
    }

    /// Draws the scene through a never-ordered hosting window.
    @MainActor
    private static func save(_ scene: some View, size: CGSize, scale: CGFloat? = nil, to file: URL) async throws {
        let host = NSHostingView(rootView: scene.frame(width: size.width, height: size.height))
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        if let screen = NSScreen.screens.max(by: { $0.backingScaleFactor < $1.backingScaleFactor }) {
            window.setFrameOrigin(CGPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2))
        }
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Let SwiftUI settle, and a fading card finish its fade.
        try await Task.sleep(for: .milliseconds(600))
        let bitmap: NSBitmapImageRep?
        if let scale {
            bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            bitmap?.size = size
        } else {
            bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        }
        guard let bitmap else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: file)
    }

    /// A white reply body `field` points wide from the caret, under a
    /// synthetic header line and with the quoted thread's grey lines below,
    /// the caret at its top left, the dot above it at full ink, and the
    /// card with its first line at the caret.
    private struct Scene: View {
        let field: CGFloat
        let textWidth: CGFloat
        let fades: Bool
        var keyName = "fn"
        var appearance = Appearance.light
        var draft = CardShots.draft
        /// The caret's left edge and top, from the scene's top left.
        static let caret = CGPoint(x: 64, y: 84)
        static let caretHeight: CGFloat = 17

        var body: some View {
            let paragraphs = ProposalCard.paragraphs(of: draft)
            let sheetWidth = textWidth + 2 * ProposalCard.sidePadding
            let width = max(Self.caret.x + field + 40, Self.caret.x - ProposalCard.sidePadding + sheetWidth + 40)
            ZStack(alignment: .topLeading) {
                (appearance == .light ? Color.white : Color(hex: 0x141F40))
                VStack(alignment: .leading, spacing: 9) {
                    RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.86)).frame(width: min(field, 220), height: 8)
                    RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.9)).frame(width: min(field, 140), height: 8)
                }
                .offset(x: Self.caret.x, y: 26)
                Rectangle().fill(Color(white: 0.85)).frame(width: field, height: 1).offset(x: Self.caret.x, y: Self.caret.y - 12)
                VStack(alignment: .leading, spacing: 9) {
                    ForEach([0.82, 0.64, 0.74, 0.5, 0.7, 0.35], id: \.self) { fraction in
                        RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.9)).frame(width: field * fraction, height: 8)
                    }
                }
                .offset(x: Self.caret.x, y: Self.caret.y + 150)
                Rectangle().fill(SetupStyle.ink).frame(width: 1.5, height: Self.caretHeight).offset(x: Self.caret.x, y: Self.caret.y)
                ProposalCardView(paragraphs: paragraphs, keyName: keyName, textWidth: textWidth, fades: fades, appearance: appearance)
                    .offset(x: Self.caret.x - ProposalCard.sidePadding - ProposalCard.shadowRoom,
                            y: Self.caret.y - ProposalCard.topPadding - ProposalCard.shadowRoom)
                let diameter: CGFloat = 12
                Path(OwnHandMark.dot(diameter: diameter).path)
                    .fill(SetupStyle.ink)
                    .frame(width: diameter, height: diameter)
                    .offset(x: Self.caret.x + 0.75 - diameter / 2, y: Self.caret.y - 3.4 - diameter)
            }
            .frame(width: width, height: 420, alignment: .topLeading)
        }
    }
}
