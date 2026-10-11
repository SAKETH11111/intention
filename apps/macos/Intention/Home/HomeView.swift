import AppKit
import SwiftUI

/// What the main window shows besides the history itself: whether Settings
/// is over it and on which section, the row under the pointer, the emails
/// whose words are folded out, and the search. The window keeps one for as
/// long as it lives, so reopening it finds Home as it was left.
@MainActor
@Observable
final class MainWindowState: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        settings = nil
        hoveredRow = nil
    }
    var settings: SettingsSection?
    var hoveredRow: HistoryRow.ID?
    var unfolded: Set<HistoryRow.ID> = []
    var search = ""

    /// Home's page: the painting with "Say something" until the first
    /// dictation, then the list, even when a search matches nothing.
    enum Page: Equatable { case firstLaunch, home }

    static func page(historyIsEmpty: Bool) -> Page {
        historyIsEmpty ? .firstLaunch : .home
    }
}

/// Home: the painted band with the week's numbers, then a sheet of paper
/// with a search field and every dictation grouped by day, newest first;
/// or, before the first dictation, the band and a sheet that says what to
/// do. It reads the history and asks for everything it does through `act`,
/// so it holds no rules of its own.
struct HomeView: View {
    let history: DictationHistory
    @Bindable var state: MainWindowState
    /// The dictation key as printed on the keyboard, for first launch.
    let keyName: String
    let retryEnabled: Bool
    let act: (HistoryRow, RowPresentation.Action) -> Void
    let openSettings: () -> Void
    /// What Intention has read of the person's sent mail, or that it is ready
    /// to write as them (`LearningProgress.label`); nil with no mailbox.
    var learningLabel: String? = nil
    /// The share read, 0...1, only when the server reports a total.
    var learningFraction: Double? = nil
    var learningDetail: String? = nil
    @Environment(\.palette) private var palette

    var body: some View {
        // Redrawn at each midnight, so Today and Yesterday move on and the
        // week's words start again, and otherwise only when history or
        // the search changes.
        TimelineView(MidnightSchedule()) { context in
            ZStack(alignment: .top) {
                Band()
                switch MainWindowState.page(historyIsEmpty: history.isEmpty) {
                case .firstLaunch:
                    FirstLaunchView(keyName: keyName, learningLabel: learningLabel, learningFraction: learningFraction, learningDetail: learningDetail)
                        .sheetOfList()
                case .home:
                    home(now: context.date)
                }
            }
        }
        .overlay(alignment: .top) { TitleBar(openSettings: openSettings) }
        .frame(minWidth: HomeStyle.minimumSize.width, minHeight: HomeStyle.minimumSize.height)
        .background(palette.ground)
        .ignoresSafeArea()
        .foregroundStyle(palette.ink)
    }

    private func home(now: Date) -> some View {
        let calendar = Calendar.current
        return ZStack(alignment: .top) {
            StatsStrip(stats: history.stats(now: now, calendar: calendar))
                .padding(.top, HomeStyle.statsTop)
                .column()
            VStack(alignment: .leading, spacing: 0) {
                if let learningLabel {
                    LearningLine(label: learningLabel, fraction: learningFraction, detail: learningDetail)
                        .padding(.top, 20)
                        .padding(.horizontal, HomeStyle.rowInset + 6)
                        .transition(.opacity)
                }
                SearchField(text: $state.search)
                    .padding(.top, learningLabel == nil ? 20 : 18)
                    .padding(.horizontal, HomeStyle.rowInset + 6)
                HistoryList(sections: history.sections(matching: state.search, now: now, calendar: calendar),
                            search: state.search, state: state, retryEnabled: retryEnabled, act: act)
            }
            .sheetOfList()
        }
    }

    /// Now, then successive local midnights for as long as the view lives.
    nonisolated static func schedule(from date: Date, calendar: Calendar) -> MidnightSchedule.Entries {
        MidnightSchedule.Entries(nextDate: date, calendar: calendar)
    }
}

struct MidnightSchedule: TimelineSchedule {
    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        HomeView.schedule(from: startDate, calendar: .current)
    }

    struct Entries: Sequence, IteratorProtocol {
        var nextDate: Date?
        let calendar: Calendar

        mutating func next() -> Date? {
            guard let date = nextDate else { return nil }
            nextDate = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
            return date
        }
    }
}

