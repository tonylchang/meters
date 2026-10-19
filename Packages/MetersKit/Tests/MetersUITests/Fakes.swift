import AppKit
import Foundation
import MetersCore
import Synchronization

@testable import MetersUI

@MainActor
final class FakeModule: HUDModule {
    let identifier: String
    let view: NSView
    var onSizeChange: (() -> Void)?

    var height: CGFloat {
        didSet { onSizeChange?() }
    }
    var width: CGFloat {
        didSet { onSizeChange?() }
    }

    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var interval: Duration?
    private(set) var thresholds: ThresholdSettings?
    private(set) var graphStyle: GraphStyle?

    /// The default width makes a 220 pt HUD, the width these tests were written against.
    init(_ identifier: String, height: CGFloat, width: CGFloat = 204) {
        self.identifier = identifier
        self.height = height
        self.width = width
        view = NSView()
        view.setAccessibilityElement(true)
        view.setAccessibilityLabel(identifier)
    }

    func start() { starts += 1 }
    func stop() { stops += 1 }
    func setInterval(_ interval: Duration) { self.interval = interval }
    func applyThresholds(_ settings: ThresholdSettings) { thresholds = settings }
    func setGraphStyle(_ style: GraphStyle) { graphStyle = style }
}

extension DisplayInfo {
    /// A 1440 x 900 main display with a 70 pt Dock and a 0 pt menu bar gap, for simple geometry.
    static let main = DisplayInfo(
        id: "main", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        usableArea: CGRect(x: 0, y: 70, width: 1440, height: 830))
    /// A 1920 x 1080 display to the right of the main display, with no Dock.
    static let external = DisplayInfo(
        id: "external", frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
        usableArea: CGRect(x: 1440, y: 0, width: 1920, height: 1055))
}

@MainActor
final class FakeScreens: ScreenProviding {
    var displays: [DisplayInfo]

    init(displays: [DisplayInfo] = [.main]) {
        self.displays = displays
    }

    /// A single main display with the given usable area.
    init(usableArea: CGRect) {
        displays = [DisplayInfo(id: "main", frame: usableArea, usableArea: usableArea)]
    }
}

@MainActor
final class FakeDisplayOptions: DisplayOptionsProviding {
    var reduceTransparency = false { didSet { onChange?() } }
    var increaseContrast = false { didSet { onChange?() } }
    var reduceMotion = false
    var onChange: (() -> Void)?
}

/// A throwaway settings domain, removed when the test ends.
final class TemporaryDefaults {
    let suiteName = "net.1x0.meters.tests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
        // Removing a domain leaves an empty preferences file behind; delete it too.
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suiteName).plist")
        try? FileManager.default.removeItem(at: file)
    }
}

/// Returns scripted memory readings in order, then `nil`.
final class ScriptedMemorySource: MemorySource {
    let physicalMemory: UInt64 = 4000 * 16384
    let pageSize: UInt64 = 16384
    private let readings: Mutex<[MemoryPages?]>

    init(_ readings: [MemoryPages?]) {
        self.readings = Mutex(readings)
    }

    func readPages() -> MemoryPages? {
        readings.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }
}

/// A login item that exists only inside the test, so tests never touch the user's Login Items.
final class FakeLoginItemService: LoginItemService {
    struct State {
        var status: LoginItemStatus = .notRegistered
        /// What registering leads to: `.enabled`, or `.requiresApproval` when the user has switched meters off.
        var statusAfterRegister: LoginItemStatus = .enabled
        var fails = false
        var calls: [String] = []
    }

    let state = Mutex(State())

    var status: LoginItemStatus { state.withLock { $0.status } }

    func register() throws {
        try state.withLock {
            $0.calls.append("register")
            if $0.fails { throw CocoaError(.featureUnsupported) }
            $0.status = $0.statusAfterRegister
        }
    }

    func unregister() throws {
        try state.withLock {
            $0.calls.append("unregister")
            if $0.fails { throw CocoaError(.featureUnsupported) }
            $0.status = .notRegistered
        }
    }

    func openSystemSettings() {
        state.withLock { $0.calls.append("openSystemSettings") }
    }
}
