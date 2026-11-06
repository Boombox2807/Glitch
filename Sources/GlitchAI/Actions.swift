import AppKit

/// Things Glitch can actually do on the Mac. Each returns a short report of what happened,
/// which is passed to the model so it never claims an action that failed.
///
/// Two ways in:
/// - `performDirect` recognises plain commands ("open Discord", "volume 30") before the model runs,
///   so they work even when a small model forgets its tags.
/// - `absorbTags` runs [OPEN: …] style tags the model writes for anything phrased less directly.
@MainActor
enum Actions {
    static func performDirect(_ text: String) -> String? {
        // Strip politeness so "hey glitch, can you open discord for me please" becomes "open discord".
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        t = t.replacingOccurrences(
            of: #"^(?:(?:hey|ok|okay|yo)\s+)?(?:glitch[,\s]+)?(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?"#,
            with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"(?:[,\s]+(?:please|pls|plz|for me|now|rn|right now|thanks|thank you))+$"#,
                                   with: "", options: [.regularExpression, .caseInsensitive])
        t = t.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if let app = match(t, #"^(?:open|launch|start|run)\s+(?:up\s+)?(?:the\s+)?(.+?)(?:\s+app)?$"#) {
            if let url = urlIfWebsite(app) { return openURL(url) }
            return openApp(app)
        }
        if let app = match(t, #"^(?:quit|close|kill)\s+(?:the\s+)?(.+?)(?:\s+app)?$"#) {
            return quitApp(app)
        }
        if let n = match(t, #"(?:volume|sound)\s+(?:to\s+)?(\d{1,3})\s*%?$"#), let level = Int(n) {
            return setVolume(level)
        }
        if match(t, #"^(mute)$"#) != nil { return setVolume(0) }
        if match(t, #"^(pause|play|resume|play music|pause music|pause the music)$"#) != nil { return media("playpause") }
        if match(t, #"^(next|skip|next song|next track|skip song|skip this)$"#) != nil { return media("next track") }
        if match(t, #"^(previous|previous song|previous track|go back a song)$"#) != nil { return media("previous track") }
        return nil
    }

    /// Runs action tags in a reply and returns (reply without tags, reports).
    static func absorbTags(in reply: String) -> (String, [String]) {
        var text = reply
        var reports: [String] = []
        let handlers: [(String, (String) -> String)] = [
            ("OPEN", { arg in urlIfWebsite(arg).map(openURL) ?? openApp(arg) }),
            ("QUIT", quitApp),
            ("VOLUME", { Int($0.filter(\.isNumber)).map(setVolume) ?? "Volume not changed: no number." }),
            ("MEDIA", { arg in
                switch arg.lowercased() {
                case let a where a.contains("next"): return media("next track")
                case let a where a.contains("prev"): return media("previous track")
                default: return media("playpause")
                }
            }),
            ("URL", { arg in URL(string: arg).map(openURL) ?? "Bad link: \(arg)" }),
        ]
        for (tag, run) in handlers {
            guard let regex = try? NSRegularExpression(pattern: "\\[\(tag):\\s*([^\\]]+)\\]", options: .caseInsensitive)
            else { continue }
            for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let r = Range(m.range(at: 1), in: text) {
                    reports.append(run(String(text[r]).trimmingCharacters(in: .whitespaces)))
                }
            }
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), reports)
    }

    // MARK: - Actions

    static func openApp(_ name: String) -> String {
        guard let url = findApp(name) else { return "Could not find an app called \(name)." }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return "Opened \(url.deletingPathExtension().lastPathComponent)."
    }

    static func quitApp(_ name: String) -> String {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.localizedName?.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
        guard !apps.isEmpty else { return "\(name) wasn't running." }
        apps.forEach { $0.terminate() }
        return "Quit \(apps[0].localizedName ?? name)."
    }

    static func setVolume(_ level: Int) -> String {
        let clamped = min(max(level, 0), 100)
        _ = runScript("set volume output volume \(clamped)")
        return "Set volume to \(clamped)%."
    }

    static func media(_ command: String) -> String {
        for app in ["Spotify", "Music"] where NSWorkspace.shared.runningApplications.contains(where: { $0.localizedName == app }) {
            if runScript("tell application \"\(app)\" to \(command)") {
                return "\(app): \(command == "playpause" ? "play/pause" : command)."
            }
        }
        return "No music app is open."
    }

    static func openURL(_ url: URL) -> String {
        NSWorkspace.shared.open(url)
        return "Opened \(url.absoluteString)."
    }

    // MARK: - Helpers

    /// Finds an installed app by name, case-insensitively, in the usual folders.
    private static func findApp(_ name: String) -> URL? {
        let wanted = name.lowercased()
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                    "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        var candidates: [URL] = []
        for dir in dirs {
            let items = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            candidates += items.filter { $0.hasSuffix(".app") }.map { URL(fileURLWithPath: dir).appendingPathComponent($0) }
        }
        func displayName(_ url: URL) -> String {
            (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension.lowercased()
        }
        func fileName(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent.lowercased() }
        return candidates.first { fileName($0) == wanted || displayName($0) == wanted }
            ?? candidates.first { fileName($0).hasPrefix(wanted) || displayName($0).hasPrefix(wanted) }
            ?? candidates.first { fileName($0).contains(wanted) || displayName($0).contains(wanted) }
    }

    private static func urlIfWebsite(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.range(of: #"^(https?://)?[\w-]+(\.[\w-]+)+(/\S*)?$"#, options: .regularExpression) != nil else { return nil }
        return URL(string: t.hasPrefix("http") ? t : "https://\(t)")
    }

    private static func match(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    @discardableResult
    private static func runScript(_ source: String) -> Bool {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil
    }
}
