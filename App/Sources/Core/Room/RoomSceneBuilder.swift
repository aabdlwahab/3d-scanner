import CoreGraphics
import Foundation
import SceneKit
import simd

/// Builds a clean "dollhouse" model from ``FloorPlanData``: extruded walls with real door and
/// window openings, floor slabs, door and window panels, and colored furniture blocks.
///
/// The geometry is generated directly (instead of with `SCNShape`/`SCNBox`) so that the viewer,
/// every export format and USDZ all get exactly the same triangles.
enum RoomSceneBuilder {
    static let wallThickness: Float = 0.1
    static let floorThickness: Float = 0.03

    static func makeNode(for data: FloorPlanData) -> SCNNode {
        let node = SceneKitExport.node(for: makeModel(for: data))
        node.name = "Room"
        return node
    }

    static func makeModel(for data: FloorPlanData) -> ExportModel {
        var builder = ModelBuilder()
        let wallMaterial = builder.material("Wall", color: SIMD4(0.93, 0.94, 0.96, 1))
        let floorMaterial = builder.material("Floor", color: SIMD4(0.84, 0.82, 0.78, 1))
        let doorMaterial = builder.material("Door", color: SIMD4(0.61, 0.42, 0.29, 1))
        let windowMaterial = builder.material("Window", color: SIMD4(0.66, 0.85, 0.94, 0.45), doubleSided: true)

        let walls = data.walls
        let holes = data.doors + data.windows + data.openings

        // Floors.
        var floorPolygons: [[SIMD3<Float>]] = data.floors.map { floor in
            let m = floor.matrix
            if let polygon = floor.polygon, polygon.count >= 3 {
                return polygon.map { m.transformPoint(SIMD3($0[0], $0[1], $0.count > 2 ? $0[2] : 0)) }
            }
            let w = floor.size.x / 2, h = floor.size.y / 2
            return [SIMD3(-w, -h, 0), SIMD3(w, -h, 0), SIMD3(w, h, 0), SIMD3(-w, h, 0)].map { m.transformPoint($0) }
        }
        if floorPolygons.isEmpty, !walls.isEmpty {
            // No floor surfaces (older iOS): use the hull of the wall bases.
            let base = walls.map { $0.matrix.translation.y - $0.size.y / 2 }.min() ?? 0
            let points = walls.flatMap { wall -> [CGPoint] in
                let m = wall.matrix, half = wall.size.x / 2
                return [m.transformPoint(SIMD3(-half, 0, 0)), m.transformPoint(SIMD3(half, 0, 0))]
                    .map { CGPoint(x: Double($0.x), y: Double($0.z)) }
            }
            floorPolygons = [FloorPlanGeometry.convexHull(points).map { SIMD3(Float($0.x), base, Float($0.y)) }]
        }
        for polygon in floorPolygons where polygon.count >= 3 {
            builder.addSlab(polygon, thickness: floorThickness, material: floorMaterial)
        }

        // Walls with openings.
        for wall in walls {
            let inverse = wall.matrix.inverse
            let w = wall.size.x, h = wall.size.y
            var cutouts: [(SIMD2<Float>, SIMD2<Float>)] = []
            for hole in holes where belongs(hole, to: wall, inverse: inverse) {
                let c = (inverse * hole.matrix).translation
                let lo = simd_max(SIMD2(c.x - hole.size.x / 2, c.y - hole.size.y / 2), SIMD2(-w / 2 + 0.02, -h / 2))
                let hi = simd_min(SIMD2(c.x + hole.size.x / 2, c.y + hole.size.y / 2), SIMD2(w / 2 - 0.02, h / 2 - 0.02))
                if hi.x - lo.x > 0.05, hi.y - lo.y > 0.05 { cutouts.append((lo, hi)) }
            }
            builder.addWall(width: w, height: h, thickness: wallThickness, holes: cutouts, transform: wall.matrix, material: wallMaterial)
        }

        // Door and window panels.
        for door in data.doors where door.isOpen != true {
            builder.addBox(size: SIMD3(door.size.x, door.size.y, 0.04), transform: door.matrix, material: doorMaterial)
        }
        for window in data.windows {
            builder.addBox(size: SIMD3(window.size.x, window.size.y, 0.02), transform: window.matrix, material: windowMaterial)
        }

        // Furniture.
        var categoryMaterials: [String: Int] = [:]
        for object in data.objects {
            let material = categoryMaterials[object.category] ?? {
                let rgb = FloorPlanData.color(forCategory: object.category)
                let index = builder.material(FloorPlanData.displayName(forCategory: object.category), color: SIMD4(rgb, 1))
                categoryMaterials[object.category] = index
                return index
            }()
            builder.addBox(size: object.size, transform: object.matrix, material: material)
        }
        return builder.model(named: "Room")
    }

