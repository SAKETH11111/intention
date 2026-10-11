import SwiftUI

/// The setup window's content: a tall window under the painting, which the
/// view walks along page by page toward the sun, through the sky's morning.
/// Sign-in is in the pale before dawn; the first dictation brings first
/// light along the ridge; the first email brings the sunrise. Each page is
/// something to do, not to read: a code to type, a button to press, a key
/// to hold, a reply to speak, with its one action in the website's Ink
/// style and anything else a quiet link. When setup ends the sun lifts out
/// of the window and flies down into the foot mark (`OnboardingWindow`).
///
/// A page is three layers, the heading on the sky, the sheet and the
/// actions, so a turn can fade each on its own time while the painting
/// walks: the old heading goes first, the two sheets cross so paper is
/// always there, and the new heading writes itself on. Everything that
/// moves has an end; under Reduce Motion nothing travels or scales, and the
/// fades stay.
struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    /// Ends setup once the light has gathered in the sun, given the sun's
    /// frame in the window: the window lifts it out, fades and closes. Nil
    /// where the window closes on a page reopened after setup, which only
    /// fades.
    let end: (CGRect?) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let size = CGSize(width: 540, height: 760)

    /// The page on show, which lags the model's step by the turn.
    @State private var page: SetupPage?
    @State private var light = SetupLight()
    /// The moments of the page's payoff that have come.
    @State private var beats: Set<Beat> = []
    /// The sun's light on the sheet, and the catch of it along its top edge.
    @State private var sheetLight: Double = 0
    @State private var rim: Double = 0
    @State private var sunLifted = false
    @State private var opened = false
    /// Whether the page on show is the one the window opened on.
    @State private var opening = true
    /// Set once the window's view has gone, so no beat lands after it.
    @State private var gone = false

    var body: some View {
        let shown = page ?? SetupPage(model.step) ?? .openAtLogin
        let context = PageContext(model: model, beats: beats, sheetLight: sheetLight, rim: rim, opening: opening)
        ZStack(alignment: .topLeading) {
            SetupPainting(light: light, sunLifted: sunLifted)
            // Each layer in its own stack, so the three share the page as
            // their identity without being siblings of one another.
            ZStack(alignment: .topLeading) {
                PageView(page: shown, part: .head, context: context)
                    .id(shown)
                    .transition(.asymmetric(insertion: .identity,
                                            removal: .opacity.animation(SetupMotion.quadOut(0.2).delay(0.1))))
            }
            ZStack(alignment: .topLeading) {
                PageView(page: shown, part: .sheet, context: context)
                    .id(shown)
                    .transition(.asymmetric(insertion: .opacity.animation(SetupMotion.quadInOut(0.4).delay(opening ? 0.35 : 0.45)),
                                            removal: .opacity.animation(SetupMotion.quadInOut(0.4).delay(0.45))))
            }
            ZStack(alignment: .topLeading) {
                PageView(page: shown, part: .actions, context: context)
                    .id(shown)
                    .transition(.asymmetric(insertion: .opacity.animation(.linear(duration: 0.3).delay(0.65)),
                                            removal: .opacity.animation(SetupMotion.quadInOut(0.4).delay(0.45))))
            }
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .overlay(alignment: .bottom) {
            // The reply page's written email takes the room the note would.
            if model.keyCheckSkipped, model.step != .tryIt, !(model.step == .reply && model.replyFieldWords != nil) {
                Text("\(model.dictation?.keyName() ?? "fn") hasn't been checked. The dot still works.")
                    .font(SetupStyle.text(12))
                    .foregroundStyle(SetupStyle.secondary)
                    .padding(.bottom, 76)
            }
        }
        .overlay(alignment: .top) {
            Image(nsImage: Self.wordmark)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: 52)
                .foregroundStyle(SetupStyle.ink.opacity(0.85))
                .padding(.top, 15)
                .accessibilityLabel("Intention")
        }
        // The window opens as macOS zooms a window in, from 95.5%, while
        // the window fades in (`OnboardingWindow.show`).
        .scaleEffect(opened || reduceMotion ? 1 : 0.955)
        .ignoresSafeArea()
        .foregroundStyle(SetupStyle.ink)
        .environment(\.colorScheme, .light)
        // Grants, dictations and sync progress change outside the view, so
        // they are followed only while their page is showing.
        .task(id: model.step) {
            switch model.step {
            case .permissions: await model.watchPermissions()
            case .shortcut: await model.watchShortcut()
            case .tryIt: await model.watchDictation()
            case .mail: await model.watchMail()
            case .reply: await model.watchReply()
            case .openAtLogin: await model.followMail()
            case .signIn, .done: break
            }
        }
        .onAppear(perform: open)
        .onDisappear { gone = true }
        .onChange(of: model.step) { _, step in turn(to: step) }
        .onChange(of: model.firstDictation) { before, now in
            if case let .heard(words) = now, !before.isHeard { dictationPayoff(words) }
        }
        .onChange(of: model.reply) { before, now in
            if now == .written, before != .written { emailPayoff() }
        }
    }

    private static let wordmark: NSImage = {
        let image = SetupStyle.image("SetupWordmark", "pdf")
        image.isTemplate = true
        return image
    }()

    private var instant: Bool { SetupMotion.isStill }

    /// Runs `change` after `seconds`, if the page is still `on`.
    private func after(_ seconds: Double, on: SetupPage, _ change: @escaping @MainActor () -> Void) {
        guard seconds > 0, !instant else { return change() }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
            guard page == on, !gone else { return }
            change()
        }
    }

    private func animate(_ animation: Animation?, _ change: () -> Void) {
        if instant { change() } else { withAnimation(animation, change) }
    }

    // MARK: - The walk

    /// The window opens on the page setup is at, with the painting where
    /// that page stands and the light it has earned.
    private func open() {
        let start = SetupPage(model.step) ?? .openAtLogin
        page = start
        light = Self.light(at: start, model: model)
        beats = Self.settled(start, model: model)
        (sheetLight, rim) = Self.paper(start, model: model)
        animate(SetupMotion.cubicOut(0.32)) { opened = true }
    }

    /// The light a page has when the window opens on it, or when the walk
    /// reaches it: first light from the email on, the sunrise from You're set on,
    /// or as soon as each has been earned on its own page.
    private static func light(at page: SetupPage, model: OnboardingModel) -> SetupLight {
        var light = SetupLight()
        (light.walk, light.dusk) = SetupLight.at(page)
        let heard = page == .tryIt && model.firstDictation.isHeard
        let written = page == .reply && model.reply == .written
        if page >= .reply || heard {
            light.first = 1
            if heard { light.dusk = 0.4 }
        }
        if page >= .openAtLogin || written {
            light.rise = 1
            light.wash = 1
            light.dusk = 0
            light.warm = 0.55
            light.beam = 1
        }
        return light
    }

    /// The paper's own light on a page as it arrives: from the right once
    /// first light has come on the dictation page, from above once the sun
    /// is up.
    private static func paper(_ page: SetupPage, model: OnboardingModel) -> (Double, Double) {
        switch page {
        case .tryIt where model.firstDictation.isHeard: (0.8, 0)
        case .reply where model.reply == .written: (1, 0.55)
        case .openAtLogin: (1, 0)
        default: (0, 0)
        }
    }

    /// The beats a page shows when it arrives: all of them where its
    /// payoff has already happened, none where it is still to come.
    private static func settled(_ page: SetupPage, model: OnboardingModel) -> Set<Beat> {
        switch page {
        case .tryIt: model.firstDictation.isHeard ? Set(Beat.allCases) : []
        case .reply: model.reply == .written ? Set(Beat.allCases) : []
        default: Set(Beat.allCases)
        }
    }

    /// Turns to the step's page: the view walks along the painting while
    /// the pages cross. Done begins the end.
    private func turn(to step: OnboardingModel.Step) {
        guard let next = SetupPage(step) else { return finish() }
        guard next != page else { return }
        let target = Self.light(at: next, model: model)
        animate(reduceMotion ? nil : SetupMotion.walk) {
            light.walk = target.walk
            light.dusk = target.dusk
        }
        if target.first > light.first {
            animate(reduceMotion ? .linear(duration: 0.6) : SetupMotion.cubicOut(1.6)) { light.first = target.first }
        }
        if target.rise > light.rise {
            // A sunrise that was skipped comes with the walk to You're set.
            if reduceMotion || instant { light.rise = 1 } else { withAnimation(SetupMotion.cubicOut(1.7)) { light.rise = 1 } }
            animate(SetupMotion.quadOut(1.4)) { light.wash = 1 }
            if reduceMotion { light.beam = target.beam }
            animate(SetupMotion.quadInOut(1.4)) {
                light.warm = target.warm
                light.beam = target.beam
            }
        }
        let (paper, edge) = Self.paper(next, model: model)
        animate(SetupMotion.quadOut(0.6).delay(0.45)) {
            sheetLight = paper
            rim = edge
        }
        beats = Self.settled(next, model: model)
        opening = false
        animate(.default) { page = next }
    }

    // MARK: - Payoffs

    /// The first dictation's words have arrived. On the last word, first
    /// light runs in along the ridge from the right and the sheet's right
    /// edge catches it; the heading becomes "That's dictation" and Continue
    /// arrives.
    private func dictationPayoff(_ words: String) {
        let last = instant || reduceMotion ? 0 : SetupMotion.landing(words: words.split(separator: " ").count)
        after(last, on: .tryIt) {
            animate(reduceMotion ? .linear(duration: 0.6) : SetupMotion.cubicOut(1.6)) {
                light.first = 1
                light.dusk = 0.4
            }
        }
        reveal(.heading, at: last + 0.06, on: .tryIt)
        reveal(.lead, at: last + 0.2, on: .tryIt)
        reveal(.skipGone, at: last + 0.6, on: .tryIt, animation: .linear(duration: 0.16))
        reveal(.after, at: last + 0.7, on: .tryIt, animation: .linear(duration: 0.28))
        after(last + 0.75, on: .tryIt) { animate(SetupMotion.quadOut(0.7)) { sheetLight = 0.8 } }
        reveal(.action, at: last + 1.3, on: .tryIt)
    }

    /// The practice email has been written. On its last word the sun clears
    /// the ridge, its light comes down across the hills onto the paper, and
    /// the sheet's top edge catches it last.
    private func emailPayoff() {
        let words = model.replyFieldWords?.text.split(separator: " ").count ?? 0
        let last = instant || reduceMotion ? 0 : SetupMotion.landing(words: words)
        after(last, on: .reply) {
            // Under Reduce Motion the sun is at its height when its moment
            // comes, and only the light crossfades.
            if reduceMotion || instant { light.rise = 1 } else { withAnimation(SetupMotion.cubicOut(1.7)) { light.rise = 1 } }
            animate(SetupMotion.quadInOut(1.5)) { light.dusk = 0 }
        }
        after(last + 0.1, on: .reply) { animate(SetupMotion.quadOut(1.4)) { light.wash = 1 } }
        after(last + 0.15, on: .reply) {
            // The light comes down from the sky; under Reduce Motion it is
            // simply there, and fades in.
            if reduceMotion { light.beam = 1 }
            animate(SetupMotion.quadInOut(1.4)) {
                light.warm = 0.55
                light.beam = 1
            }
        }
        after(last + 0.95, on: .reply) { animate(SetupMotion.quadOut(0.6)) { sheetLight = 1 } }
        after(last + 1.5, on: .reply) { animate(SetupMotion.cubicOut(0.18)) { rim = 1 } }
        after(last + 1.68, on: .reply) { animate(SetupMotion.quadInOut(0.5)) { rim = 0.55 } }
        reveal(.heading, at: last + 0.06, on: .reply)
        reveal(.lead, at: last + 0.2, on: .reply)
        reveal(.after, at: last + 0.5, on: .reply, animation: .linear(duration: 0.28))
        reveal(.skipGone, at: last + 0.6, on: .reply, animation: .linear(duration: 0.16))
        reveal(.action, at: last + 1.6, on: .reply)
        reveal(.note, at: last + 2.0, on: .reply, animation: SetupMotion.quadInOut(0.28))
    }

    private func reveal(_ beat: Beat, at seconds: Double, on page: SetupPage, animation: Animation? = nil) {
        after(seconds, on: page) {
            animate(animation) { _ = beats.insert(beat) }
        }
    }

    // MARK: - The end

    /// Setup is done. The light gathers in the sun as the paper cools, then
    /// the window lifts the sun out and closes. A page reopened after setup,
    /// as mail is from Settings, closes with no flight.
    private func finish() {
        guard !sunLifted else { return }
        let on = page ?? .openAtLogin
        guard on >= .reply else { return end(nil) }
        after(0.05, on: on) {
            animate(.linear(duration: 0.2)) {
                light.warm = 0
                sheetLight = 0
                rim = 0
                light.glow = 1.12
            }
        }
        after(instant ? 0 : 0.25, on: on) {
            sunLifted = !reduceMotion
            end(SetupPainting.sunFrame(light))
        }
    }
}

