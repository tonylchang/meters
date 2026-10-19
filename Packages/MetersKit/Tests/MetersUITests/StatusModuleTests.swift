import AppKit
import MetersCore
import Observation
import Synchronization
import Testing

@testable import MetersUI

final class ScriptedBatterySource: BatterySource {
    private let readings: Mutex<[BatteryReading?]>

    init(_ readings: [BatteryReading?]) {
        self.readings = Mutex(readings)
    }

    func readBattery() -> BatteryReading? {
        readings.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }
}

struct FixedThermal: ThermalStateSource {
    func readThermalState() -> ProcessInfo.ThermalState { .fair }
}

struct FixedSwap: SwapSource {
    func readSwapUsed() -> UInt64? { 1_250_000_000 }
}

struct FixedFreeSpace: FreeSpaceSource {
    func readAvailable() -> UInt64? { 600_000_000_000 }
    func readAvailableForImportantUsage() -> UInt64? { 675_000_000_000 }
}

@MainActor
@Suite("Battery, Thermal, Swap, and Free space modules")
struct StatusModuleTests {
    let scheduler = ManualScheduler()

    init() { _ = NSApplication.shared }

    func started<Meter: ModuleMeter>(_ module: MeterModule<Meter>) -> MeterModule<Meter> {
        module.isOnScreen = { _ in true }
        module.start()
        scheduler.fire()
        return module
    }

    @Test("Each is one 18 pt row with its label, read by VoiceOver as its name and value")
    func rows() {
        let modules: [(any HUDModule, String, String, String)] = [
            (started(ThermalModule(source: FixedThermal(), scheduler: scheduler)), "thermal", "Thermal state", "warm"),
            (started(SwapModule(source: FixedSwap(), scheduler: scheduler)), "swap", "Swap", "1.25 gigabytes used"),
            (
                started(FreeSpaceModule(source: FixedFreeSpace(), scheduler: scheduler)),
                "freeSpace", "Free space", "675 gigabytes"
            ),
        ]
        for (module, identifier, label, value) in modules {
            #expect(module.identifier == identifier)
            #expect(module.height == 18)
            #expect(module.accessibilityElements.count == 1)
            #expect(module.accessibilityElements[0].accessibilityIdentifier() == label)
            #expect(module.accessibilityElements[0].accessibilityValue() as? String == "\(label), \(value)")
        }
    }

    @Test("Battery: the arrow shows as the row's marker and changes with the current")
    func batteryArrow() {
        let source = ScriptedBatterySource([
            BatteryReading(charge: 0.71, milliamps: -2_000), BatteryReading(charge: 0.72, milliamps: 50),
        ])
        let module = started(BatteryModule(source: source, scheduler: scheduler))
        #expect(module.identifier == "battery" && module.height == 18)
        let row = module.rowModels[0].row
        #expect(row.value == "71%" && row.valueMarker == "↓" && row.samples.isEmpty)
        let view = module.accessibilityElements[0]
        #expect(view.accessibilityIdentifier() == "Battery")
        #expect(view.accessibilityValue() as? String == "Battery, 71 percent, draining")
        scheduler.fire()
        #expect(module.rowModels[0].row.valueMarker == nil)
        #expect(view.accessibilityValue() as? String == "Battery, 72 percent")
    }

    @Test("An unchanged row is not redrawn (render optimization)")
    func unchangedRowNotRedrawn() {
        let module = started(ThermalModule(source: FixedThermal(), scheduler: scheduler))
        let model = module.rowModels[0]
        let changed = Mutex(false)
        withObservationTracking {
            _ = model.row
        } onChange: {
            changed.withLock { $0 = true }
        }
        scheduler.fire()
        scheduler.fire()
        #expect(!changed.withLock { $0 })
        #expect(model.row.value == "Warm")
    }

    @Test("The system modules for every ID carry that ID (lineup)")
    func systemModules() {
        for id in ModuleID.allCases {
            let module = ModuleLineup.systemModule(id, capabilities: SettingsWindowTests.laptop)
            #expect(module.identifier == id.rawValue)
        }
    }
}
