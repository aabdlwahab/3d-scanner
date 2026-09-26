import CoreGraphics
import Foundation
import simd

/// A procedurally built three-room apartment: the sample project in ScanSpace Studio and the
/// ground truth for processing / blueprint tests.
///
/// The apartment is a set of solid boxes (walls with real thickness, doorways with lintels,
/// recessed windows, a closed entrance door, furniture) in a local axis-aligned frame, rotated
/// and offset into "world" space like an ARKit session would be. Keyframes are rendered by ray
/// casting, and the mesh only contains surfaces a scanner standing at the camera stops could see.
struct SyntheticApartment {
    enum Pattern { case plain, planks, stripes, painting }

    struct Box {
        var min: SIMD3<Float>
        var max: SIMD3<Float>
        var surfaceClass: SurfaceClass
        var color: SIMD3<Float>
        var pattern: Pattern = .plain
    }

    var boxes: [Box] = []
    var cameraStops: [SIMD3<Float>] = []
    var yaw: Float
    var offset: SIMD3<Float>
    let height: Float = 2.6

    /// Interior floor area of the three rooms (excluding walls), m².
    let expectedFloorArea: Double = 4.74 * 6 + 3.14 * 3.34 + 3.14 * 2.54
    let expectedRooms = 3
    let expectedWallLengths: [Float] = [8, 8, 6, 6, 6, 3.14]

    static func standard(yaw: Float = 23 * .pi / 180, offset: SIMD3<Float> = SIMD3(1.3, -1.35, -2.1)) -> SyntheticApartment {
        var apartment = SyntheticApartment(yaw: yaw, offset: offset)
        apartment.build()
        return apartment
    }

