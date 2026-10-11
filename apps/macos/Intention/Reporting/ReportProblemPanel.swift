import AppKit
import SwiftUI

/// The small window "Report a problem…" opens from the menu bar item: one
/// optional note and Send, approved as the one exception to "no other UI".
/// The report is made when the window opens, before Intention comes forward,
/// so it names the app the person was using; picking the menu item again
/// while the window is open brings it back with its note. A sent report's
/// window is replaced by a fresh one. What goes in the report and how it
/// is sent are `ProblemReportSubmission`'s.
@MainActor
final class ReportProblemPanel {
    /// The window's name to AppKit, by which the Dock's window count and
    /// the note's focus know it.
    static let identifier = NSUserInterfaceItemIdentifier("intention.report-problem")
    private(set) var window: NSWindow?
    private(set) var prompt: ReportProblemPrompt?
    private var closeObserver: NSObjectProtocol?
    var didClose: (@MainActor () -> Void)?
    private var pendingSends = 0
    var blocksUpdates: Bool { window != nil || pendingSends > 0 }
    /// Shows the window. Tests pass one that shows nothing.
    private let present: @MainActor (NSWindow) -> Void
    /// Light or Dark, as Settings has it. The window follows a change
    /// while it is open (`intentionAppearanceChanged`).
    private let appearance: @MainActor () -> Appearance

    init(present: @escaping @MainActor (NSWindow) -> Void = ReportProblemPanel.bringForward,
         appearance: @escaping @MainActor () -> Appearance = { Appearance.current }) {
        self.present = present
        self.appearance = appearance
    }

    func open(_ makeReport: () -> ProblemReportSubmission) {
        if let window, let prompt, prompt.phase != .sent {
            present(window)
            return
        }
        let submission = makeReport()
        let prompt = ReportProblemPrompt(send: { [weak self] text in
            self?.pendingSends += 1
            defer { self?.sendFinished() }
            try await submission.send(text: text)
        })
        present(prepare(prompt))
    }

    /// The window for `prompt`, built and not shown, in place of any window
    /// open before. A fixture takes it from here to draw it where no one
    /// sees it.
    func prepare(_ prompt: ReportProblemPrompt) -> NSWindow {
        dismiss(notify: false)
        SetupStyle.registerFonts()
        let window = KeyWindow(contentRect: CGRect(origin: .zero, size: CGSize(width: ReportProblemView.width, height: 200)),
                               styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.identifier = Self.identifier
        // The title stays for the Window menu and VoiceOver; the page's own
        // heading says it.
        window.title = "Report a problem"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let appearance = self.appearance
        let root = ReportProblemView(prompt: prompt, close: { [weak window] in window?.performClose(nil) })
            .modifier(WindowLook(appearance: appearance, window: window))
        FittedWindow.install(root, in: window, width: ReportProblemView.width)
        window.center()
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main,
                                                               using: Self.closed(self, window: ObjectIdentifier(window)))
        self.window = window
        self.prompt = prompt
        return window
    }

    /// Closes the window and forgets its report. A send still on its way
    /// finishes, and its result is not shown.
    func close() { dismiss(notify: true) }

    private func dismiss(notify: Bool) {
        let window = self.window
        forget()
        window?.close()
        if window != nil, notify { didClose?() }
    }

    /// The person closed `closed`; a notice from a window already replaced
    /// changes nothing.
    func windowClosed(_ closed: ObjectIdentifier) {
        guard let window, ObjectIdentifier(window) == closed else { return }
        forget()
        didClose?()
    }

    private func sendFinished() {
        pendingSends -= 1
        if window == nil { didClose?() }
    }

