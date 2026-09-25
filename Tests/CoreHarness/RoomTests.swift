import Foundation
import SceneKit
import SwiftUI
import simd

/// A synthetic two-room apartment in RoomPlan's conventions, rotated by `yaw` to test alignment.
func makeSyntheticApartment(yaw: Float = 17 * .pi / 180) -> FloorPlanData {
    let rotation = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)))
    func rotate(_ p: SIMD3<Float>) -> SIMD3<Float> { rotation.transformPoint(p) }
    func transform(x: SIMD3<Float>, y: SIMD3<Float>, center: SIMD3<Float>) -> [Float] {
        let z = simd_cross(x, y)
        return simd_float4x4(SIMD4(x, 0), SIMD4(y, 0), SIMD4(z, 0), SIMD4(center, 1)).columnMajorArray
    }
    var data = FloorPlanData()
    let height: Float = 2.6

    func wall(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> FloorPlanData.Surface {
        let ra = rotate(a), rb = rotate(b)
        return FloorPlanData.Surface(id: UUID(), kind: .wall,
                                     transform: transform(x: simd_normalize(rb - ra), y: SIMD3(0, 1, 0), center: (ra + rb) / 2 + SIMD3(0, height / 2, 0)),
                                     dimensions: [simd_distance(ra, rb), height, 0])
    }
    func hole(_ kind: FloorPlanData.SurfaceKind, in wall: FloorPlanData.Surface, at t: Float, width: Float, height h: Float, sill: Float, open: Bool? = nil) -> FloorPlanData.Surface {
        let m = wall.matrix
        let center = m.transformPoint(SIMD3((t - 0.5) * wall.size.x, -height / 2 + sill + h / 2, 0))
        return FloorPlanData.Surface(id: UUID(), kind: kind,
                                     transform: transform(x: m.columns.0.xyz, y: SIMD3(0, 1, 0), center: center),
                                     dimensions: [width, h, 0], isOpen: open, parentID: wall.id)
    }

    // Room A: x 0...4, z 0...3.5 ; Room B: x 4...7, z 0...3.5 (shared wall at x = 4).
    let corners: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(7, 0, 0), SIMD3(7, 0, 3.5), SIMD3(0, 0, 3.5)]
    var walls = [wall(corners[0], SIMD3(4, 0, 0)), wall(SIMD3(4, 0, 0), corners[1]), wall(corners[1], corners[2]),
                 wall(corners[2], SIMD3(4, 0, 3.5)), wall(SIMD3(4, 0, 3.5), corners[3]), wall(corners[3], corners[0])]
    let shared = wall(SIMD3(4, 0, 0), SIMD3(4, 0, 3.5))
    walls.append(shared)
    data.surfaces += walls
    data.surfaces.append(hole(.door, in: shared, at: 0.5, width: 0.9, height: 2.05, sill: 0, open: false))
    data.surfaces.append(hole(.door, in: walls[0], at: 0.2, width: 0.95, height: 2.1, sill: 0, open: true))
    data.surfaces.append(hole(.window, in: walls[3], at: 0.5, width: 1.4, height: 1.2, sill: 0.9))
    data.surfaces.append(hole(.window, in: walls[4], at: 0.35, width: 1.6, height: 1.3, sill: 0.8))
    data.surfaces.append(hole(.opening, in: walls[2], at: 0.5, width: 1.0, height: 2.2, sill: 0))

    // Floors (polygon in the floor's local XY plane; local Z points down).
    for (x0, x1) in [(Float(0), Float(4)), (Float(4), Float(7))] {
        let center = rotate(SIMD3((x0 + x1) / 2, 0, 1.75))
        let fx = rotate(SIMD3(1, 0, 0)), fy = rotate(SIMD3(0, 0, 1))
        let w = (x1 - x0) / 2
        data.surfaces.append(FloorPlanData.Surface(id: UUID(), kind: .floor, transform: transform(x: fx, y: fy, center: center),
                                                   dimensions: [x1 - x0, 3.5, 0],
                                                   polygon: [[-w, -1.75, 0], [w, -1.75, 0], [w, 1.75, 0], [-w, 1.75, 0]]))
    }

    func object(_ category: String, at p: SIMD3<Float>, size: SIMD3<Float>, turn: Float = 0) -> FloorPlanData.Object {
        let r = simd_float4x4(simd_quatf(angle: yaw + turn, axis: SIMD3(0, 1, 0)))
        var m = r
        m.columns.3 = SIMD4(rotate(p + SIMD3(0, size.y / 2, 0)), 1)
        return FloorPlanData.Object(id: UUID(), category: category, transform: m.columnMajorArray, dimensions: [size.x, size.y, size.z])
    }
    data.objects = [
        object("bed", at: SIMD3(1.3, 0, 1.6), size: SIMD3(1.6, 0.5, 2.0)),
        object("storage", at: SIMD3(3.6, 0, 3.1), size: SIMD3(0.9, 1.9, 0.5)),
        object("sofa", at: SIMD3(5.5, 0, 3.0), size: SIMD3(2.0, 0.8, 0.9)),
        object("table", at: SIMD3(5.5, 0, 1.4), size: SIMD3(1.2, 0.75, 0.8)),
        object("chair", at: SIMD3(6.4, 0, 1.4), size: SIMD3(0.5, 0.9, 0.5), turn: .pi / 2),
        object("television", at: SIMD3(5.5, 0.6, 0.15), size: SIMD3(1.2, 0.7, 0.1)),
    ]
    data.sections = [
        FloorPlanData.Section(label: "bedroom", center: [rotate(SIMD3(2, 0, 1.75)).x, 0, rotate(SIMD3(2, 0, 1.75)).z]),
        FloorPlanData.Section(label: "livingRoom", center: [rotate(SIMD3(5.5, 0, 1.75)).x, 0, rotate(SIMD3(5.5, 0, 1.75)).z]),
    ]
    data.roomCount = 2
    return data
}

