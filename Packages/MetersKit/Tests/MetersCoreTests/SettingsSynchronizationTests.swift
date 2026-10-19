import Foundation
import Testing

@testable import MetersCore

@MainActor
@Suite("Settings synchronization")
struct SettingsSynchronizationTests {
    let temporary = TemporaryDefaults()

    @Test("Dependent edits publish one complete state synchronously and persist together")
    func completeUpdate() {
        let store = HUDSettingsStore(defaults: temporary.defaults)
        var changes: [SettingsChange] = []
        store.addObserver { change in
            changes.append(change)
            #expect(store.state == change.current)
            #expect(HUDSettingsStore(defaults: temporary.defaults).state == change.current)
        }
        store.update {
            $0.cpuForm = .clusters
            $0.networkForm = .twoRows
            $0.diskForm = .twoRows
        }
        #expect(changes.count == 1)
        #expect(changes.first?.previous.cpuForm == .total)
        #expect(changes.first?.current.cpuForm == .clusters)
        #expect(changes.first?.current.networkForm == .twoRows)
        #expect(changes.first?.current.diskForm == .twoRows)
    }

    @Test("Repeated preference notifications and no-op edits do not publish duplicate transitions")
    func duplicateNotifications() {
        let store = HUDSettingsStore(defaults: temporary.defaults)
        var changes: [SettingsChange] = []
        store.addObserver { changes.append($0) }
        store.networkForm = .twoRows
        store.networkForm = .twoRows
        for _ in 0..<5 { store.reload() }
        var explicitDefaults = ThresholdSettings()
        for id in ThresholdEditor.modules { explicitDefaults[id] = ThresholdSettings.defaultSetting(id) }
        store.thresholds = explicitDefaults
        #expect(changes.count == 1)
        #expect(store.state.networkForm == .twoRows)
    }

    @Test("A local edit preserves outside changes whose notifications have not been delivered")
    func pendingOutsideWrite() {
        let store = HUDSettingsStore(defaults: temporary.defaults)
        let outside = UserDefaults(suiteName: temporary.suiteName)!
        outside.set("twoRows", forKey: HUDSettingsStore.networkFormKey)
        outside.set(5.0, forKey: HUDSettingsStore.sampleIntervalKey)
        store.cpuForm = .clusters
        #expect(store.state.networkForm == .twoRows)
        #expect(store.state.sampleInterval == 5)
        #expect(store.state.cpuForm == .clusters)
        #expect(HUDSettingsStore(defaults: temporary.defaults).state == store.state)
    }

    @Test("Malformed outside preferences normalize before publication without rewriting saved choices")
    func normalization() {
        let store = HUDSettingsStore(defaults: temporary.defaults)
        let outside = UserDefaults(suiteName: temporary.suiteName)!
        outside.set(3.0, forKey: HUDSettingsStore.sampleIntervalKey)
        outside.set(["cpu": ["elevated": 101.0]], forKey: HUDSettingsStore.thresholdsKey)
        outside.set([["id": "battery", "on": true]], forKey: HUDSettingsStore.modulesKey)
        var changes: [SettingsChange] = []
        store.addObserver { changes.append($0) }
        store.reload()
        #expect(changes.count == 1)
        #expect(store.sampleInterval == 1 && store.thresholds == .defaults)
        let resolved = store.state.resolved(for: SystemCapabilities(hasBattery: false, cpuClusters: 2))
        #expect(resolved.entries.filter(\.isOn).map(\.id) == [.cpu])
        #expect(resolved.shown == [.cpu])
        #expect(store.modules.first?.id == .battery && store.modules.first?.isOn == true)
        #expect(outside.double(forKey: HUDSettingsStore.sampleIntervalKey) == 3)
    }

    @Test("Removed observers stop receiving changes")
    func observerRemoval() {
        let store = HUDSettingsStore(defaults: temporary.defaults)
        var changes = 0
        let token = store.addObserver { _ in changes += 1 }
        store.networkForm = .twoRows
        store.removeObserver(token)
        store.networkForm = .oneRow
        #expect(changes == 1)
    }

    @Test("An observer's follow-up edit is delivered to every listener in transition order")
    func reentrantUpdates() {
        let store = HUDSettingsStore(defaults: temporary.defaults)
        store.addObserver { change in
            if !change.current.isHUDVisible && change.current.networkForm == .oneRow {
                store.networkForm = .twoRows
            }
        }
        var received: [SettingsState] = []
        store.addObserver { received.append($0.current) }
        store.isHUDVisible = false
        #expect(received.count == 2)
        #expect(received.first?.networkForm == .oneRow && received.first?.isHUDVisible == false)
        #expect(received.last?.networkForm == .twoRows && received.last?.isHUDVisible == false)
        #expect(store.state == received.last)
    }
}
