import Foundation
import Synchronization
import Testing

@testable import MetersCore

/// Busy-loops one thread per logical core until stopped.
final class CPULoad: Sendable {
    private let running = Atomic(false)
    private let threadCount = ProcessInfo.processInfo.activeProcessorCount

    func start() {
        running.store(true, ordering: .relaxed)
        for _ in 0..<threadCount {
            Thread.detachNewThread { [self] in
                while running.load(ordering: .relaxed) {}
            }
        }
    }

    func stop() {
        running.store(false, ordering: .relaxed)
    }
}

/// Per-core tick counters read with `host_processor_info`, a separate path from the meter's aggregate
/// `host_statistics` source. It shows what the cores actually did, including cores macOS held back.
struct CoreTicks {
    let cores: [(busy: UInt32, total: UInt32)]

    static func read() -> CoreTicks? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
            let info
        else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_, vm_address_t(bitPattern: info),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        let cores = (0..<Int(count)).map { core in
            let ticks = (0..<states).map { UInt32(bitPattern: info[core * states + $0]) }
            let total = ticks.reduce(0, &+)
            return (busy: total &- ticks[Int(CPU_STATE_IDLE)], total: total)
        }
        return CoreTicks(cores: cores)
    }

    /// The share of all cores' time that was busy since `earlier`, from 0 to 1.
    func busyFraction(since earlier: CoreTicks) -> Double {
        var busy = 0.0
        var total = 0.0
        for (now, then) in zip(cores, earlier.cores) {
            busy += Double(now.busy &- then.busy)
            total += Double(now.total &- then.total)
        }
        return total > 0 ? busy / total : 0
    }
}

/// Live checks against the real system. They
/// briefly saturate every core or allocate gigabytes of memory, so they run one at a time, including the
/// checks other files add in extensions.
@Suite("Live accuracy", .serialized)
struct LiveTests {
    let clock = ContinuousClock()

    @Test("The Mach source reads advancing counters")
    func machSource() async throws {
        let source = MachCPUTickSource()
        let first = try #require(source.readTicks())
        try await Task.sleep(for: .milliseconds(250))
        let second = try #require(source.readTicks())
        let fraction = try #require(CPUUtilization.fraction(from: first, to: second))
        #expect((0...1).contains(fraction))
    }

    @Test("A reading 250 ms after the baseline always has data, so the first value arrives within 1 s")
    func firstReadingHasData() async throws {
        for _ in 0..<10 {
            var meter = CPUMeter(source: MachCPUTickSource())
            meter.rebaseline(at: clock.now)
            try await Task.sleep(for: CPUMeter.primingDelay)
            meter.sample(at: clock.now)
            #expect(meter.percent != nil)
        }
    }

    @Test("A full-core load reads 90% or more within 3 s, or what the cores did if macOS held some back")
    func saturation() async throws {
        var meter = CPUMeter(source: MachCPUTickSource())
        meter.rebaseline(at: clock.now)
        try await Task.sleep(for: CPUMeter.interval)
        meter.sample(at: clock.now)
        let before = try #require(meter.percent)

        let load = CPULoad()
        load.start()
        defer { load.stop() }
        var ticks = try #require(CoreTicks.read())
        var peak = 0
        var reading = 0
        var actual = 0.0
        for _ in 0..<3 where peak < 90 {
            try await Task.sleep(for: CPUMeter.interval)
            meter.sample(at: clock.now)
            let now = try #require(CoreTicks.read())
            actual = now.busyFraction(since: ticks)
            ticks = now
            reading = meter.percent ?? 0
            peak = max(peak, reading)
        }
        load.stop()
        if actual >= 0.9 {
            #expect(peak >= 90, "peak \(peak)% with every core saturated")
        } else {
            // macOS held cores back (for example, to give the GPU more power), so the load could not
            // saturate every core. The reading must still match what the cores actually did.
            let actualPercent = Int((actual * 100).rounded())
            #expect(abs(reading - actualPercent) <= 5, "read \(reading)% while the cores were \(actualPercent)% busy")
        }

        var after: Int?
        for _ in 0..<3 {
            try await Task.sleep(for: CPUMeter.interval)
            meter.sample(at: clock.now)
            after = meter.percent
            if let after, after <= before + 10 { break }
        }
        let settled = try #require(after)
        #expect(settled <= before + 10, "fell to \(settled)% after load; \(before)% before")
    }

    @Test("Over 10 s, the mean is within 5 points of top's user plus system CPU")
    func matchesTop() async throws {
        let top = Process()
        top.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        top.arguments = ["-l", "11", "-s", "1", "-n", "0"]
        let pipe = Pipe()
        top.standardOutput = pipe
        try top.run()

        var meter = CPUMeter(source: MachCPUTickSource())
        meter.rebaseline(at: clock.now)
        var ours: [Double] = []
        for _ in 0..<10 {
            try await Task.sleep(for: CPUMeter.interval)
            meter.sample(at: clock.now)
            if let fraction = meter.history.samples.last ?? nil { ours.append(fraction * 100) }
        }
        top.waitUntilExit()

        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let usage = /CPU usage: ([\d.]+)% user, ([\d.]+)% sys/
        // top's first sample reports usage since boot; the next ten cover the same 10 s as ours.
        let theirs = output.matches(of: usage).dropFirst().compactMap { match in
            Double(match.output.1).flatMap { user in Double(match.output.2).map { user + $0 } }
        }
        try #require(ours.count == 10)
        try #require(theirs.count == 10)
        let ourMean = ours.reduce(0, +) / Double(ours.count)
        let theirMean = theirs.reduce(0, +) / Double(theirs.count)
        #expect(abs(ourMean - theirMean) <= 5, "meters \(ourMean)% vs top \(theirMean)%")
    }
}
