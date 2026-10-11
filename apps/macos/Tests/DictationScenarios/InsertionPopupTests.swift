import AppKit
@testable import Dictation
import SwiftUI
import Testing

/// The popup that says why a dictation's text did not go in, placed against
/// made-up screens and kept off screen.
@MainActor
@Suite(.serialized)
struct InsertionPopupTests {
    private static let laptop = CGRect(x: 0, y: 80, width: 1440, height: 795)
    private static let size = CGSize(width: 300, height: 100)

    private func popup() -> InsertionPopup {
        let popup = InsertionPopup()
        popup.showsWindow = false
        return popup
    }

    @Test func aShownPopupChangesAppearanceInPlaceAndKeepsItsHoverAndActions() async throws {
        let popup = popup()
        var look = Appearance.light
        popup.appearance = { MainActor.assertIsolated(); return look }
        var ended = 0
        popup.ended = { ended += 1 }
        var copied: [String] = []
        popup.copy = { text, _ in copied.append(text); return true }
        popup.showDraft(.fieldChanged, text: "Synthetic reply", from: .screenFoot)
        popup.hover(true)
        let host = try #require(popup.window.contentView as? NSHostingView<PopupView>)
        let frame = popup.window.frame
        look = .dark
        await AppearanceCallbackTests.offMain { popup.appearanceChanged() }
        #expect(await AppearanceCallbackTests.eventually { host.rootView.appearance == .dark })
        #expect(popup.window.appearance?.name == .darkAqua)
        #expect(popup.window.contentView === host)
        #expect(popup.window.frame == frame)
        #expect(popup.hovered)
        #expect(popup.current?.text == "Synthetic reply")
        #expect(popup.copyText())
        #expect(copied == ["Synthetic reply"])
        #expect(ended == 0)
        look = .light
        await AppearanceCallbackTests.postOffMain()
        #expect(host.rootView.appearance == .light)
        popup.hide()
        await AppearanceCallbackTests.postOffMain()
        #expect(!popup.holdsContent)
        #expect(ended == 1)
    }

    @Test func theTwoRefusalsPeopleMeetSayWhyInPlainWords() {
        #expect(InsertionPopup.words(for: .noTextField) == "Click in the message body, then try again")
        #expect(InsertionPopup.words(for: .secureField) == "This is a password field")
        for reason in [EditReason.permissionMissing, .nothingToInsert, .busy, .noTextField, .ownApp, .secureField, .targetUnresponsive,
                       .focusChanged, .fieldChanged, .pasteUnavailable, .clipboardBusy, .composeChanged, .readbackMismatch,
                       .writeUnconfirmed, .unreadableField, .appEnded, .earlierUnsettled, .earlierUnsettledNearby] {
            let words = InsertionPopup.words(for: reason)
            #expect(!words.isEmpty && words.count <= 42)
            #expect(!words.contains(reason.rawValue))
        }
    }

    /// GPT-6-Astra's second review: a field held by an earlier write that
    /// may never show stays held, so its words name what the person can
    /// do, and do not suggest waiting; a page or window held for a few
    /// seconds says to try again then.
    @Test func aRefusalForAnEarlierWriteSaysWhatToDo() {
        #expect(InsertionPopup.words(for: .earlierUnsettled) == "Last dictation here didn't show. Use Copy")
        #expect(InsertionPopup.words(for: .earlierUnsettledNearby) == "Wait a few seconds, then dictate again")
    }

    @Test func itOpensAboveTheFootCentredOnItsDot() {
        let capsule = CGRect(x: 704, y: 78, width: 32, height: 32)
        let origin = InsertionPopup.origin(of: Self.size, from: .foot(capsule), screens: [Self.laptop], pointer: .zero)
        #expect(origin.x == capsule.midX - Self.size.width / 2)
        // The card's lower edge, inside its shadow room, sits just above the dot.
        #expect(origin.y + PopupView.shadowRoom == capsule.maxY + InsertionPopup.gap)
        #expect(InsertionPopup.opening(.foot(capsule)) == .bottom)
    }

    @Test func itOpensBesideTheDotOrOnItsLeftNearTheScreensEdge() {
        let dot = CGRect(x: 400, y: 500, width: 20, height: 20)
        let right = InsertionPopup.origin(of: Self.size, from: .dot(dot), screens: [Self.laptop], pointer: .zero)
        #expect(right.x + PopupView.shadowRoom == dot.maxX + InsertionPopup.gap)
        #expect(right.y == dot.midY - Self.size.height / 2)
        #expect(InsertionPopup.opening(.dot(dot)) == .leading)
        let nearEdge = CGRect(x: 1400, y: 500, width: 20, height: 20)
        let left = InsertionPopup.origin(of: Self.size, from: .dot(nearEdge), screens: [Self.laptop], pointer: .zero)
        #expect(left.x + Self.size.width - PopupView.shadowRoom == nearEdge.minX - InsertionPopup.gap)
    }

