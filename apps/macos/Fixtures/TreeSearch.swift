import Foundation

// Walks of a window's Accessibility tree, apart from Accessibility itself,
// so `./dev mac-dictation-test` checks them on hand-written trees: Gmail's
// own Reply control for a thread, and whether an element described a
// certain way is there, is not, or could not be told. The runners read
// the real tree through `OwnedWindows`; the tests read literal ones.

/// What a search of a tree found. A search that could not finish, because
/// an element did not answer or the tree was larger than its budget, says
/// so rather than passing absence off as an answer.
enum TreeLookup<Node> {
    case found(Node)
    /// The whole tree was read and nothing matched.
    case absent
    /// The tree was not read whole, or what it held was not one thing.
    case unknown(String)

    var node: Node? { if case .found(let node) = self { return node } else { return nil } }
    var isAbsent: Bool { if case .absent = self { return true } else { return false } }
    var why: String? { if case .unknown(let why) = self { return why } else { return nil } }
}

/// A tree read through closures: Accessibility for the runners, literal
/// nodes for the tests. Every read is a call, and nothing is kept.
struct TreeReader<Node> {
    /// The element's children; nil when they could not be read.
    var children: (Node) -> [Node]?
    var role: (Node) -> String?
    /// The element's description, as given.
    var description: (Node) -> String?
    /// The element's title, as given.
    var title: (Node) -> String?
    /// Whether a link leads somewhere, carrying an address as a link in an
    /// email's text does and Gmail's own controls do not; nil when that
    /// could not be read, which is never taken for no address.
    var linksOut: (Node) -> Bool?
    /// A dialog, sheet or popover, given the role already read; its
    /// controls are never the page's.
    var isDialog: (Node, String?) -> Bool
    /// The most elements one search reads before giving up.
    var budget = 12_000

    /// A control's name: its description or else its title, without the
    /// shortcut Gmail writes after it.
    func name(_ node: Node) -> String? {
        for text in [description(node), title(node)] {
            if let text, !text.isEmpty {
                return String(text.prefix { $0 != "\u{202A}" && $0 != "(" }).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func isControl(_ node: Node, role: String?) -> Bool { role == "AXButton" || role == "AXLink" }

    /// Gmail's own Reply control for the thread's last message: a button
    /// or link named "Reply" that leads nowhere, outside any dialog, found
    /// by reading the whole page depth first. The one beside the thread's
    /// Forward control, at its foot, is taken when there is exactly one;
    /// otherwise a lone Reply control, the last message's own. Two Reply
    /// controls and neither at the foot, a page larger than the budget or
    /// an element that does not answer give no control, so a run presses
    /// nothing rather than a link in an email's text or a dialog's button.
    func replyControl(in root: Node) -> TreeLookup<Node> {
        var stack: [(node: Node, siblings: [Node])] = [(root, [])]
        var visited = 0
        var atFoot: [Node] = [], alone: [Node] = []
        while let (node, siblings) = stack.popLast() {
            guard visited < budget else { return .unknown("the page has more than \(budget) elements") }
            visited += 1
            let role = role(node)
            if isDialog(node, role) { continue }
            if isControl(node, role: role), name(node) == "Reply" {
                guard let leads = linksOut(node) else { return .unknown("an element did not answer") }
                if !leads {
                    let beside = siblings.contains { sibling in isControl(sibling, role: self.role(sibling)) && name(sibling) == "Forward" }
                    if beside { atFoot.append(node) } else { alone.append(node) }
                }
            }
            guard let children = children(node) else { return .unknown("an element did not answer") }
            stack.append(contentsOf: children.reversed().map { ($0, children) })
        }
        switch (atFoot.count, alone.count) {
        case (1, _): return .found(atFoot[0])
        case (0, 0): return .absent
        case (0, 1): return .found(alone[0])
        case (0, let n): return .unknown("\(n) Reply controls, none beside a Forward control")
        case (let n, _): return .unknown("\(n) Reply controls beside a Forward control")
        }
    }

    /// The first element, breadth first, whose description is
    /// `description` or starts with it and a space, with `role` when one
    /// is given; Gmail's discard control carries its shortcut after its
    /// name. Absent only once the whole tree has been read.
    func element(described description: String, role wanted: String? = nil, under root: Node) -> TreeLookup<Node> {
        var queue = [root], visited = 0
        while !queue.isEmpty {
            guard visited < budget else { return .unknown("the page has more than \(budget) elements") }
            let node = queue.removeFirst()
            visited += 1
            if let d = self.description(node), d == description || d.hasPrefix(description + " "), wanted == nil || role(node) == wanted {
                return .found(node)
            }
            guard let children = children(node) else { return .unknown("an element did not answer") }
            queue.append(contentsOf: children)
        }
        return .absent
    }
}
