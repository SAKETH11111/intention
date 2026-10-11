import ApplicationServices
import Foundation

/// An Accessibility error code with the call that produced it.
struct AXFailure: Error, Equatable {
    let code: AXError

    /// The app did not answer within the messaging timeout.
    var isTimeout: Bool { code == .cannotComplete }
    var isPermissionDenied: Bool { code == .apiDisabled }
}

/// Typed reads and writes on one Accessibility element. Values are used only
/// on the `AccessibilityExecutor` thread.
struct AXElement: @unchecked Sendable {
    let ref: AXUIElement

    /// Structural class tokens only, never the field's text.
    func domClasses() -> Set<String>? {
        guard case let .success(value) = value("AXDOMClassList"), let classes = value as? [String] else { return nil }
        return Set(classes)
    }

    static func application(_ pid: pid_t) -> AXElement {
        AXElement(ref: AXUIElementCreateApplication(pid))
    }

    func sameElement(as other: AXElement) -> Bool {
        CFEqual(ref, other.ref)
    }

    /// The app has destroyed the element, as when a page replaces it.
    var isGone: Bool {
        if case let .failure(failure) = value(kAXRoleAttribute) { failure.code == .invalidUIElement } else { false }
    }

    /// Whether the element is still there, from one read of its role: true
    /// when it answers, false when the app has destroyed it, as `isGone`
    /// reads it, and nil when the app does not answer, which says neither.
    var stillThere: Bool? {
        switch value(kAXRoleAttribute) {
        case .success: true
        case let .failure(failure) where failure.code == .invalidUIElement: false
        case let .failure(failure) where failure.code == .noValue || failure.code == .attributeUnsupported: true
        case .failure: nil
        }
    }

    func value(_ attribute: String) -> Result<CFTypeRef, AXFailure> {
        var value: CFTypeRef?
        let code = AXUIElementCopyAttributeValue(ref, attribute as CFString, &value)
        guard code == .success, let value else { return .failure(AXFailure(code: code == .success ? .noValue : code)) }
        return .success(value)
    }

    func string(_ attribute: String) -> Result<String, AXFailure> {
        value(attribute).flatMap { value in
            guard CFGetTypeID(value) == CFStringGetTypeID() else { return .failure(AXFailure(code: .noValue)) }
            return .success(value as! String)
        }
    }

