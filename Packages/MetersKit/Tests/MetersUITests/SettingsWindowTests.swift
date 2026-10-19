import AppKit
import MetersCore
import SwiftUI
import Testing

@testable import MetersUI

@MainActor
@Suite("Settings window")
struct SettingsWindowTests {
    let temporary = TemporaryDefaults()

    init() { _ = NSApplication.shared }

    static let laptop = SystemCapabilities(hasBattery: true, cpuClusters: 2)

    func makeModel(
        _ capabilities: SystemCapabilities = laptop, loginItem: FakeLoginItemService = FakeLoginItemService()
    ) -> (SettingsModel, HUDSettingsStore) {
        let store = HUDSettingsStore(defaults: temporary.defaults)
        return (SettingsModel(store: store, capabilities: capabilities, loginItem: loginItem), store)
    }

    @Test("Defaults: CPU, Memory, Network on; smallest forms; Standard; Modules tab")
    func defaults() {
        let (model, _) = makeModel()
        #expect(
            model.entries.map(\.id) == [
                .cpu, .memory, .network, .gpu, .disk, .battery, .thermal, .swap, .freeSpace,
            ])
        #expect(model.entries.map(\.isOn) == [true, true, true] + Array(repeating: false, count: 6))
        #expect(model.cpuForm == .total && model.networkForm == .oneRow && model.diskForm == .oneRow)
        #expect(model.graphStyle == .sparklines && model.tab == .modules)
        #expect(ModuleID.allCases.allSatisfy { model.isAvailable($0) && model.unavailableNote($0) == nil })
    }

    @Test("Without a battery, Battery is greyed out with No battery and never shown")
    func noBattery() {
        let (model, store) = makeModel(SystemCapabilities(hasBattery: false, cpuClusters: 2))
        #expect(!model.isAvailable(.battery) && !model.canToggle(.battery))
        #expect(model.unavailableNote(.battery) == "No battery")
        model.setOn(.battery, true)
        #expect(store.modules.first { $0.id == .battery }?.isOn == false)
        // A stored selection that includes it does not count it.
        store.modules = [ModuleEntry(.battery, isOn: true), ModuleEntry(.cpu, isOn: true)]
        store.reload()
        #expect(store.state.resolved(for: model.capabilities).shown == [.cpu])
        #expect(!model.canToggle(.cpu))
    }

    @Test("The CPU form reaches the store, and every checked module still shows")
    func cpuForm() {
        let (model, store) = makeModel()
        model.setCPUForm(.clusters)
        #expect(store.cpuForm == .clusters)
        #expect(store.state.resolved(for: model.capabilities).shown == [.cpu, .memory, .network])
    }

    @Test("Checking and unchecking reaches the store; the last checked module stays on")
    func toggling() {
        let (model, store) = makeModel()
        model.setOn(.gpu, true)
        #expect(store.modules.first { $0.id == .gpu }?.isOn == true)
        model.setOn(.cpu, false)
        model.setOn(.memory, false)
        model.setOn(.network, false)
        #expect(!model.canToggle(.gpu))
        model.setOn(.gpu, false)
        #expect(store.modules.filter(\.isOn).map(\.id) == [.gpu])
    }

    @Test("Reordering by drag or by Move Up and Move Down reaches the store")
    func reordering() {
        let (model, store) = makeModel()
        model.move(fromOffsets: [3], toOffset: 0)
        #expect(store.modules.map(\.id).prefix(5) == [.gpu, .cpu, .memory, .network, .disk])
        model.moveDown(.gpu)
        #expect(store.modules.map(\.id).prefix(5) == [.cpu, .gpu, .memory, .network, .disk])
        model.moveUp(.disk)
        #expect(store.modules.map(\.id).prefix(5) == [.cpu, .gpu, .memory, .disk, .network])
        model.moveUp(.cpu)
        #expect(store.modules.first?.id == .cpu)
        model.moveDown(.freeSpace)
        #expect(store.modules.last?.id == .freeSpace)
    }

    @Test("Forms reach the store; with every module in its largest form, the HUD shows them all")
    func forms() {
        let (model, store) = makeModel()
        for id in ModuleID.allCases { model.setOn(id, true) }
        model.setForm(.network, .twoRows)
        model.setForm(.disk, .twoRows)
        model.setCPUForm(.clusters)
        #expect(store.networkForm == .twoRows && store.diskForm == .twoRows && store.cpuForm == .clusters)
        #expect(store.state.resolved(for: model.capabilities).shown == model.entries.map(\.id))
    }

    @Test("A Rows value saved by an earlier version is ignored (Edge Cases)")
    func savedRowsIgnored() {
        let (model, store) = makeModel(SystemCapabilities(hasBattery: true, cpuClusters: 3))
        temporary.defaults.set(1, forKey: "hudRows")
        store.cpuForm = .clusters
        let reopened = HUDSettingsStore(defaults: temporary.defaults)
        #expect(reopened.state.resolved(for: model.capabilities).shown == [.cpu, .memory, .network])
    }

    @Test("The window reopens on the tab last used, and follows outside changes")
    func tabAndOutsideChanges() async {
        let (model, store) = makeModel()
        model.tab = .hud
        #expect(SettingsModel(store: store, loginItem: FakeLoginItemService()).tab == .hud)
        UserDefaults(suiteName: temporary.suiteName)?.set("gauges", forKey: HUDSettingsStore.graphsKey)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(model.graphStyle == .gauges)
    }

    @Test("A titled, closable, fixed-size window, reused when shown again")
    func window() throws {
        let (_, store) = makeModel()
        let controller = SettingsWindowController(
            settings: store, capabilities: Self.laptop, loginItem: FakeLoginItemService())
        controller.show()
        let window = try #require(controller.window)
        defer { window.close() }
        // Three tabs in the toolbar, General first, each with an icon.
        let tabs = try #require(window.contentViewController as? SettingsTabViewController)
        #expect(tabs.tabStyle == .toolbar && window.toolbarStyle == .preference)
        #expect(tabs.tabViewItems.map(\.label) == ["General", "Modules", "Thresholds", "HUD"])
        #expect(tabs.tabViewItems.allSatisfy { $0.image != nil })
        #expect(window.toolbar?.items.count == 4)
        #expect(window.title == "meters Settings")
        #expect(window.styleMask.contains(.titled) && window.styleMask.contains(.closable))
        #expect(!window.styleMask.contains(.resizable))
        controller.show()
        #expect(controller.window === window)
    }

    @Test("The toolbar tabs and the model's tab follow each other; the title stays; the size never changes")
    func toolbarTabs() throws {
        let (_, store) = makeModel()
        let controller = SettingsWindowController(
            settings: store, capabilities: Self.laptop, loginItem: FakeLoginItemService())
        controller.show()
        let window = try #require(controller.window)
        defer { window.close() }
        let tabs = try #require(window.contentViewController as? SettingsTabViewController)
        #expect(tabs.selectedTabViewItemIndex == 1)
        let size = window.frame.size
        // A tab set by the model; the toolbar follows.
        controller.model.tab = .hud
        #expect(tabs.selectedTabViewItemIndex == 3)
        // Choosing a toolbar tab sets the model's tab, which persists.
        tabs.selectedTabViewItemIndex = 0
        #expect(controller.model.tab == .general && store.settingsTab == "general")
        #expect(window.title == "meters Settings")
        #expect(window.frame.size == size)
    }
}

