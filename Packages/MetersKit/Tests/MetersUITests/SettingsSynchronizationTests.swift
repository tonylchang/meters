import AppKit
import MetersCore
import Observation
import SwiftUI
import Synchronization
import Testing

@testable import MetersUI

@MainActor
@Suite("Settings synchronization, UI")
struct SettingsSynchronizationTests {
    let temporary = TemporaryDefaults()

    init() { _ = NSApplication.shared }

    func makeModel() -> (SettingsModel, HUDSettingsStore) {
        let store = HUDSettingsStore(defaults: temporary.defaults)
        return (
            SettingsModel(store: store, capabilities: SettingsWindowTests.laptop, loginItem: FakeLoginItemService()),
            store
        )
    }

    @Test("Each form change is one update; rapid changes remain consistent")
    func formChanges() {
        let (model, store) = makeModel()
        model.setCPUForm(.clusters)
        model.setForm(.network, .twoRows)
        model.setForm(.disk, .twoRows)
        var changes: [SettingsChange] = []
        store.addObserver { changes.append($0) }
        model.setCPUForm(.total)
        #expect(changes.count == 1)
        #expect(changes[0].previous.cpuForm == .clusters && changes[0].current.cpuForm == .total)
        model.setForm(.disk, .oneRow)
        model.setForm(.network, .oneRow)
        #expect(changes.count == 3)
        #expect(changes.map(\.current.networkForm) == [.twoRows, .twoRows, .oneRow])
        #expect(store.diskForm == .oneRow && store.networkForm == .oneRow)
    }

    @Test("Computed Settings values participate in observation without mirrored properties")
    func observation() {
        let (model, store) = makeModel()
        let changed = Mutex(false)
        withObservationTracking {
            _ = model.networkForm
        } onChange: {
            changed.withLock { $0 = true }
        }
        store.networkForm = .twoRows
        #expect(model.networkForm == .twoRows && changed.withLock { $0 })
    }

    @Test("Toggling and reordering use the latest outside selection, including the last-module rule")
    func pendingSelection() {
        let (model, store) = makeModel()
        let outside = UserDefaults(suiteName: temporary.suiteName)!
        outside.set([["id": "gpu", "on": true], ["id": "cpu", "on": false]], forKey: HUDSettingsStore.modulesKey)
        model.setOn(.memory, true)
        #expect(store.modules.filter(\.isOn).map(\.id) == [.gpu, .memory])
        #expect(store.modules.first?.id == .gpu)
        model.setOn(.gpu, false)
        model.setOn(.memory, false)
        #expect(store.modules.filter(\.isOn).map(\.id) == [.memory])
        outside.set([["id": "disk", "on": true], ["id": "cpu", "on": true]], forKey: HUDSettingsStore.modulesKey)
        model.moveUp(.cpu)
        #expect(store.modules.prefix(2).map(\.id) == [.cpu, .disk])
    }

    @Test("Unrelated changes and local highlight switches preserve unfinished threshold pairs")
    func preserveDrafts() {
        let (model, store) = makeModel()
        model.setThreshold(.cpu, .critical, 50)
        let revision = model.thresholdEditVersion(.cpu)
        model.setGraphStyle(.gauges)
        model.setSampleInterval(5)
        model.tab = .hud
        model.setThreshold(.gpu, .elevated, 85)
        model.setHighlight(.cpu, false)
        #expect(model.threshold(.cpu).critical == 50 && model.thresholdProblems[.cpu] != nil)
        #expect(model.thresholdEditVersion(.cpu) == revision)
        #expect(store.thresholds[.cpu].critical == 80 && !store.thresholds[.cpu].highlight)
        model.setThreshold(.cpu, .elevated, 40)
        #expect(store.thresholds[.cpu] == ThresholdSetting(highlight: false, elevated: 40, critical: 50))
        #expect(model.thresholdProblems[.cpu] == nil)
    }

    @Test("A commit queued by another listener retains its editor ownership")
    func queuedOwnCommit() {
        let (model, store) = makeModel()
        let revision = model.thresholdEditVersion(.cpu)
        let token = store.addObserver { change in
            if change.previous.graphStyle != change.current.graphStyle && change.current.graphStyle == .gauges {
                model.setThreshold(.cpu, .elevated, 60)
            }
        }
        defer { store.removeObserver(token) }
        model.setGraphStyle(.gauges)
        #expect(store.thresholds[.cpu].elevated == 60)
        #expect(model.thresholdEditVersion(.cpu) == revision)
        // A different editor's committed change must still invalidate this editor's unfinished values.
        let other = SettingsModel(
            store: store, capabilities: SettingsWindowTests.laptop, loginItem: FakeLoginItemService())
        model.setThreshold(.cpu, .critical, 50)
        other.setThreshold(.cpu, .critical, 75)
        #expect(model.thresholdProblems[.cpu] == nil && model.threshold(.cpu).critical == 75)
        #expect(model.thresholdEditVersion(.cpu) > revision)
    }

