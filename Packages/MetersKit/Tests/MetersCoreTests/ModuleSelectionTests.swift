import Foundation
import Testing

@testable import MetersCore

@Suite("Module selection")
struct ModuleSelectionTests {
    func entry(_ id: ModuleID, _ isOn: Bool) -> ModuleEntry {
        ModuleEntry(id, isOn: isOn)
    }

    @Test("First launch: CPU, Memory, Network on, then the other six off")
    func defaults() {
        #expect(
            ModuleSelection.normalized(nil) == [
                entry(.cpu, true), entry(.memory, true), entry(.network, true), entry(.gpu, false),
                entry(.disk, false), entry(.battery, false), entry(.thermal, false), entry(.swap, false),
                entry(.freeSpace, false),
            ])
        #expect(
            ModuleID.allCases.map(\.name) == [
                "CPU", "Memory", "GPU", "Network", "Disk", "Battery", "Thermal", "Swap", "Free space",
            ])
        #expect(ModuleID.allCases.filter(\.hasForms) == [.cpu, .network, .disk])
    }

    @Test("Stored lists drop unknown and repeated modules, append missing ones unchecked (Edge Cases)")
    func normalization() {
        let stored: [(id: String, isOn: Bool)] = [
            ("gpu", true), ("power", true), ("cpu", false), ("gpu", false), ("thermal", true),
        ]
        #expect(
            ModuleSelection.normalized(stored) == [
                entry(.gpu, true), entry(.cpu, false), entry(.thermal, true), entry(.memory, false),
                entry(.network, false), entry(.disk, false), entry(.battery, false), entry(.swap, false),
                entry(.freeSpace, false),
            ])
    }

    @Test("A stored list with nothing checked shows the first module (Edge Cases)")
    func nothingChecked() {
        let stored: [(id: String, isOn: Bool)] = [("disk", false), ("cpu", false)]
        #expect(ModuleSelection.normalized(stored).first == entry(.disk, true))
    }

    @Test("The HUD shows every checked module in order, in any form, with no row limit")
    func shown() {
        let entries = [
            entry(.cpu, true), entry(.network, true), entry(.gpu, false), entry(.memory, true), entry(.disk, true),
        ]
        #expect(ModuleSelection.shown(entries) == [.cpu, .network, .memory, .disk])
        // The largest forms, with every module checked: 13 rows, all shown.
        var state = SettingsState()
        state.modules = ModuleID.allCases.map { entry($0, true) }
        state.cpuForm = .clusters
        state.networkForm = .twoRows
        state.diskForm = .twoRows
        let resolved = state.resolved(for: SystemCapabilities(hasBattery: true, cpuClusters: 2))
        #expect(resolved.shown == ModuleID.allCases)
    }

    @Test("Modules this Mac cannot show are skipped; if none it can show is checked, the first it can is shown")
    func unavailable() {
        let entries = [entry(.battery, true), entry(.cpu, true), entry(.memory, true), entry(.swap, true)]
        #expect(
            ModuleSelection.shown(entries, unavailable: [.battery]) == [
                .cpu, .memory, .swap,
            ])
        let onlyBattery = [entry(.battery, true), entry(.thermal, false), entry(.cpu, false)]
        #expect(
            ModuleSelection.shown(onlyBattery, unavailable: [.battery]) == [.thermal]
        )
    }
}
