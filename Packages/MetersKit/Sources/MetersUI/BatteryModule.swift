import MetersCore

/// The Battery module: the internal battery's charge as a whole-number percent, with an arrow for the
/// direction it is actually moving, in one row.
public typealias BatteryModule = MeterModule<BatteryMeter>

extension MeterModule where Meter == BatteryMeter {
    public convenience init(
        source: any BatterySource = SystemSources.battery(),
        scheduler: any SampleScheduling = RunLoopScheduler(),
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.init(
            identifier: ModuleID.battery.rawValue,
            rows: [
                MeterRowLabels(
                    label: BatteryModuleText.label, accessibilityLabel: BatteryModuleText.accessibilityLabel,
                    showsSparkline: false)
            ],
            meter: BatteryMeter(source: source), scheduler: scheduler, now: now)
    }
}
