import Foundation
import SwiftUI

/// Everything Glitch keeps, as one document for the sync server.
struct GlitchBackup: Codable {
    struct Settings: Codable {
        var provider, openRouterModel, ollamaModel, cloudModel, ollamaKeepAlive: String
        var reviewDictation, useBuiltInMic, showInDock: Bool
    }
    struct Keys: Codable { var openRouter, ollamaCloud: String }

    var version = 1
    var exportedAt: Date
    var device: String
    var settings: Settings
    var apiKeys: Keys
    var memories: [MemoryItem]
    var conversations: [Conversation]
    /// IDs deleted on this Mac since the last sync, so the server (which merges uploads) removes them too.
    struct Deleted: Codable { var conversations: [String]; var memories: [String] }
    var deleted: Deleted?

    init(exportedAt: Date, device: String, settings: Settings, apiKeys: Keys,
         memories: [MemoryItem], conversations: [Conversation]) {
        self.exportedAt = exportedAt
        self.device = device
        self.settings = settings
        self.apiKeys = apiKeys
        self.memories = memories
        self.conversations = conversations
    }

    /// Reads chats and memories one by one, skipping any single entry that's malformed
    /// (e.g. a bad id written by another client) instead of rejecting the whole document.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        exportedAt = (try? c.decode(Date.self, forKey: .exportedAt)) ?? .distantPast
        device = (try? c.decode(String.self, forKey: .device)) ?? "?"
        settings = try c.decode(Settings.self, forKey: .settings)
        apiKeys = (try? c.decode(Keys.self, forKey: .apiKeys)) ?? Keys(openRouter: "", ollamaCloud: "")
        memories = (try? c.decode([Lossy<MemoryItem>].self, forKey: .memories))?.compactMap(\.value) ?? []
        conversations = (try? c.decode([Lossy<Conversation>].self, forKey: .conversations))?.compactMap(\.value) ?? []
        deleted = nil
    }
}

