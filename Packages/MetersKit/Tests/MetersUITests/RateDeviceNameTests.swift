import AppKit
import MetersCore
import Testing

@testable import MetersUI

@MainActor
@Suite("Device names on rate rows")
struct RateDeviceNameTests {
    init() { _ = NSApplication.shared }

    @Test(
        "Names are spoken in full, even when the row truncates them",
        arguments: ["Wi-Fi", "disk0, disk1, disk2, disk3, disk4, disk5"])
    func accessibility(names: String) {
        let network = names == "Wi-Fi"
        let model = MeterRowModel(
            row: MeterRow(
                value: "1.25M",
                spokenValue: network
                    ? "download 1.25 megabytes per second, upload 0 bytes per second"
                    : "read 1.25 megabytes per second, write 0 bytes per second",
                samples: [], hasData: true, secondValue: "0", deviceName: names))
        let row = MeterRowView(
            labels: MeterRowLabels(
                label: network ? "NET" : "DISK", marker: network ? "↓" : "R", secondMarker: network ? "↑" : "W",
                accessibilityLabel: network ? "Network" : "Disk"),
            model: model)
        let width = MeterRowContent.width(labels: row.labels, offersGauge: false, graphStyle: .sparklines)
        row.frame = CGRect(x: 0, y: 0, width: width, height: HUDMetrics.rowHeight)
        row.layout()
        #expect(
            row.accessibilityValue() as? String == "\(network ? "Network" : "Disk"), \(names), \(model.row.spokenValue)"
        )
        #expect(row.hostingView.frame == row.bounds)
    }

    @Test("Two-row forms omit device names from their existing spoken values")
    func twoRow() {
        let model = MeterRowModel(
            row: MeterRow(
                value: "1.25M", spokenValue: "1.25 megabytes per second",
                samples: [], hasData: true, deviceName: "Wi-Fi"))
        let row = MeterRowView(
            labels: MeterRowLabels(label: "NET", marker: "↓", accessibilityLabel: "Network download"), model: model)
        row.frame = CGRect(x: 0, y: 0, width: 284, height: HUDMetrics.rowHeight)
        row.layout()
        #expect(row.accessibilityValue() as? String == "Network download, 1.25 megabytes per second")
    }
}
