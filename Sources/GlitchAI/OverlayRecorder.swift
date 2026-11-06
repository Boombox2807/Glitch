import AppKit
import AVFoundation
import SwiftUI

/// Test hook (GLITCH_RECORD=<path.mp4>): plays a sample reply in the pop-up and renders it frame by
/// frame into a video, for previewing the animation without screen-recording permission.
@MainActor
enum OverlayRecorder {
    static func record(reply: String, to path: String, seconds: Double = 26, fps: Int32 = 20) {
        let size = CGSize(width: 1280, height: 800)
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let model = Overlay.shared.previewModel
        Overlay.shared.show(reply: reply)
        let start = Date()
        var frame: Int64 = 0
        Timer.scheduledTimer(withTimeInterval: 1 / Double(fps), repeats: true) { timer in
            Task { @MainActor in
                let elapsed = Date().timeIntervalSince(start)
                if elapsed > seconds {
                    timer.invalidate()
                    input.markAsFinished()
                    writer.finishWriting { DispatchQueue.main.async { NSApp.terminate(nil) } }
                    return
                }
                let view = OverlayView(model: model)
                    .frame(width: size.width, height: size.height)
                    .background(Color(red: 0.16, green: 0.17, blue: 0.22))   // stand-in for the desktop
                let renderer = ImageRenderer(content: view)
                renderer.scale = 1
                guard input.isReadyForMoreMediaData, let cg = renderer.cgImage,
                      let pool = adaptor.pixelBufferPool else { return }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let buffer else { return }
                CVPixelBufferLockBaseAddress(buffer, [])
                if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width),
                                       height: Int(size.height), bitsPerComponent: 8,
                                       bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                       space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
                    ctx.draw(cg, in: CGRect(origin: .zero, size: size))
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                adaptor.append(buffer, withPresentationTime: CMTime(value: frame, timescale: fps))
                frame += 1
            }
        }
    }
}
