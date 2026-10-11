import AppKit
import ApplicationServices

/// Runs on AccessibilityExecutor and reads only structural metadata. Admission
/// must finish before reading text, caret anchors or capturing field pixels.
enum AXWritingSurface {
    enum Admission { case allowed, secure, unsupported }

    static func admission(_ focused: AXElement, pid: pid_t) -> Admission {
        surface(focused, pid: pid).admission
    }

    /// Admission, and whether the element is in or is a web area, from one
    /// walk of its ancestors. `editableDocument` also admits focus on a web
    /// area itself; see `WritingSurfacePolicy.allowsMetadata`.
    static func surface(_ focused: AXElement, pid: pid_t, editableDocument: Bool = false) -> (admission: Admission, web: Bool) {
        guard let window = try? focused.element(kAXWindowAttribute).get() else { return (.unsupported, false) }
        var web = false
        var current = focused
        for depth in 0..<40 {
            let subrole: String?
            switch current.value(kAXSubroleAttribute) {
            case let .success(value):
                guard CFGetTypeID(value) == CFStringGetTypeID() else { return (.unsupported, web) }
                subrole = value as? String
            case let .failure(error) where error.code == .attributeUnsupported || error.code == .noValue:
                subrole = nil
            // AppKit's toolbar groups answer a generic failure. The focused
            // control's own subrole must still be read, so a secure field is
            // never admitted on an ancestor's non-answer.
            case let .failure(error) where depth > 0 && error.code == .failure:
                subrole = nil
            default: return (.unsupported, web)
            }
            if subrole == kAXSecureTextFieldSubrole { return (.secure, web) }
            guard let role = try? current.string(kAXRoleAttribute).get(),
                  WritingSurfacePolicy.allowsMetadata(role: role, subrole: subrole, focused: depth == 0,
                                                      editableDocument: editableDocument)
            else { return (.unsupported, web) }
            if role == "AXWebArea" { web = true }
            if current.sameElement(as: window) { return (.allowed, web) }
            guard let parent = try? current.element(kAXParentAttribute).get() else { return (.unsupported, web) }
            current = parent
        }
        return (.unsupported, web)
    }

    /// Whether the element or an ancestor up to `window` carries the secure
    /// subrole, or the secure role `surface` refuses too, read again after
    /// admission since a wrapper can turn secure without focus moving. Nil
    /// when either fails to answer, by `WritingSurfacePolicy.secure`'s rule.
    /// Both come in one message to the app for each element.
    static func secureAncestry(_ focused: AXElement, window: AXElement) -> Bool? {
        var current = focused
        for depth in 0..<40 {
            let (subrole, role) = subroleAndRole(of: current)
            switch WritingSurfacePolicy.secure(subrole: subrole, role: role, focused: depth == 0) {
            case true?: return true
            case nil: return nil
            case false?: break
            }
            if current.sameElement(as: window) { return false }
            guard let parent = try? current.element(kAXParentAttribute).get() else { return nil }
            current = parent
        }
        return nil
    }

    /// An element's subrole and role, asked in one message. A message that
    /// fails gives both the same answer.
    private static func subroleAndRole(of element: AXElement) -> (WritingSurfacePolicy.Answer, WritingSurfacePolicy.Answer) {
        func answer(_ read: Result<CFTypeRef, AXFailure>) -> WritingSurfacePolicy.Answer {
            switch read {
            case let .success(value):
                CFGetTypeID(value) == CFStringGetTypeID() ? .text(value as! String) : .unexpected
            case let .failure(error) where error.code == .attributeUnsupported || error.code == .noValue: .absent
            case let .failure(error) where error.code == .failure: .genericFailure
            case .failure: .unanswered
            }
        }
        switch element.values([kAXSubroleAttribute, kAXRoleAttribute]) {
        case let .success(values): return (answer(values[0]), answer(values[1]))
        case let .failure(error): return (answer(.failure(error)), answer(.failure(error)))
        }
    }

    /// Whether `window` exposes no text control, secure field or web area
    /// anywhere in it, as an app without accessible text does: Codex's
    /// Electron fork, and
    /// terminals and editors that draw their own text. Roles of at most 400
    /// elements. A larger tree is not a bare one, and neither is one that
    /// fails to answer: every role must be read and every child list must be
    /// read or answer that there is none, so an error or timeout never
    /// counts a window as bare.
    static func bare(_ window: AXElement) -> Bool {
        exposure(of: window, stopAtText: true) == .nothing
    }

    /// What `window` holds, by `WritingSurfacePolicy.exposure(role:subrole:)`
    /// for each element: `.secure` as soon as one element is or might be a
    /// password field, else `.text` if any is text, else `.nothing`. With
    /// `stopAtText` it ends at the first text, for a caller that only asks
    /// whether the window is bare. A tree larger than 400 elements, or one
    /// whose children do not answer, might hold anything and is `.secure`.
    static func exposure(of window: AXElement, stopAtText: Bool = false) -> WritingSurfacePolicy.Exposure {
        var queue = [window], visited = 0, sawText = false
        guard AXIsProcessTrusted() else { return .secure }
        while !queue.isEmpty {
            guard visited < 400 else { return .secure }
            let node = queue.removeFirst()
            visited += 1
            // Role and subrole in one message, so a field marked secure by
            // either, or one that does not say, is never taken for nothing.
            let (subrole, role) = subroleAndRole(of: node)
            if visited == 1, role != .text(kAXWindowRole) { return .secure }
            switch WritingSurfacePolicy.exposure(role: role, subrole: subrole) {
            case .secure: return .secure
            case .text:
                if stopAtText { return .text }
                sawText = true
            case .nothing: break
            }
            switch node.children() {
            case let .success(children): queue += children
            case let .failure(error) where error.code == .noValue || error.code == .attributeUnsupported: break
            case .failure: return .secure
            }
        }
        return sawText ? .text : .nothing
    }
}
