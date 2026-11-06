import AppKit
import SwiftUI

private final class PreviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }   // Esc
}

/// A large preview of an attached or sent image. Esc, a click or ⌘W closes it.
@MainActor
enum ImagePreview {
    private static var panel: PreviewPanel?

    static func show(_ image: NSImage) {
        panel?.close()
        guard let screen = NSScreen.main else { return }
        // Fit inside 85% of the screen without upscaling past the image's own size.
        let limit = NSSize(width: screen.visibleFrame.width * 0.85, height: screen.visibleFrame.height * 0.85)
        let scale = min(1, limit.width / image.size.width, limit.height / image.size.height)
        let size = NSSize(width: max(240, image.size.width * scale), height: max(160, image.size.height * scale))
        let frame = NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2,
                           width: size.width, height: size.height)

        let panel = PreviewPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: PreviewView(image: image) { panel.close() })
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    static func show(_ data: Data) {
        if let image = NSImage(data: data) { show(image) }
    }
}

private struct PreviewView: View {
    let image: NSImage
    let close: () -> Void

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(GlitchTheme.violet.opacity(0.7), lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture(perform: close)
            .help("Click or press Esc to close")
    }
}
