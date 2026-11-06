import AppKit

/// Runs the user's own Shortcuts (from the Shortcuts app) by name, only when they ask.
/// Ones that sound risky (shut down, send, call, delete, pay…) ask for confirmation first.
@MainActor
enum ShortcutsRunner {
    private(set) static var names: [String] = []
    private static var lastRefresh = Date.distantPast

    /// Reloads the list at most every 10 minutes.
    static func refreshIfNeeded() {
        guard Date.now.timeIntervalSince(lastRefresh) > 600 else { return }
        lastRefresh = .now
        Task.detached {
            let output = run(["list"])
            let list = output.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            await MainActor.run { names = list }
        }
    }

    /// Finds the shortcut the model named, tolerating case and small differences.
    static func match(_ name: String) -> String? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return names.first { $0.lowercased() == wanted }
            ?? names.first { $0.lowercased().contains(wanted) || wanted.contains($0.lowercased()) }
    }

    private static let riskyWords = [
        "shut", "restart", "reboot", "sleep", "log out", "logout", "send", "message", "call", "delete", "remove",
        "erase", "pay", "buy", "order", "post", "email",
        "выключ", "перезагр", "отправ", "сообщ", "звон", "удал", "оплат", "купи",
        "вимк", "надісл", "повідом", "дзвін", "видал",
    ]

    static func isRisky(_ name: String) -> Bool {
        let n = name.lowercased()
        return riskyWords.contains { n.contains($0) }
    }

    /// Runs a shortcut and returns a short report for the chat.
    static func runShortcut(named requested: String) async -> String {
        guard let name = match(requested) else { return "No Shortcut called \"\(requested)\"." }
        if isRisky(name) {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Run \"\(name)\"?"
            alert.informativeText = "Glitch wants to run this Shortcut. It sounds like it may send something, "
                + "change your Mac's power state or make a call."
            alert.addButton(withTitle: "Run")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return "You stopped \"\(name)\"." }
        }
        let output = await Task.detached { run(["run", name]) }.value
        Log.write("shortcut: ran \(name)")
        return output.isEmpty ? "Ran Shortcut \"\(name)\"." : "Ran Shortcut \"\(name)\": \(output.prefix(200))"
    }

    nonisolated private static func run(_ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