/// The moments of a page's payoff, which come one after another once its
/// words have landed.
enum Beat: CaseIterable {
    /// The heading rewrites; the lead changes; "or click the dot" or
    /// "You said" shows; the quiet link goes; the action arrives; and on an
    /// email page that ends setup, the Screen Recording note takes the key
    /// row's place.
    case heading, lead, after, skipGone, action, note
}

extension FirstDictation.Moment {
    fileprivate var isHeard: Bool {
        if case .heard = self { true } else { false }
    }
}

/// What every part of a page reads.
@MainActor
private struct PageContext {
    let model: OnboardingModel
    let beats: Set<Beat>
    let sheetLight: Double
    let rim: Double
    /// Whether this page is the one the window opened on, which arrives on
    /// the window's own time.
    let opening: Bool

    var key: String { model.dictation?.keyName() ?? "fn" }
}

private enum PagePart {
    case head, sheet, actions
}

private struct PageView: View {
    let page: SetupPage
    let part: PagePart
    let context: PageContext

    var body: some View {
        switch page {
        case .signIn: SignInPage(part: part, context: context)
        case .permissions: PermissionsPage(part: part, context: context)
        case .shortcut: ShortcutPage(part: part, context: context)
        case .tryIt: TryItPage(part: part, context: context)
        case .mail: MailPage(part: part, context: context)
        case .reply: ReplyPage(part: part, context: context)
        case .openAtLogin: OpenAtLoginPage(part: part, context: context)
        }
    }
}

// MARK: - The frame every page shares

/// A page's heading on the sky, 36 from the window's sides and 106 from its
/// top, and its lead 14 under it.
private struct Head: View {
    let title: String
    let lead: String
    let context: PageContext

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SetupHeading(title: title, delay: 0.45)
            SetupLead(text: lead, delay: context.opening ? 0.9 : 0.75)
        }
        .padding(.horizontal, 36)
        .frame(width: OnboardingView.size.width, alignment: .leading)
        .offset(y: 106)
    }
}

/// The line under a heading: DM Sans 15/22 in the ink at 76%, two lines at
/// most. A new one fades the old out in 0.12 s and comes in over 0.2 s.
private struct SetupLead: View {
    let text: String
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: String?
    @State private var opacity: Double = 0

    var body: some View {
        Text(shown ?? text)
            .font(SetupStyle.text(15))
            .lineSpacing(3)
            .foregroundStyle(SetupStyle.lead)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 452, minHeight: 44, alignment: .topLeading)
            .opacity(opacity)
            .onAppear {
                shown = text
                if SetupMotion.isStill { opacity = 1 } else { withAnimation(.linear(duration: 0.28).delay(delay)) { opacity = 1 } }
            }
            .onChange(of: text) { _, next in
                guard !SetupMotion.isStill else { return shown = next }
                withAnimation(.linear(duration: 0.12)) { opacity = 0 }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(120))
                    shown = next
                    withAnimation(.linear(duration: 0.2)) { opacity = 1 }
                }
            }
    }
}

/// The paper a page's content lies on: 28 from the window's sides and 352
/// from its top, radius 14, a half-point edge and no shadow. It grows from
/// the page's own height to fit what it holds. When the sun's light
/// reaches it, it takes the light from the right or from above, and its top
/// edge catches the light last.
private struct Sheet<Content: View, Below: View>: View {
    let height: CGFloat
    var lightFrom: Edge = .top
    let context: PageContext
    /// When the content arrives: with the sheet as the window opens, or
    /// just after it as a page turns.
    @ViewBuilder let content: Content
    /// A second sheet 12 under the first, on the pages that have one.
    @ViewBuilder let below: Below
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(spacing: 12) {
            content
                .padding(.vertical, 20)
                .padding(.horizontal, 22)
                .opacity(arrived ? 1 : 0)
                .offset(y: arrived || reduceMotion ? 0 : (context.opening ? 8 : 6))
                .frame(width: OnboardingView.size.width - 56, alignment: .topLeading)
                .frame(minHeight: height, alignment: .topLeading)
                .background(SetupStyle.paper, in: shape)
                .overlay { SheetLight(from: lightFrom, amount: context.sheetLight).clipShape(shape) }
                .overlay(alignment: .top) { SheetRim().opacity(context.rim).padding(.horizontal, 10) }
                .overlay(shape.strokeBorder(SetupStyle.edge, lineWidth: 0.5))
                .animation(SetupMotion.isStill ? nil : SetupMotion.quadInOut(0.28), value: height)
            below
        }
        .offset(x: 28, y: 352)
        .onAppear {
            guard !SetupMotion.isStill else { return arrived = true }
            let animation = context.opening ? SetupMotion.cubicOut(0.28).delay(0.35) : SetupMotion.cubicOut(0.35).delay(0.6)
            withAnimation(animation) { arrived = true }
        }
    }
}

extension Sheet where Below == EmptyView {
    init(height: CGFloat, lightFrom: Edge = .top, context: PageContext, @ViewBuilder content: () -> Content) {
        self.init(height: height, lightFrom: lightFrom, context: context, content: content, below: { EmptyView() })
    }
}

/// The sun's light on the paper: a warm multiply from its edge.
private struct SheetLight: View {
    let from: Edge
    let amount: Double

