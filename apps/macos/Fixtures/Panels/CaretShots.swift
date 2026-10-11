import AppKit
import SwiftUI

// The entry point of the small bundle scripts/caret-shots.sh builds: every
// surface Intention draws over other apps (the reply card, the popup, the
// notice, the caption beside the dot and the words above the foot dot),
// each by its own view, over made-up hosts: a Gmail reply, a notes field and
// the foot of a desktop. `--caret-snapshots <directory>` saves one PNG per
// state in Light and in Dark, then quits. Built with `-D AFTER` it passes
// the app's Light or Dark to the views; without it, it calls the views as
// they were before they had one, compiled from an earlier checkout's
// sources (scripts/caret-shots.sh --before <revision>), for the before
// pictures. Every name and
// message is invented, nothing is read from any app, and no window takes the
// keyboard or is seen.
@main
struct CaretShots: GuardedRender {
    @MainActor
    static func render() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let arguments = CommandLine.arguments
        SetupStyle.registerFonts()
        guard let index = arguments.firstIndex(of: "--caret-snapshots"), arguments.indices.contains(index + 1) else { exit(2) }
        var failed: Bool?
        Task {
            do {
                try await render(to: URL(fileURLWithPath: arguments[index + 1]))
                failed = false
            } catch {
                FileHandle.standardError.write(Data("caret snapshots failed: \(error)\n".utf8))
                failed = true
            }
        }
        while failed == nil { RunLoop.current.run(mode: .default, before: .now + 0.02) }
        exit(failed == true ? 1 : 0)
    }

    static let draft = """
        Hi Priya,

        Harbor Hall sounds right: a ten-minute walk from the office and room for all 40 of us. Before we hold it, what does it cost for the evening? Friday works for the deposit.

        Thanks,
        Sam
        """
    /// Six lines of draft and more: the long case.
    static let longDraft = """
        Hi Priya,

        Thanks for pulling both of these together so quickly. Harbor Hall sounds right to me: a ten-minute walk from the office, room for all 40 of us, and the terrace if the weather holds.

        Before we hold it, could you ask what the evening costs with the AV package, and whether they need the deposit by Friday or can wait until Monday? I'd also like to know if the kitchen can do a vegetarian menu for about a third of the group.

        If Lakeside comes back with a better price, let's talk on Thursday.

        Thanks,
        Sam
        """
    static let longDictation = "Can you send me the final version of the Q3 deck before the board call tomorrow morning, and also the notes from Tuesday's planning session with the numbers we agreed on for the hiring plan, the marketing budget and the two vendor contracts that still need legal review before we sign anything next week"
    static let longMic = "Sam's AirPods Pro Max (Bluetooth Hands-Free, second pair)"

    enum Look: String, CaseIterable { case light, dark }

    @MainActor
    private static func render(to directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let only = CommandLine.arguments.firstIndex(of: "--only").map { CommandLine.arguments[$0 + 1] }
        for look in Look.allCases {
            for (name, scene) in scenes(look) where only.map({ name.hasPrefix($0) }) ?? true {
                let size = NSHostingView(rootView: scene).fittingSize
                try await save(scene, size: CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up)),
                               to: directory.appendingPathComponent("\(name)-\(look.rawValue).png"))
            }
        }
    }

    // MARK: - The surfaces, as each build has them

    /// The dictation key as the card names it: "fn" since the caret
    /// surfaces print it as setup does; a checkout from before printed "Fn".
    #if AFTER
    static let cardKey = "fn"
    #else
    static let cardKey = "Fn"
    #endif

    @MainActor static func card(_ text: String, key: String = cardKey, width: CGFloat, confirming: Bool = false, words: Bool = false,
                                look: Look) -> AnyView {
        let paragraphs = ProposalCard.paragraphs(of: text)
        #if AFTER
        return AnyView(ProposalCardView(paragraphs: paragraphs, keyName: key, textWidth: width, fades: false,
                                        confirmingReplacement: confirming, withWords: words,
                                        appearance: look == .dark ? .dark : .light))
        #else
        return AnyView(ProposalCardView(paragraphs: paragraphs, keyName: key, textWidth: width, fades: false,
                                        confirmingReplacement: confirming))
        #endif
    }

    @MainActor static func popup(_ content: PopupView.Content, opens: UnitPoint, copied: Bool? = nil, look: Look) -> AnyView {
        #if AFTER
        return AnyView(PopupView(content: content, opensFrom: opens, reduceMotion: true, close: {},
                                 appearance: look == .dark ? .dark : .light, copiedAtStart: copied))
        #else
        // The popup before Light and Dark could not be drawn already
        // copied; its "Copied" state shows only after a click.
        return AnyView(PopupView(content: content, opensFrom: opens, reduceMotion: true, close: {}))
        #endif
    }

    @MainActor static func notice(_ words: String, atFoot: Bool = false, look: Look) -> AnyView {
        #if AFTER
        return AnyView(NoticeCapsule(words: words, appearance: look == .dark ? .dark : .light).padding(NoticeCapsule.shadowRoom))
        #else
        return AnyView(NoticeCapsule(words: words).padding(NoticeCapsule.shadowRoom))
        #endif
    }

    @MainActor static func caption(_ text: String, look: Look) -> AnyView {
        #if AFTER
        return AnyView(DotCaptionView(text: text, appearance: look == .dark ? .dark : .light))
        #else
        return AnyView(DotCaptionView(text: text))
        #endif
    }

    static var room: (card: CGFloat, popup: CGFloat, notice: CGFloat, caption: CGFloat) {
        (ProposalCard.shadowRoom, PopupView.shadowRoom, NoticeCapsule.shadowRoom, DotCaption.shadowRoom)
    }

    // MARK: - The states

    @MainActor
    static func scenes(_ look: Look) -> [(String, AnyView)] {
        let reasonWords = InsertionPopup.words(for: .noTextField)
        let draftWhy = InsertionPopup.draftWords(for: .focusChanged)
        let cutLong = PopupView.cuts(longDictation, lines: InsertionPopup.dictationLines)
        let cutDraft = PopupView.cuts(longDraft, lines: InsertionPopup.draftLines)
        var scenes: [(String, AnyView)] = []
        func gmail(_ name: String, compose: Bool = false, bodyWidth: CGFloat = 836, caretX: CGFloat? = nil, dot: DotInk = .resting, coveringCard: ((GmailHost.Geometry) -> CGRect)? = nil,
                   _ surface: @escaping (GmailHost.Geometry) -> AnyView) {
            scenes.append((name, AnyView(GmailHost(compose: compose, bodyWidth: bodyWidth, caretX: caretX, dot: dot, coveringCard: coveringCard, surface: surface))))
        }
        func notes(_ name: String, dark: Bool = false, _ surface: @escaping (NotesHost.Geometry) -> AnyView) {
            scenes.append((name, AnyView(NotesHost(dark: dark, surface: surface))))
        }

        // Measure the sheet once and use the production overlap rule for
        // its caret dot, including a confirmation that leaves the caret clear.
        func replyCard(_ name: String, text: String = draft, width: CGFloat = 450, bodyWidth: CGFloat = 836,
                       caretX: CGFloat? = nil, key: String = cardKey, words: Bool = false, confirming: Bool = false) {
            let view = card(text, key: key, width: width, confirming: confirming, words: words, look: look)
            let measured = NSHostingView(rootView: view).fittingSize
            let sheetSize = CGSize(width: measured.width - 2 * room.card, height: measured.height - 2 * room.card)
            let sheet: (GmailHost.Geometry) -> CGRect = { g in
                CGRect(x: min(g.caret.x - 14, g.size.width - sheetSize.width).rounded(),
                       y: (g.caret.y + (confirming ? 60 : -9)).rounded(), width: sheetSize.width, height: sheetSize.height)
            }
            gmail(name, bodyWidth: bodyWidth, caretX: caretX, dot: .full, coveringCard: sheet) { g in
                place(view, room: room.card, left: sheet(g).minX, top: sheet(g).minY)
            }
        }
        replyCard("card")
        replyCard("card-long-draft", text: longDraft)
        replyCard("card-words", words: true)
        replyCard("card-confirm", confirming: true)
        replyCard("card-narrow-long-key", width: 212, bodyWidth: 240, key: "Control + Option + Command")
        replyCard("card-narrow-long-key-words", width: 212, bodyWidth: 240, key: "Control + Option + Command", words: true)
        replyCard("card-near-edge", caretX: 760)

        // The popup.
        notes("popup-refused") { g in
            place(popup(.words(why: reasonWords, text: "Running ten minutes late, save me a seat by the window.", cut: false, copy: { true }),
                        opens: .leading, look: look), room: room.popup, left: g.mark.maxX + InsertionPopup.gap, centreY: g.mark.midY)
        }
        notes("popup-refused-long") { g in
            place(popup(.words(why: InsertionPopup.words(for: .earlierUnsettled), text: longDictation, cut: cutLong, copy: { true }),
                        opens: .leading, look: look), room: room.popup, left: g.mark.maxX + InsertionPopup.gap, centreY: g.mark.midY)
        }
        notes("popup-copied") { g in
            place(popup(.words(why: InsertionPopup.words(for: .targetUnresponsive), text: "Running ten minutes late, save me a seat by the window.", cut: false, copy: { true }),
                        opens: .leading, copied: true, look: look), room: room.popup, left: g.mark.maxX + InsertionPopup.gap, centreY: g.mark.midY)
        }
        notes("popup-copy-failed") { g in
            place(popup(.words(why: InsertionPopup.words(for: .clipboardBusy), text: "Running ten minutes late, save me a seat by the window.", cut: false, copy: { false }),
                        opens: .leading, copied: false, look: look), room: room.popup, left: g.mark.maxX + InsertionPopup.gap, centreY: g.mark.midY)
        }
        notes("popup-password") { g in
            place(popup(.words(why: InsertionPopup.words(for: .secureField), text: InsertionPopup.hidden, cut: false, copy: { true }),
                        opens: .leading, look: look), room: room.popup, left: g.mark.maxX + InsertionPopup.gap, centreY: g.mark.midY)
        }
        // Beside a dot near the screen's right edge, it opens to the dot's left.
        notes("popup-near-edge") { g in
            let mark = g.mark.offsetBy(dx: g.size.width - 60 - g.mark.maxX, dy: 0)
            return AnyView(ZStack(alignment: .topLeading) {
                DotMark(ink: .resting, host: .black).offset(x: mark.midX - 6, y: mark.midY - 6)
                place(popup(.words(why: reasonWords, text: "Running ten minutes late, save me a seat by the window.", cut: false, copy: { true }),
                            opens: .trailing, look: look), room: room.popup, right: mark.minX - InsertionPopup.gap, centreY: mark.midY)
            })
        }
        gmail("popup-draft", dot: .full) { g in
            place(popup(.draft(title: InsertionPopup.draftTitle, why: draftWhy, text: longDraft, cut: cutDraft, copy: { true }),
                        opens: .bottomLeading, look: look), room: room.popup, left: g.caret.x - 6, bottom: g.caret.y - 6 - InsertionPopup.gap)
        }
        notes("popup-no-words-retry") { g in
            place(popup(.nothing(line: "Heard no words from \(longMic)", retry: {}, switchMicrophone: {}),
                        opens: .leading, look: look), room: room.popup, left: g.mark.maxX + InsertionPopup.gap, centreY: g.mark.midY)
        }
        notes("popup-no-words") { g in
            place(popup(.nothing(line: "No sound from MacBook Pro Microphone", retry: nil, switchMicrophone: {}),
                        opens: .leading, look: look), room: room.popup, left: g.mark.maxX + InsertionPopup.gap, centreY: g.mark.midY)
        }
        notes("popup-dark-host", dark: true) { g in
            place(popup(.words(why: reasonWords, text: "Running ten minutes late, save me a seat by the window.", cut: false, copy: { true }),
                        opens: .leading, look: look), room: room.popup, left: g.mark.maxX + InsertionPopup.gap, centreY: g.mark.midY)
        }

        // The notice beside the dot, and above the foot.
        gmail("notice-nothing-to-reply") { g in
            place(notice("Nothing to reply to", look: look), room: room.notice, left: g.mark.maxX + DotNotice.gap, centreY: g.mark.midY)
        }
        scenes.append(("notice-at-foot", AnyView(FootHost(dark: false) { g in
            place(notice("Intention heard nothing from your microphone", atFoot: true, look: look), room: room.notice, centreX: g.dot.x, bottom: g.dot.y - FootMark.wordsGap)
        })))

        scenes.append(("notice-at-foot-dark-desk", AnyView(FootHost(dark: true) { g in
            place(notice("Intention heard nothing from your microphone", atFoot: true, look: look), room: room.notice, centreX: g.dot.x, bottom: g.dot.y - FootMark.wordsGap)
        })))

        // The caption beside the dot.
        for (name, words) in [("caption-writing", "Writing your email\u{2026}"), ("caption-hint", EmailHint.words(key: "fn")),
                              ("caption-typed", "Couldn't write it, so I typed what you said"),
                              ("caption-written", "Written from what you said. \u{2318}Z takes it back"),
                              ("caption-pasted", "Pasted it, which replaced what you'd copied")] {
            gmail(name, compose: true, dot: name == "caption-writing" ? .full : .resting) { g in
                place(caption(words, look: look), room: room.caption, left: g.dotCentre.x + 6 + DotCaption.gap, centreY: g.dotCentre.y)
            }
        }
        notes("caption-written-dark-host", dark: true) { g in
            place(caption("Written from what you said. \u{2318}Z takes it back", look: look), room: room.caption,
                  left: g.mark.midX + 6 + DotCaption.gap, centreY: g.mark.midY)
        }

        // Where the caret dot rests. Since caret-dot-email-only (built with
        // -D EMAIL_ONLY), only in an email Intention can write; elsewhere the
        // foot dot alone, with words still at the insertion point.
        #if EMAIL_ONLY
        let otherField: DotInk? = nil
        #else
        let otherField: DotInk? = .resting
        #endif
        scenes.append(("dot-rule-notes-resting", AnyView(NotesHost(dot: otherField) { _ in AnyView(EmptyView()) })))
        scenes.append(("dot-rule-notes-dark-app", AnyView(NotesHost(dark: true, dot: otherField) { _ in AnyView(EmptyView()) })))
        gmail("dot-rule-gmail-resting") { _ in AnyView(EmptyView()) }
        // A notice outside an email. On this branch it goes to the foot's
        // slip (drawn by foot-placement-shots); this is the fallback for
        // when the slip cannot open, as when the field reaches the foot:
        // the words stand where the dot would, their foot on its foot.
        scenes.append(("dot-rule-notes-notice", AnyView(NotesHost(dot: otherField) { g in
            #if EMAIL_ONLY
            place(caption("Pasted it, which replaced what you'd copied", look: look), room: room.caption,
                  left: g.mark.midX - 6, bottom: g.mark.midY + 6)
            #else
            place(caption("Pasted it, which replaced what you'd copied", look: look), room: room.caption,
                  left: g.mark.midX + 6 + DotCaption.gap, centreY: g.mark.midY)
            #endif
        })))
        #if EMAIL_ONLY
        let recording: DotInk? = nil
        #else
        let recording: DotInk? = .full
        #endif
        scenes.append(("dot-rule-notes-recording", AnyView(NotesHost(dot: recording) { _ in AnyView(EmptyView()) })))
        return scenes
    }

    /// Puts a surface whose view carries `room` of transparent space on
    /// every side so that its visible box has the given edges or centre.
    @MainActor
    static func place(_ view: AnyView, room: CGFloat, left: CGFloat? = nil, right: CGFloat? = nil, centreX: CGFloat? = nil,
                      top: CGFloat? = nil, bottom: CGFloat? = nil, centreY: CGFloat? = nil) -> AnyView {
        let size = NSHostingView(rootView: view).fittingSize
        let box = CGSize(width: size.width - 2 * room, height: size.height - 2 * room)
        let x = left ?? right.map { $0 - box.width } ?? centreX.map { $0 - box.width / 2 } ?? 0
        let y = top ?? bottom.map { $0 - box.height } ?? centreY.map { $0 - box.height / 2 } ?? 0
        return AnyView(view.fixedSize().offset(x: (x - room).rounded(), y: (y - room).rounded()))
    }

    /// Draws the scene off screen with SwiftUI's ImageRenderer at twice
    /// its size: no window is made or ordered front, and the process never
    /// activates, so nothing can appear on the person's screen.
    @MainActor
    private static func save(_ scene: some View, size: CGSize, to file: URL) async throws {
        let renderer = ImageRenderer(content: scene.frame(width: size.width, height: size.height).environment(\.colorScheme, .light))
        renderer.scale = 2
        renderer.isOpaque = true
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: file)
    }
}

