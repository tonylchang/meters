import AppKit
import MetersCore
import Synchronization
import Testing

@testable import MetersUI

/// Returns scripted GPU readings in order, then `nil`.
final class ScriptedGPUSource: GPUUtilizationSource {
    private let readings: Mutex<[Double?]>

    init(_ readings: [Double?]) {
        self.readings = Mutex(readings)
    }

    func readUtilization() -> Double? {
        readings.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }
}

@MainActor
@Suite("GPU module")
struct GPUModuleTests {
    let scheduler = ManualScheduler()

    init() { _ = NSApplication.shared }

    @Test("An unavailable figure shows n/a in the secondary color, and VoiceOver says unavailable")
    func unavailable() {
        let module = GPUModule(source: ScriptedGPUSource([nil, 42]), scheduler: scheduler)
        module.isOnScreen = { _ in true }
        let row = module.accessibilityElements[0]
        #expect(module.identifier == "gpu")
        #expect(module.height == 18)
        #expect(row.accessibilityIdentifier() == "GPU")
        #expect(row.accessibilityValue() as? String == "GPU, no data")
        module.start()
        scheduler.fire()
        #expect(module.rowModels[0].row.value == "n/a")
        #expect(module.rowModels[0].row.isUnavailable)
        #expect(row.accessibilityValue() as? String == "GPU, unavailable")
        scheduler.fire()
        #expect(module.rowModels[0].row.value == "42%")
        #expect(row.accessibilityValue() as? String == "GPU, 42 percent")
    }
}
