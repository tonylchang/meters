import AppKit
import MetersCore
import Testing

@testable import MetersUI

@MainActor
@Suite("HUD context menu")
struct ContextMenuTests {
    let temporary = TemporaryDefaults()

    init() { _ = NSApplication.shared }

    /// A shown HUD whose right-click menu is the menu bar item's, with menus recorded instead of shown.
    final class Harness {
        let hud: HUDController
        let settings: HUDSettingsStore
        let menuBar: MenuBarController
        var shown: [(menu: NSMenu, event: NSEvent?, view: NSView)] = []

        @MainActor
        init(defaults: UserDefaults) {
            settings = HUDSettingsStore(defaults: defaults)
            hud = HUDController(
                settings: settings, screens: FakeScreens(), displayOptions: FakeDisplayOptions(), animates: false)
            menuBar = MenuBarController(hud: hud)
            hud.setModules([FakeModule("cpu", height: 18)])
            hud.start()
            let menuBar = self.menuBar
            hud.makeContextMenu = { menuBar.makeContextMenu() }
            hud.container.presentContextMenu = { [unowned self] menu, event, view in
                shown.append((menu, event, view))
            }
        }

        @MainActor
        func tearDown() {
            hud.panel.orderOut(nil)
            menuBar.remove()
        }

        @MainActor
        func event(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: CGPoint(x: 20, y: 20), modifierFlags: flags, timestamp: 0,
                windowNumber: hud.panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
    }

    @Test("A right-click or Control-click opens the menu bar menu's items at the pointer")
    func opening() throws {
        let harness = Harness(defaults: temporary.defaults)
        defer { harness.tearDown() }
        harness.hud.container.rightMouseDown(with: harness.event(.rightMouseDown))
        harness.hud.container.mouseDown(with: harness.event(.leftMouseDown, flags: .control))
        #expect(harness.shown.count == 2)
        let menu = try #require(harness.shown.first?.menu)
        #expect(menu.items.map(\.title) == ["Hide HUD", "Settings…", "", "Quit meters"])
        #expect(menu.items.map(\.isSeparatorItem) == [false, false, true, false])
        #expect(menu.items.map(\.keyEquivalent) == ["", ",", "", "q"])
        #expect(
            menu.items[1].keyEquivalentModifierMask == .command && menu.items[3].keyEquivalentModifierMask == .command)
        #expect(harness.shown.allSatisfy { $0.event != nil && $0.view === harness.hud.container })
    }

    @Test("Hide HUD hides and persists; Settings opens Settings; Quit terminates the app")
    func actions() throws {
        let settings = HUDSettingsStore(defaults: temporary.defaults)
        let hud = HUDController(
            settings: settings, screens: FakeScreens(), displayOptions: FakeDisplayOptions(), animates: false)
        var opened = 0
        let menuBar = MenuBarController(hud: hud, openSettings: { opened += 1 })
        defer {
            hud.panel.orderOut(nil)
            menuBar.remove()
        }
        hud.start()
        let menu = menuBar.makeContextMenu()
        menu.performActionForItem(at: 1)
        #expect(opened == 1)
        #expect(menu.items[3].action == #selector(NSApplication.terminate(_:)) && menu.items[3].target === NSApp)
        menu.performActionForItem(at: 0)
        #expect(!hud.wantsVisible && !hud.panel.isVisible && !settings.isHUDVisible)
    }

    @Test("Right-clicking or right-dragging never moves the HUD; a Control-click starts no drag")
    func noMovement() {
        let harness = Harness(defaults: temporary.defaults)
        defer { harness.tearDown() }
        let frame = harness.hud.panel.frame
        let placement = harness.settings.placement
        let container = harness.hud.container
        container.rightMouseDown(with: harness.event(.rightMouseDown))
        container.rightMouseDragged(with: harness.event(.rightMouseDragged))
        container.rightMouseUp(with: harness.event(.rightMouseUp))
        container.mouseDown(with: harness.event(.leftMouseDown, flags: .control))
        container.mouseDragged(with: harness.event(.leftMouseDragged))
        container.mouseUp(with: harness.event(.leftMouseUp))
        #expect(!container.isDragging)
        #expect(harness.hud.panel.frame == frame)
        #expect(harness.settings.placement == placement)
    }

    @Test("A right-click during a primary-button drag is ignored until the drag ends (Edge Cases)")
    func duringDrag() {
        let harness = Harness(defaults: temporary.defaults)
        defer { harness.tearDown() }
        let container = harness.hud.container
        container.mouseDown(with: harness.event(.leftMouseDown))
        container.rightMouseDown(with: harness.event(.rightMouseDown))
        #expect(harness.shown.isEmpty)
        container.mouseUp(with: harness.event(.leftMouseUp))
        container.rightMouseDown(with: harness.event(.rightMouseDown))
        #expect(harness.shown.count == 1)
    }

    @Test("VoiceOver's show-menu command on a row, or on the HUD, opens the same menu")
    func voiceOver() throws {
        let settings = HUDSettingsStore(defaults: temporary.defaults)
        let hud = HUDController(
            settings: settings, screens: FakeScreens(), displayOptions: FakeDisplayOptions(), animates: false)
        let menuBar = MenuBarController(hud: hud)
        let cpu = CPUModule(source: ScriptedTickSource([]), clusters: [], scheduler: ManualScheduler())
        hud.setModules([cpu])
        hud.start()
        defer {
            hud.panel.orderOut(nil)
            menuBar.remove()
        }
        hud.makeContextMenu = { menuBar.makeContextMenu() }
        var shown: [(NSMenu, NSView)] = []
        hud.container.presentContextMenu = { menu, _, view in shown.append((menu, view)) }
        let row = try #require(cpu.accessibilityElements.first)
        #expect(row.accessibilityPerformShowMenu())
        #expect(hud.container.accessibilityPerformShowMenu())
        #expect(shown.map(\.1) == [row, hud.container])
        #expect(shown.first?.0.items.first?.title == "Hide HUD")
    }

    @Test("Without a menu, a right-click shows nothing (HUD built without the app's menu)")
    func noMenu() {
        let settings = HUDSettingsStore(defaults: temporary.defaults)
        let hud = HUDController(
            settings: settings, screens: FakeScreens(), displayOptions: FakeDisplayOptions(), animates: false)
        var shown = 0
        hud.container.presentContextMenu = { _, _, _ in shown += 1 }
        #expect(!hud.container.showContextMenu(for: nil, in: hud.container))
        #expect(shown == 0)
    }
}
