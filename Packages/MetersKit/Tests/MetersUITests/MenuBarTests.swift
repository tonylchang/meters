import AppKit
import Foundation
import MetersCore
import Testing

@testable import MetersUI

@MainActor
@Suite("Menu bar item")
struct MenuBarTests {
    let temporary = TemporaryDefaults()

    init() { _ = NSApplication.shared }

    func makeHUD() -> (HUDController, HUDSettingsStore) {
        let settings = HUDSettingsStore(defaults: temporary.defaults)
        let hud = HUDController(
            settings: settings, screens: FakeScreens(), displayOptions: FakeDisplayOptions(), animates: false)
        return (hud, settings)
    }

    @Test("Menu: show/hide item, Settings with Command-comma, separator, then Quit meters with Command-Q")
    func menuModel() {
        #expect(
            MenuBarMenu.items(hudVisible: true) == [
                .toggleHUD(title: "Hide HUD"), .settings(title: "Settings…", keyEquivalent: ","), .separator,
                .quit(title: "Quit meters", keyEquivalent: "q"),
            ])
        #expect(MenuBarMenu.items(hudVisible: false).first == .toggleHUD(title: "Show HUD"))
    }

    @Test("The icon is a monochrome template gauge symbol announced as meters")
    func icon() throws {
        let (hud, _) = makeHUD()
        let controller = MenuBarController(hud: hud)
        defer { controller.remove() }
        let button = try #require(controller.statusItem.button)
        let image = try #require(button.image)
        #expect(image.isTemplate)
        #expect(NSImage(systemSymbolName: MenuBarController.symbolName, accessibilityDescription: nil) != nil)
        #expect(button.accessibilityLabel() == "meters")
    }

    @Test("The label reflects the HUD's state when the menu opens")
    func labelAtOpen() {
        let (hud, _) = makeHUD()
        hud.start()
        defer { hud.panel.orderOut(nil) }
        let controller = MenuBarController(hud: hud)
        defer { controller.remove() }
        #expect(controller.menu.items.first?.title == "Hide HUD")

        hud.setVisible(false)
        controller.menuNeedsUpdate(controller.menu)
        #expect(controller.menu.items.first?.title == "Show HUD")
        #expect(controller.menu.items.map(\.isSeparatorItem) == [false, false, true, false])
    }

    @Test("Choosing the item hides or shows the HUD and persists the choice")
    func toggle() {
        let (hud, settings) = makeHUD()
        hud.start()
        defer { hud.panel.orderOut(nil) }
        let controller = MenuBarController(hud: hud)
        defer { controller.remove() }

        controller.toggleHUD()
        #expect(!hud.wantsVisible)
        #expect(!hud.panel.isVisible)
        #expect(!settings.isHUDVisible)
        #expect(!HUDSettingsStore(defaults: UserDefaults(suiteName: temporary.suiteName)!).isHUDVisible)

        controller.toggleHUD()
        #expect(hud.panel.isVisible)
        #expect(settings.isHUDVisible)
    }

    @Test("Quit terminates the app from the menu with Command-Q")
    func quitItem() throws {
        let (hud, _) = makeHUD()
        let controller = MenuBarController(hud: hud)
        defer { controller.remove() }
        let quit = try #require(controller.menu.items.last)
        #expect(quit.title == "Quit meters")
        #expect(quit.keyEquivalent == "q")
        #expect(quit.keyEquivalentModifierMask == .command)
        #expect(quit.action == #selector(NSApplication.terminate(_:)))
        #expect(quit.target === NSApp)
    }

    @Test("A reopen request for this instance's domain shows the HUD")
    func reopenRequest() async throws {
        let domain = "net.1x0.meters.tests.\(UUID().uuidString)"
        try await confirmation { reopened in
            let listener = ReopenListener(domain: domain) { reopened() }
            ReopenRequest.post(domain: domain + ".other")
            ReopenRequest.post(domain: domain)
            try await Task.sleep(for: .milliseconds(500))
            withExtendedLifetime(listener) {}
        }
    }

    @Test("Choosing Settings opens the Settings window")
    func settingsItem() throws {
        let (hud, _) = makeHUD()
        var opened = 0
        let controller = MenuBarController(hud: hud, openSettings: { opened += 1 })
        defer { controller.remove() }
        controller.menuNeedsUpdate(controller.menu)
        let item = try #require(controller.menu.items.first { $0.title == "Settings…" })
        #expect(item.keyEquivalent == ",")
        #expect(item.keyEquivalentModifierMask == .command)
        #expect(controller.menu.items.firstIndex(of: item) == 1)
        _ = item.target?.perform(item.action, with: item)
        #expect(opened == 1)
    }
}
