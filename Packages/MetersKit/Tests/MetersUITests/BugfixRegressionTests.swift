import AppKit
import MetersCore
import SwiftUI
import Testing

@testable import MetersUI

@MainActor
@Suite("September 30 bug fixes, UI", .serialized)
struct BugfixRegressionTests {
    init() { _ = NSApplication.shared }

    @Test("An earlier resize must not undo a completed drag")
    func resizeThenDrag() async throws {
        let temporary = TemporaryDefaults()
        let settings = HUDSettingsStore(defaults: temporary.defaults)
        let hud = HUDController(settings: settings, screens: FakeScreens(), displayOptions: FakeDisplayOptions())
        let module = FakeModule("cpu", height: 18)
        hud.setModules([module])
        hud.start()
        defer { hud.panel.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(400))
        module.height = 36
        // The resize should be near completion; a busy AppKit run loop can still leave an intermediate
        // height here. The drop must finish at the content's full height at the newly saved position.
        try await Task.sleep(for: .milliseconds(250))
        let grab = CGPoint(x: hud.panel.frame.minX + 10, y: hud.panel.frame.minY + 10)
        hud.beginDrag(at: grab)
        hud.endDrag(at: CGPoint(x: grab.x - 400, y: grab.y + 200))
        let dropped = PlacementGeometry.frame(
            for: try #require(settings.placement), size: CGSize(width: 220, height: 52), on: .main)
        try await Task.sleep(for: .milliseconds(400))
        #expect(hud.panel.frame == dropped)
        #expect(settings.placement == PlacementGeometry.placement(for: dropped, on: .main))
    }

    @Test("A drag also supersedes an animation that has not finished")
    func dragDuringResize() async throws {
        let temporary = TemporaryDefaults()
        let settings = HUDSettingsStore(defaults: temporary.defaults)
        let hud = HUDController(settings: settings, screens: FakeScreens(), displayOptions: FakeDisplayOptions())
        let module = FakeModule("cpu", height: 18)
        hud.setModules([module])
        hud.start()
        defer { hud.panel.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(400))
        module.height = 36
        try await Task.sleep(for: .milliseconds(50))
        let grab = CGPoint(x: hud.panel.frame.minX + 10, y: hud.panel.frame.minY + 10)
        hud.beginDrag(at: grab)
        let pointer = CGPoint(x: grab.x - 400, y: grab.y + 200)
        hud.drag(to: pointer)
        let dragged = hud.panel.frame.origin
        try await Task.sleep(for: .milliseconds(400))
        #expect(hud.panel.frame.origin == dragged)
        hud.endDrag(at: pointer)
        // Cancelling a resize can leave an intermediate height. The drop settles to the content's full
        // height, at the newly saved position, rather than preserving that intermediate animation frame.
        let dropped = PlacementGeometry.frame(
            for: try #require(settings.placement), size: CGSize(width: 220, height: 52), on: .main)
        try await Task.sleep(for: .milliseconds(300))
        #expect(hud.panel.frame == dropped)
    }

    @Test("Unavailable-only selection must agree between HUD and Settings")
    func unavailableSelection() {
        let temporary = TemporaryDefaults()
        let store = HUDSettingsStore(defaults: temporary.defaults)
        store.modules = [ModuleEntry(.battery, isOn: true), ModuleEntry(.cpu, isOn: false)]
        let capabilities = SystemCapabilities(hasBattery: false, cpuClusters: 2)
        let model = SettingsModel(store: store, capabilities: capabilities, loginItem: FakeLoginItemService())
        let shown = ModuleSelection.shown(store.modules, unavailable: [.battery])
        #expect(shown == [.cpu])
        #expect(model.entries.first { $0.id == .cpu }?.isOn == true)
        #expect(!model.canToggle(.cpu))
        // Reading Settings does not lose the original Battery selection. A later edit writes the effective
        // selection, so the HUD cannot fall back to an unchecked module again.
        #expect(store.modules.first { $0.id == .battery }?.isOn == true)
        #expect(model.entries.first { $0.id == .battery }?.isOn == false)
        model.setOn(.memory, true)
        model.setOn(.cpu, false)
        #expect(store.modules.filter(\.isOn).map(\.id) == [.memory])
        #expect(!model.canToggle(.memory))
    }

    @Test("Editing a numeric threshold must wait for commit")
    func thresholdTyping() async throws {
        let temporary = TemporaryDefaults()
        let store = HUDSettingsStore(defaults: temporary.defaults)
        let model = SettingsModel(
            store: store, capabilities: SettingsWindowTests.laptop, loginItem: FakeLoginItemService())
        let view = NSHostingView(
            rootView: Form { ThresholdEditorRows(model: model, id: .cpu) }.frame(width: 440, height: 340))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 440, height: 340), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        let fields = SettingsWindowTests.subviews(of: view).compactMap { $0 as? NSTextField }.filter { $0.isEditable }
        let field = try #require(fields.first { $0.stringValue == "70" })
        window.makeFirstResponder(field)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("6", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(200))
        #expect(store.thresholds[.cpu].elevated == 70)
        editor.insertText("0", replacementRange: editor.selectedRange())
        editor.insertNewline(nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.thresholds[.cpu].elevated == 60)
        // An invalid full number must not save its valid numeric prefix.
        model.restoreThresholdDefaults()
        try await Task.sleep(for: .milliseconds(100))
        editor.selectAll(nil)
        for digit in ["1", "0", "1"] {
            editor.insertText(digit, replacementRange: editor.selectedRange())
            try await Task.sleep(for: .milliseconds(100))
        }
        window.makeFirstResponder(nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.thresholdProblems[.cpu] == "Enter a number from 0 to 100.")
        model.discardThresholdDrafts()
        #expect(store.thresholds[.cpu].elevated == 70)
    }

    @Test("Threshold fields commit empty and fractional values, and reject unparseable text")
    func fieldParsing() {
        let temporary = TemporaryDefaults()
        let store = HUDSettingsStore(defaults: temporary.defaults)
        let model = SettingsModel(
            store: store, capabilities: SettingsWindowTests.laptop, loginItem: FakeLoginItemService())
        let control = ThresholdNumberField(
            name: "Swap amber threshold",
            value: Binding(get: { model.threshold(.swap).elevated }, set: { model.setThreshold(.swap, .elevated, $0) }),
            resetVersion: 0, currentResetVersion: { model.thresholdEditVersions[.swap, default: 0] },
            invalidText: { model.invalidThresholdText(.swap) })
        let coordinator = control.makeCoordinator()
        let field = NSTextField()
        coordinator.update(control, field: field, force: true)
        func commit(_ text: String) {
            field.stringValue = text
            coordinator.controlTextDidEndEditing(
                Notification(name: NSControl.textDidEndEditingNotification, object: field))
        }
        commit(1.25.formatted(.number))
        #expect(store.thresholds[.swap].elevated == 1.25)
        commit(" ")
        #expect(store.thresholds[.swap].elevated == nil)
        commit("letters")
        #expect(store.thresholds[.swap].elevated == nil && model.thresholdProblems[.swap] != nil)
        commit("7letters")
        #expect(store.thresholds[.swap].elevated == nil && model.thresholdProblems[.swap] != nil)
    }

    @Test("Closing, restoring defaults, and outside changes discard stale field text")
    func staleFieldText() {
        let temporary = TemporaryDefaults()
        let store = HUDSettingsStore(defaults: temporary.defaults)
        let model = SettingsModel(
            store: store, capabilities: SettingsWindowTests.laptop, loginItem: FakeLoginItemService())
        let control = ThresholdNumberField(
            name: "CPU amber threshold",
            value: Binding(get: { model.threshold(.cpu).elevated }, set: { model.setThreshold(.cpu, .elevated, $0) }),
            resetVersion: 0, currentResetVersion: { model.thresholdEditVersions[.cpu, default: 0] },
            invalidText: { model.invalidThresholdText(.cpu) })
        let coordinator = control.makeCoordinator()
        let field = NSTextField()
        coordinator.update(control, field: field, force: true)
        field.stringValue = "6"
        model.restoreThresholdDefaults()
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        #expect(store.thresholds[.cpu].elevated == 70 && field.stringValue == "70")
        field.stringValue = "6"
        var outside = store.thresholds
        outside[.cpu] = ThresholdSetting(elevated: 60, critical: 75)
        store.thresholds = outside
        store.reload()
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        #expect(store.thresholds[.cpu].elevated == 60 && field.stringValue == "60")
        field.stringValue = "6"
        model.discardThresholdDrafts()
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        #expect(store.thresholds[.cpu].elevated == 60 && field.stringValue == "60")
    }
}

@MainActor
@Suite("October 12 bug fixes, UI", .serialized)
struct OctoberBugfixRegressionTests {
    init() { _ = NSApplication.shared }