    private func forget() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        window = nil
        prompt = nil
    }

    /// The window's close notice, which AppKit may post from any thread; it
    /// reaches the panel on the main actor.
    nonisolated static func closed(_ panel: ReportProblemPanel, window: ObjectIdentifier) -> @Sendable (Notification) -> Void {
        { [weak panel] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { panel?.windowClosed(window) }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { panel?.windowClosed(window) } }
            }
        }
    }

    /// In front and taking the keyboard even though Intention lives in the
    /// menu bar and was not active.
    static func bringForward(_ window: NSWindow) {
        DockActivationController.shared.willOpen(window)
        window.orderFrontRegardless()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

/// The prompt's note and where its one report has got to. Sending is the
/// submission's; this only says what happened.
@MainActor
@Observable
final class ReportProblemPrompt {
    enum Phase: Equatable {
        case editing
        case sending
        /// The server has the report.
        case sent
        /// The fixed words for why, and whether sending again could work.
        case failed(String, retry: Bool)
    }

    var text = "" {
        didSet {
            // An edited note is a new report, so it is sent, not retried.
            if case .failed(_, retry: true) = phase, text != oldValue { phase = .editing }
        }
    }
    private(set) var phase = Phase.editing
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private let send: @MainActor (String) async throws -> Void

    init(send: @escaping @MainActor (String) async throws -> Void) {
        self.send = send
    }

    var note: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isTooLong: Bool { note.unicodeScalars.count > ProblemReportSubmission.maxTextLength }

    var canSend: Bool {
        switch phase {
        case .editing, .failed(_, retry: true): !isTooLong
        case .sending, .sent, .failed: false
        }
    }

    func submit() async {
        guard canSend else { return }
        phase = .sending
        do {
            try await send(note)
            phase = .sent
        } catch let failure as ProblemReportSubmission.Failure {
            if case let .rateLimited(until) = failure {
                phase = .failed(failure.userFacingMessage, retry: false)
                retryTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow))) }
                    catch { return }
                    self?.phase = .failed("You can try again now.", retry: true)
                }
                return
            }
            // A signed-out report was made without a key, and a build
            // without a server has nowhere to send, so neither retries.
            phase = .failed(failure.userFacingMessage, retry: failure == .sendFailed || failure == .tooLong)
        } catch {
            phase = .failed(ProblemReportSubmission.Failure.sendFailed.userFacingMessage, retry: true)
        }
    }
}


