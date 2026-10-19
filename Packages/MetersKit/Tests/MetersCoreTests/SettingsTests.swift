import Foundation
import Testing

@testable import MetersCore

/// A throwaway settings domain, removed when the test ends.
final class TemporaryDefaults {
    let suiteName = "net.1x0.meters.tests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
        // Removing a domain leaves an empty preferences file behind; delete it too.
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suiteName).plist")
        try? FileManager.default.removeItem(at: file)
    }
}

@MainActor
@Suite("HUD settings")
struct SettingsTests {
    @Test("Defaults: HUD visible")
    func defaults() {
        let temporary = TemporaryDefaults()
        let store = HUDSettingsStore(defaults: temporary.defaults)
        #expect(store.isHUDVisible)
    }

    @Test("Visibility persists across store instances")
    func persistence() {
        let temporary = TemporaryDefaults()
        let first = HUDSettingsStore(defaults: temporary.defaults)
        first.isHUDVisible = false

        let second = HUDSettingsStore(defaults: UserDefaults(suiteName: temporary.suiteName)!)
        #expect(!second.isHUDVisible)
    }

    @Test("A width preset saved by an earlier version is ignored")
    func savedPresetIgnored() {
        let temporary = TemporaryDefaults()
        temporary.defaults.set("wide", forKey: "hudWidthPreset")
        #expect(HUDSettingsStore(defaults: temporary.defaults).state == SettingsState().normalized())
    }

    @Test("Changes written through another handle, as `defaults write` would, are reported")
    func observesOutsideWrites() async throws {
        let temporary = TemporaryDefaults()
        let store = HUDSettingsStore(defaults: temporary.defaults)
        try await confirmation(expectedCount: 1...) { changed in
            store.addObserver { _ in changed() }
            UserDefaults(suiteName: temporary.suiteName)!.set("gauges", forKey: HUDSettingsStore.graphsKey)
            try await Task.sleep(for: .milliseconds(300))
        }
        #expect(store.state.graphStyle == .gauges)
    }

    @Test("Modules, forms, rows, and the Settings tab persist across store instances")
    func settingsPersist() {
        let temporary = TemporaryDefaults()
        let store = HUDSettingsStore(defaults: temporary.defaults)
        #expect(store.modules == ModuleSelection.defaultEntries)
        #expect(store.networkForm == .oneRow)
        #expect(store.diskForm == .oneRow)
        #expect(store.cpuForm == .total)
        #expect(store.settingsTab == nil)

        let reordered = [
            ModuleEntry(.gpu, isOn: true), ModuleEntry(.cpu, isOn: true), ModuleEntry(.memory, isOn: false),
            ModuleEntry(.network, isOn: false), ModuleEntry(.disk, isOn: true), ModuleEntry(.freeSpace, isOn: true),
            ModuleEntry(.battery, isOn: false), ModuleEntry(.thermal, isOn: false), ModuleEntry(.swap, isOn: true),
        ]
        store.modules = reordered
        store.networkForm = .twoRows
        store.cpuForm = .clusters
        store.settingsTab = "hud"
        let reopened = HUDSettingsStore(defaults: temporary.defaults)
        #expect(reopened.modules == reordered)
        #expect(reopened.networkForm == .twoRows)
        #expect(reopened.cpuForm == .clusters)
        #expect(reopened.forms(cpuClusters: 2) == ModuleForms(cpu: .clusters, network: .twoRows, cpuClusters: 2))
        #expect(reopened.settingsTab == "hud")
    }

    @Test("A placement beside the Dock keeps its screen-edge axis across relaunches")
    func screenEdgePlacementPersists() {
        let temporary = TemporaryDefaults()
        let store = HUDSettingsStore(defaults: temporary.defaults)
        let placement = HUDPlacement(
            displayID: "main", corner: .bottomRight, offset: CGSize(width: 12, height: 4), screenEdgeAxis: .vertical)
        store.placement = placement
        #expect(HUDSettingsStore(defaults: temporary.defaults).placement == placement)
    }

    @Test("Listeners added with addObserver hear module changes made through another handle")
    func observersHearModuleChanges() async {
        let temporary = TemporaryDefaults()
        let store = HUDSettingsStore(defaults: temporary.defaults)
        await confirmation { changed in
            store.addObserver { _ in changed() }
            UserDefaults(suiteName: temporary.suiteName)?.set(
                [["id": "gpu", "on": true]], forKey: HUDSettingsStore.modulesKey)
            try? await Task.sleep(for: .milliseconds(300))
        }
    }
}

@Suite("App environment")
struct AppEnvironmentTests {
    @Test("A settings suite in the environment isolates settings from the user's domain")
    func settingsSuite() {
        let isolated = AppEnvironment.settingsDefaults(environment: ["METERS_SETTINGS_SUITE": "net.1x0.meters.tests"])
        #expect(isolated !== UserDefaults.standard)
        #expect(AppEnvironment.settingsDefaults(environment: [:]) === UserDefaults.standard)
    }

    @Test("Check markers append to the configured file, with values, and do nothing otherwise")
    func checkMarkers() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let environment = ["METERS_MARKER_FILE": path]

        AppEnvironment.recordMarker("first-data", environment: environment)
        AppEnvironment.recordMarker("hud-frame", values: [1280, 90, 220, 16], environment: environment)
        AppEnvironment.recordMarker("ignored", environment: [:])

        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("first-data "))
        let frame = lines[1].split(separator: " ")
        #expect(frame.first == "hud-frame")
        #expect(frame.dropFirst(2).joined(separator: " ") == "1280 90 220 16")
    }
}
