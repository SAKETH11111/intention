import AppKit
import SwiftUI

// The entry point of the small bundle scripts/dot-shots.sh builds: the dot
// and the caption beside it, in each state a dictation into an email passes
// through, drawn over a line of synthetic text to PNGs off screen, and the
// Settings row that turns email writing off. With `--dot-demo <seconds>` the
// states play through once in a window behind the desktop, for
// scripts/dot-video.sh to record. Nothing is read from any app and no
// window takes the keyboard. `--without-caption` draws the dot alone, as it
// was before the caption existed, for a before picture from an older
// revision's sources.
@main
struct DotShots: GuardedRender {
    @MainActor
    static func render() {
        let app = NSApplication.shared
        let arguments = CommandLine.arguments
        let withCaption = !arguments.contains("--without-caption")
        if let index = arguments.firstIndex(of: "--dot-snapshots"), arguments.indices.contains(index + 1) {
            let directory = URL(fileURLWithPath: arguments[index + 1])
            var failed: Bool?
            Task {
                do {
                    try await DotScene.render(to: directory, withCaption: withCaption)
                    failed = false
                } catch {
                    FileHandle.standardError.write(Data("dot snapshots failed: \(error)\n".utf8))
                    failed = true
                }
            }
            while failed == nil { RunLoop.current.run(mode: .default, before: .now + 0.02) }
            exit(failed == true ? 1 : 0)
        }
        guard let index = arguments.firstIndex(of: "--dot-demo"), arguments.indices.contains(index + 1),
              let seconds = Double(arguments[index + 1]) else { exit(2) }
        app.setActivationPolicy(.prohibited)
        SetupStyle.registerFonts()
        let window = DotScene.stage(withCaption: withCaption)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
        withExtendedLifetime(window) { app.run() }
    }
}

/// A dictation into an email, as the dot shows it: the dot's fill and pulse
/// follow `CaretMarkView`'s rules, and the caption `DotCaption`'s place.
enum DotState: String, CaseIterable {
    case idle = "1-idle"
    case listening = "2-listening"
    case finishing = "3-finishing"
    case writingEmail = "4-writing-your-email"
    case typedTranscript = "5-typed-what-you-said"

    /// What the caption says, as `DictationController` names it.
    var caption: String? {
        switch self {
        case .writingEmail: "Writing your email…"
        case .typedTranscript: "Couldn't write it, so I typed what you said"
        default: nil
        }
    }

    var isWorking: Bool { self == .finishing || self == .writingEmail }
}

/// A line of text with the caret at its end, the dot above the caret and
/// the caption beside the dot, on paper, at the size the pictures are
/// compared at. Once the words have been typed in place of an email, the
/// line holds them too and the caret has moved on past them.
struct DotScene: View {
    static let size = CGSize(width: 680, height: 110)
    static let text = "Thanks for the update, I"
    /// What the person said, as it goes in word for word when the email
    /// could not be written.
    static let typedWords = " can make Thursday at 10"
    static let textOrigin = CGPoint(x: 28, y: 58)
    static let lineHeight: CGFloat = 17
    static let font = NSFont.systemFont(ofSize: 14)
    /// Text ink of a typical field, which the dot takes its colour from.
    static let ink = Color(red: 0.13, green: 0.13, blue: 0.13)

    let state: DotState
    let withCaption: Bool
    /// The words have been typed into the line.
    var typed = false
    /// The pulse's opacity, 1 when still.
    var pulse: Double = 1

    var line: String { typed ? Self.text + Self.typedWords : Self.text }

    private var lineWidth: CGFloat { (line as NSString).size(withAttributes: [.font: Self.font]).width }

    /// The caret's rectangle in the scene, measured from the text.
    var caret: CGRect {
        CGRect(x: Self.textOrigin.x + lineWidth.rounded() + 1, y: Self.textOrigin.y, width: 1, height: Self.lineHeight)
    }

    /// The dot over the caret, by the dot's own placement rules, in the
    /// scene's coordinates (y down).
    var dot: DotPlacement.Dot {
        let line = caret
        // Placement works in AppKit coordinates (y up); flip the line and
        // the answer.
        let flipped = CGRect(x: line.minX, y: Self.size.height - line.maxY, width: line.width, height: line.height)
        let placed = DotPlacement.dot(aboveCaret: flipped)
        return DotPlacement.Dot(center: CGPoint(x: placed.center.x, y: Self.size.height - placed.center.y), diameter: placed.diameter)
    }

