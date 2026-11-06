import AppKit
import SwiftUI

/// ⌘V with images or videos on the clipboard. Text fields ignore pasted images, so an app-wide key monitor
/// catches ⌘V first and, if the clipboard holds media, hands it to whichever Glitch window is in front.
@MainActor
enum ImagePaste {
    private static var handlers: [ObjectIdentifier: ([Attachment]) -> Void] = [:]
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v",
                  let window = event.window ?? NSApp.keyWindow,
                  let handler = handlers[ObjectIdentifier(window)],
                  Attachment.pasteboardHasMedia else { return event }
            Task { @MainActor in
                let found = await Attachment.fromPasteboard()
                if !found.isEmpty { handler(found) }
            }
            return nil   // handled; don't also paste a file name or nothing into the text field
        }
    }

    static func register(_ window: NSWindow, _ handler: @escaping ([Attachment]) -> Void) {
        handlers[ObjectIdentifier(window)] = handler
    }

    static func unregister(_ window: NSWindow) {
        handlers[ObjectIdentifier(window)] = nil
    }
}

/// Put `.background(PasteTarget { attachments in … })` in a view to receive pasted media for its window.
struct PasteTarget: NSViewRepresentable {
    let onImage: ([Attachment]) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onImage = onImage
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onImage = onImage
    }

    final class TrackingView: NSView {
        var onImage: (([Attachment]) -> Void)?
        private weak var registered: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let old = registered { ImagePaste.unregister(old) }
            registered = window
            if let window { ImagePaste.register(window) { [weak self] in self?.onImage?($0) } }
        }
    }
}
