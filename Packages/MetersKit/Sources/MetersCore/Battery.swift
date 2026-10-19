import Foundation
import IOKit
import IOKit.ps

/// One battery reading.
public struct BatteryReading: Equatable, Sendable {
    /// Current capacity divided by maximum capacity; may exceed 1 from rounding.
    public var charge: Double
    /// The battery's measured current in milliamps: positive into the battery, negative out of it. `nil`
    /// when the system does not report it.
    public var milliamps: Int?

    public init(charge: Double, milliamps: Int?) {
        self.charge = charge
        self.milliamps = milliamps
    }
}

/// Data source for the internal battery. The Battery module reads only through this protocol.
public protocol BatterySource: Sendable {
    /// The internal battery's reading, or `nil` when no internal battery is reported.
    func readBattery() -> BatteryReading?
}

extension SystemSources {
    public static func battery() -> any BatterySource {
        SystemBatterySource()
    }

    /// Whether this Mac has an internal battery.
    public static func hasBattery() -> Bool {
        SystemBatterySource.internalBattery() != nil
    }
}

/// The charge comes from the documented power-source information. Its current field reads 0 on
/// the development Mac even while charging (measured Sep 27, 2026), so the current comes from the battery
/// controller's "InstantAmperage" registry key, which is undocumented.
struct SystemBatterySource: BatterySource {
    static let amperageKey = "InstantAmperage"

    func readBattery() -> BatteryReading? {
        guard let battery = Self.internalBattery(),
            let capacity = (battery[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue,
            let maximum = (battery[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue, maximum > 0
        else { return nil }
        return BatteryReading(charge: capacity / maximum, milliamps: Self.readMilliamps())
    }

    /// The internal battery's power-source description; other sources, such as a UPS, are ignored.
    static func internalBattery() -> [String: Any]? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in list {
            guard
                let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any],
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                description[kIOPSIsPresentKey] as? Bool != false
            else { continue }
            return description
        }
        return nil
    }

    static func readMilliamps() -> Int? {
        let battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard battery != 0 else { return nil }
        defer { IOObjectRelease(battery) }
        let value = IORegistryEntryCreateCFProperty(battery, amperageKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        // Stored as a signed 64-bit number; int64Value keeps the sign either way.
        return (value as? NSNumber).map { Int($0.int64Value) }
    }
}

/// Turns battery readings into the Battery module's row: the percent, and an arrow for the direction the
/// charge is moving. Each reading stands on its own.
public struct BatteryMeter: ModuleMeter {
    public enum Direction: Equatable, Sendable {
        case charging
        case draining
        case steady
    }

    /// Current within this many milliamps of zero shows no arrow.
    public static let steadyMilliamps = 100

    public private(set) var percent: Int?
    public private(set) var direction: Direction = .steady
    /// Low charge counts only while draining.
    public private(set) var highlight = Highlight(rule: ThresholdDefaults.battery)

    private let source: any BatterySource

    public init(source: any BatterySource) {
        self.source = source
    }

    @discardableResult
    public mutating func applyThresholds(_ settings: ThresholdSettings) -> Bool {
        highlight.setRule(settings.rule(for: .battery))
    }

    @discardableResult
    public mutating func resetStates() -> Bool {
        highlight.reset()
    }

    public static func direction(milliamps: Int?) -> Direction {
        guard let milliamps, abs(milliamps) > steadyMilliamps else { return .steady }
        return milliamps > 0 ? .charging : .draining
    }

    public mutating func sample(at now: ContinuousClock.Instant) {
        guard let reading = source.readBattery(), reading.charge.isFinite else {
            percent = nil
            direction = .steady
            highlight.record(nil)
            return
        }
        let percent = MeterText.percent(reading.charge)
        self.percent = percent
        direction = Self.direction(milliamps: reading.milliamps)
        // Low charge matters only while the battery is actually draining (the arrow shows "↓").
        if direction == .draining {
            highlight.record(Double(percent))
        } else {
            highlight.recordNormal()
        }
    }

    public var rows: [MeterRow] {
        [
            MeterRow(
                value: MeterText.value(percent),
                spokenValue: BatteryModuleText.spokenValue(percent: percent, direction: direction),
                samples: [], hasData: percent != nil,
                valueMarker: percent == nil ? nil : BatteryModuleText.marker(direction), state: highlight.state,
                offersGauge: true, gaugeFraction: percent.map { Double($0) / 100 })
        ]
    }
}

/// The Battery module's visible and spoken text.
public enum BatteryModuleText {
    public static let label = "BATT"
    public static let accessibilityLabel = "Battery"
    public static let noBattery = "No battery"

    public static func marker(_ direction: BatteryMeter.Direction) -> String? {
        switch direction {
        case .charging: "↑"
        case .draining: "↓"
        case .steady: nil
        }
    }

    public static func spokenValue(percent: Int?, direction: BatteryMeter.Direction) -> String {
        guard percent != nil else { return MeterText.noData }
        switch direction {
        case .charging: return MeterText.spoken(percent) + ", charging"
        case .draining: return MeterText.spoken(percent) + ", draining"
        case .steady: return MeterText.spoken(percent)
        }
    }
}
