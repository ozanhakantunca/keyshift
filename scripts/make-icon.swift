#!/usr/bin/env swift
// Draws the Keyshift app icon and builds Resources/AppIcon/Keyshift.icns.
// Usage: swift scripts/make-icon.swift <outdir>
//   <outdir>/Keyshift.iconset/*.png, <outdir>/Keyshift.icns, <outdir>/Keyshift.png (1024 px preview)
import AppKit
import CoreGraphics
import Foundation

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: a)
}

/// Superellipse ("squircle") path approximating the Big Sur icon shape.
func squircle(_ r: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let cx = r.midX, cy = r.midY, a = r.width / 2, b = r.height / 2
    let steps = 360
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Draws the icon in a 1024x1024 design space (y up) into `ctx`.
func drawIcon(_ ctx: CGContext, pixels: Int) {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = squircle(body)

    // Drop shadow under the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: rgb(0x000000, 0.38))
    ctx.addPath(bodyPath)
    ctx.setFillColor(rgb(0x1E1745))
    ctx.fillPath()
    ctx.restoreGState()

    // Gradient background (graphite top -> deep violet bottom).
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [rgb(0x3A3F5C), rgb(0x2B2A5A), rgb(0x1E1745)] as CFArray,
                          locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    let hl = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.18), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(hl, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 600), options: [])
    ctx.restoreGState()

    // Thin inner rim.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.16))
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()

    // Keycap: rounded square with a lighter top face.
    let cap = CGRect(x: 262, y: 262, width: 500, height: 500)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 30, color: rgb(0x000000, 0.45))
    ctx.addPath(roundedRect(cap, 96))
    ctx.setFillColor(rgb(0xB9B3E8))
    ctx.fillPath()
    ctx.restoreGState()
    let face = CGRect(x: 292, y: 302, width: 440, height: 440)
    let facePath = roundedRect(face, 76)
    ctx.saveGState()
    ctx.addPath(facePath)
    ctx.clip()
    let fg = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF), rgb(0xE4E1FA)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(fg, start: CGPoint(x: 512, y: 742), end: CGPoint(x: 512, y: 302), options: [])
    ctx.restoreGState()

    // Glyph on the key: a shift arrow (⇧) in the accent colour.
    let ink = rgb(0xFF8A3D)
    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: 512, y: 660))
    arrow.addLine(to: CGPoint(x: 640, y: 520))
    arrow.addLine(to: CGPoint(x: 566, y: 520))
    arrow.addLine(to: CGPoint(x: 566, y: 400))
    arrow.addLine(to: CGPoint(x: 458, y: 400))
    arrow.addLine(to: CGPoint(x: 458, y: 520))
    arrow.addLine(to: CGPoint(x: 384, y: 520))
    arrow.closeSubpath()
    ctx.saveGState()
    ctx.setLineJoin(.round)
    ctx.setLineWidth(26)
    ctx.setStrokeColor(ink)
    ctx.setFillColor(ink)
    ctx.addPath(arrow)
    ctx.drawPath(using: .fillStroke)
    ctx.restoreGState()

    // Swap hint: small two-way arrows under the glyph (skipped at tiny sizes).
    if pixels >= 64 {
        ctx.saveGState()
        ctx.setStrokeColor(rgb(0x2B2A5A, 0.55))
        ctx.setLineWidth(18)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let y: CGFloat = 352
        ctx.move(to: CGPoint(x: 410, y: y)); ctx.addLine(to: CGPoint(x: 614, y: y))
        ctx.move(to: CGPoint(x: 438, y: y + 24)); ctx.addLine(to: CGPoint(x: 410, y: y)); ctx.addLine(to: CGPoint(x: 438, y: y - 24))
        ctx.move(to: CGPoint(x: 586, y: y + 24)); ctx.addLine(to: CGPoint(x: 614, y: y)); ctx.addLine(to: CGPoint(x: 586, y: y - 24))
        ctx.strokePath()
        ctx.restoreGState()
    }
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gctx
    let ctx = gctx.cgContext
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon(ctx, pixels: pixels)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift scripts/make-icon.swift <outdir>\n".utf8))
    exit(2)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = out.appendingPathComponent("Keyshift.iconset", isDirectory: true)
let fm = FileManager.default
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let specs: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for s in specs {
    try render(pixels: s.px).write(to: iconset.appendingPathComponent("\(s.name).png"))
}
try render(pixels: 1024).write(to: out.appendingPathComponent("Keyshift.png"))

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("Keyshift.icns").path]
try p.run()
p.waitUntilExit()
guard p.terminationStatus == 0 else { exit(1) }
print("Wrote \(out.appendingPathComponent("Keyshift.icns").path)")
