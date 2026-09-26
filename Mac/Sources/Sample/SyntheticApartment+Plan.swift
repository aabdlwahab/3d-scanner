import Foundation
import simd

extension SyntheticApartment {
    /// The apartment as a Room Plan scan would record it: walls, doors, windows, floors, room labels
    /// and furniture with RoomPlan categories. Uses the local frame (floor at 0, rooms on the X/Z axes),
    /// which is what a leveled and aligned scan looks like.
    func furnishedPlan() -> FloorPlanData {
        var plan = FloorPlanData()
        let h = height

        func transform(along axis: Int, center: SIMD3<Float>, yaw: Float = 0) -> [Float] {
            // Walls and openings: local X along the wall, Y up, Z across (see FloorPlanData.Surface).
            let x: SIMD3<Float> = axis == 0 ? SIMD3(1, 0, 0) : SIMD3(0, 0, 1)
            let z = simd_cross(x, SIMD3(0, 1, 0))
            return simd_float4x4(SIMD4(x, 0), SIMD4(0, 1, 0, 0), SIMD4(z, 0), SIMD4(center, 1)).columnMajorArray
        }

        /// A wall along `axis` (0 = x, 2 = z) from `from` to `to`, centred at `across` on the other axis.
        @discardableResult
        func wall(axis: Int, from: Float, to: Float, across: Float, thickness: Float,
                  openings: [(kind: FloorPlanData.SurfaceKind, from: Float, to: Float, bottom: Float, top: Float, open: Bool)]) -> UUID {
            let mid = (from + to) / 2
            let center = axis == 0 ? SIMD3(mid, h / 2, across) : SIMD3(across, h / 2, mid)
            let wall = FloorPlanData.Surface(id: UUID(), kind: .wall, transform: transform(along: axis, center: center),
                                             dimensions: [to - from, h, thickness])
            plan.surfaces.append(wall)
            for opening in openings {
                let a = (opening.from + opening.to) / 2, y = (opening.bottom + opening.top) / 2
                let c = axis == 0 ? SIMD3(a, y, across) : SIMD3(across, y, a)
                plan.surfaces.append(FloorPlanData.Surface(
                    id: UUID(), kind: opening.kind, transform: transform(along: axis, center: c),
                    dimensions: [opening.to - opening.from, opening.top - opening.bottom, 0],
                    isOpen: opening.kind == .door ? opening.open : nil, parentID: wall.id))
            }
            return wall.id
        }

        // Exterior walls (20 cm) and interior walls (12 cm), matching the scanned sample.
        wall(axis: 0, from: -0.2, to: 8.2, across: -0.1, thickness: 0.2, openings: [(.window, 1.2, 2.8, 0.9, 2.1, false)])
        wall(axis: 0, from: -0.2, to: 8.2, across: 6.1, thickness: 0.2, openings: [(.window, 6.0, 7.0, 1.2, 2.0, false)])
        wall(axis: 2, from: 0, to: 6, across: -0.1, thickness: 0.2, openings: [(.door, 4.0, 4.9, 0, 2.05, false)])
        wall(axis: 2, from: 0, to: 6, across: 8.1, thickness: 0.2, openings: [(.window, 1.0, 2.4, 0.9, 2.1, false)])
        wall(axis: 2, from: 0, to: 6, across: 4.8, thickness: 0.12, openings: [(.door, 2.0, 2.9, 0, 2.05, true)])
        wall(axis: 0, from: 4.86, to: 8, across: 3.4, thickness: 0.12, openings: [(.door, 6.0, 6.85, 0, 2.05, true)])

        // Floors (local XY = world XZ) and room labels.
        let floorTransform = simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, -1, 0, 0), SIMD4(0, 0, 0, 1)).columnMajorArray
        let rooms: [(label: String, lo: SIMD2<Float>, hi: SIMD2<Float>)] = [
            ("livingRoom", SIMD2(0, 0), SIMD2(4.74, 6)),
            ("bedroom", SIMD2(4.86, 0), SIMD2(8, 3.34)),
            ("bathroom", SIMD2(4.86, 3.46), SIMD2(8, 6)),
        ]
        for room in rooms {
            let polygon: [[Float]] = [[room.lo.x, room.lo.y, 0], [room.hi.x, room.lo.y, 0], [room.hi.x, room.hi.y, 0], [room.lo.x, room.hi.y, 0]]
            plan.surfaces.append(FloorPlanData.Surface(id: UUID(), kind: .floor, transform: floorTransform,
                                                       dimensions: [room.hi.x - room.lo.x, room.hi.y - room.lo.y, 0], polygon: polygon))
            let c = (room.lo + room.hi) / 2
            plan.sections.append(FloorPlanData.Section(label: room.label, center: [c.x, 0, c.y]))
        }
        plan.roomCount = rooms.count

        /// Furniture: `min`/`max` corners of the footprint (x, z) and the height; `alongZ` when the
        /// object's width runs along Z (it faces ±X).
        func object(_ category: String, _ x0: Float, _ z0: Float, _ x1: Float, _ z1: Float, height: Float, alongZ: Bool = false) {
            let center = SIMD3((x0 + x1) / 2, height / 2, (z0 + z1) / 2)
            var m = alongZ ? simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0))) : matrix_identity_float4x4
            m.columns.3 = SIMD4(center, 1)
            let size = alongZ ? [z1 - z0, height, x1 - x0] : [x1 - x0, height, z1 - z0]
            plan.objects.append(FloorPlanData.Object(id: UUID(), category: category, transform: m.columnMajorArray, dimensions: size))
        }
        // Living room with dining area and an open kitchen along the west wall.
        object("sofa", 0.6, 5.05, 2.6, 5.95, height: 0.85)
        object("table", 1.1, 3.9, 2.1, 4.5, height: 0.45)
        object("chair", 3.0, 4.3, 3.8, 5.1, height: 0.8)
        object("storage", 4.34, 3.3, 4.74, 4.6, height: 1.9, alongZ: true)
        object("table", 2.7, 1.2, 3.9, 2.0, height: 0.75)
        for (x, z) in [(3.0, 0.75), (3.6, 0.75), (3.0, 2.0), (3.6, 2.0)] as [(Float, Float)] {
            object("chair", x - 0.22, z, x + 0.22, z + 0.45, height: 0.9)
        }
        object("refrigerator", 0.0, 0.2, 0.65, 0.9, height: 1.85, alongZ: true)
        object("storage", 0.0, 0.9, 0.62, 1.5, height: 0.9, alongZ: true)
        object("stove", 0.0, 1.5, 0.62, 2.1, height: 0.9, alongZ: true)
        object("sink", 0.0, 2.1, 0.62, 2.9, height: 0.9, alongZ: true)
        object("dishwasher", 0.0, 2.9, 0.62, 3.5, height: 0.9, alongZ: true)
        // Bedroom.
        object("bed", 5.4, 0.05, 7.2, 2.15, height: 0.55)
        object("storage", 4.9, 0.05, 5.35, 0.45, height: 0.55)
        object("storage", 7.25, 0.05, 7.7, 0.45, height: 0.55)
        object("storage", 6.95, 2.74, 7.95, 3.34, height: 2.1)
        // Bathroom.
        object("bathtub", 4.9, 5.25, 6.6, 5.98, height: 0.56)
        object("toilet", 7.3, 4.6, 7.95, 5.0, height: 0.8, alongZ: true)
        object("sink", 7.4, 3.55, 7.95, 4.35, height: 0.85, alongZ: true)
        object("washerDryer", 4.9, 3.6, 5.5, 4.2, height: 0.85)
        return plan
    }
}
