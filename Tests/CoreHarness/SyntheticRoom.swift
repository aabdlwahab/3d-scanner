import CoreGraphics
import Foundation
import simd

/// A procedurally textured box room with a table, used to generate fake LiDAR captures
/// (mesh + keyframes + depth maps) with exact ground truth.
struct SyntheticRoom {
    let roomMin = SIMD3<Float>(-2.0, 0.0, -1.5)
    let roomMax = SIMD3<Float>(2.0, 2.6, 1.5)
    let tableMin = SIMD3<Float>(-0.5, 0.0, -0.3)
    let tableMax = SIMD3<Float>(0.5, 0.75, 0.3)

    private let stripes: [SIMD3<Float>] = [
        SIMD3(220, 60, 60), SIMD3(240, 200, 60), SIMD3(60, 180, 90), SIMD3(60, 120, 230), SIMD3(170, 80, 200),
    ]

    // MARK: Ground truth color

    func color(at p: SIMD3<Float>) -> SIMD3<Float> {
        let eps: Float = 0.01
        let onTable = p.x >= tableMin.x - eps && p.x <= tableMax.x + eps && p.z >= tableMin.z - eps
            && p.z <= tableMax.z + eps && p.y <= tableMax.y + eps && p.y > eps
        if onTable {
            let band = Int(((p.x + p.z) / 0.1).rounded(.down)) & 1
            return band == 0 ? SIMD3(40, 170, 90) : SIMD3(230, 240, 235)
        }
        if abs(p.y - roomMin.y) < eps {
            let checker = (Int((p.x / 0.25).rounded(.down)) + Int((p.z / 0.25).rounded(.down))) & 1
            return checker == 0 ? SIMD3(205, 170, 120) : SIMD3(90, 60, 40)
        }
        if abs(p.y - roomMax.y) < eps {
            let fx = p.x / 0.5 - (p.x / 0.5).rounded(.down)
            let fz = p.z / 0.5 - (p.z / 0.5).rounded(.down)
            return (fx < 0.06 || fz < 0.06) ? SIMD3(50, 50, 60) : SIMD3(230, 230, 225)
        }
        if abs(p.z - roomMin.z) < eps {
            return stripes[Int((p.y / 0.2).rounded(.down)).clamped(0, 99) % stripes.count]
        }
        if abs(p.z - roomMax.z) < eps {
            return stripes[(Int(((p.x + 10) / 0.2).rounded(.down)) + 2) % stripes.count]
        }
        if abs(p.x - roomMin.x) < eps {
            let checker = (Int(((p.y) / 0.3).rounded(.down)) + Int(((p.z + 10) / 0.3).rounded(.down))) & 1
            return checker == 0 ? SIMD3(200, 40, 40) : SIMD3(245, 245, 245)
        }
        let checker = (Int(((p.y) / 0.4).rounded(.down)) + Int(((p.z + 10) / 0.4).rounded(.down))) & 1
        return checker == 0 ? SIMD3(40, 70, 200) : SIMD3(250, 220, 60)
    }

    // MARK: Ray casting

    /// Nearest hit distance along a normalized ray starting inside the room.
    func raycast(origin o: SIMD3<Float>, direction d: SIMD3<Float>) -> Float? {
        // Exit point of the room box (origin is inside).
        var tRoom = Float.infinity
        for axis in 0..<3 where abs(d[axis]) > 1e-8 {
            let bound = d[axis] > 0 ? roomMax[axis] : roomMin[axis]
            let t = (bound - o[axis]) / d[axis]
            if t > 0 { tRoom = min(tRoom, t) }
        }
        // Entry point of the table box (slab method).
        var tNear = -Float.infinity, tFar = Float.infinity
        var hitsTable = true
        for axis in 0..<3 {
            if abs(d[axis]) < 1e-8 {
                if o[axis] < tableMin[axis] || o[axis] > tableMax[axis] { hitsTable = false }
                continue
            }
            var t1 = (tableMin[axis] - o[axis]) / d[axis]
            var t2 = (tableMax[axis] - o[axis]) / d[axis]
            if t1 > t2 { swap(&t1, &t2) }
            tNear = max(tNear, t1)
            tFar = min(tFar, t2)
        }
        if hitsTable, tNear <= tFar, tNear > 0 { return min(tRoom, tNear) }
        return tRoom.isFinite ? tRoom : nil
    }

    // MARK: Mesh

