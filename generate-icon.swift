#!/usr/bin/env swift
import AppKit
import Foundation

// ArchivePeek icon: stacked archive layers viewed through a magnifying lens ("peek" without extracting).

private struct Palette {
    static let bgTop = NSColor(calibratedRed: 0.14, green: 0.20, blue: 0.30, alpha: 1)
    static let bgBottom = NSColor(calibratedRed: 0.22, green: 0.42, blue: 0.58, alpha: 1)
    static let card = NSColor(calibratedWhite: 0.97, alpha: 1)
    static let cardShadow = NSColor(calibratedWhite: 0.0, alpha: 0.18)
    static let cardTint = NSColor(calibratedRed: 0.90, green: 0.94, blue: 0.98, alpha: 1)
    static let lensFill = NSColor(calibratedRed: 0.35, green: 0.72, blue: 0.88, alpha: 0.22)
    static let lensStroke = NSColor(calibratedWhite: 0.98, alpha: 1)
    static let lensHandle = NSColor(calibratedWhite: 0.92, alpha: 1)
    static let rowPrimary = NSColor(calibratedRed: 0.28, green: 0.52, blue: 0.72, alpha: 1)
    static let rowSecondary = NSColor(calibratedRed: 0.45, green: 0.62, blue: 0.76, alpha: 1)
    static let accent = NSColor(calibratedRed: 0.98, green: 0.62, blue: 0.24, alpha: 1)
}

private func roundedRect(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

private func drawBackground(in rect: NSRect) {
    let gradient = NSGradient(colors: [Palette.bgTop, Palette.bgBottom])!
    gradient.draw(in: rect, angle: 135)

    // Soft edge darkening for depth
    let vignette = NSGradient(colors: [
        NSColor.clear,
        NSColor(calibratedWhite: 0, alpha: 0.14),
    ])!
    vignette.draw(
        from: NSPoint(x: rect.midX, y: rect.midY),
        to: NSPoint(x: rect.midX, y: rect.maxY),
        options: []
    )
}

private func drawStack(scale: CGFloat) {
    let layers: [(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, alpha: CGFloat)] = [
        (248, 248, 420, 500, 0.55),
        (214, 214, 420, 500, 0.78),
        (180, 180, 420, 500, 1.0),
    ]

    for layer in layers {
        let rect = NSRect(
            x: layer.x * scale,
            y: layer.y * scale,
            width: layer.w * scale,
            height: layer.h * scale
        )
        Palette.cardShadow.setFill()
        roundedRect(
            NSRect(x: rect.minX + 10 * scale, y: rect.minY - 12 * scale, width: rect.width, height: rect.height),
            radius: 44 * scale
        ).fill()

        Palette.card.setFill()
        roundedRect(rect, radius: 44 * scale).fill()

        Palette.cardTint.withAlphaComponent(layer.alpha).setFill()
        roundedRect(
            NSRect(x: rect.minX + 28 * scale, y: rect.minY + rect.height - 72 * scale, width: rect.width - 56 * scale, height: 44 * scale),
            radius: 12 * scale
        ).fill()
    }

    // Front card: subtle file rows (visible outside the lens too)
    let front = NSRect(x: 180 * scale, y: 180 * scale, width: 420 * scale, height: 500 * scale)
    let rows: [(y: CGFloat, w: CGFloat, color: NSColor)] = [
        (360, 220, Palette.rowPrimary),
        (300, 280, Palette.rowSecondary),
        (240, 190, Palette.rowSecondary),
        (180, 250, Palette.rowPrimary.withAlphaComponent(0.65)),
    ]
    for row in rows {
        row.color.setFill()
        roundedRect(
            NSRect(x: front.minX + 52 * scale, y: row.y * scale, width: row.w * scale, height: 22 * scale),
            radius: 8 * scale
        ).fill()
    }

    // Small accent tab — archive label cue
    Palette.accent.setFill()
    roundedRect(
        NSRect(x: front.minX + 52 * scale, y: front.maxY - 58 * scale, width: 72 * scale, height: 14 * scale),
        radius: 5 * scale
    ).fill()
}

private func drawMagnifier(scale: CGFloat) {
    let center = NSPoint(x: 620 * scale, y: 430 * scale)
    let radius = 168 * scale

    // Lens glow
    let glow = NSBezierPath(ovalIn: NSRect(
        x: center.x - radius - 18 * scale,
        y: center.y - radius - 18 * scale,
        width: (radius + 18 * scale) * 2,
        height: (radius + 18 * scale) * 2
    ))
    NSColor(calibratedRed: 0.45, green: 0.78, blue: 0.95, alpha: 0.18).setFill()
    glow.fill()

    // Lens interior
    Palette.lensFill.setFill()
    NSBezierPath(ovalIn: NSRect(
        x: center.x - radius,
        y: center.y - radius,
        width: radius * 2,
        height: radius * 2
    )).fill()

    // Magnified rows inside lens (brighter "peek" detail)
    let lensRows: [(y: CGFloat, w: CGFloat)] = [
        (470, 200),
        (410, 260),
        (350, 170),
        (290, 230),
    ]
    for row in lensRows {
        NSColor.white.withAlphaComponent(0.92).setFill()
        roundedRect(
            NSRect(x: center.x - 120 * scale, y: row.y * scale, width: row.w * scale, height: 26 * scale),
            radius: 9 * scale
        ).fill()
    }

    // Lens ring
    let ring = NSBezierPath(ovalIn: NSRect(
        x: center.x - radius,
        y: center.y - radius,
        width: radius * 2,
        height: radius * 2
    ))
    ring.lineWidth = 28 * scale
    Palette.lensStroke.setStroke()
    ring.stroke()

    // Handle
    let handle = NSBezierPath()
    handle.lineWidth = 34 * scale
    handle.lineCapStyle = .round
    handle.move(to: NSPoint(x: center.x + radius * 0.62, y: center.y - radius * 0.62))
    handle.line(to: NSPoint(x: center.x + radius * 1.38, y: center.y - radius * 1.38))
    Palette.lensHandle.setStroke()
    handle.stroke()
}

func renderIcon(size: Int) -> Data? {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    NSGraphicsContext.current?.imageInterpolation = .high
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let scale = CGFloat(size) / 1024.0

    drawBackground(in: rect)
    drawStack(scale: scale)
    drawMagnifier(scale: scale)

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
}

let iconset = "AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

let mappings: [(name: String, size: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for mapping in mappings {
    guard let png = renderIcon(size: mapping.size) else {
        fputs("Failed to render \(mapping.name)\n", stderr)
        exit(1)
    }
    try png.write(to: URL(fileURLWithPath: "\(iconset)/\(mapping.name)"))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset, "-o", "AppIcon.icns"]
try process.run()
process.waitUntilExit()

if process.terminationStatus == 0 {
    print("Created AppIcon.icns")
} else {
    fputs("iconutil failed\n", stderr)
    exit(1)
}