    @Test("A resize reverted before its animation starts ends at the reverted size")
    func revertedResize() async throws {
        let temporary = TemporaryDefaults()
        let settings = HUDSettingsStore(defaults: temporary.defaults)
        let hud = HUDController(settings: settings, screens: FakeScreens(), displayOptions: FakeDisplayOptions())
        let module = FakeModule("cpu", height: 18)
        hud.setModules([module])
        hud.start()
        defer { hud.panel.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(400))
        let before = hud.panel.frame
        // Both changes land before the first animation frame, so the panel still reports the original frame.
        module.height = 36
        module.height = 18
        try await Task.sleep(for: .milliseconds(600))
        #expect(hud.panel.frame == before)
    }

    @Test("An instant relayout during a resize animation is where the HUD ends")
    func instantRelayoutDuringResize() async throws {
        let temporary = TemporaryDefaults()
        let settings = HUDSettingsStore(defaults: temporary.defaults)
        let screens = FakeScreens()
        let hud = HUDController(settings: settings, screens: screens, displayOptions: FakeDisplayOptions())
        let module = FakeModule("cpu", height: 18)
        hud.setModules([module])
        hud.start()
        defer { hud.panel.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(400))
        module.height = 36
        try await Task.sleep(for: .milliseconds(60))
        // The Dock grows by 100 pt mid-animation, as a screen-parameters notification would report.
        let display = DisplayInfo(
            id: "main", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            usableArea: CGRect(x: 0, y: 170, width: 1440, height: 730))
        screens.displays = [display]
        hud.relayout(animated: false)
        try await Task.sleep(for: .milliseconds(600))
        #expect(
            hud.panel.frame
                == PlacementGeometry.frame(
                    for: .firstLaunch(on: display), size: CGSize(width: 220, height: 52), on: display))
    }

