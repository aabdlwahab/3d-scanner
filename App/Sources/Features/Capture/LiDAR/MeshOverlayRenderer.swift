import ARKit
import SceneKit

enum MeshOverlayStyle: String, CaseIterable, Identifiable {
    case mesh, labels, normals, off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mesh: "Mesh"
        case .labels: "Surfaces"
        case .normals: "Normals"
        case .off: "Camera only"
        }
    }

    var systemImage: String {
        switch self {
        case .mesh: "square.grid.3x3"
        case .labels: "tag"
        case .normals: "paintpalette"
        case .off: "eye.slash"
        }
    }
}

/// Draws ARKit's live reconstruction mesh on top of the camera feed. All geometry work happens
/// on SceneKit's render thread (ARSCNViewDelegate callbacks); shared state is lock-protected.
final class MeshOverlayRenderer: @unchecked Sendable {
    private struct Entry {
        weak var node: SCNNode?
        var anchor: ARMeshAnchor
        var area: Float
        var styleVersion: Int
    }

    private let lock = NSLock()
    private var style: MeshOverlayStyle = .mesh
    private var styleVersion = 0
    private var entries: [UUID: Entry] = [:]

    private let fillMaterial: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .lambert
        m.diffuse.contents = UIColor(white: 1, alpha: 1)
        m.transparency = 0.22
        m.blendMode = .alpha
        m.writesToDepthBuffer = true
        return m
    }()

    private let wireMaterial: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.fillMode = .lines
        m.diffuse.contents = UIColor(red: 0.55, green: 0.84, blue: 1.0, alpha: 1)
        m.transparency = 0.6
        m.writesToDepthBuffer = false
        // Nudge the wireframe off the surface so it doesn't z-fight with the fill.
        m.shaderModifiers = [.geometry: "_geometry.position.xyz += _geometry.normal * 0.003;"]
        return m
    }()

    private let colorMaterial: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor.white
        m.transparency = 0.62
        m.blendMode = .alpha
        return m
    }()

    // MARK: Main thread

    func setStyle(_ newStyle: MeshOverlayStyle) {
        lock.lock()
        if style != newStyle {
            style = newStyle
            styleVersion += 1
        }
        lock.unlock()
    }

    func reset() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    /// Scanned surface area in m².
    var totalArea: Float {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.reduce(0) { $0 + $1.area }
    }

    // MARK: Render thread

    func makeNode(for anchor: ARMeshAnchor) -> SCNNode {
        let (style, version) = currentStyle()
        let node = SCNNode(geometry: Self.geometry(for: anchor, style: style, materials: materials(for: style)))
        node.isHidden = style == .off
        store(anchor, node: node, version: version)
        return node
    }

    func update(_ node: SCNNode, for anchor: ARMeshAnchor) {
        let (style, version) = currentStyle()
        node.geometry = Self.geometry(for: anchor, style: style, materials: materials(for: style))
        node.isHidden = style == .off
        store(anchor, node: node, version: version)
    }

    func remove(_ identifier: UUID) {
        lock.lock()
        entries[identifier] = nil
        lock.unlock()
    }

    /// Re-styles existing nodes after the style changed. Call once per frame on the render thread.
    func applyStyleIfNeeded() {
        lock.lock()
        let version = styleVersion
        let stale = entries.values.filter { $0.styleVersion != version }
        lock.unlock()
        for entry in stale {
            if let node = entry.node { update(node, for: entry.anchor) }
        }
    }

    private func currentStyle() -> (MeshOverlayStyle, Int) {
        lock.lock()
        defer { lock.unlock() }
        return (style, styleVersion)
    }

    private func store(_ anchor: ARMeshAnchor, node: SCNNode, version: Int) {
        let area = Self.area(of: anchor.geometry)
        lock.lock()
        entries[anchor.identifier] = Entry(node: node, anchor: anchor, area: area, styleVersion: version)
        lock.unlock()
    }

    private func materials(for style: MeshOverlayStyle) -> [SCNMaterial] {
        switch style {
        case .mesh, .off: [fillMaterial, wireMaterial]
        case .labels, .normals: [colorMaterial]
        }
    }

    // MARK: Geometry

    private static func geometry(for anchor: ARMeshAnchor, style: MeshOverlayStyle, materials: [SCNMaterial]) -> SCNGeometry {
        let mesh = anchor.geometry
        let vertices = mesh.vertices, normals = mesh.normals, faces = mesh.faces
        // Render straight from ARKit's Metal buffers — no copies.
        let vertexSource = SCNGeometrySource(buffer: vertices.buffer, vertexFormat: vertices.format, semantic: .vertex,
                                             vertexCount: vertices.count, dataOffset: vertices.offset, dataStride: vertices.stride)
        let normalSource = SCNGeometrySource(buffer: normals.buffer, vertexFormat: normals.format, semantic: .normal,
                                             vertexCount: normals.count, dataOffset: normals.offset, dataStride: normals.stride)
        func element() -> SCNGeometryElement {
            SCNGeometryElement(buffer: faces.buffer, primitiveType: .triangles, primitiveCount: faces.count,
                               bytesPerIndex: faces.bytesPerIndex)
        }
        let geometry: SCNGeometry
        switch style {
        case .mesh, .off:
            geometry = SCNGeometry(sources: [vertexSource, normalSource], elements: [element(), element()])
        case .labels:
            geometry = SCNGeometry(sources: [vertexSource, normalSource, classColors(mesh)], elements: [element()])
        case .normals:
            geometry = SCNGeometry(sources: [vertexSource, normalSource, normalColors(mesh, rotation: anchor.transform.upperLeft3x3)],
                                   elements: [element()])
        }
        geometry.materials = materials
        return geometry
    }

    private static func classColors(_ mesh: ARMeshGeometry) -> SCNGeometrySource {
        let fallback = ColorSpaceMath.linear(SurfaceClass.none.color)
        var colors = [SIMD3<Float>](repeating: fallback, count: mesh.vertices.count)
        if let classification = mesh.classification {
            let palette = SurfaceClass.allCases.map { ColorSpaceMath.linear($0.color) }
            let classes = classification.buffer.contents().advanced(by: classification.offset)
            let indices = mesh.faces.buffer.contents()
            let bytesPerIndex = mesh.faces.bytesPerIndex
            for f in 0..<mesh.faces.count {
                let raw = classes.load(fromByteOffset: f * classification.stride, as: UInt8.self)
                let color = raw < palette.count ? palette[Int(raw)] : fallback
                for corner in 0..<3 {
                    let v = Self.index(indices, f * 3 + corner, bytesPerIndex)
                    if v < colors.count { colors[v] = color }
                }
            }
        }
        return TexturedMeshAssets.colorSource(colors)
    }

    private static func normalColors(_ mesh: ARMeshGeometry, rotation: simd_float3x3) -> SCNGeometrySource {
        let normals = mesh.normals
        let base = normals.buffer.contents().advanced(by: normals.offset)
        var colors = [SIMD3<Float>](repeating: .zero, count: normals.count)
        for i in 0..<normals.count {
            let n = base.advanced(by: i * normals.stride).assumingMemoryBound(to: Float.self)
            let world = rotation * SIMD3(n[0], n[1], n[2])
            colors[i] = ColorSpaceMath.linear(world * 0.5 + 0.5)
        }
        return TexturedMeshAssets.colorSource(colors)
    }

    private static func area(of mesh: ARMeshGeometry) -> Float {
        let vertices = mesh.vertices
        let base = vertices.buffer.contents().advanced(by: vertices.offset)
        let indices = mesh.faces.buffer.contents()
        let bytesPerIndex = mesh.faces.bytesPerIndex
        func position(_ i: Int) -> SIMD3<Float> {
            let p = base.advanced(by: i * vertices.stride).assumingMemoryBound(to: Float.self)
            return SIMD3(p[0], p[1], p[2])
        }
        var total: Float = 0
        for f in 0..<mesh.faces.count {
            let a = index(indices, f * 3, bytesPerIndex)
            let b = index(indices, f * 3 + 1, bytesPerIndex)
            let c = index(indices, f * 3 + 2, bytesPerIndex)
            guard a < vertices.count, b < vertices.count, c < vertices.count else { continue }
            total += MeshMath.triangleArea(position(a), position(b), position(c))
        }
        return total
    }

    @inline(__always)
    static func index(_ buffer: UnsafeMutableRawPointer, _ i: Int, _ bytesPerIndex: Int) -> Int {
        bytesPerIndex == 2 ? Int(buffer.load(fromByteOffset: i * 2, as: UInt16.self))
            : Int(buffer.load(fromByteOffset: i * 4, as: UInt32.self))
    }
}

