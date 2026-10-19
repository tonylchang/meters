import AppKit
import MetersCore
import Testing

@testable import MetersUI

@MainActor
@Suite("HUD panel")
struct HUDPanelTests {
    init() { _ = NSApplication.shared }

    @Test("The panel floats above standard windows and never takes focus")
    func focusAndLevel() {
        let panel = HUDPanel()
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.styleMask.contains(.borderless))
        #expect(!panel.styleMask.contains(.titled))
        #expect(panel.level == .floating)
        #expect(panel.level.rawValue > NSWindow.Level.normal.rawValue)
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(!panel.hidesOnDeactivate)
    }

    @Test("The panel joins every Space and fullscreen app, stays put, and skips window cycling")
    func spacesAndCycling() {
        let behavior = HUDPanel().collectionBehavior
        #expect(behavior.contains(.canJoinAllSpaces))
        #expect(behavior.contains(.fullScreenAuxiliary))
        #expect(behavior.contains(.stationary))
        #expect(behavior.contains(.ignoresCycle))
    }

    @Test("The panel is chrome-free and transparent, without a window shadow")
    func chrome() {
        let panel = HUDPanel()
        #expect(!panel.isOpaque)
        #expect(panel.backgroundColor == .clear)
        #expect(!panel.hasShadow)
        // Dragging is the container's job, not the window server's.
        #expect(!panel.isMovableByWindowBackground)
    }
}

@MainActor
@Suite("HUD container")
struct HUDContainerTests {
    @Test("Rounded 12 pt corners over a translucent material that stays active")
    func appearance() {
        let container = HUDContainerView(frame: CGRect(x: 0, y: 0, width: 220, height: 50))
        #expect(container.layer?.cornerRadius == 12)
        #expect(container.materialView.state == .active)
        #expect(container.materialView.blendingMode == .behindWindow)
        #expect(!container.materialView.isHidden)
    }

    @Test("Reduce Transparency hides the material; the hairline border becomes 1 pt with Increase Contrast")
    func accessibilityDisplayStyles() {
        let container = HUDContainerView(frame: CGRect(x: 0, y: 0, width: 220, height: 50))
        container.apply(HUDBackgroundStyle(reduceTransparency: true, increaseContrast: true))
        container.updateLayer()
        #expect(container.materialView.isHidden)
        #expect(container.layer?.backgroundColor != nil)
        #expect(container.layer?.borderWidth == 1)

        container.apply(HUDBackgroundStyle(reduceTransparency: false, increaseContrast: false))
        container.updateLayer()
        #expect(!container.materialView.isHidden)
        #expect(container.layer?.backgroundColor == nil)
        #expect(container.layer?.borderWidth == 0.5)
    }

    @Test("Modules stack top to bottom in order, 4 pt apart, inside the padding")
    func columnOrder() {
        let container = HUDContainerView(frame: CGRect(x: 0, y: 0, width: 220, height: 56))
        let modules = [FakeModule("cpu", height: 18), FakeModule("memory", height: 18)]
        container.setModules(modules, visibleCount: 2)
        container.layout()
        #expect(modules[0].view.frame == CGRect(x: 8, y: 8, width: 204, height: 18))
        #expect(modules[1].view.frame == CGRect(x: 8, y: 30, width: 204, height: 18))
    }

    @Test("VoiceOver sees one group labeled meters with the visible modules in order")
    func accessibilityGroup() {
        let container = HUDContainerView(frame: .zero)
        let modules = [FakeModule("cpu", height: 18), FakeModule("memory", height: 18), FakeModule("net", height: 18)]
        container.setModules(modules, visibleCount: 2)
        #expect(container.isAccessibilityElement())
        #expect(container.accessibilityRole() == .group)
        #expect(container.accessibilityLabel() == "meters")
        let children = container.accessibilityChildren() as? [NSView]
        #expect(children == [modules[0].view, modules[1].view])
    }

    @Test("VoiceOver's pointer reaches the module under it, not just the group")
    func accessibilityHitTest() {
        _ = NSApplication.shared
        let panel = HUDPanel()
        let container = HUDContainerView(frame: .zero)
        panel.contentView = container
        panel.setFrame(CGRect(x: 100, y: 100, width: 220, height: 56), display: false)
        let modules = [FakeModule("cpu", height: 18), FakeModule("memory", height: 18)]
        container.setModules(modules, visibleCount: 2)
        container.layout()
        // Screen coordinates rise upward: the first module sits 8 to 26 pt below the HUD's top edge, the
        // second 30 to 48 pt.
        #expect(container.accessibilityHitTest(CGPoint(x: 150, y: 156 - 17)) as? NSView === modules[0].view)
        #expect(container.accessibilityHitTest(CGPoint(x: 150, y: 156 - 35)) as? NSView === modules[1].view)
        #expect(container.accessibilityHitTest(CGPoint(x: 150, y: 156 - 3)) as? NSView === container)
        #expect(panel.accessibilityTitle() == "meters")
    }
}

@MainActor
@Suite("HUD controller")
struct HUDControllerTests {
    let temporary = TemporaryDefaults()
    let screens = FakeScreens()
    let options = FakeDisplayOptions()

