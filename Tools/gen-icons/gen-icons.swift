// Silicon Audit: a silicon die and an inspection lens. Deterministic vector drawing;
// no font, SF Symbol, or external image dependency. Coordinates use a 1024-unit canvas.
// swift Tools/gen-icons/gen-icons.swift <output directory>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}
func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}
func gradient(_ ctx: CGContext, _ path: CGPath, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let fill = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(fill, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}
func ground(_ ctx: CGContext, rect: CGRect, dark: Bool) {
    gradient(ctx, CGPath(rect: rect, transform: nil), dark
             ? [color(0.16, 0.19, 0.25), color(0.065, 0.08, 0.12)]
             : [color(0.995, 0.998, 1), color(0.85, 0.89, 0.95)],
             from: CGPoint(x: rect.minX, y: rect.maxY), to: CGPoint(x: rect.maxX, y: rect.minY))
}
func mark(_ ctx: CGContext, dark: Bool, small: Bool = false) {
    // Four generous contacts per side keep the silhouette legible in the Dock and on Watch.
    let silver = dark ? [color(0.84, 0.9, 1), color(0.37, 0.48, 0.67)]
                      : [color(0.77, 0.83, 0.92), color(0.38, 0.47, 0.61)]
    for v in [CGFloat(359), 461, 563, 665] {
        for rect in [CGRect(x: v - 15, y: 186, width: 30, height: 106),
                     CGRect(x: v - 15, y: 732, width: 30, height: 106),
                     CGRect(x: 186, y: v - 15, width: 106, height: 30),
                     CGRect(x: 732, y: v - 15, width: 106, height: 30)] {
            gradient(ctx, rounded(rect, 15), silver, from: CGPoint(x: 300, y: 820), to: CGPoint(x: 720, y: 200))
        }
    }
    let body = rounded(CGRect(x: 264, y: 264, width: 496, height: 496), 104)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: color(0.06, 0.14, 0.30, dark ? 0.45 : 0.22))
    ctx.setFillColor(silver[1]); ctx.addPath(body); ctx.fillPath()
    ctx.restoreGState()
    gradient(ctx, body, [color(0.98, 0.99, 1), silver[0], silver[1]],
             from: CGPoint(x: 300, y: 760), to: CGPoint(x: 700, y: 264))
    let die = rounded(CGRect(x: 282, y: 282, width: 460, height: 460), 88)
    gradient(ctx, die, dark ? [color(0.25, 0.77, 1), color(0.08, 0.39, 0.94), color(0.10, 0.18, 0.58)]
             : [color(0.27, 0.75, 1), color(0.055, 0.40, 0.95), color(0.08, 0.20, 0.65)],
             from: CGPoint(x: 320, y: 742), to: CGPoint(x: 690, y: 282))
    if !small {
        ctx.setStrokeColor(color(1, 1, 1, 0.3)); ctx.setLineWidth(2)
        ctx.addPath(die); ctx.strokePath()
    }
    // The lens describes inspection rather than promising that the device is secure.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 8, color: color(0.015, 0.16, 0.48, 0.22))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setStrokeColor(color(1, 1, 1))
    ctx.setLineWidth(small ? 39 : 34); ctx.setLineCap(.round)
    ctx.strokeEllipse(in: CGRect(x: 386, y: 430, width: 198, height: 198))
    ctx.move(to: CGPoint(x: 560, y: 454)); ctx.addLine(to: CGPoint(x: 637, y: 377)); ctx.strokePath()
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

/// iOS/Watch backgrounds are opaque and unmasked. macOS includes its rounded tile and
/// transparent outer margin. tvOS/visionOS foregrounds preserve alpha for system layering.
func render(width: Int, height: Int, dark: Bool = false, foreground: Bool = false,
            backgroundOnly: Bool = false, mac: Bool = false, glyphScale: CGFloat = 1) -> CGImage {
    let alpha: CGImageAlphaInfo = foreground || mac ? .premultipliedLast : .noneSkipLast
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: alpha.rawValue)!
    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    ctx.saveGState()
    if mac {
        let tile = rect.insetBy(dx: rect.width * 0.065, dy: rect.height * 0.065)
        let path = rounded(tile, tile.width * 0.225)
        ctx.setShadow(offset: CGSize(width: 0, height: -rect.height * 0.008), blur: rect.width * 0.015,
                      color: color(0.1, 0.14, 0.24, 0.2))
        ctx.setFillColor(color(0.93, 0.96, 1)); ctx.addPath(path); ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.addPath(path); ctx.clip()
    }
    if !foreground { ground(ctx, rect: rect, dark: dark) }
    ctx.restoreGState()
    if !backgroundOnly {
        let side = min(rect.width, rect.height) * glyphScale * (mac ? 0.87 : 1)
        ctx.translateBy(x: (rect.width - side) / 2, y: (rect.height - side) / 2)
        ctx.scaleBy(x: side / 1024, y: side / 1024)
        mark(ctx, dark: dark, small: width <= 32)
    }
    return ctx.makeImage()!
}
func write(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw NSError(domain: "icons", code: 1) }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "icons", code: 2) }
}
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/icons")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
func save(_ name: String, _ image: CGImage) throws { try write(image, to: out.appendingPathComponent(name + ".png")) }
try save("icon-1024-light", render(width: 1024, height: 1024))
try save("icon-1024-dark", render(width: 1024, height: 1024, dark: true))
try save("icon-1024-ground", render(width: 1024, height: 1024, backgroundOnly: true))
try save("icon-1024-chip-transparent", render(width: 1024, height: 1024, foreground: true))
for size in [16, 32, 64, 128, 256, 512, 1024] {
    try save("icon-\(size)-macos", render(width: size, height: size, mac: true))
}
for (name, w, h) in [("tv-icon-back-1x", 400, 240), ("tv-icon-back-2x", 800, 480), ("tv-appstore-back", 1280, 768),
                     ("tv-shelf-1x", 1920, 720), ("tv-shelf-2x", 3840, 1440), ("tv-shelf-wide-1x", 2320, 720), ("tv-shelf-wide-2x", 4640, 1440)] {
    try save(name, render(width: w, height: h, backgroundOnly: !name.contains("shelf"), glyphScale: 0.94))
}
for (name, w, h) in [("tv-icon-front-1x", 400, 240), ("tv-icon-front-2x", 800, 480), ("tv-appstore-front", 1280, 768)] {
    try save(name, render(width: w, height: h, foreground: true, glyphScale: 0.94))
}
// Portable vector logo; same geometry as the app icon, with no platform background or shadow.
let pinRects: [(Int, Int, Int, Int)] = [359, 461, 563, 665].flatMap { v in
    [(v-15,186,30,106), (v-15,732,30,106), (186,v-15,106,30), (732,v-15,106,30)]
}
let pins = pinRects.map { x,y,w,h in "<rect x=\"\(x)\" y=\"\(y)\" width=\"\(w)\" height=\"\(h)\" rx=\"15\"/>" }.joined()
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" role="img" aria-labelledby="title">
<title id="title">Silicon Audit — silicon under inspection</title>
<defs><linearGradient id="metal" x2="1" y2="1"><stop stop-color="#e5edfa"/><stop offset="1" stop-color="#617899"/></linearGradient><linearGradient id="blue" x2="1" y2="1"><stop stop-color="#45bfff"/><stop offset=".5" stop-color="#0e66f2"/><stop offset="1" stop-color="#1433a6"/></linearGradient></defs>
<g fill="url(#metal)">\(pins)<rect x="264" y="264" width="496" height="496" rx="104"/></g>
<rect x="282" y="282" width="460" height="460" rx="88" fill="url(#blue)"/>
<g fill="none" stroke="white" stroke-width="34" stroke-linecap="round"><circle cx="485" cy="495" r="99"/><path d="M560 570 637 647"/></g>
</svg>
"""
try svg.write(to: out.appendingPathComponent("silicon-audit.svg"), atomically: true, encoding: .utf8)
print("wrote icons to \(out.path)")