    /// Whether a door/window/opening sits in a wall (RoomPlan parent link, or geometric fallback).
    private static func belongs(_ hole: FloorPlanData.Surface, to wall: FloorPlanData.Surface, inverse: simd_float4x4) -> Bool {
        if let parent = hole.parentID { return parent == wall.id }
        let c = (inverse * hole.matrix).translation
        return abs(c.z) < 0.2 && abs(c.x) < wall.size.x / 2 + 0.05 && abs(c.y) < wall.size.y / 2 + 0.05
    }
}

/// Accumulates triangles per material into a single ``ExportModel`` mesh.
private struct ModelBuilder {
    private var positions: [SIMD3<Float>] = []
    private var normals: [SIMD3<Float>] = []
    private var indicesByMaterial: [[UInt32]] = []
    private var materials: [ExportModel.Material] = []

    mutating func material(_ name: String, color: SIMD4<Float>, doubleSided: Bool = false) -> Int {
        materials.append(ExportModel.Material(name: name, baseColor: color, doubleSided: doubleSided))
        indicesByMaterial.append([])
        return materials.count - 1
    }

    func model(named name: String) -> ExportModel {
        var model = ExportModel()
        model.materials = materials
        let primitives = indicesByMaterial.enumerated().filter { !$0.element.isEmpty }
            .map { ExportModel.Primitive(indices: $0.element, material: $0.offset) }
        if !primitives.isEmpty {
            model.meshes = [ExportModel.Mesh(name: name, positions: positions, normals: normals, primitives: primitives)]
        }
        return model
    }

    /// Adds a planar quad (corners counter-clockwise when seen from the side `normal` points to).
    mutating func addQuad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, normal: SIMD3<Float>, material: Int) {
        let base = UInt32(positions.count)
        positions += [a, b, c, d]
        normals += [normal, normal, normal, normal]
        indicesByMaterial[material] += [base, base + 1, base + 2, base, base + 2, base + 3]
    }

    mutating func addBox(size: SIMD3<Float>, transform m: simd_float4x4, material: Int) {
        let h = size / 2
        let rotation = m.upperLeft3x3
        func p(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> { m.transformPoint(SIMD3(x * h.x, y * h.y, z * h.z)) }
        func n(_ v: SIMD3<Float>) -> SIMD3<Float> { simd_normalize(rotation * v) }
        addQuad(p(-1, -1, 1), p(1, -1, 1), p(1, 1, 1), p(-1, 1, 1), normal: n(SIMD3(0, 0, 1)), material: material)
        addQuad(p(1, -1, -1), p(-1, -1, -1), p(-1, 1, -1), p(1, 1, -1), normal: n(SIMD3(0, 0, -1)), material: material)
        addQuad(p(1, -1, 1), p(1, -1, -1), p(1, 1, -1), p(1, 1, 1), normal: n(SIMD3(1, 0, 0)), material: material)
        addQuad(p(-1, -1, -1), p(-1, -1, 1), p(-1, 1, 1), p(-1, 1, -1), normal: n(SIMD3(-1, 0, 0)), material: material)
        addQuad(p(-1, 1, 1), p(1, 1, 1), p(1, 1, -1), p(-1, 1, -1), normal: n(SIMD3(0, 1, 0)), material: material)
        addQuad(p(-1, -1, -1), p(1, -1, -1), p(1, -1, 1), p(-1, -1, 1), normal: n(SIMD3(0, -1, 0)), material: material)
    }

    /// Wall in local XY (centered), extruded along local Z, with rectangular holes. The face is
    /// split on a grid through all hole edges; cells outside holes become front/back quads and
    /// every cell edge that borders a hole or the outside gets a side quad.
    mutating func addWall(width: Float, height: Float, thickness: Float, holes: [(SIMD2<Float>, SIMD2<Float>)],
                          transform m: simd_float4x4, material: Int) {
        var xs = [-width / 2, width / 2], ys = [-height / 2, height / 2]
        for (lo, hi) in holes {
            xs += [lo.x, hi.x]
            ys += [lo.y, hi.y]
        }
        xs = Array(Set(xs)).sorted()
        ys = Array(Set(ys)).sorted()
        let nx = xs.count - 1, ny = ys.count - 1
        guard nx > 0, ny > 0 else { return }
        var solid = [Bool](repeating: true, count: nx * ny)
        for i in 0..<nx {
            for j in 0..<ny {
                let c = SIMD2((xs[i] + xs[i + 1]) / 2, (ys[j] + ys[j + 1]) / 2)
                if holes.contains(where: { c.x > $0.0.x && c.x < $0.1.x && c.y > $0.0.y && c.y < $0.1.y }) {
                    solid[j * nx + i] = false
                }
            }
        }
        func isSolid(_ i: Int, _ j: Int) -> Bool { i >= 0 && j >= 0 && i < nx && j < ny && solid[j * nx + i] }
        let rotation = m.upperLeft3x3
        let t = thickness / 2
        func p(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> { m.transformPoint(SIMD3(x, y, z)) }
        func n(_ v: SIMD3<Float>) -> SIMD3<Float> { simd_normalize(rotation * v) }
        for i in 0..<nx {
            for j in 0..<ny where isSolid(i, j) {
                let x0 = xs[i], x1 = xs[i + 1], y0 = ys[j], y1 = ys[j + 1]
                addQuad(p(x0, y0, t), p(x1, y0, t), p(x1, y1, t), p(x0, y1, t), normal: n(SIMD3(0, 0, 1)), material: material)
                addQuad(p(x1, y0, -t), p(x0, y0, -t), p(x0, y1, -t), p(x1, y1, -t), normal: n(SIMD3(0, 0, -1)), material: material)
                if !isSolid(i + 1, j) {
                    addQuad(p(x1, y0, t), p(x1, y0, -t), p(x1, y1, -t), p(x1, y1, t), normal: n(SIMD3(1, 0, 0)), material: material)
                }
                if !isSolid(i - 1, j) {
                    addQuad(p(x0, y0, -t), p(x0, y0, t), p(x0, y1, t), p(x0, y1, -t), normal: n(SIMD3(-1, 0, 0)), material: material)
                }
                if !isSolid(i, j + 1) {
                    addQuad(p(x0, y1, t), p(x1, y1, t), p(x1, y1, -t), p(x0, y1, -t), normal: n(SIMD3(0, 1, 0)), material: material)
                }
                if !isSolid(i, j - 1) {
                    addQuad(p(x0, y0, -t), p(x1, y0, -t), p(x1, y0, t), p(x0, y0, t), normal: n(SIMD3(0, -1, 0)), material: material)
                }
            }
        }
    }

    /// Horizontal slab whose top face is the (possibly concave) polygon.
    mutating func addSlab(_ polygon: [SIMD3<Float>], thickness: Float, material: Int) {
        let height = polygon.reduce(0) { $0 + $1.y } / Float(polygon.count)
        var points = polygon.map { SIMD2($0.x, $0.z) }
        // Ear clipping expects counter-clockwise order in the (x, z) plane.
        var area: Float = 0
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            area += a.x * b.y - b.x * a.y
        }
        if area < 0 { points.reverse() }
        let triangles = Triangulator.earClip(points)
        let top = height, bottom = height - thickness
        for tri in triangles {
            var a = SIMD3(points[tri.0].x, top, points[tri.0].y)
            let b = SIMD3(points[tri.1].x, top, points[tri.1].y)
            var c = SIMD3(points[tri.2].x, top, points[tri.2].y)
            if simd_cross(b - a, c - a).y < 0 { swap(&a, &c) }
            let base = UInt32(positions.count)
            positions += [a, b, c, SIMD3(a.x, bottom, a.z), SIMD3(c.x, bottom, c.z), SIMD3(b.x, bottom, b.z)]
            normals += [SIMD3(0, 1, 0), SIMD3(0, 1, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0), SIMD3(0, -1, 0), SIMD3(0, -1, 0)]
            indicesByMaterial[material] += [base, base + 1, base + 2, base + 3, base + 4, base + 5]
        }
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            let edge = b - a
            guard simd_length(edge) > 1e-5 else { continue }
            // With counter-clockwise (x, z) order the outward normal is (edge.z, -edge.x).
            let outward = simd_normalize(SIMD3(edge.y, 0, -edge.x))
            addQuad(SIMD3(b.x, bottom, b.y), SIMD3(a.x, bottom, a.y), SIMD3(a.x, top, a.y), SIMD3(b.x, top, b.y),
                    normal: outward, material: material)
        }
    }
}

