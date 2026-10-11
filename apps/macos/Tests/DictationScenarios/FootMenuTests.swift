import AppKit
@testable import Dictation
import Foundation
import Testing

/// The foot dot's menu: what it lists, what its items do, and how it opens,
/// from a right click, a Control-click or VoiceOver's Show Menu, none of
/// which is a click or a drag. The menu itself is never put on screen.
@MainActor
struct FootMenuTests {
    final class Calls {
        var list: [String] = []
    }

    private func rows() -> [MicrophoneMenu.Row] {
        [MicrophoneMenu.Row(id: .builtIn, preference: .builtIn, title: "Built-in microphone (recommended)", detail: nil, quiet: nil,
                            isChosen: false, isRecommended: true, canHear: true, level: nil),
         MicrophoneMenu.Row(id: .systemDefault, preference: .systemDefault, title: "System default", detail: nil, quiet: nil,
                            isChosen: false, isRecommended: false, canHear: true, level: nil),
         MicrophoneMenu.Row(id: .device("desk"), preference: .device(uid: "desk", name: "Desk Mic"), title: "Desk Mic", detail: nil,
                            quiet: nil, isChosen: true, isRecommended: false, canHear: true, level: nil)]
    }

    private func menu(_ calls: Calls, canPasteLast: Bool = true) -> NSMenu {
        FootMenu.make(microphones: rows(), canPasteLast: canPasteLast,
                      actions: FootMenu.Actions(hide: { calls.list.append("hide") }, settings: { calls.list.append("settings") },
                                                microphone: { calls.list.append("microphone \($0)") },
                                                history: { calls.list.append("history") }, pasteLast: { calls.list.append("paste") }))
    }

    private func press(_ item: NSMenuItem?) {
        guard let item, let action = item.action else { return }
        _ = (item.target as? NSObject)?.perform(action, with: item)
    }

    @Test func itListsWisprsItemsInIntentionsWordsWithTheShortcut() throws {
        let menu = menu(Calls())
        #expect(menu.items.map(\.title) == ["Hide for 1 hour", "Settings…", "", "Microphone", "", "History", "Paste last dictation"])
        let paste = try #require(menu.items.last)
        #expect(paste.keyEquivalent == "v")
        #expect(paste.keyEquivalentModifierMask == [.control, .option, .command])
        let microphones = try #require(menu.item(withTitle: "Microphone")?.submenu)
        #expect(microphones.items.map(\.title) == ["Built-in microphone", "System default", "", "Desk Mic"])
        #expect(microphones.items.map(\.state) == [.off, .off, .off, .on])
    }

    @Test func eachItemDoesWhatItSaysAndPasteGreysOutWithNothingToPaste() {
        let calls = Calls()
        let menu = menu(calls)
        press(menu.item(withTitle: "Hide for 1 hour"))
        press(menu.item(withTitle: "Settings…"))
        press(menu.item(withTitle: "Microphone")?.submenu?.item(withTitle: "System default"))
        press(menu.item(withTitle: "History"))
        press(menu.item(withTitle: "Paste last dictation"))
        #expect(calls.list == ["hide", "settings", "microphone systemDefault", "history", "paste"])
        #expect(self.menu(Calls(), canPasteLast: false).item(withTitle: "Paste last dictation")?.isEnabled == false)
        #expect(menu.item(withTitle: "Paste last dictation")?.isEnabled == true)
    }

    /// AppKit runs an item's action on the main thread; called from another
    /// queue, it still reaches the main actor instead of trapping.
    @Test(.timeLimit(.minutes(1))) func anItemsActionReachesTheMainActorFromAnyQueue() async {
        let calls = Calls()
        let item = menu(calls).item(withTitle: "History")
        nonisolated(unsafe) let target = item?.target as? NSObject
        let action = item?.action
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                if let target, let action { _ = target.perform(action, with: nil) }
                DispatchQueue.main.async { done.resume() }
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(calls.list == ["history"])
    }

    @Test func aRightClickOrAControlClickOpensTheMenuAndIsNeitherAClickNorADrag() throws {
        let foot = FootPlacementTests.foot()
        var actions: [FootAction] = []
        var menus = 0
        foot.onAction = { actions.append($0) }
        foot.target.onMenu = { _ in menus += 1 }
        let view = try #require(foot.target.contentView)
        let point = CGPoint(x: 8, y: 8)
        func event(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: foot.target.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.rightMouseDown(with: event(.rightMouseDown))
        view.mouseDown(with: event(.leftMouseDown, .control))
        view.mouseUp(with: event(.leftMouseUp, .control))
        #expect(menus == 2)
        #expect(actions.isEmpty)
        #expect(foot.presentation == .rest)
    }

    /// VoiceOver's Show Menu on the dot's button opens the menu, from the
    /// main thread or from any other queue.
    @Test(.timeLimit(.minutes(1))) func voiceOverShowMenuOpensTheMenu() async throws {
        let foot = FootPlacementTests.foot()
        var menus = 0
        foot.target.onMenu = { event in
            #expect(event == nil)
            menus += 1
        }
        let view = try #require(foot.target.contentView)
        let button = try #require((view.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }.first)
        #expect(button.accessibilityPerformShowMenu())
        nonisolated(unsafe) let element = button
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                _ = element.accessibilityPerformShowMenu()
                DispatchQueue.main.async { DispatchQueue.main.async { done.resume() } }
            }
        }
        #expect(menus == 2)
    }

    /// A right click while the dot is being dragged is ignored: no menu, and
    /// the release still lands the dot.
    @Test func aRightClickMidDragIsIgnoredAndTheDragStillLands() throws {
        let choices = FootDragTests.Choices()
        let foot = FootDragTests.foot(choices)
        var menus = 0
        foot.target.onMenu = { _ in menus += 1 }
        let view = try #require(foot.target.contentView)
        foot.target.press(at: CGPoint(x: 720, y: 106), moves: [CGPoint(x: 1200, y: 420), CGPoint(x: 1380, y: 470)], checking: {
            let right = NSEvent.mouseEvent(with: .rightMouseDown, location: CGPoint(x: 8, y: 8), modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: foot.target.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            view.rightMouseDown(with: right)
        })
        #expect(menus == 0)
        #expect(!foot.isMoving)
        #expect(choices.chosen == ["right on laptop"])
    }
}
