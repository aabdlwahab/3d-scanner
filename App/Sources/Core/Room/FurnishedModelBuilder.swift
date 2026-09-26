import Foundation
import simd

/// A look for the furnished plan model: floor, walls, wood and fabric colors.
struct FurnishingStyle: Hashable, Identifiable {
    let id: String
    let title: String
    let floorWood: SIMD3<Float>
    let wallPaint: SIMD3<Float>
    let wood: SIMD3<Float>
    let fabric: SIMD3<Float>
    let accentFabric: SIMD3<Float>
    let tile: SIMD3<Float>
    let worktop: SIMD3<Float>
    let cabinet: SIMD3<Float>

    static let scandinavian = FurnishingStyle(id: "scandinavian", title: "Scandinavian",
                                              floorWood: SIMD3(0.80, 0.66, 0.50), wallPaint: SIMD3(0.95, 0.94, 0.92),
                                              wood: SIMD3(0.78, 0.63, 0.46), fabric: SIMD3(0.72, 0.72, 0.70), accentFabric: SIMD3(0.55, 0.62, 0.58),
                                              tile: SIMD3(0.93, 0.93, 0.91), worktop: SIMD3(0.92, 0.91, 0.89), cabinet: SIMD3(0.95, 0.95, 0.94))
    static let japandi = FurnishingStyle(id: "japandi", title: "Japandi",
                                         floorWood: SIMD3(0.62, 0.46, 0.32), wallPaint: SIMD3(0.90, 0.86, 0.79),
                                         wood: SIMD3(0.42, 0.30, 0.21), fabric: SIMD3(0.83, 0.78, 0.70), accentFabric: SIMD3(0.52, 0.45, 0.36),
                                         tile: SIMD3(0.80, 0.76, 0.70), worktop: SIMD3(0.35, 0.33, 0.31), cabinet: SIMD3(0.62, 0.50, 0.38))
    static let modern = FurnishingStyle(id: "modern", title: "Modern Dark",
                                        floorWood: SIMD3(0.45, 0.33, 0.25), wallPaint: SIMD3(0.88, 0.87, 0.85),
                                        wood: SIMD3(0.30, 0.22, 0.17), fabric: SIMD3(0.22, 0.34, 0.30), accentFabric: SIMD3(0.70, 0.55, 0.35),
                                        tile: SIMD3(0.35, 0.35, 0.36), worktop: SIMD3(0.90, 0.89, 0.87), cabinet: SIMD3(0.20, 0.21, 0.23))
    static let industrial = FurnishingStyle(id: "industrial", title: "Industrial",
                                            floorWood: SIMD3(0.58, 0.57, 0.55), wallPaint: SIMD3(0.86, 0.84, 0.80),
                                            wood: SIMD3(0.50, 0.36, 0.24), fabric: SIMD3(0.55, 0.36, 0.22), accentFabric: SIMD3(0.30, 0.32, 0.34),
                                            tile: SIMD3(0.60, 0.60, 0.60), worktop: SIMD3(0.40, 0.40, 0.41), cabinet: SIMD3(0.24, 0.25, 0.27))

    static let all: [FurnishingStyle] = [.scandinavian, .japandi, .modern, .industrial]
}