// MARK: - The made-up hosts

/// How the caret dot is drawn over a host: at rest in the host's ink at 60
/// percent, or at full ink while a proposal shows or Intention works.
enum DotInk { case resting, full }

struct DotMark: View {
    let ink: DotInk
    let host: Color

    var body: some View {
        Path(OwnHandMark.dot(diameter: 12).path)
            .fill(host.opacity(ink == .full ? 1 : 0.6))
            .frame(width: 12, height: 12)
    }
}

/// A Gmail thread with an inline reply open: a message from Priya, the
/// reply box with its recipient line, the caret at the body's start with
/// the dot above it, and Send under the body. `compose` puts a few typed
/// words before the caret, as while an email is written.
struct GmailHost: View {
    struct Geometry {
        var size: CGSize
        /// The caret's left edge and top.
        var caret: CGPoint
        var dotCentre: CGPoint
        /// The dot's click target.
        var mark: CGRect
    }

    var compose = false
    var bodyWidth: CGFloat = 836
    var caretX: CGFloat?
    var dot: DotInk = .resting
    var coveringCard: ((Geometry) -> CGRect)?
    let surface: (Geometry) -> AnyView

    static let size = CGSize(width: 980, height: 660)
    static let ink = Color(red: 0.12, green: 0.12, blue: 0.13)
    static let grey = Color(red: 0.37, green: 0.39, blue: 0.41)

