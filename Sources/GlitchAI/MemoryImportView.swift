import SwiftUI
import UniformTypeIdentifiers

/// Paste or open memories exported from another AI (ChatGPT, Claude, Gemini…).
struct MemoryImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var copied = false

    static let exportPrompt = """
    List everything you remember about me: facts, preferences, projects, people, \
    and how I like you to respond. One short fact per line, written in third person \
    (e.g. "User likes DOORS"). No headings or commentary.
    """

    private var facts: [String] { MemoryImport.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import memories").font(.headline)
            Text("Paste this into ChatGPT, Claude or another AI, then paste its answer below. You can also open a saved export (.txt, .md, .json).")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Text(Self.exportPrompt).font(.caption.monospaced())
                    .padding(8).background(Color.white.opacity(0.06)).cornerRadius(6)
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.exportPrompt, forType: .string)
                    copied = true
                }
            }
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(GlitchTheme.violet.opacity(0.5)))
            HStack {
                Button("Open file…", action: openFile)
                Spacer()
                Text("\(facts.count) memories found").foregroundStyle(.secondary)
                Button("Cancel") { dismiss() }
                Button("Import") {
                    facts.forEach { MemoryStore.shared.add($0) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(facts.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 520)
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .json, UTType(filenameExtension: "md") ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url, let content = try? String(contentsOf: url) {
            text = content
        }
    }
}

enum MemoryImport {
    /// Turns an export into individual facts: JSON string values, or one fact per line
    /// with bullets, numbering and headings stripped.
    static func parse(_ raw: String) -> [String] {
        let lines: [String]
        if let data = raw.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) {
            lines = strings(in: json)
        } else {
            lines = raw.components(separatedBy: .newlines)
        }
        var seen = Set<String>()
        return lines.compactMap { line in
            var s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("#") { return nil }
            s = s.replacingOccurrences(of: #"^([-*•]|\d+[.)])\s*"#, with: "", options: .regularExpression)
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard s.count >= 3, s.count <= 400, seen.insert(s.lowercased()).inserted else { return nil }
            return s
        }
    }

    private static func strings(in json: Any) -> [String] {
        switch json {
        case let s as String: return [s]
        case let a as [Any]: return a.flatMap(strings)
        case let d as [String: Any]:
            // Prefer obvious content fields; otherwise take every string value.
            for key in ["content", "text", "memory", "value"] { if let v = d[key] { return strings(in: v) } }
            return d.values.flatMap(strings)
        default: return []
        }
    }
}
