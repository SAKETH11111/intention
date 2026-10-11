import AppKit
import SwiftUI

/// Settings, as a sheet over the main window: the sections down the left
/// and the chosen one's cards on the right, then Done. It holds only what
/// a person changes: the dictation key, microphone and languages, their
/// mail and the email switches, opening at login and the dot at the cursor,
/// setup while it is unfinished, and clearing history. Grants are asked
/// for in setup, and the menu bar item asks again for one that goes
/// missing. Which section holds what is `SettingsSection`'s.
struct SettingsSheet: View {
    let model: AppModel
    @Binding var section: SettingsSection
    let done: () -> Void
    /// The Microphone list's unfolding, kept here so the scrolling copy of
    /// the pane agrees with the one it replaces.
    @State private var microphonesOpen = SettingsSheet.drawsMicrophonesOpen
    @Environment(\.palette) private var palette

    static let width: CGFloat = 780
    static let railWidth: CGFloat = 176

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rail(section: $section)
                .frame(width: Self.railWidth)
            VStack(alignment: .trailing, spacing: 0) {
                // A short section sits as it is; a long one scrolls inside
                // the window rather than running off its foot. Done stays
                // in view under it either way.
                ViewThatFits(in: .vertical) {
                    pane
                    ScrollView { pane }
                }
                // The sheet's one action, as onboarding's Continue is drawn.
                Button("Done", action: done)
                    .buttonStyle(InkActionStyle(size: 26))
                    .keyboardShortcut(.cancelAction)
                    .padding(.trailing, 26)
                    .padding(.top, 4)
                    .padding(.bottom, 16)
            }
        }
        .frame(width: Self.width)
        .background(alignment: .leading) {
            Rectangle().fill(palette.rule).frame(width: 0.5).padding(.leading, Self.railWidth)
        }
        // The desk, with each section's cards of paper lying on it, and the
        // one float of a surface over another window.
        .paper(radius: SetupStyle.sheetRadius, floats: true, fill: palette.ground)
        .foregroundStyle(palette.ink)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings")
        .accessibilityAddTraits(.isModal)
    }

    private var pane: some View {
        VStack(alignment: .leading, spacing: 0) {
            SetupHeading(title: section.title, delay: 0.1, size: 30)
                .padding(.top, 2)
                .padding(.bottom, 26)
            ForEach(Array(section.cards.enumerated()), id: \.offset) { _, card in
                let lines = card.filter(isShown)
                if !lines.isEmpty {
                    SettingsCard {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, item in
                            line(item, isFirst: index == 0)
                        }
                    }
                    .padding(.bottom, 16)
                }
            }
        }
        .padding(.top, 28)
        .padding(.horizontal, 32)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Finishing setup is offered only while it is unfinished.
    private func isShown(_ item: SettingsItem) -> Bool {
        item != .setup || !model.onboarding.isFinished
    }

    @ViewBuilder private func line(_ item: SettingsItem, isFirst: Bool) -> some View {
        let preferences = model.preferences
        let writing = WritingRow(isOn: Binding(get: { preferences.writesEmails }, set: { model.setWritesEmails($0) }),
                                 availability: model.writer.availability,
                                 draftsReplies: Binding(get: { preferences.draftsReplies }, set: { model.setDraftsReplies($0) }),
                                 usesPill: preferences.indicator == .foot,
                                 addsSentWithIntention: Binding(get: { preferences.addsSentWithIntention },
                                                             set: { preferences.addsSentWithIntention = $0 }),
                                 keyName: FirstDictation.keycap(preferences.dictationKey))
        switch item {
        case .dictationKey:
            DictationKeyLine(model: model, isFirst: isFirst)
        case .microphone:
            MicrophoneRow(menu: model.microphoneMenu, follow: { await model.microphones.follow() },
                          isOpen: $microphonesOpen, staysOpen: SettingsSheet.drawsMicrophonesOpen)
        case .languages:
            LanguagesLine(model: model)
        case .mailboxes:
            MailLines(model: model)
        case .writesEmails:
            writing.writesLine
        case .draftsReplies:
            writing.draftsLine
        case .sentWithIntention:
            writing.sentWithIntentionLine
        case .opensAtLogin:
            LoginItemLine(model: model, isFirst: isFirst)
        case .indicator:
            IndicatorLine(model: model, isFirst: isFirst)
        case .appearance:
            AppearanceLine(model: model, isFirst: isFirst)
        case .dotPosition:
            DotPositionLine(model: model, isFirst: isFirst)
        case .setup:
            SettingsLine(title: "Setup isn't finished", detail: "Finish setting up to sign in and connect your mail.", isFirst: isFirst) {
                Button("Finish Setting Up\u{2026}") { model.showSetup() }
                    .buttonStyle(SeatButtonStyle(isSmall: true))
            }
        case .version:
            SettingsLine(title: "Version", isFirst: isFirst) {
                HStack(spacing: 14) {
                    Text(Self.version)
                        .font(SetupStyle.text(13))
                        .monospacedDigit()
                        .foregroundStyle(palette.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .textSelection(.enabled)
                    if Self.offersUpdates(model) {
                        // The menu bar item's Check for Updates, the same action.
                        Button("Check for updates") { model.updater.checkForUpdates() }
                            .buttonStyle(WordButtonStyle())
                    }
                }
                .fixedSize()
            }
        case .reportProblem:
            // The menu bar item's Report a problem. From here the report
            // names Intention as the app in front, since Settings is.
            SettingsOpenLine(title: "Report a problem", isFirst: isFirst) {
                model.problemReportPanel.open(model.makeProblemReport)
            }
        case .clearHistory:
            ClearHistoryLine(model: model, isFirst: isFirst)
        }
    }
}

