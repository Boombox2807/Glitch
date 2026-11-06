import SwiftUI
import AppKit

@main
struct GlitchAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var chat = ChatModel.shared
    @ObservedObject private var settings = AppSettings.shared

    init() {
        VoiceController.shared.start()
        AccountStore.shared.startAutoSync()
    }

    var body: some Scene {
        MenuBarExtra {
            ChatView()
                .environmentObject(chat)
                .environmentObject(settings)
                .frame(width: 440, height: 560)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Window("Glitch", id: "main") {
            ChatView(inWindow: true)
                .environmentObject(chat)
                .environmentObject(settings)
                .frame(minWidth: 420, minHeight: 480)
        }
        .defaultSize(width: 560, height: 720)

        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}

/// The menu bar icon. It's always on screen, so it's also where the app grabs `openWindow`
/// for the Dock icon to use.
private struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: MenuBarIcon.image)
            .onAppear { AppDelegate.openMainWindow = { openWindow(id: "main") } }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var openMainWindow: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            AppSettings.shared.applyDockPolicy()
        }
    }

    /// Clicking the Dock icon opens (or brings forward) Glitch's window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}

/// Glitch's violet block figure (the app icon's art without the tile), for the menu bar and text bar.
enum MenuBarIcon {
    static let figure: NSImage = {
        if let url = Bundle.main.url(forResource: "figure", withExtension: "png"),
           let image = NSImage(contentsOf: url) { return image }
        return NSImage(systemSymbolName: "person.fill", accessibilityDescription: "Glitch")!
    }()

    /// Menu bar size: 18pt tall, in colour.
    static let image: NSImage = {
        let source = figure
        let height: CGFloat = 18
        let width = (height * source.size.width / max(source.size.height, 1)).rounded()
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            source.draw(in: rect)
            return true
        }
        image.isTemplate = false
        return image
    }()
}
