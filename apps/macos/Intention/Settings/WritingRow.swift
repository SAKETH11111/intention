import SwiftUI

/// "Write emails for me", "Draft replies for me" and "Add ‘Sent with
/// Intention’ to emails Intention writes", the lines of the Email section's
/// second card. All three are on from the start and this is the one place
/// to turn them off; the words below each are the whole rule. Drafting
/// replies needs email writing and the dot, so its line is greyed, with
/// one line saying which is missing, while either is not there. It takes
/// its state as values, so `scripts/dot-shots.sh` can draw it without the
/// rest of the app.
struct WritingRow: View {
    @Binding var isOn: Bool
    /// What stands in the way of writing at the moment, from
    /// `EmailWriter.availability`; nil when nothing does.
    let availability: EmailWriter.Problem?
    @Binding var draftsReplies: Bool
    /// Whether the dot in emails is hidden, which leaves nothing at the
    /// reply's caret to show a draft by.
    let usesPill: Bool
    @Binding var addsSentWithIntention: Bool
    /// The dictation key as printed on the keyboard, for the first line's
    /// words.
    var keyName = "fn"

    var body: some View {
        writesLine
        draftsLine
        sentWithIntentionLine
    }

    var writesLine: some View {
        SettingsLine(title: Self.writesTitle, detail: Self.explanation(keyName: keyName),
                     note: isOn ? availability.flatMap(Self.words(for:)) : nil, isFirst: true) {
            SettingsSwitch(title: Self.writesTitle, isOn: $isOn)
        }
    }

    var draftsLine: some View {
        let blocked = Self.draftsBlocked(writesEmails: isOn, usesPill: usesPill)
        return SettingsLine(title: Self.draftsTitle, detail: Self.draftsExplanation, note: blocked) {
            SettingsSwitch(title: Self.draftsTitle, isOn: $draftsReplies)
                .disabled(blocked != nil)
        }
    }

    var sentWithIntentionLine: some View {
        SettingsLine(title: Self.sentWithIntentionTitle) {
            SettingsSwitch(title: Self.sentWithIntentionTitle, isOn: $addsSentWithIntention)
        }
    }

    static let writesTitle = "Write emails for me"
    static let draftsTitle = "Draft replies for me"
    static let sentWithIntentionTitle = "Add \u{2018}Sent with Intention\u{2019} to emails Intention writes"

    static func explanation(keyName: String) -> String {
        "In an email you're writing, hold \(keyName) and say what you want to say. Intention writes it in your voice."
    }

    static let draftsExplanation = "When you open a reply in Gmail, Intention proposes one at the cursor. Tab puts it in your draft. Intention never sends."

    /// Why drafting replies cannot be turned on now, or nil when it can.
    /// Email writing off is named first, since turning on the dot alone
    /// would not be enough.
    static func draftsBlocked(writesEmails: Bool, usesPill: Bool) -> String? {
        if !writesEmails { return "Drafts need email writing on" }
        if usesPill { return "Turn on Dot in emails, in System" }
        return nil
    }

    /// Why emails are typed rather than written at the moment, for a state
    /// that will not change by dictating again.
    static func words(for problem: EmailWriter.Problem) -> String? {
        switch problem {
        case .notConfigured: "This build has no Intention server, so emails are typed as you say them."
        case .signedOut: "Emails are written once Intention is signed in; until then they are typed as you say them."
        case .unavailable: "Writing isn't available yet on Intention's server, so emails are typed as you say them."
        default: nil
        }
    }
}
