import AppKit

enum ImageCapture {
    /// Captures the main display as a downscaled JPEG. Needs Screen Recording permission.
    /// Glitch's own floating windows are hidden from capture only for the moment of the screenshot,
    /// so they stay visible in the user's own screen recordings.
    @MainActor
    static func screenshot() async -> Data? {
        let path = NSTemporaryDirectory() + "glitch-\(UUID().uuidString).jpg"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let own = NSApp.windows.filter { $0.isVisible && $0.sharingType != .none }
        own.forEach { $0.sharingType = .none }
        defer { own.forEach { $0.sharingType = .readOnly } }
        guard await run("/usr/sbin/screencapture", ["-x", "-m", "-t", "jpg", path]) else { return nil }
        return jpeg(fromFile: URL(fileURLWithPath: path))
    }

    /// Captures the main window of an open app, even if other windows cover it. Read-only.
    /// Needs Screen Recording permission.
    static func window(ofApp name: String) async -> Data? {
        guard let id = mainWindowID(ofApp: name) else { return nil }
        let path = NSTemporaryDirectory() + "glitch-\(UUID().uuidString).jpg"
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard await run("/usr/sbin/screencapture", ["-x", "-o", "-l", String(id), "-t", "jpg", path]) else { return nil }
        return jpeg(fromFile: URL(fileURLWithPath: path))
    }

    /// The app's largest normal window, preferring one that's on screen.
    private static func mainWindowID(ofApp name: String) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let all = list.filter {
            ($0[kCGWindowOwnerName as String] as? String)?.caseInsensitiveCompare(name) == .orderedSame
                && ($0[kCGWindowLayer as String] as? Int) == 0
        }
        // Prefer a window on screen now; otherwise the app's main window in another Space or behind others.
        let onscreen = all.filter { ($0[kCGWindowIsOnscreen as String] as? Bool) == true }
        let windows = onscreen.isEmpty ? all : onscreen
        func area(_ w: [String: Any]) -> Double {
            let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
            return (b["Width"] ?? 0) * (b["Height"] ?? 0)
        }
        return windows.max { area($0) < area($1) }
            .flatMap { $0[kCGWindowNumber as String] as? Int }.map { CGWindowID($0) }
    }

    /// Loads any image file and re-encodes it as a JPEG no larger than 1600px.
    static func jpeg(fromFile url: URL) -> Data? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        return jpeg(from: image)
    }

    static func jpeg(from image: NSImage, maxSide: CGFloat = 1600) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, maxSide / CGFloat(max(cg.width, cg.height)))
        let size = NSSize(width: CGFloat(cg.width) * scale, height: CGFloat(cg.height) * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSImage(cgImage: cg, size: size).draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    private static func run(_ tool: String, _ args: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = args
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
    }
}
