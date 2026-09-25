import Foundation
import SceneKit
import simd

enum SceneKitExportError: LocalizedError {
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let format): "SceneKit could not write the \(format) file."
        }
    }
}

/// Converts between ``ExportModel`` and SceneKit, and writes USDZ through SceneKit.
enum SceneKitExport {
    /// Builds a SceneKit node tree for an export model (used for USDZ).
    static func node(for model: ExportModel) -> SCNNode {
        let root = SCNNode()
        root.name = "Model"
        for mesh in model.meshes where mesh.triangleCount > 0 {
            var sources = [TexturedMeshAssets.vectorSource(mesh.positions, semantic: .vertex)]
            if mesh.hasNormals { sources.append(TexturedMeshAssets.vectorSource(mesh.normals, semantic: .normal)) }
            if mesh.hasUVs {
                sources.append(mesh.uvs.withUnsafeBytes {
                    SCNGeometrySource(data: Data($0), semantic: .texcoord, vectorCount: mesh.uvs.count, usesFloatComponents: true,
                                      componentsPerVector: 2, bytesPerComponent: 4, dataOffset: 0, dataStride: 8)
                })
            }
            var averageColor = SIMD3<Float>(0.6, 0.6, 0.6)
            if mesh.hasColors {
                sources.append(TexturedMeshAssets.colorSource(mesh.colors.map {
                    SIMD3(ColorSpaceMath.linear($0.x), ColorSpaceMath.linear($0.y), ColorSpaceMath.linear($0.z))
                }))
                let sum = mesh.colors.reduce(SIMD3<Float>.zero) { $0 + SIMD3(Float($1.x), Float($1.y), Float($1.z)) }
                averageColor = sum / Float(mesh.colors.count) / 255
            }
            let primitives = mesh.primitives.filter { !$0.indices.isEmpty }
            let elements = primitives.map { primitive in
                primitive.indices.withUnsafeBytes {
                    SCNGeometryElement(data: Data($0), primitiveType: .triangles, primitiveCount: primitive.indices.count / 3, bytesPerIndex: 4)
                }
            }
            let geometry = SCNGeometry(sources: sources, elements: elements)
            geometry.materials = primitives.map { primitive in
                let material = primitive.material < model.materials.count ? model.materials[primitive.material] : ExportModel.Material(name: "default")
                return scnMaterial(material, vertexColorFallback: averageColor)
            }
            let node = SCNNode(geometry: geometry)
            node.name = mesh.name
            root.addChildNode(node)
        }
        return root
    }

    static func scnMaterial(_ material: ExportModel.Material, vertexColorFallback: SIMD3<Float>) -> SCNMaterial {
        let m = SCNMaterial()
        m.name = material.name
        m.lightingModel = .physicallyBased
        m.roughness.contents = 1.0
        m.metalness.contents = 0.0
        m.isDoubleSided = material.doubleSided
        if let texture = material.texture {
            m.diffuse.contents = texture
            m.diffuse.wrapS = .clamp
            m.diffuse.wrapT = .clamp
            m.diffuse.mipFilter = .linear
        } else {
            // USD viewers generally ignore vertex colors, so fall back to their average.
            let rgb = material.usesVertexColors ? vertexColorFallback : SIMD3(material.baseColor.x, material.baseColor.y, material.baseColor.z)
            m.diffuse.contents = PlatformColor(rgb: rgb)
        }
        if material.baseColor.w < 0.999 { m.transparency = CGFloat(material.baseColor.w) }
        return m
    }

    static func writeUSDZ(_ model: ExportModel, to url: URL) throws {
        let scene = SCNScene()
        scene.rootNode.addChildNode(node(for: model))
        try writeUSDZ(scene, to: url)
    }

    static func writeUSDZ(_ scene: SCNScene, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        guard scene.write(to: url, options: nil, delegate: nil, progressHandler: nil),
              FileManager.default.fileExists(atPath: url.path) else {
            throw SceneKitExportError.writeFailed("USDZ")
        }
    }
}

extension PlatformColor {
    /// RGBA components in (extended) sRGB.
    var srgbComponents: SIMD4<Float> {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        #if canImport(UIKit)
        getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        (usingColorSpace(.sRGB) ?? self).getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        return SIMD4(Float(r), Float(g), Float(b), Float(a))
    }
}