    /// ARKit-like mesh: separate chunks per face (duplicated seam vertices), small noise.
    func makeMesh(cell: Float = 0.05, seed: UInt64 = 7) -> RawMesh {
        var rng = SplitMix(seed: seed)
        var mesh = RawMesh()
        func addFace(origin: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>, lengthU: Float, lengthV: Float, cls: SurfaceClass) {
            let normal = simd_normalize(simd_cross(u, v))
            let nu = max(1, Int((lengthU / cell).rounded())), nv = max(1, Int((lengthV / cell).rounded()))
            let base = UInt32(mesh.positions.count)
            for j in 0...nv {
                for i in 0...nu {
                    var p = origin + u * (lengthU * Float(i) / Float(nu)) + v * (lengthV * Float(j) / Float(nv))
                    let interior = i > 0 && j > 0 && i < nu && j < nv
                    if interior { p += normal * (rng.nextFloat() - 0.5) * 0.003 }
                    mesh.positions.append(p)
                    mesh.normals.append(simd_normalize(normal + SIMD3(rng.nextFloat() - 0.5, rng.nextFloat() - 0.5, rng.nextFloat() - 0.5) * 0.05))
                }
            }
            let row = UInt32(nu + 1)
            for j in 0..<UInt32(nv) {
                for i in 0..<UInt32(nu) {
                    let a = base + j * row + i, b = a + 1, c = a + row + 1, d = a + row
                    mesh.indices.append(contentsOf: [a, b, c, a, c, d])
                    mesh.classes.append(contentsOf: [cls.rawValue, cls.rawValue])
                }
            }
        }
        let lo = roomMin, hi = roomMax, size = roomMax - roomMin
        // Room faces with inward normals (u × v = inward normal).
        addFace(origin: SIMD3(lo.x, lo.y, hi.z), u: SIMD3(1, 0, 0), v: SIMD3(0, 0, -1), lengthU: size.x, lengthV: size.z, cls: .floor)
        addFace(origin: SIMD3(lo.x, hi.y, lo.z), u: SIMD3(1, 0, 0), v: SIMD3(0, 0, 1), lengthU: size.x, lengthV: size.z, cls: .ceiling)
        addFace(origin: SIMD3(lo.x, lo.y, lo.z), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), lengthU: size.x, lengthV: size.y, cls: .wall)
        addFace(origin: SIMD3(hi.x, lo.y, hi.z), u: SIMD3(-1, 0, 0), v: SIMD3(0, 1, 0), lengthU: size.x, lengthV: size.y, cls: .wall)
        addFace(origin: SIMD3(lo.x, lo.y, hi.z), u: SIMD3(0, 0, -1), v: SIMD3(0, 1, 0), lengthU: size.z, lengthV: size.y, cls: .wall)
        addFace(origin: SIMD3(hi.x, lo.y, lo.z), u: SIMD3(0, 0, 1), v: SIMD3(0, 1, 0), lengthU: size.z, lengthV: size.y, cls: .wall)
        // Table faces with outward normals.
        let t0 = tableMin, t1 = tableMax, ts = tableMax - tableMin
        addFace(origin: SIMD3(t0.x, t1.y, t1.z), u: SIMD3(1, 0, 0), v: SIMD3(0, 0, -1), lengthU: ts.x, lengthV: ts.z, cls: .table)
        addFace(origin: SIMD3(t0.x, t0.y, t1.z), u: SIMD3(1, 0, 0), v: SIMD3(0, 1, 0), lengthU: ts.x, lengthV: ts.y, cls: .table)
        addFace(origin: SIMD3(t1.x, t0.y, t0.z), u: SIMD3(-1, 0, 0), v: SIMD3(0, 1, 0), lengthU: ts.x, lengthV: ts.y, cls: .table)
        addFace(origin: SIMD3(t0.x, t0.y, t0.z), u: SIMD3(0, 0, 1), v: SIMD3(0, 1, 0), lengthU: ts.z, lengthV: ts.y, cls: .table)
        addFace(origin: SIMD3(t1.x, t0.y, t1.z), u: SIMD3(0, 0, -1), v: SIMD3(0, 1, 0), lengthU: ts.z, lengthV: ts.y, cls: .table)
        return mesh
    }

    // MARK: Capture

    struct Pose {
        var position: SIMD3<Float>
        var yaw: Float
        var pitch: Float

        var cameraToWorld: simd_float4x4 {
            let r = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0)))
            var m = r
            m.columns.3 = SIMD4(position, 1)
            return m
        }

        static func looking(from p: SIMD3<Float>, at target: SIMD3<Float>) -> Pose {
            let d = simd_normalize(target - p)
            return Pose(position: p, yaw: atan2(-d.x, -d.z), pitch: asin(d.y))
        }
    }

    /// Walks a loop around the room; at every stop the "user" sweeps the phone from floor to ceiling.
    func trajectory(count: Int) -> [Pose] {
        var poses = [Pose]()
        let pitches: [Float] = [-0.65, -0.15, 0.35, 0.95]
        let stops = max(1, count / pitches.count)
        for stop in 0..<stops {
            let theta = Float(stop) / Float(stops) * 2 * .pi
            let p = SIMD3<Float>(0.9 * cos(theta), 1.45, 0.7 * sin(theta))
            for (j, pitch) in pitches.enumerated() {
                poses.append(Pose(position: p, yaw: -theta - .pi / 2 + 0.2 * sin(Float(stop * 4 + j)), pitch: pitch))
            }
        }
        // Frames looking at the table from around the room.
        for i in 0..<12 {
            let theta = Float(i) / 12 * 2 * .pi
            let p = SIMD3<Float>(1.5 * cos(theta), 1.4, 1.1 * sin(theta))
            poses.append(.looking(from: p, at: SIMD3(0, 0.45, 0)))
        }
        return poses
    }

    /// Renders keyframes (JPEG + Float32 depth + confidence) into `files.framesDirectory`
    /// and writes `frames.json` and `mesh.bin`, exactly like the app's recorder.
    func writeCapture(to files: ScanFiles, frameCount: Int, width: Int = 640, height: Int = 480) throws {
        try files.createDirectories()
        try makeMesh().write(to: files.rawMesh)
        let fx: Float = 520, fy: Float = 520
        let cx = Float(width) / 2, cy = Float(height) / 2
        let depthW = width / 4, depthH = height / 4
        var records = [KeyframeRecord]()
        for (i, pose) in trajectory(count: frameCount).enumerated() {
            let c2w = pose.cameraToWorld
            let camera = PinholeCamera(cameraToWorld: c2w, fx: fx, fy: fy, cx: cx, cy: cy, width: width, height: height)
            // Color image.
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let o = (y * width + x) * 4
                    if let p = hitPoint(camera: camera, pixel: SIMD2(Float(x) + 0.5, Float(y) + 0.5)) {
                        let c = color(at: p)
                        pixels[o] = UInt8(c.x); pixels[o + 1] = UInt8(c.y); pixels[o + 2] = UInt8(c.z)
                    }
                    pixels[o + 3] = 255
                }
            }
            let name = String(format: "frames/%06d", i + 1)
            try writeImage(pixels: pixels, width: width, height: height, to: files.frameFile(name + ".jpg"))
            // Depth map (Z depth) at quarter resolution.
            let depthCamera = camera.scaled(toWidth: depthW, height: depthH)
            var depth = [Float](repeating: 0, count: depthW * depthH)
            for y in 0..<depthH {
                for x in 0..<depthW {
                    if let p = hitPoint(camera: depthCamera, pixel: SIMD2(Float(x) + 0.5, Float(y) + 0.5)) {
                        depth[y * depthW + x] = -(camera.worldToCamera * SIMD4(p, 1)).z
                    }
                }
            }
            try depth.withUnsafeBytes { try Data($0).write(to: files.frameFile(name + ".depth")) }
            try Data(repeating: 2, count: depthW * depthH).write(to: files.frameFile(name + ".conf"))
            records.append(KeyframeRecord(index: i + 1, timestamp: Double(i) * 0.5, image: name + ".jpg",
                                          depth: name + ".depth", confidence: name + ".conf",
                                          imageWidth: width, imageHeight: height, depthWidth: depthW, depthHeight: depthH,
                                          intrinsics: [fx, fy, cx, cy], transform: c2w.columnMajorArray,
                                          exposureDuration: 1.0 / 60, exposureOffset: 0, ambientIntensity: 1000,
                                          colorTemperature: 6500, angularSpeed: Float(i % 5) * 0.1))
        }
        try KeyframeIndex(frames: records).write(to: files.framesIndex)
    }

    func hitPoint(camera: PinholeCamera, pixel: SIMD2<Float>) -> SIMD3<Float>? {
        let dirCamera = SIMD3<Float>((pixel.x - camera.cx) / camera.fx, -(pixel.y - camera.cy) / camera.fy, -1)
        let dir = simd_normalize(camera.cameraToWorld.transformDirection(dirCamera))
        guard let t = raycast(origin: camera.position, direction: dir) else { return nil }
        return camera.position + dir * t
    }

    private func writeImage(pixels: [UInt8], width: Int, height: Int, to url: URL) throws {
        var copy = pixels
        let image = copy.withUnsafeMutableBytes { raw -> CGImage? in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: ImageFiles.sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        }
        guard let image else { throw ImageFiles.ImageError.contextCreationFailed }
        try ImageFiles.writeJPEG(image, to: url, quality: 0.92)
    }
}

struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func nextFloat() -> Float { Float(next() >> 40) / Float(1 << 24) }
}

extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), hi) }
}
