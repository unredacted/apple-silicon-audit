// Generates every app-icon PNG from one drawing: a black chip on an off-white ground (light), or a
// white chip on near-black (dark). No image libraries: CoreGraphics only.
//   swift Tools/gen-icons/gen-icons.swift <output directory>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Palette { let ground: CGColor; let chip: CGColor; let dieInset: CGColor }
let light = Palette(ground: CGColor(red: 0.96, green: 0.96, blue: 0.965, alpha: 1), chip: CGColor(gray: 0.05, alpha: 1), dieInset: CGColor(gray: 0.96, alpha: 1))
let dark = Palette(ground: CGColor(gray: 0.06, alpha: 1), chip: CGColor(gray: 0.95, alpha: 1), dieInset: CGColor(gray: 0.06, alpha: 1))

/// Draws the chip centred in `rect`, sized by the smaller side. `scale` shrinks the glyph for
/// masked icons (the OS rounds the corners; the glyph must clear them).
func drawChip(in ctx: CGContext, rect: CGRect, palette: Palette, glyphScale: CGFloat, transparentGround: Bool = false) {
    if !transparentGround {
        ctx.setFillColor(palette.ground)
        ctx.fill(rect)
    }
    let side = min(rect.width, rect.height) * glyphScale
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let pinLength = side * 0.11, pinWidth = side * 0.045, pinGap = side * 0.03
    let body = CGRect(x: center.x - side / 2 + pinLength + pinGap, y: center.y - side / 2 + pinLength + pinGap,
                      width: side - 2 * (pinLength + pinGap), height: side - 2 * (pinLength + pinGap))
    ctx.setFillColor(palette.chip)
    // Body with softly rounded corners.
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: side * 0.06, cornerHeight: side * 0.06, transform: nil))
    ctx.fillPath()
    // Eight pins per side.
    let pins = 8
    let span = body.width * 0.78
    let step = span / CGFloat(pins - 1)
    let start = body.midX - span / 2
    for i in 0..<pins {
        let x = start + CGFloat(i) * step
        ctx.fill(CGRect(x: x - pinWidth / 2, y: body.maxY + pinGap, width: pinWidth, height: pinLength))
        ctx.fill(CGRect(x: x - pinWidth / 2, y: body.minY - pinGap - pinLength, width: pinWidth, height: pinLength))
        let y = start + CGFloat(i) * step
        ctx.fill(CGRect(x: body.maxX + pinGap, y: y - pinWidth / 2, width: pinLength, height: pinWidth))
        ctx.fill(CGRect(x: body.minX - pinGap - pinLength, y: y - pinWidth / 2, width: pinLength, height: pinWidth))
    }
    // A thin inset square: the die outline.
    let inset = body.insetBy(dx: body.width * 0.2, dy: body.height * 0.2)
    ctx.setStrokeColor(palette.dieInset)
    ctx.setLineWidth(side * 0.022)
    ctx.addPath(CGPath(roundedRect: inset, cornerWidth: side * 0.025, cornerHeight: side * 0.025, transform: nil))
    ctx.strokePath()
    // Small notch: a dot in the die's corner, so orientation reads at a glance.
    ctx.setFillColor(palette.dieInset)
    let dot = side * 0.05
    ctx.fillEllipse(in: CGRect(x: inset.minX + dot * 0.9, y: inset.maxY - dot * 1.9, width: dot, height: dot))
}

func render(width: Int, height: Int, palette: Palette, glyphScale: CGFloat, transparentGround: Bool = false, body: Bool = true) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    if body {
        drawChip(in: ctx, rect: rect, palette: palette, glyphScale: glyphScale, transparentGround: transparentGround)
    } else {
        ctx.setFillColor(palette.ground); ctx.fill(rect)
    }
    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw NSError(domain: "icons", code: 1) }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "icons", code: 2) }
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icons")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
// Square icons (the OS masks the corners): iOS/iPadOS, macOS, watchOS, visionOS layers.
try write(render(width: 1024, height: 1024, palette: light, glyphScale: 0.66), to: out.appendingPathComponent("icon-1024-light.png"))
try write(render(width: 1024, height: 1024, palette: dark, glyphScale: 0.66), to: out.appendingPathComponent("icon-1024-dark.png"))
try write(render(width: 1024, height: 1024, palette: light, glyphScale: 0.66, body: false), to: out.appendingPathComponent("icon-1024-ground.png"))
try write(render(width: 1024, height: 1024, palette: light, glyphScale: 0.66, transparentGround: true), to: out.appendingPathComponent("icon-1024-chip-transparent.png"))
for size in [16, 32, 64, 128, 256, 512] {
    try write(render(width: size, height: size, palette: light, glyphScale: 0.66), to: out.appendingPathComponent("icon-\(size)-light.png"))
}
// Apple TV brand assets: layered app icon (400×240 @1x, 800×480 @2x), App Store icon (1280×768), top shelf.
for (name, w, h) in [("tv-icon-back-1x", 400, 240), ("tv-icon-back-2x", 800, 480), ("tv-appstore-back", 1280, 768),
                     ("tv-shelf-1x", 1920, 720), ("tv-shelf-2x", 3840, 1440), ("tv-shelf-wide-1x", 2320, 720), ("tv-shelf-wide-2x", 4640, 1440)] {
    try write(render(width: w, height: h, palette: light, glyphScale: name.contains("shelf") ? 0.7 : 0.72, body: name.contains("shelf")), to: out.appendingPathComponent("\(name).png"))
}
for (name, w, h) in [("tv-icon-front-1x", 400, 240), ("tv-icon-front-2x", 800, 480), ("tv-appstore-front", 1280, 768)] {
    try write(render(width: w, height: h, palette: light, glyphScale: 0.72, transparentGround: true), to: out.appendingPathComponent("\(name).png"))
}
print("wrote icons to \(out.path)")
