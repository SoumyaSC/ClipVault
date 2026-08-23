// make_icon.swift — renders the ClipVault app icon at every required size.
// Run: swift Scripts/make_icon.swift <output-dir>
//
// Design: "Indigo-violet glass" — layered translucent clipboard sheets floating
// over a deep indigo→violet gradient squircle, per Apple's macOS icon grid
// (content ≈ 82.4% of canvas, corner ratio 0.225, generous optical margins).

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outputDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Resources/brand"

try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

private func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [r, g, b, a])!
}

func renderIcon(size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(size)
    let detailed = size >= 64

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    // ── Apple grid: 824/1024 content box, centred ──────────────────────────
    let margin = s * (100.0 / 1024.0)
    let box = CGRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin)
    let radius = box.width * 0.225
    let squircle = CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // ── Soft ambient drop shadow ───────────────────────────────────────────
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.010),
                  blur: s * 0.024,
                  color: color(0.08, 0.04, 0.22, 0.38))
    ctx.addPath(squircle)
    ctx.setFillColor(color(0.2, 0.15, 0.45, 1))
    ctx.fillPath()
    ctx.restoreGState()

    // ── Background gradient, clipped to squircle ───────────────────────────
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    let bgGradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                colors: [color(0.402, 0.365, 0.985),
                                         color(0.338, 0.235, 0.952),
                                         color(0.238, 0.128, 0.800)] as CFArray,
                                locations: [0.0, 0.52, 1.0])!
    ctx.drawLinearGradient(bgGradient,
                           start: CGPoint(x: box.midX, y: box.maxY),
                           end: CGPoint(x: box.midX, y: box.minY),
                           options: [])

    // Top-left radial bloom
    let bloom = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [color(1, 1, 1, 0.15), color(1, 1, 1, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawRadialGradient(bloom,
                           startCenter: CGPoint(x: box.minX + box.width * 0.26, y: box.minY + box.height * 0.88),
                           startRadius: 0,
                           endCenter: CGPoint(x: box.minX + box.width * 0.26, y: box.minY + box.height * 0.88),
                           endRadius: box.width * 0.62,
                           options: [])

    // Violet depth pool at the base
    let depth = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [color(0.135, 0.048, 0.360, 0.75), color(0.135, 0.048, 0.360, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawRadialGradient(depth,
                           startCenter: CGPoint(x: box.midX, y: box.minY),
                           startRadius: 0,
                           endCenter: CGPoint(x: box.midX, y: box.minY),
                           endRadius: box.width * 0.80,
                           options: [])

    // Diagonal glass sheen
    ctx.saveGState()
    let sheenAngle: CGFloat = .pi / 10
    ctx.translateBy(x: box.midX, y: box.midY)
    ctx.rotate(by: sheenAngle)
    let sheenRect = CGRect(x: -box.width, y: box.height * 0.12, width: box.width * 2, height: box.height * 0.42)
    ctx.addRect(sheenRect)
    ctx.clip()
    let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [color(1, 1, 1, 0.10), color(1, 1, 1, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen,
                           start: CGPoint(x: 0, y: box.height * 0.55),
                           end: CGPoint(x: 0, y: box.height * 0.10),
                           options: [])
    ctx.restoreGState()

    ctx.restoreGState()  // end squircle clip

    // Inner rim light
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.setStrokeColor(color(1, 1, 1, 0.30))
    ctx.setLineWidth(max(s * 0.0022, 1))
    ctx.strokePath()
    ctx.restoreGState()

    // ── Clipboard cards ───────────────────────────────────────────────────
    let cardW = box.width * 0.500
    let cardH = box.height * 0.545
    let centerX = box.midX
    let centerY = box.midY - box.height * 0.010

    func roundedCard(_ w: CGFloat, _ h: CGFloat) -> CGPath {
        CGPath(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h),
               cornerWidth: w * 0.085, cornerHeight: w * 0.085, transform: nil)
    }

    // Back sheet — tilted, translucent
    ctx.saveGState()
    ctx.translateBy(x: centerX - cardW * 0.175, y: centerY + cardH * 0.105)
    ctx.rotate(by: 9.5 * .pi / 180)
    let backShadow = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                             components: [0.05, 0.02, 0.15, detailed ? 0.22 : 0.16])!
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.006), blur: s * 0.014, color: backShadow)
    ctx.addPath(roundedCard(cardW * 0.94, cardH * 0.96))
    ctx.setFillColor(color(1, 1, 1, detailed ? 0.42 : 0.50))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.setStrokeColor(color(1, 1, 1, 0.60))
    ctx.setLineWidth(s * (detailed ? 0.0028 : 0.005))
    ctx.strokePath()
    ctx.restoreGState()

    // Front sheet
    ctx.saveGState()
    ctx.translateBy(x: centerX + cardW * 0.055, y: centerY - cardH * 0.045)

    let frontShadow = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              components: [0.06, 0.03, 0.18, 0.26])!
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.007), blur: s * 0.016, color: frontShadow)
    let frontCard = roundedCard(cardW, cardH)
    ctx.addPath(frontCard)
    ctx.setFillColor(color(1, 1, 1, 0.94))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // Content, clipped to the front card
    ctx.saveGState()
    ctx.addPath(frontCard)
    ctx.clip()

    let pad = cardW * 0.105
    let innerW = cardW - 2 * pad

    // Violet media block with abstract landscape
    let imgH = cardH * 0.400
    let imgY = cardH * 0.5 - pad - imgH
    let imgRect = CGRect(x: -innerW / 2, y: imgY, width: innerW, height: imgH)
    let imgRadius = innerW * 0.075
    let imgPath = CGPath(roundedRect: imgRect, cornerWidth: imgRadius, cornerHeight: imgRadius, transform: nil)

    ctx.saveGState()
    ctx.addPath(imgPath)
    ctx.clip()
    let mediaGrad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                               colors: [color(0.582, 0.520, 1.000),
                                        color(0.400, 0.298, 0.900)] as CFArray,
                               locations: [0, 1])!
    ctx.drawLinearGradient(mediaGrad,
                           start: CGPoint(x: imgRect.minX, y: imgRect.maxY),
                           end: CGPoint(x: imgRect.maxX, y: imgRect.minY),
                           options: [])
    if detailed {
        // sun
        ctx.setFillColor(color(1, 1, 1, 0.92))
        ctx.fillEllipse(in: CGRect(x: imgRect.maxX - imgH * 0.42, y: imgRect.maxY - imgH * 0.46,
                                   width: imgH * 0.26, height: imgH * 0.26))
        // far mountain
        ctx.setFillColor(color(1, 1, 1, 0.30))
        ctx.move(to: CGPoint(x: imgRect.minX + imgRect.width * 0.10, y: imgRect.minY))
        ctx.addLine(to: CGPoint(x: imgRect.minX + imgRect.width * 0.42, y: imgRect.maxY - imgH * 0.10))
        ctx.addLine(to: CGPoint(x: imgRect.minX + imgRect.width * 0.74, y: imgRect.minY))
        ctx.closePath()
        ctx.fillPath()
        // near hill
        ctx.setFillColor(color(1, 1, 1, 0.18))
        ctx.move(to: CGPoint(x: imgRect.minX + imgRect.width * 0.38, y: imgRect.minY))
        ctx.addQuadCurve(to: CGPoint(x: imgRect.maxX, y: imgRect.minY + imgH * 0.55),
                         control: CGPoint(x: imgRect.minX + imgRect.width * 0.70, y: imgRect.minY))
        ctx.addLine(to: CGPoint(x: imgRect.maxX, y: imgRect.minY))
        ctx.closePath()
        ctx.fillPath()
    }
    ctx.restoreGState()

    // Text bars
    let barH = max(cardH * 0.058, s * 0.009)
    let gap = cardH * 0.075
    var barY = imgY - gap - barH
    let widths: [CGFloat] = [0.92, 0.70]
    let alphas: [CGFloat] = [0.82, 0.58]
    for (i, frac) in widths.enumerated() {
        let barRect = CGRect(x: -innerW / 2, y: barY, width: innerW * frac, height: barH)
        let barPath = CGPath(roundedRect: barRect, cornerWidth: barH / 2, cornerHeight: barH / 2, transform: nil)
        ctx.addPath(barPath)
        ctx.setFillColor(color(0.290, 0.325, 0.443, alphas[i]))
        ctx.fillPath()
        barY -= gap
    }
    if detailed {
        // accent chip: short violet pill as the third line
        let chipRect = CGRect(x: -innerW / 2, y: barY, width: innerW * 0.34, height: barH)
        let chipPath = CGPath(roundedRect: chipRect, cornerWidth: barH / 2, cornerHeight: barH / 2, transform: nil)
        ctx.addPath(chipPath)
        ctx.setFillColor(color(0.480, 0.380, 0.965, 0.90))
        ctx.fillPath()
    }

    ctx.restoreGState()  // end card content clip

    // Card edge definition
    ctx.addPath(frontCard)
    ctx.setStrokeColor(color(1, 1, 1, 0.85))
    ctx.setLineWidth(s * (detailed ? 0.0016 : 0.004))
    ctx.strokePath()
    ctx.restoreGState()  // end front sheet

    // ── Metal clipboard clamp ──────────────────────────────────────────────
    let clipW = cardW * 0.340
    let clipH = cardH * 0.150

    let clipCenter = CGPoint(x: centerX + cardW * 0.055,
                             y: centerY - cardH * 0.045 + cardH * 0.5 + clipH * 0.28)
    ctx.saveGState()
    ctx.translateBy(x: clipCenter.x, y: clipCenter.y)

    let clipShadow = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                             components: [0.05, 0.03, 0.15, 0.30])!
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.004), blur: s * 0.010, color: clipShadow)

    let clipRect = CGRect(x: -clipW / 2, y: -clipH / 2, width: clipW, height: clipH)
    let clipPath = CGPath(roundedRect: clipRect, cornerWidth: clipH * 0.48, cornerHeight: clipH * 0.48, transform: nil)
    ctx.addPath(clipPath)
    ctx.setFillColor(color(0.30, 0.30, 0.36, 1))  // shadow silhouette colour
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    let metal = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [color(0.976, 0.978, 0.995),
                                    color(0.780, 0.800, 0.878),
                                    color(0.905, 0.915, 0.965)] as CFArray,
                           locations: [0, 0.55, 1])!
    ctx.addPath(clipPath)
    ctx.clip()
    ctx.drawLinearGradient(metal,
                           start: CGPoint(x: 0, y: clipH / 2),
                           end: CGPoint(x: 0, y: -clipH / 2),
                           options: [])

    // slot cut-out
    let slotW = clipW * 0.56
    let slotH = clipH * 0.30
    let slot = CGPath(roundedRect: CGRect(x: -slotW / 2, y: -slotH / 2 - clipH * 0.06, width: slotW, height: slotH),
                      cornerWidth: slotH / 2, cornerHeight: slotH / 2, transform: nil)
    ctx.addPath(slot)
    ctx.setFillColor(color(0.36, 0.33, 0.52, 0.85))
    ctx.fillPath()
    ctx.restoreGState()

    // Outline pass (separate state so stroke is not clipped away)
    ctx.saveGState()
    ctx.translateBy(x: clipCenter.x, y: clipCenter.y)
    ctx.addPath(clipPath)
    ctx.setStrokeColor(color(0.42, 0.43, 0.52, 0.9))
    ctx.setLineWidth(s * (detailed ? 0.0022 : 0.005))
    ctx.strokePath()
    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "make_icon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Failed writing \(url.lastPathComponent)"])
    }
}

// ── Emit every size Apple's iconset requires ────────────────────────────────
let specs: [(String, Int)] = [
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

for (name, px) in specs {
    let image = renderIcon(size: px)
    try writePNG(image, to: URL(fileURLWithPath: outputDir).appendingPathComponent(name))
    print("✓ \(name)")
}

// Marketing master for README / previews
try writePNG(renderIcon(size: 1024), to: URL(fileURLWithPath: outputDir).appendingPathComponent("AppIcon-master-1024.png"))
print("✓ AppIcon-master-1024.png")
print("\nAll icons rendered to \(outputDir)/")
