import ApplicationServices

/// A capture boundary established by Accessibility, never by a guessed
/// rectangle or a whole-display screenshot. AX objects stay on its executor.
struct VisualCaretTarget: Equatable, @unchecked Sendable {
    let pid: pid_t
    let element: AXElement
    let window: AXElement
    let field: CGRect
    let windowFrame: CGRect
    let selection: FieldRange?
    var anchors: [CaretSearchAnchor] = []
    /// The field has no text of its own; any text is its placeholder.
    var empty = false
    /// System uptime when the field gained focus, while apps draw a caret
    /// solid. Neither this nor `empty` is part of the capture boundary.
    var focusedAt: TimeInterval = 0
    /// The window of an app that exposes no accessible text at all, as
    /// Codex's does: the window is the boundary, and capture looks for the
    /// caret only in a band around recent input, see `VisualCaretCapture`.
    private(set) var opaque = false

    static func opaque(window: AXElement, pid: pid_t, frame: CGRect, focusedAt: TimeInterval) -> Self {
        var target = Self(pid: pid, element: window, window: window, field: frame, windowFrame: frame, selection: nil)
        target.opaque = true
        target.focusedAt = focusedAt
        return target
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pid == rhs.pid && lhs.element.sameElement(as: rhs.element)
            && lhs.window.sameElement(as: rhs.window) && lhs.field == rhs.field
            && lhs.windowFrame == rhs.windowFrame && lhs.selection == rhs.selection && lhs.anchors == rhs.anchors
            && lhs.opaque == rhs.opaque
    }

    /// The same capture boundary: process, element, window and frames. A
    /// changed selection or anchor within it is not a new boundary.
    func sameBoundary(as other: Self) -> Bool {
        pid == other.pid && element.sameElement(as: other.element) && window.sameElement(as: other.window)
            && field == other.field && windowFrame == other.windowFrame && opaque == other.opaque
    }

    private static func notSecure(_ element: AXElement, ancestor: Bool = false) -> Bool {
        switch element.value(kAXSubroleAttribute) {
        case let .success(value):
            guard CFGetTypeID(value) == CFStringGetTypeID() else { return false }
            return (value as! String) != kAXSecureTextFieldSubrole
        case let .failure(error):
            return error.code == .attributeUnsupported || error.code == .noValue || (ancestor && error.code == .failure)
        }
    }

    /// Called only on AccessibilityExecutor. Unknown roles and missing field
    /// bounds deny capture, including canvas surfaces with no accessible field.
    /// `admitted` means the caller's own walk of this element's ancestors
    /// already refused unsupported metadata. Secure subroles are read again
    /// on every call, on the field and on each ancestor, since a wrapper can
    /// turn secure in place.
    static func read(_ focused: AXElement, pid: pid_t, admitted: Bool = false) -> Self? {
        guard admitted || AXWritingSurface.admission(focused, pid: pid) == .allowed, notSecure(focused),
              let role = try? focused.string(kAXRoleAttribute).get(),
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role),
              let control = try? focused.frame().get(),
              control.width.isFinite, control.height.isFinite, control.minX.isFinite, control.minY.isFinite,
              let window = try? focused.element(kAXWindowAttribute).get(),
              let windowFrame = try? window.frame().get()
        else { return nil }
        // A control a point wide and a line tall, as Monaco's text area is at
        // the caret, holds no pixels of its own: the caret is looked for in
        // a band around it, five lines tall and 150 points to either side,
        // inside the nearest element of the control's own ancestry at least
        // 60 by 24 points, its editor. Any other control is its own boundary.
        let narrow = CaretBounds.caretFromControlFrame(control) != nil
        // A control with a width and no height, as Gmail's empty compose
        // body: the caret is looked for in a band a hundred points below
        // its top edge, inside its editor the same way.
        let flat = !narrow && CaretBounds.flatControlLine(control) != nil
        // Check ancestors too: some controls put the secure subrole on a
        // wrapper. Failure to reach the declared window denies capture.
        var ancestor = focused
        var viewports: [CGRect] = []
        var editor: CGRect?
        for _ in 0..<40 {
            guard notSecure(ancestor, ancestor: !ancestor.sameElement(as: focused)) else { return nil }
            if ancestor.sameElement(as: window) {
                let field: CGRect
                if narrow || flat {
                    guard let editor else { return nil }
                    field = narrow ? CaretBounds.controlBand(around: control, within: editor) : CaretBounds.flatControlBand(below: control, within: editor)
                } else {
                    field = control
                }
                guard field.width >= 4, field.height >= 8,
                      let visibleField = CaretFieldBounds.visible(field: field, window: windowFrame, scrollViewports: viewports) else { return nil }
                let selection: FieldRange?
                switch focused.range(kAXSelectedTextRangeAttribute) {
                case let .success(range):
                    guard range.location >= 0, range.length == 0 else { return nil }
                    selection = range
                case let .failure(error) where error.code == .attributeUnsupported || error.code == .noValue:
                    selection = nil
                default: return nil
                }
                // Text laid out inside a one-point or a flat box anchors nothing.
                let anchors = narrow || flat ? [] : CaretBounds.anchors(in: focused, at: selection?.location)
                return Self(pid: pid, element: focused, window: window, field: visibleField,
                            windowFrame: windowFrame, selection: selection, anchors: anchors)
            }
            guard let role = try? ancestor.string(kAXRoleAttribute).get() else { return nil }
            if role == kAXScrollAreaRole {
                guard let viewport = try? ancestor.frame().get() else { return nil }
                viewports.append(viewport)
            }
            if narrow || flat, editor == nil, !ancestor.sameElement(as: focused), let frame = try? ancestor.frame().get(),
               frame.width >= 60, frame.height >= 24, frame.contains(CGPoint(x: control.minX + 1, y: control.minY)) {
                editor = frame
            }
            guard let parent = try? ancestor.element(kAXParentAttribute).get() else { return nil }
            ancestor = parent
        }
        return nil
    }
}
