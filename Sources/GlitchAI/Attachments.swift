import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Something attached to a message: an image, or a video turned into a few still frames
/// (models read images, not video files).
struct Attachment: Identifiable, Equatable {
    enum Kind: Equatable {
        case image
        case video(seconds: Double)
    }

    let id = UUID()
    let kind: Kind
    let name: String
    /// JPEG frames: the image itself, or stills from a video (used when a model can't take video).
    let frames: [Data]
    /// The original video file, sent as-is to models that accept video (nil if too large or not a video).
    var video: (data: Data, mime: String)? = nil

    static func == (a: Attachment, b: Attachment) -> Bool { a.id == b.id }
    /// What the chat shows.
    var preview: Data { frames.first ?? Data() }

    static let maxPerMessage = 6
    static let framesPerVideo = 6

    var label: String {
        switch kind {
        case .image: return "image \(name)"
        case .video(let seconds): return "video \(name), \(Int(seconds.rounded())) s"
        }
    }

    /// Label when the video is sent as stills instead of the file.
    var framesLabel: String {
        if case .video(let seconds) = kind {
            return "video \(name), \(Int(seconds.rounded())) s, shown as \(frames.count) frames in order"
        }
        return label
    }

    static let maxVideoBytes = 20 * 1024 * 1024

    // MARK: - Loading

    static func image(_ data: Data, name: String = "pasted") -> Attachment {
        Attachment(kind: .image, name: name, frames: [data])
    }

    /// An image or video file. Returns nil for anything else.
    static func load(_ url: URL) async -> Attachment? {
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true {
            return await video(url)
        }
        guard let data = ImageCapture.jpeg(fromFile: url) else { return nil }
        return Attachment(kind: .image, name: url.lastPathComponent, frames: [data])
    }

    /// Evenly spaced frames across the video, skipping the very start and end.
    private static func video(_ url: URL) async -> Attachment? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration > 0 else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        let count = duration < 3 ? 2 : framesPerVideo
        var frames: [Data] = []
        for i in 0..<count {
            let t = duration * (Double(i) + 0.5) / Double(count)
            guard let (image, _) = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)),
                  let jpeg = ImageCapture.jpeg(from: NSImage(cgImage: image, size: .zero), maxSide: 960) else { continue }
            frames.append(jpeg)
        }
        guard !frames.isEmpty else { return nil }
        var attachment = Attachment(kind: .video(seconds: duration), name: url.lastPathComponent, frames: frames)
        let mimes = ["mp4": "video/mp4", "m4v": "video/mp4", "mov": "video/mov", "webm": "video/webm",
                     "mpeg": "video/mpeg", "mpg": "video/mpeg"]
        if let mime = mimes[url.pathExtension.lowercased()],
           let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxVideoBytes,
           let data = try? Data(contentsOf: url) {
            attachment.video = (data, mime)
        }
        return attachment
    }

    /// Everything attachable on the clipboard: copied files (images and videos) or raw image data.
    static func fromPasteboard() async -> [Attachment] {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            var found: [Attachment] = []
            for url in urls { if let a = await load(url) { found.append(a) } }
            if !found.isEmpty { return found }
        }
        guard board.availableType(from: [.png, .tiff]) != nil,
              let image = NSImage(pasteboard: board), let data = ImageCapture.jpeg(from: image) else { return [] }
        return [.image(data)]
    }

    /// True when ⌘V should be handled as attachments rather than text.
    static var pasteboardHasMedia: Bool {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           urls.contains(where: { url in
               let type = UTType(filenameExtension: url.pathExtension.lowercased())
               return type?.conforms(to: .image) == true || type?.conforms(to: .movie) == true
           }) { return true }
        return board.availableType(from: [.png, .tiff]) != nil
    }
}

extension Array where Element == Attachment {
    /// Adds new attachments up to the per-message limit.
    mutating func add(_ new: [Attachment]) {
        self = Array((self + new).prefix(Attachment.maxPerMessage))
    }

    /// The note sent alongside so the model knows what it's looking at.
    func note(videoAsFile: Bool) -> String? {
        guard !isEmpty else { return nil }
        let labels = map { videoAsFile && $0.video != nil ? $0.label : $0.framesLabel }
        return "[Attached, in order: " + labels.joined(separator: "; ") + "]"
    }
}

import SwiftUI

/// A row of attachment thumbnails. Videos get a ▶ badge and their length; click to enlarge,
/// ✕ to remove (when `onRemove` is set).
struct AttachmentStrip: View {
    let attachments: [Attachment]
    var size: CGFloat = 44
    var onRemove: ((Attachment) -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            ForEach(attachments) { a in
                if let image = NSImage(data: a.preview) {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(GlitchTheme.hairline))
                        .overlay(alignment: .bottomLeading) {
                            if case .video(let seconds) = a.kind {
                                HStack(spacing: 2) {
                                    Image(systemName: "play.fill")
                                    Text("\(Int(seconds.rounded()))s")
                                }
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4).padding(.vertical, 2)
                                .background(Capsule().fill(.black.opacity(0.65)))
                                .padding(3)
                            }
                        }
                        .onTapGesture { ImagePreview.show(image) }
                        .help(a.name)
                        .overlay(alignment: .topTrailing) {
                            if let onRemove {
                                Button { onRemove(a) } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                                .offset(x: 6, y: -6)
                            }
                        }
                }
            }
        }
    }
}
