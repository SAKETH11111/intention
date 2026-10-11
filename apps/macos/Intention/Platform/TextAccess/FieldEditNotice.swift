import ApplicationServices

/// Which of the followed app's notifications are an edit of the field the
/// caret tracker watches, for `CaretTracker.Observation.edit`. The tracker
/// registers text and selection notifications on the application as well
/// as on the field, so another control's change arrives too, such as
/// Gmail's search box or a list the page updates. Only the field's own
/// counts: a reply proposal ends or cancels on an edit, and a change
/// elsewhere on the page is not the person writing their reply. Chromium
/// posts a selection change on the focused editable element and on the
/// page's root, so the field's own copy still arrives.
enum FieldEditNotice {
    static func isEdit(_ name: String, from element: AXUIElement, watched: AXUIElement?) -> Bool {
        guard name == kAXValueChangedNotification || name == kAXSelectedTextChangedNotification, let watched else { return false }
        return CFEqual(element, watched)
    }
}
