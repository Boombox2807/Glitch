import AppKit
import IOKit.ps

/// A snapshot of what's going on on the Mac, added to every request so Glitch
/// can answer "what am I listening to?", "what app is this?", "how's my battery?".
@MainActor
enum LiveContext {
    static func snapshot(for question: String) -> String {
        var lines: [String] = []

        let date = Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute())
        lines.append("Now: \(date)")

        if let app = NSWorkspace.shared.frontmostApplication?.localizedName {
            lines.append("Frontmost app: \(app)")
        }
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
        lines.append("Open apps: \(running.joined(separator: ", "))")

        let badges = running.compactMap { app in badge(for: app).map { "\(app): \($0)" } }
        lines.append("Unread badges on Dock icons (notifications/pings): "
                     + (badges.isEmpty ? "none" : badges.joined(separator: ", ")))

        ShortcutsRunner.refreshIfNeeded()
        if !ShortcutsRunner.names.isEmpty {
            lines.append("User's Shortcuts (run with [SHORTCUT: name]): " + ShortcutsRunner.names.joined(separator: " | "))
        }

        lines.append("Now playing: \(nowPlaying() ?? "nothing")")
        if let battery = battery() { lines.append("Battery: \(battery)") }
        if let volume = runScript("output volume of (get volume settings)") {
            lines.append("Output volume: \(volume)%")
        }
        // The clipboard can hold passwords, so it's only shared when you ask about it.
        let asksClipboard = question.range(of: #"\b(clipboard|copied|paste)\b"#,
                                           options: [.regularExpression, .caseInsensitive]) != nil
        if asksClipboard, let clip = NSPasteboard.general.string(forType: .string)?.prefix(300), !clip.isEmpty {
            lines.append("Clipboard (start): \(clip)")
        }

        return "Live info about the user's Mac right now (use it only when relevant):\n"
            + lines.map { "- \($0)" }.joined(separator: "\n")
    }

    /// Asks Spotify or Music, but only if already running (so it never launches them).
    private static func nowPlaying() -> String? {
        for app in ["Spotify", "Music"] where isRunning(app) {
            let script = """
            tell application "\(app)"
                if player state is playing then
                    return (name of current track) & " by " & (artist of current track) & " — \(app)"
                end if
            end tell
            """
            if let result = runScript(script), !result.isEmpty { return result }
        }
        return nil
    }

    /// The red Dock badge (e.g. Discord's unread count), via lsappinfo. Needs no permission.
    private static func badge(for app: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lsappinfo")
        process.arguments = ["info", "-only", "StatusLabel", app]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let range = out.range(of: #""label"="([^"]+)""#, options: .regularExpression) else { return nil }
        return String(out[range]).replacingOccurrences(of: "\"label\"=", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private static func isRunning(_ name: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.localizedName == name }
    }

    private static func battery() -> String? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              let first = list.first,
              let desc = IOPSGetPowerSourceDescription(info, first)?.takeUnretainedValue() as? [String: Any],
              let level = desc[kIOPSCurrentCapacityKey] as? Int else { return nil }
        let charging = (desc[kIOPSIsChargingKey] as? Bool) == true ? ", charging" : ""
        return "\(level)%\(charging)"
    }

    private static func runScript(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result?.stringValue : nil
    }
}
