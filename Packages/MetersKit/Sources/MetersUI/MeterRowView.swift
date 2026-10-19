import AppKit
import MetersCore
import Observation
import SwiftUI

/// How a module row is labeled.
public struct MeterRowLabels: Sendable {
    /// Shown in the label column; only a module's first row carries it.
    public let label: String?
    /// A direction marker, such as "↓" or "R", shown at the left edge of the value column. A row's
    /// `valueMarker`, such as the battery's arrow, takes its place.
    public let marker: String?
    /// The second value's marker in the one-row rate form, such as "↑" or "W". A row with one shows two
    /// value columns and no sparkline.
    public let secondMarker: String?
    /// What VoiceOver calls the row, such as "CPU" or "Network download".
    public let accessibilityLabel: String
    /// Whether the row draws a sparkline after its value. Numbers-only rows, such as Thermal's, do not, so
    /// they need less width.
    public let showsSparkline: Bool

    public init(
        label: String?, marker: String? = nil, secondMarker: String? = nil, accessibilityLabel: String,
        showsSparkline: Bool = true
    ) {
        self.label = label
        self.marker = marker
        self.secondMarker = secondMarker
        self.accessibilityLabel = accessibilityLabel
        self.showsSparkline = showsSparkline
    }
}

@MainActor
@Observable
final class MeterRowModel {
    var row: MeterRow
    /// Sparklines or gauges, for a row that offers a gauge.
    var graphStyle: GraphStyle

    init(row: MeterRow, graphStyle: GraphStyle = .sparklines) {
        self.row = row
        self.graphStyle = graphStyle
    }
}

/// A module's rows, stacked top to bottom. The rows are the VoiceOver elements, not this view.
@MainActor
final class MeterModuleView: NSView {
    private(set) var rowViews: [MeterRowView]

    init(rowViews: [MeterRowView]) {
        self.rowViews = rowViews
        super.init(frame: .zero)
        for rowView in rowViews { addSubview(rowView) }
    }

    /// Replaces the rows, as when a two-rate module switches form.
    func setRowViews(_ newRowViews: [MeterRowView]) {
        for rowView in rowViews { rowView.removeFromSuperview() }
        rowViews = newRowViews
        for rowView in newRowViews { addSubview(rowView) }
        needsLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        for (index, rowView) in rowViews.enumerated() {
            rowView.frame = CGRect(
                x: 0, y: CGFloat(index) * HUDMetrics.rowHeight, width: bounds.width, height: HUDMetrics.rowHeight)
        }
    }

    // VoiceOver's pointer reaches the row under it. AppKit declares this nonisolated but calls it on the
    // main thread.
    override nonisolated func accessibilityHitTest(_ point: NSPoint) -> Any? {
        MainActor.assumeIsolated { () -> NSView? in
            guard let window else { return rowViews.first }
            let local = convert(window.convertPoint(fromScreen: point), from: nil)
            return rowViews.first { $0.frame.contains(local) } ?? rowViews.first
        }
    }
}

/// Hosts one SwiftUI row and presents it to VoiceOver as one element: "CPU, 23 percent".
@MainActor
final class MeterRowView: NSView {
    let hostingView: NSHostingView<MeterRowContent>
    /// What VoiceOver calls the row, such as "CPU"; also its accessibility identifier.
    let name: String
    var labels: MeterRowLabels { hostingView.rootView.labels }

    init(labels: MeterRowLabels, model: MeterRowModel) {
        hostingView = NSHostingView(rootView: MeterRowContent(labels: labels, model: model))
        name = labels.accessibilityLabel
        super.init(frame: .zero)
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityIdentifier(name)
        setAccessibilityValue(spokenText(model.row))
    }