    var body: some View {
        let caret = caret
        let dot = dot
        let shape = OwnHandMark.dot(diameter: dot.diameter)
        ZStack(alignment: .topLeading) {
            SetupStyle.paper
            Text(line)
                .font(.system(size: 14))
                .foregroundStyle(Self.ink)
                .position(x: Self.textOrigin.x + lineWidth / 2, y: caret.midY)
            Rectangle()
                .fill(Self.ink)
                .frame(width: caret.width, height: caret.height)
                .position(x: caret.midX, y: caret.midY)
            Path(shape.path)
                .fill(state == .listening ? Color(nsColor: .systemRed) : Self.ink.opacity(0.6))
                .frame(width: shape.size.width, height: shape.size.height)
                .opacity(pulse)
                .position(x: dot.center.x, y: dot.center.y)
            if withCaption, let caption = state.caption {
                // The caption's capsule starts `DotCaption.gap` right of the
                // dot and is centred on it, as `DotCaption.show` places it;
                // the view carries `shadowRoom` around the capsule.
                DotCaptionView(text: caption)
                    .fixedSize()
                    .offset(x: dot.center.x + dot.diameter / 2 + DotCaption.gap - DotCaption.shadowRoom,
                            y: dot.center.y - DotCaptionView.height / 2 - DotCaption.shadowRoom)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    // MARK: - Pictures

    @MainActor
    static func render(to directory: URL, withCaption: Bool) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        SetupStyle.registerFonts()
        for state in DotState.allCases {
            // A pulsing dot is drawn at the pulse's middle; the notice shows
            // with the words already in the line.
            let scene = DotScene(state: state, withCaption: withCaption, typed: state == .typedTranscript, pulse: state.isWorking ? 0.62 : 1)
            try await save(scene, size: size, as: state.rawValue, in: directory)
        }
        guard withCaption else { return }
        let rows: [(String, EmailWriter.Problem?, Bool, Bool)] = [
            ("6-settings-write-emails", nil, true, false),
            ("7-settings-writing-off-on-server", .unavailable(.disabled), true, false),
            ("8-settings-drafts-need-email-writing", nil, false, false),
            ("9-settings-drafts-need-the-dot", nil, true, true),
        ]
        for (name, availability, writesEmails, usesPill) in rows {
            let row = SettingsRowScene(availability: availability, writesEmails: writesEmails, usesPill: usesPill)
            let host = NSHostingView(rootView: row)
            let height = host.fittingSize.height.rounded(.up)
            try await save(row, size: CGSize(width: SettingsRowScene.width, height: height), as: name, in: directory)
        }
    }

    @MainActor
    private static func save(_ view: some View, size: CGSize, as name: String, in directory: URL) async throws {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Let SwiftUI settle its first layout before drawing.
        try await Task.sleep(for: .milliseconds(300))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }

    // MARK: - The demo

    /// A window behind the desktop picture playing the states through once:
    /// listening, finishing, writing the email, then the notice. Drawn like
    /// any window and recordable by its number, never seen, never key. It
    /// has no title bar and square corners, so the recording holds the
    /// scene alone; the title is still set, which is how the recorder finds
    /// the window.
    @MainActor
    static func stage(withCaption: Bool) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.title = "Intention dot"
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.ignoresMouseEvents = true
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: DotDemo(withCaption: withCaption))
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        return window
    }
}

/// The states in turn, on a clock from when the demo started, with the
/// dot's own pulse while it works: full to a quarter and back over 0.9
/// seconds, as `CaretMarkView` animates it. The words go into the line
/// the moment the notice appears, and stay.
struct DotDemo: View {
    let withCaption: Bool
    private let started = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { time in
            let elapsed = time.date.timeIntervalSince(started)
            let state: DotState = elapsed < 1.5 ? .idle : elapsed < 5 ? .listening : elapsed < 6 ? .finishing : elapsed < 11 ? .writingEmail
                : elapsed < 15 ? .typedTranscript : .idle
            let turn = elapsed.truncatingRemainder(dividingBy: 0.9) / 0.9
            let pulse = state.isWorking ? 0.625 + 0.375 * cos(turn * 2 * .pi) : 1
            DotScene(state: state, withCaption: withCaption, typed: elapsed >= 11, pulse: pulse)
        }
    }
}

/// The Settings sheet's card that turns email writing and reply drafts
/// off, at the sheet's pane width, with the lines as they read when writing
/// can happen, when the server has said it cannot, and with drafts greyed
/// while email writing is off or the pill is chosen. The switches are the
/// sheet's own ink ones, which draw the same whether the window is in front
/// or not.
struct SettingsRowScene: View {
    static let width: CGFloat = 540
    let availability: EmailWriter.Problem?
    @State private var isOn: Bool
    @State private var draftsReplies = true
    @State private var addsSentWithIntention = true
    let usesPill: Bool

    init(availability: EmailWriter.Problem?, writesEmails: Bool = true, usesPill: Bool = false) {
        self.availability = availability
        _isOn = State(initialValue: writesEmails)
        self.usesPill = usesPill
    }

    var body: some View {
        SettingsCard {
            WritingRow(isOn: $isOn, availability: availability, draftsReplies: $draftsReplies, usesPill: usesPill,
                       addsSentWithIntention: $addsSentWithIntention)
        }
        .padding(16)
        .frame(width: Self.width)
        .background(SetupStyle.paper)
        .fixedSize(horizontal: false, vertical: true)
    }
}