    func control(_ model: SettingsModel, id: ModuleID = .cpu) -> ThresholdNumberField {
        ThresholdNumberField(
            name: "threshold",
            value: Binding(get: { model.threshold(id).elevated }, set: { model.setThreshold(id, .elevated, $0) }),
            resetVersion: model.thresholdEditVersions[id, default: 0],
            currentResetVersion: { model.thresholdEditVersion(id) }, invalidText: { model.invalidThresholdText(id) },
            prepareCommit: { model.reconcileSettings() })
    }

    @Test("Queued outside changes invalidate field text before a focus-loss commit")
    func pendingThresholdCommit() {
        let (model, store) = makeModel()
        let control = control(model)
        let coordinator = control.makeCoordinator()
        let field = NSTextField()
        coordinator.update(control, field: field, force: true)
        field.stringValue = "6"
        let outside = UserDefaults(suiteName: temporary.suiteName)!
        outside.set(["cpu": ["elevated": 60.0, "critical": 75.0]], forKey: HUDSettingsStore.thresholdsKey)
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        #expect(store.thresholds[.cpu] == ThresholdSetting(elevated: 60, critical: 75))
        #expect(field.stringValue == "60" && model.thresholdProblems[.cpu] == nil)
    }

    @Test("Default restoration and closing defeat later field commits, even when saved values did not change")
    func invalidatedCommit() {
        let (model, store) = makeModel()
        let control = control(model)
        let coordinator = control.makeCoordinator()
        let field = NSTextField()
        coordinator.update(control, field: field, force: true)
        field.stringValue = "6"
        model.restoreThresholdDefaults()
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        #expect(field.stringValue == "70" && store.thresholds == .defaults)
        field.stringValue = "6"
        model.discardThresholdDrafts()
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        #expect(field.stringValue == "70" && store.thresholds == .defaults)
    }

    @Test("Unrelated outside changes do not discard text being typed")
    func unrelatedTyping() {
        let (model, store) = makeModel()
        let control = control(model)
        let coordinator = control.makeCoordinator()
        let field = NSTextField()
        coordinator.update(control, field: field, force: true)
        field.stringValue = "60"
        UserDefaults(suiteName: temporary.suiteName)!.set("gauges", forKey: HUDSettingsStore.graphsKey)
        coordinator.update(control, field: field)
        #expect(field.stringValue == "60")
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        #expect(store.state.graphStyle == .gauges && store.thresholds[.cpu].elevated == 60)
    }

    @Test("A stepper uses newer outside thresholds before calculating its next value")
    func pendingStepper() {
        let (model, store) = makeModel()
        UserDefaults(suiteName: temporary.suiteName)!.set(
            ["cpu": ["elevated": 60.0, "critical": 75.0]], forKey: HUDSettingsStore.thresholdsKey)
        model.stepThreshold(.cpu, .elevated, up: true)
        #expect(store.thresholds[.cpu] == ThresholdSetting(elevated: 61, critical: 75))
    }

    @Test("Only affected modules receive configuration effects; duplicate starts and notifications are harmless")
    func selectiveEffects() throws {
        let (model, store) = makeModel()
        let hud = HUDController(
            settings: store, screens: FakeScreens(), displayOptions: FakeDisplayOptions(), animates: false)
        let lineup = ModuleLineup(settings: store, hud: hud, capabilities: SettingsWindowTests.laptop) { id in
            RecordingModule(id)
        }
        lineup.start()
        hud.start()
        defer { hud.panel.orderOut(nil) }
        let cpu = try #require(lineup.module(.cpu) as? RecordingModule)
        let memory = try #require(lineup.module(.memory) as? RecordingModule)
        let network = try #require(lineup.module(.network) as? RecordingModule)
        model.setThreshold(.cpu, .elevated, 60)
        #expect(cpu.thresholdApplications == 2 && memory.thresholdApplications == 1)
        #expect(cpu.intervalApplications == 1 && network.formApplications == 1)
        model.tab = .hud
        store.reload()
        lineup.start()
        #expect(cpu.starts == 1 && cpu.intervalApplications == 1 && cpu.graphApplications == 1)
        model.setSampleInterval(5)
        #expect(cpu.intervalApplications == 2 && memory.intervalApplications == 2)
        model.setGraphStyle(.gauges)
        #expect(cpu.graphApplications == 2 && network.graphApplications == 2)
        model.setForm(.network, .twoRows)
        #expect(network.formApplications == 2 && cpu.formApplications == 1)
        #expect(hud.panel.frame.size == CGSize(width: 220, height: 96))
        model.setOn(.cpu, false)
        #expect(cpu.stops == 1 && lineup.module(.cpu) == nil)
        model.setOn(.cpu, true)
        let returned = try #require(lineup.module(.cpu) as? RecordingModule)
        #expect(returned !== cpu && returned.starts == 1)
        #expect(returned.interval == .seconds(5) && returned.graphStyle == .gauges)
        #expect(returned.thresholds?[.cpu].elevated == 60)
    }