    var body: some View {
        let warm = Color(.sRGB, red: 250 / 255, green: 210 / 255, blue: 174 / 255)
        Group {
            if from == .trailing {
                LinearGradient(stops: [.init(color: warm.opacity(0.55), location: 0), .init(color: warm.opacity(0), location: 0.45)],
                               startPoint: .trailing, endPoint: .leading)
            } else {
                LinearGradient(stops: [.init(color: warm.opacity(0.6), location: 0), .init(color: warm.opacity(0.12), location: 0.4),
                                       .init(color: warm.opacity(0), location: 0.7)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .blendMode(.multiply)
        .opacity(amount)
        .allowsHitTesting(false)
    }
}

/// The last catch of light on the paper's top edge: a 2-point warm line.
private struct SheetRim: View {
    var body: some View {
        LinearGradient(stops: [.init(color: Color(.sRGB, red: 246 / 255, green: 168 / 255, blue: 112 / 255, opacity: 0), location: 0),
                               .init(color: Color(.sRGB, red: 246 / 255, green: 168 / 255, blue: 112 / 255, opacity: 0.95), location: 0.3),
                               .init(color: Color(.sRGB, red: 252 / 255, green: 206 / 255, blue: 160 / 255), location: 0.5),
                               .init(color: Color(.sRGB, red: 246 / 255, green: 168 / 255, blue: 112 / 255, opacity: 0.95), location: 0.7),
                               .init(color: Color(.sRGB, red: 246 / 255, green: 168 / 255, blue: 112 / 255, opacity: 0), location: 1)],
                       startPoint: .leading, endPoint: .trailing)
            .frame(height: 2)
            .clipShape(Capsule())
            .allowsHitTesting(false)
    }
}

/// The actions on the desk the meadow softens into: a quiet link on the
/// left, the one Ink action on the right, 56 tall and 18 above the foot.
private struct Actions<Quiet: View, Main: View>: View {
    @ViewBuilder let quiet: Quiet
    @ViewBuilder let main: Main

    var body: some View {
        HStack(spacing: 12) {
            quiet
            Spacer(minLength: 0)
            main
        }
        .frame(height: 56)
        .padding(.leading, 36)
        .padding(.trailing, 30)
        .frame(width: OnboardingView.size.width)
        .offset(y: OnboardingView.size.height - 18 - 56)
    }
}

/// A label on the sheet: DM Sans 600 13.
private struct Label13: View {
    let text: String

    var body: some View {
        Text(text).font(SetupStyle.text(13, .semibold)).foregroundStyle(SetupStyle.ink)
    }
}

/// A hint under a label: 13/18 in the ink at 64%.
private struct Hint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(SetupStyle.text(13))
            .lineSpacing(2)
            .foregroundStyle(SetupStyle.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The hairline between rows.
private struct Hairline: View {
    var body: some View {
        SetupStyle.rule.frame(height: 0.5)
    }
}

// MARK: - Sign in

private struct SignInPage: View {
    let part: PagePart
    let context: PageContext
    @FocusState private var focused: Bool

    var body: some View {
        let model = context.model
        switch part {
        case .head:
            Head(title: OnboardingModel.greeting(hour: Calendar.current.component(.hour, from: Date()), fullName: model.fullName),
                 lead: "A couple of minutes, and you’ll have dictated your first words.", context: context)
        case .sheet:
            Sheet(height: 186, context: context) {
                VStack(alignment: .leading, spacing: 0) {
                    Label13(text: "Your invite code").padding(.top, 6)
                    CodeCells(digits: model.digits, isAccepted: model.isSignedIn, isRefused: model.signInProblem == .invalidCode,
                              isFocused: focused)
                        // The real field lies over the cells, unseen: it takes
                        // the typing, Command-V and a click anywhere on them.
                        .overlay {
                            TextField("", text: Binding(get: { model.digits }, set: { model.enter($0) }))
                                .accessibilityLabel("Invite code")
                                .textFieldStyle(.plain)
                                .foregroundStyle(.clear)
                                .tint(.clear)
                                .autocorrectionDisabled()
                                .focused($focused)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                        }
                        .padding(.top, 12)
                    Group {
                        if let problem = model.signInProblem {
                            ProblemLine(text: Self.message(problem))
                        } else if model.isSignedIn {
                            // Said outright, with a check, so the moment cannot
                            // be read as anything but accepted.
                            DoneLine(text: "You’re in", delay: 0.38)
                                .transition(.opacity.animation(.linear(duration: 0.16).delay(0.35)))
                        } else {
                            Hint(text: "Type the six digits, or paste your invite link.")
                                .transition(.opacity.animation(.linear(duration: 0.12)))
                        }
                    }
                    .padding(.top, 12)
                }
            }
            // The cells take the keyboard as soon as the window does, so the
            // first thing the person does can be to type or Command-V.
            .defaultFocus($focused, true)
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in focused = true }
            .onChange(of: model.isSignedIn) { _, isIn in
                if isIn { SetupSound.accepted.play() }
            }
            .task {
                try? await Task.sleep(for: .milliseconds(150))
                focused = true
            }
        case .actions:
            Actions {
                EmptyView()
            } main: {
                if model.canRetry {
                    Button("Try Again") { Task { await model.signIn() } }
                        .buttonStyle(InkActionStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    static func message(_ problem: OnboardingModel.SignInProblem) -> String {
        switch problem {
        case .invalidCode: "That code didn't work. A code works once and then expires, so ask whoever invited you for a new one."
        case .tooManyTries: "Too many tries. Wait ten minutes, then enter your code again."
        case .paused: "Intention has paused sign-in for now. Try your code again in a few hours."
        case .unreachable: "Intention couldn't reach its server. Check your connection, then enter the code again."
        case .server: "Intention's server had a problem. Try the code again in a minute."
        case .notSaved: "You're signed in, but Intention couldn't save that to your keychain."
        case .notConfigured: "This build of Intention has no server to sign in to."
        case .signedOut: "This Mac was signed out. Enter a new invite code to sign in again."
        }
    }
}

/// Six wells for the six digits, 56 by 64 and 10 apart, each with a firm
/// edge so an empty one reads as a place to type. Each digit drops into its
/// cell as it is typed, the cell to fill next has a full-ink edge and the
/// caret with Intention's dot while the code has the keyboard, and the cells
/// turn to ink one by one when the code is accepted.
private struct CodeCells: View {
    let digits: String
    let isAccepted: Bool
    let isRefused: Bool
    let isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let entered = Array(digits)
        HStack(spacing: 10) {
            ForEach(0..<OnboardingModel.codeLength, id: \.self) { index in
                // Stills have no keyboard; they draw the cell as it is when
                // the window has one, as the practice fields do.
                let isNext = index == entered.count && !isAccepted && (isFocused || FirstDictationField.still)
                let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
                ZStack {
                    shape.fill(isAccepted ? SetupStyle.ink : SetupStyle.well)
                    shape.strokeBorder(isRefused ? SetupStyle.alert : isNext ? SetupStyle.ink : SetupStyle.controlEdge,
                                       lineWidth: isNext || isRefused ? 1 : 0.5)
                    if isNext {
                        CaretMark().padding(.top, 10)
                    }
                    if index < entered.count {
                        Text(String(entered[index]))
                            .font(SetupStyle.text(28, .semibold))
                            .foregroundStyle(isAccepted ? SetupStyle.paper : SetupStyle.ink)
                            .transition(reduceMotion ? .opacity : .offset(y: -5).combined(with: .opacity))
                    }
                }
                .frame(width: 56, height: 64)
                .animation(SetupMotion.isStill ? nil : SetupMotion.cubicOut(0.14), value: entered.count)
                .animation(SetupMotion.isStill ? nil : SetupMotion.quadOut(0.16).delay(Double(index) * 0.05), value: isAccepted)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Invite code, \(entered.count) of \(OnboardingModel.codeLength) digits entered")
    }
}

/// A text caret with Intention's dot above it, the mark's own "i", in the
/// invite code's next cell: the caret 1.6 by 20, the dot's top 15 above the
/// caret's.
private struct CaretMark: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 0.8)
            .fill(SetupStyle.ink)
            .frame(width: 1.6, height: 20)
            .overlay(alignment: .top) {
                RestingDot(diameter: 10)
                    .offset(x: 0.8, y: -15)
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Permissions

private struct PermissionsPage: View {
    let part: PagePart
    let context: PageContext

    var body: some View {
        let model = context.model
        switch part {
        case .head:
            let inSettings = model.currentAsk == .accessibility && model.asked.contains(.accessibility)
            Head(title: "Two permissions",
                 lead: inSettings ? "Now turn Intention on in the list macOS just opened. This page moves on by itself."
                    : "Click Allow, then turn Intention on in the list macOS opens.", context: context)
        case .sheet:
            Sheet(height: 196, context: context) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(SetupPermission.allCases, id: \.self) { permission in
                        if permission != SetupPermission.allCases.first { Hairline() }
                        row(permission)
                            .padding(.top, permission == SetupPermission.allCases.first ? 6 : 16)
                            .padding(.bottom, permission == SetupPermission.allCases.last ? 0 : 16)
                    }
                }
            }
        case .actions:
            // The page has no action of its own: each row asks, and the page
            // moves on by itself once both are in.
            EmptyView()
        }
    }

    private func row(_ permission: SetupPermission) -> some View {
        let model = context.model
        let granted = model.granted.contains(permission)
        let asked = model.asked.contains(permission)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Label13(text: Self.name(permission))
                    Hint(text: Self.reason(permission, asked: asked && !granted))
                        .frame(maxWidth: 290, alignment: .leading)
                }
                Spacer(minLength: 0)
                ZStack(alignment: .trailing) {
                    if granted {
                        DoneLine(text: "Allowed", delay: 0.02)
                            .transition(.opacity.animation(.linear(duration: 0.12).delay(0.12)))
                    } else {
                        // The microphone is asked with one click; once macOS
                        // has been asked, the row offers the way back to its
                        // list. One press carries through both, as on main:
                        // the model asks for the next grant by itself.
                        let action = permission == .microphone && !asked ? "Allow" : "Open Settings"
                        // Asked in the model's order: a row waits, drawn
                        // but inactive, until the one before it is in.
                        let button = Button(action) { model.allow(permission) }
                            .buttonStyle(SeatButtonStyle())
                            .disabled(permission != model.currentAsk && !asked)
                            .accessibilityLabel(action == "Allow" ? "Allow \(Self.name(permission))" : "Open Settings for \(Self.name(permission))")
                            .transition(.opacity.animation(.linear(duration: 0.12)))
                        if permission == model.currentAsk, !asked {
                            button.keyboardShortcut(.defaultAction)
                        } else {
                            button
                        }
                    }
                }
                .frame(minWidth: 120, minHeight: 34, alignment: .trailing)
            }
            if !granted, asked, permission == .accessibility {
                SettingsHint()
            }
        }
    }

    static func name(_ permission: SetupPermission) -> String {
        switch permission {
        case .microphone: "Microphone"
        // macOS 27 renamed the list; the row uses the name the person
        // will see at the top of the page that opens.
        case .accessibility: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? "Device Control" : "Accessibility"
        }
    }

    /// One line each, saying what the grant is for and where it stops,
    /// and once macOS has been asked, what to do in its list.
    static func reason(_ permission: SetupPermission, asked: Bool) -> String {
        switch permission {
        case .microphone: "Hears you only while you hold the key."
        case .accessibility: asked ? "Find this line in the list and switch it on." : "Finds your cursor and types there. Never in a password field."
        }
    }
}

// MARK: - Shortcut

/// The keys to hold to talk: fn, which most people use, or any keys the
/// person records with Settings' own recorder, saved where Settings saves
/// them. The sheet shows the shortcut chosen, whose caps go down while it is
/// held, so the person sees Intention hears it before the first dictation, and
/// under it the two ways to change it. A keyboard with no fn, as most not
/// made by Apple, leads with recording.
private struct ShortcutPage: View {
    let part: PagePart
    let context: PageContext

    var body: some View {
        let model = context.model
        switch part {
        case .head:
            Head(title: "Choose your shortcut",
                 lead: model.leadsWithRecording ? "Your keyboard doesn't seem to have fn. Record the keys you'd like to hold to talk."
                    : "The keys you hold to talk, in any app. fn is the one most people use.", context: context)
        case .sheet:
            Sheet(height: 160, context: context) {
                VStack(alignment: .leading, spacing: 0) {
                    chosen.padding(.top, 6).padding(.bottom, 16)
                    Hairline()
                    choices.padding(.top, 16)
                }
            }
        case .actions:
            Actions {
                EmptyView()
            } main: {
                Button("Continue") { model.continueFromShortcut() }
                    .buttonStyle(InkActionStyle(delay: 0.65))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// The shortcut chosen, or while the recorder listens, the keys held so
    /// far, and what to do.
    private var chosen: some View {
        let model = context.model
        let recording = model.shortcutRecording
        let held = model.shortcutHeld && !recording.isRecording
        // Without fn on the keyboard, fn is only what is set until keys are
        // recorded, not a choice the page claims was made.
        let unconfirmed = model.holdsFn && model.leadsWithRecording
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                Group {
                    if recording.isRecording {
                        if let shown = recording.shown {
                            SetupKeycaps(name: shown, isDown: true)
                        } else {
                            SetupKeycap(label: "\u{2026}").opacity(0.5)
                        }
                    } else {
                        SetupKeycaps(name: context.key, isDown: held)
                    }
                }
                .frame(minWidth: 52, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Label13(text: recording.isRecording ? "Press the keys you want, then let go"
                        : unconfirmed ? "fn, until you record a shortcut" : model.holdsFn ? "fn, recommended" : "Your own shortcut")
                    Hint(text: recording.isRecording ? "Esc cancels." : held ? "Intention hears it."
                        : unconfirmed ? "If your keyboard has fn, hold it now to try it." : "Hold it now to try it.")
                }
                Spacer(minLength: 0)
                if !recording.isRecording, !unconfirmed {
                    DoneLine(text: "Chosen", delay: 0.02)
                }
            }
            if let problem = model.shortcutProblemMessage {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    ProblemLine(text: problem)
                    Button("Retry") { model.retryShortcut() }
                        .buttonStyle(QuietLinkStyle())
                        .fixedSize()
                        .layoutPriority(1)
                }
                .transition(.opacity.animation(.linear(duration: 0.12)))
            }
        }
    }

    /// The two ways to change it: fn, and recording any keys with the
    /// recorder Settings uses. Recording comes first where there is no fn.
    private var choices: some View {
        let model = context.model
        let recording = model.shortcutRecording.isRecording
        let record = Button(recording ? "Cancel" : model.holdsFn ? "Record a shortcut" : "Record another") { model.recordShortcut() }
            .buttonStyle(SeatButtonStyle())
            .accessibilityHint(recording ? "Stops listening for keys" : "Then press the keys to hold for dictation")
        return HStack(spacing: 12) {
            // fn is offered once something else is chosen.
            if !model.holdsFn {
                Button("Use fn") { model.useFn() }
                    .buttonStyle(SeatButtonStyle())
            }
            record
            Spacer(minLength: 0)
            Text("One key like right option, or two together.")
                .font(SetupStyle.text(12))
                .foregroundStyle(SetupStyle.secondary)
                .lineLimit(2)
                .frame(maxWidth: 170, alignment: .trailing)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// What the person is looking for in System Settings: Intention's line with
/// its switch on, drawn as macOS draws it so they recognise it when the
/// list opens.
struct SettingsHint: View {
    var width: CGFloat = 232
    var height: CGFloat = 36

    var body: some View {
        HStack(spacing: 9) {
            Image(nsImage: SetupStyle.image("AppIcon", "icns"))
                .resizable()
                .frame(width: 22, height: 22)
            Text("Intention").font(SetupStyle.text(13))
            Spacer()
            Capsule()
                .fill(Color(red: 0.20, green: 0.48, blue: 0.96))
                .frame(width: 32, height: 19)
                .overlay(alignment: .trailing) {
                    Circle().fill(.white).frame(width: 15, height: 15).padding(2)
                }
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: height)
        .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SetupStyle.hairline))
        .accessibilityHidden(true)
    }
}

// MARK: - First dictation

private struct TryItPage: View {
    let part: PagePart
    let context: PageContext

    var body: some View {
        let model = context.model
        let moment = model.firstDictation
        let key = context.key
        // Until the words have landed, the page still reads as it did
        // while Intention wrote them down.
        let landed = !moment.isHeard || context.beats.contains(.heading)
        let led = !moment.isHeard || context.beats.contains(.lead)
        switch part {
        case .head:
            Head(title: landed ? Self.title(moment, key: key) : "Hold \(key) and talk",
                 lead: led ? lead(moment, key: key) : "Writing it down.", context: context)
        case .sheet:
            Sheet(height: 196, lightFrom: .trailing, context: context) {
                Practice(words: model.firstDictationFieldWords, moment: moment, isWorking: moment == .finishing,
                         placeholder: moment == .waiting ? "Try \u{201C}Running ten minutes late, save me a seat.\u{201D}" : nil,
                         minHeight: 104, key: model.dictation?.keyName(),
                         keyLabel: model.firstKeyCheck == .works || model.firstKeyCheck == .waiting
                            ? model.firstKeyMessage ?? "" : Self.keyLabel(moment, settled: led),
                         change: moment == .waiting ? { model.changeShortcut() } : nil,
                         dotClicked: nil, showsDot: false,
                         submit: Self.continuesOnReturn(moment) ? { model.continueFromDictation() } : nil,
                         inserted: model.firstDictationInserted,
                         problem: model.firstKeyFailed ? model.firstKeyMessage : model.firstDictationProblem,
                         keyWorks: model.firstKeyCheck == .works,
                         retry: model.firstKeyFailed ? model.retryFirstKey : model.retryFirstDictation) {
                    // The plain field has no caret dot, as a plain field
                    // in any app has none; the page's own mark is the dot to
                    // click, there from the first words heard and while the
                    // dictation it starts runs, so it can be clicked again
                    // to stop, and out of the way before, while the key is
                    // checked and the first words are awaited.
                    if context.beats.contains(.after), moment.isHeard || moment == .listening || moment == .finishing {
                        let toggle = model.dictation?.isAvailable() == true ? { model.toggleDictation() } : nil
                        Button { toggle?() } label: {
                            HStack(spacing: 8) {
                                RestingDot(diameter: 10)
                                Text("or click the dot").font(SetupStyle.text(13)).foregroundStyle(SetupStyle.secondary)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(toggle == nil)
                        .accessibilityLabel("Intention's dot: start or stop dictating")
                        .transition(.opacity)
                    }
                }
            } below: {
                // Asked where it is used, just before the first dictation,
                // and out of the way once the person is speaking, or while
                // the page says what went wrong.
                if model.asksLanguages, moment == .waiting && !model.firstKeyFailed && model.firstDictationProblem == nil
                    || moment == .unavailable {
                    LanguagesSheet(model: model)
                        .transition(.opacity.animation(.linear(duration: 0.16)))
                }
            }
        case .actions:
            Actions {
                if moment == .waiting || model.firstKeyCheck != nil && model.firstKeyCheck != .works {
                    Button("Skip for now") { model.continueFromDictation() }
                        .buttonStyle(QuietLinkStyle())
                        .transition(.opacity.animation(.linear(duration: 0.16)))
                }
            } main: {
                if moment == .unavailable || (moment.isHeard && context.beats.contains(.action)) {
                    Button("Continue") { model.continueFromDictation() }
                        .buttonStyle(InkActionStyle(delay: context.beats.contains(.action) && moment.isHeard ? 0 : 0.65))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    /// What the key row says beside the keycap: nothing while listening,
    /// since the held key and the sun at the foot say it.
    static func keyLabel(_ moment: FirstDictation.Moment, settled: Bool) -> String {
        switch moment {
        case .listening: ""
        case .finishing: "Writing it down."
        case .heard: settled ? "Hold to talk" : "Writing it down."
        case .waiting, .unavailable: "Hold to talk"
        }
    }

    /// Return moves on where Continue is the page's button.
    static func continuesOnReturn(_ moment: FirstDictation.Moment) -> Bool {
        switch moment {
        case .heard, .unavailable: true
        case .waiting, .listening, .finishing: false
        }
    }

    static func title(_ moment: FirstDictation.Moment, key: String) -> String {
        switch moment {
        case .unavailable: "Hold \(key) and talk"
        case .waiting, .listening, .finishing: "Hold \(key) and talk"
        case .heard: "That’s dictation"
        }
    }

    private func lead(_ moment: FirstDictation.Moment, key: String) -> String {
        switch moment {
        case .unavailable: return "Click into any text field, hold \(key) and talk, and your words land at your cursor."
        // What went wrong is said under the field, beside Retry.
        case .waiting: return "Say anything. Let go when you’re done."
        case .listening: return "Let go of \(key) when you’re done."
        case .finishing: return "Writing it down."
        case .heard: return "Every app, wherever your cursor is. Now try the dot: click it to start, click again to stop."
        }
    }
}

/// The languages a person dictates in, on a second sheet 12 under the
/// dictation's, of the same paper.
private struct LanguagesSheet: View {
    let model: OnboardingModel

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 9) {
            Label13(text: "Which languages do you dictate in?")
            DictationLanguagePicker(
                chosen: model.chosenLanguages,
                shown: LanguageChoice.shown(preferred: model.preferredLanguages, chosen: model.chosenLanguages),
                offered: LanguageChoice.offered(preferred: model.preferredLanguages, chosen: model.chosenLanguages),
                toggle: model.toggleLanguage
            )
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .frame(width: OnboardingView.size.width - 56, alignment: .leading)
        .background(SetupStyle.paper, in: shape)
        .overlay(shape.strokeBorder(SetupStyle.edge, lineWidth: 0.5))
    }
}

/// The sheet as a page being written on: a real text field with Intention's
/// dot above its caret, a line to try while it is empty, the person's own
/// words put where the caret is, and under them the key to hold and
/// whatever the page adds beside it.
private struct Practice<Beside: View>: View {
    /// The newest words for the field, and when they arrived.
    let words: (text: String, at: Date)?
    let moment: FirstDictation.Moment
    /// While Intention writes the words down or writes the email: the caret
    /// dot breathes.
    let isWorking: Bool
    let placeholder: String?
    let minHeight: CGFloat
    var mostLines: CGFloat = 4
    /// The key to hold, shown as a keycap that goes down while it is held;
    /// nil hides the key row.
    let key: String?
    let keyLabel: String
    /// Goes back to choose another shortcut; nil hides the offer.
    let change: (() -> Void)?
    let dotClicked: (() -> Void)?
    /// Whether the field shows a dot above its caret: only the practice
    /// reply's, which is an email.
    var showsDot = true
    /// Ends the page, where the page's main button would.
    let submit: (() -> Void)?
    var inserted: ((String, Date) -> Void)? = nil
    /// What went wrong with the key or the last try, said exactly, with
    /// Retry beside it.
    var problem: String? = nil
    var keyWorks = false
    var retry: (() -> Void)? = nil
    @ViewBuilder let beside: Beside

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PracticeField(words: words, moment: moment, isWorking: isWorking, placeholder: placeholder, minHeight: minHeight,
                          mostLines: mostLines, dotClicked: dotClicked, submit: submit, inserted: inserted, showsDot: showsDot)
            if let key {
                HStack(spacing: 12) {
                    SetupKeycaps(name: key, isDown: moment == .listening)
                    HStack(spacing: 7) {
                        if keyWorks { DrawnCheck() }
                        KeyLabel(text: keyLabel)
                    }
                    Spacer(minLength: 8)
                    if let change {
                        // The key is the person's to choose: another app
                        // may already use this one.
                        Button("Change shortcut", action: change)
                            .buttonStyle(SeatButtonStyle())
                            .fixedSize()
                    }
                    beside
                }
                .padding(.top, 16)
            }
            if let problem {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        AttentionMark()
                        Text(problem)
                            .font(SetupStyle.text(12))
                            .foregroundStyle(SetupStyle.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let retry {
                        Button("Retry", action: retry).buttonStyle(QuietLinkStyle())
                            .fixedSize()
                            .layoutPriority(1)
                    }
                }
                .padding(.top, 10)
            }
        }
        .onChange(of: moment) { before, now in
            guard case .heard = now, before != now else { return }
            SetupSound.landed.play()
        }
    }
}

/// What the key row says beside the keycap. Going quiet takes 0.1 s; a new
/// line fades the old out in 0.12 s and comes in over 0.2 s.
private struct KeyLabel: View {
    let text: String
    @State private var shown: String?
    @State private var opacity: Double = 1

    var body: some View {
        Text(shown ?? text)
            .font(SetupStyle.text(13, .semibold))
            .foregroundStyle(SetupStyle.lead)
            .lineLimit(1)
            .opacity((shown ?? text).isEmpty ? 0 : opacity)
            .onAppear { shown = text }
            .onChange(of: text) { _, next in
                guard !SetupMotion.isStill else { return shown = next }
                withAnimation(.linear(duration: next.isEmpty ? 0.1 : 0.12)) { opacity = 0 }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(next.isEmpty ? 100 : 120))
                    shown = next
                    withAnimation(.linear(duration: 0.2)) { opacity = 1 }
                }
            }
    }
}

/// The field the person speaks into: a well with a half-point edge in the
/// ink at 55%, padded 14 by 16.
private struct PracticeField: View {
    let words: (text: String, at: Date)?
    let moment: FirstDictation.Moment
    let isWorking: Bool
    let placeholder: String?
    let minHeight: CGFloat
    let mostLines: CGFloat
    let dotClicked: (() -> Void)?
    let submit: (() -> Void)?
    let inserted: ((String, Date) -> Void)?
    let showsDot: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        // The field's own view keeps room above its first line for the
        // dot, which stands 15 above the caret's top.
        FirstDictationField(words: words, isListening: moment == .listening, isWorking: isWorking, placeholder: placeholder,
                            submit: submit, mostLines: mostLines, inserted: inserted, dotClicked: dotClicked, showsDot: showsDot)
            .padding(.top, 14 - FirstDictationField.headroom)
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .background(SetupStyle.field, in: shape)
            .overlay {
                // A faint inner shadow along the top, as a well has.
                shape.strokeBorder(SetupStyle.ink.opacity(0.05), lineWidth: 2).blur(radius: 1).clipShape(shape)
            }
            .overlay(shape.strokeBorder(SetupStyle.fieldEdge, lineWidth: 0.5))
    }
}

/// The key to hold as its cap, or a pair of keys as two caps with a plus
/// between them, as "control + option" names them. Both go down together.
private struct SetupKeycaps: View {
    let name: String
    let isDown: Bool

    var body: some View {
        let caps = name.components(separatedBy: " + ")
        HStack(spacing: 5) {
            ForEach(Array(caps.enumerated()), id: \.offset) { index, cap in
                if index > 0 {
                    Text("+")
                        .font(SetupStyle.text(12.5, .semibold))
                        .foregroundStyle(SetupStyle.secondary)
                        .accessibilityHidden(true)
                }
                SetupKeycap(label: cap, isDown: isDown)
            }
        }
    }
}

// MARK: - Mail

private struct MailPage: View {
    let part: PagePart
    let context: PageContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let model = context.model
        switch part {
        case .head:
            Head(title: title, lead: lead, context: context)
        case .sheet:
            Sheet(height: height, context: context) {
                VStack(alignment: .leading, spacing: 0) {
                    if !model.availableConnections.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(model.availableConnections) { connection in
                                Mailbox(connection: connection)
                            }
                        }
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: reduceMotion ? 0 : 6))
                                                    .animation(SetupMotion.cubicOut(0.28).delay(0.08)),
                                                removal: .opacity))
                        // A provider still to connect, or one to connect
                        // again, keeps its row beside the mailbox.
                        if model.hasReadMail, model.isMailOffered, !offered.isEmpty {
                            offer.padding(.top, 14)
                        }
                        // The counts above are from the last read that worked.
                        if model.mailReadFailed {
                            HStack(alignment: .firstTextBaseline, spacing: 14) {
                                ProblemLine(text: "Couldn't check your mail just now. Trying again.")
                                Spacer(minLength: 8)
                                if !showsConnect {
                                    Button("Retry") { Task { await model.refreshMail() } }
                                        .buttonStyle(QuietLinkStyle())
                                        .fixedSize()
                                }
                            }
                            .padding(.top, 10)
                        }
                    } else if !model.hasReadMail {
                        Text(model.mailReadFailed ? "Couldn't check just now. Trying again…" : "Checking…")
                            .font(SetupStyle.text(14))
                            .foregroundStyle(SetupStyle.lead)
                    } else if gmailClosed {
                        // New Gmail sign-ins are closed: no promise about
                        // mail, and Outlook still connects where it can.
                        // Alone, the line stands on the card's centre line.
                        Text("Dictation works now.")
                            .font(SetupStyle.text(14))
                            .foregroundStyle(SetupStyle.lead)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 320, minHeight: closedAlone ? 72 : nil, alignment: .leading)
                        if !offered.isEmpty { offer.padding(.top, 10) }
                    } else if model.isMailOffered {
                        offer.transition(.opacity.animation(.linear(duration: 0.16)))
                    } else {
                        Text("Mailbox setup is unavailable in this demo. Continue to try dictation.")
                            .font(SetupStyle.text(14))
                            .foregroundStyle(SetupStyle.lead)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 320, alignment: .leading)
                    }
                    if let problem = model.mailProblem {
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            ProblemLine(text: Self.message(problem))
                            Spacer(minLength: 8)
                            if model.retryMailProvider != nil, !showsConnect {
                                Button("Retry") { Task { await model.retryMail() } }
                                    .buttonStyle(QuietLinkStyle())
                                    .fixedSize()
                                    .disabled(model.isConnecting)
                            }
                        }
                        .padding(.top, 10)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .overlay(alignment: closedAlone ? .trailing : .topTrailing) {
                    // The envelope's ink runs 10 to 82 down its 96 point
                    // drawing, so 10 up puts its middle on a lone offer's
                    // centre line; centred beside the closed line, its body
                    // sits 2 above the frame's centre.
                    MailSpot().offset(x: 6, y: closedAlone ? 2 : isLoneOffer ? -10 : -6)
                }
                .animation(SetupStyle.quick, value: model.awaiting)
            }
        case .actions:
            // Without a mailbox, a browser left open or a sign-in that failed
            // can always be left for dictation alone, which closes the
            // browser's sign-in.
            let recovering = model.availableConnections.isEmpty && (model.awaiting != nil || model.retryMailProvider != nil)
            Actions {
                if recovering {
                    Button("Continue with dictation") { model.continueWithDictationOnly() }
                        .buttonStyle(QuietLinkStyle())
                        .transition(.opacity.animation(.linear(duration: 0.16)))
                } else if model.availableConnections.isEmpty, model.isMailOffered, !gmailClosed {
                    Button("Not now") { model.continueFromMail() }
                        .buttonStyle(QuietLinkStyle())
                        .transition(.opacity.animation(.linear(duration: 0.16)))
                }
            } main: {
                if recovering {
                    EmptyView()
                } else if gmailClosed {
                    Button("Continue") { model.continueWithDictationOnly() }
                        .buttonStyle(InkActionStyle(delay: 0.3))
                        .keyboardShortcut(.defaultAction)
                } else if !(model.availableConnections.isEmpty && model.isMailOffered) {
                    Button("Continue") { model.continueFromMail() }
                        .buttonStyle(InkActionStyle(delay: 0.3))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var height: CGFloat { context.model.mailPageHeight }
    private var offered: [AlphaClient.MailProvider] { context.model.offeredMailProviders }

    /// Gmail closed with no other provider to connect: one line, no rows,
    /// on the 112 paper beside the envelope.
    private var closedAlone: Bool { gmailClosed && offered.isEmpty }

    /// Whether the card shows a Connect, Reconnect or Connecting button. A
    /// problem beside one needs no Retry, which would be a second way to
    /// connect in another style.
    private var showsConnect: Bool {
        let model = context.model
        let showsOffer = model.availableConnections.isEmpty
            ? model.hasReadMail && (gmailClosed || model.isMailOffered)
            : model.hasReadMail && model.isMailOffered
        return showsOffer && offered.contains { provider in
            model.awaiting == provider || ![.nothing, .stuck].contains(model.mailOffer(for: provider))
        }
    }

    /// The server offers Gmail but has closed new Gmail sign-ins, and no
    /// mailbox is connected, so setup goes on with dictation alone. A server
    /// without Gmail, or a mailbox already connected, keeps the page as it was.
    private var gmailClosed: Bool {
        let model = context.model
        return model.hasReadMail && model.availableProviders.contains(.gmail) && !model.gmailConnectOpen
            && model.availableConnections.isEmpty
    }

    /// One provider to connect and nothing else on the paper, which is then
    /// 112 tall: its row and the envelope share the card's centre line.
    /// Two rows, a mailbox, the browser's steps, a problem line or the
    /// closed-Gmail line keep the rows at the top.
    private var isLoneOffer: Bool {
        let model = context.model
        return model.availableConnections.isEmpty && model.hasReadMail && model.isMailOffered && !gmailClosed
            && offered.count == 1 && model.awaiting == nil && model.mailProblem == nil
    }

    /// The providers, each a row 52 tall with its own Connect.
    private var offer: some View {
        let model = context.model
        let offered = offered
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(offered, id: \.self) { provider in
                if provider != offered.first { Hairline() }
                providerRow(provider)
                if model.awaiting == provider {
                    ClickSteps(provider: provider)
                        .transition(.opacity.animation(SetupMotion.cubicOut(0.28)))
                }
            }
        }
        .frame(width: 320, alignment: .leading)
        // 20 of paper, 10 and half the 52 row put a lone row's middle at 56.
        .padding(.top, isLoneOffer ? 10 : 4)
    }

    private var title: String {
        let model = context.model
        switch model.mailImport {
        case .notConnected, .stalled: return "Your mail"
        case .started, .checking: return "Importing"
        case .imported: return model.availableConnections.allSatisfy({ OnboardingModel.standing(of: $0) == .upToDate }) ? "Your mail" : "Importing"
        }
    }

    /// The count beside each mailbox is the progress the server reports;
    /// it has no total, so the page promises no duration. What it says follows the mailboxes' own
    /// standing: an import that is done is done, whatever the writer finds
    /// in it, and only a mailbox that needs connecting again is told to.
    private var lead: String {
        let model = context.model
        let standings = model.availableConnections.map(OnboardingModel.standing(of:))
        switch model.mailImport {
        case .notConnected where gmailClosed: return "New Gmail connections are paused for now."
        case .notConnected: return "Live mailbox setup is unavailable in this demo. Continue to try dictation."
        case .started, .imported, .checking, .stalled:
            if standings.contains(where: \.needsConnectingAgain) { return "Importing has stopped. Connect again to restart it." }
            if standings.contains(.addressChanged) { return "A mailbox's address changed, so its import stopped." }
            if standings.contains(.retrying) { return "The last import pass failed. Intention runs it again by itself." }
            if standings.allSatisfy({ $0 == .upToDate }) { return "Imported and up to date." }
            return "Sent mail first, then the rest. Carry on. Emails sound more like you as it reads."
        }
    }

    private func providerRow(_ provider: AlphaClient.MailProvider) -> some View {
        let model = context.model
        let isAwaiting = model.awaiting == provider
        let offer = model.mailOffer(for: provider)
        let action = isAwaiting ? "Connecting" : offer == .reconnect ? "Reconnect" : "Connect"
        return HStack(spacing: 9) {
            Image(nsImage: SetupStyle.image(provider == .gmail ? "MailGmail" : "MailOutlook", "pdf"))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 20)
                .accessibilityHidden(true)
            Text(Self.name(provider)).font(SetupStyle.text(15, .semibold))
            Spacer(minLength: 4)
            // A mailbox that syncs needs nothing; connecting again is offered
            // only when the server says the connection needs it.
            if offer == .nothing, !isAwaiting {
                DoneLine(text: "Connected")
            } else if offer == .stuck, !isAwaiting {
                // The mailbox above says why; nothing here can fix it.
                EmptyView()
            } else {
                Button {
                    Task { await model.connect(provider) }
                } label: {
                    HStack(spacing: 7) {
                        if isAwaiting { BreathingDot() }
                        Text(action)
                    }
                }
                .buttonStyle(SeatButtonStyle())
                .disabled((model.isConnecting && !isAwaiting) || model.disconnectingMail != nil)
                .allowsHitTesting(model.canChangeMail)
                .accessibilityLabel("\(action) \(Self.name(provider))")
            }
        }
        .frame(height: 52)
    }

