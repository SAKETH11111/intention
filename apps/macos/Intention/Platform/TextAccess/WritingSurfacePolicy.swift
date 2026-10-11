import Foundation

/// Metadata-only admission shared by caret observation, capture and
/// insertion. Every app is in scope, code editors and terminals included, as
/// they are for other dictation apps; what a field's metadata says decides,
/// and a secure field is always refused. User-facing labels and text never
/// grant an exception.
enum WritingSurfacePolicy {
    /// What an element answered for one attribute.
    enum Answer: Equatable, Sendable {
        case text(String)
        /// It has none: unsupported, or no value.
        case absent
        /// A generic failure, as AppKit's toolbar groups answer.
        case genericFailure
        /// A timeout or any other error.
        case unanswered
        /// Something that is not text.
        case unexpected
    }

    /// Whether one element of a field's ancestry marks it secure, by subrole
    /// or by role: true when either says so, nil when that cannot be told,
    /// false when neither does. Every answer must come back as text or as
    /// none; an ancestor's generic failure counts as none, as AppKit's
    /// toolbar groups give it, but the focused element must answer itself.
    static func secure(subrole: Answer, role: Answer, focused: Bool) -> Bool? {
        if subrole == .text("AXSecureTextField") || role == .text("AXSecureTextField") { return true }
        for answer in [subrole, role] {
            switch answer {
            case .text, .absent: continue
            case .genericFailure where !focused: continue
            default: return nil
            }
        }
        return false
    }

    /// What a window, or one element of it, says about text in it.
    enum Exposure: Equatable, Sendable {
        case nothing
        case text
        /// A field secure by role or subrole, or an element that did not
        /// say what it is: the person's cursor could be in a password field.
        case secure
    }

    /// One element's part in `AXWritingSurface.exposure(of:)`. Only an
    /// element whose role answers and is no text role, and whose subrole
    /// answers or is a toolbar group's generic failure and is not secure,
    /// is nothing.
    static func exposure(role: Answer, subrole: Answer) -> Exposure {
        if role == .text("AXSecureTextField") || subrole == .text("AXSecureTextField") { return .secure }
        guard case let .text(role) = role else { return .secure }
        switch subrole {
        case .unanswered, .unexpected: return .secure
        case .text, .absent, .genericFailure: break
        }
        return ["AXTextField", "AXTextArea", "AXComboBox", "AXWebArea"].contains(role) ? .text : .nothing
    }

    /// Chromium browsers build their web tree only for a client that sets
    /// `AXEnhancedUserInterface`, and answer their own bootstrap, so they are
    /// never taken for an app without accessible text. Google Chrome's
    /// channels share the stable identifier's prefix; the others are
    /// Chromium's own builds and browsers on it.
    static func isChromiumBrowser(bundleIdentifier: String?) -> Bool {
        guard let id = bundleIdentifier?.lowercased() else { return false }
        return id.hasPrefix("com.google.chrome") || id.hasPrefix("com.microsoft.edgemac") || id.hasPrefix("com.brave.browser")
            || ["org.chromium.chromium", "company.thebrowser.browser", "com.vivaldi.vivaldi", "com.operasoftware.opera",
                "ai.perplexity.comet"].contains(id)
    }

    /// Terminal's text area takes typing but reports neither its value nor
    /// its selected text as settable, only its selection range. Other
    /// read-only text, which draws no caret, stays unadmitted.
    static func admitsTypingWithoutSettableText(bundleIdentifier: String?, role: String) -> Bool {
        bundleIdentifier?.lowercased() == "com.apple.terminal" && role == "AXTextArea"
    }

    // A web view whose whole document is editable, such as Mail's message
    // body, has keyboard focus on its web area and no text control inside.
    // `editableDocument` admits that focus too, for callers that then
    // require the web area's value to be settable, which is how WebKit marks
    // an editable document. Pixel capture never asks for it, so a message
    // body is never captured.
    static func allowsMetadata(role: String, subrole: String?, focused: Bool, editableDocument: Bool = false) -> Bool {
        guard [role, subrole ?? ""].allSatisfy({ $0.lowercased() != "axsecuretextfield" }) else { return false }
        return !focused || ["AXTextField", "AXTextArea", "AXComboBox"].contains(role) || (editableDocument && role == "AXWebArea")
    }
}

/// Outlook's web body identity, shared by compose admission and insertion
/// readback. The label alone also appears in its read-only message pane.
enum OutlookBodyIdentity {
    static let hosts: Set<String> = ["outlook.office.com", "outlook.live.com"]
    static let descriptions: Set<String> = ["Message body", "Message body, press Alt+F10 to exit"]
}

/// Gmail localizes its aria-label. Its editor classes identify the same body
/// in every language; callers also require the text-area role and Gmail host.
enum GmailBodyIdentity {
    static let host = "mail.google.com"
    static let description = "Message Body"

    static func matches(description: String, classes: Set<String>?) -> Bool {
        description.trimmingCharacters(in: .whitespaces) == Self.description
            || classes?.isSuperset(of: ["Am", "editable"]) == true
    }
}
