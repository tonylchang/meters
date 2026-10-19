import AppKit
import MetersCore
import Testing

@testable import MetersUI

@MainActor
@Suite("Memory module")
struct MemoryModuleTests {
    let scheduler = ManualScheduler()
    let clock = ManualClock()

    init() { _ = NSApplication.shared }

    func makeModule(_ readings: [MemoryPages?]) -> MemoryModule {
        let clock = self.clock
        let module = MemoryModule(
            source: ScriptedMemorySource(readings), pressure: nil, scheduler: scheduler, now: { clock.now })
        module.isOnScreen = { _ in true }
        return module
    }

    func pages(_ anonymous: UInt64) -> MemoryPages {
        MemoryPages(anonymous: anonymous, purgeable: 0, wired: 0, compressed: 0)
    }

    @Test("The first value appears 0.25 s after launch, then every 1 s")
    func cadence() {
        let module = makeModule([pages(2120), pages(1000)])
        module.start()
        #expect(scheduler.delay == .milliseconds(250))
        #expect(scheduler.interval == .seconds(1))
        #expect(module.rowModels[0].row.value == "--")
        scheduler.fire()
        #expect(module.rowModels[0].row.value == "53%")
    }

    @Test("One 18 pt row that VoiceOver reads as Memory, then the percent used or no data")
    func accessibility() {
        let module = makeModule([pages(2120), nil])
        #expect(module.height == 18)
        #expect(module.identifier == "memory")
        #expect(module.accessibilityElements.count == 1)
        let row = module.accessibilityElements[0]
        #expect(row.accessibilityRole() == .staticText)
        #expect(row.accessibilityIdentifier() == "Memory")
        #expect(row.accessibilityValue() as? String == "Memory, no data")
        var announced: [String] = []
        module.announceValueChange = { view in announced.append(view.accessibilityValue() as? String ?? "") }
        module.start()
        scheduler.fire()
        #expect(row.accessibilityValue() as? String == "Memory, 53 percent used")
        scheduler.fire()
        #expect(announced == ["Memory, 53 percent used", "Memory, no data"])
    }

    @Test("MEM sits 4 pt below CPU, and VoiceOver meets CPU, then Memory")
    func belowCPU() {
        let cpu = CPUModule(source: ScriptedTickSource([]), scheduler: ManualScheduler())
        let memory = makeModule([])
        let container = HUDContainerView(frame: CGRect(x: 0, y: 0, width: 220, height: 56))
        container.setModules([cpu, memory], visibleCount: 2)
        container.layout()
        #expect(cpu.view.frame == CGRect(x: 8, y: 8, width: 204, height: 18))
        #expect(memory.view.frame == CGRect(x: 8, y: 30, width: 204, height: 18))
        let children = container.accessibilityChildren() as? [NSView]
        #expect(children?.map { $0.accessibilityIdentifier() } == ["CPU", "Memory"])
    }
}
