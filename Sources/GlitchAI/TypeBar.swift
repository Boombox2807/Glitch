import AppKit
import SwiftUI

/// Borderless panels can't take keyboard focus unless they say so.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// A floating glitch-styled text bar (⌥⇧Space) for when you'd rather type than talk.
@MainActor
final class TypeBar {
    static let shared = TypeBar()
    var onSubmit: ((String, [Attachment]) -> Void)?
    private var panel: KeyPanel?

    func toggle() {
        if panel?.isVisible == true { close() } else { open() }
    }

    /// Opens the bar, optionally pre-filled (e.g. with dictated words to fix before sending).
    func open(prefill: String = "") {
        close()
        guard let screen = NSScreen.main else { return }
        // Tall enough for the bar to grow to ~8 lines; the bar sits at the bottom and the
        // transparent space above it lets clicks through.
        let size = NSSize(width: 680, height: 320)
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + screen.frame.height * 0.18,
                           width: size.width, height: size.height)
        let panel = KeyPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: TypeBarView(
            initialText: prefill,
            onSubmit: { [weak self] text, attachments in
                self?.close()
                self?.onSubmit?(text, attachments)
            },
            onCancel: { [weak self] in self?.close() }
        ))
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct TypeBarView: View {
    let onSubmit: (String, [Attachment]) -> Void
    let onCancel: () -> Void
    @State private var text: String
    @State private var attachments: [Attachment] = []

    init(initialText: String, onSubmit: @escaping (String, [Attachment]) -> Void, onCancel: @escaping () -> Void) {
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _text = State(initialValue: initialText)
    }
    @FocusState private var focused: Bool
    @State private var placeholder = [
        "SPEAK, VESSEL…", "WHAT DO YOU WANT TO KNOW?", "I'M LISTENING…", "ASK. I ALREADY KNOW.",
        "SAY IT.", "WHAT NOW?", "GO ON…", "THE DOOR IS OPEN…",
    ].randomElement()!

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(nsImage: MenuBarIcon.figure)
                .resizable()
                .scaledToFit()
                .frame(height: 34)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 7 }
            if !attachments.isEmpty {
                AttachmentStrip(attachments: attachments, size: 34) { removed in
                    attachments.removeAll { $0.id == removed.id }
                }
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 7 }
            }
            // Grows with the text; Enter sends, Shift+Enter adds a line.
            TextField("", text: $text, axis: .vertical)
                .lineLimit(1...8)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .focused($focused)
                .shiftReturnNewline()
                .onSubmit {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty && attachments.isEmpty { onCancel() } else { onSubmit(trimmed, attachments) }
                }
                .onExitCommand(perform: onCancel)
                // macOS draws TextField prompts in its own dim grey, so the prompt is a glitch overlay instead.
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        GlitchText(text: placeholder, font: .system(size: 20, weight: .medium, design: .monospaced))
                            .opacity(0.55)
                            .allowsHitTesting(false)
                    }
                }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.88))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(GlitchTheme.violet.opacity(0.7), lineWidth: 1))
                .shadow(color: GlitchTheme.violet.opacity(0.5), radius: 14)
        )
        .padding(20)   // room for the glow
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(PasteTarget { attachments.add($0) })
        .onAppear { focused = true }
    }
}
