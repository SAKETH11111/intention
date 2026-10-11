import ApplicationServices
import Foundation
import os

// A scripted System Settings window for SettingsListReader, compiled with
// the production reader by scripts/test-onboarding.sh in place of
// AXElement.swift. Nothing here reaches a real app: every element is a
// `MockElement` the test builds, and its native reference only names it.

struct AXFailure: Error, Equatable {
    let code: AXError
    var isTimeout: Bool { code == .cannotComplete }
    var isPermissionDenied: Bool { code == .apiDisabled }
}

/// One element in the scripted window, with the replies it gives.
final class MockElement: @unchecked Sendable {
    var role: String
    var frame: CGRect?
    var children: [MockElement]
    /// A label's text.
    var text: String?
    /// A switch's value, 1 for on.
    var isOn: Int?
    /// A switch's own title.
    var title: String?
    /// The name the app gives the element, as System Settings gives its sidebar.
    var identifier: String?
    /// What the element is described as to a person, "Sidebar" for that one.
    var summary: String?
    /// Attributes that answer with this error instead of their value.
    var failing: [String: AXError] = [:]
    /// The one message asking for role, frame and children fails whole.
    var unanswered = false
    /// Listed by its parent, and answers that it is not an element.
    var gone = false
    /// Runs when this element answers that message, for a page that
    /// changes while it is being read.
    var whenRead: (() -> Void)?

    private static let registry = OSAllocatedUnfairLock(initialState: (next: pid_t(1), elements: [pid_t: MockElement]()))
    /// Stands for this element where the reader holds a native reference.
    /// Each element gets an application reference with its own made-up
    /// process number, which is never messaged.
    private(set) var ref: AXUIElement!

    init(_ role: String, frame: CGRect?, children: [MockElement] = [], text: String? = nil, isOn: Int? = nil, title: String? = nil) {
        self.role = role
        self.frame = frame
        self.children = children
        self.text = text
        self.isOn = isOn
        self.title = title
        let id = Self.registry.withLock { state in
            let id = state.next
            state.next += 1
            state.elements[id] = self
            return id
        }
        ref = AXUIElementCreateApplication(id)
    }

    static func named(by ref: AXUIElement) -> MockElement? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(ref, &pid) == .success else { return nil }
        let id = pid
        return registry.withLock { $0.elements[id] }
    }

    func reply(_ attribute: String) -> Result<CFTypeRef, AXFailure> {
        if let code = failing[attribute] { return .failure(AXFailure(code: code)) }
        var value: CFTypeRef?
        switch attribute {
        case kAXRoleAttribute:
            value = role as CFString
        case kAXPositionAttribute:
            if var origin = frame?.origin { value = AXValueCreate(.cgPoint, &origin) }
        case kAXSizeAttribute:
            if var size = frame?.size { value = AXValueCreate(.cgSize, &size) }
        case kAXChildrenAttribute:
            if !children.isEmpty { value = children.map { $0.ref! } as CFArray }
        case kAXValueAttribute:
            if let text { value = text as CFString } else if let isOn { value = isOn as CFNumber }
        case kAXTitleAttribute:
            if let title { value = title as CFString }
        case kAXIdentifierAttribute:
            if let identifier { value = identifier as CFString }
        case kAXDescriptionAttribute:
            if let summary { value = summary as CFString }
        default:
            break
        }
        guard let value else { return .failure(AXFailure(code: .noValue)) }
        return .success(value)
    }
}

struct AXElement: @unchecked Sendable {
    let ref: AXUIElement

    private var mock: MockElement? { MockElement.named(by: ref) }

    static func application(_ pid: pid_t) -> AXElement {
        AXElement(ref: AXUIElementCreateApplication(pid))
    }

    func value(_ attribute: String) -> Result<CFTypeRef, AXFailure> {
        mock?.reply(attribute) ?? .failure(AXFailure(code: .invalidUIElement))
    }

    func string(_ attribute: String) -> Result<String, AXFailure> {
        value(attribute).flatMap { value in
            guard CFGetTypeID(value) == CFStringGetTypeID() else { return .failure(AXFailure(code: .noValue)) }
            return .success(value as! String)
        }
    }

    func element(_ attribute: String) -> Result<AXElement, AXFailure> {
        .failure(AXFailure(code: .noValue))
    }

    func int(_ attribute: String) -> Result<Int, AXFailure> {
        value(attribute).flatMap { value in
            guard CFGetTypeID(value) == CFNumberGetTypeID() else { return .failure(AXFailure(code: .noValue)) }
            return .success((value as! NSNumber).intValue)
        }
    }

    func frame() -> Result<CGRect, AXFailure> {
        guard let mock else { return .failure(AXFailure(code: .invalidUIElement)) }
        if let code = mock.failing[kAXPositionAttribute] { return .failure(AXFailure(code: code)) }
        return mock.frame.map { .success($0) } ?? .failure(AXFailure(code: .noValue))
    }

    func values(_ attributes: [String]) -> Result<[Result<CFTypeRef, AXFailure>], AXFailure> {
        guard let mock else { return .failure(AXFailure(code: .invalidUIElement)) }
        if mock.gone { return .failure(AXFailure(code: .invalidUIElement)) }
        if mock.unanswered { return .failure(AXFailure(code: .cannotComplete)) }
        mock.whenRead?()
        return .success(attributes.map(mock.reply))
    }
}
