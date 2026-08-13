// Generates Umbra.icns from code, so the icon is reviewable in diffs and
// reproducible without binary design files.
//
//   xcrun swift Tools/make-icon.swift Resources
//
// The mark is an eclipse: a lit disc with a dark body sliding across it, leaving
// the crescent that gives the app its name. Chosen because a crescent survives
// downscaling to 16pt, where most detailed marks turn to mush.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"

// MARK: - Drawing

private func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

private func drawIcon(in context: CGContext, size: CGFloat) {
    let space = CGColorSpaceCreateDeviceRGB()

    // Apple's macOS icon grid: the squircle sits inside a margin rather than
    // bleeding to the edges.
    let margin = size * 0.085
    let plate = CGRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
    let squircle = CGPath(
        roundedRect: plate,
        cornerWidth: plate.width * 0.225,
        cornerHeight: plate.width * 0.225,
        transform: nil
    )

    context.saveGState()
    context.addPath(squircle)
    context.clip()

    if let backdrop = CGGradient(
        colorsSpace: space,
        colors: [color(0x232838), color(0x0B0D14)] as CFArray,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            backdrop,
            start: CGPoint(x: plate.midX, y: plate.maxY),
            end: CGPoint(x: plate.midX, y: plate.minY),
            options: []
        )
    }

    let width = plate.width
    let centre = CGPoint(x: plate.midX - width * 0.045, y: plate.midY)
    // Sized and offset for the 16pt case: a thinner crescent looks more elegant
    // at 512px and disappears entirely in the menu bar.
    let discRadius = width * 0.325

    // Halo, so the lit edge reads as emitted light rather than a flat shape.
    if let halo = CGGradient(
        colorsSpace: space,
        colors: [color(0x8FA8FF, 0.55), color(0x8FA8FF, 0.0)] as CFArray,
        locations: [0, 1]
    ) {
        context.drawRadialGradient(
            halo,
            startCenter: centre, startRadius: discRadius * 0.85,
            endCenter: centre, endRadius: discRadius * 1.85,
            options: []
        )
    }

    // The crescent: draw the disc, then subtract the eclipsing body from it.
    context.beginTransparencyLayer(auxiliaryInfo: nil)

    let disc = CGRect(
        x: centre.x - discRadius, y: centre.y - discRadius,
        width: discRadius * 2, height: discRadius * 2
    )
    context.saveGState()
    context.addEllipse(in: disc)
    context.clip()
    if let face = CGGradient(
        colorsSpace: space,
        colors: [color(0xFFFFFF), color(0xB9C9FF)] as CFArray,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            face,
            start: CGPoint(x: disc.minX, y: disc.maxY),
            end: CGPoint(x: disc.maxX, y: disc.minY),
            options: []
        )
    }
    context.restoreGState()

    context.setBlendMode(.destinationOut)
    context.fillEllipse(in: disc.offsetBy(dx: width * 0.255, dy: width * 0.045))
    context.setBlendMode(.normal)

    context.endTransparencyLayer()
    context.restoreGState()

    // Hairline rim, the convention that keeps icons from dissolving into a dark
    // dock background.
    context.addPath(squircle)
    context.setStrokeColor(color(0xFFFFFF, 0.10))
    context.setLineWidth(max(size * 0.004, 0.5))
    context.strokePath()
}

// MARK: - Output

private func renderPNG(pixels: Int, to url: URL) throws {
    guard let context = CGContext(
        data: nil,
        width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw Failure("could not create a \(pixels)px bitmap context") }

    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)
    drawIcon(in: context, size: CGFloat(pixels))

    guard let image = context.makeImage() else { throw Failure("could not snapshot the \(pixels)px context") }
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { throw Failure("could not open \(url.lastPathComponent) for writing") }

    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw Failure("could not encode \(url.lastPathComponent)") }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

do {
    let fileManager = FileManager.default
    let outputURL = URL(fileURLWithPath: outputDirectory)
    let iconsetURL = outputURL.appendingPathComponent("Umbra.iconset")

    try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
    if fileManager.fileExists(atPath: iconsetURL.path) {
        try fileManager.removeItem(at: iconsetURL)
    }
    try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

    for variant in variants {
        try renderPNG(pixels: variant.pixels, to: iconsetURL.appendingPathComponent("\(variant.name).png"))
    }

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = [
        "-c", "icns", iconsetURL.path,
        "-o", outputURL.appendingPathComponent("Umbra.icns").path,
    ]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else { throw Failure("iconutil exited with \(iconutil.terminationStatus)") }

    // The iconset is an intermediate; only the .icns is committed.
    try fileManager.removeItem(at: iconsetURL)
    print("wrote \(outputDirectory)/Umbra.icns")
} catch {
    FileHandle.standardError.write("make-icon: \(error)\n".data(using: .utf8)!)
    exit(1)
}
