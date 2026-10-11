import AppKit
@testable import Dictation
import Testing

/// Independent placement oracles from main 041ad403, with its 12-point
/// popup/notice room and 10-point caption room. Compare the same visible
/// size after the new windows add transparent space on each side. Since
/// #486 the foot dot rests 26 points above the Dock or the screen's edge,
/// the listening sun's whole radius, where it rested 14 and 22 before.
@MainActor
struct OverAppPlacementTests {
    private let screens = [FootPlacementTests.laptop, FootPlacementTests.monitor]

    @Test func popupsKeepMainsPlacementForEveryAnchorAndScreenEdge() {
        let size = CGSize(width: 404, height: 180)
        let extra: CGFloat = PopupView.shadowRoom - 12
        let window = CGSize(width: size.width + 2 * extra, height: size.height + 2 * extra)
        let marks = [CGRect(x: 704, y: 78, width: 32, height: 32), CGRect(x: 400, y: 500, width: 20, height: 20),
                     CGRect(x: 1400, y: 500, width: 20, height: 20), CGRect(x: 1425, y: 860, width: 14, height: 14),
                     CGRect(x: 0, y: 80, width: 14, height: 14), CGRect(x: 400, y: 820, width: 30, height: 40),
                     CGRect(x: 1900, y: 800, width: 20, height: 20)]
        let anchors = marks.flatMap { [InsertionPopup.Anchor.foot($0), .dot($0), .caret($0)] } + [.screenFoot]
        for pointer in [CGPoint(x: 700, y: 400), CGPoint(x: 2000, y: 600)] {
            for anchor in anchors {
                let origin = InsertionPopup.origin(of: window, from: anchor, screens: screens.map(\.usable), pointer: pointer)
                let newVisible = CGRect(origin: origin, size: window).insetBy(dx: PopupView.shadowRoom, dy: PopupView.shadowRoom)
                let oldVisible = CGRect(origin: mainPopupOrigin(size, anchor, pointer), size: size).insetBy(dx: 12, dy: 12)
                #expect(newVisible == oldVisible)
            }
        }
    }

    private func mainPopupOrigin(_ size: CGSize, _ anchor: InsertionPopup.Anchor, _ pointer: CGPoint) -> CGPoint {
        func usable(_ point: CGPoint) -> CGRect {
            screens.first { $0.usable.insetBy(dx: -1, dy: -1).contains(point) }?.usable ?? screens[0].usable
        }
        func clamp(_ point: CGPoint, _ screen: CGRect) -> CGPoint {
            CGPoint(x: min(max(point.x, screen.minX), screen.maxX - size.width).rounded(),
                    y: min(max(point.y, screen.minY), screen.maxY - size.height).rounded())
        }
        switch anchor {
        case let .foot(dot):
            return clamp(CGPoint(x: dot.midX - size.width / 2, y: dot.maxY + 6 - 12), usable(CGPoint(x: dot.midX, y: dot.midY)))
        case let .dot(mark):
            let screen = usable(CGPoint(x: mark.midX, y: mark.midY))
            let right = mark.maxX + 6 - 12
            let x = right + size.width <= screen.maxX ? right : mark.minX - 6 + 12 - size.width
            return clamp(CGPoint(x: x, y: mark.midY - size.height / 2), screen)
        case .screenFoot:
            let screen = usable(pointer)
            return clamp(CGPoint(x: screen.midX - size.width / 2, y: screen.minY + 26 + 20 - 12), screen)
        case let .caret(near):
            let screen = usable(CGPoint(x: near.minX, y: near.midY))
            let above = near.maxY + 6 - 12
            let y = above + size.height <= screen.maxY ? above : near.minY - 6 + 12 - size.height
            return clamp(CGPoint(x: near.minX - 12, y: y), screen)
        }
    }