    static func name(_ provider: AlphaClient.MailProvider) -> String {
        switch provider {
        case .gmail: "Gmail"
        case .outlook: "Outlook"
        }
    }

    static func message(_ problem: OnboardingModel.MailProblem) -> String {
        switch problem {
        case let .unavailable(provider): "\(name(provider)) can't be connected right now."
        case .unreachable: "Intention couldn't reach its server. Check your connection."
        case .denied: "Mail access was declined."
        case .gmailClosed: "That Google account can't be added yet. Your Gmail is unchanged."
        case .couldNotOpen: "The sign-in window couldn't open."
        case .timedOut: "Mail sign-in timed out."
        case .cancelled: "Mail sign-in was closed before it finished."
        }
    }
}

/// The mail page's drawing, top right of the sheet: an envelope in ink,
/// revealed left to right with a soft edge.
private struct MailSpot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Double = 0

    var body: some View {
        Image(nsImage: SetupStyle.image("SetupSpotMail", "webp"))
            .resizable()
            .frame(width: 96, height: 96)
            .modifier(Reveal(progress: shown))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                guard !SetupMotion.isStill else { return shown = 1 }
                withAnimation(reduceMotion ? .linear(duration: 0.42).delay(0.7) : SetupMotion.quadOut(0.42).delay(0.7)) { shown = 1 }
            }
    }

    /// Opaque up to 130% of the progress less 30%, so the edge is soft for
    /// 30% of the drawing.
    private struct Reveal: ViewModifier, Animatable {
        var progress: Double
        nonisolated var animatableData: Double {
            get { progress }
            set { progress = newValue }
        }

        func body(content: Content) -> some View {
            let end = progress * 1.3
            content.mask {
                LinearGradient(stops: [.init(color: .black, location: max(0, end - 0.3)), .init(color: .clear, location: max(0.0001, end))],
                               startPoint: UnitPoint(x: 0, y: 0.41), endPoint: UnitPoint(x: 1, y: 0.59))
            }
        }
    }
}

