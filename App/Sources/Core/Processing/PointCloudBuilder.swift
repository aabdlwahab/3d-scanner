import Foundation
import simd

/// Fuses the LiDAR depth maps of all keyframes into a colored point cloud.
enum PointCloudBuilder {
    struct Options {
        /// Roughly how many points to aim for; sets the voxel size from the scanned surface area.
        var targetPoints = 1_200_000
        var minVoxelSize: Float = 0.006
        var maxVoxelSize: Float = 0.03
        var pixelStride = 2
        /// ARKit confidence: 0 low, 1 medium, 2 high.
        var minConfidence: UInt8 = 2
        var minDepth: Float = 0.15
        var maxDepth: Float = 5.0
    }

    static func voxelSize(forSurfaceArea area: Double, options: Options = Options()) -> Float {
        let size = Float((max(area, 0.01) / Double(options.targetPoints)).squareRoot())
        return min(options.maxVoxelSize, max(options.minVoxelSize, size))
    }

    static func build(frames: [ProcessingFrame], voxelSize: Float, options: Options = Options(),
                      progress: (Double) -> Void) -> PointCloud {
        var grid = VoxelGrid(voxelSize: voxelSize)
        for (i, frame) in frames.enumerated() {
            autoreleasepool {
                guard let depth = frame.depth,
                      let image = ImageFiles.loadImage(frame.imageURL, maxPixelSize: max(depth.width, depth.height)),
                      let pixels = ImageFiles.rgbaPixels(of: image, width: depth.width, height: depth.height)
                else { return }
                let camera = frame.camera.scaled(toWidth: depth.width, height: depth.height)
                var y = 0
                while y < depth.height {
                    var x = 0
                    while x < depth.width {
                        let i = y * depth.width + x
                        let d = depth.depth[i]
                        let confident = depth.confidence.map { $0[i] >= options.minConfidence } ?? true
                        if confident, d >= options.minDepth, d <= options.maxDepth {
                            let p = camera.unproject(pixel: SIMD2(Float(x) + 0.5, Float(y) + 0.5), depth: d)
                            let o = i * 4
                            grid.add(p, color: SIMD3(Float(pixels[o]), Float(pixels[o + 1]), Float(pixels[o + 2])))
                        }
                        x += options.pixelStride
                    }
                    y += options.pixelStride
                }
            }
            progress(Double(i + 1) / Double(max(1, frames.count)))
        }
        return grid.makeCloud()
    }
}

/// Open-addressing hash grid that averages positions and colors per voxel.
struct VoxelGrid {
    private static let emptyKey = Int64.min

    private var keys: [Int64]
    /// Sum of x, y, z and the sample count in w.
    private var sums: [SIMD4<Float>]
    private var colorSums: [SIMD3<Float>]
    private var mask: Int
    private(set) var count = 0
    private let inverseVoxelSize: Float

    init(voxelSize: Float, initialCapacity: Int = 1 << 16) {
        var capacity = 1
        while capacity < initialCapacity { capacity <<= 1 }
        keys = [Int64](repeating: Self.emptyKey, count: capacity)
        sums = [SIMD4<Float>](repeating: .zero, count: capacity)
        colorSums = [SIMD3<Float>](repeating: .zero, count: capacity)
        mask = capacity - 1
        inverseVoxelSize = 1 / voxelSize
    }

    mutating func add(_ p: SIMD3<Float>, color: SIMD3<Float>) {
        if (count + 1) * 10 > keys.count * 6 { grow() }
        let key = Self.key(p, inverseVoxelSize)
        var slot = Self.hash(key) & mask
        while true {
            let existing = keys[slot]
            if existing == key {
                sums[slot] += SIMD4(p, 1)
                colorSums[slot] += color
                return
            }
            if existing == Self.emptyKey {
                keys[slot] = key
                sums[slot] = SIMD4(p, 1)
                colorSums[slot] = color
                count += 1
                return
            }
            slot = (slot + 1) & mask
        }
    }

    func makeCloud() -> PointCloud {
        var cloud = PointCloud()
        cloud.positions.reserveCapacity(count)
        cloud.colors.reserveCapacity(count)
        for slot in keys.indices where keys[slot] != Self.emptyKey {
            let s = sums[slot]
            let n = s.w
            cloud.positions.append(SIMD3(s.x, s.y, s.z) / n)
            let c = colorSums[slot] / n
            cloud.colors.append(SIMD4(UInt8(min(255, max(0, c.x))), UInt8(min(255, max(0, c.y))), UInt8(min(255, max(0, c.z))), 255))
        }
        return cloud
    }

    private mutating func grow() {
        let oldKeys = keys, oldSums = sums, oldColors = colorSums
        let capacity = keys.count * 2
        keys = [Int64](repeating: Self.emptyKey, count: capacity)
        sums = [SIMD4<Float>](repeating: .zero, count: capacity)
        colorSums = [SIMD3<Float>](repeating: .zero, count: capacity)
        mask = capacity - 1
        for i in oldKeys.indices where oldKeys[i] != Self.emptyKey {
            var slot = Self.hash(oldKeys[i]) & mask
            while keys[slot] != Self.emptyKey { slot = (slot + 1) & mask }
            keys[slot] = oldKeys[i]
            sums[slot] = oldSums[i]
            colorSums[slot] = oldColors[i]
        }
    }

    @inline(__always)
    private static func key(_ p: SIMD3<Float>, _ inv: Float) -> Int64 {
        let x = Int64((p.x * inv).rounded(.down)) & 0x1F_FFFF
        let y = Int64((p.y * inv).rounded(.down)) & 0x1F_FFFF
        let z = Int64((p.z * inv).rounded(.down)) & 0x1F_FFFF
        return (x << 42) | (y << 21) | z
    }

    @inline(__always)
    private static func hash(_ key: Int64) -> Int {
        let h = UInt64(bitPattern: key) &* 0x9E37_79B9_7F4A_7C15
        return Int(truncatingIfNeeded: h >> 17)
    }
}
