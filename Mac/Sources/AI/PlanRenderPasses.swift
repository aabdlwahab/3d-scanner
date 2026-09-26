import AppKit
import CoreGraphics
import SceneKit
import simd

/// A camera for AI renders of a floor plan.
struct PlanCamera: Codable, Equatable {
    var name: String
    var position: SIMD3<Float>
    var target: SIMD3<Float>
    /// Vertical field of view in degrees.
    var fieldOfView: Float
    /// Interior shots get a ceiling; the overview is a cut-away "dollhouse".
    var isInterior: Bool
    /// The room the camera stands in (a `FloorPlanData.Section` label), if any.
    var roomLabel: String?
}

/// What an AI render is conditioned on, all drawn from the same camera.
struct PlanRenderPasses {
    /// Neutral clay model with soft lighting (input for image-editing models, and the "before" image).
    var clay: CGImage
    /// Inverse depth, near = white, far and empty = black (ControlNet depth input).
    var depth: CGImage
    /// Flat ADE20K class colors (ControlNet segmentation input).
    var segmentation: CGImage
    /// Where the model covers the image (white) versus empty background (black).
    var mask: CGImage
    /// Furniture actually visible from the camera (walls occlude), largest on screen first.
    var visible: [VisibleObject]

    var visibleObjects: [FloorPlanData.Object] { visible.map(\.object) }
}

struct VisibleObject {
    var object: FloorPlanData.Object
    /// Fraction of the image it covers.
    var coverage: Float
    /// Centre of its visible pixels, 0...1 from the top-left corner.
    var center: SIMD2<Float>
}

/// Semantic classes used for segmentation renders, with their ADE20K palette colors (the palette
/// the ControlNet segmentation model was trained on; values from mmsegmentation's ADE20K dataset).
enum ADE20K {
    static let wall = SIMD3<UInt8>(120, 120, 120)
    static let floor = SIMD3<UInt8>(80, 50, 50)
    static let ceiling = SIMD3<UInt8>(120, 120, 80)
    static let window = SIMD3<UInt8>(230, 230, 230)
    static let door = SIMD3<UInt8>(8, 255, 51)
    static let background = SIMD3<UInt8>(0, 0, 0)

    /// Palette color for a RoomPlan object category; the size tells coffee tables from dining
    /// tables and wardrobes from low cabinets.
    static func color(for object: FloorPlanData.Object) -> SIMD3<UInt8> {
        let height = object.size.y
        switch object.category {
        case "sofa": return SIMD3(11, 102, 255)
        case "table": return height < 0.6 ? SIMD3(0, 255, 112) : SIMD3(255, 6, 82) // coffee table : table
        case "chair": return height < 0.85 && object.size.x > 0.7 ? SIMD3(8, 255, 214) : SIMD3(204, 70, 3) // armchair : chair
        case "bed": return SIMD3(204, 5, 255)
        case "storage":
            if height > 1.5 { return min(object.size.x, object.size.z) >= 0.5 ? SIMD3(7, 255, 255) : SIMD3(0, 255, 245) } // wardrobe : bookcase
            return height < 0.7 ? SIMD3(6, 51, 255) : SIMD3(224, 5, 255) // chest of drawers : cabinet
        case "refrigerator": return SIMD3(20, 255, 0)
        case "stove": return SIMD3(51, 255, 0)
        case "oven": return SIMD3(71, 255, 0)
        case "dishwasher": return SIMD3(214, 255, 0)
        case "sink": return SIMD3(0, 163, 255)
        case "toilet": return SIMD3(0, 255, 133)
        case "bathtub": return SIMD3(102, 8, 255)
        case "washerDryer": return SIMD3(184, 0, 255)
        case "television": return SIMD3(0, 255, 194)
        case "fireplace": return SIMD3(250, 10, 15)
        case "stairs": return SIMD3(255, 224, 0)
        default: return SIMD3(224, 5, 255) // cabinet
        }
    }
}

enum PlanRenderer {
    enum RenderError: LocalizedError {
        case noMetal, renderFailed

        var errorDescription: String? {
            switch self {
            case .noMetal: "This Mac has no Metal GPU for rendering."
            case .renderFailed: "The plan couldn't be rendered."
            }
        }
    }

