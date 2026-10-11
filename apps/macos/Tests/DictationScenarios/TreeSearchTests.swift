import Foundation
@testable import Dictation
import Testing

/// The runners' walks of a page (`apps/macos/Fixtures/TreeSearch.swift`)
/// over trees written out by hand: which control a run may press as
/// Gmail's Reply, and when a lookup must say it could not tell.
struct TreeSearchTests {
    /// One element of a made-up page.
    final class Node {
        let role: String
        let description: String?
        let title: String?
        let subrole: String?
        /// Nil for a link whose address could not be read.
        let url: Bool?
        /// Nil for an element that does not answer.
        let children: [Node]?
        init(_ role: String, description: String? = nil, title: String? = nil, subrole: String? = nil, url: Bool? = false, children: [Node]? = []) {
            self.role = role; self.description = description; self.title = title; self.subrole = subrole; self.url = url; self.children = children
        }
    }

    private func reader(budget: Int = 12_000) -> TreeReader<Node> {
        TreeReader(children: { $0.children }, role: { $0.role }, description: { $0.description }, title: { $0.title },
                   linksOut: { $0.url }, isDialog: { node, role in role == "AXSheet" || (role == "AXGroup" && node.subrole == "AXApplicationDialog") },
                   budget: budget)
    }

    private func group(_ children: [Node]) -> Node { Node("AXGroup", children: children) }

    /// The thread's last message with its own Reply button in its header
    /// and a link named Reply in its text, then the thread's foot with
    /// Reply beside Forward, each control named as Gmail names it.
    private let headerReply = Node("AXButton", description: "Reply")
    private let textLink = Node("AXLink", description: "Reply", url: true)
    private let footReply = Node("AXLink", title: "Reply\u{202A}(r)")
    private let footForward = Node("AXLink", title: "Forward\u{202A}(f)")

    private func thread(foot: [Node]? = nil, after: [Node] = []) -> Node {
        var messages = [group([group([headerReply]), group([Node("AXStaticText", description: "Please"), textLink])])]
        if let foot { messages.append(group(foot)) }
        return Node("AXWindow", children: [Node("AXWebArea", children: messages + after)])
    }

    @Test func theReplyBesideForwardIsTheOnePressedAndALinkInTheTextNever() {
        let page = thread(foot: [footReply, footForward])
        #expect(reader().replyControl(in: page).node === footReply)
    }

    @Test func withoutTheFootTheLastMessagesOwnReplyIsTaken() {
        #expect(reader().replyControl(in: thread()).node === headerReply)
    }

    @Test func aLinkThatLeadsSomewhereIsNeverTheReplyControl() {
        let page = Node("AXWindow", children: [group([textLink])])
        #expect(reader().replyControl(in: page).isAbsent)
    }

    @Test func aControlInADialogIsNeverTheReplyControl() {
        let dialogReply = Node("AXButton", description: "Reply")
        let dialog = Node("AXGroup", subrole: "AXApplicationDialog", children: [dialogReply, Node("AXButton", description: "Forward")])
        let sheet = Node("AXSheet", children: [Node("AXButton", description: "Reply")])
        #expect(reader().replyControl(in: Node("AXWindow", children: [group([dialog]), sheet])).isAbsent)
        // Beside the page's own foot, the dialog's is still passed over.
        #expect(reader().replyControl(in: thread(foot: [footReply, footForward], after: [dialog])).node === footReply)
    }

    @Test func twoReplyControlsAndNoFootIsNoControl() {
        let page = Node("AXWindow", children: [group([Node("AXButton", description: "Reply")]), group([Node("AXButton", description: "Reply")])])
        #expect(reader().replyControl(in: page).why == "2 Reply controls, none beside a Forward control")
        let twoFeet = thread(foot: [footReply, footForward], after: [group([Node("AXLink", title: "Reply"), Node("AXLink", title: "Forward")])])
        #expect(reader().replyControl(in: twoFeet).why == "2 Reply controls beside a Forward control")
    }

    @Test func aPageLargerThanTheBudgetGivesNoControlRatherThanTheLastSeen() {
        // The text's link comes within the budget and the foot after it.
        let page = thread(foot: [footReply, footForward])
        #expect(reader(budget: 6).replyControl(in: page).why == "the page has more than 6 elements")
        #expect(reader(budget: 12).replyControl(in: page).node === footReply)
    }

    @Test func anElementThatDoesNotAnswerGivesNoControl() {
        let page = Node("AXWindow", children: [group([headerReply]), Node("AXGroup", children: nil), group([footReply, footForward])])
        #expect(reader().replyControl(in: page).why == "an element did not answer")
        // A link named Reply whose address could not be read is never
        // taken for one without, even beside a Forward control.
        let unread = Node("AXLink", title: "Reply", url: nil)
        let page2 = thread(foot: [unread, footForward])
        #expect(reader().replyControl(in: page2).why == "an element did not answer")
    }

    @Test func anElementIsAbsentOnlyOnceTheWholePageWasRead() {
        let body = Node("AXTextArea", description: "Message Body")
        let discard = Node("AXButton", description: "Discard draft \u{202A}(⌘⇧,)")
        let page = Node("AXWindow", children: [group([Node("AXStaticText", description: "Message Bodies")]), group([body, discard])])
        #expect(reader().element(described: "Message Body", under: page).node === body)
        #expect(reader().element(described: "Message Body", role: "AXTextArea", under: page).node === body)
        #expect(reader().element(described: "Message Body", role: "AXButton", under: page).isAbsent)
        #expect(reader().element(described: "Discard draft", under: page).node === discard)
        #expect(reader().element(described: "Send", under: page).isAbsent)
        #expect(reader(budget: 3).element(described: "Send", under: page).why == "the page has more than 3 elements")
        let silent = Node("AXWindow", children: [group([Node("AXGroup", children: nil)])])
        #expect(reader().element(described: "Message Body", under: silent).why == "an element did not answer")
    }

    @Test func aControlsNameIsItsDescriptionOrTitleWithoutTheShortcut() {
        #expect(reader().name(footReply) == "Reply")
        #expect(reader().name(Node("AXLink", title: "Reply (r)")) == "Reply")
        #expect(reader().name(Node("AXButton", description: "", title: "Forward")) == "Forward")
        #expect(reader().name(Node("AXGroup")) == nil)
    }
}
