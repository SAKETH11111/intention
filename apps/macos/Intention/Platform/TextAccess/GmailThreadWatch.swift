import AppKit
import ApplicationServices
import Foundation
import os

/// Tells the reply proposals when a Gmail thread opens in a Chromium
/// browser, so a proposal can be asked for before the person clicks Reply
/// (`ReplyProposalController.threadOpened`).
///
/// It is driven by the browser's own notifications, never by a timer: while
/// proposals are wanted and a Chromium browser is the frontmost app, an
/// Accessibility observer on that app hears its focused element or focused
/// window change, and one on its focused window, moved with focus, hears
/// that window's title change, as Gmail retitles the window to the
/// thread's subject when one opens. Once the notifications stop for
/// `quiet`, it reads the focused page (`ComposeAccess.gmailThread`): the
/// focused element, the roles up to its web area and that page's address,
/// and only for a Gmail thread view not read since it opened, what the
/// thread view shows. A thread is read once each time it opens; one whose
/// address shows before its messages do is read again at most `retries`
/// times, `retryPause` apart, unless a notification comes first. However
/// the notifications and retries fall, two reads of the page are at least
/// `spacing` apart, so a page that keeps posting while its messages load
/// is walked at most once a second. Nothing is read while proposals are
/// not wanted, in any other app, or once the browser is no longer in
/// front.
///
/// The thread it last read open is remembered while the browser goes to
/// the back and comes forward again, so coming back to it asks nothing
/// again, and forgotten when proposals stop being wanted or the account
/// changes (`refresh(accountChanged:)`), since the proposals let go of
/// what they held for it then, and the same thread is asked for afresh
/// once they are wanted again.
///
/// Its own Accessibility thread keeps the page walk from delaying the dot
/// or an insertion.
final class GmailThreadWatch: @unchecked Sendable {
    /// How long the notifications must stop before the page is read, so
    /// the burst a navigation posts costs one read.
    static let quiet: Duration = .milliseconds(300)
    /// How long before a thread whose messages had not shown is read again.
    static let retryPause: Duration = .seconds(1)
    static let retries = 3
    /// The least time from one read of the page to the next.
    static let spacing: Duration = .seconds(1)

    private let executor: AccessibilityExecutor
    /// Synthetic watches use their own notifications, independent of desktop activity.
    private let activationCenter: NotificationCenter?
    /// A synthetic page read for executor-delay scenarios; native reads
    /// otherwise stay on this watch's executor.
    private let readPage: (@Sendable (String?) -> Bool)?
    /// Synthetic thread reads and browser selection for account and
    /// executor-delay scenarios, without reading another app.
    private let readThread: (@Sendable () -> ComposeAccess.ThreadRead)?
    @MainActor private let browserPID: (@MainActor () -> pid_t?)?
    /// Read on the executor and checked again before main-actor delivery,
    /// so a completed page walk cannot cross an account change.
    private let accountGeneration = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    private struct FollowRequest: Sendable {
        var pid: pid_t?
        var serial: UInt64 = 0
    }
    private let desiredFollow = OSAllocatedUnfairLock(initialState: FollowRequest())
    @MainActor private var followSubmitted = false
    private let createObserver: @Sendable (pid_t, AXObserverCallback) -> AXObserver?
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    /// Called on the main actor after the read's account generation is checked.
    private let opened: @Sendable (GmailThreadView) -> Void
    /// On the executor only: the observer of the followed app, and the
    /// thread its focused page showed when last read, so an open is read
    /// once.
    private var observer: AXObserver?
    private var observedPID: pid_t?
    /// The focused window whose title the observer hears.
    private var observedWindow: AXUIElement?
    private var open: (pid: pid_t, threadID: String)?
    @MainActor private var wanted: (@MainActor () -> Bool)?
    @MainActor private var waiting: Task<Void, Never>?
    @MainActor private var activation: NSObjectProtocol?
    /// When the last page read finished, owned by the executor. Spacing
    /// from its end also covers delays within the window and page walk.
    private var lastRead: ContinuousClock.Instant?
    private struct ReadRequest: Sendable {
        var serial: Int
        var accountGeneration: UInt64
        var retry: Int
        var ready: ContinuousClock.Instant
    }
    /// Main-actor notifications replace the queued request. The executor
    /// takes the newest one only when it can actually start a page read.
    private let pendingRead = OSAllocatedUnfairLock<ReadRequest?>(initialState: nil)
    @MainActor private(set) var readSubmitted = false
    @MainActor private var readSerial = 0
    /// How many notifications and refreshes have reached the main actor,
    /// for the checks.
    @MainActor private(set) var notices = 0
    @MainActor private(set) var refreshes = 0

