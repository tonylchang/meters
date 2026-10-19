import Darwin
import Foundation
import Synchronization
import Testing

@testable import MetersCore

private struct ReviewMemorySource: MemorySource {
    let physicalMemory: UInt64 = 100
    let pageSize: UInt64 = 1
    func readPages() -> MemoryPages? { MemoryPages(anonymous: 50, purgeable: 0, wired: 0, compressed: 0) }
}

private final class ReviewPressureSource: MemoryPressureSource {
    let value = Mutex<MemoryPressure?>(.critical)
    func readPressure() -> MemoryPressure? { value.withLock { $0 } }
}

@Suite("September 30 bug fixes, core", .serialized)
struct BugfixRegressionTests {
    @Test("Unavailable memory pressure must return highlighting to normal")
    func missingPressure() {
        let source = ReviewPressureSource()
        var meter = MemoryMeter(source: ReviewMemorySource(), pressure: source)
        for _ in 0..<3 { meter.sample(at: .now) }
        #expect(meter.rows[0].state == .critical)
        source.value.withLock { $0 = nil }
        meter.sample(at: .now)
        #expect(meter.rows[0].state == .normal)
        #expect(meter.rows[0].value == "50%")
        source.value.withLock { $0 = .critical }
        for _ in 0..<2 { meter.sample(at: .now) }
        #expect(meter.rows[0].state == .normal)
        meter.sample(at: .now)
        #expect(meter.rows[0].state == .critical)
    }

    @Test("Creating and releasing metric sources must release host send rights")
    func hostRights() {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        func refs() -> mach_port_urefs_t {
            var refs: mach_port_urefs_t = 0
            _ = mach_port_get_refs(mach_task_self_, host, mach_port_right_t(MACH_PORT_RIGHT_SEND), &refs)
            return refs
        }
        let before = refs()
        for _ in 0..<100 {
            _ = MachCPUTickSource().readTicks()
            _ = MachMemorySource().readPages()
        }
        let after = refs()
        #expect(after == before)
    }

    @Test("Copies of Mach sources share ownership and remain readable after the original is released")
    func sourceCopies() {
        func cpuCopy() -> MachCPUTickSource {
            let original = MachCPUTickSource()
            let copy = original
            #expect(original.readTicks() != nil)
            return copy
        }
        func memoryCopy() -> MachMemorySource {
            let original = MachMemorySource()
            let copy = original
            #expect(original.readPages() != nil)
            return copy
        }
        #expect(cpuCopy().readTicks() != nil)
        #expect(memoryCopy().readPages() != nil)
    }
}
