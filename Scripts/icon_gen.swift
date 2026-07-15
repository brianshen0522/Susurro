import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Usage: swift icon_gen.swift <variant> <outfile.png> <size>

func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func linearGradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors as CFArray, locations: locations)!
}

let variant = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]
let S = CGFloat(Double(CommandLine.arguments[3])!)
let pixels = Int(S)

let ctx = CGContext(
    data: nil, width: pixels, height: pixels,
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

// ---- macOS icon grid: 824/1024 squircle, centered ----
let iconRect = CGRect(
    x: S * 100 / 1024, y: S * 100 / 1024,
    width: S * 824 / 1024, height: S * 824 / 1024
)
let cornerRadius = iconRect.width * 0.225
let squircle = CGPath(roundedRect: iconRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

// Drop shadow (baked into macOS icons)
ctx.saveGState()
ctx.setShadow(
    offset: CGSize(width: 0, height: -S * 0.010),
    blur: S * 0.024,
    color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.30)
)
ctx.addPath(squircle)
ctx.setFillColor(srgb(0x0B0C10))
ctx.fillPath()
ctx.restoreGState()

// Background gradient (clipped to squircle)
ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()

switch variant {
case "gold", "line":
    ctx.drawLinearGradient(
        linearGradient([srgb(0x1C1D26), srgb(0x0A0B0F)], [0, 1]),
        start: CGPoint(x: S / 2, y: iconRect.maxY),
        end: CGPoint(x: S / 2, y: iconRect.minY),
        options: []
    )
case "twilight":
    ctx.drawLinearGradient(
        linearGradient([srgb(0x232743), srgb(0x0D0E1A)], [0, 1]),
        start: CGPoint(x: S / 2, y: iconRect.maxY),
        end: CGPoint(x: S / 2, y: iconRect.minY),
        options: []
    )
default:
    fatalError("unknown variant")
}

// Soft glow behind the waveform
let glowColor: CGColor = variant == "twilight" ? srgb(0xAFB6E8, 0.10) : srgb(0xE3C27E, 0.10)
ctx.drawRadialGradient(
    linearGradient([glowColor, srgb(0x000000, 0)], [0, 1]),
    startCenter: CGPoint(x: S * 0.46, y: S * 0.52), startRadius: 0,
    endCenter: CGPoint(x: S * 0.46, y: S * 0.52), endRadius: S * 0.34,
    options: []
)

// ---- Waveform ----
let goldTop = srgb(0xEED9A4)
let goldBottom = srgb(0xB98F45)
let ivoryTop = srgb(0xF4F1E8)
let ivoryBottom = srgb(0xC9C4B4)
let barTop = variant == "twilight" ? ivoryTop : goldTop
let barBottom = variant == "twilight" ? ivoryBottom : goldBottom

func capsule(cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat, alpha: CGFloat) {
    let rect = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    let path = CGPath(roundedRect: rect, cornerWidth: w / 2, cornerHeight: w / 2, transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.setAlpha(alpha)
    ctx.drawLinearGradient(
        linearGradient([barTop, barBottom], [0, 1]),
        start: CGPoint(x: cx, y: rect.maxY),
        end: CGPoint(x: cx, y: rect.minY),
        options: []
    )
    ctx.restoreGState()
}

if variant == "gold" || variant == "twilight" {
    // A whisper: sound rising briefly, then trailing off into silence.
    // Small rendered sizes get fewer, thicker bars so the mark stays legible.
    let heights: [CGFloat]
    let alphas: [CGFloat]
    let barW: CGFloat
    if S <= 64 {
        heights = [0.34, 0.68, 1.00, 0.62, 0.80, 0.42, 0.22, 0.12]
        alphas = [1, 1, 1, 1, 1, 0.85, 0.62, 0.42]
        barW = S * 0.058
    } else {
        heights = [0.26, 0.52, 0.86, 1.00, 0.62, 0.80, 0.46, 0.30, 0.19, 0.12, 0.075, 0.05]
        alphas = [1, 1, 1, 1, 1, 1, 0.92, 0.80, 0.66, 0.52, 0.40, 0.30]
        barW = S * 0.034
    }
    let n = heights.count
    let spanL = S * 0.245
    let spanR = S * 0.775
    let step = (spanR - spanL) / CGFloat(n - 1)
    let maxH = S * 0.335
    let cy = S * 0.5
    for i in 0..<n {
        let h = max(heights[i] * maxH, barW)
        capsule(cx: spanL + CGFloat(i) * step, cy: cy, w: barW, h: h, alpha: alphas[i])
    }
} else if variant == "line" {
    // A continuous decaying wave — one breath.
    let path = CGMutablePath()
    let x0 = S * 0.22, x1 = S * 0.78
    let cy = S * 0.5
    let amp0 = S * 0.145
    let cycles: CGFloat = 3.2
    var first = true
    var x = x0
    while x <= x1 {
        let t = (x - x0) / (x1 - x0)
        let amp = amp0 * pow(1 - t, 1.6) * (0.25 + 0.75 * min(t * 6, 1))
        let y = cy + amp * sin(t * cycles * 2 * .pi)
        if first { path.move(to: CGPoint(x: x, y: y)); first = false }
        else { path.addLine(to: CGPoint(x: x, y: y)) }
        x += 1
    }
    let stroked = path.copy(strokingWithWidth: S * 0.030, lineCap: .round, lineJoin: .round, miterLimit: 10)
    ctx.saveGState()
    ctx.addPath(stroked)
    ctx.clip()
    ctx.drawLinearGradient(
        linearGradient([goldTop, goldBottom], [0, 1]),
        start: CGPoint(x: x0, y: 0),
        end: CGPoint(x: x1, y: 0),
        options: []
    )
    ctx.restoreGState()
    // trailing dots — the sound fading out
    for (i, dx) in [0.815, 0.86].enumerated() {
        let r = S * (0.012 - CGFloat(i) * 0.004)
        ctx.setFillColor(srgb(0xC9A254, 0.55 - CGFloat(i) * 0.2))
        ctx.fillEllipse(in: CGRect(x: S * CGFloat(dx) - r, y: cy - r, width: r * 2, height: r * 2))
    }
}

// Subtle inner top highlight for depth
ctx.addPath(squircle)
ctx.clip()
ctx.drawLinearGradient(
    linearGradient([srgb(0xFFFFFF, 0.07), srgb(0xFFFFFF, 0.0)], [0, 1]),
    start: CGPoint(x: S / 2, y: iconRect.maxY),
    end: CGPoint(x: S / 2, y: iconRect.maxY - iconRect.height * 0.35),
    options: []
)
ctx.restoreGState()

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(outPath)")
