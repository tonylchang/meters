import Foundation
import Testing

@testable import MetersCore

@Suite("Disk")
struct DiskTests {
    @Test("Physical disks count; disk images, which report a virtual interconnect in a file, do not")
    func selection() {
        #expect(
            DiskSelection.isCounted(protocolCharacteristics: [
                "Physical Interconnect": "Apple Fabric", "Physical Interconnect Location": "Internal",
            ]))
        #expect(
            DiskSelection.isCounted(protocolCharacteristics: [
                "Physical Interconnect": "USB", "Physical Interconnect Location": "External",
            ]))
        #expect(
            !DiskSelection.isCounted(protocolCharacteristics: [
                "Physical Interconnect": "Virtual Interface", "Physical Interconnect Location": "File",
            ]))
        #expect(!DiskSelection.isCounted(protocolCharacteristics: ["Physical Interconnect Location": "File"]))
        #expect(DiskSelection.isCounted(protocolCharacteristics: nil))
    }

    @Test("The system source reports this Mac's internal disk")
    func systemSource() throws {
        let counters = try #require(SystemDiskSource().readCounters())
        #expect(counters.values.contains { $0.first > 0 })
    }

    @Test("The row is labeled DISK, with R and W for read and write")
    func text() {
        #expect(DiskModuleText.label == "DISK")
        #expect(DiskModuleText.readMarker == "R")
        #expect(DiskModuleText.writeMarker == "W")
        #expect(DiskModuleText.readAccessibilityLabel == "Disk read")
        #expect(DiskModuleText.writeAccessibilityLabel == "Disk write")
        #expect(DiskModuleText.sparklineFloor == 1_000_000)
    }
}