    /// Renders the clay, depth, segmentation and mask passes of `plan` from `camera`.
    static func render(_ plan: FloorPlanData, camera: PlanCamera, width: Int, height: Int) throws -> PlanRenderPasses {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderError.noMetal }
        let geometry = SceneGeometry(plan: plan, ceiling: camera.isInterior)
        let cameraNode = makeCameraNode(camera, aspect: Float(width) / Float(height))
        let size = CGSize(width: width, height: height)

        func snapshot(_ scene: SCNScene, antialiasing: SCNAntialiasingMode, occlusion: Bool = false) throws -> [UInt8] {
            scene.rootNode.addChildNode(cameraNode)
            // Soft contact shadows for the clay look only (they would corrupt the data passes).
            cameraNode.camera?.screenSpaceAmbientOcclusionIntensity = occlusion ? 1.2 : 0
            cameraNode.camera?.screenSpaceAmbientOcclusionRadius = 0.35
            cameraNode.camera?.screenSpaceAmbientOcclusionNormalThreshold = 0.3
            defer { cameraNode.removeFromParentNode() }
            let renderer = SCNRenderer(device: device, options: nil)
            renderer.scene = scene
            renderer.pointOfView = cameraNode
            let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: antialiasing)
            guard let pixels = RGBAPixels(image: image, width: width, height: height) else { throw RenderError.renderFailed }
            return pixels.bytes
        }

        // Segmentation: flat palette colors, no antialiasing, then snapped to the palette.
        let segmentationBytes = try snapshot(geometry.segmentationScene(), antialiasing: .none)
        let palette = geometry.paletteColors + [ADE20K.background]
        var segmentation = [UInt8](repeating: 0, count: width * height * 3)
        var mask = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            let p = SIMD3<Int>(Int(segmentationBytes[4 * i]), Int(segmentationBytes[4 * i + 1]), Int(segmentationBytes[4 * i + 2]))
            var best = palette[0], bestDistance = Int.max
            for c in palette {
                let d = p &- SIMD3<Int>(truncatingIfNeeded: c)
                let distance = d.x * d.x + d.y * d.y + d.z * d.z
                if distance < bestDistance { bestDistance = distance; best = c }
            }
            segmentation[3 * i] = best.x
            segmentation[3 * i + 1] = best.y
            segmentation[3 * i + 2] = best.z
            let inside: UInt8 = best == ADE20K.background ? 0 : 255
            mask[3 * i] = inside; mask[3 * i + 1] = inside; mask[3 * i + 2] = inside
        }

        // Depth in two passes: a conservative range from the bounds, then the range actually seen.
        let view = cameraNode.simdWorldTransform.inverse
        var near = Float.infinity, far: Float = 0
        for corner in geometry.bounds.corners {
            let z = -(view * SIMD4(corner, 1)).z
            near = min(near, z)
            far = max(far, z)
        }
        near = max(0.05, near)
        far = max(near + 0.5, far)
        let coarse = try snapshot(geometry.depthScene(near: near, far: far, inverse: false), antialiasing: .none)
        var seenNear = Float.infinity, seenFar: Float = 0
        for i in 0..<(width * height) where mask[3 * i] != 0 {
            let z = near + Float(coarse[4 * i]) / 255 * (far - near)
            seenNear = min(seenNear, z)
            seenFar = max(seenFar, z)
        }
        if seenNear.isFinite {
            let margin = (far - near) / 255
            near = max(0.05, seenNear - margin)
            far = max(near + 0.1, seenFar + margin)
        }
        let depthBytes = try snapshot(geometry.depthScene(near: near, far: far, inverse: true), antialiasing: .multisampling4X)
        var depth = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            let v = mask[3 * i] == 0 ? 0 : depthBytes[4 * i]
            depth[3 * i] = v; depth[3 * i + 1] = v; depth[3 * i + 2] = v
        }

        let clayBytes = try snapshot(geometry.clayScene(interior: camera.isInterior), antialiasing: .multisampling4X, occlusion: true)
        var clay = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            clay[3 * i] = clayBytes[4 * i]; clay[3 * i + 1] = clayBytes[4 * i + 1]; clay[3 * i + 2] = clayBytes[4 * i + 2]
        }

        guard let clayImage = RGBAPixels.image(rgb: clay, width: width, height: height),
              let depthImage = RGBAPixels.image(rgb: depth, width: width, height: height),
              let segmentationImage = RGBAPixels.image(rgb: segmentation, width: width, height: height),
              let maskImage = RGBAPixels.image(rgb: mask, width: width, height: height)
        else { throw RenderError.renderFailed }
        // Object IDs (walls and floors drawn black so they hide what is behind them).
        let idBytes = try snapshot(geometry.identityScene(), antialiasing: .none)
        var counts = [Int](repeating: 0, count: plan.objects.count), sums = [SIMD2<Float>](repeating: .zero, count: plan.objects.count)
        for i in 0..<(width * height) where idBytes[4 * i + 2] == 64 {
            let id = Int(idBytes[4 * i]) | Int(idBytes[4 * i + 1]) << 8
            guard id > 0, id <= plan.objects.count else { continue }
            counts[id - 1] += 1
            sums[id - 1] += SIMD2(Float(i % width), Float(i / width))
        }
        let pixels = Float(width * height)
        let visible = plan.objects.indices.compactMap { index -> VisibleObject? in
            let coverage = Float(counts[index]) / pixels
            guard coverage > 0.002 else { return nil }
            let center = sums[index] / Float(counts[index]) / SIMD2(Float(width), Float(height))
            return VisibleObject(object: plan.objects[index], coverage: coverage, center: center)
        }
        .sorted { $0.coverage > $1.coverage }
        return PlanRenderPasses(clay: clayImage, depth: depthImage, segmentation: segmentationImage, mask: maskImage, visible: visible)
    }

    /// A lit render of a finished model (e.g. the furnished plan) from `camera`.
    static func renderModel(_ model: ExportModel, camera: PlanCamera, width: Int, height: Int) throws -> CGImage {
        let root = SceneKitExport.node(for: model)
        let bounds = model.bounds
        let scene = SCNScene()
        scene.background.contents = NSColor(white: 0.96, alpha: 1)
        scene.rootNode.addChildNode(root)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = camera.isInterior ? 500 : 420
        scene.rootNode.addChildNode(ambient)
        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = camera.isInterior ? 650 : 1000
        sun.light?.castsShadow = !camera.isInterior
        sun.light?.shadowMode = .deferred
        sun.light?.shadowRadius = 5
        sun.light?.shadowSampleCount = 16
        sun.light?.shadowColor = NSColor(white: 0, alpha: 0.4)
        sun.light?.orthographicScale = CGFloat(max(bounds.size.x, bounds.size.z))
        sun.simdPosition = bounds.center + SIMD3(-4, 10, 6)
        sun.simdLook(at: bounds.center, up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
        scene.rootNode.addChildNode(sun)
        let cameraNode = makeCameraNode(camera, aspect: Float(width) / Float(height))
        cameraNode.camera?.screenSpaceAmbientOcclusionIntensity = 1.0
        cameraNode.camera?.screenSpaceAmbientOcclusionRadius = 0.3
        scene.rootNode.addChildNode(cameraNode)
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderError.noMetal }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: width, height: height), antialiasingMode: .multisampling4X)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw RenderError.renderFailed }
        return cg
    }

    /// The textured scan itself from the same camera (a reference for image-editing models).
    static func renderScan(_ node: SCNNode, camera: PlanCamera, width: Int, height: Int) throws -> CGImage {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderError.noMetal }
        let scene = SCNScene()
        scene.background.contents = NSColor(white: 0.96, alpha: 1)
        scene.rootNode.addChildNode(node.clone())
        let cameraNode = makeCameraNode(camera, aspect: Float(width) / Float(height))
        scene.rootNode.addChildNode(cameraNode)
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: width, height: height), antialiasingMode: .multisampling4X)
        guard let pixels = RGBAPixels(image: image, width: width, height: height) else { throw RenderError.renderFailed }
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) { rgb[3 * i] = pixels.bytes[4 * i]; rgb[3 * i + 1] = pixels.bytes[4 * i + 1]; rgb[3 * i + 2] = pixels.bytes[4 * i + 2] }
        guard let result = RGBAPixels.image(rgb: rgb, width: width, height: height) else { throw RenderError.renderFailed }
        return result
    }

    static func makeCameraNode(_ camera: PlanCamera, aspect: Float) -> SCNNode {
        let node = SCNNode()
        node.camera = SCNCamera()
        node.camera?.fieldOfView = CGFloat(camera.fieldOfView)
        node.camera?.projectionDirection = .vertical
        node.camera?.zNear = 0.05
        node.camera?.zFar = 200
        node.camera?.wantsHDR = false
        node.simdPosition = camera.position
        node.simdLook(at: camera.target, up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
        return node
    }

    /// Objects whose center is inside the camera's field of view (ignoring walls), nearest first.
    static func objectsInFrustum(_ plan: FloorPlanData, camera: PlanCamera, aspect: Float) -> [FloorPlanData.Object] {
        let forward = simd_normalize(camera.target - camera.position)
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
        let up = simd_cross(right, forward)
        let tanV = tan(camera.fieldOfView * .pi / 360), tanH = tanV * aspect
        return plan.objects.compactMap { object -> (FloorPlanData.Object, Float)? in
            let d = object.matrix.translation - camera.position
            let z = simd_dot(d, forward)
            guard z > 0.3 else { return nil }
            guard abs(simd_dot(d, right)) / z < tanH * 1.05, abs(simd_dot(d, up)) / z < tanV * 1.1 else { return nil }
            return (object, z)
        }
        .sorted { $0.1 < $1.1 }
        .map(\.0)
    }
}