    init() { _ = NSApplication.shared }

    func makeController(animates: Bool = false) -> (HUDController, HUDSettingsStore) {
        let settings = HUDSettingsStore(defaults: temporary.defaults)
        let controller = HUDController(
            settings: settings, screens: screens, displayOptions: options, animates: animates)
        return (controller, settings)
    }

    @Test("On launch the HUD appears at the default corner, as wide as its modules: none here")
    func launch() {
        let (controller, _) = makeController()
        controller.start()
        defer { controller.panel.orderOut(nil) }
        #expect(controller.panel.isVisible)
        #expect(controller.panel.alphaValue == 1)
        #expect(controller.panel.frame == CGRect(x: 1440 - 4 - 16, y: 70 + 12, width: 16, height: 16))
    }

    @Test("Adding modules grows the HUD away from its bottom-right anchor")
    func growsFromAnchor() {
        let (controller, _) = makeController()
        controller.start()
        defer { controller.panel.orderOut(nil) }
        controller.setModules([FakeModule("cpu", height: 18), FakeModule("memory", height: 18)])
        #expect(controller.panel.frame == CGRect(x: 1216, y: 82, width: 220, height: 56))
    }

    @Test("A top-left HUD keeps its top-left edges when it grows")
    func topLeftAnchor() {
        let (controller, _) = makeController()
        controller.start()
        defer { controller.panel.orderOut(nil) }
        // Drag from the bottom-right default into the top-left corner.
        controller.beginDrag(at: CGPoint(x: 1430, y: 90))
        controller.endDrag(at: CGPoint(x: 1430 - 1416, y: 90 + 790))
        #expect(controller.panel.frame == CGRect(x: 4, y: 872, width: 16, height: 16))
        controller.setModules([FakeModule("cpu", height: 30)])
        #expect(controller.panel.frame == CGRect(x: 4, y: 842, width: 220, height: 46))
    }

    @Test("A module's height or width change resizes the HUD")
    func resizesOnChange() {
        let (controller, _) = makeController()
        controller.start()
        defer { controller.panel.orderOut(nil) }
        let module = FakeModule("cpu", height: 18)
        controller.setModules([module])
        module.height = 40
        #expect(controller.panel.frame.height == 56)

        module.width = 284
        #expect(controller.panel.frame == CGRect(x: 1436 - 300, y: 82, width: 300, height: 56))
    }

    @Test("Resizes apply at once with Reduce Motion on, even when animations are enabled")
    func reduceMotionResize() {
        options.reduceMotion = true
        let (controller, _) = makeController(animates: true)
        controller.start()
        defer { controller.panel.orderOut(nil) }
        controller.setModules([FakeModule("cpu", height: 18)])
        #expect(controller.panel.frame.height == 34)
    }

    @Test("Modules that do not fit the display are not shown")
    func overflow() {
        // Cap: 104 - 2 * 12 = 80, which fits two 30 pt modules 4 pt apart plus padding.
        screens.displays = FakeScreens(usableArea: CGRect(x: 0, y: 0, width: 1440, height: 104)).displays
        let (controller, _) = makeController()
        controller.start()
        defer { controller.panel.orderOut(nil) }
        let modules = [FakeModule("a", height: 30), FakeModule("b", height: 30), FakeModule("c", height: 30)]
        controller.setModules(modules)
        #expect(controller.panel.frame.height == 80)
        #expect(controller.container.visibleModuleViews == [modules[0].view, modules[1].view])
        #expect(modules[2].view.superview == nil)
    }

    @Test("Hiding persists: a HUD hidden at quit stays hidden at the next launch")
    func visibilityPersists() {
        let (controller, settings) = makeController()
        controller.start()
        controller.setVisible(false)
        #expect(!settings.isHUDVisible)
        #expect(!controller.panel.isVisible)

        let (relaunched, _) = makeController()
        relaunched.start()
        #expect(!relaunched.wantsVisible)
        #expect(!relaunched.panel.isVisible)

        relaunched.setVisible(true)
        defer { relaunched.panel.orderOut(nil) }
        #expect(relaunched.panel.isVisible)
        settings.reload()
        #expect(settings.isHUDVisible)
    }

    @Test("Animated fades reach their end state, even if the display is asleep")
    func fadesComplete() async throws {
        let (controller, _) = makeController(animates: true)
        controller.start()
        defer { controller.panel.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(400))
        #expect(controller.panel.alphaValue == 1)

        controller.setVisible(false)
        try await Task.sleep(for: .milliseconds(400))
        #expect(controller.panel.alphaValue == 0)
        #expect(!controller.panel.isVisible)

        controller.setVisible(true)
        try await Task.sleep(for: .milliseconds(400))
        #expect(controller.panel.alphaValue == 1)
        #expect(controller.panel.isVisible)
    }

    @Test("Accessibility display settings apply live")
    func liveDisplayOptions() {
        let (controller, _) = makeController()
        controller.start()
        defer { controller.panel.orderOut(nil) }
        options.reduceTransparency = true
        #expect(controller.container.backgroundStyle.fill == .opaque)
        options.increaseContrast = true
        #expect(controller.container.backgroundStyle.borderWidth == 1)
    }
}
