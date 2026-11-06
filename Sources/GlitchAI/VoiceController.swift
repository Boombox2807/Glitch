import AppKit
import Carbon
import CoreGraphics
import Foundation

/// Hold ⌥Space and speak, or press ⌥⇧Space and type: Glitch answers as floating text on screen.
@MainActor
final class VoiceController {
    static let shared = VoiceController()
    private let voice = VoiceInput()
    private var transcriptWatcher: Task<Void, Never>?

    /// Phrases that mean "look at my screen" and attach a screenshot.
    private let lookPattern = #"\b(screen|look|see|seeing|read|this|that|what's here|in front of me)\b"#

    func start() {
        voice.requestPermissions()
        voice.onLevel = { Overlay.shared.pushLevel($0) }
        HotKey.register(keyCode: kVK_Space, modifiers: optionKey,
                        onPress: { [weak self] in Task { @MainActor in self?.beginListening() } },
                        onRelease: { [weak self] in Task { @MainActor in await self?.finishListening() } })
        HotKey.register(keyCode: kVK_Space, modifiers: optionKey | shiftKey,
                        onPress: { Task { @MainActor in TypeBar.shared.toggle() } })
        TypeBar.shared.onSubmit = { [weak self] text, attachments in
            Task { @MainActor in await self?.respond(to: text, attachments: attachments) }
        }
        ImagePaste.install()
        // Test hooks: GLITCH_ASK sends a message as if typed; GLITCH_DEMO only shows text.
        if let ask = ProcessInfo.processInfo.environment["GLITCH_ASK"] {
            // GLITCH_ATTACH: colon-separated file paths to attach to the test message.
            let paths = ProcessInfo.processInfo.environment["GLITCH_ATTACH"]?.split(separator: ":").map(String.init) ?? []
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                Task {
                    var attachments: [Attachment] = []
                    for path in paths { if let a = await Attachment.load(URL(fileURLWithPath: path)) { attachments.append(a) } }
                    await self.respond(to: ask, attachments: attachments)
                }
            }
        }
        if let path = ProcessInfo.processInfo.environment["GLITCH_RECORD"] {
            let reply = ProcessInfo.processInfo.environment["GLITCH_DEMO"] ?? "I see you."
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { OverlayRecorder.record(reply: reply, to: path) }
        }
        if let path = ProcessInfo.processInfo.environment["GLITCH_TOAST_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MemoryToast.renderSnapshot(to: path)
                NSApp.terminate(nil)
            }
        }
        if let path = ProcessInfo.processInfo.environment["GLITCH_UI_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                ChatView.renderSnapshot(to: path)
                NSApp.terminate(nil)
            }
        }
        if let path = ProcessInfo.processInfo.environment["GLITCH_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                Overlay.renderSnapshot(to: path)
                NSApp.terminate(nil)
            }
        }
        if let demo = ProcessInfo.processInfo.environment["GLITCH_DEMO"],
           ProcessInfo.processInfo.environment["GLITCH_RECORD"] == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Overlay.shared.show(reply: demo) }
        }
    }

    private func beginListening() {
        // Holding the key auto-repeats "pressed"; only the first press starts listening.
        guard transcriptWatcher == nil else { return }
        TypeBar.shared.close()
        Overlay.shared.startListening()
        voice.start()
        Log.write("press: listening")
        transcriptWatcher = Task {
            var sawHeld = false   // if macOS hides key state, never trust the backup check
            while !Task.isCancelled {
                if !voice.transcript.isEmpty { Overlay.shared.showStatus(voice.transcript) }
                // Backup for a missed key-release event: stop once ⌥ or Space is no longer held.
                let held = Self.talkKeysHeld()
                sawHeld = sawHeld || held
                if sawHeld && !held {
                    Log.write("keys no longer held: stopping")
                    await finishListening()
                    return
                }
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    private func finishListening() async {
        guard transcriptWatcher != nil else { return }   // already stopped
        Log.write("release: stopping")
        transcriptWatcher?.cancel()
        transcriptWatcher = nil
        Overlay.shared.stopListening()
        let text = await voice.stop()
        guard !text.isEmpty else { Overlay.shared.hide(); return }
        if AppSettings.shared.reviewDictation {
            Overlay.shared.hide()
            TypeBar.shared.open(prefill: text)
        } else {
            await respond(to: text)
        }
    }

    private static func talkKeysHeld() -> Bool {
        CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Space))
            && CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate)
    }

    private func respond(to text: String, attachments pasted: [Attachment] = []) async {
        // Attached images are what they want looked at; otherwise "look/screen" words take a screenshot.
        let wantsScreen = pasted.isEmpty
            && text.range(of: lookPattern, options: [.regularExpression, .caseInsensitive]) != nil
        Overlay.shared.showStatus((text.isEmpty ? "(attachments)" : text)
                                  + (wantsScreen || !pasted.isEmpty ? "   ◉ looking" : "   ░▒▓"))
        var attachments = pasted
        if attachments.isEmpty, wantsScreen, let shot = await ImageCapture.screenshot() {
            attachments = [.image(shot, name: "screenshot")]
        }
        let reply = await ChatModel.shared.ask(text, attachments: attachments)
        Overlay.shared.show(reply: reply)
    }
}

/// Tiny debug log at ~/Library/Logs/GlitchAI.log.
enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/GlitchAI.log")

    static func write(_ message: String) {
        let line = "\(Date.now.formatted(date: .omitted, time: .standard)) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
