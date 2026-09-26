import CoreGraphics
import Foundation
import simd

/// Evens out brightness and white balance between keyframes before their pixels are baked into
/// the texture atlas. Photos taken while the camera's exposure and white balance drift show up as
/// a patchwork of lighter and darker (or warmer and cooler) charts on flat walls.
///
/// Wherever two neighbouring triangles take their texture from different keyframes, the shared
/// edge is sampled in both photos. That gives equations `gain[a] · color[a] ≈ gain[b] · color[b]`
/// per RGB channel, solved in log space by weighted least squares with a weak pull towards 1 (so
/// the overall look stays that of the capture).
enum ColorHarmonizer {
    struct Options {
        /// Width of the downscaled keyframes used for sampling.
        var sampleWidth = 480
        /// Gains are clamped to [1/maxGain, maxGain].
        var maxGain: Float = 2.2
        /// Strength of the pull towards gain 1 (relative to one sample).
        var prior: Float = 0.02
        var iterations = 400
        /// 0 keeps the capture's overall white balance; 1 corrects it fully to neutral (the average
        /// sampled surface becomes grey, keeping its brightness). Warm lamps otherwise tint everything.
        var neutralize: Float = 0.3
    }

    /// One RGB gain per keyframe (1 for frames that aren't used or can't be sampled).
    static func gains(positions: [SIMD3<Float>], indices: [UInt32], adjacency: [Int32], labels: [Int32],
                      frames: [ProcessingFrame], options: Options = Options()) -> [SIMD3<Float>] {
        var result = [SIMD3<Float>](repeating: SIMD3(repeating: 1), count: frames.count)
        guard frames.count > 1, adjacency.count == indices.count else { return result }

        // Seam edges: (point, frame a, frame b). The mesh adjacency gives, for each triangle corner
        // edge, the neighbouring triangle (or -1).
        struct Seam { var point: SIMD3<Float>; var a: Int32; var b: Int32 }
        var seams: [Seam] = []
        let triangleCount = labels.count
        for t in 0..<triangleCount {
            let la = labels[t]
            guard la >= 0 else { continue }
            for e in 0..<3 {
                let n = Int(adjacency[3 * t + e])
                guard n > t, labels[n] >= 0, labels[n] != la else { continue }
                let p0 = positions[Int(indices[3 * t + e])], p1 = positions[Int(indices[3 * t + (e + 1) % 3])]
                seams.append(Seam(point: (p0 + p1) * 0.5, a: la, b: labels[n]))
                seams.append(Seam(point: p0 * 0.8 + p1 * 0.2, a: la, b: labels[n]))
                seams.append(Seam(point: p0 * 0.2 + p1 * 0.8, a: la, b: labels[n]))
            }
        }
        guard !seams.isEmpty else { return result }

        // Sample every seam point in both of its photos (downscaled images, 3×3 average).
        var used = Set<Int32>()
        for seam in seams { used.insert(seam.a); used.insert(seam.b) }
        var sampled = [SIMD3<Float>](repeating: SIMD3(repeating: -1), count: seams.count * 2)
        var byFrame = [Int32: [(seam: Int, slot: Int)]]()
        for (i, seam) in seams.enumerated() {
            byFrame[seam.a, default: []].append((i, 0))
            byFrame[seam.b, default: []].append((i, 1))
        }
        let keys = Array(byFrame.keys)
        sampled.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: keys.count) { k in
                let frameIndex = keys[k]
                let frame = frames[Int(frameIndex)]
                guard let image = ImageFiles.loadImage(frame.imageURL, maxPixelSize: options.sampleWidth) else { return }
                let w = image.width, h = image.height
                guard let pixels = ImageFiles.rgbaPixels(of: image, width: w, height: h) else { return }
                let camera = frame.camera.scaled(toWidth: w, height: h)
                for entry in byFrame[frameIndex] ?? [] {
                    let (pixel, depth) = camera.project(seams[entry.seam].point)
                    let x = Int(pixel.x), y = Int(pixel.y)
                    guard depth > 0, x >= 1, y >= 1, x < w - 1, y < h - 1 else { continue }
                    var sum = SIMD3<Float>.zero
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let o = ((y + dy) * w + (x + dx)) * 4
                            sum += SIMD3(Float(pixels[o]), Float(pixels[o + 1]), Float(pixels[o + 2]))
                        }
                    }
                    out[entry.seam * 2 + entry.slot] = sum / 9
                }
            }
        }

        // Pairwise log-ratio observations, skipping clipped or near-black samples.
        struct Pair { var a: Int, b: Int, d: SIMD3<Float>, w: Float }
        var pairs: [Pair] = []
        for (i, seam) in seams.enumerated() {
            let ca = sampled[2 * i], cb = sampled[2 * i + 1]
            guard ca.min() > 12, cb.min() > 12, ca.max() < 250, cb.max() < 250 else { continue }
            let d = SIMD3(log(cb.x / ca.x), log(cb.y / ca.y), log(cb.z / ca.z))
            guard abs(d).max() < 1.2 else { continue } // occlusion or a different surface
            pairs.append(Pair(a: Int(seam.a), b: Int(seam.b), d: d, w: 1))
        }
        guard !pairs.isEmpty else { return result }

        // Weighted least squares by Jacobi iteration, reweighting outliers once (Huber-like).
        var x = [SIMD3<Float>](repeating: .zero, count: frames.count)
        func solve() {
            for _ in 0..<options.iterations {
                var sum = [SIMD3<Float>](repeating: .zero, count: frames.count)
                var weight = [Float](repeating: options.prior, count: frames.count)
                for p in pairs {
                    // x[a] - x[b] ≈ d  →  x[a] ≈ x[b] + d, x[b] ≈ x[a] - d
                    sum[p.a] += (x[p.b] + p.d) * p.w
                    weight[p.a] += p.w
                    sum[p.b] += (x[p.a] - p.d) * p.w
                    weight[p.b] += p.w
                }
                for f in x.indices { x[f] = x[f] * 0.3 + sum[f] / weight[f] * 0.7 }
            }
        }
        solve()
        for i in pairs.indices {
            let r = abs(x[pairs[i].a] - x[pairs[i].b] - pairs[i].d).max()
            pairs[i].w = r < 0.08 ? 1 : 0.08 / r
        }
        solve()

        // Remove any overall shift so the average used photo keeps its brightness.
        let usedFrames = used.map { Int($0) }
        let mean = usedFrames.reduce(SIMD3<Float>.zero) { $0 + x[$1] } / Float(max(1, usedFrames.count))
        let limit = log(options.maxGain)
        for f in usedFrames {
            let v = simd_clamp(x[f] - mean, SIMD3(repeating: -limit), SIMD3(repeating: limit))
            result[f] = SIMD3(exp(v.x), exp(v.y), exp(v.z))
        }

        // Global white balance from the corrected samples (log-average, so bright spots don't dominate).
        if options.neutralize > 0 {
            var logSum = SIMD3<Float>.zero, count: Float = 0
            for (i, seam) in seams.enumerated() {
                for (slot, frame) in [(0, seam.a), (1, seam.b)] {
                    let c = sampled[2 * i + slot] * result[Int(frame)]
                    guard c.min() > 12, c.max() < 250 else { continue }
                    logSum += SIMD3(log(c.x), log(c.y), log(c.z))
                    count += 1
                }
            }
            if count > 50 {
                let average = logSum / count
                let gray = (average.x + average.y + average.z) / 3
                let shift = simd_clamp((SIMD3(repeating: gray) - average) * options.neutralize, SIMD3(repeating: -0.6), SIMD3(repeating: 0.6))
                let factor = SIMD3(exp(shift.x), exp(shift.y), exp(shift.z))
                for f in usedFrames { result[f] *= factor }
            }
        }
        return result
    }

    /// `image` with each channel multiplied by `gain` (a copy; the original is returned for gain ≈ 1).
    static func apply(_ gain: SIMD3<Float>, to image: CGImage) -> CGImage {
        guard abs(gain - 1).max() > 0.01 else { return image }
        let w = image.width, h = image.height
        guard var pixels = ImageFiles.rgbaPixels(of: image, width: w, height: h) else { return image }
        var table = [[UInt8]](repeating: [UInt8](repeating: 0, count: 256), count: 3)
        for c in 0..<3 {
            for v in 0..<256 { table[c][v] = UInt8(min(255, (Float(v) * gain[c]).rounded())) }
        }
        pixels.withUnsafeMutableBufferPointer { p in
            var i = 0
            while i < p.count {
                p[i] = table[0][Int(p[i])]
                p[i + 1] = table[1][Int(p[i + 1])]
                p[i + 2] = table[2][Int(p[i + 2])]
                i += 4
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let result = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: ImageFiles.sRGB,
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return image }
        return result
    }
}