extension SettingsWindowTests {
    static func subviews(of view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { subviews(of: $0) }
    }
}

@MainActor
@Suite("Launch at login")
struct LaunchAtLoginTests {
    let temporary = TemporaryDefaults()

    init() { _ = NSApplication.shared }

    func makeModel(_ loginItem: FakeLoginItemService) -> SettingsModel {
        SettingsModel(
            store: HUDSettingsStore(defaults: temporary.defaults), capabilities: SettingsWindowTests.laptop,
            loginItem: loginItem)
    }

    @Test("Off until checked; nothing is registered before then")
    func defaultOff() {
        let loginItem = FakeLoginItemService()
        let model = makeModel(loginItem)
        model.refreshLoginItem()
        #expect(!model.launchAtLogin && model.loginItemNote == nil)
        #expect(loginItem.state.withLock { $0.calls }.isEmpty)
    }

    @Test("Checking registers the login item and unchecking removes it, at once")
    func registerAndUnregister() {
        let loginItem = FakeLoginItemService()
        let model = makeModel(loginItem)
        model.setLaunchAtLogin(true)
        #expect(model.launchAtLogin && loginItem.status == .enabled)
        model.setLaunchAtLogin(false)
        #expect(!model.launchAtLogin && loginItem.status == .notRegistered)
        #expect(loginItem.state.withLock { $0.calls } == ["register", "unregister"])
    }

