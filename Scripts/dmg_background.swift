import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Renders the DMG window background (660x400 pt at 2x). Icon slots in the
// DMG layout: app at (165, 200), Applications at (495, 200) — the arrow and
// captions here line up with those coordinates in make-release.sh.
// Usage: swift dmg_background.swift <outfile.png>

let W: CGFloat = 1320
let H: CGFloat = 800

func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors as CFArray, locations: locations)!
}

let ctx = CGContext(
    data: nil, width: Int(W), height: Int(H),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

// Twilight ground, matching the app icon
ctx.drawLinearGradient(
    gradient([srgb(0x262B4A), srgb(0x0D0E1A)], [0, 1]),
    start: CGPoint(x: W / 2, y: H),
    end: CGPoint(x: W / 2, y: 0),
    options: []
)

// Faint whisper waveform strip across the middle, echoing the icon mark
let gains: [CGFloat] = [0.2, 0.45, 0.3, 0.62, 0.94, 0.55, 0.72, 0.38, 0.52, 0.28, 0.36, 0.18, 0.24, 0.12, 0.15, 0.08]
let barW: CGFloat = 10
let gap: CGFloat = 34
let waveWidth = CGFloat(gains.count - 1) * gap
let waveX = (W - waveWidth) / 2
let waveY: CGFloat = H * 0.5
for (index, gain) in gains.enumerated() {
    let h = max(28 * 2, 260 * gain)
    let rect = CGRect(x: waveX + CGFloat(index) * gap - barW / 2, y: waveY - h / 2, width: barW, height: h)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
    ctx.setFillColor(srgb(0xF4F1E8, 0.05))
    ctx.fillPath()
}

// Text helpers
func draw(_ text: String, font: NSFont, color: NSColor, centerX: CGFloat, baselineY: CGFloat, tracking: CGFloat = 0) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: tracking]
    let str = NSAttributedString(string: text, attributes: attrs)
    let line = CTLineCreateWithAttributedString(str)
    let bounds = CTLineGetBoundsWithOptions(line, [])
    ctx.textPosition = CGPoint(x: centerX - bounds.width / 2, y: baselineY)
    CTLineDraw(line, ctx)
}

// Wordmark + tagline (top center)
draw(
    "Susurro",
    font: NSFont.systemFont(ofSize: 76, weight: .semibold),
    color: NSColor(srgbRed: 0.96, green: 0.95, blue: 0.91, alpha: 1),
    centerX: W / 2, baselineY: H - 170
)
draw(
    "susurro (Spanish) — a whisper",
    font: NSFont.systemFont(ofSize: 26, weight: .regular),
    color: NSColor(srgbRed: 0.96, green: 0.95, blue: 0.91, alpha: 0.45),
    centerX: W / 2, baselineY: H - 224, tracking: 1.5
)

// Arrow between the two icon slots. Icon centers in window points:
// (165, 200) and (495, 200) with the icon occupying ~128pt; leave clearance.
// Window y=200 from top → in this bottom-up context: H - 400 = 400px center.
let iconCenterY: CGFloat = H - 2 * 200
let arrowStart = CGPoint(x: 165 * 2 + 150, y: iconCenterY)
let arrowEnd = CGPoint(x: 495 * 2 - 150, y: iconCenterY)
let arrow = CGMutablePath()
arrow.move(to: arrowStart)
arrow.addLine(to: CGPoint(x: arrowEnd.x - 34, y: iconCenterY))
ctx.addPath(arrow.copy(strokingWithWidth: 7, lineCap: .round, lineJoin: .round, miterLimit: 10))
ctx.setFillColor(srgb(0xF4F1E8, 0.55))
ctx.fillPath()
let head = CGMutablePath()
head.move(to: CGPoint(x: arrowEnd.x - 44, y: iconCenterY + 26))
head.addLine(to: arrowEnd)
head.addLine(to: CGPoint(x: arrowEnd.x - 44, y: iconCenterY - 26))
ctx.addPath(head.copy(strokingWithWidth: 7, lineCap: .round, lineJoin: .round, miterLimit: 10))
ctx.setFillColor(srgb(0xF4F1E8, 0.55))
ctx.fillPath()

// Caption under the icons
draw(
    "Drag Susurro into Applications",
    font: NSFont.systemFont(ofSize: 24, weight: .medium),
    color: NSColor(srgbRed: 0.96, green: 0.95, blue: 0.91, alpha: 0.35),
    centerX: W / 2, baselineY: 92
)

let image = ctx.makeImage()!
let outURL = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
// Tag as 2x so Finder renders it at 660x400 points
CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
CGImageDestinationFinalize(dest)
print("wrote \(outURL.path)")
