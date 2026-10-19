import AppKit
import MetersCore

/// Owns the HUD panel: placement, sizing, appearance, visibility, and the module column.
///
/// The HUD's frame is always derived from its saved placement (display, anchor corner, offset) and its
/// current size, so resizes, Dock and resolution changes, and display disconnects all follow one rule.
/// Only a drag writes the placement; automatic moves never do.
@MainActor
public final class HUDController {
    public let panel = HUDPanel()
    public let container = HUDContainerView(frame: .zero)

    /// The visibility the user last chose. The panel may still be fading toward it.
    public private(set) var wantsVisible = false
    /// Makes the HUD's right-click menu; the app sets it to the menu bar item's menu.
    public var makeContextMenu: (() -> NSMenu?)? {
        didSet { container.makeContextMenu = makeContextMenu }
    }

    private let settings: HUDSettingsStore
    private let screens: any ScreenProviding
    private let displayOptions: any DisplayOptionsProviding
    private let animates: Bool
    private let animationCompletions: any AnimationCompletionScheduling
    private var layoutUpdateDepth = 0
    private var needsLayout = false
    private var storeObserver: UUID?
    private var modules: [any HUDModule] = []
    private var visibilityGeneration = 0
    private var moveGeneration = 0
    private var hasShown = false
    private var dragStart: (pointer: CGPoint, origin: CGPoint)?
    private var screenObserver: (any NSObjectProtocol)?

    /// - Parameter animates: `false` applies fades, resizes, and settles instantly; used by tests.
    public init(
        settings: HUDSettingsStore,
        screens: any ScreenProviding,
        displayOptions: any DisplayOptionsProviding,
        animates: Bool = true,
        animationCompletions: any AnimationCompletionScheduling = DispatchAnimationCompletions()
    ) {
        self.settings = settings
        self.screens = screens
        self.displayOptions = displayOptions
        self.animates = animates
        self.animationCompletions = animationCompletions
        container.autoresizingMask = [.width, .height]
        panel.contentView = container
        container.onDrag = { [weak self] phase, pointer in
            switch phase {
            case .began: self?.beginDrag(at: pointer)
            case .moved: self?.drag(to: pointer)
            case .ended: self?.endDrag(at: pointer)
            }
        }
    }