    @Test func captionsKeepMainsPlacementBesideTheDotAndAtScreenEdges() {
        let size = CGSize(width: 240, height: 48)
        let extra: CGFloat = DotCaption.shadowRoom - 10
        let window = CGSize(width: size.width + 2 * extra, height: size.height + 2 * extra)
        for screen in screens.map(\.usable) {
            // Half points, where rounding before or after taking off the
            // extra room would differ, as Sol's review found at x 0.5.
            for center in [CGPoint(x: screen.midX, y: screen.midY), CGPoint(x: screen.maxX - 8, y: screen.maxY - 8),
                           CGPoint(x: screen.minX, y: screen.minY), CGPoint(x: screen.minX + 0.5, y: screen.midY + 0.5),
                           CGPoint(x: screen.midX - 0.5, y: screen.minY + 24.5)] {
                let dot = DotPlacement.Dot(center: center, diameter: 12)
                var x = center.x + 6 + 8 - 10
                if x + size.width - 10 > screen.maxX { x = center.x - 6 - 8 + 10 - size.width }
                x = max(screen.minX - 10, x)
                let y = min(max(screen.minY, center.y - size.height / 2), screen.maxY - size.height)
                let old = CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height).insetBy(dx: 10, dy: 10)
                let new = DotCaption.frame(of: window, beside: dot, on: screen).insetBy(dx: DotCaption.shadowRoom, dy: DotCaption.shadowRoom)
                #expect(new == old)
            }
        }
    }

    @Test func aCaptionWithoutADotStartsAtTheDotsLeftAndStaysOnScreen() {
        let size = CGSize(width: 280 + 2 * DotCaption.shadowRoom, height: 28 + 2 * DotCaption.shadowRoom)
        for screen in screens.map(\.usable) {
            let center = CGPoint(x: screen.midX, y: screen.midY)
            let dot = DotPlacement.Dot(center: center, diameter: 12)
            let label = DotCaption.frame(of: size, alignedWith: dot, on: screen)
                .insetBy(dx: DotCaption.shadowRoom, dy: DotCaption.shadowRoom)
            #expect(label.minX == center.x - 6)
            // Its foot on the dot's, above the caret's line.
            #expect(abs(label.minY - (center.y - 6)) <= 0.5)
            for edge in [CGPoint(x: screen.minX, y: screen.minY), CGPoint(x: screen.maxX, y: screen.maxY)] {
                let visible = DotCaption.frame(of: size, alignedWith: .init(center: edge, diameter: 12), on: screen)
                    .insetBy(dx: DotCaption.shadowRoom, dy: DotCaption.shadowRoom)
                #expect(screen.contains(visible))
            }
        }
    }

    @Test func noticesKeepMainsPlacementBesideTheDotAndAtTheFoot() {
        let size = CGSize(width: 280, height: 56)
        for pointer in [CGPoint(x: 700, y: 400), CGPoint(x: 2000, y: 600)] {
            let marks: [CGRect?] = [nil, CGRect(x: 400, y: 500, width: 20, height: 20), CGRect(x: 1400, y: 860, width: 20, height: 20),
                                   CGRect(x: 10, y: 80, width: 20, height: 20), CGRect(x: 1900, y: 800, width: 20, height: 20)]
            for mark in marks {
                let expected: CGPoint
                if let mark, let screen = screens.first(where: { $0.frame.intersects(mark) })?.usable {
                    let y = min(max(mark.midY - size.height / 2, screen.minY), screen.maxY - size.height)
                    let right = mark.maxX + 4 - 12
                    let x = right + size.width <= screen.maxX ? right : mark.minX - 4 + 12 - size.width
                    expected = CGPoint(x: x, y: y)
                } else {
                    let screen = screens.first { $0.frame.contains(pointer) } ?? screens[0]
                    let y = screen.usable.minY + 26 + 20 - 12
                    expected = CGPoint(x: (screen.usable.midX - size.width / 2).rounded(), y: y)
                }
                let actual = DotNotice.origin(of: size, beside: mark, screens: screens, pointer: pointer)
                // show grows this old placement by the extra transparent room.
                let extra = NoticeCapsule.shadowRoom - 12
                let grown = CGRect(x: actual.x - extra, y: actual.y - extra, width: size.width + 2 * extra, height: size.height + 2 * extra)
                #expect(grown.insetBy(dx: NoticeCapsule.shadowRoom, dy: NoticeCapsule.shadowRoom) == CGRect(origin: expected, size: size).insetBy(dx: 12, dy: 12))
            }
        }
    }
}