    var body: some View {
        let replyX: CGFloat = 72, replyY: CGFloat = 270
        let x = caretX ?? (replyX + 28 + (compose ? 63 : 0))
        let caret = CGPoint(x: x, y: replyY + 66)
        let dotCentre = CGPoint(x: caret.x + 0.75, y: caret.y - 3.4 - 6)
        let geometry = Geometry(size: Self.size, caret: caret, dotCentre: dotCentre,
                                mark: CGRect(x: dotCentre.x - 12, y: dotCentre.y - 12, width: 24, height: 24))
        ZStack(alignment: .topLeading) {
            Color(red: 0.97, green: 0.98, blue: 0.99)
            RoundedRectangle(cornerRadius: 16).fill(.white).frame(width: Self.size.width - 32, height: Self.size.height - 16).offset(x: 16, y: 16)
            Text("Friday venue").font(.custom("Helvetica Neue", size: 22)).foregroundStyle(Self.ink).offset(x: 72, y: 40)
            Circle().fill(Color(red: 0.2, green: 0.55, blue: 0.35)).frame(width: 40, height: 40)
                .overlay(Text("P").font(.system(size: 18, weight: .medium)).foregroundStyle(.white)).offset(x: 20, y: 92)
            HStack(spacing: 6) {
                Text("Priya Raman").font(.custom("Helvetica Neue", size: 14).weight(.bold)).foregroundStyle(Self.ink)
                Text("<priya@northwind.example>").font(.custom("Helvetica Neue", size: 12)).foregroundStyle(Self.grey)
            }.offset(x: 72, y: 96)
            Text("9:14 AM (2 hours ago)").font(.custom("Helvetica Neue", size: 12)).foregroundStyle(Self.grey).offset(x: 800, y: 98)
            Text("Hi Sam,\nI found two venues: Harbor Hall and the Lakeside Lodge. Harbor Hall is a ten-minute walk from the office and seats\n60. Lakeside is quieter but a 45-minute drive each way. Which one do you prefer? I can hold either until Friday.\nPriya")
                .font(.custom("Helvetica Neue", size: 14)).lineSpacing(4).foregroundStyle(Self.ink).offset(x: 72, y: 130)
            RoundedRectangle(cornerRadius: 12).fill(.white)
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                .frame(width: bodyWidth + 56, height: 330).offset(x: replyX, y: replyY)
            HStack(spacing: 8) {
                Image(systemName: "arrowshape.turn.up.left").font(.system(size: 13)).foregroundStyle(Self.grey)
                Text("Priya Raman").font(.custom("Helvetica Neue", size: 14)).foregroundStyle(Self.ink)
            }.offset(x: replyX + 28, y: replyY + 20)
            if compose {
                Text("Hi Priya,").font(.custom("Helvetica Neue", size: 14)).foregroundStyle(Self.ink).offset(x: replyX + 28, y: caret.y)
            }
            Rectangle().fill(Self.ink).frame(width: 1.5, height: 17).offset(x: caret.x, y: caret.y)
            Capsule().fill(Color(red: 0.04, green: 0.34, blue: 0.82)).frame(width: 94, height: 40)
                .overlay(Text("Send").font(.system(size: 14, weight: .medium)).foregroundStyle(.white)).offset(x: replyX + 24, y: replyY + 270)
            HStack(spacing: 22) {
                ForEach(["textformat", "paperclip", "link", "face.smiling", "photo", "lock", "pencil"], id: \.self) {
                    Image(systemName: $0).font(.system(size: 15)).foregroundStyle(Self.grey)
                }
            }.offset(x: replyX + 140, y: replyY + 281)
            #if AFTER
            if !DotPlacement.caretCovered(CGRect(x: caret.x, y: caret.y, width: 1.5, height: 17), by: coveringCard?(geometry)) {
                DotMark(ink: dot, host: Self.ink).offset(x: dotCentre.x - 6, y: dotCentre.y - 6)
            }
            #else
            // Before captures compile against the old placement API and
            // preserve the dot that was drawn through the sheet.
            DotMark(ink: dot, host: Self.ink).offset(x: dotCentre.x - 6, y: dotCentre.y - 6)
            #endif
            surface(geometry)
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .clipped()
    }
}

/// A notes window with one line typed and the caret at its end, the dot
/// above it, light or dark.
struct NotesHost: View {
    struct Geometry {
        var size: CGSize
        var caret: CGPoint
        var mark: CGRect
    }

