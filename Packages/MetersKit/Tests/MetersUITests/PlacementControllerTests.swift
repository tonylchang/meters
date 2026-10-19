import AppKit
import MetersCore
import Testing

@testable import MetersUI

@MainActor
@Suite("HUD placement")
struct PlacementControllerTests {
    let temporary = TemporaryDefaults()
    let screens = FakeScreens(displays: [.main, .external])
    let options = FakeDisplayOptions()

    init() { _ = NSApplication.shared }

    func makeController(animates: Bool = false) -> (HUDController, HUDSettingsStore) {
        let settings = HUDSettingsStore(defaults: temporary.defaults)
        let controller = HUDController(
            settings: settings, screens: screens, displayOptions: options, animates: animates)
        controller.setModules([FakeModule("cpu", height: 18)])
        return (controller, settings)
    }

    /// Drags the HUD by `delta`, grabbing it 10 pt inside its bottom-left corner.
    func drag(_ controller: HUDController, by delta: CGVector) {
        let grab = CGPoint(x: controller.panel.frame.minX + 10, y: controller.panel.frame.minY + 10)
        controller.beginDrag(at: grab)
        controller.drag(to: CGPoint(x: grab.x + delta.dx / 2, y: grab.y + delta.dy / 2))
        controller.endDrag(at: CGPoint(x: grab.x + delta.dx, y: grab.y + delta.dy))
    }

    @Test("Dragging moves the HUD with the pointer; away from edges it stays where dropped")
    func freePlacement() {
        let (controller, settings) = makeController()
        controller.start()
        defer { controller.panel.orderOut(nil) }
        drag(controller, by: CGVector(dx: -600, dy: 300))
        #expect(controller.panel.frame == CGRect(x: 616, y: 382, width: 220, height: 34))
        #expect(settings.placement?.displayID == "main")
    }

    @Test("A drop near a corner snaps into it and saves a snapped placement")
    func snapToCorner() {
        let (controller, settings) = makeController()
        controller.start()
        defer { controller.panel.orderOut(nil) }
        drag(controller, by: CGVector(dx: -1190, dy: 770))
        #expect(controller.panel.frame == CGRect(x: 4, y: 854, width: 220, height: 34))
        #expect(
            settings.placement
                == HUDPlacement(displayID: "main", corner: .topLeft, offset: CGSize(width: 4, height: 12)))
    }

    @Test("Dropping on another display moves the HUD there and contains it")
    func crossDisplay() {
        let (controller, settings) = makeController()
        controller.start()
        defer { controller.panel.orderOut(nil) }
        // Pointer ends on the external display, with the HUD straddling the boundary.
        drag(controller, by: CGVector(dx: 240, dy: 200))
        #expect(settings.placement?.displayID == "external")
        #expect(controller.panel.frame.minX == DisplayInfo.external.usableArea.minX + HUDMetrics.sideInset)
        #expect(DisplayInfo.external.usableArea.contains(controller.panel.frame))
    }

    @Test("After a relaunch the HUD reappears on the same display at the same position")
    func relaunch() {
        let (first, _) = makeController()
        first.start()
        drag(first, by: CGVector(dx: 1000, dy: 400))
        let frame = first.panel.frame
        first.panel.orderOut(nil)

        let (relaunched, _) = makeController()
        relaunched.start()
        defer { relaunched.panel.orderOut(nil) }
        #expect(relaunched.panel.frame == frame)
    }

    @Test("Usable-area changes keep the HUD's offset from its corner; snapped stays snapped")
    func usableAreaChange() {
        let (controller, _) = makeController()
        controller.start()
        defer { controller.panel.orderOut(nil) }
        #expect(controller.panel.frame.minY == 82)
        // The Dock auto-hides: the usable area extends to the display's bottom edge.
        screens.displays[0] = DisplayInfo(
            id: "main", frame: DisplayInfo.main.frame, usableArea: CGRect(x: 0, y: 0, width: 1440, height: 900))
        controller.relayout(animated: false)
        #expect(controller.panel.frame == CGRect(x: 1216, y: 12, width: 220, height: 34))
    }

    @Test("Disconnecting the HUD's display moves it to the main display; reconnecting brings it back")
    func disconnectAndReconnect() {
        let (controller, settings) = makeController()
        controller.start()
        defer { controller.panel.orderOut(nil) }
        drag(controller, by: CGVector(dx: 1500, dy: 700))
        let onExternal = controller.panel.frame
        let placement = settings.placement
        #expect(placement?.displayID == "external")

        screens.displays = [.main]
        controller.relayout(animated: false)
        #expect(DisplayInfo.main.usableArea.contains(controller.panel.frame))
        #expect(settings.placement == placement)

        screens.displays = [.main, .external]
        controller.relayout(animated: false)
        #expect(controller.panel.frame == onExternal)
    }

    @Test("A drag while the saved display is absent wins over the old placement")
    func dragAfterDisconnect() {
        let (controller, settings) = makeController()
        controller.start()
        defer { controller.panel.orderOut(nil) }
        drag(controller, by: CGVector(dx: 1500, dy: 700))

        screens.displays = [.main]
        controller.relayout(animated: false)
        drag(controller, by: CGVector(dx: -600, dy: -300))
        let onMain = controller.panel.frame
        #expect(settings.placement?.displayID == "main")

        screens.displays = [.main, .external]
        controller.relayout(animated: false)
        #expect(controller.panel.frame == onMain)
    }

    @Test("With Reduce Motion on, the HUD settles at once")
    func reduceMotionSettle() {
        options.reduceMotion = true
        let (controller, _) = makeController(animates: true)
        controller.start()
        defer { controller.panel.orderOut(nil) }
        drag(controller, by: CGVector(dx: -1190, dy: 770))
        #expect(controller.panel.frame == CGRect(x: 4, y: 854, width: 220, height: 34))
    }

    @Test("The whole HUD surface starts a drag, even on the first click")
    func dragHandle() {
        let (controller, _) = makeController()
        let container = controller.container
        container.frame = CGRect(x: 0, y: 0, width: 220, height: 34)
        #expect(container.acceptsFirstMouse(for: nil))
        #expect(container.hitTest(CGPoint(x: 100, y: 17)) === container)
        #expect(container.hitTest(CGPoint(x: 300, y: 17)) == nil)
    }

    @Test(
        "Dropped near the screen's bottom beside the Dock, the HUD rests 4 pt above it and stays when the Dock grows"
    )
    func besideDock() {
        let (controller, settings) = makeController()
        controller.start()
        defer { controller.panel.orderOut(nil) }
        // From the default (x 1208, y 82), drag 70 pt down: 12 pt above the screen's bottom, inside the Dock strip.
        drag(controller, by: CGVector(dx: 0, dy: -70))
        #expect(controller.panel.frame == CGRect(x: 1216, y: 4, width: 220, height: 34))
        #expect(settings.placement?.screenEdgeAxis == .vertical)

        screens.displays[0] = DisplayInfo(
            id: "main", frame: DisplayInfo.main.frame, usableArea: CGRect(x: 0, y: 100, width: 1440, height: 800))
        controller.relayout(animated: false)
        #expect(controller.panel.frame.minY == 4)
    }
}
