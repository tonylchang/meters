import CoreGraphics
import Foundation
import Testing

@testable import MetersCore

@Suite("HUD layout")
struct HUDLayoutTests {
    func sizes(_ widths: [CGFloat], _ heights: [CGFloat]) -> [CGSize] {
        zip(widths, heights).map { CGSize(width: $0, height: $1) }
    }

    @Test("Width is the widest module plus 8 pt padding each side, rounded up to a whole point")
    func widthFollowsContent() {
        let layout = HUDLayout.column(moduleSizes: sizes([148.3, 171.2, 82.3], [18, 18, 18]), usableHeight: 900)
        #expect(layout.size.width == 188)
        let numbersOnly = HUDLayout.column(moduleSizes: sizes([82.3, 82.3], [18, 18]), usableHeight: 900)
        #expect(numbersOnly.size.width == 99)
    }

    @Test("Height is the modules, 4 pt apart, plus 8 pt padding top and bottom")
    func heightFollowsContent() {
        let empty = HUDLayout.column(moduleSizes: [], usableHeight: 900)
        #expect(empty.size == CGSize(width: 16, height: 16))
        #expect(empty.visibleModuleCount == 0)

        let three = HUDLayout.column(moduleSizes: sizes([144, 144, 144], [18, 18, 30]), usableHeight: 900)
        #expect(three.size == CGSize(width: 160, height: 90))
        #expect(three.visibleModuleCount == 3)
    }

    @Test("Overflow caps height at the usable height minus insets and drops trailing modules")
    func overflowClipsTrailingModules() {
        // Cap: 104 - 2 * 12 = 80. Padding 16 + 30 + 4 + 30 = 80 fits exactly; a third module does not.
        // The module left out does not widen the HUD.
        let layout = HUDLayout.column(moduleSizes: sizes([100, 100, 284], [30, 30, 30]), usableHeight: 104)
        #expect(layout.size == CGSize(width: 116, height: 80))
        #expect(layout.visibleModuleCount == 2)
    }

    @Test("A module that does not fit entirely is not shown, even if later ones would")
    func partialModulesAreDropped() {
        let layout = HUDLayout.column(moduleSizes: sizes([100, 100, 100], [30, 80, 10]), usableHeight: 100)
        #expect(layout.visibleModuleCount == 1)
        #expect(layout.size.height == 46)
    }

    @Test("Resize and fade durations are 0.2 s; resizes are instant with Reduce Motion")
    func motionDurations() {
        #expect(HUDMotion.resizeDuration(reduceMotion: false) == 0.2)
        #expect(HUDMotion.resizeDuration(reduceMotion: true) == 0)
        #expect(HUDMotion.fadeDuration(reduceMotion: false) == 0.2)
        #expect(HUDMotion.fadeDuration(reduceMotion: true) == 0.2)
    }

    @Test("Settling after a drag takes 0.12 s, and is instant with Reduce Motion")
    func settleDuration() {
        #expect(HUDMotion.settleDuration(reduceMotion: false) == 0.12)
        #expect(HUDMotion.settleDuration(reduceMotion: true) == 0)
    }

    @Test("Reduce Transparency makes the background opaque; Increase Contrast widens the border to 1 pt")
    func backgroundStyle() {
        let normal = HUDBackgroundStyle(reduceTransparency: false, increaseContrast: false)
        #expect(normal.fill == .translucentMaterial)
        #expect(normal.borderWidth == 0.5)

        let both = HUDBackgroundStyle(reduceTransparency: true, increaseContrast: true)
        #expect(both.fill == .opaque)
        #expect(both.borderWidth == 1)
    }

    @Test("Fixed measurements match the design")
    func metrics() {
        #expect(HUDMetrics.cornerRadius == 12)
        #expect(HUDMetrics.padding == 8)
        #expect(HUDMetrics.screenInset == 12)
        #expect(AppIdentity.displayName == "meters")
    }
}

@Suite("HUD geometry")
struct HUDGeometryTests {
    let area = CGRect(x: 0, y: 70, width: 1440, height: 830)

    @Test("The anchor corner is the quadrant holding the HUD's center")
    func nearestCorner() {
        #expect(AnchorCorner.nearest(to: CGRect(x: 1200, y: 80, width: 220, height: 50), in: area) == .bottomRight)
        #expect(AnchorCorner.nearest(to: CGRect(x: 12, y: 80, width: 220, height: 50), in: area) == .bottomLeft)
        #expect(AnchorCorner.nearest(to: CGRect(x: 12, y: 800, width: 220, height: 50), in: area) == .topLeft)
        #expect(AnchorCorner.nearest(to: CGRect(x: 1200, y: 800, width: 220, height: 50), in: area) == .topRight)
    }

    @Test("A center exactly on a quadrant boundary resolves toward the right and top")
    func boundaryTie() {
        let centered = CGRect(x: 720 - 110, y: 485 - 25, width: 220, height: 50)
        #expect(AnchorCorner.nearest(to: centered, in: area) == .topRight)
    }
}