    var dark = false
    /// The caret dot over the line, or nil where none is drawn.
    var dot: DotInk? = .resting
    let surface: (Geometry) -> AnyView
    static let size = CGSize(width: 900, height: 360)

    var body: some View {
        let ink = dark ? Color(white: 0.9) : Color(red: 0.11, green: 0.11, blue: 0.12)
        let line = "Running ten minutes late, save me a seat by the window."
        let width = (line as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 15)]).width
        let caret = CGPoint(x: 70 + width + 1, y: 112)
        let dotCentre = CGPoint(x: caret.x + 0.75, y: caret.y - 9.4)
        let geometry = Geometry(size: Self.size, caret: caret, mark: CGRect(x: dotCentre.x - 12, y: dotCentre.y - 12, width: 24, height: 24))
        ZStack(alignment: .topLeading) {
            (dark ? Color(red: 0.16, green: 0.17, blue: 0.2) : Color(red: 0.86, green: 0.87, blue: 0.89))
            RoundedRectangle(cornerRadius: 12).fill(dark ? Color(white: 0.12) : .white)
                .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
                .frame(width: Self.size.width - 80, height: Self.size.height - 60).offset(x: 40, y: 30)
            Rectangle().fill(dark ? Color(white: 0.17) : Color(white: 0.94)).frame(width: Self.size.width - 80, height: 34).offset(x: 40, y: 30)
            HStack(spacing: 8) {
                Circle().fill(Color(red: 1, green: 0.37, blue: 0.34))
                Circle().fill(Color(red: 1, green: 0.74, blue: 0.18))
                Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25))
            }.frame(width: 52, height: 12).offset(x: 54, y: 41)
            Text("Notes").font(.system(size: 13, weight: .semibold)).foregroundStyle(ink.opacity(0.85)).offset(x: Self.size.width / 2 - 20, y: 39)
            Text(line).font(.system(size: 15)).foregroundStyle(ink).offset(x: 70, y: 111)
            Rectangle().fill(ink).frame(width: 1.5, height: 18).offset(x: caret.x, y: caret.y)
            if let dot { DotMark(ink: dot, host: ink).offset(x: dotCentre.x - 6, y: dotCentre.y - 6) }
            surface(geometry)
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .clipped()
    }
}

