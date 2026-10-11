import AppKit

/// Only windows a person opens belong in the Dock and Command-Tab. Settings
/// is inside History's window today; the guide is a nonactivating overlay.
enum IntentionWindowKind: CaseIterable, Hashable, Sendable {
    case history, settings, onboarding, reportProblem, settingsGuide, update
    case caretDot, footMark, card, popup

    var belongsInDock: Bool {
        switch self {
        case .history, .settings, .onboarding, .reportProblem, .settingsGuide, .update: true
        case .caretDot, .footMark, .card, .popup: false
        }
    }
}

enum DockPolicy: Equatable, Sendable {
    case regular, accessory

    static func forWindows(_ kinds: Set<IntentionWindowKind>) -> Self {
        kinds.contains(where: \.belongsInDock) ? .regular : .accessory
    }
}

/// Owns policy changes, without activating any application on dismissal.
/// Promotion precedes presentation. Dismissal waits one main-queue turn so
/// AppKit has finished ordering out a closing key window, and a replacement
/// window opened in that turn keeps the existing policy and menu bar.
@MainActor
final class DockActivationController {
    static let shared = DockActivationController()
    private let center: NotificationCenter
    private let windows: @MainActor () -> [NSWindow]
    private let apply: @MainActor (DockPolicy) -> Void
    private var observers: [NSObjectProtocol] = []
    private var opening: Set<ObjectIdentifier> = []
    private var closing: Set<ObjectIdentifier> = []
    private var reconciliationPending = false
    private var generation: UInt64 = 0
    private var updatePresentationPending = false
    private var lastAppliedPolicy = DockPolicy.accessory
    private let readPolicy: @MainActor () -> DockPolicy?
    var policy: DockPolicy { readPolicy() ?? lastAppliedPolicy }

    init(center: NotificationCenter = .default,
         windows: @escaping @MainActor () -> [NSWindow] = { NSApp.windows },
         readPolicy: (@MainActor () -> DockPolicy?)? = nil,
         apply: (@MainActor (DockPolicy) -> Void)? = nil) {
        let usesAppKit = apply == nil
        self.readPolicy = readPolicy ?? {
            guard usesAppKit else { return nil }
            return NSApp.activationPolicy() == .regular ? .regular : .accessory
        }
        self.apply = apply ?? { policy in
             // No activate(), workspace activation or temporary prohibited
             // policy here. Nonactivating indicator panels keep their order.
             NSApp.setActivationPolicy(policy == .regular ? .regular : .accessory)
        }
        self.center = center
        self.windows = windows
    }

