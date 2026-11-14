// Development-only executable. Never linked into the meters app.
import Foundation
import MetersCore

struct Check: Encodable {
    var name: String
    var passed: Bool
    var detail: String
}

struct Report: Encodable {
    var sandboxExpected: Bool
    var home: String
    var hasBattery: Bool
    var networkDeviceNames: [String: String]
    var checks: [Check]
}

let sandboxExpected = CommandLine.arguments.contains("--sandbox")
var checks: [Check] = []

@MainActor func check(_ name: String, _ passed: Bool, _ detail: String) {
    checks.append(Check(name: name, passed: passed, detail: detail))
}

let home = NSHomeDirectory()
let containerHome = home.contains("/Library/Containers/")
check("container", containerHome == sandboxExpected, home)

// A unique file outside the container proves enforcement, rather than only inspecting the signature.
let outside = URL(fileURLWithPath: "/private/tmp/meters-sandbox-\(UUID().uuidString)")
do {
    try Data("sandbox check".utf8).write(to: outside)
    try FileManager.default.removeItem(at: outside)
    check("outside-write", !sandboxExpected, "write outside container permitted")
} catch {
    let code = (error as NSError).code
    let denied = (error as NSError).domain == NSCocoaErrorDomain && code == NSFileWriteNoPermissionError
    check("outside-write", sandboxExpected && denied, String(describing: error))
}

let key = "sandbox-check-\(UUID().uuidString)"
UserDefaults.standard.set(key, forKey: key)
check("preferences", UserDefaults.standard.string(forKey: key) == key, "unique test key read back")
UserDefaults.standard.removeObject(forKey: key)

let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(key).instance.lock")
do {
    defer { try? FileManager.default.removeItem(at: lockURL) }
    let first = InstanceLock(domain: key)
    let second = InstanceLock(domain: key)
    check("instance-lock", first != nil && second == nil, FileManager.default.temporaryDirectory.path)
    withExtendedLifetime(first) {}
}

let source = MachCPUTickSource()
let first = source.readTicks()
let cores = source.readCoreTicks()
Thread.sleep(forTimeInterval: 0.5)
let second = source.readTicks()
let fraction = first.flatMap { old in second.flatMap { CPUUtilization.fraction(from: old, to: $0) } }
check("cpu", fraction != nil, "busy fraction: \(String(describing: fraction)); cores: \(cores?.count ?? 0)")

let clusters = SystemSources.cpuClusters()
let members = clusters.flatMap { $0.cores ?? [] }
check(
    "cpu-clusters",
    !clusters.isEmpty && clusters.allSatisfy { $0.cores != nil }
        && Set(members) == Set(0..<(cores?.count ?? 0)) && members.count == Set(members).count,
    clusters.map { "\($0.name): \(String(describing: $0.cores))" }.joined(separator: "; "))

let memory = MachMemorySource()
let pages = memory.readPages()
check("memory", pages != nil && memory.physicalMemory > 0, String(describing: pages))
let pressure = SystemSources.memoryPressure().readPressure()
check("memory-pressure", pressure != nil, String(describing: pressure))

let gpu = SystemSources.gpu().readUtilization()
check("gpu", gpu.map { $0.isFinite && (0...100).contains($0) } ?? false, String(describing: gpu))

let network = SystemNetworkSource().readSnapshot()
check("network", network.map { !$0.counters.isEmpty } ?? false, String(describing: network))
let disk = SystemDiskSource().readSnapshot()
check(
    "disk", disk.map { !$0.counters.isEmpty && !$0.deviceNames.isEmpty } ?? false,
    String(describing: disk))

let battery = SystemSources.battery().readBattery()
let hasBattery = SystemSources.hasBattery()
check("battery", !hasBattery || battery != nil, hasBattery ? String(describing: battery) : "no internal battery")
check(
    "battery-current", !hasBattery || battery?.milliamps != nil,
    hasBattery ? String(describing: battery?.milliamps) : "no internal battery")

let thermal = SystemThermalSource().readThermalState()
check("thermal", true, ThermalModuleText.value(thermal))
let swap = SystemSwapSource().readSwapUsed()
check("swap", swap != nil, String(describing: swap))
let space = SystemFreeSpaceSource()
let available = space.readAvailable()
let important = space.readAvailableForImportantUsage()
let capacity = space.readCapacity()
check(
    "free-space", available != nil && important != nil && capacity.map { $0 > 0 } == true,
    "available: \(String(describing: available)); important: \(String(describing: important)); capacity: \(String(describing: capacity))"
)

// Read only. Registering a login item belongs to manual verification of the final build.
check("login-status-read", true, String(describing: SystemLoginItemService().status))

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let data = try encoder.encode(
    Report(
        sandboxExpected: sandboxExpected, home: home, hasBattery: hasBattery,
        networkDeviceNames: network?.deviceNames ?? [:], checks: checks))
print(String(decoding: data, as: UTF8.self))
exit(checks.allSatisfy(\.passed) ? 0 : 1)
