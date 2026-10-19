import Foundation

/// Launch-environment hooks used by the automated checks, such as `make smoke` and `make perf`.
public enum AppEnvironment {
    /// Names a separate settings domain, so instances launched by checks never touch the user's settings.
    public static let settingsSuiteVariable = "METERS_SETTINGS_SUITE"
    /// Names a file that receives check markers for `make smoke` and `make perf`.
    public static let markerFileVariable = "METERS_MARKER_FILE"

    public static func settingsDefaults(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UserDefaults {
        if let suite = environment[settingsSuiteVariable], !suite.isEmpty,
            let defaults = UserDefaults(suiteName: suite)
        {
            return defaults
        }
        return .standard
    }

    /// Appends `<name> <seconds since 1970> [values...]` to the marker file, when one is configured.
    public static func recordMarker(
        _ name: String, values: [Double] = [], environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard let path = environment[markerFileVariable], !path.isEmpty else { return }
        let fields =
            [name, String(format: "%.3f", Date().timeIntervalSince1970)] + values.map { String(format: "%g", $0) }
        let line = fields.joined(separator: " ") + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}