/// Builds a furnished, textured model from a floor plan: floors per room type, painted walls with
/// skirting boards, framed doors and windows, and a detailed piece of furniture for every RoomPlan
/// object (sized to the scanned box). Everything is generated, so it works offline on any device.
enum FurnishedModelBuilder {
    static func makeModel(for data: FloorPlanData, style: FurnishingStyle = .scandinavian, ceiling: Bool = false) -> ExportModel {
        var b = ModelBuilder()
        var m = Materials(builder: &b, style: style)
        let walls = data.walls
        let holes = data.doors + data.windows + data.openings
        let floorLevel = data.floors.map { $0.matrix.translation.y }.min()
            ?? walls.map { $0.matrix.translation.y - $0.size.y / 2 }.min() ?? 0

        // Floors, material by room type.
        for floor in data.floors {
            let fm = floor.matrix
            let polygon: [SIMD3<Float>]
            if let points = floor.polygon, points.count >= 3 {
                polygon = points.map { fm.transformPoint(SIMD3($0[0], $0[1], $0.count > 2 ? $0[2] : 0)) }
            } else {
                let w = floor.size.x / 2, h = floor.size.y / 2
                polygon = [SIMD3(-w, -h, 0), SIMD3(w, -h, 0), SIMD3(w, h, 0), SIMD3(-w, h, 0)].map { fm.transformPoint($0) }
            }
            let kind = roomKind(polygon: polygon, data: data)
            b.addSlab(polygon, thickness: RoomSceneBuilder.floorThickness, material: kind == .wet ? m.floorTile : m.floorWood)
            if ceiling {
                let top = walls.map { $0.matrix.translation.y + $0.size.y / 2 }.max() ?? floorLevel + 2.5
                b.addSlab(polygon.map { SIMD3($0.x, top + 0.02, $0.z) }, thickness: 0.02, material: m.trim)
            }
        }

        // Walls with openings, skirting boards, door and window joinery.
        for wall in walls {
            let wm = wall.matrix, inverse = wm.inverse
            let w = wall.size.x, h = wall.size.y
            let t = wall.dimensions.count > 2 && wall.dimensions[2] > 0.01 ? wall.dimensions[2] : RoomSceneBuilder.wallThickness
            var cutouts: [(SIMD2<Float>, SIMD2<Float>)] = []
            var inWall: [(FloorPlanData.Surface, SIMD2<Float>, SIMD2<Float>)] = []
            for hole in holes where RoomSceneBuilder.belongs(hole, to: wall, inverse: inverse) {
                let c = (inverse * hole.matrix).translation
                let lo = simd_max(SIMD2(c.x - hole.size.x / 2, c.y - hole.size.y / 2), SIMD2(-w / 2 + 0.02, -h / 2))
                let hi = simd_min(SIMD2(c.x + hole.size.x / 2, c.y + hole.size.y / 2), SIMD2(w / 2 - 0.02, h / 2 - 0.02))
                if hi.x - lo.x > 0.05, hi.y - lo.y > 0.05 {
                    cutouts.append((lo, hi))
                    inWall.append((hole, lo, hi))
                }
            }
            b.addWall(width: w, height: h, thickness: t, holes: cutouts, transform: wm, material: m.wall)

            // Skirting on both faces, broken at doorways.
            let floorCuts = cutouts.filter { $0.0.y <= -h / 2 + 0.05 }.map { ($0.0.x, $0.1.x) }.sorted { $0.0 < $1.0 }
            var start = -w / 2
            var spans: [(Float, Float)] = []
            for cut in floorCuts {
                if cut.0 - start > 0.05 { spans.append((start, cut.0)) }
                start = max(start, cut.1)
            }
            if w / 2 - start > 0.05 { spans.append((start, w / 2)) }
            for (x0, x1) in spans {
                for side: Float in [-1, 1] {
                    let z0 = side * t / 2, z1 = side * (t / 2 + 0.014)
                    b.addBox(SIMD3(x0, -h / 2, min(z0, z1)), SIMD3(x1, -h / 2 + 0.08, max(z0, z1)), in: wm, material: m.trim)
                }
            }

            for (hole, lo, hi) in inWall {
                let casing: Float = 0.065, depth = t / 2 + 0.018
                switch hole.kind {
                case .door, .opening:
                    guard hole.kind == .door else { continue }
                    // Architrave on both faces and a lining inside the opening.
                    for side: Float in [-1, 1] {
                        let z0 = side * t / 2, z1 = side * depth
                        let zl = min(z0, z1), zh = max(z0, z1)
                        b.addBox(SIMD3(lo.x - casing, lo.y, zl), SIMD3(lo.x, hi.y, zh), in: wm, material: m.trim)
                        b.addBox(SIMD3(hi.x, lo.y, zl), SIMD3(hi.x + casing, hi.y, zh), in: wm, material: m.trim)
                        b.addBox(SIMD3(lo.x - casing, hi.y, zl), SIMD3(hi.x + casing, hi.y + casing, zh), in: wm, material: m.trim)
                    }
                    b.addBox(SIMD3(lo.x, lo.y, -t / 2), SIMD3(lo.x + 0.02, hi.y, t / 2), in: wm, material: m.trim)
                    b.addBox(SIMD3(hi.x - 0.02, lo.y, -t / 2), SIMD3(hi.x, hi.y, t / 2), in: wm, material: m.trim)
                    b.addBox(SIMD3(lo.x, hi.y - 0.02, -t / 2), SIMD3(hi.x, hi.y, t / 2), in: wm, material: m.trim)
                    if hole.isOpen != true {
                        // Door leaf with a handle on each side.
                        b.addBox(SIMD3(lo.x + 0.02, lo.y + 0.01, -0.02), SIMD3(hi.x - 0.02, hi.y - 0.02, 0.02), in: wm, material: m.door)
                        let hx = hi.x - 0.1, hy = lo.y + 1.0
                        for side: Float in [-1, 1] {
                            b.addBox(SIMD3(hx - 0.07, hy - 0.012, side > 0 ? 0.02 : -0.07), SIMD3(hx + 0.02, hy + 0.012, side > 0 ? 0.07 : -0.02),
                                     in: wm, material: m.metal)
                        }
                    }
                case .window:
                    let frame: Float = 0.055, fz: Float = 0.035
                    b.addBox(SIMD3(lo.x, lo.y, -fz), SIMD3(lo.x + frame, hi.y, fz), in: wm, material: m.trim)
                    b.addBox(SIMD3(hi.x - frame, lo.y, -fz), SIMD3(hi.x, hi.y, fz), in: wm, material: m.trim)
                    b.addBox(SIMD3(lo.x, lo.y, -fz), SIMD3(hi.x, lo.y + frame, fz), in: wm, material: m.trim)
                    b.addBox(SIMD3(lo.x, hi.y - frame, -fz), SIMD3(hi.x, hi.y, fz), in: wm, material: m.trim)
                    if hi.x - lo.x > 0.9 {
                        let mid = (lo.x + hi.x) / 2
                        b.addBox(SIMD3(mid - frame / 2, lo.y, -fz), SIMD3(mid + frame / 2, hi.y, fz), in: wm, material: m.trim)
                    }
                    b.addBox(SIMD3(lo.x + frame, lo.y + frame, -0.006), SIMD3(hi.x - frame, hi.y - frame, 0.006), in: wm, material: m.glass)
                    // Sills on both faces.
                    for side: Float in [-1, 1] {
                        let z0 = side * t / 2 - side * 0.02, z1 = side * (t / 2 + 0.06)
                        b.addBox(SIMD3(lo.x - 0.04, lo.y - 0.03, min(z0, z1)), SIMD3(hi.x + 0.04, lo.y, max(z0, z1)), in: wm, material: m.trim)
                    }
                case .wall, .floor:
                    break
                }
            }
        }

        // Furniture.
        let segments = wallSegments(walls)
        for object in data.objects {
            let frame = objectFrame(object, walls: segments)
            Furniture.build(object, frame: frame, floorLevel: floorLevel, data: data, builder: &b, materials: &m)
        }
        return b.model(named: "Room")
    }

