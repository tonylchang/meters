import Foundation
import Testing

@testable import MetersCore

/// Received and sent byte counters per interface, as `netstat -ib` prints them.
func netstatCounters() throws -> [String: ByteCounters] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
    process.arguments = ["-ibn"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()

    var counters: [String: ByteCounters] = [:]
    for line in output.split(separator: "\n").dropFirst() {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        // One link-layer row per interface. The address column can be empty, so count from the end:
        // ... Ibytes Opkts Oerrs Obytes Coll.
        guard fields.count >= 6, fields[2].hasPrefix("<Link#"),
            let received = UInt64(fields[fields.count - 5]), let sent = UInt64(fields[fields.count - 2])
        else { continue }
        counters[String(fields[0])] = ByteCounters(first: received, second: sent)
    }
    return counters
}

extension LiveTests {
    @Test("Over 5 s, the module's totals are within 1% or 10 KB of netstat's counters")
    func networkMatchesNetstat() async throws {
        let source = SystemNetworkSource()
        let counted = try #require(source.readCounters()).keys
        // The module's own counters for the counted interfaces, summed.
        func ours() throws -> (received: Double, sent: Double) {
            let counters = try #require(source.readCounters()).filter { counted.contains($0.key) }.values
            return (counters.reduce(0) { $0 + Double($1.first) }, counters.reduce(0) { $0 + Double($1.second) })
        }
        // netstat takes tens of milliseconds to run, so traffic during each call is allowed for: it is measured
        // by reading the module's counters just before and just after.
        var meter = RateMeter(source: source, floor: NetworkModuleText.sparklineFloor)
        var time = clock.now
        meter.rebaseline(at: time)
        let beforeStart = try ours()
        let before = try netstatCounters()
        let beforeEnd = try ours()

        var received = 0.0
        var sent = 0.0
        for _ in 0..<5 {
            try await Task.sleep(for: .seconds(1))
            let now = clock.now
            meter.sample(at: now)
            let seconds = (now - time).timeInterval
            received += try #require(meter.firstRate) * seconds
            sent += try #require(meter.secondRate) * seconds
            time = now
        }
        let afterStart = try ours()
        let after = try netstatCounters()
        let afterEnd = try ours()

        func delta(_ direction: KeyPath<ByteCounters, UInt64>) -> Double {
            counted.reduce(0) { total, name in
                guard let old = before[name]?[keyPath: direction], let new = after[name]?[keyPath: direction],
                    new >= old
                else { return total }
                return total + Double(new - old)
            }
        }
        let expectedReceived = delta(\.first)
        let expectedSent = delta(\.second)
        let receivedDuringCalls =
            (beforeEnd.received - beforeStart.received) + (afterEnd.received - afterStart.received)
        let sentDuringCalls = (beforeEnd.sent - beforeStart.sent) + (afterEnd.sent - afterStart.sent)
        #expect(
            abs(received - expectedReceived) <= max(expectedReceived * 0.01, 10_000) + receivedDuringCalls,
            "received \(received) vs \(expectedReceived); \(receivedDuringCalls) during the netstat calls")
        #expect(
            abs(sent - expectedSent) <= max(expectedSent * 0.01, 10_000) + sentDuringCalls,
            "sent \(sent) vs \(expectedSent); \(sentDuringCalls) during the netstat calls")
    }
}
