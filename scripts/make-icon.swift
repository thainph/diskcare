// Renders the DiskCare app icon (1024×1024 PNG) with CoreGraphics.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "icon-1024.png"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// macOS icon grid: 824pt body centred on a 1024 canvas, continuous-corner radius ≈ 185.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Drop shadow under the body.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(squircle)
ctx.setFillColor(color(0x2B5BEA))
ctx.fillPath()
ctx.restoreGState()

// Background gradient: blue (top-left) → violet (bottom-right).
ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let background = CGGradient(colorsSpace: space, colors: [color(0x3E8BFF), color(0x4C5CF0), color(0x7B3FE4)] as CFArray,
                            locations: [0, 0.55, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
// Soft top highlight for depth.
let highlight = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(highlight, startCenter: CGPoint(x: 360, y: 860), startRadius: 0,
                       endCenter: CGPoint(x: 360, y: 860), endRadius: 620, options: [])
ctx.restoreGState()

// Disk gauge: 270° track opening at the bottom; the filled part is the used space.
let center = CGPoint(x: 512, y: 505)
let radius: CGFloat = 255
let lineWidth: CGFloat = 78
let start = CGFloat.pi * 1.25        // bottom-left (225°)
let sweep = CGFloat.pi * 1.5         // 270°
let usedFraction: CGFloat = 0.62

ctx.setLineCap(.round)
ctx.setLineWidth(lineWidth)
// Track (free space).
ctx.setStrokeColor(color(0xFFFFFF, 0.22))
ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: start - sweep, clockwise: true)
ctx.strokePath()
// Freed segment in teal, right after the used part, to suggest "space reclaimed".
ctx.setStrokeColor(color(0x5EF2D6))
ctx.addArc(center: center, radius: radius, startAngle: start - sweep * usedFraction,
           endAngle: start - sweep * (usedFraction + 0.16), clockwise: true)
ctx.strokePath()
// Used space in white, with a subtle shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0x1A1060, 0.35))
ctx.setStrokeColor(color(0xFFFFFF))
ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: start - sweep * usedFraction, clockwise: true)
ctx.strokePath()
ctx.restoreGState()

// Four-point sparkle in the middle: "clean". Curves between the tips bow towards a control
// point on the diagonals; a larger `waist` gives a plumper star that stays legible at 16 px.
func sparkle(at p: CGPoint, radius r: CGFloat, waist: CGFloat) -> CGPath {
    let tips = (0..<4).map { i -> CGPoint in
        let angle = CGFloat(i) * .pi / 2 + .pi / 2
        return CGPoint(x: p.x + cos(angle) * r, y: p.y + sin(angle) * r)
    }
    let path = CGMutablePath()
    path.move(to: tips[0])
    for i in 0..<4 {
        let angle = CGFloat(i) * .pi / 2 + .pi / 2 + .pi / 4
        let control = CGPoint(x: p.x + cos(angle) * r * waist, y: p.y + sin(angle) * r * waist)
        path.addQuadCurve(to: tips[(i + 1) % 4], control: control)
    }
    path.closeSubpath()
    return path
}

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -5), blur: 12, color: color(0x1A1060, 0.35))
ctx.setFillColor(color(0xFFFFFF))
ctx.addPath(sparkle(at: CGPoint(x: 512, y: 512), radius: 150, waist: 0.30))
ctx.fillPath()
ctx.setFillColor(color(0xFFFFFF, 0.9))
ctx.addPath(sparkle(at: CGPoint(x: 615, y: 608), radius: 50, waist: 0.32))
ctx.fillPath()
ctx.restoreGState()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
