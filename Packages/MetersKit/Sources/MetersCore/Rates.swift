import Foundation

/// The shared rate format and its spoken form: bytes per
/// second, decimal units, 3 significant digits, suffix K, M, or G, and no unit or "/s".
public enum RateFormat {
    private static let units: [(suffix: String, scale: Double, spoken: String)] = [
        ("K", 1e3, "kilobytes"), ("M", 1e6, "megabytes"), ("G", 1e9, "gigabytes"),
    ]
    private static let terabytes = (suffix: "T", scale: 1e12, spoken: "terabytes")

    /// The displayed number and its unit word, for example ("1.25", "M", "megabytes"). Terabytes are used only
    /// where allowed (free space); otherwise values cap at "999G".
    private static func parts(
        _ bytesPerSecond: Double, allowTerabytes: Bool = false
    ) -> (number: String, suffix: String, spoken: String) {
        let rate = max(0, bytesPerSecond.isFinite ? bytesPerSecond : 0)
        let bytes = rate.rounded()
        if bytes < 1000 {
            let number = String(Int(bytes))
            return (number, "", number == "1" ? "byte" : "bytes")
        }
        for unit in allowTerabytes ? units + [terabytes] : units {
            let value = rate / unit.scale
            // Round to 3 significant digits; a result of 1000 or more belongs to the next unit.
            let decimals = value < 9.995 ? 2 : value < 99.95 ? 1 : 0
            let number = String(format: "%.\(decimals)f", value)
            if (Double(number) ?? 0) < 1000 { return (number, unit.suffix, unit.spoken) }
        }
        return allowTerabytes ? ("999", "T", "terabytes") : ("999", "G", "gigabytes")
    }

    /// "0", "820", "12.3K", "1.25M", "123M", "1.25G"; values beyond "999G" show "999G".
    public static func value(_ bytesPerSecond: Double) -> String {
        let parts = parts(bytesPerSecond)
        return parts.number + parts.suffix
    }

    /// "820 bytes per second", "1.25 megabytes per second".
    public static func spoken(_ bytesPerSecond: Double) -> String {
        let parts = parts(bytesPerSecond)
        return "\(parts.number) \(parts.spoken) per second"
    }

    /// An amount of bytes, in the same format: "675G", or "1.20T" where terabytes are allowed.
    public static func amount(_ bytes: Double, allowTerabytes: Bool = false) -> String {
        let parts = parts(bytes, allowTerabytes: allowTerabytes)
        return parts.number + parts.suffix
    }

    /// The amount the row displays, in bytes: 1,004,000,000 shows as "1.00G", so this gives 1,000,000,000.
    /// Thresholds compare against it, so the color always matches the number.
    public static func displayedAmount(_ bytes: Double, allowTerabytes: Bool = false) -> Double {
        let parts = parts(bytes, allowTerabytes: allowTerabytes)
        let scales: [String: Double] = ["K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12]
        let scale = scales[parts.suffix] ?? 1
        return (Double(parts.number) ?? 0) * scale
    }

    /// An amount of bytes, spoken: "675 gigabytes", "0 bytes".
    public static func spokenAmount(_ bytes: Double, allowTerabytes: Bool = false) -> String {
        let parts = parts(bytes, allowTerabytes: allowTerabytes)
        return "\(parts.number) \(parts.spoken)"
    }
}

public enum RateSparkline {
    /// Scales rates to 0 to 1 against the highest rate among them, but never below `floor`, so
    /// background activity stays flat.
    public static func normalized(_ rates: [Double?], floor: Double) -> [Double?] {
        let scale = max(floor, rates.compactMap { $0 }.max() ?? 0)
        return rates.map { $0.map { min(1, max(0, $0 / scale)) } }
    }
}

/// Cumulative byte counters for one interface or disk, in the module's two directions: received and
/// sent, or read and written.
public struct ByteCounters: Equatable, Sendable {
    public var first: UInt64
    public var second: UInt64

    public init(first: UInt64, second: UInt64) {
        self.first = first
        self.second = second
    }
}

/// Data source for a two-rate module. It reports counters per item (interface or disk), keyed by a
/// stable identifier, so items that appear, disappear, or reset never distort the total.
public protocol ByteCounterSource: Sendable {
    /// The current counters of every counted item, or `nil` when the read fails.
    func readCounters() -> [String: ByteCounters]?
    /// The counters and their device names from the same read. Names are optional metadata; a missing
    /// name never removes a device's counters from the total.
    func readSnapshot() -> ByteCounterSnapshot?
}

extension ByteCounterSource {
    public func readSnapshot() -> ByteCounterSnapshot? {
        readCounters().map { ByteCounterSnapshot(counters: $0) }
    }
}

/// A rate reading with display names keyed by the same stable IDs as its counters.
public struct ByteCounterSnapshot: Equatable, Sendable {
    public var counters: [String: ByteCounters]
    public var deviceNames: [String: String]