    @Test("The checkbox shows macOS's state, read when Settings is shown or becomes key")
    func followsSystemState() throws {
        let loginItem = FakeLoginItemService()
        let controller = SettingsWindowController(
            settings: HUDSettingsStore(defaults: temporary.defaults), capabilities: SettingsWindowTests.laptop,
            loginItem: loginItem)
        loginItem.state.withLock { $0.status = .enabled }
        controller.show()
        let window = try #require(controller.window)
        defer { window.close() }
        #expect(controller.model.launchAtLogin)
        // Switched off in System Settings while the window was in the background.
        loginItem.state.withLock { $0.status = .notRegistered }
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        #expect(!controller.model.launchAtLogin)
        #expect(loginItem.state.withLock { $0.calls }.isEmpty)
    }

    @Test("Needing approval: checked, with the approval note and Open Login Items")
    func needsApproval() {
        let loginItem = FakeLoginItemService()
        loginItem.state.withLock { $0.statusAfterRegister = .requiresApproval }
        let model = makeModel(loginItem)
        model.setLaunchAtLogin(true)
        #expect(model.launchAtLogin)
        #expect(model.loginItemNote?.text == "meters needs your approval to launch at login.")
        model.openLoginItems()
        #expect(loginItem.state.withLock { $0.calls } == ["register", "openSystemSettings"])
    }

    @Test("A failed change shows the system's state and the failure note, which clears on the next read")
    func failure() {
        let loginItem = FakeLoginItemService()
        loginItem.state.withLock { $0.fails = true }
        let model = makeModel(loginItem)
        model.setLaunchAtLogin(true)
        #expect(!model.launchAtLogin)
        #expect(model.loginItemNote?.text == "Couldn't change the login item. Try again, or open Login Items.")
        model.refreshLoginItem()
        #expect(model.loginItemNote == nil)
        model.setLaunchAtLogin(true)
        loginItem.state.withLock { $0.fails = false }
        model.setLaunchAtLogin(true)
        #expect(model.launchAtLogin && model.loginItemNote == nil)
    }
}

@MainActor
@Suite("Module lineup")
struct ModuleLineupTests {
    let temporary = TemporaryDefaults()

    init() { _ = NSApplication.shared }

    func makeLineup(
        _ capabilities: SystemCapabilities = SettingsWindowTests.laptop
    ) -> (ModuleLineup, HUDController, HUDSettingsStore, () -> [String: FakeModule]) {
        let settings = HUDSettingsStore(defaults: temporary.defaults)
        let hud = HUDController(
            settings: settings, screens: FakeScreens(), displayOptions: FakeDisplayOptions(), animates: false)
        var made: [String: FakeModule] = [:]
        let lineup = ModuleLineup(settings: settings, hud: hud, capabilities: capabilities) { id in
            let module = FakeModule(id.rawValue, height: id == .network && settings.networkForm == .twoRows ? 36 : 18)
            made[id.rawValue] = module
            return module
        }
        return (lineup, hud, settings, { made })
    }

    @Test("By default the HUD shows CPU, MEM, and NET, and only they sample (floating-hud module column)")
    func defaults() {
        let (lineup, hud, _, made) = makeLineup()
        lineup.apply()
        defer { hud.panel.orderOut(nil) }
        #expect(lineup.shown == [.cpu, .memory, .network])
        #expect(Set(made().keys) == ["cpu", "memory", "network"])
        #expect(made().values.allSatisfy { $0.starts == 1 })
        #expect(hud.container.visibleModuleViews.count == 3)
    }