    @Test("Waking restarts readings on the launch schedule, so the first covers the priming delay")
    func wakeReschedules() {
        let scheduler = ManualScheduler()
        let module = CPUModule(source: ScriptedTickSource([]), clusters: [], scheduler: scheduler)
        module.start()
        module.setInterval(.seconds(5))
        #expect(scheduler.delay == .seconds(5))
        module.wake()
        #expect(scheduler.delay == MeterTiming.primingDelay && scheduler.interval == .seconds(5))
        // A module that is not sampling stays that way.
        let idleScheduler = ManualScheduler()
        let idle = CPUModule(source: ScriptedTickSource([]), clusters: [], scheduler: idleScheduler)
        idle.wake()
        #expect(idleScheduler.delay == nil)
    }

    @Test("A valid commit in one field replaces unreadable text in the other, with its problem")
    func unreadableTextReplaced() {
        let temporary = TemporaryDefaults()
        let store = HUDSettingsStore(defaults: temporary.defaults)
        let model = SettingsModel(
            store: store, capabilities: SettingsWindowTests.laptop, loginItem: FakeLoginItemService())
        func control(_ level: SettingsModel.ThresholdLevel) -> ThresholdNumberField {
            ThresholdNumberField(
                name: "CPU",
                value: Binding(
                    get: { level == .elevated ? model.threshold(.cpu).elevated : model.threshold(.cpu).critical },
                    set: { model.setThreshold(.cpu, level, $0) }),
                resetVersion: model.thresholdEditVersions[.cpu, default: 0],
                currentResetVersion: { model.thresholdEditVersion(.cpu) },
                invalidText: { model.invalidThresholdText(.cpu) })
        }
        let amber = control(.elevated).makeCoordinator()
        let red = control(.critical).makeCoordinator()
        let amberField = NSTextField()
        let redField = NSTextField()
        amber.update(control(.elevated), field: amberField, force: true)
        red.update(control(.critical), field: redField, force: true)
        func commit(_ text: String, in field: NSTextField, _ coordinator: ThresholdNumberField.Coordinator) {
            field.stringValue = text
            coordinator.controlTextDidEndEditing(
                Notification(name: NSControl.textDidEndEditingNotification, object: field))
            // SwiftUI then updates both fields.
            amber.update(control(.elevated), field: amberField)
            red.update(control(.critical), field: redField)
        }
        commit("abc", in: amberField, amber)
        #expect(model.thresholdProblems[.cpu] != nil && amberField.stringValue == "abc")
        commit("85", in: redField, red)
        #expect(model.thresholdProblems[.cpu] == nil)
        #expect(amberField.stringValue == 70.0.formatted(.number))
        #expect(redField.stringValue == 85.0.formatted(.number))
        #expect(store.thresholds[.cpu] == ThresholdSetting(elevated: 70, critical: 85))
        // Without unreadable text, a valid commit leaves the other field's text alone.
        let version = model.thresholdEditVersion(.cpu)
        commit("75", in: amberField, amber)
        #expect(model.thresholdEditVersion(.cpu) == version)
    }
}
