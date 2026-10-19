import Foundation
import Testing

@testable import MetersCore

@Suite("Threshold settings")
struct ThresholdSettingsTests {
    @Test("The defaults give exactly the threshold-states defaults")
    func defaults() {
        let settings = ThresholdSettings.defaults
        #expect(settings.rule(for: .cpu) == ThresholdDefaults.cpu)
        #expect(settings.rule(for: .gpu) == ThresholdDefaults.gpu)
        #expect(settings.rule(for: .battery) == ThresholdDefaults.battery)
        #expect(settings.rule(for: .swap) == ThresholdDefaults.swap)
        #expect(settings.rule(for: .freeSpace) == ThresholdDefaults.freeSpace)
        #expect(settings.highlights(.memory) && settings.highlights(.thermal))
        #expect(settings.rule(for: .network) == nil && settings.rule(for: .memory) == nil)
    }

    @Test("Fields read by direction, with units and steps")
    func fields() throws {
        let cpu = try #require(ThresholdEditor.fields(.cpu))
        #expect(
            cpu.elevatedLabel == "Amber from" && cpu.criticalLabel == "Red above" && cpu.unit == "%" && cpu.step == 1)
        let battery = try #require(ThresholdEditor.fields(.battery))
        #expect(battery.elevatedLabel == "Amber at or below" && battery.criticalLabel == "Red at or below")
        let swap = try #require(ThresholdEditor.fields(.swap))
        #expect(swap.elevatedLabel == "Amber over" && swap.unit == "GB" && swap.step == 0.5 && swap.range == 0...1000)
        let free = try #require(ThresholdEditor.fields(.freeSpace))
        #expect(
            free.elevatedLabel == "Amber under" && free.criticalLabel == "Red under" && free.unit == "% of capacity")
        #expect(ThresholdEditor.fields(.memory) == nil && ThresholdEditor.fields(.thermal) == nil)
        #expect(ThresholdEditor.note(.memory) == "Follows macOS memory pressure.")
        #expect(ThresholdEditor.note(.thermal) == "Hot is amber; Critical is red.")
        #expect(ThresholdEditor.modules == [.cpu, .memory, .gpu, .battery, .thermal, .swap, .freeSpace])
    }

    @Test("Empty fields turn a state off; both empty or highlighting off gives no rule")
    func emptyFields() {
        var settings = ThresholdSettings()
        settings[.cpu] = ThresholdSetting(elevated: nil, critical: 90)
        #expect(settings.rule(for: .cpu)?.state(for: 85) == .normal)
        #expect(settings.rule(for: .cpu)?.state(for: 91) == .critical)
        settings[.cpu] = ThresholdSetting(elevated: nil, critical: nil)
        #expect(settings.rule(for: .cpu) == nil)
        settings[.gpu] = ThresholdSetting(highlight: false, elevated: 90)
        #expect(settings.rule(for: .gpu) == nil)
        settings[.swap] = ThresholdSetting(elevated: 2.5, critical: nil)
        #expect(settings.rule(for: .swap)?.elevated == .init(2.5e9, inclusive: false))
    }

    @Test("Validation: ranges, and red on the right side of amber; an equal pair is allowed")
    func validation() throws {
        let cpu = try #require(ThresholdEditor.fields(.cpu))
        #expect(cpu.problem(elevated: 70, critical: 80) == nil)
        #expect(cpu.problem(elevated: 70, critical: 70) == nil)
        #expect(cpu.problem(elevated: 70, critical: 60) == "Red must be above Amber.")
        #expect(cpu.problem(elevated: -1, critical: nil) == "Enter a number from 0 to 100.")
        let battery = try #require(ThresholdEditor.fields(.battery))
        #expect(battery.problem(elevated: 20, critical: 30) == "Red must be below Amber.")
        let swap = try #require(ThresholdEditor.fields(.swap))
        #expect(swap.problem(elevated: 1001, critical: nil) == "Enter a number from 0 to 1,000.")
        #expect(swap.problem(elevated: .nan, critical: nil) != nil)
    }

    @Test("Thresholds persist; unreadable, out-of-range, or invalid stored entries fall back to defaults")
    @MainActor
    func persistence() {
        let suite = "net.1x0.meters.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HUDSettingsStore(defaults: defaults)
        #expect(store.thresholds == .defaults && store.sampleInterval == 1)
        var settings = ThresholdSettings()
        settings[.cpu] = ThresholdSetting(elevated: 60, critical: nil)
        settings[.memory] = ThresholdSetting(highlight: false)
        store.thresholds = settings
        store.sampleInterval = 5
        let reopened = HUDSettingsStore(defaults: defaults)
        #expect(reopened.thresholds[.cpu] == ThresholdSetting(elevated: 60, critical: nil))
        #expect(!reopened.thresholds.highlights(.memory) && reopened.sampleInterval == 5)

        defaults.set(
            [
                "cpu": ["elevated": "high"], "gpu": ["elevated": 150.0],
                "battery": ["elevated": 10.0, "critical": 20.0],
                "swap": ["highlight": "yes"], "freeSpace": ["highlight": false, "elevated": 12.0],
            ], forKey: HUDSettingsStore.thresholdsKey)
        defaults.set(3.0, forKey: HUDSettingsStore.sampleIntervalKey)
        let bad = HUDSettingsStore(defaults: defaults).thresholds
        for id in [ModuleID.cpu, .gpu, .battery, .swap] {
            #expect(bad[id] == ThresholdSettings.defaultSetting(id), "\(id)")
        }
        #expect(bad[.freeSpace] == ThresholdSetting(highlight: false, elevated: 12, critical: nil))
        #expect(HUDSettingsStore(defaults: defaults).sampleInterval == 1)
    }

    @Test("Meters: switching off resets states at once; new numbers keep the 3-reading count")
    func meters() {
        var gpu = GPUMeter(source: ScriptedGPUSource([95, 95, 95, 95]))
        for _ in 0..<3 { gpu.sample(at: .now) }
        #expect(gpu.rows[0].state == .elevated)
        var settings = ThresholdSettings()
        settings[.gpu] = ThresholdSetting(elevated: 80, critical: 90)
        gpu.applyThresholds(settings)
        #expect(gpu.rows[0].state == .elevated)
        gpu.sample(at: .now)
        #expect(gpu.rows[0].state == .elevated)
        settings[.gpu] = ThresholdSetting(highlight: false, elevated: 80, critical: 90)
        gpu.applyThresholds(settings)
        #expect(gpu.rows[0].state == .normal)
    }

    @Test("Rates stay per second, and a baseline goes stale after 3 intervals")
    func rateInterval() {
        let start = ContinuousClock.now
        let source = ScriptedCounterSource([
            ["en0": ByteCounters(first: 0, second: 0)], ["en0": ByteCounters(first: 10_000, second: 5_000)],
        ])
        var meter = RateMeter(source: source, floor: 1)
        meter.setInterval(.seconds(5))
        meter.rebaseline(at: start)
        meter.sample(at: start + .seconds(10))
        #expect(meter.firstRate == 1_000 && meter.secondRate == 500)
        #expect(MeterTiming.staleAfter(interval: .milliseconds(500)) == .milliseconds(1500))
    }
}