    // MARK: - Room types

    enum RoomKind { case dry, wet }

    private static func roomKind(polygon: [SIMD3<Float>], data: FloorPlanData) -> RoomKind {
        let flat = polygon.map { SIMD2($0.x, $0.z) }
        func inside(_ p: SIMD3<Float>) -> Bool {
            var result = false
            var j = flat.count - 1
            for i in flat.indices {
                let a = flat[i], c = flat[j]
                if (a.y > p.z) != (c.y > p.z), p.x < (c.x - a.x) * (p.z - a.y) / (c.y - a.y) + a.x { result.toggle() }
                j = i
            }
            return result
        }
        if data.sections.contains(where: { ["bathroom", "kitchen"].contains($0.label) && inside($0.position) }) { return .wet }
        let contents = Set(data.objects.filter { inside($0.matrix.translation) }.map(\.category))
        if contents.contains("toilet") || contents.contains("bathtub") { return .wet }
        // A separate kitchen gets tiles; an open-plan living room with a kitchen keeps its wood floor.
        var area: Float = 0
        for i in flat.indices {
            let a = flat[i], c = flat[(i + 1) % flat.count]
            area += a.x * c.y - c.x * a.y
        }
        let kitchen = !contents.isDisjoint(with: ["stove", "oven", "dishwasher", "refrigerator"])
        let living = !contents.isDisjoint(with: ["sofa", "bed", "television"])
        return kitchen && !living && abs(area) / 2 < 14 ? .wet : .dry
    }

    // MARK: - Orientation

    /// Wall centre lines in plan (x, z).
    private static func wallSegments(_ walls: [FloorPlanData.Surface]) -> [(SIMD2<Float>, SIMD2<Float>)] {
        walls.map { wall in
            let m = wall.matrix, half = wall.size.x / 2
            let a = m.transformPoint(SIMD3(-half, 0, 0)), c = m.transformPoint(SIMD3(half, 0, 0))
            return (SIMD2(a.x, a.z), SIMD2(c.x, c.z))
        }
    }

    private static func distance(_ p: SIMD2<Float>, to segment: (SIMD2<Float>, SIMD2<Float>)) -> Float {
        let d = segment.1 - segment.0
        let t = simd_clamp(simd_dot(p - segment.0, d) / max(simd_length_squared(d), 1e-6), 0, 1)
        return simd_distance(p, segment.0 + d * t)
    }

    /// The object's matrix turned so local +Z is its front (the side facing into the room, away
    /// from the nearest wall behind it).
    private static func objectFrame(_ object: FloorPlanData.Object, walls: [(SIMD2<Float>, SIMD2<Float>)]) -> simd_float4x4 {
        var m = object.matrix
        guard !walls.isEmpty else { return m }
        let c = m.translation
        let z = simd_normalize(m.upperLeft3x3 * SIMD3(0, 0, 1))
        let reach = object.size.z / 2 + 0.25
        func clearance(_ direction: SIMD3<Float>) -> Float {
            let p = c + direction * reach
            return walls.map { distance(SIMD2(p.x, p.z), to: $0) }.min() ?? 10
        }
        if clearance(z) < clearance(-z) {
            // Back is at +Z: turn half way round about Y.
            m = m * simd_float4x4(simd_quatf(angle: .pi, axis: SIMD3(0, 1, 0)))
        }
        return m
    }
}

