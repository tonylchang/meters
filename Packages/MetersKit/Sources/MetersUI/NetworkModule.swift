import MetersCore

/// The Network module: download and upload rates, as two numbers in one row or with sparklines in two
/// rows.
public typealias NetworkModule = MeterModule<RateMeter>

extension MeterModule where Meter == RateMeter {
    public static func network(
        source: any ByteCounterSource = SystemNetworkSource(), form: RateForm = .oneRow,
        scheduler: any SampleScheduling = RunLoopScheduler(),
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) -> NetworkModule {
        NetworkModule(
            identifier: ModuleID.network.rawValue, rows: rateLabels(for: ModuleID.network.rawValue, form: form),
            meter: RateMeter(
                source: source, floor: NetworkModuleText.sparklineFloor, form: form,
                directionNames: ("download", "upload")),
            scheduler: scheduler, now: now)
    }

    /// Row labels for a two-rate module in either form.
    static func rateLabels(for identifier: String, form: RateForm) -> [MeterRowLabels] {
        let isDisk = identifier == ModuleID.disk.rawValue
        let label = isDisk ? DiskModuleText.label : NetworkModuleText.label
        let markers =
            isDisk
            ? (DiskModuleText.readMarker, DiskModuleText.writeMarker)
            : (NetworkModuleText.downloadMarker, NetworkModuleText.uploadMarker)
        switch form {
        case .oneRow:
            return [
                MeterRowLabels(
                    label: label, marker: markers.0, secondMarker: markers.1,
                    accessibilityLabel: isDisk ? ModuleID.disk.name : ModuleID.network.name)
            ]
        case .twoRows:
            return [
                MeterRowLabels(
                    label: label, marker: markers.0,
                    accessibilityLabel: isDisk
                        ? DiskModuleText.readAccessibilityLabel : NetworkModuleText.downloadAccessibilityLabel),
                MeterRowLabels(
                    label: nil, marker: markers.1,
                    accessibilityLabel: isDisk
                        ? DiskModuleText.writeAccessibilityLabel : NetworkModuleText.uploadAccessibilityLabel),
            ]
        }
    }
}

/// A module with a one-row and a two-row form.
@MainActor
public protocol RateFormSwitching: AnyObject {
    func setForm(_ form: RateForm)
}

extension MeterModule: RateFormSwitching where Meter == RateMeter {
    /// Switches form in place: the rates and their history carry over.
    public func setForm(_ form: RateForm) {
        guard meter.form != form else { return }
        meter.form = form
        reconfigure(rows: Self.rateLabels(for: identifier, form: form))
    }
}
