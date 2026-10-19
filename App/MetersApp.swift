import MetersCore
import MetersUI
import SwiftUI

@main
struct MetersApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The HUD, the menu bar item, and the Settings window are AppKit objects owned by AppDelegate. This
        // empty scene only satisfies SwiftUI; its Settings command opens meters's own window instead.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { appDelegate.showSettings() }
                        .keyboardShortcut(",")
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var instanceLock: InstanceLock?
    private var hud: HUDController?
    private var lineup: ModuleLineup?
    private var settingsWindow: SettingsWindowController?
    private var menuBar: MenuBarController?
    private var reopenListener: ReopenListener?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One instance per settings domain: a second launch asks the running one to show its HUD.
        let domain = ReopenRequest.domain()
        guard let instanceLock = InstanceLock(domain: domain) else {
            ReopenRequest.post(domain: domain)
            NSApp.terminate(nil)
            return
        }
        self.instanceLock = instanceLock

        let settings = HUDSettingsStore(defaults: AppEnvironment.settingsDefaults())
        let hud = HUDController(settings: settings, screens: SystemScreens(), displayOptions: SystemDisplayOptions())
        // The user's modules, from Settings. Registered before the HUD opens,
        // so it appears at its full height.
        // Read once and shared: the power sources and the CPU clusters in the device tree.
        let capabilities = SystemCapabilities.current()
        let lineup = ModuleLineup(settings: settings, hud: hud, capabilities: capabilities)
        lineup.start()
        hud.start()
        settingsWindow = SettingsWindowController(settings: settings, capabilities: capabilities)
        let menuBar = MenuBarController(hud: hud, openSettings: { [weak self] in self?.showSettings() })
        // The HUD's right-click menu is the menu bar item's menu.
        hud.makeContextMenu = { [weak menuBar] in menuBar?.makeContextMenu() }
        self.menuBar = menuBar
        reopenListener = ReopenListener(domain: domain) { [weak self] in self?.showHUD() }
        self.hud = hud
        self.lineup = lineup
    }

    func showSettings() {
        settingsWindow?.show()
    }

    // Opening meters while it runs (Finder, Spotlight, `open -a meters`) brings back a hidden HUD.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showHUD()
        return false
    }

    private func showHUD() {
        guard let hud, !hud.wantsVisible else { return }
        hud.setVisible(true)
    }
}
