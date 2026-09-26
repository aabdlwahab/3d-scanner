import Foundation
import simd

/// Replaces the photo texture of plain painted walls and ceilings with a clean, smoothly varying
/// paint color. On flat single-colored surfaces, photo textures show seams, smears and noise where
/// charts from different photos meet; the paint keeps the real color and soft light falloff without
/// them. Patterned surfaces (wallpaper, tiles, wood) and things on the wall that stand out
/// (pictures, switches, sockets) keep their photo texture.
enum SurfacePaint {
    struct Options {
        var sampleWidth = 640
        /// Planes smaller than this keep their texture (m²).
        var minArea: Float = 1.5
        /// Fine-detail level (RMS difference from the smoothed color, 0...255) below which a
        /// surface counts as plain paint.
        var plainThreshold: Float = 9
        /// Triangles differing this much from their surroundings keep their texture.
        var detailThreshold: Float = 28
    }

    struct Result {
        /// Triangles to draw with paint instead of texture.
        var painted: [Bool]
        /// Paint color for every vertex used by painted triangles.
        var colors: [SIMD4<UInt8>?]
        var paintedPlanes = 0
        var texturedPlanes = 0
    }

    static func compute(mesh: RawMesh, adjacency: [Int32], labels: [Int32], frames: [ProcessingFrame], gains: [SIMD3<Float>],
                        triangleToPlane: [Int32], planeCount: Int, options: Options = Options()) -> Result {
        let n = mesh.triangleCount
        var result = Result(painted: [Bool](repeating: false, count: n), colors: [SIMD4<UInt8>?](repeating: nil, count: mesh.vertexCount))
        guard triangleToPlane.count == n, planeCount > 0 else { return result }
        let (_, areas) = MeshMath.faceNormalsAndAreas(positions: mesh.positions, indices: mesh.indices)
        let hasClasses = mesh.classes.count == n
        let paintable: Set<UInt8> = [SurfaceClass.wall.rawValue, SurfaceClass.ceiling.rawValue]

        // Eligible planes: walls and ceilings with enough surface.
        var planeArea = [Float](repeating: 0, count: planeCount)
        var planeWallVotes = [Float](repeating: 0, count: planeCount)
        for t in 0..<n where triangleToPlane[t] >= 0 {
            let p = Int(triangleToPlane[t])
            planeArea[p] += areas[t]
            if !hasClasses || paintable.contains(mesh.classes[t]) { planeWallVotes[p] += areas[t] }
        }
        let eligible = (0..<planeCount).map { planeArea[$0] >= options.minArea && planeWallVotes[$0] > planeArea[$0] * 0.6 }
        let triangles = (0..<n).filter { triangleToPlane[$0] >= 0 && eligible[Int(triangleToPlane[$0])] }
        guard !triangles.isEmpty else { return result }

        // Sample each triangle's color in its photo (with the color-matching gain).
        var color = [SIMD3<Float>](repeating: SIMD3(repeating: -1), count: n)
        var byFrame = [Int32: [Int]]()
        for t in triangles where labels[t] >= 0 { byFrame[labels[t], default: []].append(t) }
        let keys = Array(byFrame.keys)
        color.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: keys.count) { k in
                let frame = frames[Int(keys[k])]
                guard let image = ImageFiles.loadImage(frame.imageURL, maxPixelSize: options.sampleWidth),
                      let pixels = ImageFiles.rgbaPixels(of: image, width: image.width, height: image.height) else { return }
                let w = image.width, h = image.height
                let camera = frame.camera.scaled(toWidth: w, height: h)
                let gain = Int(keys[k]) < gains.count ? gains[Int(keys[k])] : SIMD3(repeating: 1)
                for t in byFrame[keys[k]] ?? [] {
                    let c = (mesh.positions[Int(mesh.indices[3 * t])] + mesh.positions[Int(mesh.indices[3 * t + 1])]
                        + mesh.positions[Int(mesh.indices[3 * t + 2])]) / 3
                    let (pixel, depth) = camera.project(c)
                    let x = Int(pixel.x), y = Int(pixel.y)
                    guard depth > 0, x >= 1, y >= 1, x < w - 1, y < h - 1 else { continue }
                    var sum = SIMD3<Float>.zero
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let o = ((y + dy) * w + (x + dx)) * 4
                            sum += SIMD3(Float(pixels[o]), Float(pixels[o + 1]), Float(pixels[o + 2]))
                        }
                    }
                    out[t] = simd_min(sum / 9 * gain, SIMD3(repeating: 255))
                }
            }
        }

        // Smooth across neighbouring triangles of the same plane (unsampled ones take part too).
        func smooth(_ values: [SIMD3<Float>], iterations: Int) -> [SIMD3<Float>] {
            var current = values
            for _ in 0..<iterations {
                var next = current
                for t in triangles {
                    var sum = SIMD3<Float>.zero, count: Float = 0
                    if current[t].x >= 0 { sum += current[t]; count += 1 }
                    for e in 0..<3 {
                        let m = Int(adjacency[3 * t + e])
                        guard m >= 0, triangleToPlane[m] == triangleToPlane[t], current[m].x >= 0 else { continue }
                        sum += current[m]
                        count += 1
                    }
                    if count > 0 { next[t] = sum / count }
                }
                current = next
            }
            return current
        }
        let smoothed = smooth(color, iterations: 25)

        // Per plane: how much fine detail is left after smoothing?
        func luminance(_ c: SIMD3<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
        var detailSum = [Float](repeating: 0, count: planeCount), detailWeight = [Float](repeating: 0, count: planeCount)
        var standsOut = [Bool](repeating: false, count: n)
        for t in triangles where color[t].x >= 0 && smoothed[t].x >= 0 {
            let d = abs(luminance(color[t]) - luminance(smoothed[t]))
            let p = Int(triangleToPlane[t])
            if d > options.detailThreshold {
                standsOut[t] = true
            } else {
                detailSum[p] += d * d * areas[t]
                detailWeight[p] += areas[t]
            }
        }
        let plain = (0..<planeCount).map { p -> Bool in
            guard eligible[p], detailWeight[p] > 0 else { return false }
            return (detailSum[p] / detailWeight[p]).squareRoot() < options.plainThreshold
        }
        if ProcessInfo.processInfo.environment["SCANSPACE_PAINT_TRACE"] != nil {
            for p in 0..<planeCount where planeArea[p] >= 1 {
                let rms = detailWeight[p] > 0 ? (detailSum[p] / detailWeight[p]).squareRoot() : -1
                print(String(format: "plane %d: %.1f m², wall/ceiling %.0f%%, detail %.1f, %@", p, planeArea[p],
                             planeWallVotes[p] / planeArea[p] * 100, rms, plain[p] ? "paint" : eligible[p] ? "texture" : "skip"))
            }
        }
        result.paintedPlanes = plain.filter { $0 }.count
        result.texturedPlanes = eligible.filter { $0 }.count - result.paintedPlanes

        // Keep a margin of texture around things that stand out.
        var keep = standsOut
        for _ in 0..<2 {
            var grown = keep
            for t in triangles where keep[t] {
                for e in 0..<3 where adjacency[3 * t + e] >= 0 { grown[Int(adjacency[3 * t + e])] = true }
            }
            keep = grown
        }

        // Paint: a stronger smoothing of the sampled colors, ignoring the stand-out triangles.
        var base = color
        for t in triangles where keep[t] { base[t] = SIMD3(repeating: -1) }
        let paint = smooth(base, iterations: 60)
        var sums = [SIMD3<Float>](repeating: .zero, count: mesh.vertexCount), counts = [Float](repeating: 0, count: mesh.vertexCount)
        for t in triangles where plain[Int(triangleToPlane[t])] && !keep[t] && paint[t].x >= 0 {
            result.painted[t] = true
            for c in 0..<3 {
                let v = Int(mesh.indices[3 * t + c])
                sums[v] += paint[t]
                counts[v] += 1
            }
        }
        for v in 0..<mesh.vertexCount where counts[v] > 0 {
            let c = sums[v] / counts[v]
            result.colors[v] = SIMD4(UInt8(min(255, max(0, c.x))), UInt8(min(255, max(0, c.y))), UInt8(min(255, max(0, c.z))), 255)
        }
        return result
    }
}
