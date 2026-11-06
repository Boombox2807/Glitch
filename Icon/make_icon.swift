// Draws Glitch's app icon (1024×1024 PNG): the violet block figure on a black tile.
// Usage: swift Icon/make_icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
// --figure: just the figure on transparency, cropped tight (for the menu bar and text bar).
let figureOnly = CommandLine.arguments.contains("--figure")
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
var rng = SystemRandomNumberGenerator()
srand48(39)  // journal page 39; fixed seed so the icon is the same every build

// Tile: macOS icon grid leaves ~100px margin around an 824px rounded square.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
if !figureOnly {
ctx.addPath(tilePath)
ctx.clip()
ctx.setFillColor(CGColor(red: 0.02, green: 0, blue: 0.03, alpha: 1))
ctx.fill(tile)
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [CGColor(red: 0.35, green: 0.04, blue: 0.4, alpha: 0.9),
                               CGColor(red: 0.25, green: 0, blue: 0.05, alpha: 0.5),
                               CGColor(red: 0, green: 0, blue: 0, alpha: 0)] as CFArray,
                      locations: [0, 0.45, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 500), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 500), endRadius: 470, options: [])
}

// The figure: blocks along a humanoid outline, each a little rotated, like the journal sketch.
struct Block { let x, y, w, h, angle: CGFloat }
var blocks: [Block] = []
func limb(_ from: CGPoint, _ to: CGPoint, width: CGFloat, count: Int) {
    for i in 0..<count {
        let t = CGFloat(i) / CGFloat(max(count - 1, 1))
        let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        let w = width * CGFloat(0.8 + drand48() * 0.5)
        blocks.append(Block(x: p.x + CGFloat(drand48() * 14 - 7), y: p.y, w: w, h: w * CGFloat(0.7 + drand48() * 0.5),
                            angle: CGFloat(drand48() * 0.6 - 0.3)))
    }
}
limb(CGPoint(x: 512, y: 790), CGPoint(x: 512, y: 760), width: 72, count: 2)       // head
limb(CGPoint(x: 512, y: 680), CGPoint(x: 512, y: 480), width: 96, count: 5)       // torso
limb(CGPoint(x: 440, y: 690), CGPoint(x: 330, y: 470), width: 40, count: 6)       // left arm
limb(CGPoint(x: 584, y: 690), CGPoint(x: 694, y: 470), width: 40, count: 6)       // right arm
limb(CGPoint(x: 472, y: 430), CGPoint(x: 440, y: 205), width: 46, count: 6)       // left leg
limb(CGPoint(x: 552, y: 430), CGPoint(x: 584, y: 205), width: 46, count: 6)       // right leg
// A few blocks that have drifted loose.
for _ in 0..<6 {
    blocks.append(Block(x: CGFloat(300 + drand48() * 424), y: CGFloat(220 + drand48() * 560),
                        w: CGFloat(18 + drand48() * 22), h: CGFloat(18 + drand48() * 22), angle: CGFloat(drand48() - 0.5)))
}

func draw(_ b: Block, dx: CGFloat, color: CGColor) {
    ctx.saveGState()
    ctx.translateBy(x: b.x + dx, y: b.y)
    ctx.rotate(by: b.angle)
    ctx.setFillColor(color)
    ctx.fill(CGRect(x: -b.w / 2, y: -b.h / 2, width: b.w, height: b.h))
    ctx.restoreGState()
}

// Glow, then red/cyan split layers, then the violet body with a lighter face on each block.
ctx.setShadow(offset: .zero, blur: 60, color: CGColor(red: 0.7, green: 0.2, blue: 1, alpha: 0.9))
for b in blocks { draw(b, dx: 0, color: CGColor(red: 0.45, green: 0.1, blue: 0.75, alpha: 0.6)) }
ctx.setShadow(offset: .zero, blur: 0, color: nil)
for b in blocks { draw(b, dx: -12, color: CGColor(red: 1, green: 0.15, blue: 0.3, alpha: 0.75)) }
for b in blocks { draw(b, dx: 12, color: CGColor(red: 0.15, green: 0.95, blue: 0.95, alpha: 0.75)) }
for b in blocks {
    draw(b, dx: 0, color: CGColor(red: 0.6, green: 0.22, blue: 0.95, alpha: 1))
    draw(Block(x: b.x - b.w * 0.12, y: b.y + b.h * 0.12, w: b.w * 0.55, h: b.h * 0.45, angle: b.angle),
         dx: 0, color: CGColor(red: 0.85, green: 0.6, blue: 1, alpha: 0.55))
}

// Horizontal tear: one band of the image shifted sideways.
if let snapshot = ctx.makeImage() {
    let band = CGRect(x: 0, y: 560, width: size, height: 34)
    if let slice = snapshot.cropping(to: CGRect(x: 0, y: size - band.maxY, width: size, height: band.height)) {
        ctx.draw(slice, in: band.offsetBy(dx: 28, dy: 0))
    }
}

if !figureOnly {
// Pixel noise around the figure.
let noiseColors = [CGColor(red: 0.7, green: 0.3, blue: 1, alpha: 0.85),
                   CGColor(red: 0.2, green: 0.95, blue: 0.95, alpha: 0.8),
                   CGColor(red: 1, green: 1, blue: 1, alpha: 0.7),
                   CGColor(red: 1, green: 0.2, blue: 0.35, alpha: 0.7)]
for _ in 0..<140 {
    let x = CGFloat(250 + drand48() * 524), y = CGFloat(180 + drand48() * 640)
    let s = CGFloat([6, 8, 10, 14].randomElement(using: &rng)!)
    ctx.setFillColor(noiseColors[Int(drand48() * 4)])
    ctx.fill(CGRect(x: (x / 8).rounded() * 8, y: (y / 8).rounded() * 8, width: s, height: s))
}

// Thin violet rim so the tile reads on dark Docks.
ctx.resetClip()
ctx.addPath(tilePath)
ctx.setStrokeColor(CGColor(red: 0.62, green: 0.25, blue: 1, alpha: 0.6))
ctx.setLineWidth(6)
ctx.strokePath()
}

NSGraphicsContext.current = nil
if figureOnly, let full = rep.cgImage,
   let cropped = full.cropping(to: CGRect(x: 262, y: 1024 - 840, width: 500, height: 660)) {
    try! NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: out))
} else {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
}
print("wrote \(out)")