    @Test("Changes in Settings add, remove, and reorder modules; modules that leave stop sampling")
    func changes() {
        let (lineup, hud, settings, made) = makeLineup()
        lineup.apply()
        defer { hud.panel.orderOut(nil) }
        settings.modules = [
            ModuleEntry(.gpu, isOn: true), ModuleEntry(.cpu, isOn: true), ModuleEntry(.memory, isOn: false),
            ModuleEntry(.network, isOn: false), ModuleEntry(.disk, isOn: false),
        ]
        lineup.apply()
        #expect(lineup.shown == [.gpu, .cpu])
        #expect(made()["memory"]?.stops == 1 && made()["network"]?.stops == 1)
        #expect(made()["gpu"]?.starts == 1 && made()["cpu"]?.starts == 1)
        #expect(hud.container.visibleModuleViews == [made()["gpu"]!.view, made()["cpu"]!.view])
    }

    @Test("Every checked module shows, in order, with no row limit")
    func everyCheckedModule() {
        let (lineup, hud, settings, _) = makeLineup()
        defer { hud.panel.orderOut(nil) }
        settings.modules = ModuleSelection.defaultEntries.map { ModuleEntry($0.id, isOn: true) }
        lineup.apply()
        #expect(lineup.shown == ModuleSelection.defaultEntries.map(\.id))
    }

    @Test("CPU's clusters form first still shows CPU and the modules after it")
    func neverEmpty() {
        let (lineup, hud, settings, _) = makeLineup()
        lineup.start()
        hud.start()
        defer { hud.panel.orderOut(nil) }
        let model = SettingsModel(
            store: settings, capabilities: SettingsWindowTests.laptop, loginItem: FakeLoginItemService())
        model.setCPUForm(.clusters)
        #expect(lineup.shown == [.cpu, .memory, .network])
        #expect(hud.container.visibleModuleViews.count == 3)
    }

    @Test("Without a battery, a checked Battery is skipped")
    func noBattery() {
        let (lineup, hud, settings, made) = makeLineup(SystemCapabilities(hasBattery: false, cpuClusters: 2))
        defer { hud.panel.orderOut(nil) }
        settings.modules = [
            ModuleEntry(.battery, isOn: true), ModuleEntry(.cpu, isOn: true), ModuleEntry(.thermal, isOn: true),
        ]
        lineup.apply()
        #expect(lineup.shown == [.cpu, .thermal])
        #expect(made()["battery"] == nil)
    }

    @Test("Switching Network's form resizes it in place")
    func formSwitch() {
        let settings = HUDSettingsStore(defaults: temporary.defaults)
        let hud = HUDController(
            settings: settings, screens: FakeScreens(), displayOptions: FakeDisplayOptions(), animates: false)
        let network = NetworkModule.network(source: ScriptedCounterSource([]), scheduler: ManualScheduler())
        let lineup = ModuleLineup(settings: settings, hud: hud) { id in
            id == .network ? network as any HUDModule : FakeModule(id.rawValue, height: 18)
        }
        lineup.apply()
        hud.start()
        defer { hud.panel.orderOut(nil) }
        #expect(network.height == 18)
        #expect(hud.panel.frame.height == 78)
        settings.networkForm = .twoRows
        lineup.apply()
        #expect(network.height == 36)
        #expect(network.accessibilityElements.count == 2)
        #expect(hud.panel.frame.height == 96)
    }

