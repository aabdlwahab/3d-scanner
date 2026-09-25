import Foundation
import simd

/// Best keyframe for every triangle (the "label" used to texture it).
struct ViewSelection {
    /// Index into the frames array, or -1 when no keyframe sees the triangle well.
    var labels: [Int32]
    /// Score of the best view for each triangle (0 when unlabeled).
    var bestScores: [Float]

    var labeledCount: Int { labels.reduce(0) { $0 + ($1 >= 0 ? 1 : 0) } }
}

/// Picks, for every triangle, the keyframe that shows it largest, most head-on, unoccluded
/// and sharp — then smooths the choice so neighboring triangles share keyframes (fewer seams).
final class ViewSelector {
    struct Options {
        var maxDistance: Float = 5.5
        var imageMargin: Float = 6
        var strictMinCosine: Float = 0.2
        var relaxedMinCosine: Float = 0.02
        var smoothingIterations = 3
        var neighborWeight: Float = 0.35
        /// A neighbor's view is only adopted if it scores at least this fraction of the best view.
        var minRelativeScore: Float = 0.3
    }

    private struct FrameParams {
        var view: simd_float4x4
        var position: SIMD3<Float>
        var fx: Float, fy: Float, cx: Float, cy: Float
        var width: Float, height: Float
        var depthOffset: Int
        var depthWidth: Int, depthHeight: Int
        var depthScale: SIMD2<Float>
        var weight: Float
    }

    private let positions: [SIMD3<Float>]
    private let indices: [UInt32]
    private let faceNormals: [SIMD3<Float>]
    private let options: Options
    private let frameCount: Int
    private let params: UnsafeMutableBufferPointer<FrameParams>
    private let depthStorage: UnsafeMutableBufferPointer<Float>

    init(positions: [SIMD3<Float>], indices: [UInt32], faceNormals: [SIMD3<Float>], frames: [ProcessingFrame], options: Options = Options()) {
        self.positions = positions
        self.indices = indices
        self.faceNormals = faceNormals
        self.options = options
        self.frameCount = frames.count

        let totalDepth = frames.reduce(0) { $0 + ($1.depth.map { $0.width * $0.height } ?? 0) }
        depthStorage = .allocate(capacity: max(1, totalDepth))
        params = .allocate(capacity: max(1, frames.count))
        var offset = 0
        for (k, frame) in frames.enumerated() {
            var depthOffset = -1
            if let depth = frame.depth {
                depthOffset = offset
                _ = UnsafeMutableBufferPointer(rebasing: depthStorage[offset ..< offset + depth.depth.count]).initialize(from: depth.depth)
                offset += depth.depth.count
            }
            let camera = frame.camera
            params[k] = FrameParams(view: camera.worldToCamera, position: camera.position,
                                    fx: camera.fx, fy: camera.fy, cx: camera.cx, cy: camera.cy,
                                    width: Float(camera.width), height: Float(camera.height),
                                    depthOffset: depthOffset,
                                    depthWidth: frame.depth?.width ?? 0, depthHeight: frame.depth?.height ?? 0,
                                    depthScale: frame.depthScale, weight: frame.sharpness)
        }
    }

    deinit {
        params.deallocate()
        depthStorage.deallocate()
    }

    func select(adjacency: [Int32], progress: @escaping (Double) -> Void) -> ViewSelection {
        let triangleCount = indices.count / 3
        var labels = [Int32](repeating: -1, count: triangleCount)
        var scores = [Float](repeating: 0, count: triangleCount)
        guard frameCount > 0, triangleCount > 0 else { return ViewSelection(labels: labels, bestScores: scores) }

        let chunkSize = 1024
        let chunkCount = (triangleCount + chunkSize - 1) / chunkSize
        let reporter = ProgressCounter(total: chunkCount, report: { progress($0 * 0.8) })

        labels.withUnsafeMutableBufferPointer { labelBuffer in
            scores.withUnsafeMutableBufferPointer { scoreBuffer in
                DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
                    let start = chunk * chunkSize
                    let end = min(start + chunkSize, triangleCount)
                    for t in start..<end {
                        var best: Int32 = -1
                        var bestScore: Float = 0
                        // Strict pass first; fall back to relaxed criteria for triangles nobody sees well.
                        var pass = 0
                        while pass < 2 && best < 0 {
                            let strict = pass == 0
                            for k in 0..<frameCount {
                                let s = score(triangle: t, frame: k, strict: strict)
                                if s > bestScore {
                                    bestScore = s
                                    best = Int32(k)
                                }
                            }
                            pass += 1
                        }
                        labelBuffer[t] = best
                        scoreBuffer[t] = bestScore
                    }
                    reporter.increment()
                }
            }
        }