    init(activationCenter: NotificationCenter? = nil, executor: AccessibilityExecutor = AccessibilityExecutor(capacity: 2),
         readPage: (@Sendable (String?) -> Bool)? = nil,
         readThread: (@Sendable () -> ComposeAccess.ThreadRead)? = nil,
         browserPID: (@MainActor () -> pid_t?)? = nil,
         createObserver: @escaping @Sendable (pid_t, AXObserverCallback) -> AXObserver? = GmailThreadWatch.makeObserver, opened: @escaping @Sendable (GmailThreadView) -> Void) {
        self.executor = executor
        self.activationCenter = activationCenter
        self.readPage = readPage
        self.readThread = readThread
        self.browserPID = browserPID
        self.createObserver = createObserver
        self.opened = opened
    }

    /// Follows the frontmost app while `wanted` holds, refreshed whenever
    /// another app comes to the front and whenever the app calls `refresh`.
    @MainActor
    func start(while wanted: @escaping @MainActor () -> Bool) {
        guard activation == nil else { return }
        self.wanted = wanted
        activation = (activationCenter ?? NSWorkspace.shared.notificationCenter).addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main, using: Self.activationHandler(self))
        refresh()
    }

    /// The activation notification's handler: a `@Sendable` closure made
    /// outside the main actor, so nothing about it is taken for main-actor
    /// code, which reaches the main actor itself (`activated`) on whichever
    /// queue the notification center calls it.
    nonisolated static func activationHandler(_ watch: GmailThreadWatch) -> @Sendable (Notification) -> Void {
        { [weak watch] _ in watch?.activated() }
    }

    /// The frontmost app, the gates or the account may have changed:
    /// follows the frontmost app when it is a Chromium browser and
    /// proposals are wanted, and otherwise nothing, then reads its page
    /// once quiet. With proposals not wanted, or `accountChanged`, the
    /// thread last read open is forgotten first; another app coming to the
    /// front keeps it.
    @MainActor
    func refresh(accountChanged: Bool = false) {
        refreshes += 1
        let wanted = wanted?() == true
        let pid: pid_t?
        if let browserPID {
            pid = wanted ? browserPID() : nil
        } else {
            let app = NSWorkspace.shared.frontmostApplication
            pid = wanted && WritingSurfacePolicy.isChromiumBrowser(bundleIdentifier: app?.bundleIdentifier) ? app?.processIdentifier : nil
        }
        let follows = pid != nil
        if !follows || accountChanged {
            waiting?.cancel()
            pendingRead.withLock { $0 = nil }
        }
        if !wanted || accountChanged {
            accountGeneration.withLock { $0 &+= 1 }
            forgetOpen()
        }
        desiredFollow.withLock { $0.pid = pid; $0.serial &+= 1 }
        submitFollow()
        if pid != nil { noticed() }
    }

    /// Keep one follow queued and take the latest browser at execution. A
    /// full queue schedules only a main-actor retry after earlier jobs drain;
    /// cleanup itself never messages an app.
    @MainActor
    private func submitFollow() {
        guard !followSubmitted else { return }
        followSubmitted = true
        if !executor.submit({ _ in
            let request = self.desiredFollow.withLock { $0 }
            self.follow(request.pid)
            Self.onMain {
                self.followSubmitted = false
                if self.desiredFollow.withLock({ $0.serial }) != request.serial { self.submitFollow() }
            }
        }) {
            executor.submitCleanup {
                Self.onMain {
                    self.followSubmitted = false
                    self.submitFollow()
                }
            }
        }
    }

    /// Forgets the thread last read open, on the executor, which owns it.
    /// Queued as cleanup, which a full queue never drops and which runs
    /// before any read queued after it; it messages no app.
    @MainActor
    private func forgetOpen() {
        executor.submitCleanup { self.open = nil }
    }

    /// The thread id last read open, for the checks.
    func rememberedThread() async -> String? {
        await withCheckedContinuation { done in executor.submitCleanup { done.resume(returning: self.open?.threadID) } }
    }

    /// Remembers a thread as read open, as a read would, for the checks.
    func remember(pid: pid_t, threadID: String) async {
        await withCheckedContinuation { done in
            executor.submitCleanup {
                self.open = (pid, threadID)
                done.resume()
            }
        }
    }

    /// Another app came to the front. Nonisolated with its own hop, so it
    /// is safe on any queue.
    nonisolated func activated() {
        Self.onMain { [weak self] in self?.refresh() }
    }

    /// From the observer's callback on the executor's thread: the page may
    /// show something else. Reaches the main actor itself.
    nonisolated func notified() {
        Self.onMain { [weak self] in self?.noticed() }
    }

    /// Runs `work` on the main actor: at once on the main thread, through
    /// the main queue anywhere else.
    nonisolated static func onMain(_ work: @escaping @Sendable @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
        }
    }

    /// A thread open rejected during dictation gets one fresh read of the
    /// page now shown. Forgetting its old id lets `.same` become an open;
    /// a different page cannot revive the rejected thread's snapshot.
    @MainActor
    func retryOpen() {
        // A page job already queued may read before cleanup. Schedule the
        // retry only after forgetting, so that job cannot consume it early.
        executor.submitCleanup {
            self.open = nil
            Self.onMain { self.noticed() }
        }
    }

    /// Each notice replaces the request, including one already waiting on
    /// earlier Accessibility work. Only one page job may be queued at once.
    @MainActor
    private func noticed(retry: Int = 0) {
        notices += retry == 0 ? 1 : 0
        readSerial += 1
        let ready = ContinuousClock.now + (retry > 0 ? Self.retryPause : Self.quiet)
        let request = ReadRequest(serial: readSerial, accountGeneration: accountGeneration.withLock { $0 }, retry: retry, ready: ready)
        pendingRead.withLock { $0 = request }
        scheduleRead(at: ready)
    }

    @MainActor
    private func scheduleRead(at ready: ContinuousClock.Instant) {
        waiting?.cancel()
        waiting = Task { [weak self] in
            try? await Task.sleep(until: ready, clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            guard self.wanted?() == true else {
                self.pendingRead.withLock { $0 = nil }
                return self.forgetOpen()
            }
            guard !self.readSubmitted, self.pendingRead.withLock({ $0 != nil }) else { return }
            self.readSubmitted = true
            if !self.executor.submit({ _ in self.executeRead() }) {
                self.readSubmitted = false
                self.scheduleRead(at: .now + Self.quiet)
            }
        }
    }

    /// Submission time cannot enforce spacing: earlier AX calls may stall
    /// this queue. Check the actual start here and return to the scheduler
    /// without blocking the executor when the newest request is not due.
    private func executeRead() {
        precondition(executor.isCurrent)
        guard let request = pendingRead.withLock({ $0 }) else {
            return Self.onMain {
                self.readSubmitted = false
                if let newest = self.pendingRead.withLock({ $0 }) { self.scheduleRead(at: newest.ready) }
            }
        }
        let now = ContinuousClock.now
        let ready = max(request.ready, lastRead.map { $0 + Self.spacing } ?? request.ready)
        guard now >= ready else {
            return Self.onMain { self.readFinished(request, postponed: ready, retry: false) }
        }
        guard accountGeneration.withLock({ $0 }) == request.accountGeneration else {
            return Self.onMain { self.readFinished(request, postponed: nil, retry: false) }
        }
        let retry = readPage?(open?.threadID) ?? read(generation: request.accountGeneration)
        lastRead = .now
        Self.onMain { self.readFinished(request, postponed: nil, retry: retry) }
    }

    @MainActor
    private func readFinished(_ request: ReadRequest, postponed: ContinuousClock.Instant?, retry: Bool) {
        readSubmitted = false
        guard let newest = pendingRead.withLock({ $0 }) else { return }
        guard newest.serial == request.serial else { return scheduleRead(at: newest.ready) }
        if let postponed { return scheduleRead(at: postponed) }
        pendingRead.withLock { $0 = nil }
        if retry, request.retry < Self.retries { noticed(retry: request.retry + 1) }
    }

    /// Reads the focused page on the executor and reports a thread that
    /// opened. True when the page showed a thread's address and not yet
    /// its messages, so it is worth reading again.
    private func read(generation: UInt64) -> Bool {
        precondition(executor.isCurrent)
        guard readThread != nil || observedPID != nil else {
            AppLog.compose("proposal.thread.noOpened.noBrowser")
            return false
        }
        observeFocusedWindow()
        let open = open
        let result = readThread?() ?? ComposeAccess.gmailThread(ownPID: ownPID, isNew: { open?.pid != $0 || open?.threadID != $1 })
        guard accountGeneration.withLock({ $0 }) == generation else {
            AppLog.compose("proposal.thread.noOpened.account")
            return false
        }
        switch result {
        case .unknown:
            AppLog.compose("proposal.thread.noOpened.unknown")
            return false
        case .same:
            AppLog.compose("proposal.thread.noOpened.alreadyOpen")
            return false
        case let .unavailable(reason):
            AppLog.compose("proposal.thread.noOpened." + reason.rawValue)
            if reason == .notGmail || reason == .noThreadID { self.open = nil }
            return reason == .messages || reason == .pageChanged
        case .elsewhere:
            AppLog.compose("proposal.thread.noOpened.elsewhere")
            // Another page: the thread shown next is an open of its own.
            self.open = nil
            return false
        case .notReady:
            AppLog.compose("proposal.thread.noOpened.messages")
            return true
        case let .opened(view):
            self.open = (view.pid, view.threadID)
            Self.onMain {
                guard self.accountGeneration.withLock({ $0 }) == generation else { return }
                self.opened(view)
            }
            return false
        }
    }

    /// What the observer hears from the app's element: focus moving, and
    /// the focused window changing, which moves the title's registration.
    static let appNotifications = [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification]
    /// What it hears from the focused window itself. A window posts its
    /// title change to an observer registered on that window.
    static let windowNotifications = [kAXTitleChangedNotification]

    /// Observes `pid`'s focus and focused window, and its focused window's
    /// title, and only that app's; nil observes nothing.
    private func follow(_ pid: pid_t?) {
        precondition(executor.isCurrent)
        guard pid != observedPID else { return observeFocusedWindow() }
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedWindow = nil
        observedPID = nil
        guard let pid, let created = createObserver(pid, Self.callback) else { return }
        observedPID = pid
        let app = AXUIElementCreateApplication(pid)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.appNotifications {
            _ = AXObserverAddNotification(created, app, name as CFString, context)
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        observeFocusedWindow()
    }

    private static func makeObserver(_ pid: pid_t, _ callback: AXObserverCallback) -> AXObserver? {
        var observer: AXObserver?
        guard AXObserverCreate(pid, callback, &observer) == .success else { return nil }
        return observer
    }

    /// Follow a synthetic process on the observer's executor, for checks.
    func followForCheck(_ pid: pid_t?) async -> pid_t? {
        await withCheckedContinuation { done in
            executor.submitCleanup {
                self.follow(pid)
                done.resume(returning: self.observedPID)
            }
        }
    }

    /// Moves the title's registration to the followed app's focused window,
    /// when it is another window than the one registered.
    private func observeFocusedWindow() {
        precondition(executor.isCurrent)
        guard let observer, let pid = observedPID else { return }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return }
        let window = value as! AXUIElement
        if let observedWindow, CFEqual(observedWindow, window) { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.windowNotifications {
            if let observedWindow { AXObserverRemoveNotification(observer, observedWindow, name as CFString) }
            _ = AXObserverAddNotification(observer, window, name as CFString, context)
        }
        observedWindow = window
    }

    /// Runs on the executor's thread, whose run loop holds the observer's
    /// source. The watch lives as long as the app, so the unretained
    /// context stays valid.
    private static let callback: AXObserverCallback = { _, _, notification, context in
        guard let context else { return }
        let watch = Unmanaged<GmailThreadWatch>.fromOpaque(context).takeUnretainedValue()
        if (notification as String) == kAXFocusedWindowChangedNotification { watch.observeFocusedWindow() }
        watch.notified()
    }
}
