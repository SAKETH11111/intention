import AppKit
import SwiftUI

/// What one Home row shows and offers, from the model's `HistoryRow`: its
/// words, the Email tag, the one quiet line under it, the buttons, what
/// folds out, the tooltip and what VoiceOver reads. Pure, so
/// `./dev mac-dictation-test` reads it without drawing.
struct RowPresentation: Equatable {
    enum Action: Equatable {
        case copy, retry, switchMicrophone

        var title: String {
            switch self {
            case .copy: "Copy"
            case .retry: "Retry"
            case .switchMicrophone: "Switch mic"
            }
        }

        var accessibilityTitle: String {
            switch self {
            case .copy: "Copy"
            case .retry: "Retry this dictation"
            case .switchMicrophone: "Switch microphone"
            }
        }
    }

    let time: String
    /// The words as paragraphs, or empty when the row has none to show.
    let paragraphs: [String]
    /// Said in the words' place, quietly: what was heard from which
    /// microphone, or that the words are hidden.
    let placeholder: String?
    let showsEmailTag: Bool
    /// The one line under the words: "Didn't go in", and nothing for a
    /// dictation that went in.
    let status: String?
    let languageNote: String?
    /// The buttons on the status line, or beside a placeholder that stands
    /// alone, in order.
    let actions: [Action]
    /// Whether Copy appears at the row's end under the pointer. A row that
    /// already offers Copy, or has nothing to copy, does not.
    let copiesOnHover: Bool
    /// What the person said, for an email Intention wrote from it.
    let spoken: String?
    /// Why it did not go in, for the tooltip.
    let tooltip: String?
    let accessibilityLabel: String

    static let didNotGoIn = "Didn't go in"
    static let hidden = "Hidden text"
    static let noWords = "No words came back"

    init(_ row: HistoryRow, time: Date.FormatStyle = Date.FormatStyle(date: .omitted, time: .shortened)) {
        self.time = row.date.formatted(time)
        languageNote = row.languageNote
        let words = row.isConcealed ? [] : row.text.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        paragraphs = words
        switch row.kind {
        case .dictation:
            showsEmailTag = false
            spoken = nil
        case let .email(said):
            showsEmailTag = true
            spoken = said.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        case .proposal:
            showsEmailTag = true
            spoken = nil
        }
        switch row.state {
        case .inserted:
            placeholder = row.isConcealed ? Self.hidden : nil
            status = nil
            actions = []
            copiesOnHover = row.isConcealed || !words.isEmpty
            tooltip = nil
        case .didNotGoIn:
            placeholder = row.isConcealed ? Self.hidden : words.isEmpty ? Self.noWords : nil
            status = Self.didNotGoIn
            actions = [.copy] + (row.canRetry ? [.retry] : [])
            copiesOnHover = false
            tooltip = row.reason
        case .uncertain:
            placeholder = row.isConcealed ? Self.hidden : nil
            status = "May have gone in. Check before pasting again"
            actions = [.copy]
            copiesOnHover = false
            tooltip = nil
        case .failed:
            placeholder = row.reason ?? "The dictation server could not finish it."
            status = nil
            actions = row.canRetry ? [.retry] : []
            copiesOnHover = false
            tooltip = nil
        case let .heardNothing(device):
            placeholder = device.map { "Heard nothing from \($0)" } ?? "Heard nothing"
            status = nil
            actions = (row.canRetry ? [.retry] : []) + [.switchMicrophone]
            copiesOnHover = false
            tooltip = nil
        }
        // One sentence per part, so VoiceOver pauses between them; the
        // reason is read here since a tooltip never is.
        var parts = [self.time]
        if showsEmailTag { parts.append("Email") }
        parts.append(placeholder ?? words.joined(separator: " "))
        if let status { parts.append(tooltip.map { "\(status). \($0)" } ?? status) }
        if let languageNote { parts.append(languageNote) }
        accessibilityLabel = parts.map { $0.hasSuffix(".") || $0.hasSuffix("?") || $0.hasSuffix("!") ? $0 : $0 + "." }
            .joined(separator: " ")
    }
}

/// One row of Home, as the spec draws a list row: the words on one line,
/// and under them a quiet line with the time, the drawn check for an email
/// Intention wrote or the warm mark for one that didn't go in, and anything to
/// do. A click unfolds the whole text, and for an email what was said;
/// Copy shows at the row's end under the pointer.
struct HistoryRowView: View {
    let row: HistoryRow
    let isHovered: Bool
    let isUnfolded: Bool
    /// Retry waits while a dictation records or is on its way, as the old
    /// history window's did.
    let retryEnabled: Bool
    let act: (RowPresentation.Action) -> Void
    let hover: (Bool) -> Void
    let toggleFold: () -> Void
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The widths of the folded line's words as set and as drawn; the
    /// first wider means the line is cut off.
    @State private var wordsWidth: CGFloat = 0
    @State private var lineWidth: CGFloat = 0

    /// Whether the row has more than its folded line shows: what was said,
    /// a second paragraph, or words cut off at the line's end. Only such a
    /// row shows the chevron and unfolds.
    static func folds(_ shown: RowPresentation, isCut: Bool) -> Bool {
        shown.spoken != nil || shown.paragraphs.count > 1 || isCut
    }

