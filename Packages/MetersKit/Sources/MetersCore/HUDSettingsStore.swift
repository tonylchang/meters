import Foundation
import Observation

/// Owns committed settings on the main actor. Local changes publish synchronously; preference
/// notifications reload outside writes and discard duplicate echoes of this store's own writes.
@MainActor
@Observable
public final class HUDSettingsStore {
    nonisolated public static let visibleKey = "hudVisible"
    nonisolated public static let placementKey = "hudPlacement"
    nonisolated public static let modulesKey = "hudModules"
    nonisolated public static let networkFormKey = "networkForm"
    nonisolated public static let diskFormKey = "diskForm"
    nonisolated public static let cpuFormKey = "cpuForm"
    nonisolated public static let settingsTabKey = "settingsTab"
    nonisolated public static let sampleIntervalKey = "sampleInterval"
    nonisolated public static let thresholdsKey = "thresholds"
    nonisolated public static let graphsKey = "hudGraphs"

    public private(set) var state: SettingsState

    @ObservationIgnored private let persistence: HUDSettingsPersistence
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var observers: [(id: UUID, handler: @MainActor (SettingsChange) -> Void)] = []
    @ObservationIgnored private var pendingChanges: [SettingsChange] = []
    @ObservationIgnored private var isNotifying = false

    public init(defaults: UserDefaults) {
        persistence = HUDSettingsPersistence(defaults: defaults)
        state = persistence.load()
        func observe<Value>(_ keyPath: KeyPath<UserDefaults, Value>) -> NSKeyValueObservation {
            defaults.observe(keyPath) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.reload() }
            }
        }
        observations = [
            observe(\.hudVisible), observe(\.hudModules), observe(\.networkForm),
            observe(\.diskForm), observe(\.cpuForm), observe(\.sampleInterval),
            observe(\.thresholds), observe(\.hudGraphs), observe(\.hudPlacement), observe(\.settingsTab),
        ]
    }

    /// Applies dependent edits together. Observers receive the complete validated state exactly once.
    public func update(origin: UUID? = nil, _ edit: (inout SettingsState) -> Void) {
        // A queued outside notification must not let a local edit overwrite unrelated newer preferences.
        reload()
        var next = state
        edit(&next)
        next = next.normalized()
        guard next != state else { return }
        persistence.save(next, replacing: state)
        publish(next, origin: origin)
    }

    /// Reconciles the latest preferences. It is also useful before an action that depends on an edit session.
    public func reload() {
        publish(persistence.load())
    }

    @discardableResult
    public func addObserver(_ handler: @escaping @MainActor (SettingsChange) -> Void) -> UUID {
        let id = UUID()
        observers.append((id, handler))
        return id
    }

    public func removeObserver(_ id: UUID) {
        observers.removeAll { $0.id == id }
    }

    private func publish(_ next: SettingsState, origin: UUID? = nil) {
        guard next != state else { return }
        let change = SettingsChange(previous: state, current: next, origin: origin)
        state = next
        pendingChanges.append(change)
        guard !isNotifying else { return }
        isNotifying = true
        defer { isNotifying = false }
        // A listener may perform another update. Deliver transitions in order, without recursive callbacks.
        while !pendingChanges.isEmpty {
            let pending = pendingChanges.removeFirst()
            for observer in observers { observer.handler(pending) }
        }
    }

    public func forms(cpuClusters: Int) -> ModuleForms {
        ModuleForms(cpu: state.cpuForm, network: state.networkForm, disk: state.diskForm, cpuClusters: cpuClusters)
    }

    public var isHUDVisible: Bool {
        get { state.isHUDVisible }
        set { update { $0.isHUDVisible = newValue } }
    }

    public var placement: HUDPlacement? {
        get { state.placement }
        set { update { $0.placement = newValue } }
    }

    public var modules: [ModuleEntry] {
        get { state.modules }
        set { update { $0.modules = newValue } }
    }

    public var networkForm: RateForm {
        get { state.networkForm }
        set { update { $0.networkForm = newValue } }
    }

    public var diskForm: RateForm {
        get { state.diskForm }
        set { update { $0.diskForm = newValue } }
    }

    public var cpuForm: CPUForm {
        get { state.cpuForm }
        set { update { $0.cpuForm = newValue } }
    }

    public var settingsTab: String? {
        get { state.settingsTab }
        set { update { $0.settingsTab = newValue } }
    }

    public var sampleInterval: Double {
        get { state.sampleInterval }
        set { update { $0.sampleInterval = newValue } }
    }

    public var thresholds: ThresholdSettings {
        get { state.thresholds }
        set { update { $0.thresholds = newValue } }
    }

    public var graphStyle: GraphStyle {
        get { state.graphStyle }
        set { update { $0.graphStyle = newValue } }
    }
}

extension UserDefaults {
    // Key-value observable mirrors of the settings keys. Property names must match the keys.
    @objc fileprivate dynamic var hudPlacement: [String: Any]? { dictionary(forKey: HUDSettingsStore.placementKey) }
    @objc fileprivate dynamic var settingsTab: String? { string(forKey: HUDSettingsStore.settingsTabKey) }
    @objc fileprivate dynamic var hudVisible: Bool { bool(forKey: HUDSettingsStore.visibleKey) }
    @objc fileprivate dynamic var hudModules: [Any]? { array(forKey: HUDSettingsStore.modulesKey) }
    @objc fileprivate dynamic var networkForm: String? { string(forKey: HUDSettingsStore.networkFormKey) }
    @objc fileprivate dynamic var diskForm: String? { string(forKey: HUDSettingsStore.diskFormKey) }
    @objc fileprivate dynamic var cpuForm: String? { string(forKey: HUDSettingsStore.cpuFormKey) }
    @objc fileprivate dynamic var hudGraphs: String? { string(forKey: HUDSettingsStore.graphsKey) }
    @objc fileprivate dynamic var sampleInterval: Double { double(forKey: HUDSettingsStore.sampleIntervalKey) }
    @objc fileprivate dynamic var thresholds: [String: Any]? { dictionary(forKey: HUDSettingsStore.thresholdsKey) }
}
