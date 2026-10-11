import SwiftUI

/// The main window's small line icons, drawn from the design's own 16-point
/// strokes so they sit with DM Sans the way the mockups show, rather than
/// SF Symbols, whose weight and corners differ. Each takes the colour of
/// the text around it.
struct WindowIcon: View {
    enum Name {
        case search, copy, chevronRight, gear, upDown, plus, microphone
    }

    let name: Name
    var size: CGFloat = 14

    var body: some View {
        Stroke(name: name)
            .stroke(style: StrokeStyle(lineWidth: 1.5 * size / 16, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private struct Stroke: Shape {
        let name: Name

        func path(in rect: CGRect) -> Path {
            var path = Path()
            switch name {
            case .search:
                path.addEllipse(in: CGRect(x: 2.25, y: 2.25, width: 9.5, height: 9.5))
                path.move(to: CGPoint(x: 10.5, y: 10.5))
                path.addLine(to: CGPoint(x: 14, y: 14))
            case .copy:
                path.addRoundedRect(in: CGRect(x: 5.25, y: 5.25, width: 8.5, height: 8.5), cornerSize: CGSize(width: 2, height: 2))
                path.move(to: CGPoint(x: 10.75, y: 5.25))
                path.addLine(to: CGPoint(x: 10.75, y: 3.75))
                path.addArc(tangent1End: CGPoint(x: 10.75, y: 2.25), tangent2End: CGPoint(x: 9.25, y: 2.25), radius: 1.5)
                path.addLine(to: CGPoint(x: 3.75, y: 2.25))
                path.addArc(tangent1End: CGPoint(x: 2.25, y: 2.25), tangent2End: CGPoint(x: 2.25, y: 3.75), radius: 1.5)
                path.addLine(to: CGPoint(x: 2.25, y: 9.25))
                path.addArc(tangent1End: CGPoint(x: 2.25, y: 10.75), tangent2End: CGPoint(x: 3.75, y: 10.75), radius: 1.5)
                path.addLine(to: CGPoint(x: 5.25, y: 10.75))
            case .chevronRight:
                path.addLines([CGPoint(x: 6.5, y: 4.5), CGPoint(x: 10, y: 8), CGPoint(x: 6.5, y: 11.5)])
            case .gear:
                path.addLines([(6.9, 1.9), (9.1, 1.9), (9.45, 3.6), (10.65, 4.3), (12.3, 3.75), (13.4, 5.65), (12.1, 6.8),
                               (12.1, 8.2), (13.4, 9.35), (12.3, 11.25), (10.65, 10.7), (9.45, 11.4), (9.1, 13.1), (6.9, 13.1),
                               (6.55, 11.4), (5.35, 10.7), (3.7, 11.25), (2.6, 9.35), (3.9, 8.2), (3.9, 7.3), (2.6, 6.15),
                               (3.7, 4.25), (5.35, 4.8), (6.55, 4.1)].map { CGPoint(x: $0.0, y: $0.1) })
                path.closeSubpath()
                path.addEllipse(in: CGRect(x: 6.1, y: 6.1, width: 3.8, height: 3.8))
            case .upDown:
                path.addLines([CGPoint(x: 5, y: 6), CGPoint(x: 8, y: 3), CGPoint(x: 11, y: 6)])
                path.move(to: CGPoint(x: 5, y: 10))
                path.addLines([CGPoint(x: 5, y: 10), CGPoint(x: 8, y: 13), CGPoint(x: 11, y: 10)])
            case .plus:
                path.move(to: CGPoint(x: 8, y: 3.25))
                path.addLine(to: CGPoint(x: 8, y: 12.75))
                path.move(to: CGPoint(x: 3.25, y: 8))
                path.addLine(to: CGPoint(x: 12.75, y: 8))
            case .microphone:
                path.addRoundedRect(in: CGRect(x: 5.75, y: 1.75, width: 4.5, height: 8), cornerSize: CGSize(width: 2.25, height: 2.25))
                path.move(to: CGPoint(x: 3.25, y: 7.75))
                path.addArc(center: CGPoint(x: 8, y: 7.75), radius: 4.75, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
                path.move(to: CGPoint(x: 8, y: 12.5))
                path.addLine(to: CGPoint(x: 8, y: 14.25))
            }
            return path.applying(CGAffineTransform(scaleX: rect.width / 16, y: rect.height / 16).translatedBy(x: rect.minX, y: rect.minY))
        }
    }
}
