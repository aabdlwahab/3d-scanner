import Foundation
import SceneKit
import simd

/// How a LiDAR scan is drawn in the viewer.
enum RenderStyle: String, CaseIterable, Identifiable {
    case textured, shaded, wireframe, classes, points

    var id: String { rawValue }

    var title: String {
        switch self {
        case .textured: "Texture"
        case .shaded: "Solid"
        case .wireframe: "Wire"
        case .classes: "Labels"
        case .points: "Points"
        }
    }

    var systemImage: String {
        switch self {
        case .textured: "photo"
        case .shaded: "cube.fill"
        case .wireframe: "square.grid.3x3"
        case .classes: "tag"
        case .points: "circle.grid.3x3.fill"
        }
    }
}

/// Builds SceneKit geometry for processed scans. Sources are created once and shared by the
/// per-style geometries so switching styles is cheap.
final class TexturedMeshAssets {
    let mesh: TexturedMesh
    let textureURLs: [URL]
    let bounds: BoundingBox
    private let vertexSource: SCNGeometrySource
    private let normalSource: SCNGeometrySource
    private let uvSource: SCNGeometrySource
    private lazy var classColorSource: SCNGeometrySource = Self.colorSource(
        mesh.classes.count == mesh.vertexCount ? mesh.classes.map { ColorSpaceMath.linear(SurfaceClass.from($0).color) }
            : [SIMD3<Float>](repeating: ColorSpaceMath.linear(SurfaceClass.none.color), count: mesh.vertexCount))
    /// White for textured vertices (leaves the texture untouched) and the flood-filled color
    /// for vertices no photo could texture.
    private lazy var tintSource: SCNGeometrySource? = {
        guard let fill = mesh.groups.first(where: { $0.textureIndex < 0 }), mesh.colors.count == mesh.vertexCount else { return nil }
        var tint = [SIMD3<Float>](repeating: SIMD3(1, 1, 1), count: mesh.vertexCount)
        for index in fill.indices {
            let c = mesh.colors[Int(index)]
            tint[Int(index)] = SIMD3(ColorSpaceMath.linear(c.x), ColorSpaceMath.linear(c.y), ColorSpaceMath.linear(c.z))
        }
        return Self.colorSource(tint)
    }()
    private lazy var elements: [SCNGeometryElement] = mesh.groups.map { group in
        group.indices.withUnsafeBytes { raw in
            SCNGeometryElement(data: Data(raw), primitiveType: .triangles, primitiveCount: group.indices.count / 3, bytesPerIndex: 4)
        }
    }
    private var cache: [RenderStyle: SCNGeometry] = [:]

    init(mesh: TexturedMesh, textureURLs: [URL]) {
        self.mesh = mesh
        self.textureURLs = textureURLs
        self.bounds = BoundingBox(points: mesh.positions)
        vertexSource = Self.vectorSource(mesh.positions, semantic: .vertex)
        normalSource = Self.vectorSource(mesh.normals.count == mesh.vertexCount ? mesh.normals
            : MeshMath.vertexNormals(positions: mesh.positions, indices: mesh.groups.flatMap(\.indices)), semantic: .normal)
        let uvs = mesh.uvs.count == mesh.vertexCount ? mesh.uvs : [SIMD2<Float>](repeating: .zero, count: mesh.vertexCount)
        uvSource = uvs.withUnsafeBytes { raw in
            SCNGeometrySource(data: Data(raw), semantic: .texcoord, vectorCount: uvs.count, usesFloatComponents: true,
                              componentsPerVector: 2, bytesPerComponent: 4, dataOffset: 0, dataStride: 8)
        }
    }

    convenience init(files: ScanFiles) throws {
        let mesh = try TexturedMesh.read(from: files.texturedMesh)
        self.init(mesh: mesh, textureURLs: files.textureURLs(count: mesh.textureCount))
    }

    /// Geometry for a style (points are handled by ``ScanSceneBuilder/pointCloudNode(_:)``).
    func geometry(for style: RenderStyle) -> SCNGeometry {
        if let cached = cache[style] { return cached }
        let geometry: SCNGeometry
        switch style {
        case .textured, .points:
            geometry = SCNGeometry(sources: [vertexSource, normalSource, uvSource] + (tintSource.map { [$0] } ?? []), elements: elements)
            geometry.materials = mesh.groups.map { group in
                group.textureIndex >= 0 && group.textureIndex < textureURLs.count
                    ? ScanSceneBuilder.textureMaterial(textureURLs[group.textureIndex])
                    : ScanSceneBuilder.untexturedMaterial()
            }
        case .shaded:
            geometry = SCNGeometry(sources: [vertexSource, normalSource], elements: elements)
            geometry.materials = [ScanSceneBuilder.clayMaterial()]
        case .wireframe:
            geometry = SCNGeometry(sources: [vertexSource, normalSource], elements: elements)
            geometry.materials = [ScanSceneBuilder.wireMaterial()]
        case .classes:
            geometry = SCNGeometry(sources: [vertexSource, normalSource, classColorSource], elements: elements)
            geometry.materials = [ScanSceneBuilder.vertexColorMaterial(lit: true)]
        }
        cache[style] = geometry
        return geometry
    }

