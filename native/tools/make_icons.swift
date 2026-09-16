#!/usr/bin/env swift
//
// Renders the app icon and the menu bar glyph from the design handoff's
// `App Logo.dc.html`, variant "1a · Плитки" – the squircle with a 3×3 grid of
// glass tiles.
//
//   swift tools/make_icons.swift        # writes Resources/AppIcon.icns + MenuBarIcon.png
//
// This exists because there is no Xcode asset-catalog compiler in this
// Command-Line-Tools-only setup (see SelfTest/SelfTestHarness.swift for the
// same constraint on XCTest), and because a checked-in binary nobody can
// regenerate is worse than a script: when the logo changes, this file is the
// diff. Every number below is the mockup's own, divided by its 160px artboard
// so it scales to any output size.

import AppKit
import Foundation

// MARK: - Design constants (App Logo.dc.html, #1a)

let artboard: CGFloat = 160

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// `linear-gradient(145deg, #b598fa 0%, #9974f7 55%, #7d55e0 100%)`
let bodyGradient = NSGradient(
    colors: [rgb(0xb598fa), rgb(0x9974f7), rgb(0x7d55e0)],
    atLocations: [0, 0.55, 1],
    colorSpace: .sRGB
)!

/// The 3×3 grid's per-tile white opacity, reading left-to-right, top-to-bottom.
/// The centre tile is the solid one the mockup lifts with a shadow.
let tileAlpha: [CGFloat] = [0.32, 0.55, 0.32,
                            0.55, 1.00, 0.80,
                            0.18, 0.80, 0.42]

// MARK: - Drawing

/// A soft radial blob, standing in for the mockup's `filter: blur(...)` on a
/// radial gradient – the gradient is already soft, so blurring it again would
/// only wash it out.
func blob(_ colour: NSColor, centre: CGPoint, radius: CGFloat) {
    let gradient = NSGradient(colors: [colour, colour.withAlphaComponent(0)],
                              atLocations: [0, 1], colorSpace: .sRGB)!
    gradient.draw(fromCenter: centre, radius: 0, toCenter: centre, radius: radius, options: [])
}