    /// The whole phrase VoiceOver reads, name first: "CPU, 23 percent". VoiceOver reads a text element's value
    /// before its label, so a separate label came out as "23 percent, CPU" (found by the user, Sep 28, 2026);
    /// the phrase is the value, and there is no label.
    /// A row past a threshold adds its state: "CPU, 85 percent, critical".
    /// The one-row rate form adds its full device names, even when the row shows them truncated.
    func spokenText(_ row: MeterRow) -> String {
        let device =
            if labels.secondMarker != nil, let deviceName = row.deviceName {
                ", \(deviceName)"
            } else {
                ""
            }
        return "\(name)\(device), \(row.spokenValue)\(row.state.spokenSuffix)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        hostingView.frame = bounds
        let spoken = spokenText(hostingView.rootView.model.row)
        if accessibilityValue() as? String != spoken {
            setAccessibilityValue(spoken)
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    override func accessibilityChildren() -> [Any]? { [] }

    // VoiceOver's show-menu command on a row opens the HUD's right-click menu.
    override func accessibilityPerformShowMenu() -> Bool {
        let hud = sequence(first: superview, next: { $0?.superview }).lazy.compactMap { $0 as? HUDContainerView }.first
        return hud?.showContextMenu(for: nil, in: self) ?? false
    }

    // One element with no children: any point in the row is this element.
    override nonisolated func accessibilityHitTest(_ point: NSPoint) -> Any? { self }
}

/// One row on the shared grid: label column, value column, and sparkline, 6 pt apart.
struct MeterRowContent: View {
    static let spacing: CGFloat = 6
    static let sparklineHeight: CGFloat = 12
    /// A sparkline's or gauge's natural length: one point per reading of the 60-reading history. A graph fills
    /// any extra width a wider row elsewhere in the HUD gives it.
    static let graphLength: CGFloat = 60
    /// Room the one-row rate form keeps between its label and its rates for one device name, such as Wi-Fi or
    /// disk0; longer names truncate.
    static let deviceNameTemplates = ["Wi-Fi", "disk0"]
    /// The row's font as AppKit names it, to measure its columns.
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    /// Size the label column: it is as wide as the widest of these in the rendered font.
    static let labelTemplates = ["CPU", "GPU", "MEM", "NET", "DISK", "BATT", "HEAT", "SWP", "FREE"]
    /// Size the value column: the widest markers with the widest values, so every row's value and
    /// sparkline line up and never shift as values change.
    static let valueTemplates = [
        "W 88.8M", "↓ 88.8M", "↑ 88.8M", "R 88.8M", "100%", "S 100%", "↓ 100%", "8.88T", "Critical",
    ]

    let labels: MeterRowLabels
    let model: MeterRowModel

    var body: some View {
        HStack(spacing: Self.spacing) {
            Self.column(Self.labelTemplates)
                .overlay(alignment: .leading) {
                    if let label = labels.label {
                        Text(label).foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    }
                }
            if labels.secondMarker != nil {
                // Keep the paired rates at the row's trailing edge as the HUD grows wider.
                Spacer(minLength: 0)
                    .overlay(alignment: .leading) {
                        GeometryReader { geometry in
                            // The overlay never takes width away from the fixed value columns, even for a
                            // long device name.
                            if let deviceName = model.row.deviceName {
                                Text(deviceName)
                                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                                    .truncationMode(.tail)
                                    .frame(
                                        width: geometry.size.width, height: HUDMetrics.rowHeight, alignment: .leading
                                    )
                                    .clipped()
                            }
                        }
                        .frame(height: HUDMetrics.rowHeight)
                    }
            }
            valueColumn(marker: model.row.valueMarker ?? labels.marker, value: model.row.value, showsState: true)
            if let secondMarker = labels.secondMarker {
                // The one-row rate form: a second value column in place of the sparkline.
                valueColumn(
                    marker: secondMarker, value: model.row.secondValue ?? MeterText.placeholder, showsState: false)
            } else if model.graphStyle == .gauges && model.row.offersGauge {
                GaugeBar(fraction: model.row.gaugeFraction, color: Self.stateColor(model.row.state))
            } else {
                SparklineShape(samples: model.row.samples, capacity: MeterTiming.historyCapacity)
                    .fill(Self.stateColor(model.row.state) ?? Color(nsColor: .secondaryLabelColor))
                    .frame(height: Self.sparklineHeight)
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .lineLimit(1)
        .frame(height: HUDMetrics.rowHeight)
        .accessibilityHidden(true)
    }

    /// A threshold state's color: the system's amber (orange) or red; `nil` while normal, so the row stays
    /// grey.
    static func stateColor(_ state: ThresholdState) -> Color? {
        switch state {
        case .normal: nil
        case .elevated: Color(nsColor: .systemOrange)
        case .critical: Color(nsColor: .systemRed)
        }
    }

    /// A value column on the shared grid: the marker at its left edge, the value right-aligned. The row's first
    /// value shows its threshold state: the state color, in semibold.
    private func valueColumn(marker: String?, value: String, showsState: Bool) -> some View {
        let state = showsState ? model.row.state : .normal
        return Self.column(Self.valueTemplates)
            .overlay(alignment: .leading) {
                if let marker {
                    Text(marker).foregroundStyle(Color(nsColor: .secondaryLabelColor))
                }
            }
            .overlay(alignment: .trailing) {
                Text(value)
                    .fontWeight(state == .normal ? .regular : .semibold)
                    .foregroundStyle(
                        Self.stateColor(state)
                            ?? Color(nsColor: model.row.isUnavailable ? .secondaryLabelColor : .labelColor))
            }
    }

    /// The width a row needs: its label and value columns, then a graph, a device name and
    /// a second value, or nothing for a numbers-only row. Battery and Free space draw a gauge only under Gauges.
    static func width(labels: MeterRowLabels, offersGauge: Bool, graphStyle: GraphStyle) -> CGFloat {
        let fixed = textWidth(labelTemplates) + spacing + textWidth(valueTemplates)
        if labels.secondMarker != nil {
            return fixed + spacing + textWidth(deviceNameTemplates) + spacing + textWidth(valueTemplates)
        }
        let showsGauge = graphStyle == .gauges && offersGauge
        return labels.showsSparkline || showsGauge ? fixed + spacing + graphLength : fixed
    }

    /// The widest template's width in the row's font, rounded up to a whole point as SwiftUI lays out the columns.
    static func textWidth(_ templates: [String]) -> CGFloat {
        templates.map { ($0 as NSString).size(withAttributes: [.font: font]).width.rounded(.up) }.max() ?? 0
    }

    /// An invisible column as wide as the widest template.
    static func column(_ templates: [String]) -> some View {
        ZStack {
            ForEach(templates, id: \.self) { Text($0).hidden() }
        }
    }
}

/// The sparkline's filled area as a plain shape. Not a `Canvas`: a redrawing `Canvas` keeps a
/// GPU-backed drawing pool of about 190 MB, far over the 50 MB memory target (measured Sep 26, 2026).
struct SparklineShape: Shape {
    let samples: [Double?]
    let capacity: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for polygon in SparklineGeometry.areas(samples: samples, capacity: capacity, size: rect.size) {
            path.addLines(polygon.map { CGPoint(x: rect.minX + $0.x, y: rect.minY + $0.y) })
            path.closeSubpath()
        }
        return path
    }
}

/// A gauge in the sparkline's place: a faint full-width track and a fill from the left, 6 pt tall with rounded
/// ends; the fill takes the row's state color. Plain shapes, like the sparkline.
struct GaugeBar: View {
    static let height: CGFloat = 6

    /// From 0 to 1; `nil` shows only the track.
    let fraction: Double?
    /// The threshold state's color, or `nil` while normal.
    let color: Color?

    var body: some View {
        GaugeFillShape(fraction: 1)
            .fill(Color(nsColor: .quaternaryLabelColor))
            .overlay {
                if let fraction {
                    GaugeFillShape(fraction: fraction)
                        .fill(color ?? Color(nsColor: .secondaryLabelColor))
                }
            }
            .frame(height: Self.height)
    }
}

/// A rounded bar from the left edge, `fraction` of the rect's width.
struct GaugeFillShape: Shape {
    let fraction: Double

    func path(in rect: CGRect) -> Path {
        let width = rect.width * min(1, max(0, fraction))
        guard width > 0 else { return Path() }
        let bar = CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
        let radius = min(rect.height, width) / 2
        return Path(roundedRect: bar, cornerRadius: radius)
    }
}