extension SettingsSheet {
    static var version: String {
        ReleaseVersion.label(version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
    }

    /// Check for updates shows only when this build updates itself, as in
    /// the menu, and in a Settings render that asks to draw it.
    static func offersUpdates(_ model: AppModel) -> Bool {
        #if DEBUG
        if CommandLine.arguments.contains("--settings-updates") { return true }
        #endif
        return model.updater.isActive
    }

    /// A Settings render with `--settings-microphones-open` draws the
    /// Microphone list unfolded.
    static var drawsMicrophonesOpen: Bool {
        #if OFFSCREEN_RENDER
        // Only in a render, whose meter is made up; never in a live launch.
        SettingsSnapshot.isRequested && CommandLine.arguments.contains("--settings-microphones-open")
        #else
        false
        #endif
    }

    static func openMicrophonePrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// The sections, the chosen one on the sky. The arrow keys move between
/// them once the list has the keyboard.
private struct Rail: View {
    @Binding var section: SettingsSection
    @Environment(\.palette) private var palette
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings")
                .font(SetupStyle.text(11, .semibold))
                .tracking(0.88)
                .textCase(.uppercase)
                .foregroundStyle(palette.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 12)
                .accessibilityHidden(true)
            ForEach(SettingsSection.allCases) { item in
                Button { section = item } label: {
                    Text(item.title)
                }
                .buttonStyle(RailItemStyle(isChosen: item == section, raisesEdge: contrast == .increased))
                .keyboardFocusRing(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityAddTraits(item == section ? .isSelected : [])
            }
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 12)
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { direction in
            let all = SettingsSection.allCases
            guard let index = all.firstIndex(of: section) else { return }
            switch direction {
            case .up where index > 0: section = all[index - 1]
            case .down where index < all.count - 1: section = all[index + 1]
            default: break
            }
        }
    }
}

/// A section in the rail: its name in ink at 76 percent on the desk, full
/// ink under the pointer, and when chosen full ink with the hand rule
/// drawn under it, as a window's heading is. Nothing is filled.
private struct RailItemStyle: ButtonStyle {
    let isChosen: Bool
    let raisesEdge: Bool

