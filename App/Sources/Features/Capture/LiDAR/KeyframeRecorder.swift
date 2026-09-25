import ARKit
import CoreImage
import Foundation

/// Chooses keyframes during a LiDAR scan and writes them to `raw/frames/` (JPEG photo, Float32
/// depth, UInt8 confidence) together with the camera pose and intrinsics used for texturing.
///
/// A new keyframe is taken once the camera has moved or turned enough since the last one, and
/// preferably while it is steady (less motion blur).
final class KeyframeRecorder: @unchecked Sendable {
    struct Motion {
        var angularSpeed: Float = 0
        var linearSpeed: Float = 0
    }

    static let maxKeyframes = 1500

    private let rawDirectory: URL
    private let queue = DispatchQueue(label: "ScanSpace.keyframes", qos: .userInitiated)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var records: [KeyframeRecord] = []
    private var inFlight = 0

    // Main-thread state.
    private var nextIndex = 1
    private var lastKeyTransform: simd_float4x4?
    private var lastKeyTime: TimeInterval = 0
    private var pendingSince: TimeInterval?
    private var previousTransform: simd_float4x4?
    private var previousTime: TimeInterval = 0
    private(set) var motion = Motion()

    init(rawDirectory: URL) {
        self.rawDirectory = rawDirectory
        try? FileManager.default.createDirectory(at: rawDirectory.appendingPathComponent("frames", isDirectory: true),
                                                 withIntermediateDirectories: true)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return records.count + inFlight
    }

    /// Call with every ARFrame on the main thread. Returns true when the frame became a keyframe.
    @discardableResult
    func process(_ frame: ARFrame) -> Bool {
        updateMotion(frame)
        guard case .normal = frame.camera.trackingState, shouldCapture(frame) else { return false }
        capture(frame)
        return true
    }

    /// Waits for pending writes and returns all saved keyframes.
    func finish() -> [KeyframeRecord] {
        queue.sync {}
        lock.lock()
        defer { lock.unlock() }
        return records.sorted { $0.index < $1.index }
    }

    // MARK: - Selection

    private func updateMotion(_ frame: ARFrame) {
        let transform = frame.camera.transform
        if let previous = previousTransform, frame.timestamp > previousTime {
            let dt = Float(frame.timestamp - previousTime)
            let angular = Self.rotationAngle(previous, transform) / dt
            let linear = simd_distance(previous.translation, transform.translation) / dt
            motion.angularSpeed = motion.angularSpeed * 0.8 + angular * 0.2
            motion.linearSpeed = motion.linearSpeed * 0.8 + linear * 0.2
        }
        previousTransform = transform
        previousTime = frame.timestamp
    }

    private func shouldCapture(_ frame: ARFrame) -> Bool {
        lock.lock()
        let busy = inFlight >= 3 || records.count + inFlight >= Self.maxKeyframes
        lock.unlock()
        if busy { return false }
        let now = frame.timestamp
        guard let last = lastKeyTransform else { return true }
        if now - lastKeyTime < 0.25 { return false }

        let transform = frame.camera.transform
        let moved = simd_distance(last.translation, transform.translation)
        let turned = Self.rotationAngle(last, transform)
        let stale = now - lastKeyTime > 3 && (moved > 0.03 || turned > 0.05)
        guard moved > 0.12 || turned > 0.2 || stale else {
            pendingSince = nil
            return false
        }
        if pendingSince == nil { pendingSince = now }
        let steady = motion.angularSpeed < 0.7 && motion.linearSpeed < 0.5
        let waitedTooLong = now - (pendingSince ?? now) > 0.6
        return steady || waitedTooLong
    }

    // MARK: - Capture

    private func capture(_ frame: ARFrame) {
        let index = nextIndex
        nextIndex += 1
        let name = String(format: "frames/%06d", index)
        let camera = frame.camera
        let intrinsics = camera.intrinsics
        let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth
        // Depth maps are small (256×192) — copy them now so ARKit's buffers are released immediately.
        let depth = depthData.flatMap { Self.copyPixels($0.depthMap, bytesPerPixel: 4) }
        let confidence = depthData?.confidenceMap.flatMap { Self.copyPixels($0, bytesPerPixel: 1) }

        let record = KeyframeRecord(
            index: index,
            timestamp: frame.timestamp,
            image: name + ".jpg",
            depth: depth == nil ? nil : name + ".depth",
            confidence: confidence == nil ? nil : name + ".conf",
            imageWidth: Int(camera.imageResolution.width),
            imageHeight: Int(camera.imageResolution.height),
            depthWidth: depth?.width,
            depthHeight: depth?.height,
            intrinsics: [intrinsics[0][0], intrinsics[1][1], intrinsics[2][0], intrinsics[2][1]],
            transform: camera.transform.columnMajorArray,
            exposureDuration: camera.exposureDuration,
            exposureOffset: camera.exposureOffset,
            ambientIntensity: frame.lightEstimate.map { Float($0.ambientIntensity) },
            colorTemperature: frame.lightEstimate.map { Float($0.ambientColorTemperature) },
            angularSpeed: motion.angularSpeed)

        lastKeyTransform = camera.transform
        lastKeyTime = frame.timestamp
        pendingSince = nil

        let pixelBuffer = frame.capturedImage
        lock.lock()
        inFlight += 1
        lock.unlock()

        queue.async { [self] in
            autoreleasepool {
                var saved = false
                let image = CIImage(cvPixelBuffer: pixelBuffer)
                if let jpeg = ciContext.jpegRepresentation(
                    of: image, colorSpace: ImageFiles.sRGB,
                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.85]) {
                    saved = (try? jpeg.write(to: rawDirectory.appendingPathComponent(record.image))) != nil
                }
                if let depth, let path = record.depth {
                    try? depth.data.write(to: rawDirectory.appendingPathComponent(path))
                }
                if let confidence, let path = record.confidence {
                    try? confidence.data.write(to: rawDirectory.appendingPathComponent(path))
                }
                lock.lock()
                inFlight -= 1
                if saved { records.append(record) }
                lock.unlock()
            }
        }
    }

    // MARK: - Helpers

    static func rotationAngle(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        let r = simd_transpose(a.upperLeft3x3) * b.upperLeft3x3
        let trace = r.columns.0.x + r.columns.1.y + r.columns.2.z
        return acos(min(1, max(-1, (trace - 1) / 2)))
    }

    /// Copies a single-plane pixel buffer into tightly packed rows.
    static func copyPixels(_ buffer: CVPixelBuffer, bytesPerPixel: Int) -> (data: Data, width: Int, height: Int)? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let packedRow = width * bytesPerPixel
        guard rowBytes >= packedRow else { return nil }
        var data = Data(count: packedRow * height)
        data.withUnsafeMutableBytes { destination in
            guard let out = destination.baseAddress else { return }
            for y in 0..<height {
                memcpy(out + y * packedRow, base + y * rowBytes, packedRow)
            }
        }
        return (data, width, height)
    }
}