/// The window's page: the heading in Own Hand on the desk, one sheet with
/// the note and what else goes with it, and under it how the report is
/// getting on, Cancel and Send.
struct ReportProblemView: View {
    static let width: CGFloat = 440
    /// Set while stills are drawn, to show the note as it looks with the
    /// keyboard, which a window drawn behind the desktop never has.
    nonisolated(unsafe) static var drawsFocusForStills = false
    /// Set while stills are drawn, to show Cancel and the action under the
    /// pointer, pressed or with keyboard focus (`StillControlState`).
    nonisolated(unsafe) static var stillCancel: StillControlState?
    nonisolated(unsafe) static var stillAction: StillControlState?
    @Bindable var prompt: ReportProblemPrompt
    let close: () -> Void
    @Environment(\.palette) private var palette
    @FocusState private var noteFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SetupHeading(title: "Report a problem", delay: 0.1, size: 30)
                .foregroundStyle(palette.ink)
                .padding(.bottom, 22)
            VStack(alignment: .leading, spacing: 12) {
                NoteField(text: $prompt.text, focused: $noteFocused,
                          isDisabled: prompt.phase == .sending || prompt.phase == .sent)
                Text("Also sends the app you were in and Intention’s setup and recent activity, never text from other apps.")
                    .font(SetupStyle.text(13))
                    .lineSpacing(2)
                    .foregroundStyle(palette.lead)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .paper()
            HStack(alignment: .center, spacing: 14) {
                status
                Spacer(minLength: 0)
                buttons
            }
            .padding(.top, 16)
        }
        .padding(.top, 30)
        .padding([.horizontal, .bottom], 24)
        .frame(width: Self.width)
        .background(palette.ground)
        // The note takes the keyboard as the window opens, ahead of the
        // buttons, which take part in focus for their keyboard ring. The
        // window is built before it is shown, and focus asked for then is
        // dropped once the buttons take part, so it is asked for again
        // each time the window becomes key.
        .defaultFocus($noteFocused, true)
        .onAppear { noteFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notice in
            guard (notice.object as? NSWindow)?.identifier == ReportProblemPanel.identifier,
                  prompt.phase != .sending, prompt.phase != .sent else { return }
            noteFocused = true
        }
    }

    @ViewBuilder private var status: some View {
        switch prompt.phase {
        case .editing where prompt.isTooLong:
            ProblemLine(text: ProblemReportSubmission.Failure.tooLong.userFacingMessage)
        case .editing:
            EmptyView()
        case .sending:
            HStack(spacing: 8) {
                WorkingDot()
                Text("Sending…")
                    .font(SetupStyle.text(13))
                    .foregroundStyle(palette.secondary)
            }
            .accessibilityElement(children: .combine)
        case .sent:
            DoneLine(text: "Sent. Thanks.")
        case .failed(let message, _):
            ProblemLine(text: message)
        }
    }

    /// Cancel, a quiet link, and the window's one action in Ink: Send, Try
    /// again, or Done once the report has gone. While it sends, and while
    /// the note is too long, the action rests as a label with no rule or
    /// arrow, at 70 percent and 42 percent.
    @ViewBuilder private var buttons: some View {
        if prompt.phase == .sent {
            Button("Done", action: close)
                .buttonStyle(InkActionStyle(size: Self.actionSize))
                .keyboardShortcut(.defaultAction)
                .environment(\.stillControlState, Self.stillAction)
        } else {
            Button("Cancel", action: close)
                .buttonStyle(QuietLinkStyle())
                .keyboardShortcut(.cancelAction)
                .disabled(prompt.phase == .sending)
                .opacity(prompt.phase == .sending ? 0.5 : 1)
                .environment(\.stillControlState, Self.stillCancel)
            if prompt.canSend {
                Button(isRetry ? "Try again" : "Send") { Task { await prompt.submit() } }
                    .buttonStyle(InkActionStyle(size: Self.actionSize))
                    .keyboardShortcut(.defaultAction)
                    .environment(\.stillControlState, Self.stillAction)
            } else {
                RestingInk(title: isRetry ? "Try again" : "Send",
                           strength: prompt.phase == .sending ? palette.secondary : palette.faint)
            }
        }
    }

    /// The Ink action's label at rest: Own Hand in a quieter ink, the
    /// rule undrawn and no arrow, where the action cannot be pressed. It is
    /// a dimmed button to VoiceOver.
    private struct RestingInk: View {
        let title: String
        let strength: Color

        var body: some View {
            Button(title) {}
                .buttonStyle(Resting(strength: strength))
                .disabled(true)
        }

        private struct Resting: ButtonStyle {
            let strength: Color

            func makeBody(configuration: Configuration) -> some View {
                configuration.label
                    .font(SetupStyle.display(ReportProblemView.actionSize))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(strength)
                    // The Ink action's own padding, and its arrow's room, so
                    // the row keeps its place when the action can be pressed.
                    .padding(EdgeInsets(top: 6, leading: 4, bottom: 12,
                                        trailing: 4 + 12 + 24 * ReportProblemView.actionSize / 30))
            }
        }
    }

    /// The Ink action's size in this small window: Own Hand's least but two.
    static let actionSize: CGFloat = 26

    private var isRetry: Bool {
        if case .failed(_, retry: true) = prompt.phase { true } else { false }
    }

    /// The note: a well one step below the page that turns to paper with
    /// an ink edge while it is being written in. While the report sends
    /// and once it has gone, the note stays in full ink and cannot change:
    /// the field keeps the well's size and is set aside, and the note shows
    /// as text over it, read by VoiceOver as text, scrolling when long. A
    /// disabled field would grey the words to half their ink.
    private struct NoteField: View {
        @Binding var text: String
        var focused: FocusState<Bool>.Binding
        let isDisabled: Bool
        @Environment(\.palette) private var palette

        var body: some View {
            let isFocused = (focused.wrappedValue || ReportProblemView.drawsFocusForStills) && !isDisabled
            TextField("What happened? (optional)", text: $text,
                      prompt: Text("What happened? (optional)").foregroundStyle(palette.secondary), axis: .vertical)
                .textFieldStyle(.plain)
                .font(SetupStyle.text(14))
                .foregroundStyle(palette.ink)
                .lineSpacing(3)
                .lineLimit(4...8)
                .focused(focused)
                .disabled(isDisabled)
                .opacity(isDisabled ? 0 : 1)
                .accessibilityHidden(isDisabled)
                .padding(.vertical, 9)
                .overlay(alignment: .topLeading) {
                    if isDisabled { Sent(text: text) }
                }
                .wellField(isFocused: isFocused, height: nil)
                .animation(SetupMotion.isStill ? nil : .easeOut(duration: 0.2), value: isFocused)
        }

        /// The note as it went, in the field's own type and place.
        private struct Sent: View {
            let text: String
            @Environment(\.palette) private var palette

            var body: some View {
                ScrollView(.vertical) {
                    Text(text.isEmpty ? "No note" : text)
                        .font(SetupStyle.text(14))
                        .foregroundStyle(text.isEmpty ? palette.secondary : palette.ink)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 9)
                }
                .scrollIndicators(.automatic)
                .accessibilityLabel("Note")
                .accessibilityValue(text.isEmpty ? "No note" : text)
            }
        }
    }
}
