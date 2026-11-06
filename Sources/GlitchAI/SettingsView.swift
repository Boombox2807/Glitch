import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var memory = MemoryStore.shared
    @State private var installed: [String] = []
    @State private var ollamaOffline = false
    @State private var newMemory = ""
    @State private var importing = false
    @ObservedObject private var puller = OllamaPuller.shared
    @State private var cloudModels: [String] = []

    @AppStorage("settings.memoryOpen") private var memoryOpen = false
    @AppStorage("settings.voiceOpen") private var voiceOpen = false
    @AppStorage("settings.accountOpen") private var accountOpen = false

    var body: some View {
        Form {
            Section {
                DisclosureGroup(isExpanded: $accountOpen) {
                    AccountSection()
                } label: {
                    Label("Sync server (optional)", systemImage: "arrow.triangle.2.circlepath")
                }
            }

            // Only the chosen brain's options are shown.
            Section {
                Picker("Brain", selection: $settings.provider) {
                    ForEach(ProviderKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                switch settings.provider {
                case .openRouter: openRouterFields
                case .ollamaCloud: cloudFields
                case .ollama: localFields
                }
            } header: {
                Text("Brain")
            }

            Section {
                Toggle(isOn: $settings.showInDock) {
                    Label("Show in Dock", systemImage: "dock.rectangle")
                }
                .help("Also show Glitch in the Dock and ⌘Tab. Clicking the Dock icon opens its window.")
            }

            Section {
                DisclosureGroup(isExpanded: $voiceOpen) {
                    Toggle("Edit dictation before sending", isOn: $settings.reviewDictation)
                    Toggle("Use the Mac's microphone", isOn: $settings.useBuiltInMic)
                        .help("Keeps Bluetooth headphones in normal audio quality instead of switching to call mode while Glitch listens.")
                    LabeledContent("Talk", value: "hold ⌥Space")
                    LabeledContent("Type", value: "⌥⇧Space")
                } label: {
                    Label("Voice & shortcuts", systemImage: "waveform")
                }
            }

            Section {
                DisclosureGroup(isExpanded: $memoryOpen) {
                    memoryFields
                } label: {
                    Label("Memory (\(memory.items.count))", systemImage: "brain")
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 300)
        .onAppear {
            // Keep the sign-in in view until there's an account.
            if !AccountStore.shared.signedIn && AccountStore.shared.baseURL != nil { accountOpen = true }
        }
        .task {
            puller.onFinished = { Task { await refresh() } }
            cloudModels = await OllamaModels.cloud() ?? []
            await refresh()
        }
        .sheet(isPresented: $importing) { MemoryImportView() }
    }

    @ViewBuilder private var openRouterFields: some View {
        SecureField("API key", text: $settings.apiKey)
        TextField("Model", text: $settings.openRouterModel)
        Text("Any model id from openrouter.ai/models, e.g. z-ai/glm-5.3-flash:floor")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var cloudFields: some View {
        SecureField("API key", text: $settings.cloudKey)
        Picker("Model", selection: $settings.cloudModel) {
            ForEach(cloudModels.contains(settings.cloudModel) ? cloudModels : [settings.cloudModel] + cloudModels,
                    id: \.self) { Text($0).tag($0) }
        }
        Text("Get a key at ollama.com/settings/keys. gemma4:31b can see images.")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var localFields: some View {
        HStack {
            Picker("Model", selection: $settings.ollamaModel) {
                // Keep the saved choice selectable even if it isn't installed.
                ForEach(installed.contains(settings.ollamaModel) ? installed : [settings.ollamaModel] + installed,
                        id: \.self) { name in
                    Text(installed.contains(name) ? name : "\(name) (not installed)").tag(name)
                }
            }
            Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Reload installed models")
        }
        Picker("Keep in memory", selection: $settings.ollamaKeepAlive) {
            Text("Unload right away").tag("0")
            Text("1 minute").tag("1m")
            Text("5 minutes").tag("5m")
            Text("30 minutes").tag("30m")
            Text("Always").tag("-1")
        }
        .help("How long the model stays in RAM after Glitch answers. Shorter frees memory; the next answer then takes a few seconds to load.")
        if puller.isPulling {
            VStack(alignment: .leading, spacing: 4) {
                if let fraction = puller.fraction {
                    ProgressView(value: fraction).tint(GlitchTheme.violet)
                } else {
                    ProgressView().progressViewStyle(.linear).tint(GlitchTheme.violet)
                }
                Text("\(puller.model ?? "") — \(puller.status)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        } else if !ollamaOffline, !installed.contains(settings.ollamaModel) {
            Button("Download \(settings.ollamaModel)") { puller.pull(settings.ollamaModel) }
        }
        if let error = puller.error {
            Text("Download failed: \(error)").font(.caption).foregroundStyle(.red)
        }
        Text(ollamaOffline
             ? "Ollama isn't running. Open the Ollama app, then reload."
             : "Runs on this Mac and uses its RAM. Get more with: ollama pull <name>.")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var memoryFields: some View {
        HStack {
            TextField("Add something it should know about you", text: $newMemory)
                .onSubmit(addMemory)
            Button("Add", action: addMemory)
                .disabled(newMemory.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if memory.items.isEmpty {
            Text("Nothing yet. Add something above, or tell it about yourself.")
                .foregroundStyle(.secondary)
        }
        ForEach(memory.items) { item in
            HStack {
                Text(item.text).textSelection(.enabled)
                Spacer()
                Button { memory.delete(item) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
        }
        HStack {
            Button("Import from another AI…") { importing = true }
            Spacer()
            if !memory.items.isEmpty {
                Button("Forget everything", role: .destructive) { memory.deleteAll() }
            }
        }
    }

    private func addMemory() {
        memory.add(newMemory)
        newMemory = ""
    }

    private func refresh() async {
        if let names = await OllamaModels.installed() {
            installed = names
            ollamaOffline = false
        } else {
            ollamaOffline = true
        }
    }
}

enum OllamaModels {
    /// Sets how long the model stays loaded; "0" unloads it now.
    /// A request with no prompt only loads/unloads, it doesn't generate anything.
    static func setKeepAlive(model: String, _ keepAlive: String) async {
        guard let url = URL(string: "http://localhost:11434/api/generate") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let value: Any = Int(keepAlive) ?? keepAlive
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "keep_alive": value])
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Models offered by Ollama Cloud (this list is public; using them needs a key).
    static func cloud() async -> [String]? {
        struct List: Decodable { struct Model: Decodable { let id: String }; let data: [Model] }
        guard let url = URL(string: "https://ollama.com/v1/models"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let list = try? JSONDecoder().decode(List.self, from: data) else { return nil }
        return list.data.map(\.id).sorted()
    }

    /// Names of models the local Ollama server has, or nil if it isn't reachable.
    static func installed() async -> [String]? {
        struct Tags: Decodable { struct Model: Decodable { let name: String }; let models: [Model] }
        guard let url = URL(string: "http://localhost:11434/api/tags"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let tags = try? JSONDecoder().decode(Tags.self, from: data) else { return nil }
        return tags.models.map(\.name).sorted()
    }
}

/// Downloads an Ollama model and reports progress. A singleton so the download
/// keeps going (and its progress stays visible) when the panel closes.
@MainActor
final class OllamaPuller: ObservableObject {
    static let shared = OllamaPuller()
    @Published private(set) var model: String?
    @Published private(set) var status = ""
    @Published private(set) var fraction: Double?
    @Published private(set) var error: String?
    var onFinished: (() -> Void)?

    var isPulling: Bool { model != nil }

    func pull(_ name: String) {
        guard !isPulling, let url = URL(string: "http://localhost:11434/api/pull") else { return }
        model = name
        status = "starting"
        fraction = nil
        error = nil
        Task {
            defer { model = nil; onFinished?() }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 3600
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": name, "stream": true])
            struct Line: Decodable { let status: String?; let total: Int64?; let completed: Int64?; let error: String? }
            do {
                let (bytes, _) = try await URLSession.shared.bytes(for: request)
                for try await raw in bytes.lines {
                    guard let line = try? JSONDecoder().decode(Line.self, from: Data(raw.utf8)) else { continue }
                    if let e = line.error { error = e; return }
                    if let s = line.status { status = s }
                    if let total = line.total, total > 0, let done = line.completed {
                        fraction = Double(done) / Double(total)
                        status = "\(line.status ?? "downloading") · "
                            + ByteCountFormatter.string(fromByteCount: done, countStyle: .file) + " / "
                            + ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
                    }
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
