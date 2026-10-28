import Darwin
import Foundation
import Testing

@testable import MetersCore

/// A system tool's standard output.
func toolOutput(_ path: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return output
}

/// The battery controller's registry entry as `ioreg` prints it.
func ioregSmartBattery() throws -> String {
    try toolOutput("/usr/sbin/ioreg", ["-r", "-c", "AppleSmartBattery", "-w0", "-d", "1"])
}

/// A signed registry number: `ioreg` may print a negative value as its unsigned 64-bit pattern.
func signedRegistryNumber(_ text: Substring) -> Int? {
    if let value = Int64(text) { return Int(value) }
    return UInt64(text).map { Int(Int64(bitPattern: $0)) }
}

/// Whether the tests run in a virtual machine, such as a hosted CI runner (`kern.hv_vmm_present`).
let isVirtualMachine: Bool = {
    var present: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname("kern.hv_vmm_present", &present, &size, nil, 0) == 0 && present != 0
}()

extension Trait where Self == ConditionTrait {
    /// For checks against Apple Silicon hardware that a virtual machine replaces with virtual devices: the GPU's
    /// utilization figure, the CPU's clusters, and the physical disk. They are skipped there, not failed, and every
    /// Mac still runs them.
    static var physicalMacOnly: Self {
        .enabled(if: !isVirtualMachine, "a virtual machine has a virtual GPU, CPU topology, and disk")
    }
}

extension LiveTests {
    @Test(
        "CPU clusters: this Mac's performance levels by name and size, covering every core once",
        .physicalMacOnly
    )
    func clusterMembership() throws {
        let clusters = SystemSources.cpuClusters()
        let levels =
            Int(
                try toolOutput("/usr/sbin/sysctl", ["-n", "hw.nperflevels"]).trimmingCharacters(
                    in: .whitespacesAndNewlines)) ?? 0
        #expect(clusters.count == levels)
        for (index, cluster) in clusters.enumerated() {
            let name = try toolOutput("/usr/sbin/sysctl", ["-n", "hw.perflevel\(index).name"])
            let cores = try toolOutput("/usr/sbin/sysctl", ["-n", "hw.perflevel\(index).logicalcpu"])
            #expect(cluster.name == name.trimmingCharacters(in: .whitespacesAndNewlines))
            #expect(cluster.cores?.count == Int(cores.trimmingCharacters(in: .whitespacesAndNewlines)), "\(cluster)")
        }
        let all = clusters.flatMap { $0.cores ?? [] }.sorted()
        #expect(all == Array(0..<ProcessInfo.processInfo.processorCount))
    }

    @Test(
        "CPU clusters: weighted by core count, the cluster values agree with the total within 1 point, idle and loaded",
        .physicalMacOnly
    )
    func clusterAgreement() async throws {
        let clusters = SystemSources.cpuClusters()
        try #require(clusters.allSatisfy { $0.cores != nil })
        var meter = CPUMeter(source: MachCPUTickSource(), form: .clusters, clusters: clusters)
        meter.rebaseline(at: clock.now)
        let load = CPULoad()
        defer { load.stop() }
        for second in 0..<6 {
            if second == 3 { load.start() }
            try await Task.sleep(for: CPUMeter.interval)
            meter.sample(at: clock.now)
            let total = try #require(meter.percent)
            let weighted =
                zip(clusters, meter.clusterReadings).reduce(0.0) {
                    $0 + Double(($1.0.cores?.count ?? 0) * ($1.1.percent ?? 0))
                } / Double(clusters.reduce(0) { $0 + ($1.cores?.count ?? 0) })
            #expect(
                abs(weighted - Double(total)) <= 1, "clusters \(meter.clusterReadings.map(\.percent)) against \(total)%"
            )
        }
    }

    // Skipped, not failed, on a Mac without a battery. There Settings greys out Battery instead, which the Settings
    // model tests cover.
    @Test(
        "Battery: the percent is within 1 point of pmset, and the arrow follows ioreg's current",
        .enabled(if: SystemSources.hasBattery(), "this Mac has no battery")
    )
    func batteryAccuracy() throws {
        for _ in 0..<3 {
            let current = { () throws -> Int? in
                try ioregSmartBattery().firstMatch(of: /"InstantAmperage" = (\d+)/).flatMap {
                    signedRegistryNumber($0.output.1)
                }
            }
            let before = try current()
            var meter = BatteryMeter(source: SystemSources.battery())
            meter.sample(at: .now)
            let after = try current()
            let pmset = try toolOutput("/usr/bin/pmset", ["-g", "batt"])
            let theirs = try #require(pmset.firstMatch(of: /(\d+)%/).flatMap { Int($0.output.1) })
            let ours = try #require(meter.percent)
            #expect(abs(ours - theirs) <= 1, "meters \(ours)%, pmset \(theirs)%")
            // Compare the arrow when ioreg's current stayed on one side of the threshold across the read.
            let directions = [before, after].map { BatteryMeter.direction(milliamps: $0) }
            if directions[0] == directions[1] {
                #expect(
                    meter.direction == directions[0],
                    "meters \(meter.direction), ioreg \(String(describing: before)) mA")
            }
        }
    }

    @Test("Thermal: the word matches the system's thermal state")
    func thermalMatches() {
        var meter = ThermalMeter(source: SystemThermalSource())
        meter.sample(at: .now)
        #expect(meter.rows[0].value == ThermalModuleText.value(ProcessInfo.processInfo.thermalState))
    }

    @Test("Swap: within 1 MB of sysctl vm.swapusage's used figure")
    func swapMatches() throws {
        let ours = try #require(SystemSwapSource().readSwapUsed())
        let output = try toolOutput("/usr/sbin/sysctl", ["-n", "vm.swapusage"])
        let used = try #require(output.firstMatch(of: /used = ([\d.]+)M/).flatMap { Double($0.output.1) })
        // sysctl prints mebibytes to two decimals.
        #expect(
            abs(Double(ours) - used * 1_048_576) <= 1_048_576 + 0.005 * 1_048_576, "meters \(ours), sysctl \(used)M")
    }

    @Test("Free space: within 1% of Finder's figure read directly, and never below df's")
    func freeSpaceMatches() throws {
        var meter = FreeSpaceMeter(source: SystemFreeSpaceSource())
        meter.sample(at: .now)
        let ours = try #require(meter.bytes)
        let direct = try #require(
            URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage)
        #expect(abs(Double(ours) - Double(direct)) <= 0.01 * Double(direct), "meters \(ours), direct \(direct)")
        let df = try toolOutput("/bin/df", ["-k", "/"]).split(separator: "\n").last?.split(separator: " ")
        let dfAvailable = try #require(df.flatMap { $0.count > 3 ? UInt64($0[3]) : nil }) * 1024
        #expect(ours >= dfAvailable, "meters \(ours), df \(dfAvailable)")
    }
}

extension LiveTests {
    @Test("Memory pressure: the source reads the same level as sysctl (threshold-states Behavior Details)")
    func memoryPressureMatches() throws {
        let ours = try #require(SystemSources.memoryPressure().readPressure())
        let output = try toolOutput("/usr/sbin/sysctl", ["-n", "kern.memorystatus_vm_pressure_level"])
        let level = try #require(Int(output.trimmingCharacters(in: .whitespacesAndNewlines)))
        let expected: [Int: MemoryPressure] = [1: .normal, 2: .warning, 4: .critical]
        #expect(ours == expected[level], "meters \(ours), sysctl \(level)")
    }
}
