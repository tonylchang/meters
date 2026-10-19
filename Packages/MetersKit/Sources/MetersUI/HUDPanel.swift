import AppKit
import MetersCore

/// The HUD window: a borderless, non-activating panel that floats above standard windows on every
/// Space, including over fullscreen apps, and never takes focus.
@MainActor
public final class HUDPanel: NSPanel {
    public init() {
        super.init(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        // No window shadow: it made WindowServer spend 12 to 20% of a core (measured Sep 26, 2026).
        // A hairline border defines the edge instead.
        hasShadow = false
        // The HUD tracks its own drags, so it knows when one ends and can settle and save its placement.
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // No title bar shows it, but VoiceOver names the window by it rather than "untitled".
        setAccessibilityTitle(AppIdentity.displayName)
    }

    // Clicking or dragging must leave keyboard focus with the app in use.
    override public var canBecomeKey: Bool { false }
    override public var canBecomeMain: Bool { false }
}
