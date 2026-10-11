import SwiftUI

/// The Settings sheet's sections and what each holds, in the order the
/// sheet shows them. The sheet draws from this table, so the tests that
/// read it read what a person sees: every setting in one place, Clear
/// history under Data and nowhere else.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, email, system, account, data

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .email: "Email"
        case .system: "System"
        case .account: "Account"
        case .data: "Data"
        }
    }

    /// The section's cards, each a list of its lines.
    var cards: [[SettingsItem]] {
        switch self {
        case .general: [[.dictationKey, .microphone, .languages]]
        case .email: [[.mailboxes], [.writesEmails, .draftsReplies, .sentWithIntention]]
        case .system: [[.opensAtLogin, .indicator, .dotPosition, .appearance]]
        case .account: [[.setup, .version, .reportProblem]]
        case .data: [[.clearHistory]]
        }
    }

    var items: [SettingsItem] { cards.flatMap { $0 } }
}

/// Everything a person can change or read in Settings.
enum SettingsItem: CaseIterable {
    /// The key held to dictate, and the recorder that changes it.
    case dictationKey
    case microphone
    /// The languages dictation listens for, up to five.
    case languages
    /// Each connected mailbox and its sync, Reconnect when the server asks,
    /// and the way to connect another.
    case mailboxes
    case writesEmails
    case draftsReplies
    /// "Sent with Intention" at the foot of each email Intention writes.
    case sentWithIntention
    case opensAtLogin
    /// Whether the dot also shows at the caret.
    case indicator
    /// Light or Dark, Light unless chosen.
    case appearance
    /// Where the dot at the foot of the screen rests: the bottom, the left
    /// or the right.
    case dotPosition
    /// Finishing setup, while it is not finished.
    case setup
    /// The version, and Check for updates when this build updates itself.
    case version
    /// The menu bar item's Report a problem, here as well.
    case reportProblem
    case clearHistory
}

/// A card of lines: paper on the desk, a half-point edge, the lines parted
/// by rules inset from its sides.
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .paper(radius: 10)
    }
}

/// One line of a card: its title, a sentence under it, and its control at
/// the right. Lines after the first are parted by a rule inset 16 points.
struct SettingsLine<Control: View>: View {
    let title: String
    var detail: String?
    /// A second sentence for something the person should act on, such as a
    /// refused key or a microphone that cannot hear, after the warm mark.
    var note: String?
    var isFirst = false
    @ViewBuilder let control: Control
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(SetupStyle.text(14, .semibold))
                    .foregroundStyle(palette.ink)
                if let detail {
                    Text(detail)
                        .font(SetupStyle.text(13))
                        .lineSpacing(2)
                        .foregroundStyle(palette.lead)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note {
                    SettingsNote(text: note)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 48)
        .overlay(alignment: .top) {
            if !isFirst { SettingsRule() }
        }
    }
}

/// Something to act on: the warm mark, then the line in ink.
struct SettingsNote: View {
    let text: String
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            AttentionMark()
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 0.5 }
            Text(text)
                .font(SetupStyle.text(13, .semibold))
                .lineSpacing(2)
                .foregroundStyle(palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The rule between two lines of a card, inset 16 points from its sides.
struct SettingsRule: View {
    @Environment(\.palette) private var palette

    var body: some View {
        Rectangle().fill(palette.rule).frame(height: 0.5).padding(.horizontal, 16)
    }
}

/// A switch in a Settings line: the spec's (`IntentionSwitch`).
typealias SettingsSwitch = IntentionSwitch

/// A menu's button in a Settings line, as the spec draws a picker: a small
/// paper seat button with what is chosen and a drawn chevron.
struct PopUpLabel: View {
    let title: String
    /// The chevron a picker has; a button that opens a menu of ticks, such
    /// as Add, leaves it out.
    var showsMarks = true
    /// Whether what it opens is open: the chevron points up.
    var isOpen = false
    @Environment(\.palette) private var palette
    @Environment(\.stillControlState) private var still
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let hovering = hovering || still == .hover
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        HStack(spacing: 8) {
            Text(title)
                .font(SetupStyle.text(12.5, .semibold))
                .foregroundStyle(palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                // A long device name gives way before the line's sentence,
                // which stays on one line.
                .frame(maxWidth: 180)
            if showsMarks {
                DrawnChevron()
                    .foregroundStyle(palette.faint)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
                    // It turns with the list it opens; under Reduce Motion
                    // it swaps.
                    .transaction { if reduceMotion { $0.animation = nil } }
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, showsMarks ? 9 : 11)
        .frame(height: 28)
        .background(hovering ? palette.paperButtonHover : palette.paperButton, in: shape)
        .overlay(shape.strokeBorder(palette.controlEdge, lineWidth: 0.5))
        .background(shape.fill(palette.paperSeat).offset(y: 1.5))
        .offset(y: hovering ? -0.5 : 0)
        .padding(.bottom, 1.5)
        .onHover { self.hovering = $0 }
        .contentShape(Rectangle())
    }
}
