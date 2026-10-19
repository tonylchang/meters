import CoreGraphics
import Foundation
import Testing

@testable import MetersCore

@Suite("Placement geometry")
struct PlacementGeometryTests {
    /// A 1440 x 900 display with a 70 pt Dock at the bottom: usable area x 0 to 1440, y 70 to 900.
    let display = DisplayInfo(
        id: "main", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        usableArea: CGRect(x: 0, y: 70, width: 1440, height: 830))
    var area: CGRect { display.usableArea }
    let size = CGSize(width: 220, height: 34)

    func frame(x: CGFloat, y: CGFloat) -> CGRect {
        CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    @Test("First launch: bottom-right of the main display, 4 pt from the right and 12 pt from the bottom")
    func firstLaunch() {
        let placement = HUDPlacement.firstLaunch(on: display)
        #expect(PlacementGeometry.frame(for: placement, size: size, in: area) == frame(x: 1216, y: 82))
    }

    @Test("Released within 24 pt of an edge's inset line, the HUD snaps to it")
    func magnetism() {
        // 24 pt inside the right inset line (x 1436, 4 pt from the edge): snaps. 25 pt: stays.
        #expect(PlacementGeometry.settle(frame(x: 1436 - 220 - 24, y: 400), in: area).minX == 1216)
        #expect(PlacementGeometry.settle(frame(x: 1436 - 220 - 25, y: 400), in: area).minX == 1191)
        // Near the left inset line (x 4): 24 pt away snaps, 25 pt stays.
        #expect(PlacementGeometry.settle(frame(x: 28, y: 400), in: area).minX == 4)
        #expect(PlacementGeometry.settle(frame(x: 29, y: 400), in: area).minX == 29)
        // Away from every edge, the HUD stays exactly where it was dropped.
        #expect(PlacementGeometry.settle(frame(x: 600, y: 400), in: area) == frame(x: 600, y: 400))
    }

    @Test("Each axis snaps independently; near two edges the HUD lands in the corner")
    func corners() {
        // Near the top (inset line y 888) and the right: top-right corner.
        #expect(PlacementGeometry.settle(frame(x: 1200, y: 840), in: area) == frame(x: 1216, y: 854))
        // Near the bottom only: snaps vertically, keeps its x.
        #expect(PlacementGeometry.settle(frame(x: 600, y: 100), in: area) == frame(x: 600, y: 82))
    }

    @Test("A HUD dropped partly off-screen, under the menu bar, or under the Dock slides inside")
    func containment() {
        #expect(PlacementGeometry.settle(frame(x: 1400, y: 400), in: area).minX == 1216)
        #expect(PlacementGeometry.settle(frame(x: -100, y: 400), in: area).minX == 4)
        #expect(PlacementGeometry.settle(frame(x: 600, y: 890), in: area).maxY == 888)
        #expect(PlacementGeometry.settle(frame(x: 600, y: 20), in: area).minY == 82)
    }

    @Test("A placement records the corner nearest the HUD and its offset from that corner")
    func placementFromFrame() {
        let snapped = PlacementGeometry.placement(for: frame(x: 1208, y: 82), on: display)
        #expect(snapped == HUDPlacement(displayID: "main", corner: .bottomRight, offset: CGSize(width: 12, height: 12)))
        let free = PlacementGeometry.placement(for: frame(x: 100, y: 700), on: display)
        #expect(free == HUDPlacement(displayID: "main", corner: .topLeft, offset: CGSize(width: 100, height: 166)))
        #expect(PlacementGeometry.frame(for: free, size: size, in: area) == frame(x: 100, y: 700))
    }

    @Test("Resizing keeps the edges that face the anchor corner fixed", arguments: AnchorCorner.allCases)
    func resizeKeepsAnchorEdges(corner: AnchorCorner) {
        let placement = HUDPlacement(displayID: "main", corner: corner, offset: CGSize(width: 40, height: 50))
        let small = PlacementGeometry.frame(for: placement, size: CGSize(width: 160, height: 34), in: area)
        let large = PlacementGeometry.frame(for: placement, size: CGSize(width: 300, height: 80), in: area)
        if corner.isRight { #expect(large.maxX == small.maxX) } else { #expect(large.minX == small.minX) }
        if corner.isTop { #expect(large.maxY == small.maxY) } else { #expect(large.minY == small.minY) }
    }

    @Test("When the usable area changes, the HUD keeps its offset from its corner")
    func usableAreaChange() {
        let snapped = HUDPlacement.firstLaunch(on: display)
        // The Dock moves to the right side: the bottom inset now sits at the display's edge.
        let dockRight = CGRect(x: 0, y: 0, width: 1370, height: 900)
        #expect(PlacementGeometry.frame(for: snapped, size: size, in: dockRight) == frame(x: 1146, y: 12))
    }

    @Test("A saved placement resolves to its own display, or the main display while it is absent")
    func displayResolution() {
        let external = DisplayInfo(
            id: "external", frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
            usableArea: CGRect(x: 1440, y: 0, width: 1920, height: 1055))
        let saved = HUDPlacement(displayID: "external", corner: .topRight, offset: CGSize(width: 12, height: 12))
        #expect(PlacementGeometry.display(for: saved, among: [display, external]) == external)
        #expect(PlacementGeometry.display(for: saved, among: [display]) == display)
        #expect(PlacementGeometry.display(for: nil, among: [display, external]) == display)
        #expect(PlacementGeometry.display(for: saved, among: []) == nil)
    }

    @Test("The HUD belongs to the display under the pointer")
    func displayAtPointer() {
        let external = DisplayInfo(
            id: "external", frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
            usableArea: CGRect(x: 1440, y: 0, width: 1920, height: 1055))
        #expect(PlacementGeometry.display(at: CGPoint(x: 2000, y: 500), among: [display, external]) == external)
        #expect(PlacementGeometry.display(at: CGPoint(x: 700, y: 500), among: [display, external]) == display)
        #expect(PlacementGeometry.display(at: CGPoint(x: -500, y: 500), among: [display, external]) == display)
    }

    @Test("The Dock's edge is where the usable area stops short, other than the menu bar's top")
    func dockEdge() {
        #expect(display.dockEdge == .bottom)
        let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(
            DisplayInfo(id: "a", frame: frame, usableArea: CGRect(x: 80, y: 0, width: 1360, height: 875)).dockEdge
                == .left)
        #expect(
            DisplayInfo(id: "b", frame: frame, usableArea: CGRect(x: 0, y: 0, width: 1360, height: 875)).dockEdge
                == .right)
        #expect(
            DisplayInfo(id: "c", frame: frame, usableArea: CGRect(x: 0, y: 0, width: 1440, height: 875)).dockEdge == nil
        )
    }

    @Test(
        "Beside the Dock: a drop near the screen's bottom snaps 4 pt from it; near the Dock's line, above the Dock"
    )
    func besideDockMagnetism() {
        // Bottom snap lines: 4 (the screen's edge) and 82 (12 pt above the 70 pt Dock strip).
        #expect(PlacementGeometry.settle(frame(x: 400, y: 20), on: display).minY == 4)
        #expect(PlacementGeometry.settle(frame(x: 400, y: 100), on: display).minY == 82)
        // Between the two lines and more than 24 pt from each, it stays where dropped.
        #expect(PlacementGeometry.settle(frame(x: 400, y: 45), on: display).minY == 45)
    }

    @Test("Beside the Dock, containment allows the Dock's strip down to 4 pt from the screen's edge")
    func besideDockContainment() {
        #expect(PlacementGeometry.settle(frame(x: 400, y: -30), on: display).minY == 4)
        // The left and right edges keep their 4 pt inset from the usable area.
        #expect(PlacementGeometry.settle(frame(x: -50, y: 400), on: display).minX == 4)
        // Without the display (usable area only), the Dock's strip stays off limits, as before.
        #expect(PlacementGeometry.settle(frame(x: 400, y: 20), in: area).minY == 82)
    }

    @Test("A HUD beside the Dock stays 4 pt from the screen's edge when the Dock changes size")
    func besideDockAnchoring() {
        let beside = PlacementGeometry.settle(frame(x: 1208, y: 20), on: display)
        let placement = PlacementGeometry.placement(for: beside, on: display)
        #expect(placement.screenEdgeAxis == .vertical)
        #expect(placement.offset == CGSize(width: 4, height: 4))

        let biggerDock = DisplayInfo(
            id: "main", frame: display.frame, usableArea: CGRect(x: 0, y: 100, width: 1440, height: 800))
        #expect(PlacementGeometry.frame(for: placement, size: size, on: biggerDock) == frame(x: 1216, y: 4))

        // A HUD above the Dock keeps following the Dock's line.
        let above = PlacementGeometry.placement(for: frame(x: 1208, y: 82), on: display)
        #expect(above.screenEdgeAxis == nil)
        #expect(PlacementGeometry.frame(for: above, size: size, on: biggerDock) == frame(x: 1208, y: 112))
    }

    @Test("A Dock on the left works the same way along the horizontal axis")
    func leftDock() {
        let leftDock = DisplayInfo(
            id: "main", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            usableArea: CGRect(x: 70, y: 0, width: 1370, height: 875))
        let settled = PlacementGeometry.settle(frame(x: 20, y: 400), on: leftDock)
        #expect(settled.minX == 4)
        let placement = PlacementGeometry.placement(for: settled, on: leftDock)
        #expect(placement.screenEdgeAxis == .horizontal)
        #expect(placement.offset.width == 4)
    }
}

@MainActor
@Suite("Placement persistence")
struct PlacementPersistenceTests {
    @Test("The placement survives a relaunch; a missing or unreadable one reads as none")
    func roundTrip() {
        let temporary = TemporaryDefaults()
        let store = HUDSettingsStore(defaults: temporary.defaults)
        #expect(store.placement == nil)
        let placement = HUDPlacement(displayID: "ABC-123", corner: .topLeft, offset: CGSize(width: 40, height: 12))
        store.placement = placement
        #expect(HUDSettingsStore(defaults: UserDefaults(suiteName: temporary.suiteName)!).placement == placement)

        temporary.defaults.set(["display": "ABC-123", "corner": "middle", "x": 1.0, "y": 2.0], forKey: "hudPlacement")
        store.reload()
        #expect(store.placement == nil)
    }
}
