import AppKit
import MetersCore
import SwiftUI
import Testing

@testable import MetersUI

@MainActor
@Suite("Shared row grid")
struct MeterRowTests {
    init() { _ = NSApplication.shared }

    static let labelSets: [MeterRowLabels] = [
        MeterRowLabels(label: "CPU", accessibilityLabel: "CPU"),
        MeterRowLabels(label: "MEM", accessibilityLabel: "Memory"),
        MeterRowLabels(label: "NET", marker: "↓", accessibilityLabel: "Network download"),
        MeterRowLabels(label: nil, marker: "↑", accessibilityLabel: "Network upload"),
        MeterRowLabels(label: "DISK", marker: "R", accessibilityLabel: "Disk read"),
        MeterRowLabels(label: nil, marker: "W", accessibilityLabel: "Disk write"),
    ]
    static let values = ["--", "n/a", "0%", "5%", "42%", "100%", "820", "12.3K", "1.25M", "88.8M", "999G"]

    @Test(
        "Every row is 18 pt tall, and its columns never shift with the label, marker, or value (shared row grid)",
        arguments: [148.0, 172.0, 284.0])
    func rowGrid(width: CGFloat) {
        // Measure the SwiftUI row itself; the module's own host opts out of sizing so it never
        // constrains the HUD. One ideal width for every combination means the value column and the
        // sparkline start at the same place in every row.
        var idealWidths: Set<CGFloat> = []
        for labels in Self.labelSets {
            let model = MeterRowModel(row: MeterRow(value: "--", spokenValue: "no data", samples: [], hasData: false))
            let host = NSHostingView(rootView: MeterRowContent(labels: labels, model: model))
            host.frame = CGRect(x: 0, y: 0, width: width, height: HUDMetrics.rowHeight)
            for value in Self.values {
                model.row = MeterRow(
                    value: value, spokenValue: value, samples: Array(repeating: 0.5, count: 60), hasData: true)
                host.layoutSubtreeIfNeeded()
                #expect(host.fittingSize.height == HUDMetrics.rowHeight, "\(value): \(host.fittingSize)")
                idealWidths.insert(host.fittingSize.width)
            }
        }
        #expect(idealWidths.count == 1, "ideal widths \(idealWidths)")
    }

    @Test("The column templates fit every label, and every marker with every value (shared row grid)")
    func templatesFit() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        func width(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }

        let labelWidth = MeterRowContent.labelTemplates.map(width).max() ?? 0
        for label in ["CPU", "GPU", "MEM", "NET", "DISK", "BATT", "HEAT", "SWP", "FREE"] {
            #expect(width(label) <= labelWidth, "\(label)")
        }
        let valueWidth = MeterRowContent.valueTemplates.map(width).max() ?? 0
        let rates = ["820", "999", "8.88K", "88.8K", "888K", "8.88M", "88.8M", "888M", "8.88G", "88.8G", "999G"]
        for marker in ["↓", "↑", "R", "W"] {
            for rate in rates {
                #expect(width("\(marker) \(rate)") <= valueWidth, "\(marker) \(rate)")
            }
        }
        for value in ["100%", "--", "n/a", "OK", "Warm", "Hot", "Critical", "8.88T", "999T"] {
            #expect(width(value) <= valueWidth, "\(value)")
        }
        // Cluster initials and the battery's arrows, with every percent.
        for marker in ["S", "P", "E", "M", "↑", "↓"] {
            #expect(width("\(marker) 100%") <= valueWidth, "\(marker) 100%")
        }
    }

    @Test("The one-row rate form fits both values and its name room in its natural width, 18 pt tall")
    func pairedRowFits() {
        let labels = MeterRowLabels(label: "DISK", marker: "W", secondMarker: "W", accessibilityLabel: "Disk")
        let model = MeterRowModel(
            row: MeterRow(value: "88.8M", spokenValue: "", samples: [], hasData: true, secondValue: "88.8M"))
        let host = NSHostingView(rootView: MeterRowContent(labels: labels, model: model))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height == HUDMetrics.rowHeight)
        let natural = MeterRowContent.width(labels: labels, offersGauge: false, graphStyle: .sparklines)
        let nameRoom = MeterRowContent.textWidth(MeterRowContent.deviceNameTemplates)
        // SwiftUI's own columns agree with the measurement: what is left beyond them is the name's room.
        #expect(natural - host.fittingSize.width == nameRoom, "\(host.fittingSize)")
        #expect(nameRoom >= MeterRowContent.textWidth(["Wi-Fi"]) && nameRoom >= MeterRowContent.textWidth(["disk0"]))
    }

    @Test("Natural widths: numbers only; a 60 pt graph after 6 pt; gauges only under Gauges")
    func naturalWidths() {
        let numbers = MeterRowLabels(label: "HEAT", accessibilityLabel: "Thermal", showsSparkline: false)
        let graph = MeterRowLabels(label: "CPU", accessibilityLabel: "CPU")
        let rates = MeterRowLabels(label: "NET", marker: "↓", secondMarker: "↑", accessibilityLabel: "Network")
        let numbersWidth = MeterRowContent.width(labels: numbers, offersGauge: false, graphStyle: .sparklines)
        for style in GraphStyle.allCases {
            #expect(MeterRowContent.width(labels: graph, offersGauge: true, graphStyle: style) == numbersWidth + 66)
        }
        // Battery and Free space: numbers only, unless Gauges gives them a gauge.
        #expect(MeterRowContent.width(labels: numbers, offersGauge: true, graphStyle: .sparklines) == numbersWidth)
        #expect(MeterRowContent.width(labels: numbers, offersGauge: true, graphStyle: .gauges) == numbersWidth + 66)
        // With 8 pt padding each side: the default HUD, whose widest row is one-row NET, and a numbers-only HUD.
        let rateWidth = MeterRowContent.width(labels: rates, offersGauge: false, graphStyle: .sparklines)
        #expect((rateWidth + 16).rounded(.up) == 188)
        #expect((numbersWidth + 66 + 16).rounded(.up) == 165)
        #expect((numbersWidth + 16).rounded(.up) == 99)
    }
}
