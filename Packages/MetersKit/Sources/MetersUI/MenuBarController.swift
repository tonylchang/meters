import AppKit
import MetersCore

/// The menu's contents for a given HUD state. The HUD's right-click menu has
/// the same contents.
public enum MenuBarMenu {
    public enum Item: Equatable, Sendable {
        case toggleHUD(title: String)
        case settings(title: String, keyEquivalent: String)
        case separator
        case quit(title: String, keyEquivalent: String)
    }

    public static func items(hudVisible: Bool) -> [Item] {
        [
            .toggleHUD(title: hudVisible ? "Hide HUD" : "Show HUD"),
            .settings(title: "Settings…", keyEquivalent: ","),
            .separator,
            .quit(title: "Quit \(AppIdentity.displayName)", keyEquivalent: "q"),
        ]
    }
}

/// The menu bar item: a static gauge icon whose menu shows or hides the HUD, opens Settings, and quits the app
///. It never displays metrics or state. It also builds the HUD's right-click
/// menu, so both menus share one definition and one set of actions.
@MainActor
public final class MenuBarController: NSObject, NSMenuDelegate {
    /// From the SF Symbols gauge-with-needle family; chosen by the user on Sep 26, 2026.
    public static let symbolName = "gauge.open.with.lines.needle.33percent"

    public let statusItem: NSStatusItem
    let menu = NSMenu()
    private let hud: HUDController
    private let statusBar: NSStatusBar
    private let openSettings: @MainActor () -> Void

    public init(
        hud: HUDController, statusBar: NSStatusBar = .system, openSettings: @escaping @MainActor () -> Void = {}
    ) {
        self.hud = hud
        self.statusBar = statusBar
        self.openSettings = openSettings
        statusItem = statusBar.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        let image = NSImage(
            systemSymbolName: Self.symbolName, accessibilityDescription: AppIdentity.displayName)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.setAccessibilityLabel(AppIdentity.displayName)

        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
        // For `make smoke`: the window server does not reliably list menu bar items, so the app reports
        // that its item exists, is visible, and uses a template image.
        AppEnvironment.recordMarker(
            "status-item", values: [statusItem.isVisible ? 1 : 0, image?.isTemplate == true ? 1 : 0])
    }

    /// Removes the item from the menu bar. Used by tests; the app keeps its item for its whole life.
    public func remove() {
        statusBar.removeStatusItem(statusItem)
    }

    // The label must reflect the HUD's state at the moment the menu opens.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    func rebuildMenu() {
        fill(menu)
    }

    /// A new menu with the menu bar menu's items, for the HUD's right-click menu.
    public func makeContextMenu() -> NSMenu {
        let contextMenu = NSMenu()
        contextMenu.autoenablesItems = false
        fill(contextMenu)
        return contextMenu
    }

    private func fill(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in MenuBarMenu.items(hudVisible: hud.wantsVisible) {
            switch item {
            case .toggleHUD(let title):
                let menuItem = NSMenuItem(title: title, action: #selector(toggleHUD), keyEquivalent: "")
                menuItem.target = self
                menu.addItem(menuItem)
            case .settings(let title, let keyEquivalent):
                let menuItem = NSMenuItem(title: title, action: #selector(showSettings), keyEquivalent: keyEquivalent)
                menuItem.keyEquivalentModifierMask = .command
                menuItem.target = self
                menu.addItem(menuItem)
            case .separator:
                menu.addItem(.separator())
            case .quit(let title, let keyEquivalent):
                let menuItem = NSMenuItem(
                    title: title, action: #selector(NSApplication.terminate(_:)), keyEquivalent: keyEquivalent)
                menuItem.keyEquivalentModifierMask = .command
                menuItem.target = NSApp
                menu.addItem(menuItem)
            }
        }
    }

    @objc func toggleHUD() {
        hud.setVisible(!hud.wantsVisible)
    }

    @objc func showSettings() {
        openSettings()
    }
}