    var body: some View {
        let shown = RowPresentation(row)
        let folds = isUnfolded || Self.folds(shown, isCut: wordsWidth > lineWidth + 0.5)
        VStack(alignment: .leading, spacing: 4) {
            words(shown)
                .frame(maxWidth: HomeStyle.textWidth, alignment: .leading)
            if isUnfolded, let spoken = shown.spoken {
                said(spoken)
            }
            meta(shown)
            if let note = shown.languageNote {
                Text(note)
                    .font(SetupStyle.text(13))
                    .foregroundStyle(palette.secondary)
            }
        }
        .padding(.vertical, 10)
        .padding(.leading, HomeStyle.rowInset + 6)
        .padding(.trailing, HomeStyle.copyRoom + 24)
        .frame(maxWidth: .infinity, minHeight: HomeStyle.rowHeight, alignment: .leading)
        .contentShape(Rectangle())
        // Unfolding is a click anywhere on a folded row; an unfolded one
        // folds from its chevron's line, so selecting its words does not.
        .onTapGesture { if folds, !isUnfolded { toggleFold() } }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 14) {
                // Copy under the pointer, and on an unfolded row, which a
                // click has already picked out.
                if shown.copiesOnHover, isHovered || isUnfolded {
                    Button("Copy") { act(.copy) }
                        .buttonStyle(WordButtonStyle())
                        .accessibilityLabel(RowPresentation.Action.copy.accessibilityTitle)
                        .transition(.opacity)
                }
                if folds {
                    // Folds an unfolded row; a folded one unfolds from
                    // anywhere on it.
                    Button { toggleFold() } label: {
                        DrawnChevron(direction: isUnfolded ? .down : .right)
                            .foregroundStyle(isHovered ? palette.secondary : palette.faint)
                            .frame(width: 22, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardFocusRing(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .accessibilityHidden(true)
                }
            }
            .padding(.top, 10)
            .padding(.trailing, 12)
        }
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? palette.ink.opacity(0.05) : .clear)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(isHovered ? .clear : palette.rule).frame(height: 0.5).padding(.horizontal, HomeStyle.rowInset)
        }
        .animation(reduceMotion ? nil : SetupStyle.quick, value: isHovered)
        .animation(reduceMotion ? nil : SetupStyle.quick, value: isUnfolded)
        .onHover(perform: hover)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(shown.accessibilityLabel)
        .accessibilityActions {
            if shown.copiesOnHover {
                Button(RowPresentation.Action.copy.accessibilityTitle) { act(.copy) }
            }
            if folds {
                Button(isUnfolded ? "Show less" : "Show all") { toggleFold() }
            }
        }
    }

    /// The words on one line, or all of them unfolded; or the quiet line
    /// said in their place.
    @ViewBuilder private func words(_ shown: RowPresentation) -> some View {
        if let placeholder = shown.placeholder {
            // Wraps rather than cuts: a microphone's name or why it failed
            // is what the person needs to read.
            Text(placeholder)
                .font(SetupStyle.text(14))
                .foregroundStyle(palette.lead)
                .fixedSize(horizontal: false, vertical: true)
        } else if isUnfolded {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(shown.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(SetupStyle.text(14))
                        .lineSpacing(HomeStyle.textLeading)
                        .foregroundStyle(palette.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            let line = shown.paragraphs.joined(separator: " ")
            Text(line)
                .font(SetupStyle.text(14))
                .foregroundStyle(palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { lineWidth = $0 }
                .background(alignment: .leading) {
                    // The same words at their own width, never drawn.
                    Text(line)
                        .font(SetupStyle.text(14))
                        .fixedSize()
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { wordsWidth = $0 }
                }
        }
    }

    /// The quiet line: the drawn check for an email Intention wrote that went
    /// in, the warm mark for one that didn't, "Email" for an email, the
    /// time, then what can be done.
    private func meta(_ shown: RowPresentation) -> some View {
        HStack(alignment: .center, spacing: 7) {
            if shown.status != nil {
                AttentionMark()
            } else if shown.showsEmailTag, shown.placeholder == nil {
                DrawnCheck().scaleEffect(0.78).frame(width: 13, height: 11)
            }
            Text(([shown.status, shown.showsEmailTag ? "Email" : nil, shown.time] as [String?]).compactMap { $0 }.joined(separator: ", "))
                .font(SetupStyle.text(13))
                .monospacedDigit()
                .foregroundStyle(shown.status != nil ? palette.lead : palette.secondary)
                // The reason only under the pointer, and to VoiceOver,
                // which reads it, with these words, in the row's label.
                .help(shown.tooltip ?? "")
                .accessibilityHidden(true)
            if !shown.actions.isEmpty {
                HStack(spacing: 14) {
                    ForEach(shown.actions, id: \.title) { action in
                        Button(action.title) { act(action) }
                            .buttonStyle(WordButtonStyle())
                            .disabled(action == .retry && !retryEnabled)
                            .accessibilityLabel(action.accessibilityTitle)
                    }
                }
                .padding(.leading, 8)
            }
        }
    }

    /// What was said, for an email Intention wrote from it, under the sky's
    /// rule as the spec quotes.
    private func said(_ spoken: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("What you said")
                .font(SetupStyle.text(11, .semibold))
                .tracking(0.88)
                .textCase(.uppercase)
                .foregroundStyle(palette.secondary)
            Text(spoken)
                .font(SetupStyle.text(13))
                .lineSpacing(3)
                .foregroundStyle(palette.lead)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .padding(.leading, 12)
        .overlay(alignment: .leading) { Rectangle().fill(palette.isNight ? palette.skyInk.opacity(0.6) : palette.sky).frame(width: 2) }
        .padding(.top, 4)
        .padding(.bottom, 2)
        .transition(.opacity)
    }
}
