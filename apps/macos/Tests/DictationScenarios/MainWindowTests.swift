import AppKit
import Foundation
@testable import Dictation
import SwiftUI
import Testing

/// The main window's views over the history model's rows: what each row
/// shows, offers and reads to VoiceOver in each state and kind, that a
/// row's unfolded words change its height while the pointer
/// does not, when first launch shows, and which Settings section holds
/// each setting. The rows come from `DictationHistory.sections`, as the
/// window takes them; the expected words are the approved design's.
@MainActor
struct MainWindowTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        value.locale = Locale(identifier: "en_US_POSIX")
        return value
    }

    private var now: Date { ISO8601DateFormatter().date(from: "2026-10-08T23:12:00Z")! }

    /// The time as macOS writes it, with a narrow space before PM.
    private let time = "4:12\u{202F}PM"

    private var clock: Date.FormatStyle {
        Date.FormatStyle(date: .omitted, time: .shortened, locale: Locale(identifier: "en_US_POSIX"), calendar: calendar,
                         timeZone: calendar.timeZone)
    }

    /// The rows the window would show for these entries, newest first.
    private func rows(_ entries: [DictationHistory.Entry], keepAudioFor kept: Set<UUID> = []) -> [HistoryRow] {
        let history = DictationHistory(file: nil)
        for entry in entries.reversed() {
            history.add(entry, retry: kept.contains(entry.id) ? .init(chunks: [Data([1, 2])], start: .init(register: "other")) : nil)
        }
        return history.sections(matching: "", now: now, calendar: calendar).flatMap(\.rows)
    }

    private func entry(_ text: String, _ outcome: DictationHistory.Entry.Outcome = .inserted, reason: String? = nil,
                       spoken: String? = nil, proposal: DictationHistory.Entry.Proposal? = nil, device: String? = nil) -> DictationHistory.Entry {
        var value = DictationHistory.Entry(id: UUID(), date: now, text: text, outcome: outcome, reason: reason, spoken: spoken)
        value.proposal = proposal
        value.device = device
        return value
    }

    @Test(arguments: [Palette.day, Palette.night])
    func keycapImagesFillTheirRetinaPixelBounds(palette: Palette) throws {
        for image in [HomeStyle.keycaps("fn", palette: palette), HomeStyle.keycaps("control + option", palette: palette)] {
            let pixels = try #require(image.representations.first as? NSBitmapImageRep)
            #expect(pixels.pixelsWide == Int(ceil(image.size.width * 2)))
            #expect(pixels.pixelsHigh == Int(ceil(image.size.height * 2)))
            var left = pixels.pixelsWide
            var right = -1
            var top = pixels.pixelsHigh
            var bottom = -1
            for y in 0..<pixels.pixelsHigh {
                for x in 0..<pixels.pixelsWide where (pixels.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                    left = min(left, x)
                    right = max(right, x)
                    top = min(top, y)
                    bottom = max(bottom, y)
                }
            }
            // Rounded corners and antialiasing can leave a pixel at an edge.
            #expect(left <= 1)
            #expect(top <= 1)
            #expect(right >= pixels.pixelsWide - 2)
            #expect(bottom >= pixels.pixelsHigh - 2)
            // The rounded outer corners must survive too; a second scale
            // can fill the bounds while clipping the enlarged label.
            for x in [0, pixels.pixelsWide - 1] {
                for y in [0, pixels.pixelsHigh - 1] {
                    #expect((pixels.colorAt(x: x, y: y)?.alphaComponent ?? 0) < 0.1)
                }
            }
        }
    }

    @Test func keycapImagesCanBeDrawnFromABackgroundTask() async {
        let image = HomeStyle.keycaps("control + option")
        let drawn = await Task.detached {
            image.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil
        }.value
        #expect(drawn)
    }

    @Test func closingARetainedWindowDismissesSettingsAndStopsItsTask() async throws {
        let state = MainWindowState()
        state.settings = .email
        let polls = WindowPolls()
        let host = NSHostingView(rootView: SettingsTaskFixture(state: state, polls: polls))
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 300, height: 100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.delegate = state
        host.layoutSubtreeIfNeeded()
        for _ in 0..<100 where polls.count == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(polls.count > 0)
        window.close()
        for _ in 0..<100 where !polls.cancelled { try await Task.sleep(for: .milliseconds(10)) }
        #expect(state.settings == nil)
        #expect(polls.cancelled)
        let atClose = polls.count
        try await Task.sleep(for: .milliseconds(50))
        #expect(polls.count == atClose)
        #expect(window.contentView === host)
    }

    @Test func midnightScheduleContinuesPastTheThirtySecondDay() throws {
        let start = calendar.startOfDay(for: now)
        let values = Array(HomeView.schedule(from: start, calendar: calendar).prefix(65))
        #expect(values.count == 65)
        if values.count == 65 {
            #expect(values[32] == calendar.date(byAdding: .day, value: 32, to: start))
            #expect(values[64] == calendar.date(byAdding: .day, value: 64, to: start))
        }
    }

    @Test func aDictationThatWentInHasNoLabelAndCopiesUnderThePointer() throws {
        let row = try #require(rows([entry("Can we move the standup to ten tomorrow?")]).first)
        let shown = RowPresentation(row, time: clock)
        #expect(shown.time == time)
        #expect(shown.paragraphs == ["Can we move the standup to ten tomorrow?"])
        #expect(shown.placeholder == nil)
        #expect(shown.status == nil)
        #expect(shown.actions.isEmpty)
        #expect(shown.copiesOnHover)
        #expect(!shown.showsEmailTag)
        #expect(shown.spoken == nil)
        #expect(shown.tooltip == nil)
        #expect(shown.accessibilityLabel == "\(time). Can we move the standup to ten tomorrow?")
    }

    @Test func oneThatDidNotGoInSaysSoWithCopyAndKeepsItsReasonForTheTooltipAndVoiceOver() throws {
        let row = try #require(rows([entry("Remind me to book the venue.", .notInserted, reason: "focusChanged")]).first)
        let shown = RowPresentation(row, time: clock)
        #expect(shown.paragraphs == ["Remind me to book the venue."])
        #expect(shown.status == "Didn't go in")
        #expect(shown.actions == [.copy])
        // Its own line offers Copy, so the pointer adds no second one.
        #expect(!shown.copiesOnHover)
        #expect(shown.tooltip == "The text box changed while Intention was typing.")
        // The reason is never on the row itself, only in the tooltip and here.
        #expect(shown.accessibilityLabel
            == "\(time). Remind me to book the venue. Didn't go in. The text box changed while Intention was typing.")
        // An uncertain insertion warns before another paste, with Copy only.
        let uncertain = try #require(rows([entry("Maybe in.", .uncertain)]).first)
        #expect(RowPresentation(uncertain, time: clock).status == "May have gone in. Check before pasting again")
        #expect(RowPresentation(uncertain, time: clock).actions == [.copy])
    }

    @Test func concealedWordsShowAsHiddenAndStillOfferCopy() throws {
        let row = try #require(rows([entry("hunter2 and the rest", .notInserted, reason: "secureField")]).first)
        let shown = RowPresentation(row, time: clock)
        #expect(shown.paragraphs.isEmpty)
        #expect(shown.placeholder == "Hidden text")
        #expect(shown.actions == [.copy])
        #expect(!shown.accessibilityLabel.contains("hunter2"))
        #expect(shown.accessibilityLabel.hasPrefix("\(time). Hidden text. Didn't go in."))
    }

    @Test func heardNothingNamesTheMicrophoneWithRetryAndSwitchMic() throws {
        let kept = entry("", .failed, reason: "noWords", device: "Studio Headset")
        let row = try #require(rows([kept], keepAudioFor: [kept.id]).first)
        let shown = RowPresentation(row, time: clock)
        #expect(shown.paragraphs.isEmpty)
        #expect(shown.placeholder == "Heard nothing from Studio Headset")
        #expect(shown.status == nil)
        #expect(shown.actions == [.retry, .switchMicrophone])
        #expect(shown.actions.map(\.title) == ["Retry", "Switch mic"])
        #expect(!shown.copiesOnHover)
        #expect(shown.accessibilityLabel == "\(time). Heard nothing from Studio Headset.")
        // With the audio gone, as after a relaunch, only Switch mic is left;
        // with no microphone named, the line says so plainly.
        let gone = try #require(rows([entry("", .failed, reason: "noWords")]).first)
        #expect(RowPresentation(gone, time: clock).actions == [.switchMicrophone])
        #expect(RowPresentation(gone, time: clock).placeholder == "Heard nothing")
    }

    @Test(arguments: [
        ("unauthorized", "The dictation server refused this copy of Intention."),
        ("timedOut", "The dictation server did not answer in time."),
        ("unreachable", "Could not reach the dictation server."),
        ("refused.language_unsupported", "The dictation server supports none of your selected languages."),
        ("refused.other", "The dictation server could not finish it.")
    ])
    func emptyServerFailuresShowTheirReasonAndOnlyRetryWhileAudioIsKept(reason: String, sentence: String) throws {
        let failed = entry("", .failed, reason: reason, device: "Studio Headset")
        for kept in [true, false] {
            let row = try #require(rows([failed], keepAudioFor: kept ? [failed.id] : []).first)
            let shown = RowPresentation(row, time: clock)
            #expect(shown.placeholder == sentence)
            #expect(shown.status == nil)
            #expect(shown.actions == (kept ? [.retry] : []))
            #expect(!shown.copiesOnHover)
            #expect(shown.accessibilityLabel == "\(time). \(sentence)")
        }
    }

    @Test func languageWarningIsCarriedIntoTheRowAndVoiceOver() throws {
        let note = "Spanish isn't available on this server; this was heard as English."
        for outcome in [DictationHistory.Entry.Outcome.inserted, .notInserted] {
            var value = entry("Please send the agenda.", outcome, reason: outcome == .inserted ? nil : "focusChanged")
            value.languageNote = note
            let shown = RowPresentation(try #require(rows([value]).first), time: clock)
            #expect(shown.languageNote == note)
            #expect(shown.accessibilityLabel.contains(note))
        }
    }

    @Test func anEmailIntentionWroteHasTheTagAndFoldsOutWhatWasSaid() throws {
        let row = try #require(rows([entry("Hi Jordan,\nThanks for sending the contract over.", spoken: "tell Jordan the contract looks fine")]).first)
        let shown = RowPresentation(row, time: clock)
        #expect(shown.showsEmailTag)
        #expect(shown.paragraphs == ["Hi Jordan,", "Thanks for sending the contract over."])
        #expect(shown.spoken == "tell Jordan the contract looks fine")
        #expect(shown.status == nil)
        #expect(shown.copiesOnHover)
        #expect(shown.accessibilityLabel == "\(time). Email. Hi Jordan, Thanks for sending the contract over.")
        // Nothing said, nothing to fold.
        let silent = try #require(rows([entry("Hi.", spoken: " ")]).first)
        #expect(RowPresentation(silent, time: clock).spoken == nil)
    }

    @Test func anAcceptedProposalHasTheTagAndNothingToFold() throws {
        let row = try #require(rows([entry("Hi Jonah, yes, go ahead.", proposal: .accepted)]).first)
        let shown = RowPresentation(row, time: clock)
        #expect(shown.showsEmailTag)
        #expect(shown.spoken == nil)
        #expect(shown.status == nil)
        #expect(shown.actions.isEmpty)
        #expect(shown.copiesOnHover)
    }

    @Test func noRowNarratesInternalState() throws {
        let all = rows([
            entry("Went in"), entry("Kept", .notInserted, reason: "retried"), entry("Unsure", .uncertain),
            entry("", .failed, reason: "unreachable"), entry("Draft", proposal: .changed),
        ])
        for row in all {
            let shown = RowPresentation(row, time: clock)
            let visible = [shown.status, shown.placeholder].compactMap { $0 } + shown.actions.map(\.title)
            for words in visible {
                #expect(!words.contains("Not inserted"))
                #expect(!words.contains("Recovered"))
                #expect(!words.contains("Draft,"))
            }
        }
    }

    @Test func aRowOffersUnfoldingForSpokenWordsParagraphsOrMeasuredTruncation() throws {
        let plain = RowPresentation(try #require(rows([entry("Went in.")]).first))
        #expect(!HistoryRowView.folds(plain, isCut: false))
        #expect(HistoryRowView.folds(plain, isCut: true))
        let written = RowPresentation(try #require(rows([
            entry("The contract looks fine.", spoken: "tell Jordan the contract looks fine")
        ]).first))
        #expect(HistoryRowView.folds(written, isCut: false))
        let paragraphs = RowPresentation(try #require(rows([entry("Hi Jordan,\nI'll sign it today.")]).first))
        #expect(HistoryRowView.folds(paragraphs, isCut: false))
    }

    @Test func unfoldingShowsSpokenWordsAndEveryParagraphWithoutHoverChangingHeight() throws {
        // One short paragraph isolates the extra height of what was said.
        let email = entry("The contract looks fine.", spoken: "tell Jordan the contract looks fine")
        let paragraphs = entry("Hi Jordan,\nThanks for sending the contract over.\nI'll sign it today.")
        let all = rows([entry("Went in."), entry("Kept.", .notInserted, reason: "focusChanged"), email, paragraphs])
        func height(_ row: HistoryRow, hovered: Bool = false, unfolded: Bool = false) -> CGFloat {
            let view = HistoryRowView(row: row, isHovered: hovered, isUnfolded: unfolded, retryEnabled: true,
                                      act: { _ in }, hover: { _ in }, toggleFold: {})
                .frame(width: HomeStyle.column + HomeStyle.rowInset * 2)
            return NSHostingView(rootView: view).fittingSize.height
        }
        let wentIn = try #require(all.first { $0.text == "Went in." })
        let kept = try #require(all.first { $0.text == "Kept." })
        let written = try #require(all.first { $0.id == email.id })
        let multiple = try #require(all.first { $0.id == paragraphs.id })
        #expect(height(written, unfolded: true) > height(written))
        #expect(height(multiple, unfolded: true) > height(multiple))
        // Copy and the chevron appear over the row without moving its lines.
        for row in [wentIn, kept, written, multiple] {
            for unfolded in [false, true] {
                #expect(height(row, hovered: true, unfolded: unfolded) == height(row, unfolded: unfolded))
            }
        }
    }

    @Test func firstLaunchShowsOnlyUntilTheFirstDictation() {
        let history = DictationHistory(file: nil)
        #expect(MainWindowState.page(historyIsEmpty: history.isEmpty) == .firstLaunch)
        // A proposal nobody used is not a dictation.
        history.add(entry("Unused draft.", .notInserted, proposal: .unused))
        #expect(MainWindowState.page(historyIsEmpty: history.isEmpty) == .firstLaunch)
        history.add(entry("Hello."))
        #expect(MainWindowState.page(historyIsEmpty: history.isEmpty) == .home)
        // A search that matches nothing is still Home, not the welcome.
        #expect(history.sections(matching: "zebra", now: now, calendar: calendar).isEmpty)
        #expect(MainWindowState.page(historyIsEmpty: history.isEmpty) == .home)
        #expect(history.clear())
        #expect(MainWindowState.page(historyIsEmpty: history.isEmpty) == .firstLaunch)
    }

    @Test func homeRedrawsAtEachMidnightAndAtFirstForNow() {
        let schedule = Array(HomeView.schedule(from: now, calendar: calendar).prefix(32))
        #expect(schedule.first == now)
        #expect(schedule.count == 32)
        #expect(schedule.dropFirst().allSatisfy { calendar.startOfDay(for: $0) == $0 && $0 > now })
    }

    @Test func settingsHoldsEveryOneOfTodaysSettingsOnceInTheMockupsSections() {
        #expect(SettingsSection.allCases.map(\.title) == ["General", "Email", "System", "Account", "Data"])
        let placed = SettingsSection.allCases.flatMap(\.items)
        #expect(placed.count == SettingsItem.allCases.count)
        #expect(Set(placed.map { "\($0)" }) == Set(SettingsItem.allCases.map { "\($0)" }))
        // What the old Settings form held, each still somewhere.
        let oldForm: [SettingsItem] = [.dictationKey, .languages, .microphone, .writesEmails, .draftsReplies, .indicator,
                                       .mailboxes, .setup, .opensAtLogin, .version]
        for item in oldForm { #expect(placed.contains(item)) }
        #expect(SettingsSection.general.items == [.dictationKey, .microphone, .languages])
        #expect(SettingsSection.email.cards == [[.mailboxes], [.writesEmails, .draftsReplies, .sentWithIntention]])
        #expect(SettingsSection.system.cards == [[.opensAtLogin, .indicator, .dotPosition, .appearance]])
        #expect(SettingsSection.account.cards == [[.setup, .version, .reportProblem]])
    }

    @Test func clearingHistoryLivesUnderDataAndNowhereElse() {
        #expect(SettingsSection.allCases.filter { $0.items.contains(.clearHistory) } == [.data])
        #expect(SettingsSection.data.items == [.clearHistory])
    }

    @Test func theEmailSwitchesSayWhatTheyDo() {
        #expect(WritingRow.explanation(keyName: "right option").contains("hold right option and say"))
        #expect(WritingRow.sentWithIntentionTitle == "Add \u{2018}Sent with Intention\u{2019} to emails Intention writes")
        for words in [WritingRow.explanation(keyName: "fn"), WritingRow.draftsExplanation, WritingRow.sentWithIntentionTitle] {
            #expect(!words.contains("\u{2014}"))
        }
    }

    @Test func theMicrophoneButtonNamesTheChoiceWithoutTheMenusAdvice() {
        let inputs = AudioInputs(devices: [AudioInput(id: 1, uid: "built-in", name: "MacBook Pro Microphone", isBuiltIn: true),
                                           AudioInput(id: 2, uid: "usb", name: "USB Microphone", isBuiltIn: false)],
                                 systemDefault: 2, lidClosed: false)
        #expect(MicrophoneRow.label(for: .builtIn, in: inputs) == "Built-in microphone")
        #expect(MicrophoneRow.label(for: .systemDefault, in: inputs) == "System default")
        #expect(MicrophoneRow.label(for: .device(uid: "usb", name: "USB Microphone"), in: inputs) == "USB Microphone")
        #expect(MicrophoneRow.label(for: .device(uid: "gone", name: "Desk Mic"), in: inputs) == "Desk Mic (not connected)")
    }
}

@MainActor @Observable private final class WindowPolls {
    var count = 0
    var cancelled = false
}

private struct SettingsTaskFixture: View {
    let state: MainWindowState
    let polls: WindowPolls
    var body: some View {
        if state.settings != nil {
            Text("Synthetic settings")
                .task {
                    defer { polls.cancelled = true }
                    while !Task.isCancelled {
                        polls.count += 1
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                }
        }
    }
}