/// Materials shared by the furnished model, created on demand.
struct Materials {
    let wall, floorWood, floorTile, trim, door, glass, metal: Int
    private(set) var fabric, cushion, wood, white, dark, worktop, cabinet, bedding, blanket, chrome, tileWall: Int
    private var books: [Int]

    init(builder b: inout ModelBuilder, style s: FurnishingStyle) {
        func tex(_ kind: MaterialTextures.Kind) -> URL? { MaterialTextures.url(for: kind) }
        wall = b.material("Wall", color: SIMD4(1, 1, 1, 1), texture: tex(.paint(s.wallPaint)), tile: 2, roughness: 0.95)
        floorWood = b.material("Wood Floor", color: SIMD4(1, 1, 1, 1), texture: tex(.planks(s.floorWood)), tile: 1.6, roughness: 0.55)
        floorTile = b.material("Tile Floor", color: SIMD4(1, 1, 1, 1), texture: tex(.tiles(s.tile, grout: s.tile * 0.8, count: 3)), tile: 1.2, roughness: 0.35)
        trim = b.material("Trim", color: SIMD4(0.96, 0.96, 0.95, 1), roughness: 0.5)
        door = b.material("Door", color: SIMD4(1, 1, 1, 1), texture: tex(.grain(s.wood * 1.05)), tile: 1.2, roughness: 0.5)
        glass = b.material("Glass", color: SIMD4(0.75, 0.85, 0.92, 0.35), doubleSided: true, roughness: 0.05)
        metal = b.material("Brushed Metal", color: SIMD4(0.72, 0.72, 0.74, 1), roughness: 0.35, metalness: 1)
        fabric = b.material("Fabric", color: SIMD4(1, 1, 1, 1), texture: tex(.fabric(s.fabric)), tile: 0.5, roughness: 1)
        cushion = b.material("Cushion", color: SIMD4(1, 1, 1, 1), texture: tex(.fabric(s.accentFabric)), tile: 0.5, roughness: 1)
        wood = b.material("Wood", color: SIMD4(1, 1, 1, 1), texture: tex(.grain(s.wood)), tile: 0.8, roughness: 0.45)
        white = b.material("White Enamel", color: SIMD4(0.95, 0.95, 0.95, 1), roughness: 0.25)
        dark = b.material("Black Glass", color: SIMD4(0.06, 0.06, 0.07, 1), roughness: 0.15)
        worktop = b.material("Worktop", color: SIMD4(1, 1, 1, 1), texture: tex(.stone(s.worktop)), tile: 1.5, roughness: 0.3)
        cabinet = b.material("Cabinet", color: SIMD4(s.cabinet, 1), roughness: 0.4)
        bedding = b.material("Bedding", color: SIMD4(1, 1, 1, 1), texture: tex(.fabric(SIMD3(0.95, 0.95, 0.94))), tile: 0.5, roughness: 1)
        blanket = b.material("Blanket", color: SIMD4(1, 1, 1, 1), texture: tex(.fabric(s.accentFabric)), tile: 0.4, roughness: 1)
        chrome = b.material("Chrome", color: SIMD4(0.85, 0.85, 0.88, 1), roughness: 0.1, metalness: 1)
        tileWall = b.material("Wall Tile", color: SIMD4(1, 1, 1, 1), texture: tex(.tiles(s.tile, grout: s.tile * 0.85, count: 5)), tile: 1, roughness: 0.3)
        books = [SIMD3<Float>(0.62, 0.20, 0.18), SIMD3(0.20, 0.32, 0.50), SIMD3(0.85, 0.78, 0.60), SIMD3(0.25, 0.45, 0.35), SIMD3(0.15, 0.15, 0.17)]
            .enumerated().map { b.material("Books \($0.offset + 1)", color: SIMD4($0.element, 1), roughness: 0.8) }
    }

    func book(_ i: Int) -> Int { books[i % books.count] }
}

// MARK: - Furniture

