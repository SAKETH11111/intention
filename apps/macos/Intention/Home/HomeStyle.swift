import AppKit
import SwiftUI

/// The main window's measures, from the approved mockups
/// (window-design/mix/build.py): a 1100 by 720 point window, an 860-point
/// column shared by the stats and the list, and the ink at a few fixed
/// strengths. Colours and typefaces are `SetupStyle`'s.
enum HomeStyle {
    static let windowSize = CGSize(width: 1100, height: 720)
    static let minimumSize = CGSize(width: 820, height: 560)
    static let column: CGFloat = 860
    /// The least room either side of the column in a narrow window.
    static let margin: CGFloat = 40
    /// The watercolour strip, and where the list starts under it.
    static let bandHeight: CGFloat = 182
    static let listTop: CGFloat = 178
    static let statsTop: CGFloat = 70
    /// A row reaches this far past the column on each side, so its words
    /// line up with the column and its hover tint does not.
    static let rowInset: CGFloat = 10
    static let timeWidth: CGFloat = 84
    static let textWidth: CGFloat = 680
    /// The room at a row's end that Copy takes under the pointer.
    static let copyRoom: CGFloat = 92
    /// The space DM Sans 14 needs between lines to stand 22 points apart.
    static let textLeading: CGFloat = 4

    /// A list row's least height, one line of words and one quiet line.
    static let rowHeight: CGFloat = 56
    /// The paper sheet the list lies on: its margin of desk on each side
    /// beyond the column, and its corners.
    static let sheetInset: CGFloat = 24

    /// The dictation key as keycaps, "fn" or "control + option" as two caps
    /// with a plus between them, drawn as one image so it sits in a line of
    /// text like a word: the spec's keycap, a paper face with an edge on its
    /// seat, in `palette`'s colours.
    @MainActor static func keycaps(_ name: String, palette: Palette = .day) -> NSImage {
        let caps = name.components(separatedBy: " + ").map {
            NSAttributedString(string: $0, attributes: [.font: dmSans(11.5, weight: 600), .foregroundColor: NSColor(palette.ink)])
        }
        let plus = NSAttributedString(string: "+", attributes: [.font: dmSans(12, weight: 500),
                                                               .foregroundColor: NSColor(palette.secondary)])
        let widths = caps.map { max(22, ceil($0.size().width) + 12) }
        let gap = ceil(plus.size().width) + 8
        let size = CGSize(width: widths.reduce(0, +) + gap * CGFloat(caps.count - 1), height: 21)
        let image = rasterImage(size: size) { _ in
            var x: CGFloat = 0
            for (index, cap) in caps.enumerated() {
                if index > 0 {
                    plus.draw(at: CGPoint(x: x + (gap - plus.size().width) / 2, y: 1 + (20 - plus.size().height) / 2))
                    x += gap
                }
                // The key's seat, then its face a point and a half above it.
                let face = CGRect(x: x + 0.25, y: 1.75, width: widths[index] - 0.5, height: 19)
                NSColor(palette.paperSeat).setFill()
                NSBezierPath(roundedRect: face.offsetBy(dx: 0, dy: -1.5), xRadius: 5, yRadius: 5).fill()
                NSColor(palette.paperButton).setFill()
                let outline = NSBezierPath(roundedRect: face, xRadius: 5, yRadius: 5)
                outline.fill()
                NSColor(palette.controlEdge).setStroke()
                outline.lineWidth = 0.5
                outline.stroke()
                let text = cap.size()
                cap.draw(at: CGPoint(x: x + (widths[index] - text.width) / 2, y: 1 + (20 - text.height) / 2))
                x += widths[index]
            }
        }
        image.accessibilityDescription = name
        return image
    }

    /// Draw eagerly at Retina resolution. The returned image has pixels,
    /// so AppKit can read it on any thread without calling actor-bound code.
    @MainActor private static func rasterImage(size: CGSize, draw: (CGRect) -> Void) -> NSImage {
        let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * 2)),
                                      pixelsHigh: Int(ceil(size.height * 2)), bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        // AppKit derives the point-to-pixel transform from this size when
        // creating the context. Applying another backing scale clips the label.
        pixels.size = size
        let context = NSGraphicsContext(bitmapImageRep: pixels)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw(CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(pixels)
        return image
    }

    /// DM Sans at a weight on its variable axis, for text drawn by AppKit
    /// into an image; SwiftUI text uses `SetupStyle.text`.
    static func dmSans(_ size: CGFloat, weight: CGFloat) -> NSFont {
        SetupStyle.registerFonts()
        guard let regular = NSFont(name: "DM Sans", size: size) else { return .systemFont(ofSize: size, weight: .semibold) }
        let axis = 0x7767_6874 // 'wght'
        let descriptor = regular.fontDescriptor.addingAttributes([.variation: [axis: weight]])
        return NSFont(descriptor: descriptor, size: size) ?? regular
    }
}
