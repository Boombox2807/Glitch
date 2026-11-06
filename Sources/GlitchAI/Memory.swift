import Foundation

struct MemoryItem: Identifiable, Codable, Equatable {
    var id = UUID()
    let text: String
    let created: Date
}

/// Facts Glitch learns about you, saved in ~/Library/Application Support/GlitchAI/memories.json.
@MainActor
final class MemoryStore: ObservableObject {
    static let shared = MemoryStore()
    @Published private(set) var items: [MemoryItem] = []

    private let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GlitchAI", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("memories.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([MemoryItem].self, from: data) {
            items = saved
        }
    }

    /// Returns whether a new memory was actually added (false for blanks and duplicates).
    @discardableResult
    func add(_ text: String) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty,
              !items.contains(where: { $0.text.caseInsensitiveCompare(clean) == .orderedSame }) else { return false }
        items.append(MemoryItem(text: clean, created: .now))
        save()
        AccountStore.shared.scheduleSync()
        return true
    }

    /// Removes memories containing the words; returns the ones removed.
    @discardableResult
    func forget(matching text: String) -> [MemoryItem] {
        let needle = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let removed = items.filter { $0.text.lowercased().contains(needle) }
        guard !removed.isEmpty else { return [] }
        items.removeAll { $0.text.lowercased().contains(needle) }
        save()
        AccountStore.shared.scheduleSync()
        return removed
    }

    func delete(_ item: MemoryItem) {
        items.removeAll { $0.id == item.id }
        save()
        AccountStore.shared.scheduleSync()
    }

    /// Adds memories this Mac doesn't have yet (matched by id or text).
    func merge(_ incoming: [MemoryItem]) {
        let new = incoming.filter { m in
            !items.contains { $0.id == m.id || $0.text.caseInsensitiveCompare(m.text) == .orderedSame }
        }
        guard !new.isEmpty else { return }
        items += new
        save()
    }

    func replaceAll(with items: [MemoryItem]) {
        self.items = items
        save()
    }

    func deleteAll() {
        items.removeAll()
        save()
        AccountStore.shared.scheduleSync()
    }

    /// The block appended to the system prompt.
    var promptSection: String {
        guard !items.isEmpty else { return "You remember nothing about the user yet." }
        return "What you remember about the user:\n" + items.map { "- \($0.text)" }.joined(separator: "\n")
    }

    /// Pulls [REMEMBER: …] and [FORGET: …] tags out of a reply, applies them,
    /// and returns the reply without the tags.
    func absorbTags(in reply: String) -> String {
        var text = reply
        var toasts: [MemoryToast.Item] = []
        for tag in ["REMEMBER", "FORGET"] {
            let pattern = "\\[\(tag):\\s*([^\\]]+)\\]"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard let r = Range(match.range(at: 1), in: text) else { continue }
                let value = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                if tag == "REMEMBER" {
                    if add(value) { toasts.append(.init(kind: .etched, text: value)) }
                } else {
                    for gone in forget(matching: value) { toasts.append(.init(kind: .erased, text: gone.text)) }
                }
            }
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                  withTemplate: "")
        }
        // Only Glitch's own memory changes get a notification, not manual edits, imports or sync.
        if !toasts.isEmpty { MemoryToast.shared.show(toasts) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: file, options: .atomic) }
    }
}
