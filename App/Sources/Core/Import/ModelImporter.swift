import Foundation
import ModelIO
import simd

/// Imports meshes and point clouds from other apps (PLY, OBJ, STL, USD/USDZ) through ModelIO.
enum ModelImporter {
    enum ImportError: LocalizedError {
        case unsupported(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .unsupported(let ext): "“.\(ext)” files can't be imported. Use PLY, OBJ, STL or USDZ."
            case .empty: "The file doesn't contain any geometry."
            }
        }
    }

    struct Result {
        var mesh: TexturedMesh?
        var points: PointCloud?
    }

    static let supportedExtensions = ["ply", "obj", "stl", "usd", "usda", "usdc", "usdz"]

    static func load(_ url: URL) throws -> Result {
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext), MDLAsset.canImportFileExtension(ext) else { throw ImportError.unsupported(ext) }
        let asset = MDLAsset(url: url)
        // Convert Z-up files (common for CAD / photogrammetry tools) to ScanSpace's +Y up.
        let zUp = asset.upAxis.z > 0.9
        func fix(_ p: SIMD3<Float>) -> SIMD3<Float> { zUp ? SIMD3(p.x, p.z, -p.y) : p }

        var mesh = TexturedMesh()
        var indices: [UInt32] = []
        var cloud = PointCloud()
        for object in asset.childObjects(of: MDLMesh.self) {
            guard let source = object as? MDLMesh, source.vertexCount > 0 else { continue }
            let transform = MDLTransform.globalTransform(with: source, atTime: 0)
            let rotation = transform.upperLeft3x3
            let positions = read(source, MDLVertexAttributePosition).map { fix(transform.transformPoint($0)) }
            let normals = read(source, MDLVertexAttributeNormal).map { fix(simd_normalize(rotation * $0)) }
            let colors = read(source, MDLVertexAttributeColor).map {
                SIMD4<UInt8>(UInt8(min(255, max(0, $0.x * 255))), UInt8(min(255, max(0, $0.y * 255))), UInt8(min(255, max(0, $0.z * 255))), 255)
            }
            let faces = triangles(source)
            if faces.isEmpty {
                cloud.positions += positions
                cloud.colors += colors.count == positions.count ? colors : [SIMD4<UInt8>](repeating: SIMD4(200, 200, 200, 255), count: positions.count)
                continue
            }
            let base = UInt32(mesh.positions.count)
            mesh.positions += positions
            mesh.normals += normals.count == positions.count ? normals : [SIMD3<Float>](repeating: .zero, count: positions.count)
            mesh.colors += colors.count == positions.count ? colors : [SIMD4<UInt8>](repeating: SIMD4(185, 185, 190, 255), count: positions.count)
            indices += faces.map { $0 + base }
        }

        var result = Result()
        if !indices.isEmpty {
            if mesh.normals.contains(.zero) { mesh.normals = MeshMath.vertexNormals(positions: mesh.positions, indices: indices) }
            mesh.uvs = [SIMD2<Float>](repeating: .zero, count: mesh.positions.count)
            mesh.classes = [UInt8](repeating: 0, count: mesh.positions.count)
            mesh.groups = [TexturedMesh.Group(textureIndex: -1, indices: indices)]
            result.mesh = mesh
        }
        if cloud.count > 0 { result.points = cloud }
        guard result.mesh != nil || result.points != nil else { throw ImportError.empty }
        return result
    }

    private static func read(_ mesh: MDLMesh, _ attribute: String) -> [SIMD3<Float>] {
        guard let data = mesh.vertexAttributeData(forAttributeNamed: attribute, as: .float3) else { return [] }
        return (0..<mesh.vertexCount).map { i in
            let p = data.dataStart.advanced(by: i * data.stride).assumingMemoryBound(to: Float.self)
            return SIMD3(p[0], p[1], p[2])
        }
    }

    private static func triangles(_ mesh: MDLMesh) -> [UInt32] {
        var result: [UInt32] = []
        for case let submesh as MDLSubmesh in mesh.submeshes ?? [] {
            let buffer = submesh.indexBuffer(asIndexType: .uInt32)
            let map = buffer.map()
            let values = UnsafeBufferPointer(start: map.bytes.assumingMemoryBound(to: UInt32.self), count: submesh.indexCount)
            switch submesh.geometryType {
            case .triangles:
                result += values.prefix(values.count / 3 * 3)
            case .quads:
                var i = 0
                while i + 3 < values.count {
                    result += [values[i], values[i + 1], values[i + 2], values[i], values[i + 2], values[i + 3]]
                    i += 4
                }
            case .triangleStrips:
                if values.count >= 3 {
                    for i in 0..<(values.count - 2) {
                        result += i % 2 == 0 ? [values[i], values[i + 1], values[i + 2]] : [values[i + 1], values[i], values[i + 2]]
                    }
                }
            default:
                continue
            }
        }
        return result.filter { Int($0) < mesh.vertexCount }.count == result.count ? result : []
    }
}
