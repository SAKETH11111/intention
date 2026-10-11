import CoreGraphics

/// Fallible AX search geometry. Anchors invalidate temporal evidence when
/// geometry changes; they never authorize a caret from a static stroke.
struct CaretSearchAnchor: Equatable, Sendable {
    enum Source: Sendable { case textRange, textMarker }
    let bounds: CGRect
    let source: Source
}