    static func vectorSource(_ vectors: [SIMD3<Float>], semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
        var packed = [Float]()
        packed.reserveCapacity(vectors.count * 3)
        for v in vectors {
            packed.append(v.x)
            packed.append(v.y)
            packed.append(v.z)
        }
        return packed.withUnsafeBytes { raw in
            SCNGeometrySource(data: Data(raw), semantic: semantic, vectorCount: vectors.count, usesFloatComponents: true,
                              componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        }
    }

    static func colorSource(_ colors: [SIMD3<Float>]) -> SCNGeometrySource {
        vectorSource(colors, semantic: .color)
    }
}

enum ScanSceneBuilder {
    // MARK: Materials

    static func textureMaterial(_ url: URL) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = url
        material.diffuse.mipFilter = .linear
        material.diffuse.minificationFilter = .linear
        material.diffuse.magnificationFilter = .linear
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        material.isDoubleSided = false
        return material
    }

    /// Material for triangles no photo could texture: white diffuse, so the per-vertex fill
    /// colors show through (they fall back to mid gray when there is no color source).
    static func untexturedMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = PlatformColor(white: 1, alpha: 1)
        return material
    }

    static func clayMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = PlatformColor(white: 0.82, alpha: 1)
        material.roughness.contents = 0.85
        material.metalness.contents = 0.0
        return material
    }

    static func wireMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.fillMode = .lines
        material.diffuse.contents = PlatformColor(hex: 0x7C8CFF)
        material.isDoubleSided = true
        return material
    }

    static func vertexColorMaterial(lit: Bool) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = lit ? .lambert : .constant
        material.diffuse.contents = PlatformColor.white
        return material
    }

    // MARK: Nodes

    static func pointCloudNode(_ cloud: PointCloud, pointSize: CGFloat = 0.012) -> SCNNode {
        let positions = InlineVectors.pack(cloud.positions)
        var colors = [Float]()
        colors.reserveCapacity(cloud.count * 3)
        for c in cloud.colors {
            colors.append(ColorSpaceMath.linear(c.x))
            colors.append(ColorSpaceMath.linear(c.y))
            colors.append(ColorSpaceMath.linear(c.z))
        }
        let vertexSource = positions.withUnsafeBytes {
            SCNGeometrySource(data: Data($0), semantic: .vertex, vectorCount: cloud.count, usesFloatComponents: true,
                              componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        }
        let colorSource = colors.withUnsafeBytes {
            SCNGeometrySource(data: Data($0), semantic: .color, vectorCount: cloud.count, usesFloatComponents: true,
                              componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        }
        let indices = (0..<UInt32(cloud.count)).map { $0 }
        let element = indices.withUnsafeBytes {
            SCNGeometryElement(data: Data($0), primitiveType: .point, primitiveCount: cloud.count, bytesPerIndex: 4)
        }
        element.pointSize = pointSize
        element.minimumPointScreenSpaceRadius = 1
        element.maximumPointScreenSpaceRadius = 5
        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        geometry.materials = [vertexColorMaterial(lit: false)]
        let node = SCNNode(geometry: geometry)
        node.name = "points"
        return node
    }

    /// Soft studio lighting used for solid / label styles (textured materials are unlit).
    static func addStudioLights(to root: SCNNode) {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 450
        ambient.light?.color = PlatformColor(white: 1, alpha: 1)
        ambient.name = "ambient-light"
        root.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
        key.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 5, 0)
        key.name = "key-light"
        root.addChildNode(key)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .directional
        fill.light?.intensity = 350
        fill.eulerAngles = SCNVector3(-Float.pi / 6, -Float.pi * 0.8, 0)
        fill.name = "fill-light"
        root.addChildNode(fill)
    }

    /// A camera positioned for a "dollhouse" view: above and to the side, looking at the center.
    static func makeCamera(framing bounds: BoundingBox, aspect: Float = 1) -> SCNNode {
        let camera = SCNCamera()
        camera.fieldOfView = 55
        camera.zNear = 0.01
        camera.zFar = Double(max(50, bounds.radius * 30))
        let node = SCNNode()
        node.camera = camera
        node.name = "camera"
        frame(node, on: bounds)
        return node
    }

    static func frame(_ cameraNode: SCNNode, on bounds: BoundingBox, direction: SIMD3<Float> = SIMD3(0.55, 0.95, 0.85)) {
        let center = bounds.center
        let radius = max(bounds.radius, 0.2)
        let distance = radius / tan(Float(27.5) * .pi / 180) * 1.05
        let position = center + simd_normalize(direction) * distance
        cameraNode.simdPosition = position
        cameraNode.simdLook(at: center, up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
    }
}

enum InlineVectors {
    static func pack(_ vectors: [SIMD3<Float>]) -> [Float] {
        var packed = [Float]()
        packed.reserveCapacity(vectors.count * 3)
        for v in vectors {
            packed.append(v.x)
            packed.append(v.y)
            packed.append(v.z)
        }
        return packed
    }
}
