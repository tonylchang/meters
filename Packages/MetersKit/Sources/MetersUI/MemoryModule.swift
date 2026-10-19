import MetersCore

/// The Memory module: label, memory used as a whole-number percent of RAM, and a 60-sample sparkline
/// in one row.
public typealias MemoryModule = MeterModule<MemoryMeter>

extension MeterModule where Meter == MemoryMeter {
    public convenience init(
        source: any MemorySource = MachMemorySource(),
        pressure: (any MemoryPressureSource)? = SystemSources.memoryPressure(),
        scheduler: any SampleScheduling = RunLoopScheduler(),
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.init(
            identifier: "memory",
            rows: [
                MeterRowLabels(label: MemoryModuleText.label, accessibilityLabel: MemoryModuleText.accessibilityLabel)
            ],
            meter: MemoryMeter(source: source, pressure: pressure), scheduler: scheduler, now: now)
    }
}
