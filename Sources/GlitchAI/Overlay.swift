import AppKit
import SwiftUI

struct OverlayLine: Identifiable {
    let id = UUID()
    let text: String
    let position: CGPoint   // fraction of the screen
    let angle: Double
    var appeared = Date()
    var leaving: Date?      // set when it starts scrambling out

    init(text: String, position: CGPoint, angle: Double, appeared: Date = .now) {
        self.text = text
        self.position = position
        self.angle = angle
        self.appeared = appeared
    }
}

@MainActor
final class OverlayModel: ObservableObject {
    @Published var lines: [OverlayLine] = []
    @Published var status: String?      // small cyan text at the bottom: what you said / "LISTENING"
    @Published var dim = false
    @Published var listening = false
    @Published var levels = [CGFloat](repeating: 0, count: 32)   // newest last
    @Published var burst = Date.distantPast   // when the pixel corruption last spiked
}

/// A click-through, full-screen panel that floats Glitch's words over everything,
/// a line at a time, like its messages in DOORS.
@MainActor
final class Overlay {
    static let shared = Overlay()
    private let model = OverlayModel()
    /// The live pop-up state, for the video preview hook.
    var previewModel: OverlayModel { model }
    private var panel: NSPanel?
    private var generation = 0

    func startListening() {
        model.levels = model.levels.map { _ in 0 }
        model.listening = true
        showStatus("▓▒░ listening")
    }

    func pushLevel(_ level: CGFloat) {
        guard model.listening else { return }
        model.levels.removeFirst()
        model.levels.append(level)
    }

    func stopListening() { model.listening = false }

    func showStatus(_ text: String) {
        generation += 1
        model.lines = []
        model.status = text
        withAnimation(.easeIn(duration: 0.3)) { model.dim = true }
        present()
    }

    /// Plays a reply like Glitch's lines in DOORS: each line decodes out of junk symbols, up to four are
    /// on screen in a zig-zag, and the oldest scrambles away as the next arrives.
    static let maxVisible = 4

