import CoreGraphics
import Foundation
import simd

/// Procedural, tileable textures for the furnished plan model (wood floors, tiles, paint, fabric,
/// stone, wood grain). Generated once per look and cached as PNG files.
enum MaterialTextures {
    enum Kind: Hashable {
        /// Floor planks; one texture covers `tile` meters.
        case planks(SIMD3<Float>)
        case tiles(SIMD3<Float>, grout: SIMD3<Float>, count: Int)
        case paint(SIMD3<Float>)
        case fabric(SIMD3<Float>)
        case stone(SIMD3<Float>)
        case grain(SIMD3<Float>)

        var key: String {
            func hex(_ c: SIMD3<Float>) -> String {
                String(format: "%02x%02x%02x", Int(c.x * 255), Int(c.y * 255), Int(c.z * 255))
            }
            switch self {
            case .planks(let c): return "planks-\(hex(c))"
            case .tiles(let c, let g, let n): return "tiles-\(hex(c))-\(hex(g))-\(n)"
            case .paint(let c): return "paint-\(hex(c))"
            case .fabric(let c): return "fabric-\(hex(c))"
            case .stone(let c): return "stone-\(hex(c))"
            case .grain(let c): return "grain-\(hex(c))"
            }
        }
    }

    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("PlanMaterials", isDirectory: true)
    }

    /// PNG for `kind`, generated on first use. Nil if it can't be written.
    static func url(for kind: Kind, size: Int = 512) -> URL? {
        let url = directory.appendingPathComponent("v3-\(kind.key)-\(size).png")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let image = render(kind, size: size) else { return nil }
        do {
            try ImageFiles.writePNG(image, to: url)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Rendering

    static func render(_ kind: Kind, size n: Int) -> CGImage? {
        var pixels = [UInt8](repeating: 255, count: n * n * 4)
        var noise = TileNoise(seed: UInt32(truncatingIfNeeded: kind.key.hashValue & 0x7fff_ffff) | 1, period: 8)
        for y in 0..<n {
            for x in 0..<n {
                let u = Float(x) / Float(n), v = Float(y) / Float(n)
                let c = shade(kind, u: u, v: v, noise: &noise)
                let i = (y * n + x) * 4
                pixels[i] = UInt8(max(0, min(255, c.x * 255)))
                pixels[i + 1] = UInt8(max(0, min(255, c.y * 255)))
                pixels[i + 2] = UInt8(max(0, min(255, c.z * 255)))
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func shade(_ kind: Kind, u: Float, v: Float, noise: inout TileNoise) -> SIMD3<Float> {
        switch kind {
        case .planks(let base):
            // Six rows of planks, each row split into staggered boards.
            let rows: Float = 6
            let row = floor(v * rows)
            let offset = fract(row * 0.37) * 0.5
            let board = floor((u + offset) * 2)
            let seedValue = hash(row * 7 + board * 13)
            let tint = 0.93 + 0.12 * seedValue
            let grain = noise.fbm(u * 3 + seedValue * 5, v * 40) * 0.5 + sin((v * rows - row) * 30 + noise.value(u * 6, v * 6) * 6) * 0.04
            var c = base * (tint + grain * 0.35)
            let edgeV = min(fract(v * rows), 1 - fract(v * rows)), edgeU = min(fract((u + offset) * 2), 1 - fract((u + offset) * 2))
            if edgeV < 0.02 || edgeU < 0.004 { c *= 0.55 }
            return c
        case .tiles(let base, let grout, let count):
            let fu = fract(u * Float(count)), fv = fract(v * Float(count))
            if min(fu, 1 - fu) < 0.025 || min(fv, 1 - fv) < 0.025 { return grout }
            let cell = hash(floor(u * Float(count)) * 17 + floor(v * Float(count)) * 31)
            return base * (0.94 + 0.08 * cell + noise.fbm(u * 8, v * 8) * 0.05)
        case .paint(let base):
            return base * (0.975 + noise.fbm(u * 16, v * 16) * 0.05)
        case .fabric(let base):
            let weave = (sin(u * 2 * .pi * 96) * sin(v * 2 * .pi * 96)) * 0.04
            return base * (0.95 + weave + noise.fbm(u * 10, v * 10) * 0.08)
        case .stone(let base):
            let vein = abs(sin((u + noise.fbm(u * 3, v * 3) * 0.6) * 2 * .pi * 2))
            let line = vein < 0.06 ? 0.82 : 1
            return base * Float(line) * (0.96 + noise.fbm(u * 12, v * 12) * 0.06)
        case .grain(let base):
            // Long fibres along u: fine streaks plus a few wavy growth lines.
            let streak = noise.fbm(u * 2, v * 48) * 0.16
            let rings = sin((v * 6 + noise.fbm(u * 1, v * 2) * 0.8) * 2 * .pi) * 0.035
            return base * (0.97 + streak + rings)
        }
    }

    private static func fract(_ x: Float) -> Float { x - floor(x) }

    private static func hash(_ x: Float) -> Float {
        let s = sin(x * 12.9898) * 43758.5453
        return s - floor(s)
    }
}

/// Periodic value noise (tiles seamlessly over 0...1).
struct TileNoise {
    private var values: [Float]
    let period: Int

    init(seed: UInt32, period: Int) {
        self.period = period
        var state = seed
        values = (0..<(period * period)).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(state >> 8) / Float(1 << 24)
        }
    }

    func value(_ x: Float, _ y: Float) -> Float {
        let p = Float(period)
        let fx = x * p, fy = y * p
        let x0 = Int(floor(fx)), y0 = Int(floor(fy))
        let tx = fx - floor(fx), ty = fy - floor(fy)
        func at(_ i: Int, _ j: Int) -> Float {
            let a = ((i % period) + period) % period, b = ((j % period) + period) % period
            return values[b * period + a]
        }
        let sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty)
        let top = at(x0, y0) + (at(x0 + 1, y0) - at(x0, y0)) * sx
        let bottom = at(x0, y0 + 1) + (at(x0 + 1, y0 + 1) - at(x0, y0 + 1)) * sx
        return top + (bottom - top) * sy - 0.5
    }

    /// Three octaves; integer frequency multiples keep it periodic.
    mutating func fbm(_ x: Float, _ y: Float) -> Float {
        value(x, y) * 0.6 + value(x * 2, y * 2) * 0.3 + value(x * 4, y * 4) * 0.15
    }
}