    func makeBody(configuration: Configuration) -> some View {
        Item(label: configuration.label, isChosen: isChosen, raisesEdge: raisesEdge)
    }

    private struct Item<Label: View>: View {
        let label: Label
        let isChosen: Bool
        let raisesEdge: Bool
        @Environment(\.palette) private var palette
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.stillControlState) private var still
        @State private var hovering = false
        @State private var ruled: CGFloat = SetupMotion.isStill ? 1 : 0

        var body: some View {
            label
                .font(SetupStyle.text(14, isChosen ? .semibold : .medium))
                .foregroundStyle(isChosen || hovering || still == .hover ? palette.ink : palette.lead)
                .fixedSize()
                .background {
                    GeometryReader { proxy in
                        HandRule(width: proxy.size.width + 4)
                            .trim(from: 0, to: isChosen ? ruled : 0)
                            .stroke(palette.ink.opacity(raisesEdge ? 0.9 : 0.6),
                                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                            .frame(width: proxy.size.width + 4, height: 8)
                            .offset(x: -2, y: proxy.size.height - 3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .onAppear { if isChosen { draw() } }
                .onChange(of: isChosen) { _, chosen in
                    guard chosen else { return }
                    var none = Transaction()
                    none.disablesAnimations = true
                    withTransaction(none) { ruled = 0 }
                    Task { @MainActor in draw() }
                }
        }

        /// The rule draws on once, in 180 ms, as the section is chosen.
        private func draw() {
            guard !SetupMotion.isStill, !reduceMotion else {
                ruled = 1
                return
            }
            withAnimation(SetupMotion.quadOut(SetupMotion.draw)) { ruled = 1 }
        }
    }
}

/// A line that opens something, as Report a problem does: the whole line
/// is the button, ending in a drawn chevron.
private struct SettingsOpenLine: View {
    let title: String
    var isFirst = false
    let open: () -> Void
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.stillControlState) private var still
    @State private var hovering = false

    var body: some View {
        let hovering = hovering || still == .hover
        Button(action: open) {
            HStack {
                Text(title)
                    .font(SetupStyle.text(14, .semibold))
                    .foregroundStyle(palette.ink)
                Spacer(minLength: 16)
                DrawnChevron(direction: .right)
                    .foregroundStyle(palette.faint)
                    .offset(x: hovering ? 2 : 0)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardFocusRing(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { inside in withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { self.hovering = inside } }
        .overlay(alignment: .top) {
            if !isFirst { SettingsRule() }
        }
    }
}

/// The dictation key, its field, and while the field listens, what to do
/// or why the keys pressed cannot be used. A build with no dictation
/// server says so here.
private struct DictationKeyLine: View {
    let model: AppModel
    let isFirst: Bool

    var body: some View {
        let recorder = model.keyRecorder
        let notConfigured = model.dictation.problem == .notConfigured
        SettingsLine(title: "Hold to dictate",
                     detail: recorder.isRecording ? "Press the keys you want, then let go. Esc cancels."
                         : HoldKey.instructions(for: model.preferences.dictationKey),
                     note: recorder.isRecording ? recorder.refusal
                         : notConfigured ? "This build has no dictation server, so dictation is off." : nil,
                     isFirst: isFirst) {
            DictationKeyField(recorder: recorder, key: model.preferences.dictationKey)
        }
    }
}

/// The dictation key, shown as its keycaps on a paper seat button.
/// Clicking it listens for the keys the person presses next and saves them
/// once they are let go; while it listens it is a field, paper with an ink
/// edge. Clicking it again, Escape, or the window losing the keyboard
/// cancels; the recorder watches for that last one itself.
private struct DictationKeyField: View {
    let recorder: KeyRecorder
    let key: HoldKey.Key
    @Environment(\.palette) private var palette
    @Environment(\.stillControlState) private var still
    @State private var hovering = false

    var body: some View {
        let recording = recorder.isRecording
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Button {
            recording ? recorder.cancel() : recorder.start()
        } label: {
            Group {
                if recording {
                    Text(recorder.shown ?? "Press keys\u{2026}")
                        .font(SetupStyle.text(13, .semibold))
                        .foregroundStyle(recorder.shown == nil ? palette.secondary : palette.ink)
                } else {
                    HStack(spacing: 5) {
                        ForEach(Array(FirstDictation.keycap(key).components(separatedBy: " + ").enumerated()), id: \.offset) { index, cap in
                            if index > 0 {
                                Text("+").font(SetupStyle.text(12, .medium)).foregroundStyle(palette.secondary)
                            }
                            InlineKeycap(label: cap)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(minWidth: 84)
            .frame(height: 30)
            .background(recording ? palette.sheet : hovering || still == .hover ? palette.paperButtonHover : palette.well, in: shape)
            .overlay(shape.strokeBorder(recording ? palette.ink : palette.edge, lineWidth: recording ? 1 : 0.5))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
        }
        .buttonStyle(.plain)
        .keyboardFocusRing(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityLabel("Dictation key")
        .accessibilityValue(recording ? "Listening for keys" : key.title)
        .accessibilityHint("Click, then press the keys to hold for dictation")
        .onDisappear { recorder.cancel() }
    }
}

/// The languages the person dictates in, as chips, with Add for a menu of
/// ticks under the names already picked; unticking one there takes it
/// away. The question and its rules are setup's (`LanguageChoice`); this
/// is the place to change the answer.
private struct LanguagesLine: View {
    let model: AppModel
    @Environment(\.palette) private var palette

    var body: some View {
        let chosen = LanguageChoice.chosen(from: model.preferences.dictationLanguages)
        SettingsLine(title: "Languages", detail: "Up to five. Intention hears whichever you speak.") {
            // As many chosen languages as the line has room for, then how
            // many more, then Add.
            ViewThatFits(in: .horizontal) {
                ForEach((1...max(1, chosen.count)).reversed(), id: \.self) { shown in
                    HStack(spacing: 12) {
                        ForEach(chosen.prefix(shown), id: \.self) { word($0, in: chosen) }
                        if chosen.count > shown {
                            Text("+\(chosen.count - shown)")
                                .font(SetupStyle.text(14))
                                .foregroundStyle(palette.lead)
                        }
                        menu(chosen).padding(.leading, 2)
                    }
                }
            }
            // As wide as the words need, up to 360 points, before the
            // sentence beside it gives way.
            .frame(maxWidth: 360, alignment: .trailing)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Languages: \(ListFormatter.localizedString(byJoining: chosen.map(LanguageChoice.name)))")
        }
    }

    /// A chosen language: its name in ink, and under the pointer a drawn
    /// cross that takes it away, as unticking it in Add's menu does. The
    /// last one cannot be taken away (`LanguageChoice.toggled`).
    private func word(_ code: String, in chosen: [String]) -> some View {
        let without = LanguageChoice.toggled(code, in: chosen)
        return LanguageWord(name: LanguageChoice.name(code), canRemove: without != chosen) {
            model.setDictationLanguages(LanguageChoice.saved(for: without))
        }
    }

    private func menu(_ chosen: [String]) -> some View {
        Menu {
            ForEach(LanguageChoice.offered(preferred: Locale.preferredLanguages, chosen: chosen), id: \.self) { code in
                Toggle(LanguageChoice.name(code), isOn: Binding(
                    get: { chosen.contains(code) },
                    set: { _ in model.setDictationLanguages(LanguageChoice.saved(for: LanguageChoice.toggled(code, in: chosen))) }
                ))
                // A sixth cannot be added, and the last one cannot be
                // taken away; `toggled` holds both rules.
                .disabled(LanguageChoice.toggled(code, in: chosen) == chosen)
            }
        } label: {
            PopUpLabel(title: "+ Add", showsMarks: false)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .keyboardFocusRing(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityLabel("Change languages")
    }
}

/// One chosen language in the Languages line: the name, then a drawn
/// cross at 70 percent that shows under the pointer, or with keyboard
/// focus, to remove it; the last language has none.
private struct LanguageWord: View {
    let name: String
    let canRemove: Bool
    let remove: () -> Void
    @Environment(\.palette) private var palette
    @Environment(\.stillControlState) private var still
    @State private var hovering = false
    @FocusState private var crossFocused: Bool

    var body: some View {
        let shown = canRemove && (hovering || crossFocused || still == .hover)
        HStack(spacing: 5) {
            Text(name)
                .font(SetupStyle.text(14))
                .foregroundStyle(palette.ink)
                .fixedSize()
            Button(action: remove) {
                // The spec's cross as a control: 16 points, two strokes.
                DrawnCross(size: 10)
                    .foregroundStyle(palette.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardFocusRing(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .focused($crossFocused)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .disabled(!canRemove)
            .accessibilityLabel("Remove \(name)")
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// The mailboxes as the server reports them, reread while Settings is
/// open through the same reading setup's mail page uses. A mailbox that
/// syncs or is up to date shows its address and progress and offers
/// nothing; Reconnect appears only when the server says it is needed.
private struct MailLines: View {
    let model: AppModel
    @Environment(\.palette) private var palette

    var body: some View {
        let onboarding = model.onboarding
        Group {
            if !onboarding.isFinished {
                SettingsLine(title: "Mail", detail: "Mailbox setup is unavailable in this demo. Use the supplied demo account.", isFirst: true) {
                    Button("Finish Setting Up\u{2026}") { model.showSetup() }
                        .buttonStyle(SeatButtonStyle(isSmall: true))
                }
            } else if onboarding.settingsConnections.isEmpty {
                // Gmail stops taking new accounts at Google's unverified-app
                // limit; another provider, when offered, still connects. A
                // server without Gmail says nothing about it.
                let gmailClosed = onboarding.hasReadMail && onboarding.availableProviders.contains(.gmail)
                    && !onboarding.gmailConnectOpen
                let connectable = onboarding.offeredMailProviders
                SettingsLine(title: "Mail", detail: gmailClosed ? "New Gmail connections are paused. Dictation works now."
                    : "Mailbox setup is unavailable in this demo. Use the supplied demo account.", isFirst: true) {
                    if !onboarding.hasReadMail, onboarding.mailReadFailed {
                        // The list could not be read; setup's mail page shows
                        // the providers and keeps trying.
                        Button("Open Mail Setup\u{2026}") { model.showMailSetup() }
                            .buttonStyle(SeatButtonStyle(isSmall: true))
                    } else if !onboarding.hasReadMail {
                        Text("Checking\u{2026}").font(SetupStyle.text(13)).foregroundStyle(palette.secondary)
                    } else if !connectable.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(connectable, id: \.self) { provider in
                                Button { model.connectMail(provider) } label: {
                                    HStack(spacing: 7) {
                                        ProviderMark(provider: provider, size: 14)
                                        Text("Connect \(MailboxLine.name(provider))")
                                    }
                                }
                                .accessibilityLabel("Connect \(MailboxLine.name(provider))")
                            }
                        }
                        .buttonStyle(SeatButtonStyle(isSmall: true))
                        .disabled(!onboarding.canChangeMail)
                    } else if !gmailClosed {
                        Text("Mailbox setup is unavailable in this demo.").font(SetupStyle.text(13)).foregroundStyle(palette.secondary)
                    }
                }
            } else {
                ForEach(Array(onboarding.settingsConnections.enumerated()), id: \.element.id) { index, connection in
                    MailboxLine(connection: connection, isFirst: index == 0,
                                isDisconnecting: onboarding.disconnectingMail == connection.id,
                                canChange: onboarding.canChangeMail,
                                canReconnect: AlphaClient.MailProvider(rawValue: connection.provider).map { onboarding.mailOffer(for: $0) == .reconnect } ?? false,
                                reconnect: { model.connectMail($0) },
                                disconnect: { Task { await onboarding.disconnectMail(connection) } })
                }
                // The server keeps one mailbox per provider, so another can
                // be added only while a provider has none.
                if onboarding.canAddMail {
                    AddAccountLine { model.showMailSetup() }
                        .disabled(!onboarding.canChangeMail)
                }
            }
            if onboarding.mailDisconnectFailed {
                SettingsNote(text: "Couldn't confirm the disconnection. Check your connection and try again.")
                    .padding(16)
            }
            if onboarding.isFinished, onboarding.mailReadFailed {
                let failure = Self.failure(unreachable: onboarding.mailProblem == .unreachable, shownBefore: onboarding.hasReadMail)
                Group {
                    if onboarding.hasReadMail {
                        // What an earlier read showed stays; this only says
                        // it may be out of date.
                        Text(failure)
                            .font(SetupStyle.text(13))
                            .foregroundStyle(palette.secondary)
                    } else {
                        // Nothing could be read: a line that needs doing.
                        SettingsNote(text: failure)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { SettingsRule() }
            }
        }
        // Reread while Settings shows this, and stopped when it closes.
        .task { await onboarding.followMail() }
    }

    /// Why the latest read of the mailbox list failed. What an earlier
    /// read showed stays, marked as possibly out of date, until a read
    /// succeeds again.
    private static func failure(unreachable: Bool, shownBefore: Bool) -> String {
        switch (unreachable, shownBefore) {
        case (true, false): "Couldn't reach Intention's server to read your mailboxes."
        case (false, false): "Intention couldn't read your mailboxes just now."
        case (true, true): "Couldn't reach Intention's server, so this may be out of date."
        case (false, true): "Couldn't check just now, so this may be out of date."
        }
    }
}

/// One mailbox: its provider's own mark, its address, one line of which
/// provider and how far its sync has come, and why it stopped, with
/// Reconnect, when it has.
private struct MailboxLine: View {
    let connection: AlphaClient.MailConnection
    let isFirst: Bool
    let isDisconnecting: Bool
    let canChange: Bool
    let canReconnect: Bool
    let reconnect: (AlphaClient.MailProvider) -> Void
    let disconnect: () -> Void
    @State private var confirmingDisconnect = false
    @Environment(\.palette) private var palette

    var body: some View {
        let standing = OnboardingModel.standing(of: connection)
        let provider = AlphaClient.MailProvider(rawValue: connection.provider)
        HStack(spacing: 14) {
            ProviderMark(provider: provider)
            VStack(alignment: .leading, spacing: 3) {
                Text(connection.address)
                    .font(SetupStyle.text(14, .semibold))
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 7) {
                    if standing == .upToDate { DrawnCheck().scaleEffect(0.8) }
                    Text(Self.summary(provider: provider, standing: standing, stored: connection.storedMessages))
                        .font(SetupStyle.text(13))
                        .monospacedDigit()
                        .foregroundStyle(palette.lead)
                }
                if standing.isBroken {
                    SettingsNote(text: Self.reason(standing))
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            VStack(alignment: .trailing, spacing: 8) {
                if canReconnect, let provider {
                    Button("Reconnect") { reconnect(provider) }
                        .buttonStyle(SeatButtonStyle(isSmall: true))
                }
                Button(isDisconnecting ? "Disconnecting…" : "Disconnect") { confirmingDisconnect = true }
                    .buttonStyle(SeatButtonStyle(isSmall: true))
            }
            .disabled(!canChange)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 48)
        .overlay(alignment: .top) {
            if !isFirst { SettingsRule() }
        }
        .confirmationDialog("Disconnect \(Self.name(provider))?", isPresented: $confirmingDisconnect) {
            Button("Disconnect", role: .destructive, action: disconnect)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Intention will stop reading this mailbox and delete its imported mail. Your mail in \(Self.name(provider)) stays.")
        }
    }

    static func name(_ provider: AlphaClient.MailProvider?) -> String {
        switch provider {
        case .gmail?: "Gmail"
        case .outlook?: "Outlook"
        case nil: "Mail"
        }
    }

    /// One short line: the provider, how far the sync has come and how
    /// many messages it holds, such as "Gmail · up to date · 4,212 messages".
    static func summary(provider: AlphaClient.MailProvider?, standing: OnboardingModel.MailStanding, stored: Int) -> String {
        let count = "\(stored.formatted()) \(stored == 1 ? "message" : "messages")"
        let state: [String] = switch standing {
        case .syncing: stored == 0 ? ["syncing, starting with sent mail"] : ["syncing", count]
        case .checking: ["checking", count]
        case .upToDate: ["up to date", count]
        case .retrying: ["retrying soon", count]
        case .addressChanged: ["stopped", count]
        case .needsReconnect, .stopped: [count]
        }
        return ([name(provider)] + state).joined(separator: " \u{00B7} ")
    }

    /// Why the mailbox stopped, in one plain line. The server says only
    /// that Intention can no longer read it, not who ended that, so the line
    /// does not guess.
    static func reason(_ standing: OnboardingModel.MailStanding) -> String {
        switch standing {
        case .addressChanged: "Its address changed, so syncing stopped. Reconnecting can't fix this yet."
        case .stopped: "Syncing stopped and won't restart until you reconnect."
        default: "Intention needs your permission again to read this mailbox."
        }
    }
}

/// A mail provider's own mark, Gmail's or Outlook's, as setup shows it:
/// the real logo, never redrawn.
private struct ProviderMark: View {
    let provider: AlphaClient.MailProvider?
    var size: CGFloat = 20

    var body: some View {
        Image(nsImage: SetupStyle.image(provider == .outlook ? "MailOutlook" : "MailGmail", "pdf"))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Another mailbox, through setup's mail page: a line that opens something.
private struct AddAccountLine: View {
    let add: () -> Void

    var body: some View {
        SettingsOpenLine(title: "Add an account", open: add)
    }
}

/// Opening Intention at login, and what macOS is waiting for when it has not
/// added Intention yet.
private struct LoginItemLine: View {
    let model: AppModel
    let isFirst: Bool

    var body: some View {
        let loginItem = model.loginItem
        let pending = loginItem.state == .off && model.preferences.loginItemPending
        SettingsLine(title: "Open Intention at login",
                     // Waiting for a launch from Applications, or for macOS,
                     // which refused the last try from there; each launch
                     // tries again.
                     detail: pending ? (LoginItem.isStable()
                         ? "macOS hasn't added Intention to Login Items yet. Intention tries again each time it opens."
                         : "Intention will open at login once you open it from Applications.") : loginItem.failure,
                     note: loginItem.state == .needsApproval ? "macOS is waiting for you to allow Intention in Login Items." : nil,
                     isFirst: isFirst) {
            HStack(spacing: 12) {
                if loginItem.state == .needsApproval {
                    Button("Open Login Items") { loginItem.openSystemSettings() }
                        .buttonStyle(SeatButtonStyle(isSmall: true))
                }
                SettingsSwitch(title: "Open Intention at login", isOn: Binding(get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) }))
            }
        }
        .onAppear { loginItem.refresh() }
    }
}

/// Whether the dot also sits above the cursor in an email Intention can
/// write; the foot mark shows either way, and no other field has a caret
/// dot. Shown is the default and the question is not asked during setup;
/// this is the one place to change the answer.
private struct IndicatorLine: View {
    let model: AppModel
    let isFirst: Bool

    var body: some View {
        let style = model.preferences.indicator
        SettingsLine(title: "Dot in emails",
                     detail: style == .dot ? "In an email Intention can write, a dot sits above your cursor."
                         : "Only the dot at the edge of your screen shows.",
                     isFirst: isFirst) {
            IntentionSegments(title: "Show the dot at your cursor in emails",
                           selection: Binding(get: { model.preferences.indicator }, set: { model.setIndicator($0) }),
                           options: IndicatorStyle.allCases.map { ($0, $0.title) })
        }
    }
}

/// Light or Dark. Light is the default and Dark is only ever chosen here,
/// never taken from the system's setting or the clock.
private struct AppearanceLine: View {
    let model: AppModel
    let isFirst: Bool

    var body: some View {
        SettingsLine(title: "Appearance", detail: "Light unless you choose Dark.", isFirst: isFirst) {
            IntentionSegments(title: "Appearance",
                           selection: Binding(get: { model.preferences.appearance }, set: { model.setAppearance($0) }),
                           options: Appearance.allCases.map { ($0, $0.title) })
        }
    }
}

/// Where the dot at the foot of the screen rests, on every display. Dragging
/// the dot there moves it on one display; the last choice shows here. While
/// the person has hidden it from its menu, the line says until when and
/// offers to show it now.
private struct DotPositionLine: View {
    let model: AppModel
    let isFirst: Bool

    var body: some View {
        let hidden = model.footHiddenUntil
        SettingsLine(title: "Dot position", detail: "Or drag the dot to where you want it.",
                     note: hidden.map { "Hidden until \($0.formatted(date: .omitted, time: .shortened))." }, isFirst: isFirst) {
            VStack(alignment: .trailing, spacing: 8) {
                IntentionSegments(title: "Dot position",
                               selection: Binding(get: { model.preferences.dotPosition }, set: { model.setDotPosition($0) }),
                               options: FootSlot.allCases.map { ($0, $0.title) }) { slot, _ in
                    SlotGlyph(slot: slot)
                }
                if hidden != nil {
                    Button("Show it now") { model.showFootAgain() }
                        .buttonStyle(WordButtonStyle())
                }
            }
        }
    }
}

/// A screen in outline with the dot where the slot puts it: the foot's
/// centre, or halfway up the left or right edge. It stands in for the
/// slot's name, which stays its VoiceOver label. Drawn to the small-size
/// rule: true geometry, an even 1.5-point pen, in the segment's ink.
private struct SlotGlyph: View {
    let slot: FootSlot

    var body: some View {
        let alignment: Alignment = switch slot {
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .strokeBorder(lineWidth: 1.5)
            .overlay(alignment: alignment) {
                Circle().frame(width: 5, height: 5).padding(3)
            }
            .frame(width: 24, height: 16)
    }
}

/// History, and clearing it, here and nowhere else. Clearing also drops
/// every recording kept for Retry (`AppModel.clearHistory`).
private struct ClearHistoryLine: View {
    let model: AppModel
    let isFirst: Bool
    @State private var confirming = false
    @State private var failed = false

    var body: some View {
        SettingsLine(title: "History",
                     detail: "Your dictations are kept on this Mac. Clearing removes your history from this Mac. Emails Intention wrote stay in your mail.",
                     isFirst: isFirst) {
            Button("Clear history\u{2026}") { confirming = true }
                .buttonStyle(SeatButtonStyle(isSmall: true, isDestructive: true))
                .disabled(!model.dictation.history.canClear)
        }
        .confirmationDialog("Clear your history?", isPresented: $confirming) {
            Button("Clear History", role: .destructive) {
                if !model.clearHistory() { failed = true }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your history on this Mac goes, with any recording kept for Retry. This can't be undone.")
        }
        .alert("History could not be removed from this Mac, so it is still shown.", isPresented: $failed) {
            Button("OK") {}
        }
    }
}
