import AppKit
import Foundation
import Security

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var provider: ProviderKind {
        didSet { defaults.set(provider.rawValue, forKey: "provider") }
    }
    @Published var openRouterModel: String {
        didSet { defaults.set(openRouterModel, forKey: "openRouterModel") }
    }
    @Published var ollamaModel: String {
        didSet { defaults.set(ollamaModel, forKey: "ollamaModel") }
    }
    /// How long Ollama keeps the model in RAM after an answer, in Ollama's keep_alive format.
    @Published var ollamaKeepAlive: String {
        didSet { defaults.set(ollamaKeepAlive, forKey: "ollamaKeepAlive") }
    }
    /// After dictation, put the words in the text bar to fix before sending.
    @Published var reviewDictation: Bool {
        didSet { defaults.set(reviewDictation, forKey: "reviewDictation") }
    }
    /// Show Glitch in the Dock and ⌘Tab, not just the menu bar.
    @Published var showInDock: Bool {
        didSet {
            defaults.set(showInDock, forKey: "showInDock")
            applyDockPolicy()
        }
    }

    func applyDockPolicy() {
        NSApplication.shared.setActivationPolicy(showInDock ? .regular : .accessory)
        if showInDock { NSApp.activate(ignoringOtherApps: true) }
    }

    /// Listen through the Mac's own mic so Bluetooth headphones don't drop into call-quality audio.
    @Published var useBuiltInMic: Bool {
        didSet { defaults.set(useBuiltInMic, forKey: "useBuiltInMic") }
    }
    @Published var cloudModel: String {
        didSet { defaults.set(cloudModel, forKey: "cloudModel") }
    }
    @Published var cloudKey: String {
        didSet { Secrets.set(cloudKey, for: "ollamacloud") }
    }
    @Published var apiKey: String {
        didSet { Secrets.set(apiKey, for: "openrouter") }
    }

    private init() {
        provider = ProviderKind(rawValue: defaults.string(forKey: "provider") ?? "") ?? .openRouter
        openRouterModel = defaults.string(forKey: "openRouterModel") ?? "openrouter/auto"
        ollamaModel = defaults.string(forKey: "ollamaModel") ?? "gemma3:4b"
        ollamaKeepAlive = defaults.string(forKey: "ollamaKeepAlive") ?? "5m"
        reviewDictation = defaults.object(forKey: "reviewDictation") as? Bool ?? true
        showInDock = defaults.bool(forKey: "showInDock")
        useBuiltInMic = defaults.object(forKey: "useBuiltInMic") as? Bool ?? true
        cloudModel = defaults.string(forKey: "cloudModel") ?? "gemma4:31b"
        cloudKey = Secrets.get("ollamacloud") ?? ""
        apiKey = Secrets.get("openrouter") ?? ""
    }

    var client: LLMClient {
        switch provider {
        case .openRouter: return LLMClient(kind: .openRouter, model: openRouterModel, apiKey: apiKey)
        case .ollama: return LLMClient(kind: .ollama, model: ollamaModel, apiKey: nil)
        case .ollamaCloud: return LLMClient(kind: .ollamaCloud, model: cloudModel, apiKey: cloudKey)
        }
    }
}

/// Glitch's secrets (API keys, VoidBox sign-in) in a private file:
/// ~/Library/Application Support/GlitchAI/secrets.json, readable only by your account (0600, folder 0700).
/// Used instead of the Keychain because a self-signed app is re-asked for Keychain access on every rebuild.
enum Secrets {
    private static let accounts = ["openrouter", "ollamacloud", "voidbox-token"]
    private static let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("GlitchAI", isDirectory: true)
    private static let file = dir.appendingPathComponent("secrets.json")
    private static var cache: [String: String] = load()

    static func get(_ account: String) -> String? {
        cache[account].flatMap { $0.isEmpty ? nil : $0 }
    }

    static func set(_ value: String, for account: String) {
        cache[account] = value.isEmpty ? nil : value
        write(cache)
    }

    private static func load() -> [String: String] {
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            return saved
        }
        // First run with the file: move anything still in the Keychain over (one last round of prompts).
        var moved: [String: String] = [:]
        for account in accounts {
            if let value = LegacyKeychain.take(account) { moved[account] = value }
        }
        write(moved)
        return moved
    }

    private static func write(_ secrets: [String: String]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        guard let data = try? JSONEncoder().encode(secrets) else { return }
        // Create with owner-only permissions before any secret is written.
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? data.write(to: file)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

/// Reads and removes secrets saved in the Keychain by older versions of Glitch.
private enum LegacyKeychain {
    static func take(_ account: String) -> String? {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "com.glitch.ai",
                                   kSecAttrAccount as String: account]
        var query = base
        query[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let value = String(data: data, encoding: .utf8) else { return nil }
        SecItemDelete(base as CFDictionary)
        return value
    }
}