    @Test("Non-layout settings cannot reset a drag in progress")
    func unrelatedChangeDuringDrag() {
        let (model, store) = makeModel()
        let hud = HUDController(
            settings: store, screens: FakeScreens(), displayOptions: FakeDisplayOptions(), animates: false)
        let lineup = ModuleLineup(settings: store, hud: hud, capabilities: SettingsWindowTests.laptop) {
            RecordingModule($0)
        }
        lineup.start()
        hud.start()
        defer { hud.panel.orderOut(nil) }
        let grab = CGPoint(x: hud.panel.frame.minX + 10, y: hud.panel.frame.minY + 10)
        hud.beginDrag(at: grab)
        let pointer = CGPoint(x: grab.x - 200, y: grab.y + 100)
        hud.drag(to: pointer)
        let dragged = hud.panel.frame
        model.setThreshold(.cpu, .elevated, 60)
        model.setGraphStyle(.gauges)
        model.tab = .thresholds
        #expect(hud.panel.frame == dragged)
        hud.endDrag(at: pointer)
        #expect(store.placement == PlacementGeometry.placement(for: dragged, on: .main))
    }

    @Test("A delayed resize fallback cannot undo a newer drag, with explicit callback delivery")
    func staleResizeCallback() {
        let store = HUDSettingsStore(defaults: temporary.defaults)
        let completions = ManualAnimationCompletions()
        let hud = HUDController(
            settings: store, screens: FakeScreens(), displayOptions: FakeDisplayOptions(),
            animationCompletions: completions)
        let module = FakeModule("cpu", height: 18)
        hud.setModules([module])
        hud.start()
        defer { hud.panel.orderOut(nil) }
        completions.runAll()
        module.height = 36
        #expect(!completions.actions.isEmpty)
        // Deliver the fallback after the resize's target frame has been reached and the user has dragged.
        hud.panel.setFrame(CGRect(x: 1216, y: 82, width: 220, height: 52), display: true)
        let grab = CGPoint(x: 1226, y: 92)
        hud.beginDrag(at: grab)
        hud.endDrag(at: CGPoint(x: grab.x - 200, y: grab.y + 100))
        let dropped = hud.panel.frame
        completions.runAll()
        #expect(hud.panel.frame == dropped)
        #expect(store.placement == PlacementGeometry.placement(for: dropped, on: .main))
    }

    @Test("Older fade completions cannot hide the HUD after a newer show action")
    func staleFadeCallbacks() {
        let store = HUDSettingsStore(defaults: temporary.defaults)
        let completions = ManualAnimationCompletions()
        let hud = HUDController(
            settings: store, screens: FakeScreens(), displayOptions: FakeDisplayOptions(),
            animationCompletions: completions)
        hud.setModules([FakeModule("cpu", height: 18)])
        hud.start()
        defer { hud.panel.orderOut(nil) }
        hud.setVisible(false)
        hud.setVisible(true)
        completions.runAll()
        #expect(hud.wantsVisible && hud.panel.isVisible && hud.panel.alphaValue == 1)
        #expect(store.isHUDVisible)
    }
}

@MainActor
private final class RecordingModule: HUDModule, CPUFormSwitching, RateFormSwitching {
    let id: ModuleID
    var identifier: String { id.rawValue }
    let view = NSView()
    var height: CGFloat = 18
    var width: CGFloat = 204
    var onSizeChange: (() -> Void)?
    var starts = 0
    var stops = 0
    var formApplications = 0
    var intervalApplications = 0
    var thresholdApplications = 0
    var graphApplications = 0
    var interval: Duration?
    var thresholds: ThresholdSettings?
    var graphStyle: GraphStyle?

    init(_ id: ModuleID) { self.id = id }
    func start() { starts += 1 }
    func stop() { stops += 1 }
    func setForm(_ form: CPUForm) {
        formApplications += 1
        height = form == .total ? 18 : 54
        onSizeChange?()
    }
    func setForm(_ form: RateForm) {
        formApplications += 1
        height = CGFloat(form.rows * 18)
        onSizeChange?()
    }
    func setInterval(_ interval: Duration) {
        intervalApplications += 1
        self.interval = interval
    }
    func applyThresholds(_ settings: ThresholdSettings) {
        thresholdApplications += 1
        thresholds = settings
    }
    func setGraphStyle(_ style: GraphStyle) {
        graphApplications += 1
        graphStyle = style
    }
}

@MainActor
private final class ManualAnimationCompletions: AnimationCompletionScheduling {
    var actions: [@MainActor @Sendable () -> Void] = []

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) {
        actions.append(action)
    }

    func runAll() {
        let pending = actions
        actions = []
        for action in pending { action() }
    }
}
