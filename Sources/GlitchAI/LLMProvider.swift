import Foundation

struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case system, user, assistant }
    var id = UUID()
    let role: Role
    var content: String
    /// Images and videos sent with this message. Not saved to disk (chats are stored as text).
    var attachments: [Attachment] = []

    private enum CodingKeys: String, CodingKey { case id, role, content }
}

enum ProviderKind: String, CaseIterable, Identifiable, Codable {
    case openRouter = "OpenRouter"
    case ollama = "Local (Ollama)"
    case ollamaCloud = "Ollama Cloud"
    var id: String { rawValue }
}

enum LLMError: LocalizedError {
    case missingKey(ProviderKind), badResponse(Int, String), empty

    var errorDescription: String? {
        switch self {
        case .missingKey(let kind): return "No \(kind.rawValue) API key. Add one in Settings."
        case .badResponse(let code, let body): return "HTTP \(code): \(body.prefix(300))"
        case .empty: return "The model returned nothing."
        }
    }
}

/// OpenRouter and Ollama both speak the OpenAI chat-completions format,
/// so one client covers both; only the base URL and auth differ.
struct LLMClient {
    let kind: ProviderKind
    let model: String
    let apiKey: String?

    private var endpoint: URL {
        switch kind {
        case .openRouter: return URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        case .ollama: return URL(string: "http://localhost:11434/v1/chat/completions")!
        case .ollamaCloud: return URL(string: "https://ollama.com/v1/chat/completions")!
        }
    }

    /// Sends the conversation and returns the full reply. With `onPartial`, the reply is streamed and
    /// `onPartial` gets the text so far (raw, tags included) as it arrives.
    func complete(_ messages: [ChatMessage],
                  onPartial: (@MainActor (String) -> Void)? = nil) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if kind != .ollama {
            guard let apiKey, !apiKey.isEmpty else { throw LLMError.missingKey(kind) }
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("Glitch AI", forHTTPHeaderField: "X-Title")
        }

        let hasVideo = messages.contains { $0.attachments.contains { $0.video != nil } }
        do {
            return try await send(messages, videoAsFile: kind == .openRouter && hasVideo, request: request,
                                  onPartial: onPartial)
        } catch LLMError.badResponse(let code, _) where hasVideo && kind == .openRouter
                    && (400..<500).contains(code) && code != 401 {
            // The model or provider refused the video file: send its still frames instead.
            Log.write("video: file refused (\(code)), retrying with frames")
            return try await send(messages, videoAsFile: false, request: request, onPartial: onPartial)
        }
    }

    private func send(_ messages: [ChatMessage], videoAsFile: Bool, request base: URLRequest,
                      onPartial: (@MainActor (String) -> Void)?) async throws -> String {
        var request = base
        if messages.contains(where: { $0.attachments.contains { $0.video != nil } }) {
            Log.write("video: sending as \(videoAsFile ? "file" : "frames")")
        }
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { Self.encode($0, videoAsFile: videoAsFile) },
        ]
        // Thinking models (qwen3.5…) can reason for minutes on a 4B model; Glitch needs quick lines.
        if kind == .ollama { body["reasoning_effort"] = "none" }
        if onPartial != nil { body["stream"] = true }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        guard let onPartial else {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                throw LLMError.badResponse(status, String(data: data, encoding: .utf8) ?? "")
            }
            struct Reply: Decodable {
                struct Choice: Decodable { struct Msg: Decodable { let content: String? }; let message: Msg }
                let choices: [Choice]
            }
            let reply = try JSONDecoder().decode(Reply.self, from: data)
            guard let text = reply.choices.first?.message.content, !text.isEmpty else { throw LLMError.empty }
            return Self.stripThinking(text)
        }

        // Streaming: server-sent events, one "data: {json}" line per chunk, ending with "data: [DONE]".
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var errorBody = ""
            for try await line in bytes.lines { errorBody += line; if errorBody.count > 2000 { break } }
            throw LLMError.badResponse(status, errorBody)
        }
        struct Chunk: Decodable {
            struct Choice: Decodable { struct Delta: Decodable { let content: String? }; let delta: Delta? }
            let choices: [Choice]?
        }
        var text = ""
        var chunks = 0
        defer { Log.write("stream: \(chunks) chunks, \(text.count) chars") }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(payload.utf8)),
                  let piece = chunk.choices?.first?.delta?.content, !piece.isEmpty else { continue }
            text += piece
            chunks += 1
            await onPartial(text)
        }
        guard !text.isEmpty else { throw LLMError.empty }
        return Self.stripThinking(text)
    }

    /// Text that's safe to show mid-stream: no thinking blocks, no finished or half-written tags.
    static func displayable(_ partial: String) -> String {
        var t = partial.replacingOccurrences(of: "(?s)<think>.*?(</think>|$)", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[(REMEMBER|FORGET|OPEN|QUIT|VOLUME|MEDIA|URL|SHORTCUT):[^\]]*(\]|$)"#, with: "",
                                   options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"\[/?DRAFT\]"#, with: "", options: [.regularExpression, .caseInsensitive])
        if let open = t.lastIndex(of: "["), !t[open...].contains("]") { t = String(t[..<open]) }   // "[REMEM…"
        return t.replacingOccurrences(of: " / ", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Text, then each attachment: images as image_url; videos as video_url when `videoAsFile`
    /// (OpenRouter), otherwise as their still frames.
    private static func encode(_ m: ChatMessage, videoAsFile: Bool) -> [String: Any] {
        guard !m.attachments.isEmpty else { return ["role": m.role.rawValue, "content": m.content] }
        let text = [m.content.isEmpty ? "What do you see?" : m.content, m.attachments.note(videoAsFile: videoAsFile)]
            .compactMap { $0 }.joined(separator: "\n\n")
        var parts: [[String: Any]] = [["type": "text", "text": text]]
        for a in m.attachments {
            if videoAsFile, let video = a.video {
                parts.append(["type": "video_url",
                              "video_url": ["url": "data:\(video.mime);base64,\(video.data.base64EncodedString())"]])
            } else {
                for frame in a.frames {
                    parts.append(["type": "image_url",
                                  "image_url": ["url": "data:image/jpeg;base64,\(frame.base64EncodedString())"]])
                }
            }
        }
        return ["role": m.role.rawValue, "content": parts]
    }

    /// Qwen3 and similar local models emit <think>…</think> blocks; hide them.
    static func stripThinking(_ text: String) -> String {
        text.replacingOccurrences(of: "(?s)<think>.*?</think>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