// MARK: - Cameras

enum PlanCameras {
    /// Cut-away view of the whole plan from above at an angle, like a real-estate 3D floor plan.
    static func overview(_ plan: FloorPlanData, aspect: Float) -> PlanCamera {
        let box = SceneGeometry(plan: plan, ceiling: false).bounds
        let center = box.center
        // Look across the short side so the long side runs along the (wide) image.
        let direction = box.size.z > box.size.x * 1.15 ? simd_normalize(SIMD3<Float>(0.95, 1.1, -0.45))
                                                       : simd_normalize(SIMD3<Float>(-0.62, 1.05, 0.95))
        let fov: Float = 34
        // Fit the footprint: distance for the larger of the vertical and horizontal extents.
        let radius = simd_length(SIMD2(box.size.x, box.size.z)) / 2
        let tanV = tan(fov * .pi / 360)
        var distance = radius / min(tanV, tanV * aspect) * 0.9
        let target = center - SIMD3(0, 0.4, 0)
        // Refine so the projected bounds fill about 90% of the frame (long plans otherwise sit small).
        for _ in 0..<3 {
            let camera = PlanCamera(name: "Overview", position: target + direction * distance, target: target,
                                    fieldOfView: fov, isInterior: false, roomLabel: nil)
            let forward = simd_normalize(camera.target - camera.position)
            let right = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
            let up = simd_cross(right, forward)
            var extent: Float = 0
            for corner in box.corners {
                let d = corner - camera.position
                let z = max(simd_dot(d, forward), 0.1)
                extent = max(extent, abs(simd_dot(d, right)) / z / (tanV * aspect), abs(simd_dot(d, up)) / z / tanV)
            }
            distance *= extent / 0.9
        }
        return PlanCamera(name: "Overview", position: target + direction * distance, target: target,
                          fieldOfView: fov, isInterior: false, roomLabel: nil)
    }

