import AppKit

/// The borderless window that carries the dot. It never takes focus,
/// activates Intention or catches a click.
final class DotWindow: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A small window over the dot that takes a click on it, for dictation. It
/// is a non-activating panel that never becomes key, so the click neither
/// activates Intention nor moves focus or the caret out of the field below.
/// It covers the dot and two points around it.
@MainActor
final class DotTargetWindow: NSPanel {
    var onClick: () -> Void = {}

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        level = .statusBar
        // Set explicitly, so the whole target takes clicks. Left at its
        // default, the window server passes a click through any pixel that
        // is fully transparent, as this window's are.
        ignoresMouseEvents = false
        #if DEBUG
        title = "dot target"
        #endif
        let view = DotTargetView()
        view.onClick = { [weak self] in self?.onClick() }
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Moves over `dot`, given in AppKit screen coordinates, and shows. A
    /// window moved under a click can miss it, and a dot placed from pixels
    /// wobbles by a point or so, so the target stays put while the dot is
    /// still well inside it. While `held`, as during dictation, when it is
    /// the way to stop, it moves only once the dot has left it.
    func cover(_ dot: DotPlacement.Dot, held: Bool) {
        // Little more than the dot itself: the text just above the caret
        // stays clickable, and a click that lands on the dot meant it.
        let side = dot.diameter + 4
        let slack = held ? frame.width / 2 - 2 : 3
        if isVisible, abs(frame.midX - dot.center.x) <= slack, abs(frame.midY - dot.center.y) <= slack,
           held || abs(frame.width - side) <= 2 {
            return
        }
        setFrame(DotPlacement.anchor(for: dot), display: false)
        if !isVisible { orderFrontRegardless() }
    }
}

private final class DotTargetView: NSView {
    var onClick: () -> Void = {}

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick()
    }
}
