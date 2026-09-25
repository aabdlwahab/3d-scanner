import Foundation
import simd

/// Wavefront OBJ + MTL (+ texture files copied next to them).
enum OBJWriter {
    /// Writes `<baseName>.obj`, `<baseName>.mtl` and the textures into `directory`.
    /// Returns every written file.
    static func write(_ model: ExportModel, to directory: URL, baseName: String) throws -> [URL] {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var files: [URL] = []

        // Materials and textures.
        var mtl = ASCIIBuffer()
        mtl.append("# ScanSpace material library\n")
        var textureNames: [URL: String] = [:]
        for material in model.materials {
            mtl.append("\nnewmtl \(sanitized(material.name))\n")
            mtl.append("Ka 0 0 0\nKs 0 0 0\n")
            mtl.append("Kd ")
            mtl.append(material.baseColor.x, decimals: 4)
            mtl.append(" ")
            mtl.append(material.baseColor.y, decimals: 4)
            mtl.append(" ")
            mtl.append(material.baseColor.z, decimals: 4)
            mtl.append("\nd ")
            mtl.append(material.baseColor.w, decimals: 4)
            mtl.append("\nillum 1\n")
            if let texture = material.texture {
                let name = textureNames[texture] ?? texture.lastPathComponent
                if textureNames[texture] == nil {
                    textureNames[texture] = name
                    let destination = directory.appendingPathComponent(name)
                    if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                    try fm.copyItem(at: texture, to: destination)
                    files.append(destination)
                }
                mtl.append("map_Kd \(name)\n")
            }
        }
        let mtlURL = directory.appendingPathComponent("\(baseName).mtl")
        try mtl.data.write(to: mtlURL, options: .atomic)
        files.insert(mtlURL, at: 0)

        // Geometry.
        let estimated = model.meshes.reduce(0) { $0 + $1.positions.count * 90 + $1.triangleCount * 40 }
        var obj = ASCIIBuffer(reserving: estimated)
        obj.append("# ScanSpace export — units: meters, +Y up\nmtllib \(baseName).mtl\n")
        var vertexOffset = 1
        for mesh in model.meshes where mesh.triangleCount > 0 {
            obj.append("\no \(sanitized(mesh.name))\n")
            for (i, p) in mesh.positions.enumerated() {
                obj.append("v ")
                obj.append(p.x); obj.append(byte: 32); obj.append(p.y); obj.append(byte: 32); obj.append(p.z)
                if mesh.hasColors {
                    let c = mesh.colors[i]
                    obj.append(byte: 32); obj.append(Float(c.x) / 255, decimals: 3)
                    obj.append(byte: 32); obj.append(Float(c.y) / 255, decimals: 3)
                    obj.append(byte: 32); obj.append(Float(c.z) / 255, decimals: 3)
                }
                obj.append(byte: 10)
            }
            if mesh.hasUVs {
                for uv in mesh.uvs {
                    // OBJ's texture origin is the bottom-left corner.
                    obj.append("vt ")
                    obj.append(uv.x, decimals: 6); obj.append(byte: 32); obj.append(1 - uv.y, decimals: 6)
                    obj.append(byte: 10)
                }
            }
            if mesh.hasNormals {
                for n in mesh.normals {
                    obj.append("vn ")
                    obj.append(n.x, decimals: 4); obj.append(byte: 32); obj.append(n.y, decimals: 4)
                    obj.append(byte: 32); obj.append(n.z, decimals: 4)
                    obj.append(byte: 10)
                }
            }
            for primitive in mesh.primitives where !primitive.indices.isEmpty {
                let materialName = primitive.material < model.materials.count ? model.materials[primitive.material].name : "default"
                obj.append("usemtl \(sanitized(materialName))\n")
                var t = 0
                while t + 2 < primitive.indices.count {
                    obj.append("f")
                    for k in 0..<3 {
                        let index = Int(primitive.indices[t + k]) + vertexOffset
                        obj.append(byte: 32)
                        obj.append(index)
                        if mesh.hasUVs || mesh.hasNormals {
                            obj.append(byte: 47)
                            if mesh.hasUVs { obj.append(index) }
                            if mesh.hasNormals {
                                obj.append(byte: 47)
                                obj.append(index)
                            }
                        }
                    }
                    obj.append(byte: 10)
                    t += 3
                }
            }
            vertexOffset += mesh.positions.count
        }
        let objURL = directory.appendingPathComponent("\(baseName).obj")
        try obj.data.write(to: objURL, options: .atomic)
        files.insert(objURL, at: 0)
        return files
    }