private extension View {
    /// The column the stats and the list share: 860 points, or less in a
    /// narrow window, centred.
    func column() -> some View {
        frame(maxWidth: HomeStyle.column, alignment: .leading)
            .padding(.horizontal, HomeStyle.margin)
            .frame(maxWidth: .infinity)
    }

    /// The one sheet of paper Home's list lies on: the column with a margin
    /// of paper, from under the numbers to past the window's foot, so it
    /// reads as a page on the desk.
    func sheetOfList() -> some View {
        frame(maxWidth: HomeStyle.column + HomeStyle.sheetInset * 2, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, HomeStyle.sheetInset - HomeStyle.rowInset)
            .modifier(SheetFoot())
            .paper(radius: 14)
            .padding(.horizontal, HomeStyle.margin - HomeStyle.sheetInset)
            .padding(.top, HomeStyle.listTop)
            .padding(.bottom, -20)
            .frame(maxWidth: .infinity)
    }
}

/// The list fades into the paper at the window's foot.
private struct SheetFoot: ViewModifier {
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            LinearGradient(colors: [palette.sheet.opacity(0), palette.sheet], startPoint: .top, endPoint: .bottom)
                .frame(height: 56)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// The painting across the top, the day's or the night's, fading into the
/// desk. A still image: nothing in it moves or redraws.
private struct Band: View {
    @Environment(\.palette) private var palette

    var body: some View {
        GeometryReader { proxy in
            let width = max(HomeStyle.windowSize.width, proxy.size.width)
            let height = width * Painting.aspect
            Image(nsImage: palette.isNight ? Painting.night : Painting.image)
                .resizable()
                .frame(width: width, height: height)
                // The mockup's "center 56%": the band shows the sky and the
                // hills; by night, the moon and the stars above them.
                .offset(y: (HomeStyle.bandHeight - height) * (palette.isNight ? 0.5 : 0.56))
                .frame(width: proxy.size.width, height: HomeStyle.bandHeight + 40, alignment: .top)
                .clipped()
        }
        .frame(height: HomeStyle.bandHeight + 40)
        .overlay {
            LinearGradient(stops: [.init(color: palette.ground.opacity(0), location: 0.45),
                                   .init(color: palette.ground.opacity(0.8), location: 0.8),
                                   .init(color: palette.ground, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .accessibilityHidden(true)
    }
}

/// The watercolours, loaded once: setup's day, and the night.
@MainActor
enum Painting {
    static let image = SetupStyle.image("SetupPanorama", "jpg")
    static let night = SetupStyle.image("HomePanoramaNight", "jpg")
    /// Height over width; both files are 2400 by 1188 pixels.
    static let aspect: CGFloat = 1188.0 / 2400.0
}

/// The wordmark where a title would be, and Settings at the right, over
/// the painting.
private struct TitleBar: View {
    let openSettings: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack(alignment: .top) {
            Image(nsImage: Wordmark.image)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 15)
                .foregroundStyle(palette.ink)
                .padding(.top, 17)
                .accessibilityHidden(true)
            HStack {
                Spacer()
                Button("Settings", action: openSettings)
                    .buttonStyle(SeatButtonStyle(isSmall: true))
                    .keyboardShortcut(",", modifiers: .command)
                    .accessibilityLabel("Settings")
            }
            .padding(.top, 11)
            .padding(.trailing, 16)
        }
    }
}

/// The wordmark, as a template so it takes the ink of either appearance.
@MainActor
private enum Wordmark {
    static let image: NSImage = {
        let image = SetupStyle.image("SetupWordmark", "pdf")
        image.isTemplate = true
        return image
    }()
}

/// Words this week, words per minute and emails Intention wrote: Own Hand
/// numerals with a few words beside each.
private struct StatsStrip: View {
    let stats: HistoryStats
    @Environment(\.palette) private var palette

    var body: some View {
        // Closer together in a narrow window, rather than cut off.
        ViewThatFits(in: .horizontal) {
            numbers(spacing: 48)
            numbers(spacing: 28)
        }
    }

    private func numbers(spacing: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: spacing) {
            stat(stats.wordsThisWeek.formatted(), stats.wordsThisWeek == 1 ? "word this week" : "words this week")
            // A dash until there is speech to divide the words by.
            stat(stats.wordsPerMinute?.formatted() ?? "\u{2013}", "words per minute",
                 spoken: stats.wordsPerMinute == nil ? "Words per minute: not measured yet" : nil)
            stat(stats.emailsWritten.formatted(), stats.emailsWritten == 1 ? "email Intention wrote" : "emails Intention wrote")
        }
    }

    private func stat(_ number: String, _ label: String, spoken: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(number)
                .font(SetupStyle.display(32))
                .tracking(0.32)
                .foregroundStyle(palette.ink)
            Text(label)
                .font(SetupStyle.text(13, .semibold))
                .foregroundStyle(palette.lead)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken ?? "\(number) \(label)")
    }
}

/// The search over the list, always in view above it: the spec's field.
private struct SearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool
    @Environment(\.palette) private var palette
    @Environment(\.stillControlState) private var still

