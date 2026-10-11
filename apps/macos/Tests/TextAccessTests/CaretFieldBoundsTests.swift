@testable import Intention
import CoreGraphics
import Testing

struct CaretFieldBoundsTests {
    private let window = CGRect(x: 0, y: 38, width: 521, height: 356)
    private let terminal = CGRect(x: 0, y: -238.203125, width: 504, height: 632.203125)
    private let viewport = CGRect(x: 0, y: 66, width: 504, height: 328)

    @Test func scrollbackUsesOnlyTheVisibleTextViewport() {
        #expect(CaretFieldBounds.visible(field: terminal, window: window, scrollViewports: [viewport]) == viewport)
    }

    @Test func nestedScrollViewsIntersectWithoutExpandingCapture() {
        let outer = CGRect(x: 0, y: 70, width: 400, height: 300)
        let inner = CGRect(x: 20, y: 50, width: 500, height: 250)
        #expect(CaretFieldBounds.visible(field: terminal, window: window, scrollViewports: [outer, inner]) == CGRect(x: 20, y: 70, width: 380, height: 230))
    }

    @Test func missingOrInvalidViewportDoesNotPermitOffscreenFields() {
        #expect(CaretFieldBounds.visible(field: terminal, window: window, scrollViewports: []) == nil)
        #expect(CaretFieldBounds.visible(field: terminal, window: window, scrollViewports: [.null]) == nil)
        #expect(CaretFieldBounds.visible(field: terminal, window: window, scrollViewports: [CGRect(x: 0, y: 0, width: 1, height: 1)]) == nil)
    }

    @Test func ordinaryFieldsKeepTheirExactFractionalBounds() {
        let field = CGRect(x: 20.25, y: 100.5, width: 220.5, height: 80.25)
        #expect(CaretFieldBounds.visible(field: field, window: window, scrollViewports: []) == field)
    }
}
