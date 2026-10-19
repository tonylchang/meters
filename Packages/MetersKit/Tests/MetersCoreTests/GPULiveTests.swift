import Foundation
import Metal
import Synchronization
import Testing

@testable import MetersCore

/// Keeps the GPU busy with a compute kernel until stopped. Setup happens in `start()`, so a kernel that
/// fails to compile fails the test instead of leaving the GPU idle.
final class GPULoad: Sendable {
    static let threads = 1 << 20
    static let kernel = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void spin(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
            float x = float(id);
            for (int i = 0; i < 20000; i++) { x = fma(x, 1.000001f, 0.5f); }
            out[id] = x;
        }
        """

    /// Metal objects for the load thread. They are used from that one thread only.
    private struct Work: @unchecked Sendable {
        let queue: MTLCommandQueue
        let pipeline: MTLComputePipelineState
        let output: MTLBuffer
    }

    private let running = Atomic(false)

    func start() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let function = try #require(
            try device.makeLibrary(source: Self.kernel, options: nil).makeFunction(name: "spin"))
        let work = Work(
            queue: try #require(device.makeCommandQueue()),
            pipeline: try device.makeComputePipelineState(function: function),
            output: try #require(device.makeBuffer(length: 4 * Self.threads, options: .storageModePrivate)))
        running.store(true, ordering: .relaxed)
        Thread.detachNewThread { [self] in
            let (queue, pipeline, output) = (work.queue, work.pipeline, work.output)
            // Two command buffers in flight, so the GPU never waits for the next one.
            var previous: MTLCommandBuffer?
            while running.load(ordering: .relaxed) {
                guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder()
                else { break }
                encoder.setComputePipelineState(pipeline)
                encoder.setBuffer(output, offset: 0, index: 0)
                encoder.dispatchThreads(
                    MTLSize(width: Self.threads, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: pipeline.maxTotalThreadsPerThreadgroup, height: 1, depth: 1))
                encoder.endEncoding()
                commands.commit()
                previous?.waitUntilCompleted()
                previous = commands
            }
            previous?.waitUntilCompleted()
        }
    }

    func stop() {
        running.store(false, ordering: .relaxed)
    }
}

/// The GPU's "Device Utilization %" as `ioreg` prints it: the same figure read through a separate tool.
func ioregGPUUtilization() throws -> Double? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
    process.arguments = ["-r", "-c", "IOAccelerator", "-d", "1", "-w0"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    let values = output.matches(of: /"Device Utilization %"=(\d+)/).compactMap { Double($0.output.1) }
    return values.max()
}

/// The middle value; with an even count, the mean of the two middle values.
func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
}

/// Other work is using the GPU when the median of 1 s of readings, before the test's own workload, is above
/// this.
let gpuBusyThreshold = 10.0

extension LiveTests {
    // While the display redraws, the idle figure jumps between 0 and about 27% and holds each value for
    // about half a second, so single readings taken moments apart disagree. These checks compare medians,
    // under a steady workload, and allow more when other work was already using the GPU.

    /// The GPU's level before a test's workload: the median of four readings over 1 s.
    func gpuIdleLevel(_ source: any GPUUtilizationSource) async throws -> Double {
        var readings: [Double] = []
        for _ in 0..<4 {
            readings.append(try #require(source.readUtilization(), "GPU utilization is unavailable"))
            try await Task.sleep(for: .milliseconds(250))
        }
        return median(readings)
    }

    @Test(
        "Under a steady workload, the median reading is within 5 points of ioreg's, or 15 when the GPU was busy"
    )
    func gpuMatchesIoreg() async throws {
        let source = SystemSources.gpu()
        let idle = try await gpuIdleLevel(source)
        let tolerance = idle > gpuBusyThreshold ? 15.0 : 5.0

        let load = GPULoad()
        try load.start()
        defer { load.stop() }
        // Wait until the workload is steady. The figure covers the time since it was last read, by any
        // program, so leave half a second after the last warm-up read.
        for _ in 0..<20 where (source.readUtilization() ?? 0) < 80 {
            try await Task.sleep(for: .milliseconds(250))
        }
        try await Task.sleep(for: .milliseconds(500))

        var ours: [Double] = []
        var theirs: [Double] = []
        // Each read starts a new window for every reader, so alternate the readers evenly: both then cover
        // windows of the same length.
        for _ in 0..<10 {
            ours.append(try #require(source.readUtilization()))
            try await Task.sleep(for: .milliseconds(300))
            theirs.append(try #require(try ioregGPUUtilization()))
            try await Task.sleep(for: .milliseconds(300))
        }
        #expect(median(theirs) >= 50, "the workload should keep the GPU busy; ioreg \(theirs)")
        #expect(
            abs(median(ours) - median(theirs)) <= tolerance,
            "ours \(ours); ioreg \(theirs); \(idle)% before, so \(tolerance) points allowed")
    }

    @Test("A GPU workload raises the reading to 80% or more within 3 s; it falls back within 3 s")
    func gpuFollowsLoad() async throws {
        let source = SystemSources.gpu()
        var meter = GPUMeter(source: source)
        let before = try await gpuIdleLevel(source)
        let allowance = before > gpuBusyThreshold ? 25.0 : 10.0

        let load = GPULoad()
        try load.start()
        defer { load.stop() }
        var peak = 0
        for _ in 0..<3 where peak < 80 {
            try await Task.sleep(for: .seconds(1))
            meter.sample(at: clock.now)
            peak = max(peak, meter.percent ?? 0)
        }
        load.stop()
        #expect(peak >= 80, "peak \(peak)% under a GPU workload")

        var readings: [Int] = []
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(250))
            meter.sample(at: clock.now)
            readings.append(meter.percent ?? 100)
            if let last = readings.last, Double(last) <= before + allowance { break }
        }
        #expect(
            readings.contains { Double($0) <= before + allowance },
            "after the workload: \(readings); \(before)% before, so \(allowance) points allowed")
    }
}