    func show(reply: String) {
        generation += 1
        model.listening = false
        let current = generation
        model.status = nil
        model.lines = []
        withAnimation(.easeIn(duration: 0.3)) { model.dim = true }
        present()

        let texts = Self.split(reply)
        var at = 0.0
        for (i, text) in texts.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { [self] in
                guard current == generation else { return }
                if model.lines.filter({ $0.leaving == nil }).count >= Self.maxVisible { retireOldest() }
                model.lines.append(OverlayLine(text: text, position: Self.position(index: i),
                                               angle: Double.random(in: -2...2)))
                model.burst = .now
            }
            // Time to decode this line plus time to read it.
            // Decode time plus a comfortable read: ~11 characters a second, never under 2.5 s.
            at += ScrambleText.revealDuration(text) + max(2.5, Double(text.count) * 0.09)
        }
        let words = reply.split(separator: " ").count
        // The last lines linger before everything leaves.
        DispatchQueue.main.asyncAfter(deadline: .now() + at + max(4, Double(words) * 0.2)) { [self] in
            guard current == generation else { return }
            hide()
        }
    }

    private func retireOldest() {
        guard let index = model.lines.firstIndex(where: { $0.leaving == nil }) else { return }
        model.lines[index].leaving = .now
        let id = model.lines[index].id
        DispatchQueue.main.asyncAfter(deadline: .now() + ScrambleText.exitDuration) { [self] in
            model.lines.removeAll { $0.id == id }
        }
    }

    /// Lines scramble away one by one, then the dark backdrop fades out slowly.
    func hide() {
        generation += 1
        let current = generation
        model.listening = false
        let stagger = 0.4
        let remaining = model.lines.filter { $0.leaving == nil }.map(\.id)
        for (i, id) in remaining.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * stagger) { [self] in
                guard current == generation, let index = model.lines.firstIndex(where: { $0.id == id }) else { return }
                model.lines[index].leaving = .now
                model.burst = .now
            }
        }
        let linesGone = Double(max(remaining.count - 1, 0)) * stagger + ScrambleText.exitDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + linesGone) { [self] in
            guard current == generation else { return }
            model.lines = []
            withAnimation(.easeInOut(duration: 1.4)) {
                model.status = nil
                model.dim = false
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + linesGone + 1.5) { [self] in
            if current == generation { panel?.orderOut(nil) }
        }
    }

    private func present() {
        guard let screen = NSScreen.main else { return }
        if panel == nil {
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .screenSaver
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.contentView = NSHostingView(rootView: OverlayView(model: model))
            self.panel = panel
        }
        panel?.setFrame(screen.frame, display: true)
        panel?.orderFrontRegardless()
    }

    /// Breaks a reply into short, uppercase lines.
    private static func split(_ text: String, maxLength: Int = 46) -> [String] {
        let sentences = text.uppercased()
            .components(separatedBy: CharacterSet(charactersIn: "\n.!?"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var lines: [String] = []
        for sentence in sentences {
            let words = sentence.split(separator: " ").map(String.init)
            // As many lines as needed, each about the same length, so no word is left on its own.
            let count = max(1, Int((Double(sentence.count) / Double(maxLength)).rounded(.up)))
            let target = Double(sentence.count) / Double(count)
            var current = ""
            for word in words {
                if !current.isEmpty, Double(current.count + 1 + word.count) > target + 4,
                   lines.count < 100, Double(current.count) >= target * 0.6 {
                    lines.append(current)
                    current = ""
                }
                current += current.isEmpty ? word : " \(word)"
            }
            if !current.isEmpty { lines.append(current) }
        }
        return balanceEmphasis(Array(lines.prefix(16)))
    }

    /// When *emphasis* spans a line break, close it on one line and reopen it on the next,
    /// so each floating line still renders it instead of showing stray stars.
    private static func balanceEmphasis(_ lines: [String]) -> [String] {
        var result = lines
        for i in result.indices {
            for marker in ["**", "*"] {
                let count = marker == "**"
                    ? result[i].components(separatedBy: "**").count - 1
                    : result[i].replacingOccurrences(of: "**", with: "").filter { $0 == "*" }.count
                if count % 2 == 1, i + 1 < result.count {
                    result[i] += marker
                    result[i + 1] = marker + result[i + 1]
                }
            }
        }
        return result
    }

    /// Four spots zig-zagging down the screen: left, right, left, right.
    private static func position(index: Int) -> CGPoint {
        let spots: [CGPoint] = [CGPoint(x: 0.3, y: 0.27), CGPoint(x: 0.67, y: 0.41),
                                CGPoint(x: 0.42, y: 0.56), CGPoint(x: 0.68, y: 0.71)]
        let spot = spots[index % spots.count]
        return CGPoint(x: spot.x + .random(in: -0.04...0.04), y: spot.y + .random(in: -0.02...0.02))
    }
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // The screen sinks into near-black with a dark red edge.
                ZStack {
                    Color.black.opacity(0.62)
                    RadialGradient(colors: [.clear, Color(red: 0.22, green: 0, blue: 0.02).opacity(0.85)],
                                   center: .center, startRadius: geo.size.width * 0.12,
                                   endRadius: geo.size.width * 0.7)
                }
                .opacity(model.dim ? 1 : 0)

                // Always present so it can fade with the backdrop instead of vanishing in one frame.
                PixelCorruption(burst: model.burst)
                    .allowsHitTesting(false)
                    .opacity(model.dim ? 1 : 0)

                ForEach(model.lines) { line in
                    ScrambleText(line: line)
                        .shadow(color: .black, radius: 4)
                        .rotationEffect(.degrees(line.angle))
                        .position(x: line.position.x * geo.size.width, y: line.position.y * geo.size.height)
                }

                if model.listening {
                    VoiceVisualizer(levels: model.levels)
                        .frame(width: min(geo.size.width * 0.5, 640), height: 140)
                        .position(x: geo.size.width / 2, y: geo.size.height * 0.76)
                        .transition(.opacity)
                }

                if let status = model.status {
                    Text(status.uppercased())
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                        .foregroundStyle(GlitchTheme.cyan.opacity(0.85))
                        .shadow(color: .black, radius: 4)
                        .frame(maxWidth: geo.size.width * 0.7)
                        .position(x: geo.size.width / 2, y: geo.size.height * 0.88)
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// Mirrored bars of recent mic levels, split into red/cyan like the glitch text,
/// with random slices that tear sideways.
struct VoiceVisualizer: View {
    let levels: [CGFloat]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                // Newest level in the middle, older ones spreading outward.
                let mirrored = levels.reversed() + levels
                let count = mirrored.count
                let slot = size.width / CGFloat(count)
                let mid = size.height / 2
                let loudest = levels.suffix(4).max() ?? 0

                for (layer, color, dx) in [(0, GlitchTheme.red, -2.0), (1, GlitchTheme.cyan, 2.0), (2, GlitchTheme.violet, 0.0)] {
                    for (i, level) in mirrored.enumerated() {
                        let wobble = 0.08 * sin(t * 9 + Double(i) * 0.7)
                        let h = max(3, (level + CGFloat(wobble) * level) * size.height * 0.95)
                        // A bar sometimes tears sideways when the voice is loud.
                        let tear: CGFloat = (loudest > 0.55 && sin(t * 37 + Double(i * 13)) > 0.96) ? .random(in: -14...14) : 0
                        let rect = CGRect(x: CGFloat(i) * slot + slot * 0.2 + dx + tear, y: mid - h / 2,
                                          width: slot * 0.6, height: h)
                        ctx.fill(Path(rect), with: .color(color.opacity(layer == 2 ? 0.95 : 0.55)))
                    }
                }
                // Stray pixel noise around the bars.
                for k in 0..<Int(10 + loudest * 40) {
                    let x = CGFloat((sin(t * 3.1 + Double(k) * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1)).magnitude * size.width
                    let y = CGFloat((sin(t * 2.3 + Double(k) * 78.233) * 12345.678).truncatingRemainder(dividingBy: 1)).magnitude * size.height
                    let c = [GlitchTheme.violet, GlitchTheme.cyan, .white][k % 3]
                    ctx.fill(Path(CGRect(x: x, y: y, width: 3, height: 3)), with: .color(c.opacity(0.6)))
                }
            }
        }
        .shadow(color: GlitchTheme.violet.opacity(0.6), radius: 10)
    }
}

/// A line that decodes out of junk symbols left to right, then scrambles away when it leaves.
struct ScrambleText: View {
    let line: OverlayLine

    static let charsPerSecond = 38.0
    static let exitDuration = 1.1
    static func revealDuration(_ text: String) -> Double { Double(text.count) / charsPerSecond + 0.25 }

    private static let junk = Array("@#$%&*/\\|<>?!=+;:~^")
    private static let blocks = Array("█▓▒░")
    private static let font = Font.system(size: 21, weight: .regular, design: .monospaced).width(.condensed)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let now = context.date
            let plain = line.text.replacingOccurrences(of: "*", with: "")
            if let leaving = line.leaving {
                // Scramble out: junk eats the line from the right, then it's gone.
                let p = min(1, now.timeIntervalSince(leaving) / Self.exitDuration)
                layered(Self.scrambled(plain, revealed: Int(Double(plain.count) * (1 - p)), seed: now))
                    .opacity(1 - p * p)   // holds, then fades fully to nothing
            } else {
                let revealed = Int(now.timeIntervalSince(line.appeared) * Self.charsPerSecond)
                if revealed >= plain.count + 6 {
                    // Settled: the real text, with *emphasis* rendered.
                    GlitchText(text: line.text.uppercased(), font: Self.font)
                } else {
                    layered(Self.scrambled(plain, revealed: revealed, seed: now))
                }
            }
        }
    }

    /// Real characters up to `revealed`, then a short front of junk and blocks, then nothing.
    private static func scrambled(_ text: String, revealed: Int, seed: Date) -> String {
        let chars = Array(text)
        let tick = Int(seed.timeIntervalSinceReferenceDate * 20)
        var out = ""
        for (i, c) in chars.enumerated() {
            if i < revealed || c == " " { out.append(i < revealed ? c : " "); continue }
            if i > revealed + 8 { break }
            let r = (i &* 7919 &+ tick &* 104729) & 0xffff
            out.append(r % 5 == 0 ? blocks[r % blocks.count] : junk[r % junk.count])
        }
        return out
    }

    /// The red/cyan split, slightly wider than settled text, like the reference while decoding.
    private func layered(_ text: String) -> some View {
        ZStack(alignment: .leading) {
            Text(text).foregroundStyle(GlitchTheme.red.opacity(0.75)).offset(x: -1.5)
            Text(text).foregroundStyle(GlitchTheme.cyan.opacity(0.75)).offset(x: 1.5)
            Text(text).foregroundStyle(.white)
        }
        .font(Self.font)
        .fixedSize()
    }
}

