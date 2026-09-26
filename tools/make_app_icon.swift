// Builds the iOS app icon from the Android launcher artwork.
//
// iOS wants one opaque 1024-pixel square and rounds the corners itself.
// The Android artwork is the pixel-art monitor pre-padded for an adaptive
// icon's safe zone, which on iOS would leave it floating small in the
// middle, so it is enlarged until the monitor fills most of the square, on
// the same near-black the Android launcher puts behind it. Scaled by
// nearest neighbour: smoothing pixel art turns every edge to mush.
//
//     swift tools/make_app_icon.swift <ic_launcher_monitor.png> <out.png>

import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3,
      let source = NSImage(contentsOfFile: arguments[1]),
      let art = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    FileHandle.standardError.write("usage: make_app_icon.swift <in.png> <out.png>\n".data(using: .utf8)!)
    exit(1)
}

let side = 1024
/// How much of the icon the monitor's width should take: its frame runs
/// across about 48% of the Android canvas.
let fill = 0.74
let monitorShare = 0.48
let scale = Double(side) * fill / (Double(art.width) * monitorShare)

let context = CGContext(
    data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
)!
context.setFillColor(CGColor(srgbRed: 8 / 255, green: 8 / 255, blue: 9 / 255, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: side, height: side))
context.interpolationQuality = .none
let drawn = Double(art.width) * scale
// A touch below centre, because the stand makes the artwork top-heavy.
let origin = (Double(side) - drawn) / 2
context.draw(art, in: CGRect(x: origin, y: origin - Double(side) * 0.02, width: drawn, height: drawn))

let output = NSBitmapImageRep(cgImage: context.makeImage()!)
try! output.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[2]))
print("Wrote \(arguments[2])")
