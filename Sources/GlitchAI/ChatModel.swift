import AppKit
import Foundation

@MainActor
final class ChatModel: ObservableObject {
    static let shared = ChatModel()

    @Published var messages: [ChatMessage] = []
    @Published private(set) var conversationID = UUID()
    @Published var isThinking = false
    /// The assistant message currently being streamed in, if any.
    @Published private(set) var streamingID: UUID?
    @Published var greeting = Persona.greetings.randomElement()!

    /// Sends a message (optionally with an image) and returns Glitch's reply.
    /// Voice and the chat panel share this one conversation.
    @discardableResult
    func ask(_ text: String, attachments: [Attachment] = []) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return "" }
        // Naming an open app ("what's new in Discord?") attaches a look at that app's window.
        var attachments = attachments
        var windowNote: String?
        if attachments.isEmpty, let app = Self.mentionedApp(in: trimmed) {
            if let shot = await ImageCapture.window(ofApp: app) {
                attachments = [.image(shot, name: "\(app) window")]
            } else {
                windowNote = "You tried to look at \(app)'s window but couldn't capture it (it may be minimized, "
                    + "or Glitch lacks Screen Recording permission). Say so plainly in your own voice."
            }
        }
        messages.append(ChatMessage(role: .user, content: trimmed, attachments: attachments))
        isThinking = true
        defer { isThinking = false }

        // Only the newest attachments are resent; older ones would cost tokens on every turn.
        let lastImageID = messages.last(where: { !$0.attachments.isEmpty })?.id
        let recent = messages.suffix(20).map { m in
            m.id == lastImageID ? m : ChatMessage(id: m.id, role: m.role, content: m.content)
        }
        // Plain commands ("open Discord") run before the model, so they work even if it forgets its tags.
        let direct = Actions.performDirect(trimmed)
        let actionNote = direct.map {
            "For the user's latest message, the app ALREADY did this: \($0) Comment on it in character. Do not write action tags."
        } ?? "No action has been performed for the latest message."
        let system = [Persona.systemPrompt, MemoryStore.shared.promptSection,
                      LiveContext.snapshot(for: trimmed), actionNote, windowNote].compactMap { $0 }
                      .joined(separator: "\n\n")
        // The character reminder goes right before the newest message, where the model reads last.
        var conversation = Array(recent)
        if let last = conversation.indices.last {
            conversation.insert(ChatMessage(role: .system, content: Persona.reminder), at: last)
        }
        let history = [ChatMessage(role: .system, content: system)] + conversation

        let reply: String
        do {
            // Stream into a placeholder message so the reply appears as it's written.
            let streamID = UUID()
            let raw = try await AppSettings.shared.client.complete(history) { [weak self] partial in
                guard let self, !Task.isCancelled else { return }
                let shown = LLMClient.displayable(partial)
                guard !shown.isEmpty else { return }
                if let i = self.messages.firstIndex(where: { $0.id == streamID }) {
                    self.messages[i].content = shown
                } else {
                    self.messages.append(ChatMessage(id: streamID, role: .assistant, content: shown))
                    self.streamingID = streamID
                }
            }
            messages.removeAll { $0.id == streamID }   // replaced by the finished reply below
            streamingID = nil
            if Task.isCancelled { return "" }   // stopped while the answer was arriving
            // Small models write couplets as "LINE ONE / LINE TWO"; split them onto lines.
            let (withoutActions, reports) = Actions.absorbTags(in: raw)
            // Surface failures, so Glitch never seems to have done something it couldn't.
            let failures = reports.filter { !$0.hasPrefix("Opened") && !$0.hasPrefix("Quit ")
                && !$0.hasPrefix("Set volume") && !$0.contains(": ") }
            let (afterDrafts, drafts) = Self.absorbDrafts(in: withoutActions)
            let (afterShortcuts, shortcutReports) = await Self.absorbShortcuts(in: afterDrafts)
            reply = (MemoryStore.shared.absorbTags(in: afterShortcuts)
                .replacingOccurrences(of: " / ", with: "\n")
                + failures.map { "\n\($0)" }.joined()
                + shortcutReports.filter { !$0.hasPrefix("Ran ") }.map { "\n\($0)" }.joined()
                + drafts.map { "\n\n\($0)" }.joined())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch is CancellationError {
            finishStopped()
            return ""   // stopped: keep the question and whatever had streamed in
        } catch let error as URLError where error.code == .cancelled {
            finishStopped()
            return ""
        } catch {
            reply = (direct.map { "\($0)\n" } ?? "") + "S-SIGNAL LOST. \(error.localizedDescription)"
        }
        let final = Self.withClosingLine(reply)
        messages.append(ChatMessage(role: .assistant, content: final))
        ConversationStore.shared.save(id: conversationID, messages: messages)
        AccountStore.shared.scheduleSync()

        let settings = AppSettings.shared
        if settings.provider == .ollama, settings.ollamaKeepAlive != "5m" {   // 5m is Ollama's default
            let model = settings.ollamaModel, keepAlive = settings.ollamaKeepAlive
            Task { await OllamaModels.setKeepAlive(model: model, keepAlive) }
        }
        return final
    }

    /// Errors always get a glitchy failure line; normal replies get a DOORS closing line about a quarter
    /// of the time, never the same one twice in a row.
    private static var lastClosing: String?
    private static func withClosingLine(_ reply: String) -> String {
        let failed = reply.contains("S-SIGNAL LOST") || reply.contains("Could not") || reply.contains("No music app")
        guard failed || Double.random(in: 0..<1) < 0.25 else { return reply }
        let pool = (failed ? Persona.failureLines : Persona.closingLines).filter { $0 != lastClosing }
        // The "repressed" lines come up more often than the rest: about a third of closing lines.
        let repressed = pool.filter { $0.contains("REPRESSED") }
        let useRepressed = !failed && !repressed.isEmpty && Double.random(in: 0..<1) < 0.35
        guard let line = (useRepressed ? repressed : pool).randomElement() else { return reply }
        lastClosing = line
        return reply + "\n\n" + line
    }

    private var replyTask: Task<Void, Never>?

    /// After Stop: keep the partial reply (if any) as a finished message.
    private func finishStopped() {
        if let id = streamingID, let i = messages.firstIndex(where: { $0.id == id }) {
            messages[i].content += " ▓▒░"
            ConversationStore.shared.save(id: conversationID, messages: messages)
        }
        streamingID = nil
    }

    /// The open app whose name appears in the message as a whole word (longest name wins), e.g. "Discord".
    private static func mentionedApp(in text: String) -> String? {
        let names = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap(\.localizedName)
            .filter { $0.count >= 3 }
            .sorted { $0.count > $1.count }
        return names.first { name in
            text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: name))\\b",
                       options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// [DRAFT]…[/DRAFT]: copies the draft to the clipboard and keeps it visible in the reply.
    private static func absorbDrafts(in text: String) -> (String, [String]) {
        guard let regex = try? NSRegularExpression(pattern: #"\[DRAFT\]\s*(.*?)\s*\[/DRAFT\]"#,
                                                   options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return (text, []) }
        let range = NSRange(text.startIndex..., in: text)
        let drafts = regex.matches(in: text, range: range).compactMap { m in
            Range(m.range(at: 1), in: text).map { String(text[$0]) }
        }.filter { !$0.isEmpty }
        guard let last = drafts.last else { return (text, []) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(last, forType: .string)
        MemoryToast.shared.show([.init(kind: .copied, text: String(last.prefix(140)))])
        let stripped = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return (stripped, drafts.map { "> " + $0.replacingOccurrences(of: "\n", with: "\n> ") })
    }

    /// [SHORTCUT: name]: runs the user's Shortcut and returns reports for the chat.
    private static func absorbShortcuts(in text: String) async -> (String, [String]) {
        guard let regex = try? NSRegularExpression(pattern: #"\[SHORTCUT:\s*([^\]]+)\]"#, options: .caseInsensitive)
        else { return (text, []) }
        let range = NSRange(text.startIndex..., in: text)
        let names = regex.matches(in: text, range: range).compactMap { m in
            Range(m.range(at: 1), in: text).map { String(text[$0]) }
        }
        var reports: [String] = []
        for name in names {
            let report = await ShortcutsRunner.runShortcut(named: name)
            reports.append(report)
            MemoryToast.shared.show([.init(kind: report.hasPrefix("Ran ") ? .ran : .failed, text: report)])
        }
        return (regex.stringByReplacingMatches(in: text, range: range, withTemplate: ""), reports)
    }

    func send(_ text: String, attachments: [Attachment] = []) {
        guard !isThinking else { return }
        replyTask = Task { await ask(text, attachments: attachments) }
    }

    /// Cancels the reply being generated. The question stays; no answer is added.
    func stop() {
        replyTask?.cancel()
        replyTask = nil
        isThinking = false
    }

    /// Takes a message of yours back for editing: removes it and everything after it,
    /// and returns its text and image to put back in the input.
    func edit(_ message: ChatMessage) -> (String, [Attachment])? {
        guard message.role == .user, let index = messages.firstIndex(where: { $0.id == message.id }) else { return nil }
        stop()
        messages.removeSubrange(index...)
        if messages.isEmpty {
            ConversationStore.shared.deleteIfExists(conversationID)
        } else {
            ConversationStore.shared.save(id: conversationID, messages: messages)
        }
        AccountStore.shared.scheduleSync()
        return (message.content, message.attachments)
    }

    func open(_ convo: Conversation) {
        conversationID = convo.id
        messages = convo.messages
    }

    func reset() {
        conversationID = UUID()
        messages.removeAll()
        greeting = Persona.greetings.randomElement()!
    }
}