    func start() {
        guard observers.isEmpty else { return }
        let names: [Notification.Name] = [
            NSWindow.willCloseNotification, NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification, NSWindow.didResignMainNotification,
            NSWindow.didUpdateNotification, NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification,
            NSApplication.didUpdateNotification, NSApplication.didUnhideNotification
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main,
                                                using: Self.observer(self, generation: generation)))
        }
        reconcile()
    }

    func stop() {
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
        generation &+= 1
        reconciliationPending = false
        opening.removeAll()
        closing.removeAll()
        updatePresentationPending = false
    }

    /// disabled updater's pre-presentation hooks have no window reference yet.
    /// Hold promotion through this ordering turn, then count its real window.
    func willPresentUpdate() {
        updatePresentationPending = true
        setPolicy(.regular)
        scheduleReconciliation()
    }

    /// Called before ordering our own window front, so Settings' first
    /// presentation and activation happen after regular policy is requested.
    func willOpen(_ window: NSWindow) {
        guard Self.kind(of: window)?.belongsInDock == true else { return }
        let id = ObjectIdentifier(window)
        closing.remove(id)
        opening.insert(id)
        setPolicy(.regular)
        scheduleReconciliation()
    }

    static func kind(of window: NSWindow) -> IntentionWindowKind? {
        // The dot, foot, cards, popups, setup flight and permission guide all
        // use borderless nonactivating panels. disabled updater owns titled windows
        // and panels, so class alone cannot distinguish them from overlays.
        guard !window.styleMask.contains(.nonactivatingPanel), window.styleMask.contains(.titled) else { return nil }
        switch window.identifier?.rawValue {
        case "intention.main": return .history
        case "intention.onboarding": return .onboarding
        case "intention.report-problem": return .reportProblem
        case "intention.update": return .update
        default: return .update
        }
    }

    private func receive(_ name: Notification.Name, window: ObjectIdentifier?, generation: UInt64) {
        guard self.generation == generation else { return }
        if name == NSWindow.willCloseNotification, let window {
            closing.insert(window)
            opening.remove(window)
        }
        // disabled updater owns its presentation; key/update/occlusion notifications
        // discover those windows without taking over its delegates.
        if name != NSWindow.willCloseNotification { reconcile(allowAccessory: false) }
        scheduleReconciliation()
    }

    private func scheduleReconciliation() {
        guard !reconciliationPending else { return }
        reconciliationPending = true
        let generation = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.reconciliationPending = false
            self.opening.removeAll()
            self.updatePresentationPending = false
            self.reconcile()
            self.closing.removeAll()
        }
    }

    private func reconcile(allowAccessory: Bool = true) {
        let kinds = Set(windows().compactMap { window -> IntentionWindowKind? in
            let id = ObjectIdentifier(window)
            guard !closing.contains(id), window.isVisible || window.isMiniaturized || opening.contains(id) else { return nil }
            return Self.kind(of: window)
        })
        let requested = DockPolicy.forWindows(kinds)
        if requested == .accessory {
            guard allowAccessory, opening.isEmpty, !updatePresentationPending else { return }
            // Never demote while a closing application window is still key.
            // willClose runs before AppKit removes it from the key ordering.
            guard !windows().contains(where: { $0.isKeyWindow && Self.kind(of: $0) != nil }) else { return }
        }
        setPolicy(requested)
    }

    private func setPolicy(_ requested: DockPolicy) {
        guard policy != requested else { return }
        apply(requested)
        // Read AppKit on each decision. A cached successful request cannot
        // prove the current policy after a rejected request or external reset.
        lastAppliedPolicy = requested
    }

    /// NotificationCenter's queue is main, but the framework entry itself
    /// stays nonisolated. Tests also invoke it directly from a worker queue.
    nonisolated static func observer(_ controller: DockActivationController, generation: UInt64 = 0) -> @Sendable (Notification) -> Void {
        { [weak controller] notification in
            let name = notification.name
            let window = (notification.object as AnyObject?).map(ObjectIdentifier.init)
            if Thread.isMainThread {
                MainActor.assumeIsolated { controller?.receive(name, window: window, generation: generation) }
            } else {
                DispatchQueue.main.async { controller?.receive(name, window: window, generation: generation) }
            }
        }
    }
}

/// The two application delegate entry points share the same main-actor hop.
enum MainWindowReopening {
    static func shouldOpenAtLaunch(atLogin: Bool, opensSetup: Bool, isTestHost: Bool, arguments: [String]) -> Bool {
        !atLogin && !opensSetup && shouldHandleReopen(isTestHost: isTestHost, arguments: arguments)
    }

    static func shouldHandleReopen(isTestHost: Bool, arguments: [String]) -> Bool {
        guard !isTestHost else { return false }
        #if DEBUG
        // These runners intentionionally start the app behind their own fields.
        let backgroundFlags: Set<String> = ["--settings-snapshot", "--home-snapshot", "--controls-snapshot", "--caret-fixture", "--insertion-checks", "--proposal-log", "--dot-log"]
        guard !arguments.contains(where: backgroundFlags.contains) else { return false }
        #endif
        return true
    }

    nonisolated static func request(_ open: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { open() }
        } else {
            DispatchQueue.main.async { open() }
        }
    }
}