func roundedPath(_ rect: CGRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

/// Apple's macOS icon grid: the shape occupies 824 of a 1024 canvas, leaving
/// room for the drop shadow. Drawing edge to edge instead makes the icon read
/// a size larger than every other icon in the Dock.
let bodyFraction: CGFloat = 824.0 / 1024.0

/// The full "1a" mark on a `canvas`-point square, inset to the macOS icon grid.
func drawLogo(canvas: CGFloat) {
    let size = canvas * bodyFraction          // the squircle's own side
    let k = size / artboard                   // scale every mockup number by this
    let inset = (canvas - size) / 2
    let rect = CGRect(x: inset, y: inset, width: size, height: size)
    let corner = 36 * k
    let body = roundedPath(rect, corner)

    // Standard macOS icon shadow, so the mark sits on the Dock rather than
    // floating flat on it.
    NSGraphicsContext.current?.saveGraphicsState()
    let dropShadow = NSShadow()
    dropShadow.shadowColor = rgb(0x1e1932, 0.28)
    dropShadow.shadowBlurRadius = canvas * 0.035
    dropShadow.shadowOffset = NSSize(width: 0, height: -canvas * 0.012)
    dropShadow.set()
    rgb(0x9974f7).setFill()
    body.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGraphicsContext.current?.saveGraphicsState()
    body.addClip()

    // Body. CSS 145deg runs top-left → bottom-right; in Cocoa's y-up space
    // that is an angle of -45°.
    bodyGradient.draw(in: rect, angle: -45)

    // Liquid: white sheen across the top, pink under the bottom-right corner,
    // blue at the right edge. Kept tight and low-alpha on purpose – scaled up
    // to cover the face they grey the whole mark out and the gradient's deep
    // `#7d55e0` corner disappears, which is most of what makes it read as this
    // logo rather than a generic purple square.
    blob(rgb(0xffffff, 0.38), centre: CGPoint(x: rect.minX + size * 0.30, y: rect.maxY),
         radius: size * 0.46)
    blob(rgb(0xf772c9, 0.26), centre: CGPoint(x: rect.maxX, y: rect.minY - size * 0.05),
         radius: size * 0.42)
    blob(rgb(0x5f9df7, 0.20), centre: CGPoint(x: rect.maxX + size * 0.08, y: rect.midY),
         radius: size * 0.36)

    // Inner rim: `inset 0 0 0 1px rgba(255,255,255,0.35)`.
    rgb(0xffffff, 0.35).setStroke()
    let rim = roundedPath(rect.insetBy(dx: k, dy: k), corner - k)
    rim.lineWidth = max(1, 2 * k)
    rim.stroke()

    // 3×3 grid: 26pt cells, 7pt gaps, 7pt radius, centred.
    let cell = 26 * k, gap = 7 * k, tileRadius = 7 * k
    let gridSide = cell * 3 + gap * 2
    let origin = CGPoint(x: rect.midX - gridSide / 2, y: rect.midY - gridSide / 2)

    for row in 0..<3 {
        for col in 0..<3 {
            let index = row * 3 + col
            // Row 0 is the mockup's top row; Cocoa's y grows upward.
            let tile = CGRect(
                x: origin.x + CGFloat(col) * (cell + gap),
                y: origin.y + CGFloat(2 - row) * (cell + gap),
                width: cell, height: cell
            )
            let path = roundedPath(tile, tileRadius)
            let alpha = tileAlpha[index]

            if alpha >= 1 {
                // The centre tile is solid and lifted: `0 3px 10px rgba(60,30,120,0.4)`.
                NSGraphicsContext.current?.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = rgb(0x3c1e78, 0.4)
                shadow.shadowBlurRadius = 10 * k
                shadow.shadowOffset = NSSize(width: 0, height: -3 * k)
                shadow.set()
                rgb(0xffffff).setFill()
                path.fill()
                NSGraphicsContext.current?.restoreGraphicsState()
            } else {
                rgb(0xffffff, alpha).setFill()
                path.fill()
            }

            // `inset 0 1px 1px rgba(255,255,255,·)` – a lit rim on each glass
            // tile. Scaled *with* the tile's own alpha rather than added on
            // top of it: a constant bright rim equalises the nine tiles and
            // the deliberate 0.18 → 1.0 spread the mockup uses stops reading.
            rgb(0xffffff, min(1, alpha * 0.5 + 0.1)).setStroke()
            path.lineWidth = max(0.75, 1 * k)
            path.stroke()
        }
    }

    NSGraphicsContext.current?.restoreGraphicsState()
}

/// The menu bar face. At 18pt the 3×3 grid is illegible, so the mockup's
/// "В МАСШТАБЕ" row collapses it to a single white tile on the purple square.
func drawMenuBarGlyph(size: CGFloat) {
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let body = roundedPath(rect, size * 6 / 20)
    NSGraphicsContext.current?.saveGraphicsState()
    body.addClip()
    bodyGradient.draw(in: rect, angle: -45)
    NSGraphicsContext.current?.restoreGraphicsState()

    let tileSide = size * 9 / 20
    let tile = CGRect(
        x: (size - tileSide) / 2, y: (size - tileSide) / 2,
        width: tileSide, height: tileSide
    )
    rgb(0xffffff).setFill()
    roundedPath(tile, size * 2.5 / 20).fill()
}

// MARK: - Output

func render(size: Int, _ draw: (CGFloat) -> Void) -> Data {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocusFlipped(false)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw(CGFloat(size))
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("error: could not encode \(size)px PNG\n".data(using: .utf8)!)
        exit(1)
    }
    return png
}

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources")
guard fm.fileExists(atPath: resources.path) else {
    FileHandle.standardError.write("error: run from the `native` directory (no ./Resources here)\n".data(using: .utf8)!)
    exit(1)
}

// iconutil insists on exactly these names.
let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(size: px, drawLogo).write(to: iconset.appendingPathComponent(name))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path,
                      "-o", resources.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("error: iconutil failed\n".data(using: .utf8)!)
    exit(1)
}

// 54px = 3× the 18pt display size; AppKit downsamples this one bitmap for
// 1x/2x displays (see MenuBarController.brandIcon).
try render(size: 54, drawMenuBarGlyph).write(to: resources.appendingPathComponent("MenuBarIcon.png"))

print("wrote Resources/AppIcon.icns and Resources/MenuBarIcon.png")
