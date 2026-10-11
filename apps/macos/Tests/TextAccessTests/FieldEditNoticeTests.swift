import ApplicationServices
@testable import Intention
import Testing

/// Which notifications count as an edit of the watched field. Elements for
/// two processes stand in for the field and another control: creating them
/// needs no Accessibility grant and reads nothing.
struct FieldEditNoticeTests {
    private let field = AXUIElementCreateApplication(getpid())
    /// The same field, as the notification hands it in a reference of its own.
    private let sameField = AXUIElementCreateApplication(getpid())
    private let otherControl = AXUIElementCreateApplication(1)

    @Test func theWatchedFieldsTextAndSelectionChangesAreEdits() {
        #expect(FieldEditNotice.isEdit(kAXValueChangedNotification, from: sameField, watched: field))
        #expect(FieldEditNotice.isEdit(kAXSelectedTextChangedNotification, from: sameField, watched: field))
    }

    @Test func anotherControlsTextOrSelectionChangeIsNotAnEdit() {
        #expect(!FieldEditNotice.isEdit(kAXValueChangedNotification, from: otherControl, watched: field))
        #expect(!FieldEditNotice.isEdit(kAXSelectedTextChangedNotification, from: otherControl, watched: field))
    }

    @Test func nothingIsAnEditBeforeAFieldIsWatched() {
        #expect(!FieldEditNotice.isEdit(kAXValueChangedNotification, from: field, watched: nil))
    }

    @Test func theFieldsOtherNotificationsAreNotEdits() {
        #expect(!FieldEditNotice.isEdit(kAXFocusedUIElementChangedNotification, from: field, watched: field))
        #expect(!FieldEditNotice.isEdit(kAXWindowMovedNotification, from: field, watched: field))
    }
}
