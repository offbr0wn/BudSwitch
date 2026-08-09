import AppKit
import Foundation

// Draws the BudSwitch app icon and emits every size an .icns needs.
//
// The mark is the panel's route line distilled: a bud mid-track between two poles. The
// app is about the handoff, not the hardware, so the icon shows transit rather than a
// generic headphone glyph.
//
// Everything is drawn in a 1024-unit space and scaled, so each size is rendered natively
// rather than resampled — small sizes stay crisp instead of going muddy.

// MARK: - Geometry

/// Apple's squircle is a superellipse, not a rounded rectangle. Approximating it with
/// corner arcs reads subtly wrong next to real macOS icons.
func squirclePath(in rect: CGRect, n: CGFloat = 5.0) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        // Superellipse: |x/a|^n + |y/b|^n = 1
        let x = cx + a * CGFloat(sign(ct)) * pow(abs(ct), 2 / n)
        let y = cy + b * CGFloat(sign(st)) * pow(abs(st), 2 / n)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func sign(_ v: CGFloat) -> CGFloat { v < 0 ? -1 : 1 }

// MARK: - Palette
//
// Deep indigo → violet. Chosen to sit apart from the blue every other audio utility
// reaches for, while staying dark enough that the white mark carries the contrast.

let bgTop = NSColor(srgbRed: 0.36, green: 0.31, blue: 0.86, alpha: 1)
let bgBottom = NSColor(srgbRed: 0.16, green: 0.13, blue: 0.42, alpha: 1)
let accent = NSColor(srgbRed: 0.55, green: 0.94, blue: 0.99, alpha: 1)

// MARK: - Drawing

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let s = size / 1024  // scale factor from design space
    // macOS icons sit inset in their canvas rather than filling it edge to edge.
    let inset = 100 * s
    let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let squircle = squirclePath(in: body)

    // Background gradient
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [bgTop.cgColor, bgBottom.cgColor] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: body.minX, y: body.maxY),
        end: CGPoint(x: body.maxX, y: body.minY),
        options: []
    )

    // Top highlight, so the surface reads as lit rather than flat.
    let sheen = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor.white.withAlphaComponent(0.22).cgColor,
            NSColor.white.withAlphaComponent(0.0).cgColor,
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        sheen,
        start: CGPoint(x: body.midX, y: body.maxY),
        end: CGPoint(x: body.midX, y: body.midY),
        options: []
    )
    ctx.restoreGState()

    // MARK: Route line

    let cy = body.midY
    let trackInset = 150 * s
    let left = CGPoint(x: body.minX + trackInset, y: cy)
    let right = CGPoint(x: body.maxX - trackInset, y: cy)

    // The bud is deliberately small relative to the track. An earlier pass sized it large
    // and the whole mark read as a camera lens — the track has to dominate for this to
    // say "handoff" rather than "aperture".
    let budR = 78 * s
    let gap = budR + 52 * s

    ctx.setLineCap(.round)

    // Track behind the bud is dim; the leading half is bright, so the mark has a
    // direction of travel rather than being symmetric and inert.
    ctx.setLineWidth(30 * s)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor)
    ctx.move(to: left)
    ctx.addLine(to: CGPoint(x: body.midX - gap, y: cy))
    ctx.strokePath()

    ctx.setStrokeColor(accent.withAlphaComponent(0.95).cgColor)
    ctx.move(to: CGPoint(x: body.midX + gap, y: cy))
    ctx.addLine(to: right)
    ctx.strokePath()

    // Endpoints: origin hollow, destination solid. Reads as "moving to that side".
    ctx.setLineWidth(26 * s)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
    ctx.addArc(center: left, radius: 52 * s, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()

    ctx.setFillColor(accent.cgColor)
    ctx.addArc(center: right, radius: 52 * s, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.fillPath()

    // MARK: Sound arcs
    //
    // Without these the mark is three dots on a line — indistinguishable from a sync or
    // VPN utility. The arcs are what make it audio. They radiate from the bud on both
    // sides, reinforcing that it belongs to neither end exclusively.
    ctx.setLineCap(.round)
    let center = CGPoint(x: body.midX, y: cy)
    for (i, r) in [148, 214].enumerated() {
        let radius = CGFloat(r) * s
        let alpha = 0.55 - Double(i) * 0.22
        ctx.setLineWidth((26 - CGFloat(i) * 5) * s)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(alpha).cgColor)
        // Arc pairs opening left and right, clear of the horizontal track.
        let spread = CGFloat.pi * 0.24
        ctx.addArc(center: center, radius: radius, startAngle: .pi / 2 - spread, endAngle: .pi / 2 + spread, clockwise: false)
        ctx.strokePath()
        ctx.addArc(center: center, radius: radius, startAngle: -.pi / 2 - spread, endAngle: -.pi / 2 + spread, clockwise: false)
        ctx.strokePath()
    }

    // MARK: The bud

    ctx.saveGState()
    ctx.setShadow(
        offset: .zero,
        blur: 54 * s,
        color: accent.withAlphaComponent(0.9).cgColor
    )
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.addArc(center: center, radius: budR, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.fillPath()
    ctx.restoreGState()

    image.unlockFocus()
    return image
}

// MARK: - Emit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// Each entry is rendered at its true pixel size rather than downsampled from 1024.
let targets: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for (name, px) in targets {
    let img = drawIcon(size: px)
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else { continue }
    try? png.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
}
print("wrote \(targets.count) sizes to \(outDir)")
