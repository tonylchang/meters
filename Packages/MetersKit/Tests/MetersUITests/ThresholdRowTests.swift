import AppKit
import MetersCore
import SwiftUI
import Testing

@testable import MetersUI

@MainActor
@Suite("Threshold rows")
struct ThresholdRowTests {
    let scheduler = ManualScheduler()
    let clock = ManualClock()

    init() { _ = NSApplication.shared }

    @Test("Amber and red are the system's orange and red; a normal row has no state color")
    func colors() {
        #expect(MeterRowContent.stateColor(.normal) == nil)
        #expect(MeterRowContent.stateColor(.elevated) == Color(nsColor: .systemOrange))
        #expect(MeterRowContent.stateColor(.critical) == Color(nsColor: .systemRed))
    }

    @Test("A critical CPU row reads its state, announced when it changes")
    func spokenState() {
        // Each reading adds 100 ticks: 85 busy.
        let readings = (0...4).map { CPUTicks(user: UInt32($0 * 85), system: 0, idle: UInt32($0 * 15), nice: 0) }
        let clock = self.clock
        let module = CPUModule(
            source: ScriptedTickSource(readings), clusters: [], scheduler: scheduler, now: { clock.now })
        module.isOnScreen = { _ in true }
        var announced: [String] = []
        module.announceValueChange = { view in announced.append(view.accessibilityValue() as? String ?? "") }
        module.start()
        for _ in 0..<3 {
            clock.elapsed += .seconds(1)
            scheduler.fire()
        }
        #expect(module.rowModels[0].row.state == .critical)
        #expect(module.accessibilityElements[0].accessibilityValue() as? String == "CPU, 85 percent, critical")
        #expect(announced == ["CPU, 85 percent", "CPU, 85 percent, critical"])
    }

    @Test("Semibold values still fit the value column, so the grid never shifts")
    func semiboldFits() {
        let regular = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let semibold = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        func width(_ text: String, _ font: NSFont) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }
        let column = MeterRowContent.valueTemplates.map { width($0, regular) }.max() ?? 0
        for value in ["100%", "↓ 100%", "S 100%", "Critical", "Hot", "999G", "8.88G", "999T", "1.20T"] {
            #expect(width(value, semibold) <= column, "\(value)")
        }
    }
}
