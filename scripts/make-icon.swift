#!/usr/bin/env swift
// Draws the SmoothDisplay app icon as a 1024x1024 PNG.
//
//   swift scripts/make-icon.swift out.png
//
// CoreGraphics + ImageIO only: no external assets, no network.
// The idea: an ultrawide monitor whose screen shows one bold stroke that starts
// as blocky 1x pixel stairs on the left and turns into a smooth curve on the right.

import CoreGraphics
import Foundation
import ImageIO

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("usage: swift make-icon.swift out.png\n".data(using: .utf8)!)
    exit(2)
}
let outURL = URL(fileURLWithPath: CommandLine.arguments[1])

let S: CGFloat = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("cannot create bitmap context")
}
// Work in a top-left origin, y-down space. Shadow offsets stay in base space (y-up).
ctx.translateBy(x: 0, y: S)
ctx.scaleBy(x: 1, y: -1)
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

// MARK: - Helpers

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
    ])!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
}

func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

/// Rounded square with continuous ("squircle") corners, the outline macOS Big Sur
/// and later use for app icons. Curve constants are the well-known iOS/macOS
/// continuous-corner approximation; each corner spans 1.528 * radius of the edge.
func squircle(_ r: CGRect, radius: CGFloat) -> CGPath {
    let k: CGFloat = 1.52866483
    let rad = min(radius, min(r.width, r.height) / 2 / k)
    // Each corner is described for the top-right corner in units of `rad` and mapped.
    let corners: [(CGFloat, CGFloat) -> CGPoint] = [
        { x, y in CGPoint(x: r.maxX - x * rad, y: r.minY + y * rad) },  // top right
        { x, y in CGPoint(x: r.maxX - y * rad, y: r.maxY - x * rad) },  // bottom right
        { x, y in CGPoint(x: r.minX + x * rad, y: r.maxY - y * rad) },  // bottom left
        { x, y in CGPoint(x: r.minX + y * rad, y: r.minY + x * rad) },  // top left
    ]
    let path = CGMutablePath()
    path.move(to: corners[3](0, k))
    for m in corners {
        path.addLine(to: m(k, 0))
        path.addCurve(to: m(0.66993427, 0.06549600), control1: m(1.08849323, 0), control2: m(0.86840689, 0))
        path.addLine(to: m(0.63149399, 0.07491100))
        path.addCurve(to: m(0.07491100, 0.63149399), control1: m(0.37282392, 0.16905899), control2: m(0.16905899, 0.37282392))
        path.addLine(to: m(0.06549600, 0.66993427))
        path.addCurve(to: m(0, k), control1: m(0, 0.86840689), control2: m(0, 1.08849323))
    }
    path.closeSubpath()
    return path
}

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fillLinear(_ path: CGPath, _ g: CGGradient, from a: CGPoint, to b: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

// MARK: - Tile

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = squircle(tile, radius: 185)

// Soft drop shadow under the tile (offset is in base space: negative = down).
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.38))
ctx.addPath(tilePath)
ctx.setFillColor(color(0x2A2380))
ctx.fillPath()
ctx.restoreGState()

// Deep indigo at the top to blue at the bottom.
fillLinear(tilePath, gradient([(0, color(0x33279A)), (0.55, color(0x2C42C2)), (1, color(0x2170E6))]),
           from: CGPoint(x: 512, y: tile.minY), to: CGPoint(x: 512, y: tile.maxY))
// Gentle sheen on the upper half.
fillLinear(tilePath, gradient([(0, color(0xFFFFFF, 0.08)), (0.5, color(0xFFFFFF, 0))]),
           from: CGPoint(x: 512, y: tile.minY), to: CGPoint(x: 512, y: tile.maxY))

// MARK: - Monitor geometry

let frame = CGRect(x: 162, y: 300, width: 700, height: 330)  // screen inside is 21:9
let bezel: CGFloat = 22, chin: CGFloat = 26
let screen = CGRect(x: frame.minX + bezel, y: frame.minY + bezel,
                    width: frame.width - 2 * bezel, height: frame.height - bezel - chin)
let neckTop = frame.maxY - 4, neckBottom: CGFloat = 698
let base = CGRect(x: 512 - 140, y: neckBottom, width: 280, height: 24)

// Shadow of the whole monitor onto the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 34, color: color(0x0B0A3A, 0.45))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.setFillColor(color(0xFFFFFF))
let neck = CGMutablePath()
neck.move(to: CGPoint(x: 512 - 46, y: neckTop))
neck.addLine(to: CGPoint(x: 512 + 46, y: neckTop))
neck.addLine(to: CGPoint(x: 512 + 64, y: neckBottom + 2))
neck.addLine(to: CGPoint(x: 512 - 64, y: neckBottom + 2))
neck.closeSubpath()
ctx.addPath(neck); ctx.fillPath()
ctx.addPath(roundedRect(base, 12)); ctx.fillPath()
ctx.addPath(roundedRect(frame, 30)); ctx.fillPath()
ctx.endTransparencyLayer()
ctx.restoreGState()

// Stand: neck slightly darker than the body, light base.
fillLinear(neck, gradient([(0, color(0xB9C0D6)), (1, color(0xD9DEEC))]),
           from: CGPoint(x: 512, y: neckTop), to: CGPoint(x: 512, y: neckBottom))
fillLinear(roundedRect(base, 12), gradient([(0, color(0xFFFFFF)), (1, color(0xD5DBEA))]),
           from: CGPoint(x: 512, y: base.minY), to: CGPoint(x: 512, y: base.maxY))