    public init(counters: [String: ByteCounters], deviceNames: [String: String] = [:]) {
        self.counters = counters
        self.deviceNames = deviceNames
    }

    /// Only names belonging to counted devices, in stable ID order, with resolved names before ID
    /// fallbacks. Keep duplicates: two identical drives are still two devices. Unknown names remain absent.
    public var deviceName: String? {
        let identifiers = counters.keys.sorted { left, right in
            let leftFallback = deviceNames[left] == nil || deviceNames[left] == left
            let rightFallback = deviceNames[right] == nil || deviceNames[right] == right
            return (leftFallback ? 1 : 0, left) < (rightFallback ? 1 : 0, right)
        }
        let names = identifiers.compactMap { id -> String? in
            guard let name = deviceNames[id]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return nil
            }
            return name
        }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }
}

/// Turns counter readings into a two-rate module's values and sparklines.
public struct RateMeter: ModuleMeter {
    /// The sparklines' lowest full-scale rate, in bytes per second.
    public let floor: Double
    /// One row with both rates as numbers, or two rows with sparklines. Changing it keeps the history.
    public var form: RateForm
    /// How the one-row form speaks each direction, such as "download" and "upload".
    public let directionNames: (first: String, second: String)
    /// The rates to display, in bytes per second; `nil` shows the placeholder.
    public private(set) var firstRate: Double?
    public private(set) var secondRate: Double?
    public private(set) var firstHistory = SampleHistory(capacity: MeterTiming.historyCapacity)
    public private(set) var secondHistory = SampleHistory(capacity: MeterTiming.historyCapacity)
    public private(set) var deviceName: String?

    private let source: any ByteCounterSource
    private var baseline: (counters: [String: ByteCounters], time: ContinuousClock.Instant)?
    private var staleness = StalenessLimit()

    public init(
        source: any ByteCounterSource, floor: Double, form: RateForm = .twoRows,
        directionNames: (first: String, second: String) = ("", "")
    ) {
        self.source = source
        self.floor = floor
        self.form = form
        self.directionNames = directionNames
    }

    /// Records the baseline the next reading is measured against. Used at launch and after wake.
    public mutating func rebaseline(at now: ContinuousClock.Instant) {
        let snapshot = source.readSnapshot()
        baseline = snapshot.map { (counters: $0.counters, time: now) }
        deviceName = snapshot?.deviceName
    }

    public mutating func setInterval(_ interval: Duration) {
        staleness.setInterval(interval)
    }

    public mutating func sample(at now: ContinuousClock.Instant) {
        guard let snapshot = source.readSnapshot() else {
            // A failed read shows the placeholder and leaves a gap; the old baseline still applies.
            deviceName = nil
            record(nil, nil)
            return
        }
        let counters = snapshot.counters
        defer { baseline = (counters: counters, time: now) }
        let limit = staleness.take()
        guard let baseline, now - baseline.time <= limit else { return }
        let seconds = (now - baseline.time).timeInterval
        guard seconds > 0 else { return }
        var first: UInt64 = 0
        var second: UInt64 = 0
        for (item, current) in counters {
            // A new item's first reading is only its baseline; a counter that went backwards (a reset or
            // a replaced item) contributes nothing for this sample.
            guard let previous = baseline.counters[item] else { continue }
            if current.first >= previous.first { first += current.first - previous.first }
            if current.second >= previous.second { second += current.second - previous.second }
        }
        deviceName = snapshot.deviceName
        record(Double(first) / seconds, Double(second) / seconds)
    }

    private mutating func record(_ first: Double?, _ second: Double?) {
        firstRate = first
        secondRate = second
        firstHistory.append(first)
        secondHistory.append(second)
    }

    public var rows: [MeterRow] {
        switch form {
        case .twoRows:
            return [row(firstRate, firstHistory), row(secondRate, secondHistory)]
        case .oneRow:
            let spoken =
                if let firstRate, let secondRate {
                    "\(directionNames.first) \(RateFormat.spoken(firstRate)), "
                        + "\(directionNames.second) \(RateFormat.spoken(secondRate))"
                } else {
                    MeterText.noData
                }
            return [
                MeterRow(
                    value: firstRate.map(RateFormat.value) ?? MeterText.placeholder, spokenValue: spoken, samples: [],
                    hasData: firstRate != nil, secondValue: secondRate.map(RateFormat.value) ?? MeterText.placeholder,
                    deviceName: deviceName)
            ]
        }
    }

    private func row(_ rate: Double?, _ history: SampleHistory) -> MeterRow {
        MeterRow(
            value: rate.map(RateFormat.value) ?? MeterText.placeholder,
            spokenValue: rate.map(RateFormat.spoken) ?? MeterText.noData,
            samples: RateSparkline.normalized(history.samples, floor: floor), hasData: rate != nil)
    }
}

extension Duration {
    public var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
