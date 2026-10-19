import Foundation
import IOKit

/// Data source for GPU utilization. The GPU module reads only through this protocol, so tests can substitute a
/// fake and the undocumented source stays replaceable.
public protocol GPUUtilizationSource: Sendable {
    /// The GPU's device utilization in percent, or `nil` when no GPU reports a readable figure.
    func readUtilization() -> Double?
}

/// The system's data sources, created here so UI code never references one that reads undocumented keys.
public enum SystemSources {
    public static func gpu() -> any GPUUtilizationSource {
        IOKitGPUSource()
    }
}

/// Undocumented source: the "Device Utilization %" figure in each GPU accelerator's "PerformanceStatistics"
/// registry dictionary. The key is undocumented and may change between macOS releases; when it is
/// missing or not a number, the reading is `nil` and the module shows "n/a".
struct IOKitGPUSource: GPUUtilizationSource {
    static let statisticsKey = "PerformanceStatistics"
    static let utilizationKey = "Device Utilization %"

    func readUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator)
                == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        var highest: Double?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            let property = IORegistryEntryCreateCFProperty(
                service, Self.statisticsKey as CFString, kCFAllocatorDefault, 0)
            guard let statistics = property?.takeRetainedValue() as? [String: Any],
                let number = statistics[Self.utilizationKey] as? NSNumber,
                number.doubleValue.isFinite
            else { continue }
            highest = max(highest ?? 0, number.doubleValue)
        }
        return highest
    }
}

/// Turns GPU readings into the GPU module's value and sparkline history. Each reading
/// stands on its own, so there is no baseline.
public struct GPUMeter: ModuleMeter {
    /// The value to display; `nil` shows the placeholder or, once sampling has failed, "n/a".
    public private(set) var percent: Int?
    public private(set) var isUnavailable = false
    public private(set) var history = SampleHistory(capacity: MeterTiming.historyCapacity)
    public private(set) var highlight = Highlight(rule: ThresholdDefaults.gpu)

    private let source: any GPUUtilizationSource

    public init(source: any GPUUtilizationSource) {
        self.source = source
    }

    @discardableResult
    public mutating func applyThresholds(_ settings: ThresholdSettings) -> Bool {
        highlight.setRule(settings.rule(for: .gpu))
    }

    @discardableResult
    public mutating func resetStates() -> Bool {
        highlight.reset()
    }

    public mutating func sample(at now: ContinuousClock.Instant) {
        guard let utilization = source.readUtilization(), utilization.isFinite else {
            percent = nil
            isUnavailable = true
            history.append(nil)
            highlight.record(nil)
            return
        }
        // Readable numbers outside 0 to 100 are clamped, not treated as unavailable.
        let fraction = min(1, max(0, utilization / 100))
        percent = MeterText.percent(fraction)
        isUnavailable = false
        history.append(fraction)
        highlight.record(percent.map(Double.init))
    }

    public var rows: [MeterRow] {
        [
            MeterRow(
                value: isUnavailable ? GPUModuleText.unavailable : MeterText.value(percent),
                spokenValue: isUnavailable ? GPUModuleText.spokenUnavailable : MeterText.spoken(percent),
                samples: history.samples, hasData: percent != nil, isUnavailable: isUnavailable,
                state: highlight.state, offersGauge: true, gaugeFraction: percent.map { Double($0) / 100 })
        ]
    }
}

/// The GPU module's visible and spoken text.
public enum GPUModuleText {
    public static let label = "GPU"
    public static let unavailable = "n/a"
    public static let spokenUnavailable = "unavailable"
}