/// Copies ARKit mesh anchors into one world-space ``RawMesh``.
enum MeshExtractor {
    static func rawMesh(from anchors: [ARMeshAnchor]) -> RawMesh {
        var mesh = RawMesh()
        let totalVertices = anchors.reduce(0) { $0 + $1.geometry.vertices.count }
        let totalFaces = anchors.reduce(0) { $0 + $1.geometry.faces.count }
        mesh.positions.reserveCapacity(totalVertices)
        mesh.normals.reserveCapacity(totalVertices)
        mesh.indices.reserveCapacity(totalFaces * 3)
        mesh.classes.reserveCapacity(totalFaces)

        for anchor in anchors {
            let geometry = anchor.geometry
            let transform = anchor.transform
            let rotation = transform.upperLeft3x3
            let base = UInt32(mesh.positions.count)

            let vertices = geometry.vertices
            let vertexBase = vertices.buffer.contents().advanced(by: vertices.offset)
            for i in 0..<vertices.count {
                let p = vertexBase.advanced(by: i * vertices.stride).assumingMemoryBound(to: Float.self)
                mesh.positions.append(transform.transformPoint(SIMD3(p[0], p[1], p[2])))
            }
            let normals = geometry.normals
            let normalBase = normals.buffer.contents().advanced(by: normals.offset)
            for i in 0..<normals.count {
                let n = normalBase.advanced(by: i * normals.stride).assumingMemoryBound(to: Float.self)
                let world = rotation * SIMD3(n[0], n[1], n[2])
                let length = simd_length(world)
                mesh.normals.append(length > 1e-6 ? world / length : SIMD3(0, 1, 0))
            }
            let faces = geometry.faces
            let indexBuffer = faces.buffer.contents()
            for f in 0..<faces.count {
                for corner in 0..<3 {
                    let v = MeshOverlayRenderer.index(indexBuffer, f * 3 + corner, faces.bytesPerIndex)
                    mesh.indices.append(base + UInt32(min(v, vertices.count - 1)))
                }
            }
            if let classification = geometry.classification {
                let classes = classification.buffer.contents().advanced(by: classification.offset)
                for f in 0..<faces.count {
                    mesh.classes.append(classes.load(fromByteOffset: f * classification.stride, as: UInt8.self))
                }
            } else {
                mesh.classes.append(contentsOf: [UInt8](repeating: 0, count: faces.count))
            }
        }
        return mesh
    }
}
