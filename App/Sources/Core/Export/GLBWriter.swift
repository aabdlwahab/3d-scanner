import Foundation
import simd

/// Writes binary glTF 2.0 (.glb) with embedded JPEG/PNG textures.
enum GLBWriter {
    enum GLBError: LocalizedError {
        case emptyModel

        var errorDescription: String? { "There is no geometry to export." }
    }

    static func write(_ model: ExportModel, to url: URL, generator: String = "ScanSpace") throws {
        try data(for: model, generator: generator).write(to: url, options: .atomic)
    }

    static func data(for model: ExportModel, generator: String = "ScanSpace") throws -> Data {
        guard model.triangleCount > 0 else { throw GLBError.emptyModel }
        var binary = Data()
        var bufferViews: [[String: Any]] = []
        var accessors: [[String: Any]] = []

        func addBufferView(_ bytes: Data, target: Int?) -> Int {
            while binary.count % 4 != 0 { binary.append(0) }
            var view: [String: Any] = ["buffer": 0, "byteOffset": binary.count, "byteLength": bytes.count]
            if let target { view["target"] = target }
            binary.append(bytes)
            bufferViews.append(view)
            return bufferViews.count - 1
        }

        func addAccessor(view: Int, componentType: Int, count: Int, type: String,
                         min: [Double]? = nil, max: [Double]? = nil) -> Int {
            var accessor: [String: Any] = ["bufferView": view, "componentType": componentType, "count": count, "type": type]
            if let min { accessor["min"] = min }
            if let max { accessor["max"] = max }
            accessors.append(accessor)
            return accessors.count - 1
        }

        let arrayBuffer = 34962, elementArrayBuffer = 34963
        let float = 5126, unsignedInt = 5125

        // Images and textures.
        var images: [[String: Any]] = []
        var textures: [[String: Any]] = []
        var textureIndexForMaterial: [Int: Int] = [:]
        for (i, material) in model.materials.enumerated() {
            guard let textureURL = material.texture, let bytes = try? Data(contentsOf: textureURL) else { continue }
            let view = addBufferView(bytes, target: nil)
            let mime = textureURL.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
            images.append(["bufferView": view, "mimeType": mime, "name": textureURL.deletingPathExtension().lastPathComponent])
            textures.append(["sampler": 0, "source": images.count - 1])
            textureIndexForMaterial[i] = textures.count - 1
        }

        var usesUnlit = false
        let materials: [[String: Any]] = model.materials.enumerated().map { i, material in
            // glTF factors and vertex colors are linear; textures stay sRGB-encoded.
            let linear = ColorSpaceMath.linear(SIMD3(material.baseColor.x, material.baseColor.y, material.baseColor.z))
            var pbr: [String: Any] = [
                "baseColorFactor": [Double(linear.x), Double(linear.y), Double(linear.z), Double(material.baseColor.w)],
                "metallicFactor": 0.0,
                "roughnessFactor": 1.0,
            ]
            if let texture = textureIndexForMaterial[i] { pbr["baseColorTexture"] = ["index": texture] }
            var json: [String: Any] = ["name": material.name, "pbrMetallicRoughness": pbr, "doubleSided": material.doubleSided]
            if material.baseColor.w < 0.999 { json["alphaMode"] = "BLEND" }
            if material.unlit {
                usesUnlit = true
                json["extensions"] = ["KHR_materials_unlit": [String: Any]()]
            }
            return json
        }

        // Meshes.
        var meshes: [[String: Any]] = []
        var nodes: [[String: Any]] = []
        for mesh in model.meshes where mesh.triangleCount > 0 {
            let box = BoundingBox(points: mesh.positions)
            var attributes: [String: Int] = [:]
            attributes["POSITION"] = addAccessor(
                view: addBufferView(packed(mesh.positions), target: arrayBuffer), componentType: float,
                count: mesh.positions.count, type: "VEC3",
                min: [Double(box.min.x), Double(box.min.y), Double(box.min.z)],
                max: [Double(box.max.x), Double(box.max.y), Double(box.max.z)])
            if mesh.hasNormals {
                let normals = mesh.normals.map { v -> SIMD3<Float> in
                    let len = simd_length(v)
                    return len > 1e-6 ? v / len : SIMD3(0, 1, 0)
                }
                attributes["NORMAL"] = addAccessor(view: addBufferView(packed(normals), target: arrayBuffer),
                                                   componentType: float, count: normals.count, type: "VEC3")
            }
            if mesh.hasUVs {
                attributes["TEXCOORD_0"] = addAccessor(view: addBufferView(raw(mesh.uvs), target: arrayBuffer),
                                                       componentType: float, count: mesh.uvs.count, type: "VEC2")
            }
            if mesh.hasColors {
                var linear = [Float]()
                linear.reserveCapacity(mesh.colors.count * 4)
                for c in mesh.colors {
                    linear.append(ColorSpaceMath.linear(c.x))
                    linear.append(ColorSpaceMath.linear(c.y))
                    linear.append(ColorSpaceMath.linear(c.z))
                    linear.append(Float(c.w) / 255)
                }
                attributes["COLOR_0"] = addAccessor(view: addBufferView(raw(linear), target: arrayBuffer),
                                                    componentType: float, count: mesh.colors.count, type: "VEC4")
            }
            var primitives: [[String: Any]] = []
            for primitive in mesh.primitives where !primitive.indices.isEmpty {
                let indexAccessor = addAccessor(view: addBufferView(raw(primitive.indices), target: elementArrayBuffer),
                                                componentType: unsignedInt, count: primitive.indices.count, type: "SCALAR")
                primitives.append(["attributes": attributes, "indices": indexAccessor, "material": primitive.material, "mode": 4])
            }
            meshes.append(["name": mesh.name, "primitives": primitives])
            nodes.append(["name": mesh.name, "mesh": meshes.count - 1])
        }

        var json: [String: Any] = [
            "asset": ["version": "2.0", "generator": generator],
            "scene": 0,
            "scenes": [["name": "Scene", "nodes": Array(0..<nodes.count)]],
            "nodes": nodes,
            "meshes": meshes,
            "materials": materials,
            "accessors": accessors,
            "bufferViews": bufferViews,
            "buffers": [["byteLength": binary.count]],
        ]
        if !images.isEmpty {
            json["images"] = images
            json["textures"] = textures
            // Linear filtering with trilinear mipmaps; clamp so atlas charts never wrap.
            json["samplers"] = [["magFilter": 9729, "minFilter": 9987, "wrapS": 33071, "wrapT": 33071]]
        }
        if usesUnlit { json["extensionsUsed"] = ["KHR_materials_unlit"] }

        var jsonData = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        while jsonData.count % 4 != 0 { jsonData.append(0x20) }
        while binary.count % 4 != 0 { binary.append(0) }

        var out = BinaryWriter(reserving: 28 + jsonData.count + binary.count)
        out.write(UInt32(0x4654_6C67))  // "glTF"
        out.write(UInt32(2))
        out.write(UInt32(12 + 8 + jsonData.count + 8 + binary.count))
        out.write(UInt32(jsonData.count))
        out.write(UInt32(0x4E4F_534A))  // "JSON"
        var data = out.data
        data.append(jsonData)
        var binHeader = BinaryWriter()
        binHeader.write(UInt32(binary.count))
        binHeader.write(UInt32(0x004E_4942))  // "BIN\0"
        data.append(binHeader.data)
        data.append(binary)
        return data
    }

    private static func packed(_ vectors: [SIMD3<Float>]) -> Data {
        raw(InlineVectors.pack(vectors))
    }

    private static func raw<T>(_ array: [T]) -> Data {
        array.withUnsafeBytes { Data($0) }
    }
}