/// The foot of a desktop: a window's lower edge, the Dock and the resting
/// dot above it, on a light or a dark desktop.
struct FootHost: View {
    struct Geometry {
        var size: CGSize
        var dot: CGPoint
    }

    var dark = false
    let surface: (Geometry) -> AnyView
    static let size = CGSize(width: 720, height: 220)

    var body: some View {
        let dockTop = Self.size.height - 66
        let dot = CGPoint(x: Self.size.width / 2, y: dockTop - FootMark.aboveDock)
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: dark ? [Color(red: 0.09, green: 0.14, blue: 0.28), Color(red: 0.07, green: 0.1, blue: 0.22)]
                                        : [Color(red: 0.95, green: 0.93, blue: 0.89), Color(red: 0.9, green: 0.89, blue: 0.84)],
                           startPoint: .top, endPoint: .bottom)
            RoundedRectangle(cornerRadius: 12).fill(dark ? Color(white: 0.12) : .white)
                .frame(width: 560, height: 120).offset(x: 80, y: -40)
            RoundedRectangle(cornerRadius: 18).fill(dark ? Color.white.opacity(0.1) : Color.white.opacity(0.55))
                .frame(width: 460, height: 58).offset(x: 130, y: dockTop + 4)
            Path(OwnHandMark.dot(diameter: 11).path).fill(dark ? Color(white: 0.85).opacity(0.7) : Color(red: 0.125, green: 0.165, blue: 0.18).opacity(0.6))
                .frame(width: 11, height: 11).offset(x: dot.x - 5.5, y: dot.y - 5.5)
            surface(Geometry(size: Self.size, dot: dot))
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .clipped()
    }
}