// Body.
fillLinear(roundedRect(frame, 30), gradient([(0, color(0xFFFFFF)), (1, color(0xE2E6F2))]),
           from: CGPoint(x: 512, y: frame.minY), to: CGPoint(x: 512, y: frame.maxY))

// Screen.
let screenPath = roundedRect(screen, 12)
fillLinear(screenPath, gradient([(0, color(0x0C1236)), (1, color(0x18215C))]),
           from: CGPoint(x: 512, y: screen.minY), to: CGPoint(x: 512, y: screen.maxY))

// MARK: - The stroke: jagged on the left, smooth on the right

// Cubic Bezier in screen coordinates, rising from lower left to upper right.
func P(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
    CGPoint(x: screen.minX + u * screen.width, y: screen.minY + v * screen.height)
}
let p0 = P(0.08, 0.76), p1 = P(0.34, 0.60), p2 = P(0.52, 0.12), p3 = P(0.90, 0.22)
func bez(_ t: CGFloat) -> CGPoint {
    let m = 1 - t
    let a = m * m * m, b = 3 * m * m * t, c = 3 * m * t * t, d = t * t * t
    return CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                   y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
}
let samples = (0...800).map { bez(CGFloat($0) / 800) }

let thickness: CGFloat = 76          // smooth stroke width
let pixelReach: CGFloat = 38         // cells whose centre is this close to the curve are lit
let cell = screen.width / 16          // one "pixel" of the jagged part
let splitCol = 8                      // columns left of this are drawn as pixels
let splitX = screen.minX + CGFloat(splitCol) * cell

// Stroke colour runs warm (left) to cool (right).
let strokeStops: [(CGFloat, UInt32)] = [(0, 0xFF6F91), (0.5, 0xC48CFF), (1, 0x6BE4FF)]
func strokeColor(atX x: CGFloat) -> CGColor {
    let t = max(0, min(1, (x - p0.x) / (p3.x - p0.x)))
    var i = 0
    while i < strokeStops.count - 2 && t > strokeStops[i + 1].0 { i += 1 }
    let (t0, c0) = strokeStops[i], (t1, c1) = strokeStops[i + 1]
    let k = (t - t0) / (t1 - t0)
    func ch(_ c: UInt32, _ s: UInt32) -> CGFloat { CGFloat((c >> s) & 0xFF) / 255 }
    return CGColor(colorSpace: space, components: [
        lerp(ch(c0, 16), ch(c1, 16), k), lerp(ch(c0, 8), ch(c1, 8), k), lerp(ch(c0, 0), ch(c1, 0), k), 1,
    ])!
}

ctx.saveGState()
ctx.addPath(screenPath)
ctx.clip()

// Jagged part: rasterize the thick curve on a coarse grid, no anti-aliasing.
ctx.setShouldAntialias(false)
let rows = Int(ceil(screen.height / cell)) + 1
let gridTop = screen.midY - CGFloat(rows) * cell / 2
for col in 0..<splitCol {
    for row in 0..<rows {
        let cx = screen.minX + (CGFloat(col) + 0.5) * cell
        let cy = gridTop + (CGFloat(row) + 0.5) * cell
        var best = CGFloat.greatestFiniteMagnitude, bestIndex = 0
        for (i, p) in samples.enumerated() {
            let d = hypot(p.x - cx, p.y - cy)
            if d < best { best = d; bestIndex = i }
        }
        // bestIndex == 0 means the cell lies behind the start point: keep a flat (butt) start.
        if best <= pixelReach && bestIndex > 0 {
            ctx.setFillColor(strokeColor(atX: cx))
            ctx.fill(CGRect(x: screen.minX + CGFloat(col) * cell, y: gridTop + CGFloat(row) * cell,
                            width: cell, height: cell).integral)
        }
    }
}
ctx.setShouldAntialias(true)

// Smooth part: the same curve from the split onward, soft glow, round cap at the end only.
// It starts a little before the split and is clipped there, so the seam is a clean
// vertical cut on the pixel grid.
let smooth = CGMutablePath()
var started = false
for p in samples where p.x >= splitX - cell {
    if !started { smooth.move(to: p); started = true } else { smooth.addLine(to: p) }
}
ctx.saveGState()
ctx.clip(to: CGRect(x: splitX, y: 0, width: S, height: S))
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 26, color: color(0x6BE4FF, 0.55))
ctx.addPath(smooth)
ctx.setLineWidth(thickness)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.setStrokeColor(color(0x9FB8FF))
ctx.strokePath()
ctx.restoreGState()
// Paint the smooth stroke with the horizontal colour ramp.
ctx.saveGState()
ctx.addPath(smooth)
ctx.setLineWidth(thickness)
ctx.setLineCap(.round)
ctx.replacePathWithStrokedPath()
ctx.clip()
let ramp = gradient(strokeStops.map { ($0.0, color($0.1)) })
ctx.drawLinearGradient(ramp, start: CGPoint(x: p0.x, y: 0), end: CGPoint(x: p3.x, y: 0),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.restoreGState()
ctx.restoreGState() // split clip

ctx.restoreGState() // screen clip

// Thin glass highlight along the top of the screen.
fillLinear(screenPath, gradient([(0, color(0xFFFFFF, 0.07)), (0.35, color(0xFFFFFF, 0))]),
           from: CGPoint(x: 512, y: screen.minY), to: CGPoint(x: 512, y: screen.maxY))

// MARK: - Write PNG

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.png" as CFString, 1, nil) else {
    fatalError("cannot create PNG")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(outURL.path)") }
print("wrote \(outURL.path)")