/// Intention's dot breathing in a button while the browser has the person.
private struct BreathingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var low = false

    var body: some View {
        Path(OwnHandMark.dot(diameter: 9).path)
            .fill(SetupStyle.ink)
            .frame(width: 9, height: 9)
            .opacity(low ? 0.3 : 1)
            .onAppear {
                guard !reduceMotion, !SetupMotion.isStill else { return }
                withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) { low = true }
            }
            .onChange(of: reduceMotion) { _, still in
                // Turned on while the browser has the person: the breath
                // stops at once; turned off, it comes back.
                if still {
                    var stop = Transaction()
                    stop.disablesAnimations = true
                    withTransaction(stop) { low = false }
                } else if !SetupMotion.isStill {
                    withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) { low = true }
                }
            }
    }
}

/// What the browser is about to show and what to click, drawn on the page
/// before the person sees it, so Google's unverified-app page reads as the
/// expected step and not a warning to back out of. The words are Google's
/// own for that page and its consent screen; Microsoft's are its sign-in
/// and its Accept button.
struct ClickSteps: View {
    let provider: AlphaClient.MailProvider

    static func steps(_ provider: AlphaClient.MailProvider) -> [(Text, Text?)] {
        let bold = { (words: String) in Text(words).fontWeight(.semibold).foregroundStyle(SetupStyle.ink) }
        switch provider {
        case .gmail: return [
            (Text("Choose your account."), nil),
            (Text("Google says it hasn’t verified Intention."),
             Text("Click \(bold("Advanced")), then \(bold("Go to Intention (unsafe)")).")),
            (Text("Tick \(bold("Select all")), then Continue."), nil),
        ]
        case .outlook: return [
            (Text("Sign in to your Microsoft account."), nil),
            (Text("Microsoft lists what Intention reads. Click \(bold("Accept"))."), nil),
        ]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Hint(text: "Finish in your browser. Three clicks:")
                .padding(.top, 2)
                .padding(.bottom, 6)
            ForEach(Array(Self.steps(provider).enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(index + 1).")
                        .frame(width: 14, alignment: .trailing)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        step.0
                        if let sub = step.1 { sub.foregroundStyle(SetupStyle.secondary) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .font(SetupStyle.text(13.5))
                .lineSpacing(3)
                .foregroundStyle(SetupStyle.lead)
                .padding(.bottom, 4)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

/// One mailbox and how far its first sync has come: the provider, the
/// address and a check, then the count in Own Hand. The server reports a
/// running count and no total, so the count is the figure and there is no
/// bar to fill. It rolls up from nothing when the mailbox arrives.
private struct Mailbox: View {
    let connection: AlphaClient.MailConnection

    var body: some View {
        let standing = OnboardingModel.standing(of: connection)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: SetupStyle.image(connection.provider == "outlook" ? "MailOutlook" : "MailGmail", "pdf"))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 22, height: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Label13(text: connection.provider == "outlook" ? "Outlook" : "Gmail")
                    Text(connection.address)
                        .font(SetupStyle.text(13))
                        .foregroundStyle(SetupStyle.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if !standing.isBroken { DrawnCheck(delay: 0.3) }
            }
            .padding(.top, 10)
            .padding(.bottom, 14)
            .overlay(alignment: .bottom) { Hairline() }
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                RollingCount(value: connection.storedMessages)
                    .font(SetupStyle.display(30))
                    .foregroundStyle(SetupStyle.ink)
                Text(Self.status(standing, stored: connection.storedMessages))
                    .font(SetupStyle.text(14))
                    .foregroundStyle(standing.isBroken ? SetupStyle.alert : SetupStyle.lead)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 26)
        }
        .frame(width: 330, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    static func status(_ standing: OnboardingModel.MailStanding, stored: Int) -> String {
        let noun = stored == 1 ? "message" : "messages"
        switch standing {
        case .checking: return "\(noun), checking stored mail"
        case .upToDate: return "\(noun), up to date"
        case .needsReconnect: return "\(noun). Needs connecting again"
        case .addressChanged: return "\(noun). Its address changed, so syncing stopped"
        case .stopped: return "\(noun). Syncing stopped. Connect again to restart it"
        case .retrying: return "\(noun). The last sync failed and will run again"
        case .syncing: return stored == 0 ? "\(noun) yet, starting with sent mail" : "\(noun) so far, sent mail first"
        }
    }
}

/// A count that rolls up to its value: from nothing over 2.6 s as it
/// arrives, and over 0.6 s to each newer count.
private struct RollingCount: View {
    let value: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Double = 0

    var body: some View {
        Rolled(number: shown)
            .onAppear {
                guard !SetupMotion.isStill, !reduceMotion else { return shown = Double(value) }
                withAnimation(SetupMotion.quadOut(2.6).delay(0.1)) { shown = Double(value) }
            }
            .onChange(of: value) { _, now in
                guard !SetupMotion.isStill, !reduceMotion else { return shown = Double(now) }
                withAnimation(SetupMotion.quadOut(0.6)) { shown = Double(now) }
            }
            .accessibilityLabel("\(value)")
    }

    private struct Rolled: View, Animatable {
        var number: Double
        nonisolated var animatableData: Double {
            get { number }
            set { number = newValue }
        }

        var body: some View {
            Text(Int(number.rounded()).formatted())
                .monospacedDigit()
        }
    }
}

// MARK: - First email

private struct ReplyPage: View {
    @State private var sheetDisplayed = false
    let part: PagePart
    let context: PageContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let model = context.model
        let moment = model.reply
        let key = context.key
        let written = moment == .written
        let landed = !written || context.beats.contains(.heading)
        let led = !written || context.beats.contains(.lead)
        // When setup ends here, the switch macOS asks for next takes the key
        // row's place once there is a way off the page; after the email it
        // waits for the payoff to finish first.
        let noted = isLast && Self.canLeave(moment) && (!written || context.beats.contains(.note))
        // The way off the page comes only once what follows setup is shown:
        // on a last page, after the note.
        let ready = !written || context.beats.contains(.action) && (!isLast || context.beats.contains(.note))
        let own = Self.ownThread(model.replySubject)
        switch part {
        case .head:
            Head(title: Self.title(landed ? moment : .waiting, own: own != nil),
                 lead: led ? lead(moment, key: key) : "Intention is writing it from what you said.", context: context)
        case .sheet:
            Sheet(height: noted ? 310 : 270, context: context) {
                VStack(alignment: .leading, spacing: 12) {
                    MessageCard(message: moment == .unavailable ? .example : Self.card(model.replySubject),
                                compact: model.replyFieldWords != nil)
                        .task {
                            // The sheet finishes its delayed fade 850 ms after mounting.
                            if !SetupMotion.isStill { try? await Task.sleep(for: .milliseconds(850)) }
                            guard !Task.isCancelled else { return }
                            sheetDisplayed = true
                            reportThreadShown(model)
                        }
                        .onChange(of: model.replySubject) { _, _ in reportThreadShown(model) }
                        .onChange(of: moment) { _, _ in reportThreadShown(model) }
                    if moment == .unavailable {
                        example
                    } else {
                        Practice(words: model.replyFieldWords, moment: Self.dictationMoment(moment),
                                 isWorking: moment == .finishing || moment == .writing,
                                 placeholder: moment == .waiting ? Self.placeholder(model.replySubject) : nil, minHeight: 96,
                                 // Three lines, or two beside the note, keep
                                 // the sheet clear of the actions.
                                 mostLines: noted ? 2 : 3,
                                 key: noted ? nil : model.dictation?.keyName(),
                                 keyLabel: Self.keyLabel(moment, settled: led),
                                 change: nil,
                                 dotClicked: model.dictation?.isAvailable() == true ? { model.toggleDictation() } : nil,
                                 submit: Self.finishesOnReturn(moment) && ready ? { model.finish() } : nil,
                                 inserted: model.replyInserted) {
                            if written, context.beats.contains(.after), let spoken = model.replySaid {
                                Text("You said: \(spoken)")
                                    .font(SetupStyle.text(12.5))
                                    .foregroundStyle(SetupStyle.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .transition(.opacity)
                            }
                        }
                        // The native field keeps what it took; a retry's
                        // answer or a switch to Maya starts it afresh.
                        .id(ReplyFieldIdentity(arrival: model.replyWords?.at, thread: own?.id))
                        if moment == .typed, let notice = model.replyNotice {
                            HStack(alignment: .firstTextBaseline, spacing: 14) {
                                ProblemLine(text: notice)
                                Spacer(minLength: 8)
                                Button("Retry") { Task { await model.retryReply() } }
                                    .buttonStyle(QuietLinkStyle())
                                    .fixedSize()
                            }
                        }
                    }
                    if noted {
                        VStack(alignment: .leading, spacing: 12) {
                            Hairline()
                            ScreenRecordingRow()
                        }
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: reduceMotion ? 0 : 6))
                                                    .animation(SetupMotion.cubicOut(0.28)),
                                                removal: .opacity))
                    }
                }
            }
        case .actions:
            Actions {
                if moment == .waiting {
                    Button("Skip for now") { model.finish() }
                        .buttonStyle(QuietLinkStyle())
                        .transition(.opacity.animation(.linear(duration: 0.16)))
                } else if moment == .typed, own != nil {
                    // A write on their own thread failed: Maya's message
                    // shows how it works without their mail.
                    Button("Answer Maya instead") { model.useExampleReply() }
                        .buttonStyle(QuietLinkStyle())
                        .transition(.opacity.animation(.linear(duration: 0.16)))
                }
            } main: {
                if moment == .typed || moment == .unavailable || (written && ready) {
                    Button(model.asksOpenAtLogin ? "Continue" : "Start using Intention") { model.finish() }
                        .buttonStyle(InkActionStyle(delay: written ? 0 : 0.65))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func reportThreadShown(_ model: OnboardingModel) {
        guard sheetDisplayed else { return }
        if model.reply == .unavailable { model.replyThreadShown(.example) }
        else {
            switch model.replySubject {
            case .own: model.replyThreadShown(.ownThread)
            case .example: model.replyThreadShown(.example)
            case .looking: break
            }
        }
    }

    /// Whether this page ends setup and macOS asks for Screen Recording next.
    private var isLast: Bool {
        !context.model.asksOpenAtLogin && context.model.asksScreenRecordingNext
    }

    static func placeholder(_ subject: OnboardingModel.ReplySubject) -> String {
        switch subject {
        case .looking: "Say how you\u{2019}d answer"
        case .own: "Say \u{201C}\(PracticeReply.ownCue)\u{201D}, or what you want to tell them"
        case .example: "Say \u{201C}\(PracticeReply.instructionCue)\u{201D} or just \u{201C}\(PracticeReply.directCue)\u{201D}"
        }
    }

    /// The person's own thread, when the page answers one.
    static func ownThread(_ subject: OnboardingModel.ReplySubject) -> AlphaClient.ReplyThread? {
        if case let .own(thread) = subject { thread } else { nil }
    }

    /// What the card shows: the person's thread, Maya's, or a quiet line
    /// while Intention is still looking.
    static func card(_ subject: OnboardingModel.ReplySubject) -> MessageCard.Message {
        switch subject {
        case .looking: .looking
        case let .own(thread): .own(thread)
        case .example: .example
        }
    }

    /// The example in place of a field: "An example" above it, then the
    /// words the example's person says and the reply they become.
    private var example: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return VStack(alignment: .leading, spacing: 8) {
            Text("AN EXAMPLE")
                .font(SetupStyle.text(11, .semibold))
                .tracking(0.88)
                .foregroundStyle(SetupStyle.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("you say: \u{201C}\(PracticeReply.directCue)\u{201D}")
                    .font(SetupStyle.display(18))
                    .foregroundStyle(SetupStyle.ink.opacity(0.7))
                    .accessibilityLabel("An example. You say: \(PracticeReply.directCue)")
                Text(PracticeReply.exampleEmail)
                    .font(FirstDictationField.swiftUIFont(16))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(PracticeReply.exampleEmail)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SetupStyle.field, in: shape)
            .overlay(shape.strokeBorder(SetupStyle.fieldEdge, lineWidth: 0.5))
            // Said exactly: why the writer was not asked, and once words were
            // said here, that they were heard and went nowhere.
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if context.model.replyHeardWithoutWriter {
                    ProblemLine(text: "Intention heard you, but didn't write. \(context.model.replyUnavailableReason)")
                } else {
                    Hint(text: context.model.replyUnavailableReason)
                }

            }
        }
    }

    /// The field's own moment, from the page's: it listens the same way,
    /// and shows nothing of its own while the writer works.
    static func dictationMoment(_ moment: OnboardingModel.ReplyMoment) -> FirstDictation.Moment {
        switch moment {
        case .unavailable: .unavailable
        case .waiting: .waiting
        case .listening: .listening
        case .finishing, .writing: .finishing
        case .written, .typed: .heard("")
        }
    }

    static func keyLabel(_ moment: OnboardingModel.ReplyMoment, settled: Bool) -> String {
        switch moment {
        case .listening: ""
        case .finishing: "Writing it down."
        case .writing: "Writing your email…"
        case .written: settled ? "Hold to talk" : "Writing your email…"
        case .waiting, .typed, .unavailable: "Hold to talk"
        }
    }

    /// Whether the page offers a way off it, Continue or Skip for now, so
    /// what follows setup can be shown first.
    static func canLeave(_ moment: OnboardingModel.ReplyMoment) -> Bool {
        moment == .waiting || finishesOnReturn(moment)
    }

    static func finishesOnReturn(_ moment: OnboardingModel.ReplyMoment) -> Bool {
        switch moment {
        case .written, .typed, .unavailable: true
        case .waiting, .listening, .finishing, .writing: false
        }
    }

    static func title(_ moment: OnboardingModel.ReplyMoment, own: Bool) -> String {
        switch moment {
        case .unavailable: "In an email"
        case .waiting, .listening, .finishing, .writing, .typed: own ? "Now a real email" : "Now an email"
        case .written: own ? "That’s your voice" : "That’s your email"
        }
    }

    private func lead(_ moment: OnboardingModel.ReplyMoment, key: String) -> String {
        let model = context.model
        switch moment {
        case .unavailable: return "With your cursor in a Gmail or Mail reply, the same key writes the email from what you say."
        case .waiting:
            if model.replyNeedsMicrophone {
                return "Intention couldn't use the microphone. Check it in System Settings, then hold \(key) again."
            }
            if model.replySilent {
                return "Intention didn't hear anything. Hold \(key), say your reply, then let go."
            }
            if model.replyMissed { return "That one didn't come through. Hold \(key) and try again." }
            return switch model.replySubject {
            case .looking: "Finding a recent email of yours to answer."
            case .own: "From your inbox, waiting on you. Hold \(key) and say how you’d answer."
            case .example(.noCandidate): "Nothing recent is waiting on your reply, so try this one. Hold \(key) and answer."
            // The server said none of their received mail is ready yet.
            case .example(.preparing): "Intention hasn't read enough of your mail yet, so try this one. Your own emails work here once it has."
            // An older server, an error or a timeout says nothing about their mail.
            case .example(.unavailable): "Try this one to see how it works. Hold \(key) and answer."
            }
        case .listening: return "Let go of \(key) when you’re done."
        case .finishing: return "Writing it down."
        case .writing: return "Intention is writing it from what you said."
        case .written:
            return Self.ownThread(model.replySubject) != nil
                ? "Nothing was sent. In Gmail it works the same: cursor in the reply, hold \(key), talk."
                : "Same thing in Gmail or Mail: cursor in the reply, hold \(key), talk."
        // Why, as exactly as the writer said, where there is room for it.
        case .typed: return PracticeReply.typedLead(for: model.replyFailureName, key: key)
        }
    }
}

/// What the reply page's field is rebuilt for.
private struct ReplyFieldIdentity: Hashable {
    let arrival: Date?
    let thread: String?
}

/// The message the person answers, drawn as an email client shows one:
/// who, when, and what they wrote, on a card on the sheet. The person's own
/// thread also shows its subject and at most two lines of the message, one
/// once the reply is written under it, so the sheet keeps clear of the
/// actions.
struct MessageCard: View {
    enum Message: Equatable {
        case looking
        case own(AlphaClient.ReplyThread)
        case example
    }

    let message: Message
    /// One line of the message, once the reply is in the field under it.
    var compact = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 7) {
            switch message {
            case .looking:
                Text("Looking in your inbox…")
                    .font(SetupStyle.text(15))
                    .foregroundStyle(SetupStyle.secondary)
                    .frame(minHeight: 44, alignment: .leading)
            case let .own(thread):
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(thread.senderName).font(SetupStyle.text(13, .semibold)).lineLimit(1).layoutPriority(1)
                    Text(thread.subject).font(SetupStyle.text(13)).foregroundStyle(SetupStyle.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Self.when(thread.sentAt)).font(SetupStyle.text(13)).foregroundStyle(SetupStyle.secondary).fixedSize()
                }
                Text(Self.oneParagraph(thread.message))
                    .font(SetupStyle.text(15))
                    .lineSpacing(3)
                    .lineLimit(compact ? 1 : 2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            case .example:
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(PracticeReply.Message.sender).font(SetupStyle.text(13, .semibold))
                    Text(PracticeReply.Message.time).font(SetupStyle.text(13)).foregroundStyle(SetupStyle.secondary)
                }
                Text(PracticeReply.Message.text)
                    .font(SetupStyle.text(15))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SetupStyle.paper, in: shape)
        .overlay(shape.strokeBorder(SetupStyle.edge, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .animation(SetupStyle.quick, value: message)
    }

    /// Today's time, the weekday within the week, the date before that, as
    /// a mail list shows them.
    static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 6 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// The message as one run of text, so two lines show its start rather
    /// than a greeting and a blank line.
    static func oneParagraph(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}

// MARK: - Open at login

/// The last question, asked once the person has spoken: whether Intention
/// opens when they log in. Nothing is added to Login Items unless they say
/// yes, and Settings changes the answer later. On the sheet, what Intention
/// does, in up to three lines, and how far it has come reading the
/// person's mail, read again while the page shows. When macOS is about to
/// ask for Screen Recording as setup ends, the switch is drawn first, as
/// the sheet's last row.
private struct OpenAtLoginPage: View {
    let part: PagePart
    let context: PageContext

    var body: some View {
        let model = context.model
        let noted = model.asksScreenRecordingNext
        let lines = Self.recap(key: context.key, offers: model.recapOffers)
        let learning = Self.learning(model)
        switch part {
        case .head:
            Head(title: "You’re set", lead: "Intention lives in your menu bar. Open it at login and it’s always ready.", context: context)
        case .sheet:
            Sheet(height: noted ? 264 : 252, context: context) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        if index > 0 { Hairline() }
                        HStack(spacing: 14) {
                            glyph(line.glyph)
                            Text(line.text).font(SetupStyle.text(15)).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, noted ? 11 : 15)
                    }
                    if let label = learning?.label {
                        LearningLine(label: label, fraction: learning?.fraction, detail: learning?.detail, width: OnboardingView.size.width - 100)
                            .padding(.top, 2)
                            .transition(.opacity)
                    } else if let voice = Self.voice(model.voice) {
                        Hint(text: voice)
                            .padding(.top, 2)
                            .transition(.opacity)
                    }
                    if noted {
                        Hairline().padding(.top, learning?.label == nil && Self.voice(model.voice) == nil ? 0 : 11)
                        ScreenRecordingRow().padding(.top, 11)
                    }
                }
                .animation(SetupStyle.quick, value: model.voice)
            }
        case .actions:
            Actions {
                Button("Not now") { model.answerOpenAtLogin(false) }
                    .buttonStyle(QuietLinkStyle())
            } main: {
                Button("Open at Login") { model.answerOpenAtLogin(true) }
                    .buttonStyle(InkActionStyle(delay: 0.15))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// While mail comes in, or once the voice is ready, the line History
    /// shows, read from the same mailbox list; the hint otherwise.
    static func learning(_ model: OnboardingModel) -> (label: String?, fraction: Double?, detail: String?)? {
        guard model.voice == .learning || model.voice == .ready || model.voice == .imported else { return nil }
        let shown = LearningProgress.presentation(model.availableConnections, learning: model.learning)
        // The server can still be preparing examples after import finishes.
        // Explain continued learning without claiming more mail is already needed.
        if model.voice == .imported {
            return (shown.label, nil, "Keeps learning as you send")
        }
        return shown
    }

    enum Glyph { case key, mail, reply }

    @ViewBuilder private func glyph(_ glyph: Glyph) -> some View {
        switch glyph {
        case .key:
            SetupKeycap(label: context.key.components(separatedBy: " + ").first ?? context.key, small: true)
                .frame(width: 38)
        case .mail, .reply:
            RecapGlyph(glyph: glyph)
                .stroke(SetupStyle.lead, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                .frame(width: 20, height: 20)
                .frame(width: 38)
                .accessibilityHidden(true)
        }
    }

    /// Only what is on: a line for a setting turned off would promise
    /// something Intention will not do.
    static func recap(key: String, offers: OnboardingModel.Offers) -> [(glyph: Glyph, text: String)] {
        [(.key, "Hold \(key) to talk anywhere.")]
            + (offers.writesEmails ? [(.mail, "In an email, it writes the email.")] : [])
            + (offers.proposesReplies ? [(.reply, "When you open a reply in Gmail, it offers one.")] : [])
    }

    static func voice(_ voice: OnboardingModel.Voice) -> String? {
        switch voice {
        case .unknown: nil
        case .noMail: "Connect your mail in Settings, so emails sound like you."
        // Conditional: a mailbox with little sent mail may never have enough,
        // and the notification shows only if macOS allows it; the menu bar
        // and History say it either way.
        case .learning: "Intention is reading your sent mail to learn how you write, and lets you know once it has enough."
        case .ready: VoiceReady.message
        // Imported and not ready: it needs more sent mail, or a little time
        // while the server prepares it. Nothing is promised either way.
        case .imported: "Your mail is in. Intention needs enough sent mail to learn how you write, and keeps learning as you send."
        case .stopped: "Your mail stopped. Check it in Settings."
        }
    }

    /// An envelope and a reply arrow, in a 24 by 24 box.
    private struct RecapGlyph: Shape {
        let glyph: Glyph

        func path(in rect: CGRect) -> Path {
            let s = rect.width / 24
            let p = { (x: CGFloat, y: CGFloat) in CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
            var path = Path()
            switch glyph {
            case .mail:
                path.addRoundedRect(in: CGRect(origin: p(3.5, 6), size: CGSize(width: 17 * s, height: 12.5 * s)),
                                    cornerSize: CGSize(width: 2 * s, height: 2 * s))
                path.move(to: p(4.5, 7.5))
                path.addLine(to: p(12, 13))
                path.addLine(to: p(19.5, 7.5))
            case .reply:
                path.move(to: p(10, 6.5))
                path.addLine(to: p(4.5, 11.5))
                path.addLine(to: p(10, 16.5))
                path.move(to: p(5, 11.5))
                path.addLine(to: p(14, 11.5))
                path.addCurve(to: p(19.5, 17.5), control1: p(17.2, 11.5), control2: p(19.5, 13.6))
            case .key:
                break
            }
            return path
        }
    }
}

/// The switch macOS asks for as setup ends, drawn before its alert comes,
/// so the alert reads as expected and the line in the list is recognised:
/// a row of the last page's sheet, with Intention's line as System Settings
/// shows it at its right.
private struct ScreenRecordingRow: View {
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Label13(text: "One more switch comes next")
                Hint(text: "Screen Recording, so the dot shows in Gmail before you type. Turn Intention on.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SettingsHint(width: 210, height: 32)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Languages

/// The languages a person dictates in, as buttons to press: the picked
/// ones inked, the Mac's own shown first, and the rest under More. It
/// holds no choice of its own.
struct DictationLanguagePicker: View {
    let chosen: [String]
    /// The ones shown as buttons.
    let shown: [String]
    /// Every language on offer; those not shown are under More.
    let offered: [String]
    let toggle: (String) -> Void

    var body: some View {
        let isFull = chosen.count >= LanguageChoice.limit
        FlowRow(spacing: 7) {
            ForEach(shown, id: \.self) { code in
                let isChosen = chosen.contains(code)
                Button(LanguageChoice.name(code)) { toggle(code) }
                    .buttonStyle(SeatButtonStyle(isChosen: isChosen))
                    // A sixth cannot be added. The last one left stays picked
                    // when pressed, and keeps its full ink.
                    .disabled(!isChosen && isFull)
                    .accessibilityValue(isChosen ? "Chosen" : "")
            }
            let rest = offered.filter { !shown.contains($0) }
            if !rest.isEmpty, !isFull {
                Menu("More") {
                    ForEach(rest, id: \.self) { code in
                        Button(LanguageChoice.name(code)) { toggle(code) }
                    }
                }
                .menuStyle(.button)
                .buttonStyle(SeatButtonStyle())
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }
}

/// Lays its buttons in a row and starts a new row when one is full.
private struct FlowRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(in: proposal.width ?? .infinity, subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0,
                      height: rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(in: bounds.width, subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(in width: CGFloat, _ subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1] = (last.items + [index], last.width + spacing + size.width, max(last.height, size.height))
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
    }
}
