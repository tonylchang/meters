# Changelog

All notable changes to meters are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- MIT license (Oct 12, 2026).
- One-row NET/DISK forms show device names between the label and the rates: Wi-Fi when counted, and physical disk names such as disk0. The row keeps room for one name; longer disk lists shorten to fit, and VoiceOver reads the full label. Network rates still total all counted interfaces.
- Floating HUD: a chrome-free, translucent panel with a faint hairline edge and no window shadow, which keeps its drawing cost to the system near zero. It stays above other windows on every Space and over fullscreen apps, without taking focus from the app in use. It sizes itself to its modules, in width and height, fades in and out, remembers whether it is hidden, and adapts to Reduce Transparency, Increase Contrast, and Reduce Motion.
- HUD placement: drag the HUD anywhere on any display. Released within 24 pt of an edge it snaps into line, and near a corner it settles into the corner. It can also sit beside the Dock, snapping 4 pt above the screen's bottom edge as well as just above the Dock. It stays clear of the menu bar, keeps its place through relaunches, resolution and Dock changes, and moves to the main display when its display disconnects, returning when it reconnects.
- Menu bar item: a monochrome gauge icon with Show or Hide HUD, Settings… (⌘,), and Quit meters (⌘Q). meters runs without a Dock icon, and opening it while it is already running brings back a hidden HUD.
- HUD right-click menu: right-click, Control-click, or two-finger click the HUD for the same controls as the menu bar item, without taking focus from the app in use. VoiceOver opens it with VO-Shift-M on any row.
- Settings window, with General, Modules, and HUD tabs in its toolbar: choose which modules the HUD shows and their order, and pick each module's form. The HUD's size follows the chosen modules and their forms.
- Launch at login: an opt-in checkbox on the General tab. It follows macOS's Login Items setting, and says so when macOS needs your approval.
- CPU module: total CPU utilization as a whole-number percent, with a 60-second sparkline on a fixed 0 to 100% scale. The "Total and clusters" form adds one row per CPU cluster, named as the system reports them (for example, Super and Performance). The first value appears within a second of launch, and readings stay within 5 points of `top`. Sampling continues while the HUD is hidden, so the history is current when it reappears; drawing pauses while the HUD is out of sight.
- Memory module: memory used as a whole-number percent of RAM, measured as Activity Monitor measures it, with a 60-second sparkline.
- GPU module: GPU utilization as a whole-number percent with a 60-second sparkline. It reads an undocumented system figure; if a macOS update removes that figure, the row shows "n/a" instead of a wrong value.
- Network module: download and upload rates, summed across physical connections so VPN and virtual links are not counted twice. One row shows both rates as numbers; two rows ("NET ↓" and "↑") add a sparkline to each, scaled to the last minute's peak.
- Disk module: read and write rates across physical disks, leaving out mounted disk images, in the same one-row or two-row forms ("DISK R" and "W").
- Battery module: the charge as a whole-number percent, with an arrow showing whether it is actually rising or falling, measured from the battery's current. It catches a charger too weak for the load, which macOS still reports as charging.
- Thermal module: macOS's thermal state as one word: OK, Warm, Hot, or Critical.
- Swap module: swap space in use ("SWP").
- Free space module: the startup disk's available space as Finder counts it, including purgeable space, in gigabytes or terabytes ("1.20T").
- Every row reads to VoiceOver as one phrase, name first: "CPU, 23 percent", "Memory, 53 percent used". Changes are announced as they happen.
- Threshold states: a row whose metric stays past a threshold for 3 readings turns amber or red, value and sparkline, with the value in semibold, and returns to grey after 3 readings back under, so brief spikes never color it. Defaults: CPU and each cluster amber from 70 to 80% and red above 80%; Memory follows macOS memory pressure; GPU amber at 90% or more; Battery amber at 20% and red at 10% while draining; Thermal amber at Hot and red at Critical; Swap amber over 1 GB and red over 8 GB; Free space amber under 10% of the disk and red under 5%. VoiceOver adds the state: "CPU, 85 percent, critical".

- Thresholds tab in Settings: change each module's amber and red numbers, switch a module's highlighting off, or restore the defaults. An impossible pair, such as red below amber for CPU, is pointed out and not applied.
- "Update every" on the General tab: readings every 0.5, 1, 2, or 5 seconds. Sparklines always keep the last 60 readings.

- Gauges: a "Graphs" setting on the HUD tab switches CPU and its clusters, Memory, GPU, Battery, and Free space from sparklines to bar gauges on a fixed 0 to 100% scale, colored by threshold state. Free space's bar fills with used space, like Finder's storage bar. Sparklines keep recording, so switching back loses no history.

### Changed

- The HUD's width now follows its modules too, and the Width setting is gone. Graphs are at least 60 pt, and one-row Network and Disk keep room for one device name; the default HUD is 188 pt wide (Oct 17, 2026).
- The HUD shows every checked module, and its height follows the modules and their forms. The Rows setting and its "Your modules need" message are gone (Oct 14, 2026).
- Settings changes now reach the window and HUD through one committed state. Related changes apply together, outside changes are reconciled before editing, and unrelated preferences no longer reconfigure every module (Sep 30, 2026).

- The HUD shows 3 rows by default: CPU, MEM, and one-row NET. The other modules are off until chosen in Settings.
- The Settings tabs moved from a tab bar into the window's toolbar, so VoiceOver can move across them without switching tabs and reach every tab's content.

### Fixed

- A Dock or display change during a HUD resize could leave the HUD at the resize's earlier target, overlapping the Dock or off the main display, until the next layout change. A resize undone before its animation began could also keep the larger size. Every move now cancels the one before it (Oct 12, 2026).
- After waking from sleep, the first reading could cover only a few milliseconds, so wake-time network or disk traffic could show as a spike that flattened the rest of the graph. Readings now restart as at launch, with the first 0.25 s after wake (Oct 12, 2026).
- On the Thresholds tab, a valid entry in one field could clear the error for unreadable text in the other while that text stayed. The unreadable text is now replaced with the saved value (Oct 12, 2026).
- The one-row Network and Disk value pairs now sit at the HUD's right edge.
- Threshold text now applies when committed, so typing an invalid number cannot save its valid prefix. Closing Settings, restoring defaults, and outside changes discard stale field text.
- Dragging the HUD supersedes earlier resize and settle animations, including their delayed callbacks.
- Unavailable memory pressure immediately clears stale threshold highlighting and starts the reading count over.
- Settings now shows the same fallback module as the HUD when only unavailable modules were selected.
- CPU and Memory sources release their Mach host references when modules are recreated, while source copies share ownership safely.
- Build failures now propagate through the logging pipeline on macOS's bundled Make 3.81, which ignores the previously used shell-options setting.
- The CPU row's first value could appear after 1.25 s instead of within 1 s, because the system-wide CPU counters update in bursts. meters now sums per-core counters.
- VoiceOver read each row's value before its name ("23 percent, CPU"). Rows now read name first.
- The Launch at login control appeared as a switch; it is now a checkbox, like the rest of Settings.
- A module unchecked and checked again came back with its old value, color, and history; it now starts fresh.
- After waking from sleep, a red or amber row could stay colored for a few seconds; states now start over on wake.
- Choosing a shorter "Update every" interval could skip a reading.
- A corrupt battery reading could crash meters.
- On the Thresholds tab: a change made outside the window could be overwritten by an unsaved entry; percentages accepted fractions; a changed error message was not read to VoiceOver; and on a Mac without a battery, Battery lacked its greyed-out switch.