    private static func sanitized(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
    }
}

/// Binary little-endian PLY for meshes (with vertex colors) and point clouds.
enum PLYWriter {
    static func writeMesh(positions: [SIMD3<Float>], normals: [SIMD3<Float>], colors: [SIMD4<UInt8>],
                          indices: [UInt32], to url: URL) throws {
        let hasNormals = normals.count == positions.count
        let hasColors = colors.count == positions.count
        var header = "ply\nformat binary_little_endian 1.0\ncomment Created by ScanSpace (meters, +Y up)\n"
        header += "element vertex \(positions.count)\nproperty float x\nproperty float y\nproperty float z\n"
        if hasNormals { header += "property float nx\nproperty float ny\nproperty float nz\n" }
        if hasColors { header += "property uchar red\nproperty uchar green\nproperty uchar blue\n" }
        header += "element face \(indices.count / 3)\nproperty list uchar int vertex_indices\nend_header\n"

        let vertexSize = 12 + (hasNormals ? 12 : 0) + (hasColors ? 3 : 0)
        var w = BinaryWriter(reserving: header.utf8.count + positions.count * vertexSize + indices.count / 3 * 13)
        w.writeMagic(header)
        for i in positions.indices {
            let p = positions[i]
            w.write(p.x); w.write(p.y); w.write(p.z)
            if hasNormals {
                let n = normals[i]
                w.write(n.x); w.write(n.y); w.write(n.z)
            }
            if hasColors {
                let c = colors[i]
                w.write(c.x); w.write(c.y); w.write(c.z)
            }
        }
        var t = 0
        while t + 2 < indices.count {
            w.write(UInt8(3))
            w.write(Int32(indices[t])); w.write(Int32(indices[t + 1])); w.write(Int32(indices[t + 2]))
            t += 3
        }
        try w.data.write(to: url, options: .atomic)
    }

    static func writePoints(_ cloud: PointCloud, to url: URL) throws {
        let header = "ply\nformat binary_little_endian 1.0\ncomment Created by ScanSpace (meters, +Y up)\n"
            + "element vertex \(cloud.count)\nproperty float x\nproperty float y\nproperty float z\n"
            + "property uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n"
        var w = BinaryWriter(reserving: header.utf8.count + cloud.count * 15)
        w.writeMagic(header)
        let hasColors = cloud.colors.count == cloud.count
        for i in 0..<cloud.count {
            let p = cloud.positions[i]
            w.write(p.x); w.write(p.y); w.write(p.z)
            let c = hasColors ? cloud.colors[i] : SIMD4(200, 200, 200, 255)
            w.write(c.x); w.write(c.y); w.write(c.z)
        }
        try w.data.write(to: url, options: .atomic)
    }
}

/// Binary STL in millimeters with +Z up (what slicers and CAD tools expect).
enum STLWriter {
    static func write(_ model: ExportModel, to url: URL) throws {
        let triangleCount = model.triangleCount
        var w = BinaryWriter(reserving: 84 + triangleCount * 50)
        var header = Array("ScanSpace STL export - millimeters, Z up".utf8)
        header += [UInt8](repeating: 0x20, count: max(0, 80 - header.count))
        w.writeRaw(Array(header.prefix(80)))
        w.write(UInt32(triangleCount))
        func convert(_ p: SIMD3<Float>) -> SIMD3<Float> { SIMD3(p.x, -p.z, p.y) * 1000 }
        for mesh in model.meshes {
            for primitive in mesh.primitives {
                var t = 0
                while t + 2 < primitive.indices.count {
                    let a = convert(mesh.positions[Int(primitive.indices[t])])
                    let b = convert(mesh.positions[Int(primitive.indices[t + 1])])
                    let c = convert(mesh.positions[Int(primitive.indices[t + 2])])
                    var n = simd_cross(b - a, c - a)
                    let len = simd_length(n)
                    n = len > 0 ? n / len : .zero
                    for v in [n, a, b, c] {
                        w.write(v.x); w.write(v.y); w.write(v.z)
                    }
                    w.write(UInt16(0))
                    t += 3
                }
            }
        }
        try w.data.write(to: url, options: .atomic)
    }
}
