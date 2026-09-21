// Fit Mac window captures onto the canvas App Store Connect accepts for macOS.
//
// The Mac App Store takes 1280x800, 1440x900, 2560x1600 or 2880x1800 and nothing else, while a
// window capture is whatever size the window was. This centres each capture on a 2880x1800 canvas
// with a neutral background, keeping its aspect ratio and never scaling it up past 1:1 (an upscaled
// screenshot looks soft, and Apple notices).
//
// Usage: swift Scripts/compose-macos-screenshots.swift [inDir] [outDir]
// Defaults: build/screenshots/macOS/raw -> build/screenshots/macOS/store

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let inDir = args.count > 1 ? args[1] : "build/screenshots/macOS/raw"
let outDir = args.count > 2 ? args[2] : "build/screenshots/macOS/store"

let canvas = CGSize(width: 2880, height: 1800)
let margin: CGFloat = 96          // breathing room so the window does not touch the edge
let background = CGColor(red: 0.949, green: 0.949, blue: 0.969, alpha: 1)   // systemGroupedBackground, light

let fm = FileManager.default
guard let names = try? fm.contentsOfDirectory(atPath: inDir) else {
    FileHandle.standardError.write(Data("No such directory: \(inDir)\n".utf8))
    exit(1)
}
let sources = names.filter { $0.lowercased().hasSuffix(".png") }.sorted()
guard !sources.isEmpty else {
    FileHandle.standardError.write(Data("No .png captures in \(inDir)\n".utf8))
    exit(1)
}
try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
// A capture deleted or renamed in raw/ must not leave its composed twin behind: the release
// checklist says to upload everything in store/, so a stale file there ships silently.
for stale in (try? fm.contentsOfDirectory(atPath: outDir))?.filter({ $0.lowercased().hasSuffix(".png") }) ?? [] {
    try? fm.removeItem(atPath: URL(fileURLWithPath: outDir).appendingPathComponent(stale).path)
}

var written = 0
var failed: [String] = []

for name in sources {
    let url = URL(fileURLWithPath: inDir).appendingPathComponent(name)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        FileHandle.standardError.write(Data("Cannot read \(name)\n".utf8))
        failed.append(name)
        continue
    }
    let size = CGSize(width: image.width, height: image.height)
    let fit = min((canvas.width - 2 * margin) / size.width,
                  (canvas.height - 2 * margin) / size.height,
                  1)   // never upscale
    let drawn = CGSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())
    let origin = CGPoint(x: ((canvas.width - drawn.width) / 2).rounded(),
                         y: ((canvas.height - drawn.height) / 2).rounded())

    guard let ctx = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height),
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        FileHandle.standardError.write(Data("Could not make a canvas for \(name)\n".utf8))
        failed.append(name)
        continue
    }
    ctx.setFillColor(background)
    ctx.fill(CGRect(origin: .zero, size: canvas))
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(origin: origin, size: drawn))

    let outURL = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    guard let out = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        FileHandle.standardError.write(Data("Could not write \(name)\n".utf8))
        failed.append(name)
        continue
    }
    CGImageDestinationAddImage(dest, out, nil)
    // Finalize is where a full disk or an unwritable directory actually shows up.
    guard CGImageDestinationFinalize(dest) else {
        FileHandle.standardError.write(Data("Could not finish writing \(name)\n".utf8))
        failed.append(name)
        continue
    }
    written += 1
    let note = fit < 1 ? String(format: " (scaled to %.0f%%)", fit * 100) : ""
    print("  \(name)  \(image.width)x\(image.height) -> \(Int(canvas.width))x\(Int(canvas.height))\(note)")
}

print("Wrote \(written) of \(sources.count) screenshots to \(outDir)")
// A partial set must not look like success: the next step is an upload.
if !failed.isEmpty {
    FileHandle.standardError.write(Data("Failed: \(failed.joined(separator: ", "))\n".utf8))
    exit(1)
}
