import Foundation
import simd

/// Surface classes reported by ARKit scene reconstruction (mirrors `ARMeshClassification`
/// so the processing code does not depend on ARKit).
enum SurfaceClass: UInt8, CaseIterable {
    case none = 0, wall, floor, ceiling, table, seat, window, door

    var name: String {
        switch self {
        case .none: "Other"
        case .wall: "Wall"
        case .floor: "Floor"
        case .ceiling: "Ceiling"
        case .table: "Table"
        case .seat: "Seat"
        case .window: "Window"
        case .door: "Door"
        }
    }

    /// Display color (linear-ish sRGB, 0...1).
    var color: SIMD3<Float> {
        switch self {
        case .none: SIMD3(0.62, 0.64, 0.70)
        case .wall: SIMD3(0.36, 0.55, 0.98)
        case .floor: SIMD3(0.30, 0.82, 0.55)
        case .ceiling: SIMD3(0.98, 0.80, 0.32)
        case .table: SIMD3(0.96, 0.50, 0.30)
        case .seat: SIMD3(0.78, 0.42, 0.95)
        case .window: SIMD3(0.35, 0.90, 0.96)
        case .door: SIMD3(0.95, 0.36, 0.52)
        }
    }

    static func from(_ raw: UInt8) -> SurfaceClass { SurfaceClass(rawValue: raw) ?? .none }
}

/// sRGB <-> linear conversion. SceneKit treats vertex colors as linear values, while
/// camera pixels and design colors are sRGB.
enum ColorSpaceMath {
    private static let table: [Float] = (0...255).map { srgbToLinear(Float($0) / 255) }

    @inline(__always)
    static func linear(_ byte: UInt8) -> Float { table[Int(byte)] }

    static func srgbToLinear(_ c: Float) -> Float {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func linear(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(srgbToLinear(rgb.x), srgbToLinear(rgb.y), srgbToLinear(rgb.z))
    }
}

/// Triangle mesh captured from ARKit, in world space (meters, +Y up).
struct RawMesh {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    /// Three indices per triangle.
    var indices: [UInt32] = []
    /// One ``SurfaceClass`` raw value per triangle; empty when unavailable.
    var classes: [UInt8] = []

    var triangleCount: Int { indices.count / 3 }
    var vertexCount: Int { positions.count }
}

/// Mesh produced by the texturing pipeline. Vertex arrays are shared by all groups;
/// each group is drawn with one texture page (or untextured when `textureIndex == -1`).
struct TexturedMesh {
    struct Group {
        var textureIndex: Int
        var indices: [UInt32]
    }

    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    /// Texture coordinates with the origin at the top-left of the image (SceneKit / glTF convention).
    var uvs: [SIMD2<Float>] = []
    /// Per-vertex colors sampled from the texture pages (used for PLY export and fallbacks).
    var colors: [SIMD4<UInt8>] = []
    /// Per-vertex ``SurfaceClass`` raw values.
    var classes: [UInt8] = []
    var groups: [Group] = []
    var textureCount = 0

    var vertexCount: Int { positions.count }
    var triangleCount: Int { groups.reduce(0) { $0 + $1.indices.count / 3 } }
}

/// Colored point cloud (meters, +Y up).
struct PointCloud {
    var positions: [SIMD3<Float>] = []
    var colors: [SIMD4<UInt8>] = []

    var count: Int { positions.count }
}

struct BoundingBox: Equatable {
    var min: SIMD3<Float>
    var max: SIMD3<Float>

    static let empty = BoundingBox(min: SIMD3(repeating: .infinity), max: SIMD3(repeating: -.infinity))

    init(min: SIMD3<Float>, max: SIMD3<Float>) {
        self.min = min
        self.max = max
    }

    init<S: Sequence>(points: S) where S.Element == SIMD3<Float> {
        var box = BoundingBox.empty
        for p in points { box.formUnion(p) }
        self = box
    }

    var isEmpty: Bool { min.x > max.x }
    var size: SIMD3<Float> { isEmpty ? .zero : max - min }
    var center: SIMD3<Float> { isEmpty ? .zero : (min + max) * 0.5 }
    var radius: Float { simd_length(size) * 0.5 }

