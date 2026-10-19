import MetersCore

/// The Disk module: read and write rates, as two numbers in one row or with sparklines in two rows.
public typealias DiskModule = MeterModule<RateMeter>

extension MeterModule where Meter == RateMeter {
    public static func disk(
        source: any ByteCounterSource = SystemDiskSource(), form: RateForm = .oneRow,
        scheduler: any SampleScheduling = RunLoopScheduler(),
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) -> DiskModule {
        DiskModule(
            identifier: ModuleID.disk.rawValue, rows: rateLabels(for: ModuleID.disk.rawValue, form: form),
            meter: RateMeter(
                source: source, floor: DiskModuleText.sparklineFloor, form: form, directionNames: ("read", "write")),
            scheduler: scheduler, now: now)
    }
}