    func element(_ attribute: String) -> Result<AXElement, AXFailure> {
        value(attribute).flatMap { value in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return .failure(AXFailure(code: .noValue)) }
            return .success(AXElement(ref: value as! AXUIElement))
        }
    }

    /// The element's children. A value that is not a list of elements is
    /// a failure, never an empty list.
    func children() -> Result<[AXElement], AXFailure> {
        value(kAXChildrenAttribute).flatMap { value in
            guard CFGetTypeID(value) == CFArrayGetTypeID() else { return .failure(AXFailure(code: .failure)) }
            var children: [AXElement] = []
            for item in value as! [AnyObject] {
                guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return .failure(AXFailure(code: .failure)) }
                children.append(AXElement(ref: item as! AXUIElement))
            }
            return .success(children)
        }
    }

    /// Several attributes in one message to the other app. The whole read
    /// fails when the message does; otherwise each attribute carries its
    /// own value or error, `.attributeUnsupported` or `.noValue` when the
    /// element lacks it.
    func values(_ attributes: [String]) -> Result<[Result<CFTypeRef, AXFailure>], AXFailure> {
        var result: CFArray?
        let code = AXUIElementCopyMultipleAttributeValues(ref, attributes as CFArray, AXCopyMultipleAttributeOptions(), &result)
        guard code == .success, let values = result as? [AnyObject], values.count == attributes.count else {
            return .failure(AXFailure(code: code == .success ? .failure : code))
        }
        return .success(values.map { value in
            if CFGetTypeID(value) == CFNullGetTypeID() { return .failure(AXFailure(code: .noValue)) }
            guard CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError else { return .success(value) }
            var raw: Int32 = AXError.failure.rawValue
            AXValueGetValue(value as! AXValue, .axError, &raw)
            return .failure(AXFailure(code: AXError(rawValue: raw) ?? .failure))
        })
    }

    /// How many of the element's children are blocks: groups and lists. A
    /// web editor that keeps each line in its own paragraph has one for
    /// each, an empty paragraph included, where a text area has none and a
    /// plain editable element has only its text. Roles are read, never
    /// text. Nil when the children or one of their roles do not answer.
    func blockChildren() -> Int? {
        guard case let .success(children) = children() else { return nil }
        var blocks = 0
        for child in children {
            guard case let .success(role) = child.string(kAXRoleAttribute) else { return nil }
            if role == kAXGroupRole || role == kAXListRole { blocks += 1 }
        }
        return blocks
    }

    /// Starts of direct block children, measured from this field's start
    /// marker in the same offsets as its ranged reads. Used only to
    /// corroborate a mail editor's blank paragraph after a paste. Missing or
    /// out-of-field markers provide no evidence.
    func blockStarts(expectedLength: Int) -> [Int]? {
        guard let whole = textMarkers() else { return nil }
        let origin = AXTextMarkerRangeCopyStartMarker(whole)
        guard length(from: origin, to: AXTextMarkerRangeCopyEndMarker(whole)) == expectedLength,
              case let .success(children) = children() else { return nil }
        var starts: [Int] = []
        for child in children {
            guard case let .success(role) = child.string(kAXRoleAttribute) else { return nil }
            guard role == kAXGroupRole else { return nil }
            guard let range = child.textMarkers(),
                  let start = length(from: origin, to: AXTextMarkerRangeCopyStartMarker(range)),
                  let end = length(from: origin, to: AXTextMarkerRangeCopyEndMarker(range)),
                  start >= 0, start <= end, end <= expectedLength,
                  starts.last.map({ $0 <= start }) ?? true else { return nil }
            starts.append(start)
        }
        return starts
    }

    /// Whether the element's text is all text the page generated, as a CSS
    /// placeholder's `::before` content is: static text within three levels
    /// of its children, and none of it text the person can edit. Chromium
    /// lists an editable ancestor for the second and none for the first,
    /// as the caret tracker tells an empty editor
    /// (`CaretTracker.generatedPlaceholder`), and a placeholder shows only
    /// while the editor holds nothing of the person's. False where there is
    /// no static text, or some lists an editable ancestor. Nil when the
    /// children, a child's role or a static text's attribute names do not
    /// answer. Roles and attribute names are read, never text.
    func generatedText() -> Bool? {
        var level = [self]
        var generated = false
        for _ in 0..<3 {
            var next: [AXElement] = []
            for node in level {
                let children: [AXElement]
                switch node.children() {
                case let .success(found): children = found
                case let .failure(failure) where failure.code == .noValue || failure.code == .attributeUnsupported: children = []
                case .failure: return nil
                }
                for child in children.prefix(4) {
                    guard case let .success(role) = child.string(kAXRoleAttribute) else { return nil }
                    guard role == kAXStaticTextRole else {
                        next.append(child)
                        continue
                    }
                    var names: CFArray?
                    guard AXUIElementCopyAttributeNames(child.ref, &names) == .success, let names = names as? [String] else { return nil }
                    if names.contains("AXEditableAncestor") { return false }
                    generated = true
                }
            }
            level = Array(next.prefix(8))
        }
        return generated
    }

    func int(_ attribute: String) -> Result<Int, AXFailure> {
        value(attribute).flatMap { value in
            guard CFGetTypeID(value) == CFNumberGetTypeID() else { return .failure(AXFailure(code: .noValue)) }
            return .success((value as! NSNumber).intValue)
        }
    }

    func range(_ attribute: String) -> Result<FieldRange, AXFailure> {
        value(attribute).flatMap(Self.decodeRange)
    }

    func frame() -> Result<CGRect, AXFailure> {
        let position = value(kAXPositionAttribute).flatMap(Self.decodePoint)
        let size = value(kAXSizeAttribute).flatMap(Self.decodeSize)
        switch (position, size) {
        case let (.success(origin), .success(size)): return .success(CGRect(origin: origin, size: size))
        case let (.failure(error), _), let (_, .failure(error)): return .failure(error)
        }
    }

    func isSettable(_ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(ref, attribute as CFString, &settable) == .success && settable.boolValue
    }

    func parameterizedAttributes() -> Set<String> { parameterizedNames() ?? [] }

    /// The parameterized attributes the element offers, or nil when it
    /// does not answer for them.
    func parameterizedNames() -> Set<String>? {
        var names: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(ref, &names) == .success, let names = names as? [String] else { return nil }
        return Set(names)
    }

    func string(for range: FieldRange) -> Result<String, AXFailure> {
        if range.length == 0 { return .success("") }
        return parameterized(kAXStringForRangeParameterizedAttribute, range: range).flatMap { value in
            guard CFGetTypeID(value) == CFStringGetTypeID() else { return .failure(AXFailure(code: .noValue)) }
            return .success(value as! String)
        }
    }

    /// An optional geometry read may use a shorter timeout than text reads.
    /// Set it only on this element and restore the executor's normal timeout.
    func bounds(for range: FieldRange, timeout: Float? = nil) -> Result<CGRect, AXFailure> {
        if let timeout {
            let code = AXUIElementSetMessagingTimeout(ref, timeout)
            guard code == .success else { return .failure(AXFailure(code: code)) }
        }
        defer {
            if timeout != nil { AXUIElementSetMessagingTimeout(ref, AccessibilityExecutor.messagingTimeout) }
        }
        return parameterized(kAXBoundsForRangeParameterizedAttribute, range: range).flatMap(Self.decodeRect)
    }

    func setString(_ attribute: String, _ string: String) -> AXError {
        AXUIElementSetAttributeValue(ref, attribute as CFString, string as CFString)
    }

    func setValue(_ attribute: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(ref, attribute as CFString, value)
    }

    /// The process that owns the element.
    func pid() -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(ref, &pid) == .success ? pid : nil
    }

    /// AppKit's cross-process name for accessibilityReplaceRange:withText:.
    /// Its parameter is a dictionary keyed by AXReplacementRange and
    /// AXReplacementText; the result is a Boolean.
    static let replaceRangeWithText = "AXReplaceRangeWithText"

    /// Replaces a UTF-16 range through the field's editing pipeline. Returns
    /// `.success` only when the app reported that it performed the edit.
    func replace(_ range: FieldRange, with text: String) -> AXError {
        var cfRange = range.cfRange
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return .illegalArgument }
        let parameter = ["AXReplacementRange": rangeValue, "AXReplacementText": text as CFString] as CFDictionary
        var result: CFTypeRef?
        let code = AXUIElementCopyParameterizedAttributeValue(ref, Self.replaceRangeWithText as CFString, parameter, &result)
        guard code == .success else { return code }
        return (result as? NSNumber)?.boolValue == true ? .success : .failure
    }

    // MARK: - Text markers

    /// WebKit's cross-process name for editing the text of marker ranges.
    static let textOperation = "AXTextOperation"

    /// What a web area that is itself the editable text, such as Mail's
    /// message body, must offer to be read and edited by UTF-16 offsets. It
    /// reports its selection and length only as text markers.
    static let markerEditing: Set<String> = [
        textOperation, "AXTextMarkerForIndex", "AXIndexForTextMarker", "AXStringForTextMarkerRange",
        kAXStringForRangeParameterizedAttribute,
    ]

    /// A marker's UTF-16 offset from the start of the element's text.
    func index(of marker: AXTextMarker) -> Int? {
        guard case let .success(value) = parameterized("AXIndexForTextMarker", marker),
              CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
        return (value as! NSNumber).intValue
    }

    /// The markers around a UTF-16 range of the element's text.
    func markers(for range: FieldRange) -> AXTextMarkerRange? {
        func marker(_ index: Int) -> AXTextMarker? {
            guard case let .success(value) = parameterized("AXTextMarkerForIndex", index as CFNumber),
                  CFGetTypeID(value) == AXTextMarkerGetTypeID() else { return nil }
            return (value as! AXTextMarker)
        }
        guard let start = marker(range.location), let end = marker(range.upperBound) else { return nil }
        return AXTextMarkerRangeCreate(nil, start, end)
    }

    /// The selection as UTF-16 offsets, from the offsets of its selection
    /// markers.
    func markerSelection() -> Result<FieldRange, AXFailure> {
        value("AXSelectedTextMarkerRange").flatMap { value in
            guard CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() else { return .failure(AXFailure(code: .noValue)) }
            let selected = value as! AXTextMarkerRange
            guard let start = index(of: AXTextMarkerRangeCopyStartMarker(selected)),
                  let end = index(of: AXTextMarkerRangeCopyEndMarker(selected)), start <= end
            else { return .failure(AXFailure(code: .noValue)) }
            return .success(FieldRange(location: start, length: end - start))
        }
    }

    /// A marker range as UTF-16 offsets, from the offsets of its two ends.
    func offsets(of markers: AXTextMarkerRange) -> FieldRange? {
        guard let start = index(of: AXTextMarkerRangeCopyStartMarker(markers)),
              let end = index(of: AXTextMarkerRangeCopyEndMarker(markers)), start <= end else { return nil }
        return FieldRange(location: start, length: end - start)
    }

    /// The UTF-16 length of the element's text, as its end marker's offset.
    func markerLength() -> Int? {
        guard case let .success(end) = value("AXEndTextMarker"), CFGetTypeID(end) == AXTextMarkerGetTypeID() else { return nil }
        return index(of: end as! AXTextMarker)
    }

    /// What a web field must offer for `rangedLength`.
    static let rangedLengthReads: Set<String> = ["AXTextMarkerRangeForUIElement", "AXLengthForTextMarkerRange"]

    /// The length of the element's text as its text markers measure it. In
    /// Chromium that is the length its selection and ranged reads address,
    /// which leaves out the break between block paragraphs.
    func rangedLength() -> Int? {
        guard let range = textMarkers(), case let .success(length) = parameterized("AXLengthForTextMarkerRange", range),
              CFGetTypeID(length) == CFNumberGetTypeID() else { return nil }
        return (length as! NSNumber).intValue
    }

    /// The marker range the element gives for its own text.
    func textMarkers() -> AXTextMarkerRange? {
        guard case let .success(range) = parameterized("AXTextMarkerRangeForUIElement", ref),
              CFGetTypeID(range) == AXTextMarkerRangeGetTypeID() else { return nil }
        return (range as! AXTextMarkerRange)
    }

    /// The length of the text between two markers, as the markers measure it.
    func length(from start: AXTextMarker, to end: AXTextMarker) -> Int? {
        guard case let .success(value) = parameterized("AXLengthForTextMarkerRange", AXTextMarkerRangeCreate(nil, start, end)),
              CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
        return (value as! NSNumber).intValue
    }

    func string(for markers: AXTextMarkerRange) -> Result<String, AXFailure> {
        parameterized("AXStringForTextMarkerRange", markers).flatMap { value in
            guard CFGetTypeID(value) == CFStringGetTypeID() else { return .failure(AXFailure(code: .noValue)) }
            return .success(value as! String)
        }
    }

    /// Replaces the text between two markers through WebKit's editing
    /// pipeline. WebKit answers with the text it wrote. `.failure` only when
    /// it answers with other text: a WebKit that does not know the operation
    /// selects the range and answers with the text already there. Any other
    /// answer leaves the write's effect unknown, so it counts as accepted
    /// and the readback decides.
    ///
    /// The plain replace operation recases the new text to match the text it
    /// replaces, lowercasing all of it over a lowercase word, so this asks
    /// for the case-preserving one. Smart replace is off because it adds
    /// spaces around the text.
    func replace(_ markers: AXTextMarkerRange, with text: String) -> AXError {
        let parameter = [
            "AXTextOperationType": "TextOperationReplacePreserveCase" as CFString,
            "AXTextOperationMarkerRanges": [markers] as CFArray,
            "AXTextOperationReplacementString": text as CFString,
            "AXTextOperationSmartReplace": kCFBooleanFalse!,
        ] as CFDictionary
        var result: CFTypeRef?
        let code = AXUIElementCopyParameterizedAttributeValue(ref, Self.textOperation as CFString, parameter, &result)
        guard code == .success else { return code }
        guard let written = result as? [String], !written.isEmpty else { return .success }
        return written == [text] ? .success : .failure
    }

    /// The nearest web area at or above the element, within a bounded walk
    /// of its ancestors: the page a web field is in, or the web area that
    /// is itself the field. Nil when there is none, or a role or parent
    /// does not answer. Roles are read, never text.
    func nearestWebArea(limit: Int = 40) -> AXElement? {
        var current = self
        for _ in 0..<limit {
            guard case let .success(role) = current.string(kAXRoleAttribute) else { return nil }
            if role == "AXWebArea" { return current }
            guard case let .success(parent) = current.element(kAXParentAttribute) else { return nil }
            current = parent
        }
        return nil
    }

    func setRange(_ attribute: String, _ range: FieldRange) -> AXError {
        var cfRange = range.cfRange
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return .illegalArgument }
        return AXUIElementSetAttributeValue(ref, attribute as CFString, value)
    }

    private func parameterized(_ attribute: String, range: FieldRange) -> Result<CFTypeRef, AXFailure> {
        var cfRange = range.cfRange
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else { return .failure(AXFailure(code: .illegalArgument)) }
        return parameterized(attribute, parameter)
    }

    func parameterized(_ attribute: String, _ parameter: CFTypeRef) -> Result<CFTypeRef, AXFailure> {
        var value: CFTypeRef?
        let code = AXUIElementCopyParameterizedAttributeValue(ref, attribute as CFString, parameter, &value)
        guard code == .success, let value else { return .failure(AXFailure(code: code == .success ? .noValue : code)) }
        return .success(value)
    }

    private static func axValue(_ value: CFTypeRef, _ type: AXValueType) -> AXValue? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        return AXValueGetType(axValue) == type ? axValue : nil
    }

    private static func decodeRange(_ value: CFTypeRef) -> Result<FieldRange, AXFailure> {
        var range = CFRange()
        guard let axValue = axValue(value, .cfRange), AXValueGetValue(axValue, .cfRange, &range) else {
            return .failure(AXFailure(code: .noValue))
        }
        return .success(FieldRange(range))
    }

    private static func decodePoint(_ value: CFTypeRef) -> Result<CGPoint, AXFailure> {
        var point = CGPoint.zero
        guard let axValue = axValue(value, .cgPoint), AXValueGetValue(axValue, .cgPoint, &point) else {
            return .failure(AXFailure(code: .noValue))
        }
        return .success(point)
    }

    private static func decodeSize(_ value: CFTypeRef) -> Result<CGSize, AXFailure> {
        var size = CGSize.zero
        guard let axValue = axValue(value, .cgSize), AXValueGetValue(axValue, .cgSize, &size) else {
            return .failure(AXFailure(code: .noValue))
        }
        return .success(size)
    }

    static func decodeRect(_ value: CFTypeRef) -> Result<CGRect, AXFailure> {
        var rect = CGRect.zero
        guard let axValue = axValue(value, .cgRect), AXValueGetValue(axValue, .cgRect, &rect) else {
            return .failure(AXFailure(code: .noValue))
        }
        return .success(rect)
    }
}