    @Test("Switching the CPU form resizes it in place, one row per cluster")
    func cpuFormSwitch() {
        let settings = HUDSettingsStore(defaults: temporary.defaults)
        let hud = HUDController(
            settings: settings, screens: FakeScreens(), displayOptions: FakeDisplayOptions(), animates: false)
        let clusters = [CPUCluster(name: "Super", cores: [1]), CPUCluster(name: "Performance", cores: [0])]
        let cpu = CPUModule(source: ScriptedTickSource([]), clusters: clusters, scheduler: ManualScheduler())
        let lineup = ModuleLineup(settings: settings, hud: hud, capabilities: SettingsWindowTests.laptop) { id in
            id == .cpu ? cpu as any HUDModule : FakeModule(id.rawValue, height: 18)
        }
        settings.modules = [ModuleEntry(.cpu, isOn: true), ModuleEntry(.memory, isOn: true)]
        lineup.apply()
        hud.start()
        defer { hud.panel.orderOut(nil) }
        #expect(cpu.height == 18)
        settings.cpuForm = .clusters
        lineup.apply()
        #expect(lineup.shown == [.cpu, .memory])
        #expect(cpu.height == 54)
        #expect(
            cpu.accessibilityElements.map { $0.accessibilityIdentifier() } == ["CPU", "CPU Super", "CPU Performance"])
        // 8 pt padding, 4 rows, and 4 pt between the two modules.
        #expect(hud.panel.frame.height == 92)
    }
}

@MainActor
@Suite("Sampling interval and threshold settings")
struct IntervalAndThresholdSettingsTests {
    let temporary = TemporaryDefaults()

    init() { _ = NSApplication.shared }

    func makeModel(_ capabilities: SystemCapabilities = SettingsWindowTests.laptop) -> (SettingsModel, HUDSettingsStore)
    {
        let store = HUDSettingsStore(defaults: temporary.defaults)
        return (SettingsModel(store: store, capabilities: capabilities, loginItem: FakeLoginItemService()), store)
    }

    @Test("Update every: 0.5 s, 1 s, 2 s, 5 s; 1 s by default; a choice persists")
    func interval() {
        let (model, store) = makeModel()
        #expect(MeterTiming.intervalChoices.map(SettingsModel.intervalName) == ["0.5 s", "1 s", "2 s", "5 s"])
        #expect(model.sampleInterval == 1 && store.sampleInterval == 1)
        model.setSampleInterval(2)
        #expect(store.sampleInterval == 2 && HUDSettingsStore(defaults: temporary.defaults).sampleInterval == 2)
        model.setSampleInterval(3)
        #expect(model.sampleInterval == 2)
    }

    @Test("The tab lists the seven modules in the Modules order; Battery greyed out without a battery")
    func modules() {
        let (model, _) = makeModel()
        #expect(model.thresholdModules == [.cpu, .memory, .gpu, .battery, .thermal, .swap, .freeSpace])
        model.moveUp(.gpu)
        model.moveUp(.gpu)
        #expect(model.thresholdModules.prefix(3) == [.cpu, .gpu, .memory])
        let (noBattery, _) = makeModel(SystemCapabilities(hasBattery: false, cpuClusters: 2))
        #expect(!noBattery.isAvailable(.battery) && noBattery.unavailableNote(.battery) == "No battery")
    }