    /// One eye-level shot per room: stand in the corner that sees the most furniture and look at
    /// the opposite corner.
    static func rooms(_ plan: FloorPlanData, aspect: Float) -> [PlanCamera] {
        let floorLevel = plan.floors.map { $0.matrix.translation.y }.min() ?? 0
        var cameras: [PlanCamera] = []
        // Floors and sections are written in the same order, so the index names the room.
        let floors = plan.floors.enumerated().sorted { $0.element.size.x * $0.element.size.y > $1.element.size.x * $1.element.size.y }
        for (floorIndex, floor) in floors {
            let m = floor.matrix
            let points: [SIMD3<Float>]
            if let polygon = floor.polygon, polygon.count >= 3 {
                points = polygon.map { m.transformPoint(SIMD3($0[0], $0[1], $0.count > 2 ? $0[2] : 0)) }
            } else {
                let w = floor.size.x / 2, h = floor.size.y / 2
                points = [SIMD3(-w, -h, 0), SIMD3(w, -h, 0), SIMD3(w, h, 0), SIMD3(-w, h, 0)].map { m.transformPoint($0) }
            }
            let box = BoundingBox(points: points)
            guard box.size.x > 1.2, box.size.z > 1.2 else { continue }
            let label = plan.sections.count == plan.floors.count ? plan.sections[floorIndex].label
                : plan.sections.min { simd_distance($0.position, box.center) < simd_distance($1.position, box.center) }?.label
            let inset: Float = 0.3
            let eye = floorLevel + 1.35
            let corners = [SIMD2(box.min.x + inset, box.min.z + inset), SIMD2(box.max.x - inset, box.min.z + inset),
                           SIMD2(box.max.x - inset, box.max.z - inset), SIMD2(box.min.x + inset, box.max.z - inset)]
            var best: (camera: PlanCamera, score: Float)?
            for (index, corner) in corners.enumerated() {
                let opposite = corners[(index + 2) % 4]
                let position = SIMD3(corner.x, eye, corner.y)
                // Don't stand inside furniture.
                let blocked = plan.objects.contains { object in
                    let local = object.matrix.inverse.transformPoint(position)
                    let half = object.size / 2 + 0.25
                    return abs(local.x) < half.x && abs(local.z) < half.z && position.y - floorLevel < object.size.y + 0.3
                }
                if blocked { continue }
                let camera = PlanCamera(name: FloorPlanData.displayName(forSection: label ?? "unidentified"),
                                        position: position, target: SIMD3(opposite.x, floorLevel + 1.15, opposite.y),
                                        fieldOfView: 56, isInterior: true, roomLabel: label)
                let inRoom = PlanRenderer.objectsInFrustum(plan, camera: camera, aspect: aspect).filter { object in
                    let p = object.matrix.translation
                    return p.x > box.min.x - 0.1 && p.x < box.max.x + 0.1 && p.z > box.min.z - 0.1 && p.z < box.max.z + 0.1
                }
                let score = Float(inRoom.count) + simd_distance(corner, opposite) * 0.05
                if score > best?.score ?? -1 { best = (camera, score) }
            }
            if let best { cameras.append(best.camera) }
        }
        return cameras
    }
}

