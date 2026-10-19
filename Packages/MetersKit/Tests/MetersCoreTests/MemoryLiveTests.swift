import Darwin
import Foundation
import Testing

@testable import MetersCore

/// Memory Used computed from `vm_stat`'s page counts, the same definition read through a separate tool.
func vmStatMemoryUsed(physicalMemory: UInt64) throws -> Double {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/vm_stat")
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()

    func count(_ name: String) throws -> UInt64 {
        let line = try #require(output.split(separator: "\n").first { $0.hasPrefix(name + ":") })
        return try #require(UInt64(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces).dropLast()))
    }
    let header = try #require(output.split(separator: "\n").first)
    let pageSize = try #require(UInt64(header.split(separator: " ").first { UInt64($0) != nil } ?? ""))
    let pages = MemoryPages(
        anonymous: try count("Anonymous pages"), purgeable: try count("Pages purgeable"),
        wired: try count("Pages wired down"), compressed: try count("Pages occupied by compressor"))
    return try #require(MemoryUsage.fraction(pages, pageSize: pageSize, physicalMemory: physicalMemory))
}

extension LiveTests {
    @Test("The reading is within 1 point of Memory Used computed from vm_stat")
    func memoryMatchesVMStat() throws {
        let source = MachMemorySource()
        var meter = MemoryMeter(source: source)
        let expected = MeterText.percent(try vmStatMemoryUsed(physicalMemory: source.physicalMemory))
        meter.sample(at: clock.now)
        let reading = try #require(meter.percent)
        #expect(abs(reading - expected) <= 1, "read \(reading)%; vm_stat gives \(expected)%")
    }

    @Test("Allocating 5% of RAM raises the reading 3 to 7 points within 2 s; releasing it lowers it")
    func memoryFollowsAllocation() async throws {
        let source = MachMemorySource()
        var meter = MemoryMeter(source: source)
        // Readings come right before and right after each step, so other apps' memory has little time to
        // change the total; then every 250 ms until the change shows, within 2 s.
        // This process's own memory, in points of RAM: what the test allocates, and nothing else.
        func ownPoints() throws -> Double {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            try #require(result == KERN_SUCCESS)
            return Double(info.phys_footprint) / Double(source.physicalMemory) * 100
        }
        // Memory held by everything else, in points: the total less this process. On Apple silicon, GPU work
        // wires and unwires its buffers in steps of 1 to 25 points (measured Sep 28, 2026),
        // which moves the total under a trial. It is compared at the readings the rise and fall are measured
        // from, since between them the total and this process's footprint update at slightly different moments.
        var others: [Double] = []
        func reading() throws -> Double {
            meter.sample(at: clock.now)
            let total = try #require(meter.history.samples.last ?? nil)
            others.append(total * 100 - (try ownPoints()))
            return total
        }
        func change(from start: Double, sign: Double) async throws -> Double {
            var points = 0.0
            for attempt in 0...8 {
                if attempt > 0 { try await Task.sleep(for: .milliseconds(250)) }
                points = (try reading() - start) * 100 * sign
                if (3...7).contains(points) { break }
            }
            return points
        }
        // Waits, up to 10 s, until the total has held within 0.1 points for 1 s, so a trial starts in a lull.
        func quietWindow() async throws {
            var recent: [Double] = []
            for _ in 0..<40 {
                recent = Array((recent + [try reading() * 100]).suffix(5))
                if recent.count == 5, (recent.max() ?? 0) - (recent.min() ?? 0) <= 0.1 { return }
                try await Task.sleep(for: .milliseconds(250))
            }
        }

        let size = Int(source.physicalMemory / 20)
        let disturbanceLimit = 0.5
        var trials: [String] = []
        // Up to 5 trials; only a trial during which everything else stayed within 0.5 points is judged, and the
        // first such trial decides. A meter that stops following memory makes every trial look disturbed, so
        // it still fails.
        for trial in 1...5 {
            try await quietWindow()
            let region = try #require(mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0))
            try #require(region != MAP_FAILED)
            // Released exactly once: explicitly below, or here if the test stops early.
            var mapped = true
            defer { if mapped { munmap(region, size) } }
            let before = try reading()
            let othersBefore = others.last ?? 0
            // Random data, so the compressor cannot shrink the pages away; the fill takes under 1 s.
            arc4random_buf(region, size)
            let risen = try await change(from: before, sign: 1)
            let othersRisen = others.last ?? 0

            let peak = try reading()
            let othersPeak = others.last ?? 0
            munmap(region, size)
            mapped = false
            let fallen = try await change(from: peak, sign: -1)
            let othersFallen = others.last ?? 0

            let disturbance = max(abs(othersRisen - othersBefore), abs(othersFallen - othersPeak))
            let summary = String(
                format: "trial %d: rose %.2f, fell %.2f, other memory moved %.2f points", trial, risen, fallen,
                disturbance)
            trials.append(summary)
            guard disturbance > disturbanceLimit else {
                #expect((3...7).contains(risen), "\(summary)")
                #expect((3...7).contains(fallen), "\(summary)")
                return
            }
        }
        let summaries = trials.joined(separator: "; ")
        Issue.record(
            "Memory outside this process moved in every trial, or the meter is not following memory: \(summaries)")
    }
}