/// Decodes to nil instead of throwing, so one bad array element doesn't fail the array.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// Optional sync with your own Glitch server (see README: "Sync server API"). Off until a server URL is set.
@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()
    /// The sync server, e.g. https://glitch.example.com. Empty means sync is off.
    @Published var server: String {
        didSet { UserDefaults.standard.set(server, forKey: "account.server") }
    }
    var baseURL: URL? {
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }

    @Published private(set) var email: String
    @Published private(set) var signedIn: Bool
    @Published private(set) var busy = false
    @Published var status: String?
    @Published private(set) var lastExport: Date?

    private let defaults = UserDefaults.standard
    private var token: String? { Secrets.get("voidbox-token") }

    private init() {
        email = defaults.string(forKey: "account.email") ?? ""
        signedIn = Secrets.get("voidbox-token") != nil
        lastExport = defaults.object(forKey: "account.lastExport") as? Date
        autoSync = defaults.object(forKey: "account.autoSync") as? Bool ?? true
        server = defaults.string(forKey: "account.server") ?? ""
    }

    func signIn(email: String, password: String) async {
        await run("Signed in.") {
            struct Reply: Decodable { let token: String }
            let data = try await self.request("POST", "api/login", body: ["email": email, "password": password], auth: false)
            let reply = try JSONDecoder().decode(Reply.self, from: data)
            Secrets.set(reply.token, for: "voidbox-token")
            self.email = email
            self.defaults.set(email, forKey: "account.email")
            self.signedIn = true
        }
        if signedIn { await sync(quiet: true) }
    }

    func signOut() {
        Secrets.set("", for: "voidbox-token")
        signedIn = false
        pendingSync?.cancel()
        status = nil
    }

    @Published var autoSync: Bool {
        didSet { defaults.set(autoSync, forKey: "account.autoSync") }
    }
    private var pendingSync: Task<Void, Never>?
    private var timer: Timer?

    /// Starts background syncing: once now, then every 5 minutes.
    func startAutoSync() {
        Log.write("sync: auto-sync starting (signedIn=\(signedIn), autoSync=\(autoSync))")
        scheduleSync(after: 2)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in AccountStore.shared.scheduleSync(after: 0) }
        }
    }

    /// Syncs a few seconds from now, folding bursts of changes (e.g. several replies) into one upload.
    func scheduleSync(after seconds: Double = 5) {
        guard signedIn, autoSync, baseURL != nil else { return }
        pendingSync?.cancel()
        pendingSync = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await sync(quiet: true)
        }
    }

    /// Two-way sync: pulls the server copy, merges it with this Mac (deletions included), uploads the result.
    func sync(quiet: Bool = false) async {
        guard signedIn, !busy else { Log.write("sync: skipped (signedIn=\(signedIn), busy=\(busy))"); return }
        Log.write("sync: starting")
        let work = {
            if let data = try? await self.request("GET", "api/glitch/data") {
                // If the server copy can't be read, stop rather than overwrite it.
                let remote = try Self.decoder.decode(GlitchBackup.self, from: data)
                self.merge(remote)
            }
            // Anything that was on both sides last time but is gone here was deleted on this Mac.
            let deleted = GlitchBackup.Deleted(
                conversations: Array(self.baselineConversations.subtracting(ConversationStore.shared.all.map(\.id.uuidString))),
                memories: Array(self.baselineMemories.subtracting(MemoryStore.shared.items.map(\.id.uuidString))))
            var snapshot = Self.snapshot()
            snapshot.deleted = deleted
            let body = try Self.encoder.encode(snapshot)
            _ = try await self.request("PUT", "api/glitch/data", rawBody: body)
            self.rememberBaseline()
            self.lastExport = .now
            self.defaults.set(self.lastExport, forKey: "account.lastExport")
        }
        if quiet {
            busy = true
            defer { busy = false }
            do {
                try await work()
                Log.write("sync: done")
            } catch {
                status = "Sync failed: \(error.localizedDescription)"
                Log.write("sync: failed: \(error.localizedDescription)")
            }
        } else {
            await run("Synced with the server.", work)
        }
    }

    // MARK: - Three-way merge

    /// IDs present on both sides after the last sync. Something in the baseline that's now missing
    /// on one side was deleted there, so it's deleted on the other side too instead of coming back.
    private var baselineMemories: Set<String> {
        Set(defaults.stringArray(forKey: "sync.baseline.memories") ?? [])
    }
    private var baselineConversations: Set<String> {
        Set(defaults.stringArray(forKey: "sync.baseline.conversations") ?? [])
    }

    private func rememberBaseline() {
        defaults.set(MemoryStore.shared.items.map(\.id.uuidString), forKey: "sync.baseline.memories")
        defaults.set(ConversationStore.shared.all.map(\.id.uuidString), forKey: "sync.baseline.conversations")
    }

    private func merge(_ remote: GlitchBackup) {
        MemoryStore.shared.replaceAll(with: Self.merged(
            local: MemoryStore.shared.items, remote: remote.memories, baseline: baselineMemories,
            key: { $0.id.uuidString }, newer: { _, _ in false }))
        ConversationStore.shared.replaceAll(with: Self.merged(
            local: ConversationStore.shared.all, remote: remote.conversations, baseline: baselineConversations,
            key: { $0.id.uuidString }, newer: { remote, local in remote.updated > local.updated }))
    }

    /// - In both: keep local unless `newer(remote, local)`.
    /// - Only remote: add it, unless it was in the baseline (deleted on this Mac).
    /// - Only local: keep it, unless it was in the baseline (deleted on the server/web).
    private static func merged<T>(local: [T], remote: [T], baseline: Set<String>,
                                  key: (T) -> String, newer: (T, T) -> Bool) -> [T] {
        let remoteByKey = Dictionary(remote.map { (key($0), $0) }, uniquingKeysWith: { a, _ in a })
        let localKeys = Set(local.map(key))
        var result: [T] = local.compactMap { item in
            guard let other = remoteByKey[key(item)] else { return baseline.contains(key(item)) ? nil : item }
            return newer(other, item) ? other : item
        }
        result += remote.filter { !localKeys.contains(key($0)) && !baseline.contains(key($0)) }
        return result
    }

    func restore() async {
        await run("Restored from the server.") {
            let data = try await self.request("GET", "api/glitch/data")
            Self.apply(try Self.decoder.decode(GlitchBackup.self, from: data))
        }
    }

    // MARK: - Snapshot

    private static func snapshot() -> GlitchBackup {
        let s = AppSettings.shared
        return GlitchBackup(
            exportedAt: .now,
            device: Host.current().localizedName ?? "Mac",
            settings: .init(provider: s.provider.rawValue, openRouterModel: s.openRouterModel, ollamaModel: s.ollamaModel,
                            cloudModel: s.cloudModel, ollamaKeepAlive: s.ollamaKeepAlive,
                            reviewDictation: s.reviewDictation, useBuiltInMic: s.useBuiltInMic, showInDock: s.showInDock),
            apiKeys: .init(openRouter: s.apiKey, ollamaCloud: s.cloudKey),
            memories: MemoryStore.shared.items,
            conversations: ConversationStore.shared.all)
    }

    private static func apply(_ backup: GlitchBackup) {
        let s = AppSettings.shared
        if let provider = ProviderKind(rawValue: backup.settings.provider) { s.provider = provider }
        s.openRouterModel = backup.settings.openRouterModel
        s.ollamaModel = backup.settings.ollamaModel
        s.cloudModel = backup.settings.cloudModel
        s.ollamaKeepAlive = backup.settings.ollamaKeepAlive
        s.reviewDictation = backup.settings.reviewDictation
        s.useBuiltInMic = backup.settings.useBuiltInMic
        s.showInDock = backup.settings.showInDock
        if !backup.apiKeys.openRouter.isEmpty { s.apiKey = backup.apiKeys.openRouter }
        if !backup.apiKeys.ollamaCloud.isEmpty { s.cloudKey = backup.apiKeys.ollamaCloud }
        MemoryStore.shared.replaceAll(with: backup.memories)
        ConversationStore.shared.merge(backup.conversations)
    }

    // MARK: - Networking

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    /// Accepts ISO dates with or without fractional seconds (the web side may write either).
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let plain = ISO8601DateFormatter()
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = plain.date(from: text) ?? fractional.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date: \(text)"))
        }
        return d
    }()

    private struct ServerError: LocalizedError {
        let errorDescription: String?
    }

    private func request(_ method: String, _ path: String, body: [String: String]? = nil,
                         rawBody: Data? = nil, auth: Bool = true) async throws -> Data {
        guard let baseURL else { throw ServerError(errorDescription: "No sync server set.") }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if auth {
            guard let token else { throw ServerError(errorDescription: "Not signed in.") }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        if let rawBody { request.httpBody = rawBody }

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200..<300: return data
        case 401:
            if auth { signOut() }
            throw ServerError(errorDescription: auth ? "Session expired. Sign in again." : "Wrong email or password.")
        case 404 where path == "api/glitch/data" && method == "GET":
            throw ServerError(errorDescription: "Nothing exported yet.")
        default:
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw ServerError(errorDescription: message ?? "Server error \(code).")
        }
    }

    private func run(_ success: String, _ work: @escaping () async throws -> Void) async {
        busy = true
        status = nil
        defer { busy = false }
        do {
            try await work()
            status = success
        } catch {
            status = error.localizedDescription
        }
    }
}

