import SwiftUI

enum GlitchTheme {
    static let violet = Color(red: 0.62, green: 0.25, blue: 1.0)
    static let cyan = Color(red: 0.2, green: 0.95, blue: 0.95)
    static let red = Color(red: 1.0, green: 0.2, blue: 0.3)
    static let mono = Font.system(size: 13, weight: .medium, design: .monospaced)
    static let reading = Font.system(size: 13.5, weight: .regular, design: .monospaced)
    static let panel = Color.white.opacity(0.045)
    static let hairline = Color.white.opacity(0.08)
}

/// Faint CRT scanlines over the background.
struct Scanlines: View {
    var body: some View {
        Canvas { ctx, size in
            var y: CGFloat = 0
            while y < size.height {
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.white.opacity(0.025)))
                y += 3
            }
        }
        .allowsHitTesting(false)
    }
}

/// Header and toolbar icon button: small, dim, brightens on hover.
struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .foregroundStyle(hover ? Color.white : Color.white.opacity(0.5))
                .background(Circle().fill(Color.white.opacity(hover ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// White monospace text with a red/cyan chromatic-aberration split that jitters now and then.
/// *word* renders italic and **word** bold.
struct GlitchText: View {
    let text: String
    var font: Font = GlitchTheme.mono
    /// How far the red/cyan copies sit apart (1 = full effect, lower = calmer for long text).
    var split: CGFloat = 1

    private var styled: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.12)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let spike = sin(t * 7.3) > 0.93
            let dx = (spike ? 2.5 : 1.0) * split
            ZStack {
                Text(styled).foregroundStyle(GlitchTheme.red.opacity(0.4 + 0.4 * split)).offset(x: -dx)
                Text(styled).foregroundStyle(GlitchTheme.cyan.opacity(0.4 + 0.4 * split)).offset(x: dx)
                Text(styled).foregroundStyle(.white.opacity(0.94))
            }
            .font(font)
            .offset(x: spike ? CGFloat.random(in: -2...2) * split : 0)
        }
    }
}