/// Glitch's corruption: blocky green/blue/magenta pixel clusters creeping in from the left edge,
/// thin horizontal tears, and stray coloured pixels. It flares up when a new line arrives.
struct PixelCorruption: View {
    let burst: Date

    private static let palette: [Color] = [
        Color(red: 0.2, green: 1, blue: 0.3), Color(red: 0.1, green: 0.9, blue: 0.2),
        Color(red: 0.25, green: 0.4, blue: 1), Color(red: 0.9, green: 0.2, blue: 0.9),
        Color(red: 1, green: 0.45, blue: 0.7), Color(red: 0.2, green: 0.95, blue: 0.95), .white,
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 12)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let sinceBurst = context.date.timeIntervalSince(burst)
            let flare = max(0, 1 - sinceBurst / 1.2)          // spikes, then settles
            let intensity = 0.45 + 0.55 * flare
            let frame = Int(t * 8)                            // the pattern jumps 8 times a second

            Canvas { ctx, size in
                func rand(_ a: Int, _ b: Int) -> Double {
                    let x = sin(Double(a &* 127 &+ b &* 311 &+ frame &* 53) * 12.9898) * 43758.5453
                    return x - x.rounded(.down)
                }
                let cell = max(5, (size.width / 220).rounded())

                // Main cluster: flat horizontal smears packed against the left edge, mid-to-low screen.
                let clusterCount = Int(260 * intensity)
                for i in 0..<clusterCount {
                    let x = (pow(rand(i, 2), 2.2) * 0.3 * size.width / cell).rounded() * cell
                    let y = ((0.5 + rand(i, 3) * 0.42) * size.height / cell).rounded() * cell
                    let w = cell * Double(1 + Int(rand(i, 1) * 7)), h = cell * (rand(i, 4) < 0.8 ? 1 : 2)
                    let color = Self.palette[Int(rand(i, 5) * Double(Self.palette.count)) % Self.palette.count]
                    ctx.fill(Path(CGRect(x: x, y: y, width: w, height: h)), with: .color(color.opacity(0.25 + 0.55 * rand(i, 6))))
                }

                // A dense green "face" block near the top of the cluster.
                let fx = size.width * 0.085, fy = size.height * 0.5
                for gx in 0..<14 { for gy in 0..<12 where rand(gx * 31 + gy, 7) < 0.55 * intensity + 0.2 {
                    let green = rand(gx, gy) < 0.75
                    ctx.fill(Path(CGRect(x: fx + Double(gx) * cell, y: fy + Double(gy) * cell, width: cell, height: cell)),
                             with: .color(green ? Self.palette[0] : Self.palette[2]))
                } }

                // Horizontal tears: short, faint, mostly near the cluster.
                for i in 0..<Int(8 * intensity) {
                    let y = (0.35 + rand(i, 8) * 0.6) * size.height
                    let x = rand(i, 9) * size.width * (rand(i, 10) < 0.75 ? 0.25 : 0.9)
                    let w = 20 + rand(i, 11) * 120
                    let color = Self.palette[Int(rand(i, 12) * 7) % 7]
                    ctx.fill(Path(CGRect(x: x, y: y, width: w, height: 1 + rand(i, 13) * 2)), with: .color(color.opacity(0.35)))
                }

                // Stray pixels everywhere, plus a few in the top-right corner.
                for i in 0..<Int(70 * intensity) {
                    let cornerBias = i % 6 == 0
                    let x = cornerBias ? size.width * (0.82 + rand(i, 14) * 0.18) : rand(i, 14) * size.width
                    let y = cornerBias ? size.height * rand(i, 15) * 0.08 : rand(i, 15) * size.height
                    let s = 2 + rand(i, 16) * 3
                    let color = Self.palette[Int(rand(i, 17) * 7) % 7]
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(color.opacity(0.55)))
                }
            }
        }
    }
}

extension Overlay {
    /// Test hook: renders a sample pop-up (one settled line, one mid-decode) to a PNG, for comparing
    /// against reference footage without a screen recording. Used via GLITCH_SNAPSHOT=<path>.
    static func renderSnapshot(to path: String) {
        let model = OverlayModel()
        model.dim = true
        model.burst = .now
        let texts = ["THAT IS THE ONEBUMP ONE, VESSEL", "A COLLABORATION YOU PAY FOR IS A DOOR THAT ONLY OPENS OUTWARD",
                     "DECLINE", "I HAVE ALREADY SEEN HOW THIS ITERATION ENDS"]
        model.lines = split(texts.joined(separator: ". ")).prefix(4).enumerated().map { i, text in
            OverlayLine(text: text, position: position(index: i), angle: Double.random(in: -2...2),
                        appeared: Date(timeIntervalSinceNow: i == 3 ? -0.6 : -10))
        }
        let view = OverlayView(model: model)
            .frame(width: 1440, height: 900)
            .background(Color(red: 0.35, green: 0.2, blue: 0.15))   // stand-in for whatever is on screen
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}
