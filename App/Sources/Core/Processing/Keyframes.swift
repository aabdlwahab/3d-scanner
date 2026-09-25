import Foundation
import simd

/// Metadata for one keyframe recorded during a LiDAR scan.
struct KeyframeRecord: Codable {
    var index: Int
    var timestamp: Double
    /// Paths relative to the scan's `raw/` directory.
    var image: String
    var depth: String?
    var confidence: String?
    var imageWidth: Int
    var imageHeight: Int
    var depthWidth: Int?
    var depthHeight: Int?
    /// fx, fy, cx, cy in pixels of the captured image (sensor landscape orientation).
    var intrinsics: [Float]
    /// Camera-to-world transform, 16 floats column-major (ARKit camera convention:
    /// +X right, +Y up, looking down -Z, relative to the sensor's landscape orientation).
    var transform: [Float]
    var exposureDuration: Double?
    var exposureOffset: Float?
    var ambientIntensity: Float?
    var colorTemperature: Float?
    /// Angular speed of the camera at capture time (rad/s) — a motion blur indicator.
    var angularSpeed: Float?
}

struct KeyframeIndex: Codable {
    var version = 1
    var frames: [KeyframeRecord]

    func write(to url: URL) throws {
        try JSONEncoder.scanSpace.encode(self).write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> KeyframeIndex {
        try JSONDecoder.scanSpace.decode(KeyframeIndex.self, from: Data(contentsOf: url))
    }
}

/// Pinhole camera matching ARKit's conventions.
struct PinholeCamera {
    let cameraToWorld: simd_float4x4
    let worldToCamera: simd_float4x4
    let fx: Float, fy: Float, cx: Float, cy: Float
    let width: Int, height: Int

    init(cameraToWorld: simd_float4x4, fx: Float, fy: Float, cx: Float, cy: Float, width: Int, height: Int) {
        self.cameraToWorld = cameraToWorld
        self.worldToCamera = cameraToWorld.inverse
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
        self.width = width
        self.height = height
    }

    var position: SIMD3<Float> { cameraToWorld.translation }
    /// Viewing direction in world space (camera -Z).
    var forward: SIMD3<Float> { -simd_normalize(cameraToWorld.columns.2.xyz) }

    /// Projects a world point into image pixels. `depth` is the distance along the viewing axis
    /// (positive in front of the camera).
    @inline(__always)
    func project(_ p: SIMD3<Float>) -> (pixel: SIMD2<Float>, depth: Float) {
        let c = worldToCamera * SIMD4(p, 1)
        let z = -c.z
        let invZ = 1 / z
        return (SIMD2(fx * c.x * invZ + cx, -fy * c.y * invZ + cy), z)
    }

    /// World position of an image pixel at the given depth (inverse of ``project(_:)``).
    @inline(__always)
    func unproject(pixel: SIMD2<Float>, depth: Float) -> SIMD3<Float> {
        let x = (pixel.x - cx) / fx * depth
        let y = -(pixel.y - cy) / fy * depth
        return cameraToWorld.transformPoint(SIMD3(x, y, -depth))
    }

    /// Camera with intrinsics scaled to another image resolution (e.g. the depth map).
    func scaled(toWidth newWidth: Int, height newHeight: Int) -> PinholeCamera {
        let sx = Float(newWidth) / Float(width)
        let sy = Float(newHeight) / Float(height)
        return PinholeCamera(cameraToWorld: cameraToWorld, fx: fx * sx, fy: fy * sy, cx: cx * sx, cy: cy * sy,
                             width: newWidth, height: newHeight)
    }
}

/// Row-major Float32 depth map (meters along the viewing axis) with optional ARKit confidence (0...2).
struct DepthMap {
    let width: Int
    let height: Int
    let depth: [Float]
    let confidence: [UInt8]?

    static func load(depthURL: URL, confidenceURL: URL?, width: Int, height: Int) -> DepthMap? {
        guard let data = try? Data(contentsOf: depthURL), data.count >= width * height * 4 else { return nil }
        let depth = data.withUnsafeBytes { raw in Array(raw.bindMemory(to: Float.self).prefix(width * height)) }
        var confidence: [UInt8]?
        if let confidenceURL, let c = try? Data(contentsOf: confidenceURL), c.count >= width * height {
            confidence = Array(c.prefix(width * height))
        }
        return DepthMap(width: width, height: height, depth: depth, confidence: confidence)
    }

    /// Minimum depth in the 2x2 neighborhood around a (fractional) depth-map pixel.
    /// Taking the minimum makes occlusion tests conservative near depth edges.
    @inline(__always)
    func minDepth(x: Float, y: Float) -> Float? {
        let x0 = Int((x - 0.5).rounded(.down)), y0 = Int((y - 0.5).rounded(.down))
        var best = Float.infinity
        var yy = max(0, y0)
        while yy <= min(height - 1, y0 + 1) {
            var xx = max(0, x0)
            while xx <= min(width - 1, x0 + 1) {
                let d = depth[yy * width + xx]
                if d > 0, d < best { best = d }
                xx += 1
            }
            yy += 1
        }
        return best.isFinite ? best : nil
    }
}

/// A keyframe prepared for processing.
struct ProcessingFrame {
    let index: Int
    let camera: PinholeCamera
    let imageURL: URL
    let depth: DepthMap?
    /// Scale from image pixels to depth pixels.
    let depthScale: SIMD2<Float>
    /// 0...1 weight that penalizes motion blur.
    let sharpness: Float

    static func load(files: ScanFiles) throws -> [ProcessingFrame] {
        guard FileManager.default.fileExists(atPath: files.framesIndex.path) else { return [] }
        let index = try KeyframeIndex.read(from: files.framesIndex)
        return index.frames.compactMap { record in
            guard record.intrinsics.count == 4, record.transform.count == 16 else { return nil }
            let imageURL = files.frameFile(record.image)
            guard FileManager.default.fileExists(atPath: imageURL.path) else { return nil }
            let camera = PinholeCamera(cameraToWorld: simd_float4x4(columnMajor: record.transform),
                                       fx: record.intrinsics[0], fy: record.intrinsics[1],
                                       cx: record.intrinsics[2], cy: record.intrinsics[3],
                                       width: record.imageWidth, height: record.imageHeight)
            var depth: DepthMap?
            if let depthPath = record.depth, let w = record.depthWidth, let h = record.depthHeight {
                depth = DepthMap.load(depthURL: files.frameFile(depthPath),
                                      confidenceURL: record.confidence.map { files.frameFile($0) },
                                      width: w, height: h)
            }
            let scale = depth.map { SIMD2(Float($0.width) / Float(record.imageWidth), Float($0.height) / Float(record.imageHeight)) } ?? .zero
            let speed = record.angularSpeed ?? 0
            let sharpness = 1 / (1 + (speed / 0.6) * (speed / 0.6))
            return ProcessingFrame(index: record.index, camera: camera, imageURL: imageURL, depth: depth,
                                   depthScale: scale, sharpness: sharpness)
        }
    }
}