    isolated deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let storeObserver { settings.removeObserver(storeObserver) }
    }

    public func start() {
        guard storeObserver == nil else { return }
        relayout(animated: false)
        applyAppearance()

        storeObserver = settings.addObserver { [weak self] change in self?.settingsDidChange(change) }
        displayOptions.onChange = { [weak self] in self?.applyAppearance() }
        // Display connections, resolution, Dock, and menu bar changes all arrive here.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout(animated: false) }
        }

        applyVisibility(settings.isHUDVisible)
    }

    /// Shows or hides the HUD with a fade and persists the choice.
    public func setVisible(_ visible: Bool) {
        settings.isHUDVisible = visible
        if storeObserver == nil { applyVisibility(visible) }
    }

    /// Replaces the module column, in display order, and resizes the HUD to fit.
    public func setModules(_ modules: [any HUDModule]) {
        for module in self.modules { module.onSizeChange = nil }
        self.modules = modules
        for module in modules {
            module.onSizeChange = { [weak self] in self?.relayout(animated: true) }
        }
        relayout(animated: true)
    }

    // MARK: - Layout

    /// Module forms and selection may change together; defer their size callbacks to one final layout.
    func withLayoutUpdate(_ update: () -> Void) {
        layoutUpdateDepth += 1
        update()
        layoutUpdateDepth -= 1
        if layoutUpdateDepth == 0, needsLayout {
            needsLayout = false
            relayout(animated: true)
        }
    }

    private func columnLayout(on display: DisplayInfo) -> HUDColumnLayout {
        HUDLayout.column(
            moduleSizes: modules.map { CGSize(width: $0.width, height: $0.height) },
            usableHeight: display.usableArea.height)
    }

    /// Places the HUD from its saved placement at its current size: on its own display while connected,
    /// otherwise on the main display at the same corner and offset.
    func relayout(animated: Bool) {
        guard layoutUpdateDepth == 0 else {
            needsLayout = true
            return
        }
        guard let display = PlacementGeometry.display(for: settings.placement, among: screens.displays) else {
            return
        }
        let layout = columnLayout(on: display)
        container.setModules(modules, visibleCount: layout.visibleModuleCount)
        let placement = settings.placement ?? .firstLaunch(on: display)
        let duration = animated ? HUDMotion.resizeDuration(reduceMotion: displayOptions.reduceMotion) : 0
        move(to: PlacementGeometry.frame(for: placement, size: layout.size, on: display), duration: duration)
    }

    /// Moves or resizes the panel with an ease-out over `duration`; zero applies it at once.
    private func move(to target: CGRect, duration: TimeInterval) {
        // Every move supersedes an unfinished one and its delayed fallback, even when the panel already reports the
        // target or the move is instant; otherwise the older animation would carry on to its own target.
        moveGeneration += 1
        let generation = moveGeneration
        cancelMoveAnimation()
        guard target != panel.frame else { return }
        guard animates, duration > 0, panel.isVisible else {
            panel.setFrame(target, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }
        // Window animations stall while the display sleeps; make sure the latest move still lands.
        afterAnimation(duration) { [weak self] in
            guard let self, generation == self.moveGeneration, self.panel.frame != target else { return }
            self.panel.setFrame(target, display: true)
        }
    }

    /// Stops an in-flight frame animation where it is. A plain `setFrame` does not: the animation keeps running.
    private func cancelMoveAnimation() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().setFrame(panel.frame, display: true)
        }
    }

    /// Runs `action` on the main actor shortly after an animation of `duration` should have finished.
    private func afterAnimation(_ duration: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        animationCompletions.schedule(after: duration + 0.1, action)
    }

    // MARK: - Dragging

    /// Pointer locations are in global screen coordinates.
    func beginDrag(at pointer: CGPoint) {
        // A user move supersedes any resize/settle and its delayed fallback, even when this drop will need
        // no new animation. Otherwise the earlier target can undo the drag after it has been saved.
        moveGeneration += 1
        cancelMoveAnimation()
        dragStart = (pointer: pointer, origin: panel.frame.origin)
    }

    func drag(to pointer: CGPoint) {
        guard let dragStart else { return }
        panel.setFrameOrigin(
            CGPoint(
                x: dragStart.origin.x + pointer.x - dragStart.pointer.x,
                y: dragStart.origin.y + pointer.y - dragStart.pointer.y))
    }

    /// Settles the HUD on the display under the pointer, with magnetism and containment, and saves the
    /// resulting placement.
    func endDrag(at pointer: CGPoint) {
        drag(to: pointer)
        dragStart = nil
        guard let display = PlacementGeometry.display(at: pointer, among: screens.displays) else { return }
        let layout = columnLayout(on: display)
        container.setModules(modules, visibleCount: layout.visibleModuleCount)
        let dropped = CGRect(origin: panel.frame.origin, size: layout.size)
        let settled = PlacementGeometry.settle(dropped, on: display)
        settings.placement = PlacementGeometry.placement(for: settled, on: display)
        move(to: settled, duration: HUDMotion.settleDuration(reduceMotion: displayOptions.reduceMotion))
    }

    // MARK: - Appearance

    private func applyAppearance() {
        container.apply(
            HUDBackgroundStyle(
                reduceTransparency: displayOptions.reduceTransparency,
                increaseContrast: displayOptions.increaseContrast))
    }

    // MARK: - Visibility

    private func settingsDidChange(_ change: SettingsChange) {
        if change.previous.isHUDVisible != change.current.isHUDVisible {
            applyVisibility(change.current.isHUDVisible)
        }
    }

    private func applyVisibility(_ visible: Bool) {
        guard visible != wantsVisible else { return }
        wantsVisible = visible
        visibilityGeneration += 1
        let generation = visibilityGeneration
        let duration = HUDMotion.fadeDuration(reduceMotion: displayOptions.reduceMotion)

        if visible {
            if !panel.isVisible {
                panel.alphaValue = animates ? 0 : 1
                panel.orderFrontRegardless()
            }
            if !hasShown {
                hasShown = true
                let frame = panel.frame
                AppEnvironment.recordMarker(
                    "hud-frame", values: [frame.minX, frame.minY, frame.width, frame.height])
                AppEnvironment.recordMarker("hud-shown")
            }
        }
        let targetAlpha: CGFloat = visible ? 1 : 0
        guard animates else {
            panel.alphaValue = targetAlpha
            if !visible { panel.orderOut(nil) }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = targetAlpha
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.finishFade(generation: generation) }
        }
        // Window animations stall while the display sleeps; make sure the latest fade still completes.
        afterAnimation(duration) { [weak self] in self?.finishFade(generation: generation) }
    }

    /// Brings the panel to the end state of the latest fade. A later choice supersedes an earlier fade,
    /// so only the latest one may set the final alpha or order the panel out.
    private func finishFade(generation: Int) {
        guard generation == visibilityGeneration else { return }
        let targetAlpha: CGFloat = wantsVisible ? 1 : 0
        if panel.alphaValue != targetAlpha { panel.alphaValue = targetAlpha }
        if !wantsVisible, panel.isVisible { panel.orderOut(nil) }
    }
}