struct ChatView: View {
    var inWindow = false
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject var chat: ChatModel
    @EnvironmentObject var settings: AppSettings
    @State private var input = ""
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var pending: [Attachment] = []
    @State private var hovered: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            LinearGradient(colors: [.clear, GlitchTheme.violet.opacity(0.55), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 1)
            if showSettings {
                SettingsView().environmentObject(settings)
            } else if showHistory {
                HistoryView(onOpen: { showHistory = false }).environmentObject(chat)
            } else {
                transcript
                inputBar
            }
        }
        .background(
            ZStack {
                Color(red: 0.03, green: 0.01, blue: 0.04)
                RadialGradient(colors: [Color(red: 0.2, green: 0.04, blue: 0.16).opacity(0.7), .clear],
                               center: .top, startRadius: 10, endRadius: 520)
                RadialGradient(colors: [Color(red: 0.18, green: 0.02, blue: 0.04).opacity(0.6), .clear],
                               center: .bottomLeading, startRadius: 10, endRadius: 420)
                Scanlines()
            }
        )
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: MenuBarIcon.figure)
                .resizable().scaledToFit().frame(height: 26)
            VStack(alignment: .leading, spacing: 1) {
                GlitchText(text: "GLITCH", font: .system(size: 14, weight: .bold, design: .monospaced), split: 0.8)
                    .tracking(3)
                Text(chat.isThinking ? "watching…" : "listening")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(chat.isThinking ? GlitchTheme.violet : .white.opacity(0.35))
            }
            Spacer()
            HStack(spacing: 2) {
                if !inWindow {
                    IconButton(symbol: "macwindow", help: "Open in a window") {
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
                IconButton(symbol: showHistory ? "xmark" : "clock.arrow.circlepath", help: "Saved conversations") {
                    showHistory.toggle(); showSettings = false
                }
                IconButton(symbol: "square.and.pencil", help: "New conversation") {
                    chat.reset(); showHistory = false; showSettings = false
                }
                IconButton(symbol: showSettings ? "xmark" : "gearshape", help: "Settings") {
                    showSettings.toggle(); showHistory = false
                }
                IconButton(symbol: "power", help: "Quit Glitch") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if chat.messages.isEmpty {
                        VStack(spacing: 18) {
                            Image(nsImage: MenuBarIcon.figure)
                                .resizable().scaledToFit().frame(height: 90)
                                .opacity(0.85)
                            GlitchText(text: chat.greeting,
                                       font: .system(size: 15, weight: .semibold, design: .monospaced))
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 70)
                    }
                    ForEach(chat.messages) { message in
                        bubble(message).id(message.id)
                    }
                    if chat.isThinking && chat.streamingID == nil {
                        HStack(alignment: .top, spacing: 10) {
                            avatar
                            GlitchText(text: "▓▒░ …", font: GlitchTheme.reading, split: 0.6)
                        }
                        .id("thinking")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .onChange(of: chat.messages.count) {
                withAnimation { proxy.scrollTo(chat.messages.last?.id, anchor: .bottom) }
            }
            .onChange(of: chat.messages.last?.content) {
                // Follow the reply as it streams in.
                if chat.streamingID != nil { proxy.scrollTo(chat.messages.last?.id, anchor: .bottom) }
            }
        }
    }

    private var avatar: some View {
        Image(nsImage: MenuBarIcon.figure)
            .resizable().scaledToFit()
            .frame(width: 18, height: 22)
            .padding(.top, 1)
    }

    @ViewBuilder
    private func bubble(_ message: ChatMessage) -> some View {
        if message.role == .user {
            VStack(alignment: .trailing, spacing: 6) {
                if !message.attachments.isEmpty {
                    AttachmentStrip(attachments: message.attachments, size: message.attachments.count == 1 ? 140 : 72)
                }
                if !message.content.isEmpty {
                    Text(message.content)
                        .font(GlitchTheme.reading)
                        .foregroundStyle(GlitchTheme.cyan)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 12).fill(GlitchTheme.cyan.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(GlitchTheme.cyan.opacity(0.18)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 60)
            .overlay(alignment: .topLeading) {
                if hovered == message.id {
                    HStack(spacing: 0) {
                        IconButton(symbol: "pencil", help: "Edit and resend") { startEditing(message) }
                        IconButton(symbol: "doc.on.doc", help: "Copy") { copy(message.content) }
                    }
                    .padding(.leading, 6)
                }
            }
            .onHover { hovered = $0 ? message.id : (hovered == message.id ? nil : hovered) }
            .contextMenu {
                Button("Edit and resend", systemImage: "pencil") { startEditing(message) }
                Button("Copy", systemImage: "doc.on.doc") { copy(message.content) }
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                avatar
                GlitchText(text: message.content, font: GlitchTheme.reading, split: 0.45)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.trailing, 24)
            .contextMenu {
                Button("Copy", systemImage: "doc.on.doc") { copy(message.content) }
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                Button("Show it your screen", systemImage: "camera.viewfinder") {
                    Task {
                        if let shot = await ImageCapture.screenshot() { pending.add([.image(shot, name: "screenshot")]) }
                    }
                }
                Button("Choose images or videos…", systemImage: "photo.on.rectangle", action: pickFiles)
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Attach images or videos (or paste with ⌘V, or drop them here)")

            VStack(alignment: .leading, spacing: 8) {
                if !pending.isEmpty {
                    AttachmentStrip(attachments: pending) { removed in pending.removeAll { $0.id == removed.id } }
                        .padding(.top, 6)
                }
                TextField("", text: $input, axis: .vertical)
                    .lineLimit(1...8)
                    .textFieldStyle(.plain)
                    .font(GlitchTheme.reading)
                    .shiftReturnNewline()
                    .onSubmit(submit)
                    .overlay(alignment: .leading) {
                        if input.isEmpty {
                            Text("speak, vessel…")
                                .font(GlitchTheme.reading)
                                .foregroundStyle(.white.opacity(0.32))
                                .allowsHitTesting(false)
                        }
                    }
            }
            .padding(.vertical, 5)

            if chat.isThinking {
                Button { chat.stop() } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(GlitchTheme.red.opacity(0.85)))
                }
                .buttonStyle(.plain)
                .help("Stop")
            } else {
                Button(action: submit) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(canSend ? GlitchTheme.violet : Color.white.opacity(0.1)))
                        .shadow(color: canSend ? GlitchTheme.violet.opacity(0.6) : .clear, radius: 8)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("Send (Enter). Shift+Enter for a new line.")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 16).fill(GlitchTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(GlitchTheme.violet.opacity(0.28)))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, 4)
        .background(PasteTarget { pending.add($0) })
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        if let a = await Attachment.load(url) { pending.add([a]) }
                    }
                }
            }
            return true
        }
    }

    private func startEditing(_ message: ChatMessage) {
        guard let (text, attachments) = chat.edit(message) else { return }
        input = text
        pending = attachments
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var canSend: Bool {
        !chat.isThinking && (!input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pending.isEmpty)
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            for url in urls { if let a = await Attachment.load(url) { pending.add([a]) } }
        }
    }

    private func submit() {
        guard !chat.isThinking else { return }
        chat.send(input, attachments: pending)
        input = ""
        pending = []
    }
}

extension ChatView {
    /// Test hook: renders the chat panel with sample messages to a PNG (GLITCH_UI_SNAPSHOT=<path>).
    @MainActor static func renderSnapshot(to path: String) {
        let chat = ChatModel.shared
        chat.messages = [
            ChatMessage(role: .user, content: "Hi! How are you?"),
            ChatMessage(role: .assistant, content: "How am I? I do not wear out. I only *repeat*, improved.\n\nCurious vessel. Something on your Dock has been blinking, waiting to be answered."),
            ChatMessage(role: .user, content: "what am I listening to?"),
            ChatMessage(role: .assistant, content: "CRUSH TEKK. Slowed.\nYou've been playing it a lot.\n\nDID YOU ENJOY IT?"),
        ]
        let host = NSHostingView(rootView: ChatView()
            .environmentObject(chat)
            .environmentObject(AppSettings.shared)
            .frame(width: 440, height: 560))
        host.frame = NSRect(x: 0, y: 0, width: 440, height: 560)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

extension View {
    /// Shift+Return inserts a line break at the cursor instead of sending.
    func shiftReturnNewline() -> some View {
        onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.shift) else { return .ignored }
            NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
            return .handled
        }
    }
}
