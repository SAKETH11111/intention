import Foundation

/// Visible text pixels need an explicit viewport when the accessible text
/// area includes offscreen content, as Terminal's scrollback does.
enum CaretFieldBounds {
    static func visible(field: CGRect, window: CGRect, scrollViewports: [CGRect]) -> CGRect? {
        guard finite(field), finite(window) else { return nil }
        var visible = field
        for viewport in scrollViewports {
            guard finite(viewport) else { return nil }
            visible = visible.intersection(viewport)
        }
        // A window alone cannot identify a scrolled field's viewport. Require
        // an enclosing scroll area before admitting a partially visible field.
        guard window.contains(field) || !scrollViewports.isEmpty else { return nil }
        visible = visible.intersection(window)
        guard finite(visible), visible.width >= 4, visible.height >= 8 else { return nil }
        return visible
    }

    private static func finite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0
    }
}
