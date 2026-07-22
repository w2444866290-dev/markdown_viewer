#!/usr/bin/env swift

import AppKit
import Foundation

private struct IconVariant {
    let filename: String
    let pixels: Int
}

private let variants = [
    IconVariant(filename: "icon_16x16.png", pixels: 16),
    IconVariant(filename: "icon_16x16@2x.png", pixels: 32),
    IconVariant(filename: "icon_32x32.png", pixels: 32),
    IconVariant(filename: "icon_32x32@2x.png", pixels: 64),
    IconVariant(filename: "icon_128x128.png", pixels: 128),
    IconVariant(filename: "icon_128x128@2x.png", pixels: 256),
    IconVariant(filename: "icon_256x256.png", pixels: 256),
    IconVariant(filename: "icon_256x256@2x.png", pixels: 512),
    IconVariant(filename: "icon_512x512.png", pixels: 512),
    IconVariant(filename: "icon_512x512@2x.png", pixels: 1024),
]

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("generate-debug-icon: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3 else {
    fail("usage: generate-debug-icon.swift INPUT.png OUTPUT.iconset")
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = NSImage(contentsOf: inputURL) else {
    fail("could not load \(inputURL.path)")
}

let fileManager = FileManager.default
try? fileManager.removeItem(at: outputURL)
do {
    try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
} catch {
    fail("could not create \(outputURL.path): \(error)")
}

private func render(pixels: Int) -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fail("could not allocate the \(pixels)px bitmap")
    }

    let scale = CGFloat(pixels) / 1024
    let canvas = NSRect(x: 0, y: 0, width: pixels, height: pixels)
    let badge = NSRect(
        x: 684 * scale,
        y: 70 * scale,
        width: 270 * scale,
        height: 270 * scale
    )

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.clear(canvas)
    source.draw(
        in: canvas,
        from: .zero,
        operation: .copy,
        fraction: 1,
        respectFlipped: false,
        hints: [.interpolation: NSImageInterpolation.high]
    )

    let badgePath = NSBezierPath(
        roundedRect: badge,
        xRadius: 76 * scale,
        yRadius: 76 * scale
    )
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = max(1, 20 * scale)
    shadow.shadowOffset = NSSize(width: 0, height: -8 * scale)
    shadow.set()
    NSColor(srgbRed: 47 / 255, green: 111 / 255, blue: 235 / 255, alpha: 1).setFill()
    badgePath.fill()

    NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0)
    NSColor.white.withAlphaComponent(0.96).setStroke()
    badgePath.lineWidth = max(1, 18 * scale)
    badgePath.stroke()

    let label = NSString(string: "D")
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: max(5, 176 * scale), weight: .black),
        .foregroundColor: NSColor.white,
    ]
    let labelSize = label.size(withAttributes: attributes)
    label.draw(
        at: NSPoint(
            x: badge.midX - labelSize.width / 2,
            y: badge.midY - labelSize.height / 2 - 7 * scale
        ),
        withAttributes: attributes
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        fail("could not encode the \(pixels)px icon")
    }
    return data
}

for variant in variants {
    let destination = outputURL.appendingPathComponent(variant.filename)
    do {
        try render(pixels: variant.pixels).write(to: destination, options: .atomic)
    } catch {
        fail("could not write \(destination.path): \(error)")
    }
}
