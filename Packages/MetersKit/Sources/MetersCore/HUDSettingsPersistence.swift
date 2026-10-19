import CoreGraphics
import Foundation

/// Keeps the existing preference keys and encoding separate from in-memory state publication.
@MainActor
final class HUDSettingsPersistence {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func load() -> SettingsState {
        var state = SettingsState()
        state.isHUDVisible = isHUDVisible
        state.placement = placement
        state.modules = modules
        state.networkForm = networkForm
        state.diskForm = diskForm
        state.cpuForm = cpuForm
        state.settingsTab = settingsTab
        state.sampleInterval = sampleInterval
        state.thresholds = thresholds
        state.graphStyle = graphStyle
        return state.normalized()
    }

    func save(_ state: SettingsState, replacing previous: SettingsState) {
        if state.isHUDVisible != previous.isHUDVisible { isHUDVisible = state.isHUDVisible }
        if state.placement != previous.placement { placement = state.placement }
        if state.modules != previous.modules { modules = state.modules }
        if state.networkForm != previous.networkForm { networkForm = state.networkForm }
        if state.diskForm != previous.diskForm { diskForm = state.diskForm }
        if state.cpuForm != previous.cpuForm { cpuForm = state.cpuForm }
        if state.settingsTab != previous.settingsTab { settingsTab = state.settingsTab }
        if state.sampleInterval != previous.sampleInterval { sampleInterval = state.sampleInterval }
        if state.thresholds != previous.thresholds { thresholds = state.thresholds }
        if state.graphStyle != previous.graphStyle { graphStyle = state.graphStyle }
    }

    /// Defaults to visible.
    var isHUDVisible: Bool {
        get { defaults.object(forKey: HUDSettingsStore.visibleKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: HUDSettingsStore.visibleKey) }
    }

    /// Where the HUD was last settled; `nil` before the first drag or when unreadable.
    var placement: HUDPlacement? {
        get {
            guard let stored = defaults.dictionary(forKey: HUDSettingsStore.placementKey),
                let displayID = stored["display"] as? String,
                let corner = (stored["corner"] as? String).flatMap(AnchorCorner.init(rawValue:)),
                let x = stored["x"] as? Double, let y = stored["y"] as? Double, x.isFinite, y.isFinite
            else { return nil }
            let screenEdgeAxis = (stored["screenEdge"] as? String).flatMap(PlacementAxis.init(rawValue:))
            return HUDPlacement(
                displayID: displayID, corner: corner, offset: CGSize(width: x, height: y),
                screenEdgeAxis: screenEdgeAxis)
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: HUDSettingsStore.placementKey)
                return
            }
            var stored: [String: Any] = [
                "display": newValue.displayID, "corner": newValue.corner.rawValue,
                "x": Double(newValue.offset.width), "y": Double(newValue.offset.height),
            ]
            if let axis = newValue.screenEdgeAxis { stored["screenEdge"] = axis.rawValue }
            defaults.set(stored, forKey: HUDSettingsStore.placementKey)
        }
    }

    /// The user's modules, in order, each on or off; defaults to CPU, Memory, and
    /// Network on, then GPU and Disk off.
    var modules: [ModuleEntry] {
        get {
            let stored = (defaults.array(forKey: HUDSettingsStore.modulesKey) as? [[String: Any]])?.compactMap {
                item -> (id: String, isOn: Bool)? in
                guard let id = item["id"] as? String else { return nil }
                return (id: id, isOn: item["on"] as? Bool ?? false)
            }
            return ModuleSelection.normalized(stored)
        }
        set {
            defaults.set(newValue.map { ["id": $0.id.rawValue, "on": $0.isOn] }, forKey: HUDSettingsStore.modulesKey)
        }
    }

    /// Defaults to one row.
    var networkForm: RateForm {
        get { defaults.string(forKey: HUDSettingsStore.networkFormKey).flatMap(RateForm.init(rawValue:)) ?? .oneRow }
        set { defaults.set(newValue.rawValue, forKey: HUDSettingsStore.networkFormKey) }
    }

    /// Defaults to one row.
    var diskForm: RateForm {
        get { defaults.string(forKey: HUDSettingsStore.diskFormKey).flatMap(RateForm.init(rawValue:)) ?? .oneRow }
        set { defaults.set(newValue.rawValue, forKey: HUDSettingsStore.diskFormKey) }
    }

    /// Defaults to Total.
    var cpuForm: CPUForm {
        get { defaults.string(forKey: HUDSettingsStore.cpuFormKey).flatMap(CPUForm.init(rawValue:)) ?? .total }
        set { defaults.set(newValue.rawValue, forKey: HUDSettingsStore.cpuFormKey) }
    }

    /// Sparklines or gauges; anything else reads as Sparklines.
    var graphStyle: GraphStyle {
        get { defaults.string(forKey: HUDSettingsStore.graphsKey).flatMap(GraphStyle.init(rawValue:)) ?? .sparklines }
        set { defaults.set(newValue.rawValue, forKey: HUDSettingsStore.graphsKey) }
    }

    /// Seconds between readings: one of the offered choices, else 1.
    var sampleInterval: Double {
        get {
            let stored = defaults.object(forKey: HUDSettingsStore.sampleIntervalKey) as? Double ?? 1
            return MeterTiming.intervalChoices.contains(stored) ? stored : 1
        }
        set { defaults.set(newValue, forKey: HUDSettingsStore.sampleIntervalKey) }
    }

    /// The user's thresholds. A module's stored entry that is unreadable, out of
    /// range, or an invalid pair is replaced by its defaults; a missing number in a readable entry means off.
    var thresholds: ThresholdSettings {
        get {
            let stored = defaults.dictionary(forKey: HUDSettingsStore.thresholdsKey) ?? [:]
            var settings = ThresholdSettings()
            for id in ThresholdEditor.modules {
                guard let entry = stored[id.rawValue] as? [String: Any] else { continue }
                guard let setting = Self.setting(entry, for: id) else { continue }
                settings[id] = setting
            }
            return settings
        }
        set {
            var stored: [String: Any] = [:]
            for id in ThresholdEditor.modules {
                let setting = newValue[id]
                var entry: [String: Any] = ["highlight": setting.highlight]
                entry["elevated"] = setting.elevated
                entry["critical"] = setting.critical
                stored[id.rawValue] = entry
            }
            defaults.set(stored, forKey: HUDSettingsStore.thresholdsKey)
        }
    }

    private static func setting(_ entry: [String: Any], for id: ModuleID) -> ThresholdSetting? {
        func number(_ key: String) -> Double?? {
            guard let value = entry[key] else { return .some(nil) }
            return (value as? NSNumber).map { .some($0.doubleValue) } ?? nil
        }
        var highlight = true
        if let value = entry["highlight"] {
            guard let stored = value as? Bool else { return nil }
            highlight = stored
        }
        guard let elevated = number("elevated"), let critical = number("critical") else { return nil }
        if let fields = ThresholdEditor.fields(id), fields.problem(elevated: elevated, critical: critical) != nil {
            return nil
        }
        return ThresholdSetting(highlight: highlight, elevated: elevated, critical: critical)
    }

    /// The Settings tab last used, so the window reopens on it.
    var settingsTab: String? {
        get { defaults.string(forKey: HUDSettingsStore.settingsTabKey) }
        set { defaults.set(newValue, forKey: HUDSettingsStore.settingsTabKey) }
    }
}
