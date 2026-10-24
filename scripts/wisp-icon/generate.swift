// Draws the Wisp app icon: a glowing will-o'-the-wisp flame on a night sky.
//
// Usage: swift scripts/wisp-icon/generate.swift <output dir>
//
// Writes the Icon Composer layers (Glow.png, Wisp.png, Sparkles.png; 1024px,
// transparent) and Flat.png, the whole icon flattened for places that need a
// plain image such as the About window.

import AppKit
import CoreGraphics

let size = 1024
let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let space = CGColorSpace(name: CGColorSpace.displayP3)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: space,
        components: [
            CGFloat((hex >> 16) & 0xFF) / 255,
            CGFloat((hex >> 8) & 0xFF) / 255,
            CGFloat(hex & 0xFF) / 255,
            alpha,
        ])!
}

/// A transparent canvas with a top-left origin.
func canvas(_ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: 1, y: -1)
    draw(ctx)
    return ctx.makeImage()!
}

func save(_ image: CGImage, _ name: String) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    try rep.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent(name))
}

/// The flame: a round body with a tip that sweeps up and to the right.
let flame: CGPath = {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 318, y: 610))
    p.addCurve(to: CGPoint(x: 628, y: 168), control1: CGPoint(x: 300, y: 440), control2: CGPoint(x: 540, y: 380))
    p.addCurve(to: CGPoint(x: 706, y: 600), control1: CGPoint(x: 590, y: 310), control2: CGPoint(x: 730, y: 430))
    p.addCurve(to: CGPoint(x: 512, y: 812), control1: CGPoint(x: 706, y: 722), control2: CGPoint(x: 618, y: 812))
    p.addCurve(to: CGPoint(x: 318, y: 610), control1: CGPoint(x: 400, y: 812), control2: CGPoint(x: 318, y: 718))
    p.closeSubpath()
    return p
}()

/// A second, smaller flame inside the first: the bright core.
let core: CGPath = {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 420, y: 640))
    p.addCurve(to: CGPoint(x: 590, y: 380), control1: CGPoint(x: 410, y: 530), control2: CGPoint(x: 540, y: 480))
    p.addCurve(to: CGPoint(x: 612, y: 650), control1: CGPoint(x: 590, y: 470), control2: CGPoint(x: 640, y: 560))
    p.addCurve(to: CGPoint(x: 512, y: 748), control1: CGPoint(x: 600, y: 712), control2: CGPoint(x: 560, y: 748))
    p.addCurve(to: CGPoint(x: 420, y: 640), control1: CGPoint(x: 460, y: 748), control2: CGPoint(x: 420, y: 700))
    p.closeSubpath()
    return p
}()

func sparkle(_ ctx: CGContext, at c: CGPoint, radius r: CGFloat, alpha: CGFloat) {
    let p = CGMutablePath()
    let w = r * 0.22
    p.move(to: CGPoint(x: c.x, y: c.y - r))
    p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + w, y: c.y - w))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + w, y: c.y + w))
    p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - w, y: c.y + w))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - w, y: c.y - w))
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: r * 0.8, color: color(0x9CF6FF, 0.9 * alpha))
    ctx.addPath(p)
    ctx.setFillColor(color(0xF2FFFE, alpha))
    ctx.fillPath()
    ctx.restoreGState()
}

func drawGlow(_ ctx: CGContext) {
    // Soft halo around the flame, stronger near the body.
    let halo = CGGradient(
        colorsSpace: space,
        colors: [color(0x5FF2FF, 0.55), color(0x7A5CFF, 0.22), color(0x7A5CFF, 0)] as CFArray,
        locations: [0, 0.55, 1])!
    ctx.drawRadialGradient(
        halo,
        startCenter: CGPoint(x: 520, y: 600), startRadius: 0,
        endCenter: CGPoint(x: 520, y: 560), endRadius: 430,
        options: [])
}

func drawWisp(_ ctx: CGContext) {
    // Outer flame: cyan at the heart to violet at the tip.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 60, color: color(0x48E5FF, 0.85))
    ctx.addPath(flame)
    ctx.setFillColor(color(0x48E5FF))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(flame)
    ctx.clip()
    let body = CGGradient(
        colorsSpace: space,
        colors: [color(0xB8FFF3), color(0x3FD8FF), color(0x6A5BFF), color(0x9B4DFF)] as CFArray,
        locations: [0, 0.38, 0.78, 1])!
    ctx.drawRadialGradient(
        body,
        startCenter: CGPoint(x: 505, y: 660), startRadius: 0,
        endCenter: CGPoint(x: 560, y: 520), endRadius: 470,
        options: [.drawsAfterEndLocation])
    ctx.restoreGState()

    // Bright core.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 40, color: color(0xFFFFFF, 0.9))
    ctx.addPath(core)
    ctx.clip()
    let coreGradient = CGGradient(
        colorsSpace: space,
        colors: [color(0xFFFFFF), color(0xDFFFF9, 0.95), color(0x8DF3FF, 0.6)] as CFArray,
        locations: [0, 0.5, 1])!
    ctx.drawRadialGradient(
        coreGradient,
        startCenter: CGPoint(x: 512, y: 670), startRadius: 0,
        endCenter: CGPoint(x: 540, y: 600), endRadius: 230,
        options: [.drawsAfterEndLocation])
    ctx.restoreGState()
}

func drawSparkles(_ ctx: CGContext) {
    sparkle(ctx, at: CGPoint(x: 262, y: 300), radius: 46, alpha: 1)
    sparkle(ctx, at: CGPoint(x: 790, y: 286), radius: 30, alpha: 0.9)
    sparkle(ctx, at: CGPoint(x: 780, y: 760), radius: 22, alpha: 0.75)
    sparkle(ctx, at: CGPoint(x: 220, y: 720), radius: 16, alpha: 0.6)
}

try save(canvas(drawGlow), "Glow.png")
try save(canvas(drawWisp), "Wisp.png")
try save(canvas(drawSparkles), "Sparkles.png")

// Flattened icon with the macOS squircle and night background.
try save(canvas { ctx in
    let inset: CGFloat = 100
    let rect = CGRect(x: inset, y: inset, width: CGFloat(size) - inset * 2, height: CGFloat(size) - inset * 2)
    let squircle = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: color(0x000000, 0.45))
    ctx.addPath(squircle)
    ctx.setFillColor(color(0x0B0E24))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let sky = CGGradient(
        colorsSpace: space,
        colors: [color(0x23286B), color(0x0B0E24)] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 512, y: rect.minY), end: CGPoint(x: 512, y: rect.maxY), options: [])

    // Layers are drawn for the full 1024 canvas; scale them into the squircle.
    let scale = rect.width / CGFloat(size)
    ctx.translateBy(x: rect.minX, y: rect.minY)
    ctx.scaleBy(x: scale, y: scale)
    drawGlow(ctx)
    drawWisp(ctx)
    drawSparkles(ctx)
    ctx.restoreGState()
}, "Flat.png")

print("wrote icon layers to \(outDir.path)")
