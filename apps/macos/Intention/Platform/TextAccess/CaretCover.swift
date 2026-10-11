import CoreGraphics


/// Whether something the person can see is drawn over the caret, so the dot
/// would sit on it rather than on the caret: a menu, popover, list box,
/// dialog, sheet, tooltip or any overlay of a page, in the page or in a
/// window of its own, or another app's window. Read from the element the
/// window server finds at the caret's point, the same element a click there
/// would reach, so windows that let the pointer through, such as other apps'
/// see-through overlays, never count. Only roles, window identity and
/// frames are read, never text. `CaretTracker` walks up from that element
/// and this decides.
///
/// Inside the field nothing covers the caret but a menu, list box, popover,
/// sheet, help tag, drawer, dialog or tooltip met on the way up. Whatever
/// else a page draws in its own editor at the caret belongs to the field,
/// and the caret blinks beside it: a placeholder, a hint such as Gmail's
/// "Press / to write", ghost text that completes a sentence, a chip, a
/// link, an image or the text run beside the caret. Reaching the field,
/// from the element that holds the caret's own text position or from any
/// other, leaves the caret showing. Until October 7, 2026 an element inside
/// a web field that was neither that holder nor one of its ancestors
/// covered the caret, meant for a role-less picker drawn inside an editor;
/// it hid the dot under Gmail's hint and beside whichever text run the hit
/// test preferred, while Chromium's hit test rarely answers with such a
/// picker at all.
///
/// Another window of the same app at the caret covers it, as a menu, a
/// popover, a sheet or a page's select list does, unless it is a borderless
/// window (subrole `AXUnknown`) whose frame holds the whole field and the
/// element met is bare, a group with no children: a frame drawn around the
/// field, as Chrome's address bar suggestions are, whose see-through strip
/// over the omnibox is not a cover. A dialog, a sheet and a menu all carry
/// a subrole or a role of their own and still cover.
///
/// The walk ends where that element's ancestors meet the field's own. The
/// part of the page it came through there, the branch, covers the caret
/// unless it lies inside the field's frame: a placeholder drawn beside an
/// empty composer does, while a dropdown or a dialog reaches outside it.
///
/// Where the field says which element holds the caret's own text position,
/// as web fields do through their selection markers, a menu, dialog or
/// tooltip among that element's ancestors up to the field still covers it,
/// while its list does not, since that is the list being typed in.
/// Chromium and WebKit give a list and a list box the same role, so where
/// the field does not say, a list at the caret covers it.
enum CaretCover {
    /// One element on the way up from the element at the caret's point.
    enum Step: Equatable {
        /// The focused field itself, an element inside it that is no cover,
        /// or an element that holds it, such as its border: nothing is
        /// drawn over the caret.
        case field
        /// A window that does not hold the field, of the same app.
        case otherWindow
        /// A borderless window of the same app drawn as a frame around the
        /// field, met at the caret through a bare element of its own, with
        /// no children and no role of its own: Chrome's address bar
        /// suggestions open so, and their see-through top strip lies over
        /// the omnibox while the caret stays in plain view.
        case frameAround
        /// An element that holds the field, reached through a branch that
        /// lies inside the field's frame, or not.
        case joins(insideField: Bool)
        case element(role: String, subrole: String?)
    }

    /// Whether the caret is covered, from the element at its point upward.
    /// A walk that ends without saying, as when it runs out of parents or
    /// depth, counts as uncovered.
    static func covered(by steps: [Step]) -> Bool {
        for step in steps {
            switch step {
            case .field, .frameAround: return false
            case .otherWindow: return true
            case let .joins(inside): return !inside
            case let .element(role, subrole): if covers(role: role, subrole: subrole) { return true }
            }
        }
        return false
    }

    /// Whether the elements that hold the caret, from the one at its point
    /// up to the field, include a menu, dialog, tooltip or other covering
    /// role. A list among them is the one being typed in.
    static func refused(_ roles: [(role: String, subrole: String?)]) -> Bool {
        roles.contains { $0.role != "AXList" && covers(role: $0.role, subrole: $0.subrole) }
    }

    /// Roles a page or app draws over other content for a moment.
    static func covers(role: String, subrole: String?) -> Bool {
        if ["AXMenu", "AXMenuItem", "AXPopover", "AXSheet", "AXHelpTag", "AXList", "AXListBox", "AXDrawer"].contains(role) { return true }
        return ["AXApplicationDialog", "AXApplicationAlertDialog", "AXDialog", "AXUserInterfaceTooltip"].contains(subrole ?? "")
    }

    /// Whether a branch's frame lies inside the field's, allowing for a
    /// border or a few points of padding.
    static func inside(_ branch: CGRect, field: CGRect) -> Bool {
        field.insetBy(dx: -6, dy: -6).contains(branch)
    }
}