    @Test("A valid entry saves at once; an invalid pair is noted and not saved until fixed")
    func validation() {
        let (model, store) = makeModel()
        model.setThreshold(.cpu, .elevated, 60)
        #expect(store.thresholds[.cpu] == ThresholdSetting(elevated: 60, critical: 80))
        model.setThreshold(.cpu, .critical, 50)
        #expect(model.thresholdProblems[.cpu] == "Red must be above Amber.")
        #expect(model.threshold(.cpu).critical == 50 && store.thresholds[.cpu].critical == 80)
        model.setThreshold(.cpu, .critical, 90)
        #expect(
            model.thresholdProblems[.cpu] == nil
                && store.thresholds[.cpu] == ThresholdSetting(elevated: 60, critical: 90))
        model.setThreshold(.battery, .critical, 30)
        #expect(model.thresholdProblems[.battery] == "Red must be below Amber.")
        model.setThreshold(.swap, .elevated, 2_000)
        #expect(model.thresholdProblems[.swap] == "Enter a number from 0 to 1,000.")
        model.setThreshold(.gpu, .elevated, 101)
        #expect(model.thresholdProblems[.gpu] == "Enter a number from 0 to 100.")
        // Closing the window drops the unsaved entries (Edge Cases).
        model.discardThresholdDrafts()
        #expect(model.thresholdProblems.isEmpty && model.threshold(.battery) == store.thresholds[.battery])
    }

    @Test("Empty fields turn a state off; steppers move by the field's step within its range")
    func fieldsAndSteppers() {
        let (model, store) = makeModel()
        model.setThreshold(.gpu, .elevated, nil)
        #expect(store.thresholds.rule(for: .gpu) == nil)
        model.stepThreshold(.swap, .elevated, up: true)
        #expect(store.thresholds[.swap].elevated == 1.5)
        model.stepThreshold(.cpu, .critical, up: true)
        #expect(store.thresholds[.cpu].critical == 81)
        model.setThreshold(.cpu, .elevated, 0)
        model.stepThreshold(.cpu, .elevated, up: false)
        #expect(store.thresholds[.cpu].elevated == 0)
        // An empty field starts from the other number, or from 0 when both are empty.
        model.stepThreshold(.gpu, .critical, up: true)
        #expect(store.thresholds[.gpu] == ThresholdSetting(elevated: nil, critical: 0))
        model.setThreshold(.gpu, .critical, nil)
        model.setThreshold(.gpu, .elevated, 90)
        model.stepThreshold(.gpu, .critical, up: true)
        #expect(store.thresholds[.gpu] == ThresholdSetting(elevated: 90, critical: 90))
    }

    @Test("Highlight switches and Restore Defaults apply at once")
    func switchesAndRestore() {
        let (model, store) = makeModel()
        model.setHighlight(.memory, false)
        model.setThreshold(.cpu, .elevated, 50)
        #expect(!store.thresholds.highlights(.memory) && store.thresholds[.cpu].elevated == 50)
        model.restoreThresholdDefaults()
        #expect(store.thresholds == .defaults && model.thresholds == .defaults)
    }

    @Test("The lineup gives every module the interval and thresholds")
    func lineup() {
        let settings = HUDSettingsStore(defaults: temporary.defaults)
        let hud = HUDController(
            settings: settings, screens: FakeScreens(), displayOptions: FakeDisplayOptions(), animates: false)
        var made: [ModuleID: FakeModule] = [:]
        let lineup = ModuleLineup(settings: settings, hud: hud, capabilities: SettingsWindowTests.laptop) { id in
            let module = FakeModule(id.rawValue, height: 18)
            made[id] = module
            return module
        }
        defer { hud.panel.orderOut(nil) }
        settings.sampleInterval = 0.5
        var thresholds = ThresholdSettings()
        thresholds[.cpu] = ThresholdSetting(elevated: 50, critical: 60)
        settings.thresholds = thresholds
        lineup.apply()
        #expect(made[.cpu]?.interval == .milliseconds(500))
        #expect(made[.cpu]?.thresholds?.rule(for: .cpu)?.elevated?.value == 50)
    }
}

@MainActor
@Suite("Interval and thresholds in modules")
struct ModuleSettingsTests {
    let scheduler = ManualScheduler()
    let clock = ManualClock()

    init() { _ = NSApplication.shared }

    func busy(_ step: Int, percent: Int) -> CPUTicks {
        CPUTicks(user: UInt32(step * percent), system: 0, idle: UInt32(step * (100 - percent)), nice: 0)
    }

    @Test("A new interval reschedules readings one interval out; the baseline carries over")
    func reschedule() {
        let clock = self.clock
        let module = CPUModule(
            source: ScriptedTickSource((0...3).map { busy($0, percent: 40) }), clusters: [], scheduler: scheduler,
            now: { clock.now })
        module.isOnScreen = { _ in true }
        module.setInterval(.seconds(5))
        #expect(scheduler.interval == nil)
        module.start()
        #expect(scheduler.delay == .milliseconds(250) && scheduler.interval == .seconds(5))
        module.setInterval(.seconds(2))
        #expect(scheduler.delay == .seconds(2) && scheduler.interval == .seconds(2))
        // At 5 s, a reading 10 s after its baseline would be stale at 3 s; at 5 s it still counts.
        module.setInterval(.seconds(5))
        clock.elapsed += .seconds(10)
        scheduler.fire()
        #expect(module.rowModels[0].row.value == "40%")
    }