        var selection = ViewSelection(labels: labels, bestScores: scores)
        smooth(&selection, adjacency: adjacency)
        progress(1)
        return selection
    }

    /// Majority-vote smoothing: a triangle adopts a neighbor's keyframe when that keyframe
    /// still shows it reasonably well.
    private func smooth(_ selection: inout ViewSelection, adjacency: [Int32]) {
        let triangleCount = selection.labels.count
        guard adjacency.count == triangleCount * 3 else { return }
        for _ in 0..<options.smoothingIterations {
            let old = selection.labels
            let best = selection.bestScores
            var next = old
            next.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: (triangleCount + 4095) / 4096) { chunk in
                    let start = chunk * 4096
                    let end = min(start + 4096, triangleCount)
                    for t in start..<end {
                        let current = old[t]
                        let bestScore = best[t]
                        guard current >= 0, bestScore > 0 else { continue }
                        let n0 = adjacency[3 * t], n1 = adjacency[3 * t + 1], n2 = adjacency[3 * t + 2]
                        let l0: Int32 = n0 >= 0 ? old[Int(n0)] : -1
                        let l1: Int32 = n1 >= 0 ? old[Int(n1)] : -1
                        let l2: Int32 = n2 >= 0 ? old[Int(n2)] : -1
                        var chosen = current
                        var chosenObjective = -Float.infinity
                        var candidateIndex = 0
                        while candidateIndex < 4 {
                            let candidate: Int32 = candidateIndex == 0 ? current : (candidateIndex == 1 ? l0 : (candidateIndex == 2 ? l1 : l2))
                            candidateIndex += 1
                            guard candidate >= 0 else { continue }
                            let s = score(triangle: t, frame: Int(candidate), strict: true)
                            guard s >= options.minRelativeScore * bestScore else { continue }
                            var agreeing: Float = 0
                            if l0 == candidate { agreeing += 1 }
                            if l1 == candidate { agreeing += 1 }
                            if l2 == candidate { agreeing += 1 }
                            let objective = s / bestScore + options.neighborWeight * agreeing
                            if objective > chosenObjective {
                                chosenObjective = objective
                                chosen = candidate
                            }
                        }
                        out[t] = chosen
                    }
                }
            }
            selection.labels = next
        }
    }

    /// Texture quality score of triangle `t` seen from frame `k`; 0 when unusable.
    @inline(__always)
    func score(triangle t: Int, frame k: Int, strict: Bool) -> Float {
        let f = params[k]
        let p0 = positions[Int(indices[3 * t])]
        let p1 = positions[Int(indices[3 * t + 1])]
        let p2 = positions[Int(indices[3 * t + 2])]
        let centroid = (p0 + p1 + p2) * (1.0 / 3.0)
        let toCamera = f.position - centroid
        let distance = simd_length(toCamera)
        if distance < 0.08 || distance > options.maxDistance { return 0 }
        let cosine = simd_dot(faceNormals[t], toCamera) / distance
        if cosine < (strict ? options.strictMinCosine : options.relaxedMinCosine) { return 0 }

        let margin = strict ? options.imageMargin : 0.5
        guard let q0 = project(p0, f, margin), let q1 = project(p1, f, margin), let q2 = project(p2, f, margin),
              let qc = project(centroid, f, margin) else { return 0 }
        let area = abs((q1.x - q0.x) * (q2.y - q0.y) - (q2.x - q0.x) * (q1.y - q0.y)) * 0.5
        if area <= 0 { return 0 }

        if f.depthOffset >= 0 {
            // Depth tolerance grows with distance (LiDAR noise); relaxed pass forgives more.
            let base: Float = strict ? 0.03 : 0.10
            let slope: Float = strict ? 0.03 : 0.08
            if !visible(qc, f, base + slope * qc.z) || !visible(q0, f, base + slope * q0.z)
                || !visible(q1, f, base + slope * q1.z) || !visible(q2, f, base + slope * q2.z) {
                return 0
            }
        }
        return area * cosine * f.weight
    }

    /// Projects into the image; returns (u, v, depth) or nil when outside the image margins.
    @inline(__always)
    private func project(_ p: SIMD3<Float>, _ f: FrameParams, _ m: Float) -> SIMD3<Float>? {
        let c = f.view * SIMD4(p, 1)
        let z = -c.z
        if z < 0.05 { return nil }
        let u = f.fx * c.x / z + f.cx
        let v = -f.fy * c.y / z + f.cy
        if u < m || v < m || u > f.width - m || v > f.height - m { return nil }
        return SIMD3(u, v, z)
    }

    @inline(__always)
    private func visible(_ q: SIMD3<Float>, _ f: FrameParams, _ tolerance: Float) -> Bool {
        let x = q.x * f.depthScale.x, y = q.y * f.depthScale.y
        let x0 = Int((x - 0.5).rounded(.down)), y0 = Int((y - 0.5).rounded(.down))
        var minDepth = Float.infinity
        let base = depthStorage.baseAddress! + f.depthOffset
        var yy = max(0, y0)
        while yy <= min(f.depthHeight - 1, y0 + 1) {
            var xx = max(0, x0)
            while xx <= min(f.depthWidth - 1, x0 + 1) {
                let d = base[yy * f.depthWidth + xx]
                if d > 0, d < minDepth { minDepth = d }
                xx += 1
            }
            yy += 1
        }
        guard minDepth.isFinite else { return true }
        return q.z <= minDepth + tolerance
    }
}

/// Thread-safe progress counter that reports at most ~50 times.
final class ProgressCounter {
    private let lock = NSLock()
    private let total: Int
    private var done = 0
    private var lastReported = -1
    private let report: (Double) -> Void

    init(total: Int, report: @escaping (Double) -> Void) {
        self.total = max(1, total)
        self.report = report
    }

    func increment() {
        lock.lock()
        done += 1
        let bucket = done * 50 / total
        let shouldReport = bucket != lastReported
        if shouldReport { lastReported = bucket }
        let fraction = Double(done) / Double(total)
        lock.unlock()
        if shouldReport { report(fraction) }
    }
}
