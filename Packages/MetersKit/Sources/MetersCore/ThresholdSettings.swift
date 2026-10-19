import Foundation

/// One module's editable highlighting: its switch, and its amber and red numbers in
/// the field's unit (percent, or GB for Swap). An absent number turns that state off.
public struct ThresholdSetting: Equatable, Sendable {
    public var highlight: Bool
    public var elevated: Double?
    public var critical: Double?

    public init(highlight: Bool = true, elevated: Double? = nil, critical: Double? = nil) {
        self.highlight = highlight
        self.elevated = elevated
        self.critical = critical
    }
}

/// How a module's two threshold fields read and what they mean.
public struct ThresholdFields: Equatable, Sendable {
    public let elevatedLabel: String
    public let criticalLabel: String
    public let unit: String
    public let step: Double
    public let range: ClosedRange<Double>
    public let defaults: ThresholdSetting
    /// Percentages take whole numbers; gigabytes may be fractional.
    public var wholeNumbers: Bool { unit != "GB" }
    let direction: ThresholdRule.Direction
    let elevatedInclusive: Bool
    let criticalInclusive: Bool
    /// Multiplies a field value into the value the meter compares: 1 for percent, 1e9 for GB.
    let scale: Double

    /// The rule for these numbers; `nil` when both are empty.
    public func rule(elevated: Double?, critical: Double?) -> ThresholdRule? {
        guard elevated != nil || critical != nil else { return nil }
        return ThresholdRule(
            direction: direction,
            elevated: elevated.map { .init($0 * scale, inclusive: elevatedInclusive) },
            critical: critical.map { .init($0 * scale, inclusive: criticalInclusive) })
    }

    /// Why a pair cannot be used, or `nil` when it can.
    public func problem(elevated: Double?, critical: Double?) -> String? {
        for value in [elevated, critical].compactMap({ $0 }) where !value.isFinite || !range.contains(value) {
            return "Enter a number from \(Self.number(range.lowerBound)) to \(Self.number(range.upperBound))."
        }
        // Percentages are compared as whole numbers, so a fraction would not mean what it says.
        if wholeNumbers, [elevated, critical].contains(where: { $0.map { $0 != $0.rounded() } ?? false }) {
            return "Enter a whole number."
        }
        guard let elevated, let critical else { return nil }
        switch direction {
        case .high: return critical < elevated ? "Red must be above Amber." : nil
        case .low: return critical > elevated ? "Red must be below Amber." : nil
        }
    }

    /// "0", "100", "1,000".
    static func number(_ value: Double) -> String {
        value.formatted(.number.grouping(.automatic).precision(.fractionLength(0...1)))
    }
}

/// The modules on the Thresholds tab and their fields. Network and Disk have no thresholds.
public enum ThresholdEditor {
    public static let modules: [ModuleID] = [.cpu, .memory, .gpu, .battery, .thermal, .swap, .freeSpace]

    static let percent: ClosedRange<Double> = 0...100

    /// The fields for a module with numbers; `nil` for Memory and Thermal, which follow macOS's levels.
    public static func fields(_ id: ModuleID) -> ThresholdFields? {
        switch id {
        case .cpu:
            ThresholdFields(
                elevatedLabel: "Amber from", criticalLabel: "Red above", unit: "%", step: 1, range: percent,
                defaults: ThresholdSetting(elevated: 70, critical: 80), direction: .high, elevatedInclusive: true,
                criticalInclusive: false, scale: 1)
        case .gpu:
            ThresholdFields(
                elevatedLabel: "Amber from", criticalLabel: "Red above", unit: "%", step: 1, range: percent,
                defaults: ThresholdSetting(elevated: 90, critical: nil), direction: .high, elevatedInclusive: true,
                criticalInclusive: false, scale: 1)
        case .battery:
            ThresholdFields(
                elevatedLabel: "Amber at or below", criticalLabel: "Red at or below", unit: "%", step: 1,
                range: percent, defaults: ThresholdSetting(elevated: 20, critical: 10), direction: .low,
                elevatedInclusive: true, criticalInclusive: true, scale: 1)
        case .swap:
            ThresholdFields(
                elevatedLabel: "Amber over", criticalLabel: "Red over", unit: "GB", step: 0.5, range: 0...1000,
                defaults: ThresholdSetting(elevated: 1, critical: 8), direction: .high, elevatedInclusive: false,
                criticalInclusive: false, scale: 1e9)
        case .freeSpace:
            ThresholdFields(
                elevatedLabel: "Amber under", criticalLabel: "Red under", unit: "% of capacity", step: 1,
                range: percent, defaults: ThresholdSetting(elevated: 10, critical: 5), direction: .low,
                elevatedInclusive: false, criticalInclusive: false, scale: 1)
        case .memory, .thermal, .network, .disk: nil
        }
    }

    /// The line under a switch-only module.
    public static func note(_ id: ModuleID) -> String? {
        switch id {
        case .memory: "Follows macOS memory pressure."
        case .thermal: "Hot is amber; Critical is red."
        default: nil
        }
    }
}

/// Every module's highlighting, as the user set it. Missing modules use the defaults.
public struct ThresholdSettings: Equatable, Sendable {
    public private(set) var values: [ModuleID: ThresholdSetting]

    public init(_ values: [ModuleID: ThresholdSetting] = [:]) {
        self.values = values
    }

    public static let defaults = ThresholdSettings()

    public static func defaultSetting(_ id: ModuleID) -> ThresholdSetting {
        ThresholdEditor.fields(id)?.defaults ?? ThresholdSetting()
    }

    public subscript(id: ModuleID) -> ThresholdSetting {
        get { values[id] ?? Self.defaultSetting(id) }
        set { values[id] = newValue }
    }

    /// The rule a numeric module uses; `nil` when its highlighting is off or both numbers are empty.
    public func rule(for id: ModuleID) -> ThresholdRule? {
        let setting = self[id]
        guard setting.highlight, let fields = ThresholdEditor.fields(id) else { return nil }
        return fields.rule(elevated: setting.elevated, critical: setting.critical)
    }

    /// Whether a switch-only module (Memory, Thermal) highlights.
    public func highlights(_ id: ModuleID) -> Bool {
        self[id].highlight
    }

    /// Equal when every module's effective setting is, whether stored explicitly or taken from the defaults.
    public static func == (lhs: ThresholdSettings, rhs: ThresholdSettings) -> Bool {
        ThresholdEditor.modules.allSatisfy { lhs[$0] == rhs[$0] }
    }
}