struct AccountSection: View {
    @ObservedObject private var account = AccountStore.shared
    @State private var email = AccountStore.shared.email
    @State private var password = ""

    var body: some View {
        if account.signedIn {
            LabeledContent("Signed in as", value: account.email)
            Toggle("Sync automatically", isOn: $account.autoSync)
                .help("After each reply, at launch and every 5 minutes. Deletions sync too.")
            HStack {
                Button("Sync now") { Task { await account.sync() } }
                Button("Restore from server") { Task { await account.restore() } }
                Spacer()
                Button("Sign out", role: .destructive) { account.signOut() }
            }
            .disabled(account.busy)
            if let last = account.lastExport {
                Text("Last synced: \(last.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Syncs memories and conversations both ways with \(account.server), and uploads this Mac's settings and API keys.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            TextField("Server", text: $account.server, prompt: Text("https://your-glitch-server"))
            Text("Optional. Only for syncing with a Glitch server you run yourself. Leave empty to keep everything on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Email", text: $email)
                .textContentType(.username)
            SecureField("Password", text: $password)
                .textContentType(.password)
                .onSubmit(signIn)
            Button("Sign in", action: signIn)
                .disabled(account.busy || account.baseURL == nil || email.isEmpty || password.isEmpty)
        }
        if account.busy { ProgressView().controlSize(.small) }
        if let status = account.status {
            Text(status).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func signIn() {
        let pw = password
        password = ""
        Task { await account.signIn(email: email, password: pw) }
    }
}