// MARK: - Scenes

/// The plan's geometry, split so each render pass can color it differently.
private struct SceneGeometry {
    let structure: ExportModel
    let objects: [FloorPlanData.Object]
    let ceilingPolygons: [[SIMD3<Float>]]
    let bounds: BoundingBox

    init(plan: FloorPlanData, ceiling: Bool) {
        var bare = plan
        bare.objects = []
        structure = RoomSceneBuilder.makeModel(for: bare)
        objects = plan.objects
        var box = structure.bounds
        let top = plan.walls.map { $0.matrix.translation.y + $0.size.y / 2 }.max() ?? (box.max.y)
        if ceiling {
            ceilingPolygons = plan.floors.map { floor in
                let m = floor.matrix
                let polygon = floor.polygon ?? []
                return polygon.map { m.transformPoint(SIMD3($0[0], $0[1], $0.count > 2 ? $0[2] : 0)) }.map { SIMD3($0.x, top, $0.z) }
            }
            .filter { $0.count >= 3 }
        } else {
            ceilingPolygons = []
        }
        for object in plan.objects { box.formUnion(object.matrix.translation) }
        bounds = box
    }

    var paletteColors: [SIMD3<UInt8>] {
        [ADE20K.wall, ADE20K.floor, ADE20K.ceiling, ADE20K.window, ADE20K.door] + objects.map(ADE20K.color(for:))
    }

    // Structure materials from RoomSceneBuilder are named Wall, Floor, Door and Window.
    private func structureNode(color: (String) -> NSColor, configure: (SCNMaterial) -> Void) -> SCNNode {
        let node = SceneKitExport.node(for: structure)
        node.enumerateHierarchy { child, _ in
            for material in child.geometry?.materials ?? [] {
                let name = material.name ?? ""
                material.diffuse.contents = color(name)
                material.transparency = 1
                material.isDoubleSided = name == "Window"
                configure(material)
            }
        }
        return node
    }

