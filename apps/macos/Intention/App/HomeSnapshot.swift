#if OFFSCREEN_RENDER
import AppKit
import SwiftUI

/// `--home-snapshot <file.png> [--home-state list|empty|hover|unfolded|search|nomatch|long]
/// [--home-width <points>] [--home-height <points>]` draws the main window's
/// Home off screen, from made-up dictations kept in memory, to a PNG and
/// quits once launching has finished (any earlier, SwiftUI holds back the
/// state a row measures itself into). It reads no history file and, like
/// the Settings render (`SettingsSnapshot.isRequested`), takes no
/// single-instance lock and starts no indicator. Run it with
/// `--onboarding-fixture`, as the Settings render is, so the app model it
/// waits for touches no keychain or network. `-appearance
/// light|dark` chooses the appearance as Settings would, and `--still-state
/// hover|pressed|focused` draws every control in that state. It draws at the
/// window's own size, 1100 by 720, unless another is given, so two
/// revisions compare at one size.
@MainActor
enum HomeSnapshot {
    static func renderIfRequested(arguments: [String]) {
        OffscreenRenderGuard.requireInstalled()
        guard let path = value(after: "--home-snapshot", in: arguments) else { return }
        SetupStyle.registerFonts()
        SetupMotion.isStill = true
        let shown = value(after: "--home-state", in: arguments) ?? "list"
        let width = value(after: "--home-width", in: arguments).flatMap(Double.init) ?? HomeStyle.windowSize.width
        let height = value(after: "--home-height", in: arguments).flatMap(Double.init) ?? HomeStyle.windowSize.height
        let appearance = UserDefaults.standard.string(forKey: "appearance").flatMap(Appearance.init(rawValue:)) ?? .light
        let history = shown == "empty" ? DictationHistory(file: nil) : sample(longNames: shown == "long")
        let state = MainWindowState()
        let rows = history.sections(matching: "", now: .now, calendar: .current).flatMap(\.rows)
        switch shown {
        case "hover": state.hoveredRow = rows.first?.id
        case "unfolded": state.unfolded = Set(rows.filter { if case .email(spoken: .some) = $0.kind { true } else { false } }.map(\.id))
        case "search": state.search = "venue"
        case "nomatch": state.search = "zebra"
        default: break
        }
        // `--home-learning-label <words> [--home-learning-fraction <0...1>]`
        // draws what Intention has read of the person's sent mail, as
        // `LearningProgress` words it; without a fraction, no track.
        let learningLabel = value(after: "--home-learning-label", in: arguments)
        let learningFraction = value(after: "--home-learning-fraction", in: arguments).flatMap(Double.init)
        let view = HomeView(history: history, state: state, keyName: "fn", retryEnabled: true, act: { _, _ in }, openSettings: {},
                            learningLabel: learningLabel, learningFraction: learningFraction, learningDetail: value(after: "--home-learning-detail", in: arguments))
            .appearance(appearance)
            .environment(\.stillControlState, StillControlState.requested)
        let size = CGSize(width: width, height: height)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance.nsAppearance
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Let SwiftUI settle its first layout and the hover tint before drawing.
        RunLoop.current.run(until: .now + 0.6)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        let file = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        exit((try? png.write(to: file)) == nil ? 1 : 0)
    }

    /// A made-up week: dictations, an email written from what was said, a
    /// reply draft, one that heard nothing and one that didn't go in.
    static func sample(longNames: Bool = false) -> DictationHistory {
        let history = DictationHistory(file: nil)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        func at(_ daysAgo: Int, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(byAdding: DateComponents(day: -daysAgo, hour: hour, minute: minute), to: today) ?? today
        }
        typealias Entry = DictationHistory.Entry
        let entries: [Entry] = [
            Entry(id: UUID(), date: at(3, 13, 5), text: "The second draft is closer. The opening still explains too much before it shows anything, so I'd cut the first two paragraphs and start with the kitchen scene. Keep the ending as it is.",
                  outcome: .inserted, speechDuration: 14),
            Entry(id: UUID(), date: at(3, 16, 3), text: "Two adults and one child for the 7:30 showing, if there's still room near the aisle.",
                  outcome: .inserted, speechDuration: 6),
            Entry(id: UUID(), date: at(1, 10, 20), text: "Hi Jonah, yes, go ahead and order the chairs. The grey ones are fine. Thanks for checking first.",
                  outcome: .inserted, proposal: .accepted),
            Entry(id: UUID(), date: at(1, 18, 41), text: "Remind me to book the venue for the offsite and send Priya the headcount by Friday.",
                  outcome: .notInserted, reason: "focusChanged", speechDuration: 7),
            Entry(id: UUID(), date: at(0, 14, 30), text: "", outcome: .failed, reason: "noWords",
                  device: longNames ? "Alex's very long USB podcasting microphone on the studio desk by the window" : "MacBook Pro Microphone",
                  speechDuration: 3),
            Entry(id: UUID(), date: at(0, 15, 48), text: "Hi Jordan,\nThanks for sending the contract over. Section 4 reads fine to me, but I'd like the payment terms at 30 days rather than 15. If that works on your side, I can sign this week.",
                  outcome: .inserted, spoken: "tell jordan section four is fine but I want thirty day payment terms not fifteen and I can sign this week", speechDuration: 9),
            Entry(id: UUID(), date: at(0, 16, 12), text: "Can we move the standup to ten tomorrow? I have the dentist at nine and I don't want to rush it.",
                  outcome: .inserted, speechDuration: 7),
        ]
        for entry in entries { history.add(entry) }
        return history
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
extension StillControlState {
    /// The state a render asks for with `--still-state`, if any.
    static var requested: StillControlState? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--still-state"), arguments.indices.contains(index + 1) else { return nil }
        return switch arguments[index + 1] {
        case "hover": .hover
        case "pressed": .pressed
        case "focused": .focused
        default: nil
        }
    }
}
#endif
