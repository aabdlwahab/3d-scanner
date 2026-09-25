import Foundation
import simd

/// Format-neutral description of what gets exported: meshes with shared vertex arrays,
/// primitives (index lists) that reference materials.
struct ExportModel {
    struct Material {
        var name: String
        /// sRGB base color (multiplied with the texture when present).
        var baseColor: SIMD4<Float> = SIMD4(1, 1, 1, 1)
        var texture: URL?
        /// Scanned textures already contain lighting; unlit materials show them as captured.
        var unlit = false
        var doubleSided = false
        /// Whether the mesh's vertex colors should color this material.
        var usesVertexColors = false
    }

    struct Primitive {
        var indices: [UInt32]
        var material: Int
    }

    struct Mesh {
        var name: String
        var positions: [SIMD3<Float>]
        var normals: [SIMD3<Float>] = []
        /// Texture coordinates, origin at the top-left of the image.
        var uvs: [SIMD2<Float>] = []
        /// sRGB vertex colors.
        var colors: [SIMD4<UInt8>] = []
        var primitives: [Primitive]

        var hasNormals: Bool { !normals.isEmpty && normals.count == positions.count }
        var hasUVs: Bool { !uvs.isEmpty && uvs.count == positions.count }
        var hasColors: Bool { !colors.isEmpty && colors.count == positions.count }
        var triangleCount: Int { primitives.reduce(0) { $0 + $1.indices.count / 3 } }
    }

    var meshes: [Mesh] = []
    var materials: [Material] = []

    var triangleCount: Int { meshes.reduce(0) { $0 + $1.triangleCount } }

    var bounds: BoundingBox {
        var box = BoundingBox.empty
        for mesh in meshes { box.formUnion(BoundingBox(points: mesh.positions)) }
        return box
    }
}

extension ExportModel {
    /// Export model for a processed LiDAR scan: one textured mesh plus, if some triangles could
    /// not be textured, a separate vertex-colored "fill" mesh.
    init(textured mesh: TexturedMesh, textureURLs: [URL], name: String) {
        self.init()
        for (i, url) in textureURLs.enumerated() {
            materials.append(Material(name: "texture_\(i)", texture: url, unlit: true))
        }
        let texturedPrimitives = mesh.groups.filter { $0.textureIndex >= 0 && $0.textureIndex < textureURLs.count }
            .map { Primitive(indices: $0.indices, material: $0.textureIndex) }
        if !texturedPrimitives.isEmpty {
            // Compact to the vertices actually used by textured primitives.
            var remap = [Int32](repeating: -1, count: mesh.vertexCount)
            var out = Mesh(name: name, positions: [], normals: [], uvs: [], primitives: [])
            for primitive in texturedPrimitives {
                var indices = [UInt32]()
                indices.reserveCapacity(primitive.indices.count)
                for index in primitive.indices {
                    let v = Int(index)
                    if remap[v] < 0 {
                        remap[v] = Int32(out.positions.count)
                        out.positions.append(mesh.positions[v])
                        out.normals.append(mesh.normals[v])
                        out.uvs.append(mesh.uvs[v])
                    }
                    indices.append(UInt32(remap[v]))
                }
                out.primitives.append(Primitive(indices: indices, material: primitive.material))
            }
            meshes.append(out)
        }
        let fillIndices = mesh.groups.filter { $0.textureIndex < 0 || $0.textureIndex >= textureURLs.count }.flatMap(\.indices)
        if !fillIndices.isEmpty {
            let fillMaterial = materials.count
            materials.append(Material(name: "untextured", baseColor: SIMD4(1, 1, 1, 1), unlit: true, usesVertexColors: true))
            var remap = [UInt32: UInt32]()
            var out = Mesh(name: name + "_fill", positions: [], normals: [], colors: [], primitives: [])
            var indices = [UInt32]()
            for index in fillIndices {
                if let existing = remap[index] {
                    indices.append(existing)
                    continue
                }
                let v = Int(index)
                let newIndex = UInt32(out.positions.count)
                remap[index] = newIndex
                out.positions.append(mesh.positions[v])
                out.normals.append(mesh.normals[v])
                out.colors.append(mesh.colors.count == mesh.vertexCount ? mesh.colors[v] : SIMD4(150, 150, 150, 255))
                indices.append(newIndex)
            }
            out.primitives = [Primitive(indices: indices, material: fillMaterial)]
            meshes.append(out)
        }
    }
}
