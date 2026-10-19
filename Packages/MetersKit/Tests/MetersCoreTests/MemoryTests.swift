import Foundation
import Synchronization
import Testing

@testable import MetersCore

final class ScriptedMemorySource: MemorySource {
    let physicalMemory: UInt64
    let pageSize: UInt64
    private let readings: Mutex<[MemoryPages?]>

    init(physicalMemory: UInt64 = 4000 * 16384, pageSize: UInt64 = 16384, _ readings: [MemoryPages?]) {
        self.physicalMemory = physicalMemory
        self.pageSize = pageSize
        self.readings = Mutex(readings)
    }

    func readPages() -> MemoryPages? {
        readings.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }
}

@Suite("Memory")
struct MemoryTests {
    func pages(anonymous: UInt64, purgeable: UInt64 = 0, wired: UInt64 = 0, compressed: UInt64 = 0) -> MemoryPages {
        MemoryPages(anonymous: anonymous, purgeable: purgeable, wired: wired, compressed: compressed)
    }

    @Test("Memory Used is app memory plus wired plus compressed, as a share of RAM")
    func fraction() throws {
        // (1000 - 100) + 200 + 50 = 1150 of 4000 pages.
        let used = pages(anonymous: 1000, purgeable: 100, wired: 200, compressed: 50)
        let fraction = try #require(MemoryUsage.fraction(used, pageSize: 16384, physicalMemory: 4000 * 16384))
        #expect(abs(fraction - 0.2875) < 1e-9)
        #expect(MeterText.percent(fraction) == 29)
    }

    @Test("Purgeable pages beyond anonymous pages count as zero app memory (edge case)")
    func purgeableExceedsAnonymous() {
        let odd = pages(anonymous: 100, purgeable: 300, wired: 400)
        #expect(MemoryUsage.fraction(odd, pageSize: 1, physicalMemory: 4000) == 0.1)
    }

    @Test("Out-of-range results are clamped to 0 to 100% (edge case)")
    func clamped() {
        #expect(MemoryUsage.fraction(pages(anonymous: 5000), pageSize: 1, physicalMemory: 4000) == 1)
        #expect(MemoryUsage.fraction(pages(anonymous: 1), pageSize: 1, physicalMemory: 0) == nil)
    }

    @Test("Readings show as a percent and a history; a failed read shows the placeholder and a gap")
    func meter() {
        let source = ScriptedMemorySource([pages(anonymous: 1000), nil, pages(anonymous: 4000)])
        var meter = MemoryMeter(source: source)
        #expect(
            meter.rows == [
                MeterRow(value: "--", spokenValue: "no data", samples: [], hasData: false, offersGauge: true)
            ])

        meter.sample(at: .now)
        #expect(
            meter.rows == [
                MeterRow(
                    value: "25%", spokenValue: "25 percent used", samples: [0.25], hasData: true, offersGauge: true,
                    gaugeFraction: 0.25)
            ])
        meter.sample(at: .now)
        #expect(
            meter.rows == [
                MeterRow(value: "--", spokenValue: "no data", samples: [0.25, nil], hasData: false, offersGauge: true)
            ])
        meter.sample(at: .now)
        #expect(meter.percent == 100)
        #expect(meter.history.samples == [0.25, nil, 1])
    }

    @Test("The history keeps the last 60 samples")
    func history() {
        let half = MemoryPages(anonymous: 2000, purgeable: 0, wired: 0, compressed: 0)
        let source = ScriptedMemorySource(Array(repeating: half, count: 61))
        var meter = MemoryMeter(source: source)
        for _ in 1...61 { meter.sample(at: .now) }
        #expect(meter.history.samples.count == 60)
    }

    @Test("The row is labeled MEM and spoken as Memory")
    func text() {
        #expect(MemoryModuleText.label == "MEM")
        #expect(MemoryModuleText.accessibilityLabel == "Memory")
        #expect(MemoryModuleText.spoken(53) == "53 percent used")
        #expect(MemoryModuleText.spoken(nil) == "no data")
    }

    @Test("The Mach source reports the installed memory and a sensible share of it")
    func machSource() throws {
        let source = MachMemorySource()
        var size: UInt64 = 0
        var length = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &size, &length, nil, 0)
        #expect(source.physicalMemory == size)
        #expect([4096, 16384].contains(source.pageSize))
        let pages = try #require(source.readPages())
        let fraction = try #require(
            MemoryUsage.fraction(pages, pageSize: source.pageSize, physicalMemory: source.physicalMemory))
        #expect(fraction > 0 && fraction < 1)
    }
}
