import AppKit
import ApplicationServices

// The tracker uses the same scripted AXElement as insertion. These direct
// system calls also stay inside the fixture; no app is observed or changed.
func AXUIElementGetPid(_ element: AXUIElement, _ pid: UnsafeMutablePointer<pid_t>) -> AXError {
    pid.pointee = MockField.shared.appPID ?? getppid()
    return .success
}

func AXUIElementSetAttributeValue(_ element: AXUIElement, _ attribute: CFString, _ value: CFTypeRef) -> AXError { .success }
func AXObserverCreate(_ pid: pid_t, _ callback: AXObserverCallback, _ observer: UnsafeMutablePointer<AXObserver?>) -> AXError { .failure }

extension AXElement {
    init(ref: AXUIElement) { self.init(ref: ref, id: MockField.shared.focusedElement) }
    static func decodeRect(_ value: CFTypeRef) -> Result<CGRect, AXFailure> { .failure(AXFailure(code: .attributeUnsupported)) }
    func parameterizedAttributes() -> [String] { Array(parameterizedNames() ?? []) }
    func parameterized(_ name: String, _ value: CFTypeRef) -> Result<CFTypeRef, AXFailure> { .failure(AXFailure(code: .attributeUnsupported)) }
}

extension AppLog { static func caret(_ reason: String) {} }
extension CaretFixtureMode {
    static func diagnostic(_ message: String, duration: Double? = nil) {}
    static func anchorObservation(_ anchors: [CaretSearchAnchor], selection: Int?, readAt: TimeInterval) {}
}
extension AXWritingSurface {
    static func bare(_ window: AXElement) -> Bool { MockField.shared.bareWindow }
    static func admission(_ element: AXElement, pid: pid_t) -> Admission { surface(element, pid: pid).admission }
}
enum DotLog { static func tracker(_ reason: String) {} }
