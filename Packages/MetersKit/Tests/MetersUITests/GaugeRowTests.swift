import AppKit
import MetersCore
import SwiftUI
import Testing

@testable import MetersUI

@MainActor
@Suite("Gauge rows")
struct GaugeRowTests {
    let scheduler = ManualScheduler()
    let temporary = TemporaryDefaults()

    init() { _ = NSApplication.shared }

    @Test("The fill is a rounded bar from the left, the fraction of the width; empty at 0")
    func shape() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 6)
        #expect(GaugeFillShape(fraction: 0.5).path(in: rect).boundingRect == CGRect(x: 0, y: 0, width: 50, height: 6))
        #expect(GaugeFillShape(fraction: 1.5).path(in: rect).boundingRect.width == 100)
        #expect(GaugeFillShape(fraction: 0).path(in: rect).isEmpty)
        #expect(GaugeBar.height == 6)
    }

    @Test(
        "Switching Graphs reaches every row, also rows added by a form switch; history is kept")
    func switching() {
        let clusters = [CPUCluster(name: "Super", cores: nil), CPUCluster(name: "Performance", cores: nil)]
        let readings = (0...3).map { CPUTicks(user: UInt32($0 * 40), system: 0, idle: UInt32($0 * 60), nice: 0) }
        let module = CPUModule(source: ScriptedTickSource(readings), clusters: clusters, scheduler: scheduler)
        module.isOnScreen = { _ in true }
        module.start()
        scheduler.fire()
        scheduler.fire()
        module.setGraphStyle(.gauges)
        #expect(module.rowModels.allSatisfy { $0.graphStyle == .gauges })
        module.setForm(.clusters)
        #expect(module.rowModels.count == 3 && module.rowModels.allSatisfy { $0.graphStyle == .gauges })
        module.setGraphStyle(.sparklines)
        #expect(module.rowModels[0].graphStyle == .sparklines)
        #expect(module.rowModels[0].row.samples.count == 2)
    }

    @Test("The lineup gives every module the Graphs setting; the model persists it")
    func lineupAndModel() {
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
        let model = SettingsModel(
            store: settings, capabilities: SettingsWindowTests.laptop, loginItem: FakeLoginItemService())
        #expect(model.graphStyle == .sparklines)
        model.setGraphStyle(.gauges)
        lineup.apply()
        #expect(settings.graphStyle == .gauges)
        #expect(made.values.allSatisfy { $0.graphStyle == .gauges } && !made.isEmpty)
    }
}
