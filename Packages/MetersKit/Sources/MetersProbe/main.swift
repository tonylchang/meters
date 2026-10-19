// meters-probe: development tool for `make smoke` and `make perf`. Never linked into the app.
//
//   meters-probe windows <pid>   One line per window owned by <pid>:
//                                layer=<n> x=<x> y=<y> width=<w> height=<h> onscreen=<0|1> alpha=<a>
//   meters-probe now             Seconds since 1970, with millisecond precision.
//   meters-probe session         Screen lock and display sleep state: locked=<0|1> asleep=<0|1>
//
// Window bounds use the window server's top-left origin, and the window server scales them while
// the screen is locked. Reading bounds and layers does not require Screen Recording permission;
// window titles, which would, are never read.

import CoreGraphics
import Foundation

let usage = "usage: meters-probe windows <pid> | now | session\n"

func printWindows(pid: pid_t) {
    let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
    guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return }
    for window in windows {
        guard let owner = window[kCGWindowOwnerPID as String] as? Int32, owner == pid,
            let layer = window[kCGWindowLayer as String] as? Int,
            let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
        else { continue }
        let onscreen = (window[kCGWindowIsOnscreen as String] as? Bool) == true ? 1 : 0
        let alpha = window[kCGWindowAlpha as String] as? Double ?? 0
        print(
            "layer=\(layer) x=\(Int(bounds.minX)) y=\(Int(bounds.minY)) "
                + "width=\(Int(bounds.width)) height=\(Int(bounds.height)) onscreen=\(onscreen) "
                + String(format: "alpha=%.2f", alpha))
    }
}

let arguments = CommandLine.arguments
switch arguments.dropFirst().first {
case "windows":
    guard arguments.count == 3, let pid = Int32(arguments[2]) else {
        FileHandle.standardError.write(Data(usage.utf8))
        exit(2)
    }
    printWindows(pid: pid)
case "now":
    print(String(format: "%.3f", Date().timeIntervalSince1970))
case "session":
    let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
    let locked = (session["CGSSessionScreenIsLocked"] as? Bool) == true ? 1 : 0
    let asleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0 ? 1 : 0
    print("locked=\(locked) asleep=\(asleep)")
default:
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}
