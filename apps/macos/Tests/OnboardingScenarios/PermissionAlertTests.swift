// AppKit rather than Foundation: the Command Line Tools cannot load the
// overlay that importing Foundation beside Testing asks for.
import AppKit
@testable import Onboarding
import Testing

/// Who opens System Settings after Intention asks for a permission, from
/// made-up window lists and looks at the screen. No request is made of
/// macOS and the real window list is never read.
@Suite
struct PermissionAlertTests {
    private static func alert(_ number: CGWindowID, layer: Int = 0) -> PermissionAlert.Window {
        PermissionAlert.Window(owner: "universalAccessAuthWarn", layer: layer, number: number)
    }

    private static func window(_ owner: String?, layer: Int = 0) -> PermissionAlert.Window {
        PermissionAlert.Window(owner: owner, layer: layer, number: 7)
    }

    // MARK: Whether the alert is in front

    @Test func theAlertCountsWhenItIsTheFrontmostOrdinaryWindow() {
        // As observed when nothing else was opened: the alert, then the
        // windows that were there before it.
        #expect(PermissionAlert.inFront([Self.alert(41), Self.window("Intention"), Self.window("Finder")]) == 41)
        // The menu bar and Intention's dot are listed first, on higher layers.
        #expect(PermissionAlert.inFront([Self.window("Window Server", layer: 24), Self.window("Intention", layer: 25),
                                         Self.alert(41), Self.window("Finder")]) == 41)
    }

    @Test func anAlertBehindAnotherWindowDoesNotCount() {
        // As observed when Intention opened the page as well: System Settings
        // came in front of the alert and covered it.
        #expect(PermissionAlert.inFront([Self.window("System Settings"), Self.alert(41), Self.window("Finder")]) == nil)
        // A window that names no owner is still a window in front of it.
        #expect(PermissionAlert.inFront([Self.window(nil), Self.alert(41)]) == nil)
    }

    @Test func nothingElseIsTakenForTheAlert() {
        #expect(PermissionAlert.inFront([]) == nil)
        #expect(PermissionAlert.inFront([Self.window("Finder")]) == nil)
        // Another process whose name only starts the same way.
        #expect(PermissionAlert.inFront([Self.window("universalAccessAuthWarnHelper")]) == nil)
        #expect(PermissionAlert.inFront([Self.window("UniversalAccessAuthWarn")]) == nil)
        // A window of the alert's process on another layer is not the
        // ordinary window that was observed, and the window under it is
        // the frontmost ordinary one.
        #expect(PermissionAlert.inFront([Self.alert(41, layer: 3), Self.window("Finder")]) == nil)
        // An alert whose number cannot be read cannot be told from the one
        // before, so it does not count.
        #expect(PermissionAlert.inFront([PermissionAlert.Window(owner: "universalAccessAuthWarn", layer: 0, number: nil)]) == nil)
    }

    // MARK: What to do after a look

    @Test func theWatchLastsOneAndAHalfSeconds() {
        #expect(PermissionAlert.watch == .milliseconds(1500))
    }

    @Test func anAlertThatCameInFrontSinceAskingIsLeftAlone() {
        #expect(PermissionAlert.step(inFrontBefore: nil, inFrontNow: 41, waited: .milliseconds(900)) == .leaveToAlert)
        #expect(PermissionAlert.step(inFrontBefore: nil, inFrontNow: 41, waited: .zero) == .leaveToAlert)
        // Seen at the last look still counts.
        #expect(PermissionAlert.step(inFrontBefore: nil, inFrontNow: 41, waited: .milliseconds(1500)) == .leaveToAlert)
    }

    @Test func withoutAnAlertThePageOpensWhenTheWatchEnds() {
        #expect(PermissionAlert.step(inFrontBefore: nil, inFrontNow: nil, waited: .zero) == .keepWatching)
        #expect(PermissionAlert.step(inFrontBefore: nil, inFrontNow: nil, waited: .milliseconds(1400)) == .keepWatching)
        #expect(PermissionAlert.step(inFrontBefore: nil, inFrontNow: nil, waited: .milliseconds(1500)) == .openSettings)
        #expect(PermissionAlert.step(inFrontBefore: nil, inFrontNow: nil, waited: .seconds(4)) == .openSettings)
    }

    @Test func anAlertAlreadyInFrontBeforeAskingIsNotTheAnswer() {
        // Another app's alert, or an earlier one of Intention's: the page
        // opens as it did before this rule.
        #expect(PermissionAlert.step(inFrontBefore: 41, inFrontNow: 41, waited: .milliseconds(600)) == .keepWatching)
        #expect(PermissionAlert.step(inFrontBefore: 41, inFrontNow: 41, waited: .milliseconds(1500)) == .openSettings)
        // It was answered while Intention watched, and nothing took its place.
        #expect(PermissionAlert.step(inFrontBefore: 41, inFrontNow: nil, waited: .milliseconds(1500)) == .openSettings)
        // A second alert came in front of it.
        #expect(PermissionAlert.step(inFrontBefore: 41, inFrontNow: 57, waited: .milliseconds(600)) == .leaveToAlert)
    }
}