@MainActor
func runRoomTests(output: URL, check: (Bool, String) -> Void) throws {
    let data = makeSyntheticApartment()
    let url = output.appendingPathComponent("floorplan.json")
    try data.write(to: url)
    let decoded = try FloorPlanData.read(from: url)
    check(decoded.surfaces.count == data.surfaces.count && decoded.objects.count == 6, "FloorPlanData JSON round trip")

    let plan = FloorPlanGeometry(data: decoded)
    let degrees = plan.rotation * 180 / .pi
    check(abs(abs(degrees) - 17) < 0.5, "dominant wall angle detected (\(String(format: "%.1f", degrees))°)")
    check(abs(plan.floorArea - 24.5) < 0.1, "floor area \(String(format: "%.2f", plan.floorArea)) m² (expected 24.5)")
    let axisAligned = plan.walls.allSatisfy { abs($0.start.x - $0.end.x) < 1e-3 || abs($0.start.y - $0.end.y) < 1e-3 }
    check(axisAligned, "walls are axis-aligned after rotation")
    check(plan.labels.count == 2 && plan.labels.allSatisfy { abs(($0.area ?? 0) - 14) < 0.1 || abs(($0.area ?? 0) - 10.5) < 0.1 },
          "room labels get their floor areas")

    // 3D model and exports.
    let node = RoomSceneBuilder.makeNode(for: decoded)
    let model = RoomSceneBuilder.makeModel(for: decoded)
    check(model.triangleCount > 100 && model.materials.count >= 4, "room flattens to \(model.triangleCount) triangles, \(model.materials.count) materials")
    let box = model.bounds
    check(abs(box.max.y - 2.6) < 0.05 && abs(box.min.y + RoomSceneBuilder.floorThickness) < 0.05, "room height 2.6 m, floor slab below 0")
    let glb = try GLBWriter.data(for: model)
    try validateGLB(glb, check: check)
    try glb.write(to: output.appendingPathComponent("apartment.glb"))
    let usdzURL = output.appendingPathComponent("apartment.usdz")
    try SceneKitExport.writeUSDZ(model, to: usdzURL)
    let reloaded = try SCNScene(url: usdzURL, options: nil)
    let (lo, hi) = reloaded.rootNode.boundingBox
    check(abs(Float(hi.y - lo.y) - (box.max.y - box.min.y)) < 0.02, "room USDZ reloads with the same height")
    // Watertight-ish check: every wall/box quad should be outward facing (normals agree with winding).
    var agree = 0, total = 0
    for mesh in model.meshes {
        for primitive in mesh.primitives {
            var t = 0
            while t + 2 < primitive.indices.count {
                let a = mesh.positions[Int(primitive.indices[t])], b = mesh.positions[Int(primitive.indices[t + 1])]
                let c = mesh.positions[Int(primitive.indices[t + 2])]
                let n = mesh.normals[Int(primitive.indices[t])]
                if simd_dot(simd_cross(b - a, c - a), n) > 0 { agree += 1 }
                total += 1
                t += 3
            }
        }
    }
    check(agree == total, "room triangle winding matches normals (\(agree)/\(total))")

    // Renders for visual inspection.
    renderRoom(node: node, bounds: box, to: output.appendingPathComponent("render-room.png"))
    try renderFloorPlan(plan, style: .paper, to: output.appendingPathComponent("floorplan-paper.png"))
    try renderFloorPlan(plan, style: .dark, system: .imperial, to: output.appendingPathComponent("floorplan-dark.png"))
}

func renderRoom(node: SCNNode, bounds: BoundingBox, to url: URL) {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let scene = SCNScene()
    scene.background.contents = PlatformColor(hex: 0x14161F)
    scene.rootNode.addChildNode(node)
    ScanSceneBuilder.addStudioLights(to: scene.rootNode)
    let camera = ScanSceneBuilder.makeCamera(framing: bounds)
    scene.rootNode.addChildNode(camera)
    let renderer = SCNRenderer(device: device, options: nil)
    renderer.scene = scene
    renderer.pointOfView = camera
    let image = renderer.snapshot(atTime: 0, with: CGSize(width: 900, height: 700), antialiasingMode: .multisampling4X)
    if let cg = image.cgImageRepresentation { try? ImageFiles.writePNG(cg, to: url) }
    print("  wrote \(url.path)")
}

@MainActor
func renderFloorPlan(_ plan: FloorPlanGeometry, style: FloorPlanStyle, system: MeasurementSystem = .metric, to url: URL) throws {
    let view = FloorPlanCanvas(geometry: plan, style: style, system: system).frame(width: 900, height: 600)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    guard let image = renderer.cgImage else { throw ImageFiles.ImageError.contextCreationFailed }
    try ImageFiles.writePNG(image, to: url)
    print("  wrote \(url.path)")
}