    private func objectNodes(color: (FloorPlanData.Object) -> NSColor, configure: (SCNMaterial) -> Void) -> [SCNNode] {
        objects.map { object in
            let box = SCNBox(width: CGFloat(object.size.x), height: CGFloat(object.size.y), length: CGFloat(object.size.z), chamferRadius: 0)
            let material = SCNMaterial()
            material.diffuse.contents = color(object)
            configure(material)
            box.materials = [material]
            let node = SCNNode(geometry: box)
            node.simdTransform = object.matrix
            return node
        }
    }

    private func ceilingNode(color: NSColor, configure: (SCNMaterial) -> Void) -> SCNNode? {
        guard !ceilingPolygons.isEmpty else { return nil }
        var positions: [SCNVector3] = [], normals: [SCNVector3] = [], indices: [Int32] = []
        for polygon in ceilingPolygons {
            var points = polygon.map { SIMD2($0.x, $0.z) }
            var area: Float = 0
            for i in points.indices {
                let a = points[i], b = points[(i + 1) % points.count]
                area += a.x * b.y - b.x * a.y
            }
            if area < 0 { points.reverse() }
            let y = polygon[0].y
            let base = Int32(positions.count)
            positions += points.map { SCNVector3(CGFloat($0.x), CGFloat(y), CGFloat($0.y)) }
            normals += points.map { _ in SCNVector3(0, -1, 0) }
            for (a, b, c) in Triangulator.earClip(points) {
                // Facing down (seen from inside the room).
                indices += [base + Int32(a), base + Int32(b), base + Int32(c)]
            }
        }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normals)],
                                   elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.isDoubleSided = true
        configure(material)
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }

    private static func ns(_ c: SIMD3<UInt8>) -> NSColor {
        NSColor(srgbRed: CGFloat(c.x) / 255, green: CGFloat(c.y) / 255, blue: CGFloat(c.z) / 255, alpha: 1)
    }

    func segmentationScene() -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = NSColor.black
        let flat: (SCNMaterial) -> Void = { $0.lightingModel = .constant }
        scene.rootNode.addChildNode(structureNode(color: { name in
            switch name {
            case "Floor": Self.ns(ADE20K.floor)
            case "Door": Self.ns(ADE20K.door)
            case "Window": Self.ns(ADE20K.window)
            default: Self.ns(ADE20K.wall)
            }
        }, configure: flat))
        objectNodes(color: { Self.ns(ADE20K.color(for: $0)) }, configure: flat).forEach { scene.rootNode.addChildNode($0) }
        if let ceiling = ceilingNode(color: Self.ns(ADE20K.ceiling), configure: flat) { scene.rootNode.addChildNode(ceiling) }
        return scene
    }

    /// Objects in unique flat colors (red/green = index + 1, blue = 64 as a marker), structure black.
    func identityScene() -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = NSColor.black
        let flat: (SCNMaterial) -> Void = { $0.lightingModel = .constant }
        scene.rootNode.addChildNode(structureNode(color: { _ in .black }, configure: flat))
        var index = 0
        objectNodes(color: { _ in
            index += 1
            return NSColor(srgbRed: CGFloat(index & 0xFF) / 255, green: CGFloat(index >> 8) / 255, blue: 64 / 255, alpha: 1)
        }, configure: flat).forEach { scene.rootNode.addChildNode($0) }
        if let ceiling = ceilingNode(color: .black, configure: flat) { scene.rootNode.addChildNode(ceiling) }
        return scene
    }

    /// Writes view-space depth into the color: linear over [near, far] (for range finding) or
    /// inverse depth (near white, far black) like the MiDaS maps ControlNet was trained on.
    func depthScene(near: Float, far: Float, inverse: Bool) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = NSColor.black
        let modifier = """
        #pragma arguments
        float nearDepth;
        float farDepth;
        float inverseDepth;
        #pragma body
        float z = max(-_surface.position.z, 0.001);
        float v = inverseDepth > 0.5 ? (1.0 / z - 1.0 / farDepth) / (1.0 / nearDepth - 1.0 / farDepth)
                                     : 1.0 - (z - nearDepth) / (farDepth - nearDepth);
        v = clamp(v, 0.0, 1.0);
        if (inverseDepth < 0.5) { v = 1.0 - v; }
        // The render target is sRGB: pre-linearize so the stored byte is v itself.
        float l = v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
        _output.color = float4(l, l, l, 1.0);
        """
        let configure: (SCNMaterial) -> Void = { material in
            material.lightingModel = .constant
            material.isDoubleSided = true
            material.shaderModifiers = [.fragment: modifier]
            material.setValue(NSNumber(value: near), forKey: "nearDepth")
            material.setValue(NSNumber(value: far), forKey: "farDepth")
            material.setValue(NSNumber(value: inverse ? 1 : 0), forKey: "inverseDepth")
        }
        scene.rootNode.addChildNode(structureNode(color: { _ in .white }, configure: configure))
        objectNodes(color: { _ in .white }, configure: configure).forEach { scene.rootNode.addChildNode($0) }
        if let ceiling = ceilingNode(color: .white, configure: configure) { scene.rootNode.addChildNode(ceiling) }
        return scene
    }

    /// Neutral "clay" model: white walls, warm grey floor, light grey furniture, soft light.
    func clayScene(interior: Bool) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = NSColor(white: 0.96, alpha: 1)
        let lit: (SCNMaterial) -> Void = { material in
            material.lightingModel = .physicallyBased
            material.roughness.contents = 0.85
            material.metalness.contents = 0.0
        }
        scene.rootNode.addChildNode(structureNode(color: { name in
            switch name {
            case "Floor": NSColor(srgbRed: 0.80, green: 0.76, blue: 0.70, alpha: 1)
            case "Door": NSColor(srgbRed: 0.74, green: 0.70, blue: 0.66, alpha: 1)
            case "Window": NSColor(srgbRed: 0.78, green: 0.86, blue: 0.92, alpha: 1)
            default: NSColor(white: 0.93, alpha: 1)
            }
        }, configure: lit))
        objectNodes(color: { _ in NSColor(white: 0.84, alpha: 1) }, configure: lit).forEach { scene.rootNode.addChildNode($0) }
        if let ceiling = ceilingNode(color: NSColor(white: 0.95, alpha: 1), configure: lit) { scene.rootNode.addChildNode(ceiling) }

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = interior ? 420 : 450
        scene.rootNode.addChildNode(ambient)
        if interior {
            // One soft overhead light without shadows (the ceiling would block a sun); faces are
            // shaded by how they point, corners get the ambient occlusion.
            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .directional
            key.light?.intensity = 520
            key.simdPosition = bounds.center + SIMD3(2, 6, 3)
            key.simdLook(at: bounds.center, up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
            scene.rootNode.addChildNode(key)
        } else {
            let sun = SCNNode()
            sun.light = SCNLight()
            sun.light?.type = .directional
            sun.light?.intensity = 900
            sun.light?.castsShadow = true
            sun.light?.shadowMode = .deferred
            sun.light?.shadowRadius = 6
            sun.light?.shadowSampleCount = 16
            sun.light?.shadowColor = NSColor(white: 0, alpha: 0.35)
            sun.light?.orthographicScale = CGFloat(max(bounds.size.x, bounds.size.z))
            sun.simdPosition = bounds.center + SIMD3(-4, 10, 6)
            sun.simdLook(at: bounds.center, up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
            scene.rootNode.addChildNode(sun)
        }
        return scene
    }
}

extension BoundingBox {
    var corners: [SIMD3<Float>] {
        (0..<8).map { i in SIMD3(i & 1 == 0 ? min.x : max.x, i & 2 == 0 ? min.y : max.y, i & 4 == 0 ? min.z : max.z) }
    }
}

/// RGBA8 (sRGB) pixels of an image at an exact size.
struct RGBAPixels {
    var bytes: [UInt8]

    init?(image: NSImage, width: Int, height: Int) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        self.init(cgImage: cgImage, width: width, height: height)
    }

    init?(cgImage: CGImage, width: Int, height: Int) {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.bytes = bytes
    }

    /// An opaque sRGB image from packed RGB bytes (top row first).
    static func image(rgb: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgb) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