    /// A refused reply proposal opens above the caret, the dot and the
    /// card, leaving the compose's formatting bar and Send row below the
    /// body uncovered, and below only when the screen has no room above.
    @Test func aRefusedProposalOpensAboveTheCaretAndBelowOnlyWithoutRoom() {
        let near = CGRect(x: 400, y: 300, width: 470, height: 220)
        let above = InsertionPopup.origin(of: Self.size, from: .caret(near), screens: [Self.laptop], pointer: .zero)
        #expect(above.x + PopupView.shadowRoom == near.minX)
        #expect(above.y + PopupView.shadowRoom == near.maxY + InsertionPopup.gap)
        #expect(InsertionPopup.opening(.caret(near)) == .bottomLeading)
        let top = CGRect(x: 400, y: 820, width: 30, height: 40)
        let below = InsertionPopup.origin(of: Self.size, from: .caret(top), screens: [Self.laptop], pointer: .zero)
        #expect(below.y + Self.size.height - PopupView.shadowRoom == top.minY - InsertionPopup.gap)
    }

    @Test func aRefusedProposalSaysWhatToDoAndWhyInThePersonsTerms() {
        let popup = popup()
        popup.showDraft(.fieldChanged, text: "Hi Priya,\n\nThanks,\nSam", from: .screenFoot)
        #expect(popup.current?.words == "Couldn't put it in. Copy it instead. The reply changed before it went in")
        #expect(InsertionPopup.draftWords(for: .focusChanged) == "You left the reply before it went in")
        #expect(InsertionPopup.draftWords(for: .busy) == "Intention couldn't finish putting it in")
        #expect(!InsertionPopup.draftWords(for: .composeChanged).contains("Intention typed"))
    }

    /// The popup shows what Copy puts on the clipboard: the whole draft,
    /// sign-off included, or a visible cut when it is too long, even when
    /// the cut falls at a line break, where no ellipsis would be drawn.
    @Test func thePreviewIsWhatCopyCopiesAndACutSaysSo() {
        let popup = popup()
        var copied: [String] = []
        popup.copy = { text, _ in copied.append(text); return true }
        let draft = "Hi Priya,\n\nHarbor Hall sounds right: a ten-minute walk from the office and room for all 40 of us.\n\nThanks,\nSam"
        popup.showDraft(.fieldChanged, text: draft, from: .screenFoot)
        #expect(popup.current?.text == draft)
        #expect(popup.copyText())
        #expect(copied == [draft])
        #expect(!PopupView.cuts(draft, lines: InsertionPopup.draftLines))
        // Four short lines then a sign-off: cut at the break before it.
        #expect(PopupView.cuts("One\nTwo\nThree\nFour\n\nSam", lines: 4))
        #expect(!PopupView.cuts("One\nTwo\nThree\nFour", lines: 4))
    }

    @Test func withNeitherShownItSitsAtTheFootOfThePointersScreenAndStaysOnIt() {
        let monitor = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
        let origin = InsertionPopup.origin(of: Self.size, from: .screenFoot, screens: [Self.laptop, monitor], pointer: CGPoint(x: 2000, y: 600))
        #expect(origin.x == monitor.midX - Self.size.width / 2)
        // Above where the foot's words go, clear of its dot.
        #expect(origin.y == monitor.minY + FootMark.aboveEdge + FootMark.wordsGap - PopupView.shadowRoom)
        // A dot in a screen's top corner keeps the popup on that screen.
        let corner = CGRect(x: 1425, y: 860, width: 14, height: 14)
        let kept = InsertionPopup.origin(of: Self.size, from: .dot(corner), screens: [Self.laptop], pointer: .zero)
        #expect(Self.laptop.contains(CGRect(origin: kept, size: Self.size).insetBy(dx: PopupView.shadowRoom - PopupView.placedRoom, dy: PopupView.shadowRoom - PopupView.placedRoom)))
    }

    @Test func itClosesItselfAfterAWhile() async throws {
        let popup = popup()
        var ended = 0
        popup.ended = { ended += 1 }
        popup.show(.noTextField, text: "Hello.", from: .screenFoot)
        #expect(popup.isShown)
        #expect(popup.current?.words == "Click in the message body, then try again")
        #expect(popup.current?.text == "Hello.")
        try await Task.sleep(for: .seconds(3))
        popup.appearanceChanged()
        try await Task.sleep(for: .milliseconds(1300))
        #expect(!popup.isShown)
        #expect(ended == 1)
    }