enum Triangulator {
    /// Ear-clipping triangulation of a simple counter-clockwise polygon.
    static func earClip(_ points: [SIMD2<Float>]) -> [(Int, Int, Int)] {
        var remaining = Array(points.indices)
        var result: [(Int, Int, Int)] = []
        func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var guardCounter = 0
        while remaining.count > 3 && guardCounter < 10_000 {
            guardCounter += 1
            var clipped = false
            for k in remaining.indices {
                let i0 = remaining[(k + remaining.count - 1) % remaining.count]
                let i1 = remaining[k]
                let i2 = remaining[(k + 1) % remaining.count]
                let a = points[i0], b = points[i1], c = points[i2]
                guard cross(a, b, c) > 1e-9 else { continue }
                let containsOther = remaining.contains { j in
                    guard j != i0, j != i1, j != i2 else { return false }
                    let p = points[j]
                    return cross(a, b, p) >= 0 && cross(b, c, p) >= 0 && cross(c, a, p) >= 0
                }
                if containsOther { continue }
                result.append((i0, i1, i2))
                remaining.remove(at: k)
                clipped = true
                break
            }
            // Degenerate input (collinear or self-intersecting): fall back to a fan.
            if !clipped { break }
        }
        if remaining.count >= 3 {
            for k in 1..<(remaining.count - 1) { result.append((remaining[0], remaining[k], remaining[k + 1])) }
        }
        return result
    }
}
