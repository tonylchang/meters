import Darwin
import Foundation
import Testing

@testable import MetersCore

/// Each block storage driver's read and write byte counters as `ioreg` prints them, keyed like the
/// module's source: the registry entry ID in decimal.
func ioregDiskCounters() throws -> [String: ByteCounters] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
    process.arguments = ["-r", "-c", "IOBlockStorageDriver", "-w0", "-d", "1"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()

    var counters: [String: ByteCounters] = [:]
    var current: String?
    for line in output.split(separator: "\n") {
        if let match = line.firstMatch(of: /<class IOBlockStorageDriver, id 0x([0-9a-f]+)/),
            let identifier = UInt64(match.output.1, radix: 16)
        {
            current = String(identifier)
        } else if let current, let read = line.firstMatch(of: /"Bytes \(Read\)"=(\d+)/),
            let written = line.firstMatch(of: /"Bytes \(Write\)"=(\d+)/),
            let readBytes = UInt64(read.output.1), let writtenBytes = UInt64(written.output.1)
        {
            counters[current] = ByteCounters(first: readBytes, second: writtenBytes)
        }
    }
    return counters
}

extension LiveTests {
    @Test(
        "Writing and reading back a 1 GB file advances the counters by at least 1 GB within 3 s",
        .physicalMacOnly
    )
    func diskFollowsFile() async throws {
        let source = SystemDiskSource()
        let url = FileManager.default.temporaryDirectory.appending(path: "meters-disk-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let chunk = 8 << 20
        let chunks = 128  // 1 GiB, a little over 1 GB.
        var buffer = [UInt8](repeating: 0, count: chunk)
        arc4random_buf(&buffer, chunk)

        func totals() throws -> (read: UInt64, written: UInt64) {
            let counters = try #require(source.readCounters()).values
            return (counters.reduce(0) { $0 + $1.first }, counters.reduce(0) { $0 + $1.second })
        }
        func waitFor(_ condition: () throws -> Bool) async throws -> Bool {
            for _ in 0..<12 {
                if try condition() { return true }
                try await Task.sleep(for: .milliseconds(250))
            }
            return try condition()
        }

        // Write with caching off, then flush to the disk.
        let before = try totals()
        let writer = open(url.path, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
        try #require(writer >= 0)
        _ = fcntl(writer, F_NOCACHE, 1)
        for _ in 0..<chunks { #expect(write(writer, buffer, chunk) == chunk) }
        _ = fcntl(writer, F_FULLFSYNC)
        close(writer)
        let wrote = try await waitFor { try totals().written - before.written >= 1_000_000_000 }
        let writtenBytes = try totals().written - before.written
        #expect(wrote, "wrote \(writtenBytes) bytes")

        // Read it back with caching off, so the reads reach the disk.
        let middle = try totals()
        let reader = open(url.path, O_RDONLY)
        try #require(reader >= 0)
        _ = fcntl(reader, F_NOCACHE, 1)
        while read(reader, &buffer, chunk) > 0 {}
        close(reader)
        let readBack = try await waitFor { try totals().read - middle.read >= 1_000_000_000 }
        let readBytes = try totals().read - middle.read
        #expect(readBack, "read \(readBytes) bytes")
    }

    @Test("Over 5 s, the module's totals are within 1% or 1 MB of the statistics read through ioreg")
    func diskMatchesIoreg() async throws {
        let source = SystemDiskSource()
        var meter = RateMeter(source: source, floor: DiskModuleText.sparklineFloor)
        var time = clock.now
        meter.rebaseline(at: time)
        let counted = try #require(source.readCounters()).keys
        let before = try ioregDiskCounters()

        var read = 0.0
        var written = 0.0
        for _ in 0..<5 {
            try await Task.sleep(for: .seconds(1))
            let now = clock.now
            meter.sample(at: now)
            let seconds = (now - time).timeInterval
            read += try #require(meter.firstRate) * seconds
            written += try #require(meter.secondRate) * seconds
            time = now
        }
        let after = try ioregDiskCounters()
        #expect(Set(counted).isSubset(of: after.keys), "counted \(counted); ioreg \(after.keys)")

        func delta(_ direction: KeyPath<ByteCounters, UInt64>) -> Double {
            counted.reduce(0) { total, key in
                guard let old = before[key]?[keyPath: direction], let new = after[key]?[keyPath: direction],
                    new >= old
                else { return total }
                return total + Double(new - old)
            }
        }
        let expectedRead = delta(\.first)
        let expectedWritten = delta(\.second)
        #expect(abs(read - expectedRead) <= max(expectedRead * 0.01, 1_000_000), "read \(read) vs \(expectedRead)")
        #expect(
            abs(written - expectedWritten) <= max(expectedWritten * 0.01, 1_000_000),
            "written \(written) vs \(expectedWritten)")
    }
}
