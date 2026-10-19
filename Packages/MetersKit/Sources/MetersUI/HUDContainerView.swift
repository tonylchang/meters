import AppKit
import MetersCore

/// A phase of a HUD drag.
public enum DragPhase: Sendable {
    case began
    case moved
    case ended
}

/// The HUD's content: a rounded translucent background with the module column on top
///. The whole surface is the drag handle.
@MainActor
public final class HUDContainerView: NSView {
    public private(set) var backgroundStyle = HUDBackgroundStyle(reduceTransparency: false, increaseContrast: false)
    /// Module views currently shown, in display order.
    public private(set) var visibleModuleViews: [NSView] = []
    /// Receives each drag phase with the pointer in global screen coordinates.
    var onDrag: ((DragPhase, CGPoint) -> Void)?
    /// Makes the right-click menu; `nil` means the HUD has none.
    var makeContextMenu: (() -> NSMenu?)?
    /// Shows the right-click menu for a mouse event, or at a view when VoiceOver asks. Replaceable in tests, since
    /// the real menu tracks the mouse until it closes.
    var presentContextMenu: (NSMenu, NSEvent?, NSView) -> Void = { menu, event, view in
        if let event {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        } else {
            menu.popUp(positioning: nil, at: CGPoint(x: 0, y: view.bounds.height), in: view)
        }
    }
    /// Whether a primary-button drag is in progress; a right-click then is ignored.
    private(set) var isDragging = false

    let materialView = NSVisualEffectView()
    private var modules: [any HUDModule] = []

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = HUDMetrics.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        materialView.material = .popover
        materialView.blendingMode = .behindWindow
        // The HUD's app is never active, so the material must not fall back to its inactive look.
        materialView.state = .active
        materialView.maskImage = Self.roundedMask(radius: HUDMetrics.cornerRadius)
        materialView.autoresizingMask = [.width, .height]
        materialView.frame = bounds
        addSubview(materialView)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(AppIdentity.displayName)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override public var isFlipped: Bool { true }
    override public var wantsUpdateLayer: Bool { true }

    // Border and opaque fill colors resolve per appearance, so redraw on light and dark switches.
    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    public func apply(_ style: HUDBackgroundStyle) {
        backgroundStyle = style
        materialView.isHidden = style.fill == .opaque
        needsDisplay = true
    }

    /// Shows the first `visibleCount` modules, in order, and drops the rest.
    public func setModules(_ modules: [any HUDModule], visibleCount: Int) {
        self.modules = modules
        let shown = modules.prefix(visibleCount).map(\.view)
        for view in visibleModuleViews where !shown.contains(view) {
            view.removeFromSuperview()
        }
        for view in shown where view.superview !== self {
            addSubview(view)
        }
        visibleModuleViews = shown
        needsLayout = true
    }

    override public func layout() {
        super.layout()
        var y = HUDMetrics.padding
        for (module, view) in zip(modules, visibleModuleViews) {
            view.frame = CGRect(
                x: HUDMetrics.padding, y: y, width: bounds.width - 2 * HUDMetrics.padding, height: module.height)
            y += module.height + HUDMetrics.moduleSpacing
        }
    }

    override public func updateLayer() {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor =
                backgroundStyle.fill == .opaque ? NSColor.windowBackgroundColor.cgColor : nil
            layer.borderColor = NSColor.separatorColor.cgColor
        }
        layer.borderWidth = backgroundStyle.borderWidth
    }

    // Each visible module's rows, in display order, so a two-rate module reads as two elements.
    override public func accessibilityChildren() -> [Any]? {
        modules.prefix(visibleModuleViews.count).flatMap(\.accessibilityElements)
    }

    // `hitTest` claims every point for the drag handle, so find the module under the pointer here;
    // otherwise VoiceOver's pointer tracking would only ever reach the "meters" group.
    // AppKit declares this nonisolated but calls it on the main thread.
    override public nonisolated func accessibilityHitTest(_ point: NSPoint) -> Any? {
        let module = MainActor.assumeIsolated { () -> NSView? in
            guard let window else { return nil }
            let local = convert(window.convertPoint(fromScreen: point), from: nil)
            return visibleModuleViews.first { $0.frame.contains(local) }
        }
        guard let module else { return self }
        return module.accessibilityHitTest(point) ?? module
    }

    // MARK: - Dragging

    // Modules are not interactive in v1, so every point on the HUD belongs to the drag handle.
    override public func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    // The HUD's app is never active, so the first click must start a drag rather than activate it.
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override public func mouseDown(with event: NSEvent) {
        // A Control-click is a right-click.
        if event.modifierFlags.contains(.control) {
            showContextMenu(for: event, in: self)
            return
        }
        isDragging = true
        onDrag?(.began, NSEvent.mouseLocation)
    }

    override public func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        onDrag?(.moved, NSEvent.mouseLocation)
    }

    override public func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        onDrag?(.ended, NSEvent.mouseLocation)
    }

    // MARK: - Right-click menu

    // A secondary-button drag never moves the HUD: only the primary button drags.
    override public func rightMouseDown(with event: NSEvent) {
        showContextMenu(for: event, in: self)
    }

    override public func rightMouseDragged(with event: NSEvent) {}
    override public func rightMouseUp(with event: NSEvent) {}

    /// Shows the right-click menu for `event`, or, without one, at `view` for VoiceOver's show-menu command.
    /// Returns whether a menu was shown.
    @discardableResult
    func showContextMenu(for event: NSEvent?, in view: NSView) -> Bool {
        guard !isDragging, let menu = makeContextMenu?() else { return false }
        presentContextMenu(menu, event, view)
        return true
    }

    // VoiceOver's show-menu command on the HUD group.
    override public func accessibilityPerformShowMenu() -> Bool {
        showContextMenu(for: nil, in: self)
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