    mutating func formUnion(_ p: SIMD3<Float>) {
        min = simd_min(min, p)
        max = simd_max(max, p)
    }

    mutating func formUnion(_ other: BoundingBox) {
        guard !other.isEmpty else { return }
        min = simd_min(min, other.min)
        max = simd_max(max, other.max)
    }
}

enum MeshMath {
    @inline(__always)
    static func triangleArea(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float {
        simd_length(simd_cross(b - a, c - a)) * 0.5
    }

    static func surfaceArea(positions: [SIMD3<Float>], indices: [UInt32]) -> Double {
        var total: Double = 0
        var t = 0
        while t + 2 < indices.count {
            total += Double(triangleArea(positions[Int(indices[t])], positions[Int(indices[t + 1])], positions[Int(indices[t + 2])]))
            t += 3
        }
        return total
    }

    /// Area-weighted vertex normals from triangle winding (counter-clockwise = front).
    static func vertexNormals(positions: [SIMD3<Float>], indices: [UInt32]) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        var t = 0
        while t + 2 < indices.count {
            let i0 = Int(indices[t]), i1 = Int(indices[t + 1]), i2 = Int(indices[t + 2])
            let n = simd_cross(positions[i1] - positions[i0], positions[i2] - positions[i0])
            normals[i0] += n
            normals[i1] += n
            normals[i2] += n
            t += 3
        }
        for i in normals.indices {
            let len = simd_length(normals[i])
            normals[i] = len > 1e-12 ? normals[i] / len : SIMD3(0, 1, 0)
        }
        return normals
    }

    /// Unit face normals (from winding) and face areas.
    static func faceNormalsAndAreas(positions: [SIMD3<Float>], indices: [UInt32]) -> (normals: [SIMD3<Float>], areas: [Float]) {
        let count = indices.count / 3
        var normals = [SIMD3<Float>](repeating: SIMD3(0, 1, 0), count: count)
        var areas = [Float](repeating: 0, count: count)
        for t in 0..<count {
            let p0 = positions[Int(indices[3 * t])]
            let p1 = positions[Int(indices[3 * t + 1])]
            let p2 = positions[Int(indices[3 * t + 2])]
            let c = simd_cross(p1 - p0, p2 - p0)
            let len = simd_length(c)
            areas[t] = len * 0.5
            if len > 1e-12 { normals[t] = c / len }
        }
        return (normals, areas)
    }
}

extension simd_float4x4 {
    /// Builds a matrix from 16 floats in column-major order.
    init(columnMajor a: [Float]) {
        precondition(a.count == 16, "Expected 16 floats")
        self.init(SIMD4(a[0], a[1], a[2], a[3]),
                  SIMD4(a[4], a[5], a[6], a[7]),
                  SIMD4(a[8], a[9], a[10], a[11]),
                  SIMD4(a[12], a[13], a[14], a[15]))
    }

    var columnMajorArray: [Float] {
        [columns.0.x, columns.0.y, columns.0.z, columns.0.w,
         columns.1.x, columns.1.y, columns.1.z, columns.1.w,
         columns.2.x, columns.2.y, columns.2.z, columns.2.w,
         columns.3.x, columns.3.y, columns.3.z, columns.3.w]
    }

    var translation: SIMD3<Float> { SIMD3(columns.3.x, columns.3.y, columns.3.z) }

    var upperLeft3x3: simd_float3x3 {
        simd_float3x3(SIMD3(columns.0.x, columns.0.y, columns.0.z),
                      SIMD3(columns.1.x, columns.1.y, columns.1.z),
                      SIMD3(columns.2.x, columns.2.y, columns.2.z))
    }

    @inline(__always)
    func transformPoint(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let r = self * SIMD4(p, 1)
        return SIMD3(r.x, r.y, r.z)
    }

    @inline(__always)
    func transformDirection(_ d: SIMD3<Float>) -> SIMD3<Float> {
        let r = self * SIMD4(d, 0)
        return SIMD3(r.x, r.y, r.z)
    }
}

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
