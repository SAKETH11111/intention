import Foundation

/// The server's exact terminal footer, presented as a link only for accepted emails.
/// Georgia at 12px, since recipients' mail has no DM Sans, with no colour of
/// its own: the label and the link take the body's text colour, so each
/// client's dark view does to them what it does to the body and they read as
/// the body does. A fixed grey cannot read at 4.5:1 on both a light and a
/// dark view, and opacity is handled unevenly, so the footer is quiet by its
/// size and face. The link keeps the client's own underline. Until October
/// 10, 2026 it was #737C80, 4.27:1 on white and 3.77:1 on Gmail's dark view.
struct EmailFooter: Sendable {
    let renderedText: String
    let html: String

    init?(_ text: String) {
        guard let range = text.range(
            of: #"(?:\A|(?<=\n))(?:Sent with Intention|sent with intention) https://intention\.example/\?ref=[A-Za-z0-9_-]{12}\z"#,
            options: .regularExpression
        ) else { return nil }
        let prefix = String(text[..<range.lowerBound])
        let url = String(text[range].dropFirst("Sent with Intention ".count))
        renderedText = prefix + "sent with intention"
        html = "<span style=\"white-space: pre-wrap\">" + Self.escape(prefix)
            + "<span style=\"font-family:Georgia,'Times New Roman',serif;font-size:12px\">sent with "
            + "<a href=\"" + url + "\" style=\"color:inherit\">intention</a></span></span>"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\r", with: "&#13;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}