/// Detailed furniture generated to fit a RoomPlan bounding box. Coordinates are in the object's
/// local frame: x across its width, y up from the floor, +z towards its front.
private enum Furniture {
    static func build(_ object: FloorPlanData.Object, frame: simd_float4x4, floorLevel: Float, data: FloorPlanData,
                      builder b: inout ModelBuilder, materials m: inout Materials) {
        let s = object.size
        // Local frame with y = 0 on the floor under the object.
        var f = frame
        f.columns.3 = SIMD4(frame.transformPoint(SIMD3(0, -s.y / 2, 0)), 1)
        let w = s.x / 2, h = s.y, d = s.z / 2
        func box(_ x0: Float, _ y0: Float, _ z0: Float, _ x1: Float, _ y1: Float, _ z1: Float, _ material: Int) {
            b.addBox(SIMD3(min(x0, x1), min(y0, y1), min(z0, z1)), SIMD3(max(x0, x1), max(y0, y1), max(z0, z1)), in: f, material: material)
        }
        func leg(_ x: Float, _ z: Float, _ height: Float, _ radius: Float, _ material: Int) {
            b.addCylinder(base: SIMD3(x, 0, z), radius: radius, height: height, in: f, material: material, segments: 10)
        }
        func near(_ categories: Set<String>, within radius: Float) -> Bool {
            data.objects.contains { categories.contains($0.category) && simd_distance($0.matrix.translation, object.matrix.translation) < radius && $0.id != object.id }
        }

        let appliances: Set<String> = ["stove", "refrigerator", "oven", "dishwasher", "sink"]
        let isKitchenUnit = ["storage", "dishwasher", "stove", "oven", "sink"].contains(object.category) && h > 0.7 && h < 1.1
            && near(appliances, within: 1.6) && !near(["toilet", "bathtub"], within: 2.2)

        switch object.category {
        case "sofa":
            let arm = min(0.16, w * 0.15), back = min(0.2, d * 0.4), seatH = min(0.45, h * 0.52)
            let legH: Float = 0.08
            for x in [-w + 0.06, w - 0.06] { for z in [-d + 0.06, d - 0.06] { leg(x, z, legH, 0.02, m.wood) } }
            box(-w, legH, -d, w, seatH - 0.1, d, m.fabric)                                    // base
            box(-w, legH, -d, w, h, -d + back, m.fabric)                                      // back
            box(-w, legH, -d, -w + arm, seatH + 0.18, d, m.fabric)                            // arms
            box(w - arm, legH, -d, w, seatH + 0.18, d, m.fabric)
            let seats = max(1, Int(((2 * w - 2 * arm) / 0.75).rounded()))
            let seatW = (2 * w - 2 * arm) / Float(seats)
            for i in 0..<seats {
                let x0 = -w + arm + Float(i) * seatW
                box(x0 + 0.01, seatH - 0.1, -d + back, x0 + seatW - 0.01, seatH, d - 0.02, m.fabric)          // seat cushion
                box(x0 + 0.03, seatH, -d + back, x0 + seatW - 0.03, h - 0.05, -d + back + 0.14, m.fabric)    // back cushion
            }
            box(-w + arm + 0.08, seatH, -d + back + 0.12, -w + arm + 0.5, seatH + 0.4, -d + back + 0.24, m.cushion)
            box(w - arm - 0.5, seatH, -d + back + 0.12, w - arm - 0.08, seatH + 0.4, -d + back + 0.24, m.cushion)

        case "chair" where s.x > 0.7 && h < 0.9:
            // Armchair.
            let legH: Float = 0.12
            for x in [-w + 0.07, w - 0.07] { for z in [-d + 0.07, d - 0.07] { leg(x, z, legH, 0.018, m.wood) } }
            box(-w, legH, -d, w, 0.42, d, m.fabric)
            box(-w, legH, -d, w, h, -d + 0.16, m.fabric)
            box(-w, legH, -d, -w + 0.12, 0.62, d, m.fabric)
            box(w - 0.12, legH, -d, w, 0.62, d, m.fabric)
            box(-w + 0.14, 0.42, -d + 0.2, w - 0.14, 0.5, d - 0.03, m.cushion)

        case "chair":
            let seat = min(0.46, h * 0.52), r: Float = 0.018
            for x in [-w + 0.04, w - 0.04] { for z in [-d + 0.04, d - 0.04] { leg(x, z, seat - 0.03, r, m.wood) } }
            box(-w, seat - 0.03, -d, w, seat, d, m.wood)
            for x in [-w + 0.04, w - 0.04] { box(x - 0.018, seat, -d + 0.01, x + 0.018, h, -d + 0.045, m.wood) }
            box(-w + 0.02, h - 0.16, -d + 0.01, w - 0.02, h - 0.03, -d + 0.04, m.wood)

        case "table":
            let top: Float = h < 0.6 ? 0.035 : 0.04
            box(-w, h - top, -d, w, h, d, m.wood)
            let inset: Float = 0.06, r: Float = h < 0.6 ? 0.022 : 0.028
            for x in [-w + inset, w - inset] { for z in [-d + inset, d - inset] { leg(x, z, h - top, r, m.wood) } }
            if h < 0.6 {
                box(-w + 0.08, 0.1, -d + 0.08, w - 0.08, 0.125, d - 0.08, m.wood)           // shelf
                box(-0.12, h, -0.08, 0.1, h + 0.03, 0.08, m.book(1))                          // books
                box(-0.1, h + 0.03, -0.07, 0.08, h + 0.05, 0.07, m.book(2))
            } else {
                box(-w + inset, h - top - 0.08, -d + inset, w - inset, h - top, -d + inset + 0.02, m.wood) // aprons
                box(-w + inset, h - top - 0.08, d - inset - 0.02, w - inset, h - top, d - inset, m.wood)
            }

        case "bed":
            let frameH = min(0.3, h * 0.5), mattress = h
            box(-w, 0.05, -d, w, frameH, d, m.wood)
            for x in [-w + 0.05, w - 0.05] { for z in [-d + 0.05, d - 0.05] { leg(x, z, 0.05, 0.03, m.wood) } }
            box(-w + 0.02, frameH, -d + 0.08, w - 0.02, mattress, d - 0.02, m.bedding)       // mattress + duvet
            box(-w - 0.01, mattress - 0.12, -d + 0.55 * (2 * d), w + 0.01, mattress + 0.02, d, m.blanket) // throw
            box(-w, 0.05, -d - 0.05, w, max(1.0, h + 0.45), -d + 0.02, m.fabric)              // headboard
            let pillows = w > 0.6 ? 2 : 1
            let pw = (2 * w - 0.2) / Float(pillows)
            for i in 0..<pillows {
                let x0 = -w + 0.1 + Float(i) * pw
                box(x0 + 0.03, mattress, -d + 0.1, x0 + pw - 0.03, mattress + 0.13, -d + 0.48, m.bedding)
            }

        case "storage" where h > 1.5 && min(s.x, s.z) >= 0.5:
            // Wardrobe with two (or more) doors.
            box(-w, 0.06, -d, w, h, d - 0.02, m.wood)
            box(-w + 0.02, 0, -d + 0.02, w - 0.02, 0.06, d - 0.06, m.dark)
            let doors = max(2, Int((2 * w / 0.5).rounded()))
            let dw = (2 * w) / Float(doors)
            for i in 0..<doors {
                let x0 = -w + Float(i) * dw
                box(x0 + 0.003, 0.07, d - 0.02, x0 + dw - 0.003, h - 0.01, d, m.wood)
                let hx = i % 2 == 0 ? x0 + dw - 0.05 : x0 + 0.05
                box(hx - 0.008, h * 0.45, d, hx + 0.008, h * 0.45 + 0.3, d + 0.025, m.metal)
            }

        case "storage" where h > 1.5:
            // Bookcase.
            let side: Float = 0.022
            box(-w, 0, -d, -w + side, h, d, m.wood)
            box(w - side, 0, -d, w, h, d, m.wood)
            box(-w, 0, -d, w, h, -d + 0.01, m.wood)
            let shelves = max(3, Int(h / 0.36))
            var seed: UInt32 = UInt32(truncatingIfNeeded: abs(object.id.hashValue)) | 1
            for i in 0...shelves {
                let y = Float(i) / Float(shelves) * (h - side)
                box(-w + side, y, -d, w - side, y + side, d, m.wood)
                guard i < shelves else { continue }
                var x = -w + side + 0.02
                while x < w - side - 0.08 {
                    seed = seed &* 1_103_515_245 &+ 12345
                    let bw = 0.025 + Float(seed >> 28) / 16 * 0.03
                    let bh = min((h - side) / Float(shelves) - 0.05, 0.2 + Float((seed >> 20) & 0xFF) / 255 * 0.1)
                    if (seed >> 12) & 7 == 0 { x += 0.1; continue }
                    box(x, y + side, -d + 0.03, x + bw, y + side + bh, d - 0.03, m.book(Int(seed >> 24)))
                    x += bw + 0.004
                }
            }

        case "storage" where h < 0.7:
            // Nightstand / chest.
            box(-w, 0.05, -d, w, h, d - 0.015, m.wood)
            for z in [-d + 0.04, d - 0.05] { for x in [-w + 0.04, w - 0.04] { leg(x, z, 0.05, 0.015, m.wood) } }
            let drawers = h > 0.45 ? 2 : 1
            for i in 0..<drawers {
                let y0 = 0.06 + Float(i) * (h - 0.06) / Float(drawers)
                box(-w + 0.01, y0 + 0.005, d - 0.015, w - 0.01, y0 + (h - 0.06) / Float(drawers) - 0.005, d, m.wood)
                box(-0.05, y0 + (h - 0.06) / Float(drawers) / 2 - 0.006, d, 0.05, y0 + (h - 0.06) / Float(drawers) / 2 + 0.006, d + 0.02, m.metal)
            }
            if w > 0.15 { b.addCylinder(base: SIMD3(0.05, h, 0), radius: 0.06, height: 0.25, in: f, material: m.white, segments: 14) } // lamp

        case _ where isKitchenUnit:
            // A run of fitted kitchen units with worktop.
            let top = h
            box(-w, 0.1, -d, w, top - 0.04, d - 0.02, m.cabinet)
            box(-w + 0.02, 0, -d + 0.02, w - 0.02, 0.1, d - 0.08, m.dark)                     // plinth
            box(-w - 0.005, top - 0.04, -d, w + 0.005, top, d + 0.02, m.worktop)
            switch object.category {
            case "stove", "oven":
                box(-w + 0.03, 0.14, d - 0.02, w - 0.03, top - 0.12, d, m.dark)             // oven door
                box(-w + 0.08, top - 0.2, d, w - 0.08, top - 0.185, d + 0.03, m.metal)     // handle
                box(-w + 0.04, top, -d + 0.06, w - 0.04, top + 0.006, d - 0.06, m.dark)   // hob
                for (x, z) in [(-0.14, -0.12), (0.14, -0.12), (-0.14, 0.12), (0.14, 0.12)] as [(Float, Float)] where abs(x) < w {
                    b.addCylinder(base: SIMD3(x, top + 0.006, z), radius: 0.08, height: 0.002, in: f, material: m.metal, segments: 20)
                }
            case "sink":
                box(-w + 0.08, top - 0.005, -d + 0.1, w - 0.08, top + 0.003, d - 0.08, m.chrome)
                box(-w + 0.11, top - 0.004, -d + 0.13, w - 0.11, top + 0.004, d - 0.11, m.dark)
                b.addCylinder(base: SIMD3(0, top, -d + 0.07), radius: 0.02, height: 0.3, in: f, material: m.chrome, segments: 12)
                box(-0.012, top + 0.27, -d + 0.07, 0.012, top + 0.3, -d + 0.25, m.chrome)
                doors(&b, f, w, d, top, m)
            case "dishwasher":
                box(-w + 0.01, 0.12, d - 0.02, w - 0.01, top - 0.06, d, m.cabinet)
                box(-w + 0.08, top - 0.14, d, w - 0.08, top - 0.125, d + 0.025, m.metal)
            default:
                doors(&b, f, w, d, top, m)
            }

        case "storage":
            // Sideboard / cabinet.
            box(-w, 0.08, -d, w, h, d - 0.02, m.wood)
            for x in [-w + 0.05, w - 0.05] { for z in [-d + 0.05, d - 0.07] { leg(x, z, 0.08, 0.018, m.wood) } }
            let n = max(2, Int((2 * w / 0.5).rounded()))
            for i in 0..<n {
                let x0 = -w + Float(i) * 2 * w / Float(n)
                box(x0 + 0.004, 0.09, d - 0.02, x0 + 2 * w / Float(n) - 0.004, h - 0.01, d, m.wood)
            }

        case "refrigerator":
            box(-w, 0, -d, w, h, d - 0.03, m.white)
            box(-w + 0.005, 0.01, d - 0.03, w - 0.005, h * 0.62 - 0.005, d, m.white)
            box(-w + 0.005, h * 0.62 + 0.005, d - 0.03, w - 0.005, h - 0.01, d, m.white)
            box(w - 0.07, h * 0.4, d, w - 0.05, h * 0.58, d + 0.035, m.metal)
            box(w - 0.07, h * 0.66, d, w - 0.05, h * 0.8, d + 0.035, m.metal)

        case "stove", "oven":
            // Freestanding cooker.
            box(-w, 0, -d, w, h - 0.02, d - 0.02, m.white)
            box(-w + 0.04, 0.1, d - 0.02, w - 0.04, h - 0.16, d, m.dark)
            box(-w, h - 0.02, -d, w, h, d, m.dark)
            for (x, z) in [(-0.14, -0.12), (0.14, -0.12), (-0.14, 0.12), (0.14, 0.12)] as [(Float, Float)] where abs(x) < w {
                b.addCylinder(base: SIMD3(x, h, z), radius: 0.08, height: 0.003, in: f, material: m.metal, segments: 20)
            }

        case "dishwasher":
            box(-w, 0, -d, w, h, d - 0.02, m.white)
            box(-w + 0.01, 0.1, d - 0.02, w - 0.01, h - 0.02, d, m.white)
            box(-w + 0.08, h - 0.12, d, w - 0.08, h - 0.105, d + 0.025, m.metal)

        case "sink":
            // Bathroom vanity with basin, tap and mirror.
            let top = max(0.8, h)
            box(-w, 0.15, -d, w, top - 0.12, d - 0.02, m.wood)
            box(-w + 0.01, 0.16, d - 0.02, w - 0.01, top - 0.13, d, m.wood)
            box(-w, top - 0.12, -d, w, top - 0.02, d, m.white)
            b.addCylinder(base: SIMD3(0, top - 0.02, 0.02), radius: min(w, d) * 0.7, height: 0.02, in: f, material: m.white, segments: 24)
            b.addCylinder(base: SIMD3(0, top - 0.015, 0.02), radius: min(w, d) * 0.55, height: 0.02, in: f, material: m.chrome, segments: 24)
            b.addCylinder(base: SIMD3(0, top - 0.02, -d + 0.06), radius: 0.018, height: 0.2, in: f, material: m.chrome, segments: 12)
            box(-0.012, top + 0.15, -d + 0.06, 0.012, top + 0.18, -d + 0.18, m.chrome)
            box(-w + 0.05, top + 0.35, -d - 0.005, w - 0.05, top + 1.05, -d + 0.01, m.chrome)   // mirror

        case "toilet":
            // Bowl, seat, cistern.
            let bowlR = min(w, d * 0.55)
            b.addCylinder(base: SIMD3(0, 0, 0.05), radius: bowlR * 0.75, height: 0.38, in: f, material: m.white, segments: 20)
            b.addCylinder(base: SIMD3(0, 0.38, 0.05), radius: bowlR, height: 0.03, in: f, material: m.white, segments: 24)
            box(-w, 0.3, -d, w, h, -d + 0.18, m.white)
            box(-0.05, h, -d + 0.07, 0.05, h + 0.01, -d + 0.12, m.chrome)

        case "bathtub":
            let rim: Float = 0.07
            box(-w, 0, -d, w, 0.08, d, m.white)                  // base
            box(-w, 0, -d, w, h, -d + rim, m.white)              // sides
            box(-w, 0, d - rim, w, h, d, m.white)
            box(-w, 0, -d, -w + rim, h, d, m.white)
            box(w - rim, 0, -d, w, h, d, m.white)
            box(-w + rim, 0.08, -d + rim, w - rim, 0.1, d - rim, m.chrome)
            b.addCylinder(base: SIMD3(-w + 0.12, h, -d + rim / 2), radius: 0.02, height: 0.15, in: f, material: m.chrome, segments: 12)

        case "washerDryer":
            box(-w, 0, -d, w, h, d - 0.01, m.white)
            let r = min(w, h / 2) * 0.6
            // Porthole: a cylinder whose axis points out of the front (+z).
            var door = matrix_identity_float4x4
            door.columns.3 = SIMD4(0, h * 0.45, d - 0.01, 1)
            door = f * door * simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0)))
            b.addCylinder(base: .zero, radius: r, height: 0.03, in: door, material: m.chrome, segments: 28)
            b.addCylinder(base: .zero, radius: r * 0.8, height: 0.035, in: door, material: m.dark, segments: 28)
            box(-w + 0.02, h - 0.12, d - 0.01, w - 0.02, h - 0.02, d, m.dark)

        case "television":
            box(-w, 0.02, -0.03, w, h, 0.03, m.dark)
            box(-0.15, 0, -0.1, 0.15, 0.02, 0.1, m.dark)

        case "fireplace":
            box(-w, 0, -d, w, h, d, m.white)
            box(-w * 0.6, 0.1, d - 0.02, w * 0.6, h * 0.6, d + 0.001, m.dark)
            box(-w - 0.05, h, -d, w + 0.05, h + 0.05, d + 0.05, m.wood)

        case "stairs":
            let steps = max(3, Int(h / 0.18))
            for i in 0..<steps {
                let z0 = -d + Float(i) / Float(steps) * 2 * d
                box(-w, 0, z0, w, Float(i + 1) / Float(steps) * h, d, m.wood)
            }

        default:
            box(-w, 0, -d, w, h, d, m.cabinet)
        }
    }

    /// Door fronts for fitted kitchen units.
    private static func doors(_ b: inout ModelBuilder, _ f: simd_float4x4, _ w: Float, _ d: Float, _ top: Float, _ m: Materials) {
        let n = max(1, Int((2 * w / 0.6).rounded()))
        let dw = 2 * w / Float(n)
        for i in 0..<n {
            let x0 = -w + Float(i) * dw
            b.addBox(SIMD3(x0 + 0.003, 0.11, d - 0.02), SIMD3(x0 + dw - 0.003, top - 0.05, d), in: f, material: m.cabinet)
            b.addBox(SIMD3(x0 + dw / 2 - 0.08, top - 0.12, d), SIMD3(x0 + dw / 2 + 0.08, top - 0.108, d + 0.02), in: f, material: m.metal)
        }
    }
}
