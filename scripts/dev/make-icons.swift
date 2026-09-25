// Renders the app icon and the install-page icons with CoreGraphics.
// Usage: swift scripts/dev/make-icons.swift   (run from the repository root)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func drawIcon(in ctx: CGContext) {
    // Work in top-left coordinates.
    ctx.translateBy(x: 0, y: canvas)
    ctx.scaleBy(x: 1, y: -1)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // Background gradient + glow.
    let background = CGGradient(colorsSpace: space, colors: [color(0x23286A), color(0x0B0D1C), color(0x05060C)] as CFArray,
                                locations: [0, 0.6, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: 0), end: CGPoint(x: canvas, y: canvas), options: [])
    let glow = CGGradient(colorsSpace: space, colors: [color(0x6B73FF, 0.55), color(0x6B73FF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 640), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 640), endRadius: 520, options: [])

    // Isometric room corner: back corner c, floor spans +x/+z, walls rise along y.
    let s: CGFloat = 400
    let c = CGPoint(x: 512, y: 480)
    let ax = CGPoint(x: 0.866 * s, y: 0.5 * s)
    let az = CGPoint(x: -0.866 * s, y: 0.5 * s)
    let ay = CGPoint(x: 0, y: -0.88 * s)
    func p(_ u: CGFloat, _ w: CGFloat, _ v: CGFloat) -> CGPoint {
        CGPoint(x: c.x + u * ax.x + w * az.x + v * ay.x, y: c.y + u * ax.y + w * az.y + v * ay.y)
    }
    func quad(_ a: CGPoint, _ b: CGPoint, _ d: CGPoint, _ e: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: [a, b, d, e])
        path.closeSubpath()
        return path
    }

    let floor = quad(p(0, 0, 0), p(1, 0, 0), p(1, 1, 0), p(0, 1, 0))
    let wallX = quad(p(0, 0, 0), p(1, 0, 0), p(1, 0, 1), p(0, 0, 1))
    let wallZ = quad(p(0, 0, 0), p(0, 1, 0), p(0, 1, 1), p(0, 0, 1))

    func fill(_ path: CGPath, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }
    fill(wallX, [color(0x6B73FF, 0.38), color(0x3DD6F5, 0.10)], from: p(0, 0, 1), to: p(1, 0, 0))
    fill(wallZ, [color(0x8A6BFF, 0.34), color(0x6B73FF, 0.08)], from: p(0, 0, 1), to: p(0, 1, 0))
    fill(floor, [color(0x3DD6F5, 0.55), color(0x6B73FF, 0.30)], from: p(0, 0, 0), to: p(1, 1, 0))

    // Triangulated scan mesh.
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(color(0xFFFFFF, 0.30))
    ctx.setLineWidth(3.5)
    let n = 6
    func grid(_ point: (CGFloat, CGFloat) -> CGPoint, rows: Int) {
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n)
            ctx.move(to: point(t, 0)); ctx.addLine(to: point(t, 1))
        }
        for j in 0...rows {
            let t = CGFloat(j) / CGFloat(rows)
            ctx.move(to: point(0, t)); ctx.addLine(to: point(1, t))
        }
        for i in 0..<n {
            for j in 0..<rows {
                ctx.move(to: point(CGFloat(i) / CGFloat(n), CGFloat(j) / CGFloat(rows)))
                ctx.addLine(to: point(CGFloat(i + 1) / CGFloat(n), CGFloat(j + 1) / CGFloat(rows)))
            }
        }
        ctx.strokePath()
    }
    grid({ p($0, $1, 0) }, rows: n)
    grid({ p($0, 0, $1) }, rows: 5)
    grid({ p(0, $0, $1) }, rows: 5)

    // A block of furniture on the floor.
    let b0: CGFloat = 0.52, b1: CGFloat = 0.82, h: CGFloat = 0.22
    let top = quad(p(b0, b0, h), p(b1, b0, h), p(b1, b1, h), p(b0, b1, h))
    let front1 = quad(p(b1, b0, 0), p(b1, b1, 0), p(b1, b1, h), p(b1, b0, h))
    let front2 = quad(p(b0, b1, 0), p(b1, b1, 0), p(b1, b1, h), p(b0, b1, h))
    fill(front1, [color(0x3DD6F5, 0.95), color(0x2C9FD8, 0.95)], from: p(b1, b0, h), to: p(b1, b1, 0))
    fill(front2, [color(0x6B73FF, 0.95), color(0x4B4FD8, 0.95)], from: p(b0, b1, h), to: p(b1, b1, 0))
    fill(top, [color(0xBFF4FF, 1), color(0x8FD9FF, 1)], from: p(b0, b0, h), to: p(b1, b1, h))

    // Room outline.
    ctx.setStrokeColor(color(0xFFFFFF, 0.95))
    ctx.setLineWidth(12)
    let outline = CGMutablePath()
    outline.addLines(between: [p(0, 0, 1), p(0, 0, 0), p(1, 0, 0), p(1, 1, 0), p(0, 1, 0), p(0, 0, 0)])
    outline.move(to: p(1, 0, 0)); outline.addLine(to: p(1, 0, 1))
    outline.move(to: p(0, 1, 0)); outline.addLine(to: p(0, 1, 1))
    outline.move(to: p(0, 0, 1)); outline.addLine(to: p(1, 0, 1))
    outline.move(to: p(0, 0, 1)); outline.addLine(to: p(0, 1, 1))
    ctx.addPath(outline)
    ctx.strokePath()

    // LiDAR scan beam sweeping across the walls.
    let v: CGFloat = 0.6
    let beam = CGMutablePath()
    beam.addLines(between: [p(0, 1, v), p(0, 0, v), p(1, 0, v)])
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 28, color: color(0x3DD6F5, 1))
    ctx.setStrokeColor(color(0x9BEFFF, 1))
    ctx.setLineWidth(9)
    ctx.addPath(beam)
    ctx.strokePath()
    ctx.restoreGState()
    ctx.setFillColor(color(0xFFFFFF, 1))
    for (u, w) in [(0.25, 0.0), (0.55, 0.0), (0.85, 0.0), (0.0, 0.35), (0.0, 0.7)] as [(CGFloat, CGFloat)] {
        let dot = p(u, w, v)
        ctx.fillEllipse(in: CGRect(x: dot.x - 11, y: dot.y - 11, width: 22, height: 22))
    }
}

func render(size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    drawIcon(in: ctx)
    return ctx.makeImage()!
}

func write(_ image: CGImage, _ path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    print("wrote \(path)")
}

write(render(size: 1024), "App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
for size in [512, 180, 57, 64] {
    write(render(size: size), "site/assets/icon-\(size).png")
}
