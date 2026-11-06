import SwiftUI

struct Conversation: Identifiable, Codable {
    var id = UUID()
    var title: String
    var updated: Date
    var messages: [ChatMessage]
}

/// Saved chats, one JSON file each in ~/Library/Application Support/GlitchAI/conversations.
/// Images aren't saved, only text, so the files stay small.
@MainActor
final class ConversationStore: ObservableObject {
    static let shared = ConversationStore()
    @Published private(set) var all: [Conversation] = []

    private let dir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GlitchAI/conversations", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        all = files.compactMap { try? JSONDecoder().decode(Conversation.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updated > $1.updated }
    }

    func save(id: UUID, messages: [ChatMessage]) {
        guard let first = messages.first(where: { $0.role == .user }) else { return }
        let title = String(first.content.prefix(48)).trimmingCharacters(in: .whitespacesAndNewlines)
        let textOnly = messages.map { ChatMessage(id: $0.id, role: $0.role, content: $0.content) }
        let convo = Conversation(id: id, title: title.isEmpty ? "Image" : title, updated: .now, messages: textOnly)
        all.removeAll { $0.id == id }
        all.insert(convo, at: 0)
        if let data = try? JSONEncoder().encode(convo) {
            try? data.write(to: file(id), options: .atomic)
        }
    }

    /// Adds restored conversations, keeping whichever copy of each is newer.
    func merge(_ incoming: [Conversation]) {
        for convo in incoming {
            if let existing = all.first(where: { $0.id == convo.id }), existing.updated >= convo.updated { continue }
            all.removeAll { $0.id == convo.id }
            all.append(convo)
            if let data = try? JSONEncoder().encode(convo) { try? data.write(to: file(convo.id), options: .atomic) }
        }
        all.sort { $0.updated > $1.updated }
    }

    /// Replaces the whole list (used by sync), writing changed chats and removing deleted ones.
    func replaceAll(with conversations: [Conversation]) {
        let keep = Set(conversations.map(\.id))
        for old in all where !keep.contains(old.id) { try? FileManager.default.removeItem(at: file(old.id)) }
        for convo in conversations {
            if let data = try? JSONEncoder().encode(convo) { try? data.write(to: file(convo.id), options: .atomic) }
        }
        all = conversations.sorted { $0.updated > $1.updated }
    }

    func deleteIfExists(_ id: UUID) {
        all.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: file(id))
    }

    func delete(_ convo: Conversation) {
        all.removeAll { $0.id == convo.id }
        try? FileManager.default.removeItem(at: file(convo.id))
        AccountStore.shared.scheduleSync()
    }

    private func file(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).json") }
}

struct HistoryView: View {
    @ObservedObject private var store = ConversationStore.shared
    @EnvironmentObject var chat: ChatModel
    let onOpen: () -> Void

    var body: some View {
        if store.all.isEmpty {
            GlitchText(text: "NOTHING SAVED.\nYET.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(store.all) { convo in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(convo.title).font(GlitchTheme.mono).lineLimit(1)
                                .foregroundStyle(convo.id == chat.conversationID ? GlitchTheme.cyan : .white)
                            Text(convo.updated.formatted(date: .abbreviated, time: .shortened) + " · \(convo.messages.count) messages")
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { store.delete(convo) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        chat.open(convo)
                        onOpen()
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
    }
}