    var body: some View {
        HStack(spacing: 8) {
            WindowIcon(name: .search, size: 14)
                .foregroundStyle(palette.secondary)
            TextField("Search", text: $text, prompt: Text("Search").foregroundStyle(palette.secondary))
                .textFieldStyle(.plain)
                .font(SetupStyle.text(14))
                .foregroundStyle(palette.ink)
                .focused($focused)
                .accessibilityLabel("Search history")
                .onExitCommand { text = "" }
        }
        .wellField(isFocused: focused || still == .focused, height: 34)
        .frame(width: 300)
    }
}

/// The days, each under its label, and their rows.
private struct HistoryList: View {
    let sections: [HistorySection]
    let search: String
    let state: MainWindowState
    let retryEnabled: Bool
    let act: (HistoryRow, RowPresentation.Action) -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if sections.isEmpty {
                    Text("Nothing matches your search.")
                        .font(SetupStyle.text(14))
                        .foregroundStyle(palette.secondary)
                        .padding(.top, 28)
                        .padding(.leading, HomeStyle.rowInset + 6)
                }
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    Text(section.title)
                        .font(SetupStyle.text(11, .semibold))
                        .tracking(0.88)
                        .textCase(.uppercase)
                        .foregroundStyle(palette.secondary)
                        .padding(.horizontal, HomeStyle.rowInset + 6)
                        .padding(.top, index == 0 ? 22 : 30)
                        .padding(.bottom, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(section.rows) { row in
                        HistoryRowView(row: row, isHovered: state.hoveredRow == row.id, isUnfolded: state.unfolded.contains(row.id),
                                       retryEnabled: retryEnabled, act: { act(row, $0) },
                                       hover: { inside in
                                           if inside { state.hoveredRow = row.id } else if state.hoveredRow == row.id { state.hoveredRow = nil }
                                       },
                                       toggleFold: {
                                           if state.unfolded.contains(row.id) { state.unfolded.remove(row.id) } else { state.unfolded.insert(row.id) }
                                       })
                    }
                }
            }
            .padding(.bottom, 56)
        }
        .scrollIndicators(.automatic)
    }
}

/// Before the first dictation: the resting dot, the page's one heading and
/// what to do, on the sheet. It goes once there is a dictation to show.
struct FirstLaunchView: View {
    let keyName: String
    var learningLabel: String? = nil
    var learningFraction: Double? = nil
    var learningDetail: String? = nil
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 14) {
            RestingDot(diameter: 11)
            SetupHeading(title: "Say something", delay: 0.2, size: 32)
                .padding(.bottom, 8)
            (Text("Hold ") + Text(Image(nsImage: HomeStyle.keycaps(keyName, palette: palette))).baselineOffset(-6)
                + Text(" and speak. The words go in where your cursor is.\nEverything you dictate shows up here."))
                .font(SetupStyle.text(14))
                .lineSpacing(5)
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.lead)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Hold \(keyName) and speak. The words go in where your cursor is. Everything you dictate shows up here.")
            if let learningLabel {
                LearningLine(label: learningLabel, fraction: learningFraction, detail: learningDetail)
                    .padding(.top, 22)
            }
        }
        // Centred in the part of the sheet the window shows, a little high.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 90)
        .accessibilityElement(children: .combine)
    }
}