    @Test func wordsMeantForAPasswordFieldAreNotShownButCanBeCopied() {
        let popup = popup()
        var copied: [String] = []
        popup.copy = { text, _ in copied.append(text); return true }
        popup.show(.secureField, text: "hunter2 is my password", from: .screenFoot)
        #expect(popup.current?.text == InsertionPopup.hidden)
        #expect(popup.current?.text.contains("hunter2") == false)
        // An app that did not answer whether the field is secure may have
        // been showing a password field.
        popup.show(.targetUnresponsive, text: "hunter2", from: .screenFoot)
        #expect(popup.current?.text == InsertionPopup.hidden)
        // Refused for an earlier write before the field was looked at: it
        // may be a password field.
        popup.show(.earlierUnsettled, text: "hunter2", from: .screenFoot)
        #expect(popup.current?.text == InsertionPopup.hidden)
        popup.show(.earlierUnsettledNearby, text: "hunter2", from: .screenFoot)
        #expect(popup.current?.text == InsertionPopup.hidden)
        popup.show(.noTextField, text: "Hello.", from: .screenFoot)
        #expect(popup.current?.text == "Hello.")
    }

    @Test func wordsCopiedFromAMaskedPopupAreMarkedConcealedAndOthersAreNot() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("co.intention.tests.\(UUID().uuidString)"))
        let owner = PasteboardOwner(pasteboard: pasteboard, mayRead: { true })
        let popup = popup()
        popup.copy = { owner.copy($0, concealed: $1) }
        popup.show(.secureField, text: "hunter2", from: .screenFoot)
        #expect(popup.copyText())
        #expect(pasteboard.string(forType: .string) == "hunter2")
        #expect(pasteboard.types?.contains(PasteboardOwner.concealedType) == true)
        popup.show(.noTextField, text: "Hello.", from: .screenFoot)
        #expect(popup.copyText())
        #expect(pasteboard.string(forType: .string) == "Hello.")
        #expect(pasteboard.types?.contains(PasteboardOwner.concealedType) == false)
    }

    @Test func aClosedPopupKeepsNothingOfTheText() {
        let popup = popup()
        popup.show(.secureField, text: "hunter2", from: .screenFoot)
        #expect(popup.holdsContent)
        popup.hide()
        #expect(!popup.holdsContent)
        #expect(popup.current == nil)
        #expect(!popup.copyText())
    }

    @Test func itStaysWhileThePointerIsOverItAndClosesAfterItLeaves() async throws {
        let popup = popup()
        popup.show(.secureField, text: "Hello.", from: .screenFoot)
        popup.hover(true)
        try await Task.sleep(for: InsertionPopup.shown + .milliseconds(300))
        #expect(popup.isShown)
        popup.hover(false)
        try await Task.sleep(for: InsertionPopup.shown - .milliseconds(500))
        #expect(popup.isShown)
        try await Task.sleep(for: .milliseconds(800))
        #expect(!popup.isShown)
    }

    /// A dictation that came back with no words: one line naming the
    /// microphone, Retry when its audio was kept, and a way to switch the
    /// microphone. Either button closes the popup; nothing is copied.
    @Test func anEmptyDictationsPopupOffersRetryAndAnotherMicrophone() {
        let popup = popup()
        var retried: [UUID] = []
        var switched = 0
        var ended = 0
        var order: [String] = []
        popup.retry = { retried.append($0); order.append("retry") }
        popup.switchMicrophone = { switched += 1 }
        popup.ended = { ended += 1; order.append("ended") }
        let entry = UUID()
        popup.showEmpty("Heard no words from Studio Headset", retrying: entry, from: .screenFoot)
        #expect(popup.isShown)
        #expect(popup.current?.words == "Heard no words from Studio Headset")
        #expect(popup.current?.text == "")
        #expect(popup.retryEntry == entry)
        #expect(!popup.copyText())
        popup.pressRetry()
        #expect(retried == [entry])
        #expect(!popup.isShown)
        #expect(ended == 1)
        // The retry is under way before the popup's end can let a waiting
        // update install over the audio it resends.
        #expect(order == ["retry", "ended"])

        popup.showEmpty("No sound from Studio Headset", retrying: nil, from: .screenFoot)
        #expect(popup.retryEntry == nil)
        popup.pressRetry()
        #expect(retried == [entry])
        #expect(popup.isShown)
        popup.pressSwitchMicrophone()
        #expect(switched == 1)
        #expect(!popup.isShown)
        // Once it is gone its buttons do nothing.
        popup.pressSwitchMicrophone()
        #expect(switched == 1)
    }

    @Test func aNewPopupReplacesTheOldAndClosingEndsItAtOnce() {
        let popup = popup()
        var ended = 0
        popup.ended = { ended += 1 }
        popup.show(.noTextField, text: "First.", from: .screenFoot)
        popup.show(.ownApp, text: "Second.", from: .screenFoot)
        #expect(popup.current?.text == "Second.")
        popup.hide()
        #expect(!popup.isShown)
        #expect(ended == 1)
        // Hover reported after it closed does nothing.
        popup.hover(false)
        #expect(!popup.isShown)
    }
}
