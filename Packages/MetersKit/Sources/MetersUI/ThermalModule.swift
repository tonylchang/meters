import MetersCore

/// The Thermal module: the system's thermal state as one word, in one row.
public typealias ThermalModule = MeterModule<ThermalMeter>

extension MeterModule where Meter == ThermalMeter {
    public convenience init(
        source: any ThermalStateSource = SystemThermalSource(),
        scheduler: any SampleScheduling = RunLoopScheduler(),
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.init(
            identifier: ModuleID.thermal.rawValue,
            rows: [
                MeterRowLabels(
                    label: ThermalModuleText.label, accessibilityLabel: ThermalModuleText.accessibilityLabel,
                    showsSparkline: false)
            ],
            meter: ThermalMeter(source: source), scheduler: scheduler, now: now)
    }
}