    @Test("Switching highlighting off returns a red row to normal at once")
    func highlightOff() {
        let clock = self.clock
        let module = CPUModule(
            source: ScriptedTickSource((0...4).map { busy($0, percent: 90) }), clusters: [], scheduler: scheduler,
            now: { clock.now })
        module.isOnScreen = { _ in true }
        module.start()
        for _ in 0..<3 {
            clock.elapsed += .seconds(1)
            scheduler.fire()
        }
        #expect(module.rowModels[0].row.state == .critical)
        var settings = ThresholdSettings()
        settings[.cpu] = ThresholdSetting(highlight: false, elevated: 70, critical: 80)
        module.applyThresholds(settings)
        #expect(module.rowModels[0].row.state == .normal)
        #expect(module.accessibilityElements[0].accessibilityValue() as? String == "CPU, 90 percent")
    }
}

@MainActor
@Suite("Code review fixes, UI")
struct ReviewFixUITests {
    let temporary = TemporaryDefaults()
    let scheduler = ManualScheduler()
    let clock = ManualClock()

    init() { _ = NSApplication.shared }

    @Test("A module that leaves the HUD is let go; added back, it starts fresh")
    func freshOnReturn() {
        let settings = HUDSettingsStore(defaults: temporary.defaults)
        let hud = HUDController(
            settings: settings, screens: FakeScreens(), displayOptions: FakeDisplayOptions(), animates: false)
        var created: [ModuleID] = []
        let lineup = ModuleLineup(settings: settings, hud: hud, capabilities: SettingsWindowTests.laptop) { id in
            created.append(id)
            return FakeModule(id.rawValue, height: 18)
        }
        defer { hud.panel.orderOut(nil) }
        lineup.apply()
        let first = lineup.module(.cpu)
        settings.modules = [ModuleEntry(.cpu, isOn: false), ModuleEntry(.memory, isOn: true)]
        lineup.apply()
        #expect(lineup.module(.cpu) == nil)
        settings.modules = [ModuleEntry(.cpu, isOn: true), ModuleEntry(.memory, isOn: true)]
        lineup.apply()
        #expect(created.filter { $0 == .cpu }.count == 2)
        #expect(lineup.module(.cpu) !== first)
    }

    @Test("Waking from sleep returns a red row to normal at once")
    func wakeResets() {
        let clock = self.clock
        let readings = (0...6).map { CPUTicks(user: UInt32($0 * 90), system: 0, idle: UInt32($0 * 10), nice: 0) }
        let module = CPUModule(
            source: ScriptedTickSource(readings), clusters: [], scheduler: scheduler, now: { clock.now })
        module.isOnScreen = { _ in true }
        module.start()
        for _ in 0..<3 {
            clock.elapsed += .seconds(1)
            scheduler.fire()
        }
        #expect(module.rowModels[0].row.state == .critical)
        module.wake()
        #expect(module.rowModels[0].row.state == .normal)
        #expect(module.accessibilityElements[0].accessibilityValue() as? String == "CPU, 90 percent")
    }

    @Test("An outside change replaces an unsaved entry, so the next edit cannot save over it")
    func outsideChangeBeatsDraft() {
        let store = HUDSettingsStore(defaults: temporary.defaults)
        let model = SettingsModel(
            store: store, capabilities: SettingsWindowTests.laptop, loginItem: FakeLoginItemService())
        model.setThreshold(.cpu, .critical, 50)
        #expect(model.thresholdProblems[.cpu] != nil)
        var outside = store.thresholds
        outside[.cpu] = ThresholdSetting(elevated: 60, critical: 70)
        store.thresholds = outside
        store.reload()
        #expect(model.thresholdProblems[.cpu] == nil)
        #expect(model.threshold(.cpu) == ThresholdSetting(elevated: 60, critical: 70))
        model.setThreshold(.cpu, .critical, 95)
        #expect(store.thresholds[.cpu] == ThresholdSetting(elevated: 60, critical: 95))
    }
}
