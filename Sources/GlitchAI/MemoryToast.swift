import AppKit
import SwiftUI

/// A small glitch-styled notification in the top-right corner when Glitch saves or forgets
/// something about you on its own. Click-through, stacks several, fades after a few seconds.
@MainActor
final class MemoryToast: ObservableObject {
    static let shared = MemoryToast()

    struct Item: Identifiable, Equatable {
        enum Kind { case etched, erased, copied, ran, failed }
        let id = UUID()
        let kind: Kind
        let text: String
        var appeared = Date()
    }

    @Published private(set) var items: [Item] = []
    private var panel: NSPanel?
    private let size = NSSize(width: 360, height: 300)

    func show(_ new: [Item]) {
        present()
        for (i, item) in new.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.35) { [self] in
                var item = item
                item.appeared = .now
                withAnimation(.spring(duration: 0.35)) { items.append(item) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) { [self] in
                    withAnimation(.easeIn(duration: 0.3)) { items.removeAll { $0.id == item.id } }
                    if items.isEmpty {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
                            if items.isEmpty { panel?.orderOut(nil) }
                        }
                    }
                }
            }
        }
    }

    private func present() {
        guard let screen = NSScreen.main else { return }
        let frame = NSRect(x: screen.visibleFrame.maxX - size.width - 12, y: screen.visibleFrame.maxY - size.height - 8,
                           width: size.width, height: size.height)
        if panel == nil {
            let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .statusBar
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.contentView = NSHostingView(rootView: MemoryToastStack(toast: self))
            self.panel = panel
        }
        panel?.setFrame(frame, display: true)
        panel?.orderFrontRegardless()
    }
}

private struct MemoryToastStack: View {
    @ObservedObject var toast: MemoryToast

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(toast.items) { item in
                MemoryToastCard(item: item)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(6)
    }
}

struct MemoryToastCard: View {
    let item: MemoryToast.Item

    private var accent: Color {
        switch item.kind {
        case .etched, .copied, .ran: return GlitchTheme.violet
        case .erased, .failed: return GlitchTheme.red
        }
    }

    private var title: String {
        switch item.kind {
        case .etched: return "MEMORY ETCHED"
        case .erased: return "MEMORY ERASED"
        case .copied: return "DRAFT COPIED — ⌘V TO PASTE"
        case .ran: return "SHORTCUT RAN"
        case .failed: return "SHORTCUT FAILED"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: MenuBarIcon.figure)
                .resizable().scaledToFit()
                .frame(width: 22, height: 28)
            VStack(alignment: .leading, spacing: 4) {
                ScrambleText(line: OverlayLine(
                    text: title,
                    position: .zero, angle: 0, appeared: item.appeared))
                    .scaleEffect(0.62, anchor: .leading)
                    .frame(height: 16, alignment: .leading)
                Text(item.text)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(item.kind == .etched ? 0.9 : 0.55))
                    .strikethrough(item.kind == .erased, color: GlitchTheme.red.opacity(0.8))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 330, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.05, green: 0.02, blue: 0.07).opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.6), lineWidth: 1))
        .shadow(color: accent.opacity(0.45), radius: 12)
    }
}

extension MemoryToast {
    /// Test hook: renders two sample notifications to a PNG (GLITCH_TOAST_SNAPSHOT=<path>).
    static func renderSnapshot(to path: String) {
        let view = VStack(spacing: 8) {
            MemoryToastCard(item: .init(kind: .etched, text: "User wrote the main part of VoidBox alone, in one month",
                                        appeared: Date(timeIntervalSinceNow: -5)))
            MemoryToastCard(item: .init(kind: .erased, text: "User is listening to music", appeared: Date(timeIntervalSinceNow: -0.25)))
        }
        .padding(16)
        .background(Color(red: 0.25, green: 0.25, blue: 0.3))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}