    var worldTransform: simd_float4x4 {
        var m = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)))
        m.columns.3 = SIMD4(offset, 1)
        return m
    }

    // MARK: - Layout

    private mutating func build() {
        let h = height, outer: Float = 0.2
        let wallColor = SIMD3<Float>(0.90, 0.88, 0.84), bedroomColor = SIMD3<Float>(0.80, 0.86, 0.90)
        let oak = SIMD3<Float>(0.62, 0.45, 0.30), white = SIMD3<Float>(0.96, 0.96, 0.95)

        boxes.append(Box(min: SIMD3(-outer, -0.1, -outer), max: SIMD3(8 + outer, 0, 6 + outer), surfaceClass: .floor, color: oak, pattern: .planks))
        boxes.append(Box(min: SIMD3(-outer, h, -outer), max: SIMD3(8 + outer, h + 0.1, 6 + outer), surfaceClass: .ceiling, color: white))

        // Exterior walls (only their inner faces are visible).
        wall(axis: 0, span: -outer...(8 + outer), across: -outer...0, openings: [(1.2...2.8, 0.9...2.1)], color: wallColor)
        wall(axis: 0, span: -outer...(8 + outer), across: 6...(6 + outer), openings: [(6.0...7.0, 1.2...2.0)], color: wallColor, pattern: .painting)
        wall(axis: 2, span: 0...6, across: -outer...0, openings: [(4.0...4.9, 0...2.05)], color: wallColor)
        wall(axis: 2, span: 0...6, across: 8...(8 + outer), openings: [(1.0...2.4, 0.9...2.1)], color: bedroomColor)
        // Interior walls (12 cm) with doorways.
        wall(axis: 2, span: 0...6, across: 4.74...4.86, openings: [(2.0...2.9, 0...2.05)], color: wallColor, pattern: .stripes)
        wall(axis: 0, span: 4.86...8, across: 3.34...3.46, openings: [(6.0...6.85, 0...2.05)], color: bedroomColor)

        // Closed entrance door and window glass, recessed into their openings.
        boxes.append(Box(min: SIMD3(-0.07, 0, 4.0), max: SIMD3(-0.03, 2.05, 4.9), surfaceClass: .door, color: SIMD3(0.55, 0.36, 0.22), pattern: .planks))
        let glass = SIMD3<Float>(0.70, 0.84, 0.95)
        boxes.append(Box(min: SIMD3(1.2, 0.9, -0.11), max: SIMD3(2.8, 2.1, -0.09), surfaceClass: .window, color: glass))
        boxes.append(Box(min: SIMD3(8.09, 0.9, 1.0), max: SIMD3(8.11, 2.1, 2.4), surfaceClass: .window, color: glass))
        boxes.append(Box(min: SIMD3(6.0, 1.2, 6.09), max: SIMD3(7.0, 2.0, 6.11), surfaceClass: .window, color: glass))

        // Furniture.
        boxes.append(Box(min: SIMD3(0.6, 0, 5.05), max: SIMD3(2.6, 0.85, 5.95), surfaceClass: .seat, color: SIMD3(0.25, 0.38, 0.62)))
        boxes.append(Box(min: SIMD3(1.1, 0, 3.9), max: SIMD3(2.1, 0.45, 4.5), surfaceClass: .table, color: SIMD3(0.35, 0.24, 0.16)))
        boxes.append(Box(min: SIMD3(2.7, 0, 1.2), max: SIMD3(3.9, 0.75, 2.0), surfaceClass: .table, color: SIMD3(0.78, 0.62, 0.42), pattern: .planks))
        boxes.append(Box(min: SIMD3(5.3, 0, 0.4), max: SIMD3(7.3, 0.55, 2.5), surfaceClass: .none, color: SIMD3(0.92, 0.93, 0.96)))
        boxes.append(Box(min: SIMD3(5.0, 0, 4.3), max: SIMD3(5.6, 2.1, 5.9), surfaceClass: .none, color: SIMD3(0.70, 0.55, 0.40), pattern: .planks))
        boxes.append(Box(min: SIMD3(7.35, 0, 4.1), max: SIMD3(7.95, 0.9, 5.4), surfaceClass: .none, color: SIMD3(0.85, 0.85, 0.82)))

        cameraStops = [
            SIMD3(1.4, 1.45, 1.4), SIMD3(3.4, 1.45, 3.2), SIMD3(1.8, 1.45, 4.6), SIMD3(4.8, 1.45, 2.45),
            SIMD3(6.3, 1.45, 2.9), SIMD3(7.5, 1.45, 2.9), SIMD3(6.4, 1.45, 3.4), SIMD3(6.4, 1.45, 4.6), SIMD3(7.0, 1.45, 5.5),
        ]
    }

    /// A wall slab along `axis` (0 = x, 2 = z), `across` the other horizontal axis, with
    /// rectangular openings given as (along-axis range, height range).
    private mutating func wall(axis: Int, span: ClosedRange<Float>, across: ClosedRange<Float>,
                               openings: [(ClosedRange<Float>, ClosedRange<Float>)], color: SIMD3<Float>, pattern: Pattern = .plain) {
        func box(_ along: ClosedRange<Float>, _ y: ClosedRange<Float>) {
            guard along.upperBound - along.lowerBound > 0.001, y.upperBound - y.lowerBound > 0.001 else { return }
            let lo = axis == 0 ? SIMD3(along.lowerBound, y.lowerBound, across.lowerBound) : SIMD3(across.lowerBound, y.lowerBound, along.lowerBound)
            let hi = axis == 0 ? SIMD3(along.upperBound, y.upperBound, across.upperBound) : SIMD3(across.upperBound, y.upperBound, along.upperBound)
            boxes.append(Box(min: lo, max: hi, surfaceClass: .wall, color: color, pattern: pattern))
        }
        var cursor = span.lowerBound
        for (along, y) in openings.sorted(by: { $0.0.lowerBound < $1.0.lowerBound }) {
            box(cursor...along.lowerBound, 0...height)
            box(along, 0...y.lowerBound)
            box(along, y.upperBound...height)
            cursor = along.upperBound
        }
        box(cursor...span.upperBound, 0...height)
    }

    // MARK: - Ray casting (local frame)

    struct Hit {
        var distance: Float
        var point: SIMD3<Float>
        var normal: SIMD3<Float>
        var box: Int
    }

    func raycast(origin o: SIMD3<Float>, direction d: SIMD3<Float>, maxDistance: Float = .infinity) -> Hit? {
        var best: Hit?
        let inv = SIMD3<Float>(1 / d.x, 1 / d.y, 1 / d.z)
        for (index, box) in boxes.enumerated() {
            let t1 = (box.min - o) * inv, t2 = (box.max - o) * inv
            let tmin = simd_min(t1, t2), tmax = simd_max(t1, t2)
            let enter = max(tmin.x, max(tmin.y, tmin.z)), exit = min(tmax.x, min(tmax.y, tmax.z))
            guard enter <= exit, enter > 1e-4, enter < (best?.distance ?? maxDistance) else { continue }
            var normal = SIMD3<Float>.zero
            if enter == tmin.x { normal.x = d.x > 0 ? -1 : 1 } else if enter == tmin.y { normal.y = d.y > 0 ? -1 : 1 } else { normal.z = d.z > 0 ? -1 : 1 }
            best = Hit(distance: enter, point: o + d * enter, normal: normal, box: index)
        }
        return best
    }

    /// sRGB color (0...1) of a surface point.
    func color(of hit: Hit) -> SIMD3<Float> {
        let box = boxes[hit.box]
        let p = hit.point
        var c = box.color
        switch box.pattern {
        case .plain:
            break
        case .planks:
            let along = abs(hit.normal.y) > 0.5 ? p.x : (abs(hit.normal.x) > 0.5 ? p.z : p.x)
            let plank = Int((along / 0.18).rounded(.down))
            let tone = Float((plank * 7919) % 11) / 11 - 0.5
            c *= 1 + tone * 0.18
            if abs(along / 0.18 - (along / 0.18).rounded()) < 0.04 { c *= 0.7 }
        case .stripes:
            let along = abs(hit.normal.x) > 0.5 ? p.z : p.x
            if Int((along / 0.3).rounded(.down)) % 2 == 0 { c *= 0.9 }
        case .painting:
            // A colorful picture on the living-room side of the south wall.
            if hit.normal.z < -0.5, p.x > 1.4, p.x < 3.0, p.y > 1.2, p.y < 2.0 {
                let u = (p.x - 1.4) / 1.6, v = (p.y - 1.2) / 0.8
                c = SIMD3(0.9 - 0.6 * u, 0.3 + 0.5 * v, 0.35 + 0.55 * u * v)
            }
        }
        let light = simd_normalize(SIMD3<Float>(0.4, 0.8, 0.3))
        let shade = 0.78 + 0.22 * max(0, simd_dot(hit.normal, light))
        return simd_clamp(c * shade, SIMD3(repeating: 0), SIMD3(repeating: 1))
    }

    private func isVisible(_ point: SIMD3<Float>, normal: SIMD3<Float>, from camera: SIMD3<Float>) -> Bool {
        let target = point + normal * 0.002
        let toCamera = camera - target
        let distance = simd_length(toCamera)
        guard distance < 6.5, simd_dot(normal, toCamera) > 0.08 * distance else { return false }
        return raycast(origin: camera, direction: -toCamera / distance, maxDistance: distance - 0.004) == nil
    }

    // MARK: - Mesh

    /// ARKit-like mesh (world space): visible faces only, per-face chunks, small noise.
    func makeMesh(cell: Float = 0.06, seed: UInt64 = 11) -> RawMesh {
        var rng = SampleRandom(seed: seed)
        var mesh = RawMesh()
        let world = worldTransform, rotation = world.upperLeft3x3
        for box in boxes {
            for axis in 0..<3 {
                for side in [Float(-1), 1] {
                    var normal = SIMD3<Float>.zero
                    normal[axis] = side
                    let u = (axis + 1) % 3, v = (axis + 2) % 3
                    let plane = side > 0 ? box.max[axis] : box.min[axis]
                    let lengthU = box.max[u] - box.min[u], lengthV = box.max[v] - box.min[v]
                    let nu = max(1, Int((lengthU / cell).rounded())), nv = max(1, Int((lengthV / cell).rounded()))
                    func point(_ i: Int, _ j: Int) -> SIMD3<Float> {
                        var p = SIMD3<Float>.zero
                        p[axis] = plane
                        p[u] = box.min[u] + lengthU * Float(i) / Float(nu)
                        p[v] = box.min[v] + lengthV * Float(j) / Float(nv)
                        return p
                    }
                    var cellVisible = [Bool](repeating: false, count: nu * nv)
                    var any = false
                    for i in 0..<nu {
                        for j in 0..<nv {
                            let center = (point(i, j) + point(i + 1, j + 1)) / 2
                            if cameraStops.contains(where: { isVisible(center, normal: normal, from: $0) }) {
                                cellVisible[j * nu + i] = true
                                any = true
                            }
                        }
                    }
                    guard any else { continue }
                    var vertexIndex = [Int32](repeating: -1, count: (nu + 1) * (nv + 1))
                    func vertex(_ i: Int, _ j: Int) -> UInt32 {
                        let slot = j * (nu + 1) + i
                        if vertexIndex[slot] >= 0 { return UInt32(vertexIndex[slot]) }
                        var p = point(i, j)
                        let interior = i > 0 && j > 0 && i < nu && j < nv
                        if interior { p += normal * (rng.nextFloat() - 0.5) * 0.01 }
                        let jitter = SIMD3(rng.nextFloat() - 0.5, rng.nextFloat() - 0.5, rng.nextFloat() - 0.5) * 0.06
                        mesh.positions.append(world.transformPoint(p))
                        mesh.normals.append(simd_normalize(rotation * (normal + jitter)))
                        vertexIndex[slot] = Int32(mesh.positions.count - 1)
                        return UInt32(mesh.positions.count - 1)
                    }
                    for i in 0..<nu {
                        for j in 0..<nv where cellVisible[j * nu + i] {
                            let a = vertex(i, j), b = vertex(i + 1, j), c = vertex(i + 1, j + 1), d = vertex(i, j + 1)
                            // Counter-clockwise seen from the normal side.
                            let ccw = simd_dot(simd_cross(point(i + 1, j) - point(i, j), point(i, j + 1) - point(i, j)), normal) > 0
                            mesh.indices.append(contentsOf: ccw ? [a, b, c, a, c, d] : [a, c, b, a, d, c])
                            mesh.classes.append(contentsOf: [box.surfaceClass.rawValue, box.surfaceClass.rawValue])
                        }
                    }
                }
            }
        }
        return mesh
    }

    // MARK: - Capture

    struct Pose {
        var position: SIMD3<Float>
        var yaw: Float
        var pitch: Float

        var matrix: simd_float4x4 {
            var m = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0)))
            m.columns.3 = SIMD4(position, 1)
            return m
        }
    }

    func poses(yawSteps: Int = 8, pitches: [Float] = [-0.55, 0, 0.5]) -> [Pose] {
        var result: [Pose] = []
        for (s, stop) in cameraStops.enumerated() {
            for k in 0..<yawSteps {
                let yaw = Float(k) / Float(yawSteps) * 2 * .pi + Float(s) * 0.37
                for pitch in pitches { result.append(Pose(position: stop, yaw: yaw, pitch: pitch)) }
            }
        }
        return result
    }

    /// Writes a complete raw capture (mesh.bin, frames.json, keyframe JPEGs, depth, confidence)
    /// exactly like the iPhone app records it. Progress is reported from 0 to 1.
    func writeCapture(to files: ScanFiles, width: Int = 640, height: Int = 480, cell: Float = 0.06,
                      progress: (Double) -> Void = { _ in }) throws {
        try files.createDirectories()
        try makeMesh(cell: cell).write(to: files.rawMesh)
        progress(0.2)
        let fx = Float(width) * 0.8, fy = fx
        let cx = Float(width) / 2, cy = Float(height) / 2
        let depthW = max(32, width / 5), depthH = max(24, height / 5)
        let world = worldTransform
        var records: [KeyframeRecord] = []
        let allPoses = poses()
        for (i, pose) in allPoses.enumerated() {
            let local = PinholeCamera(cameraToWorld: pose.matrix, fx: fx, fy: fy, cx: cx, cy: cy, width: width, height: height)
            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            pixels.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    for x in 0..<width {
                        guard let hit = hit(camera: local, pixel: SIMD2(Float(x) + 0.5, Float(y) + 0.5)) else { continue }
                        let c = color(of: hit)
                        let o = (y * width + x) * 4
                        out[o] = UInt8(c.x * 255); out[o + 1] = UInt8(c.y * 255); out[o + 2] = UInt8(c.z * 255)
                    }
                }
            }
            let name = String(format: "frames/%06d", i + 1)
            try Self.writeJPEG(pixels: pixels, width: width, height: height, to: files.frameFile(name + ".jpg"))
            let depthCamera = local.scaled(toWidth: depthW, height: depthH)
            var depth = [Float](repeating: 0, count: depthW * depthH)
            depth.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: depthH) { y in
                    for x in 0..<depthW {
                        if let hit = hit(camera: depthCamera, pixel: SIMD2(Float(x) + 0.5, Float(y) + 0.5)) {
                            out[y * depthW + x] = -(local.worldToCamera * SIMD4(hit.point, 1)).z
                        }
                    }
                }
            }
            try depth.withUnsafeBytes { try Data($0).write(to: files.frameFile(name + ".depth")) }
            try Data(repeating: 2, count: depthW * depthH).write(to: files.frameFile(name + ".conf"))
            records.append(KeyframeRecord(index: i + 1, timestamp: Double(i) * 0.4, image: name + ".jpg",
                                          depth: name + ".depth", confidence: name + ".conf",
                                          imageWidth: width, imageHeight: height, depthWidth: depthW, depthHeight: depthH,
                                          intrinsics: [fx, fy, cx, cy], transform: (world * pose.matrix).columnMajorArray,
                                          exposureDuration: 1.0 / 60, exposureOffset: 0, ambientIntensity: 1000,
                                          colorTemperature: 6500, angularSpeed: 0.1))
            progress(0.2 + 0.8 * Double(i + 1) / Double(allPoses.count))
        }
        try KeyframeIndex(frames: records).write(to: files.framesIndex)
    }

    private func hit(camera: PinholeCamera, pixel: SIMD2<Float>) -> Hit? {
        let direction = simd_normalize(camera.cameraToWorld.transformDirection(
            SIMD3((pixel.x - camera.cx) / camera.fx, -(pixel.y - camera.cy) / camera.fy, -1)))
        return raycast(origin: camera.position, direction: direction)
    }

    private static func writeJPEG(pixels: [UInt8], width: Int, height: Int, to url: URL) throws {
        var copy = pixels
        let image = copy.withUnsafeMutableBytes { raw -> CGImage? in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: ImageFiles.sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        }
        guard let image else { throw ImageFiles.ImageError.contextCreationFailed }
        try ImageFiles.writeJPEG(image, to: url, quality: 0.9)
    }
}

/// Small deterministic PRNG (SplitMix64).
struct SampleRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextFloat() -> Float {
        Float(next() >> 40) / Float(1 << 24)
    }
}
