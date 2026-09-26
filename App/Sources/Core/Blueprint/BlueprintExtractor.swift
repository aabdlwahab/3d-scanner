import Foundation
import simd

struct BlueprintOptions: Codable, Equatable {
    /// Raster size for rooms and furniture (m).
    var cellSize: Float = 0.05
    var minWallLength: Float = 0.4
    /// Scanned surface (m²) a wall face needs before it counts.
    var minFaceArea: Float = 0.2
    /// Wall evidence is taken from this band: floor + `bandBottom` … ceiling − `bandTopMargin`.
    var bandBottom: Float = 0.3
    var bandTopMargin: Float = 0.12
    /// Gaps shorter than this along a wall are bridged (occlusions, scan holes).
    var mergeGap: Float = 0.35
    /// Fraction of the band a wall face must cover (rejects low furniture).
    var minHeightCoverage: Float = 0.45
    var maxWallThickness: Float = 0.45
    /// Thickness used when only one side of a wall was scanned.
    var defaultThickness: Float = 0.12
    var snapDistance: Float = 0.4
    var minRoomArea: Float = 1.0
}

/// One oriented surface element used as evidence (a mesh triangle or a point).
struct BlueprintSample {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    /// Surface area it represents, m².
    var weight: Float
    var surfaceClass: SurfaceClass?
}

extension BlueprintSample {
    static func samples(from mesh: TexturedMesh) -> [BlueprintSample] {
        let classified = mesh.classes.count == mesh.vertexCount && mesh.classes.contains { $0 != 0 }
        var result: [BlueprintSample] = []
        result.reserveCapacity(mesh.triangleCount)
        for group in mesh.groups {
            var i = 0
            while i + 2 < group.indices.count {
                let a = Int(group.indices[i]), b = Int(group.indices[i + 1]), c = Int(group.indices[i + 2])
                if let sample = make(mesh.positions[a], mesh.positions[b], mesh.positions[c],
                                     classified ? SurfaceClass.from(mesh.classes[a]) : nil) {
                    result.append(sample)
                }
                i += 3
            }
        }
        return result
    }

    static func samples(from mesh: RawMesh) -> [BlueprintSample] {
        let classified = mesh.classes.count == mesh.triangleCount && mesh.classes.contains { $0 != 0 }
        var result: [BlueprintSample] = []
        result.reserveCapacity(mesh.triangleCount)
        for t in 0..<mesh.triangleCount {
            let a = Int(mesh.indices[3 * t]), b = Int(mesh.indices[3 * t + 1]), c = Int(mesh.indices[3 * t + 2])
            if let sample = make(mesh.positions[a], mesh.positions[b], mesh.positions[c], classified ? SurfaceClass.from(mesh.classes[t]) : nil) {
                result.append(sample)
            }
        }
        return result
    }

    /// Point clouds have no normals: they are estimated (unoriented) from neighbors.
    static func samples(from cloud: PointCloud) -> [BlueprintSample] {
        let spacing = PointCloudFilters.averageSpacing(cloud.positions)
        let normals = PointCloudFilters.estimateNormals(cloud.positions, radius: max(0.03, spacing * 3.5))
        let weight = spacing * spacing
        return cloud.positions.indices.map { BlueprintSample(position: cloud.positions[$0], normal: normals[$0], weight: weight, surfaceClass: nil) }
    }

    private static func make(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ surfaceClass: SurfaceClass?) -> BlueprintSample? {
        let cross = simd_cross(b - a, c - a)
        let length = simd_length(cross)
        guard length > 1e-9 else { return nil }
        return BlueprintSample(position: (a + b + c) / 3, normal: cross / length, weight: length / 2, surfaceClass: surfaceClass)
    }
}

struct BlueprintResult {
    struct Room {
        var name: String
        var area: Double
    }

    var plan: FloorPlanData
    var floorHeight: Float
    var ceilingHeight: Float
    var ceilingDetected: Bool
    var rotationDegrees: Float
    var rooms: [Room]
    var notes: [String]

    var floorArea: Double { rooms.reduce(0) { $0 + $1.area } }
}

enum BlueprintError: LocalizedError {
    case noFloor
    case noWalls

    var errorDescription: String? {
        switch self {
        case .noFloor: "No floor was found. Make sure the scan includes the floor, or crop away anything below it."
        case .noWalls: "Not enough wall surface was found to draw a plan. Scan the walls from floor to ceiling."
        }
    }
}

/// Reconstructs a dimensioned floor plan (walls with thickness, doors, windows, rooms, furniture)
/// from a LiDAR mesh or point cloud of an interior, assuming a gravity-aligned scan (+Y up) and
/// mostly perpendicular walls.
enum BlueprintExtractor {
    private struct Aligned {
        var u: Float, v: Float, y: Float
        var nu: Float, nv: Float, ny: Float
        var weight: Float
        var surfaceClass: SurfaceClass?
    }

    private struct FaceSegment {
        var family: Int  // 0: plane u = offset, runs along v. 1: plane v = offset, runs along u.
        var sign: Int    // +1: faces +offset (wall body below), −1: faces −offset, 0: unknown
        var offset: Float
        var a0: Float, a1: Float
        var samples: [Int]
    }

    private struct WallLine {
        var family: Int
        var low: Float, high: Float
        var a0: Float, a1: Float
        var samples: [Int]
        var paired: Bool
        var openings: [Opening] = []

        var center: Float { (low + high) / 2 }
        var thickness: Float { high - low }
        var length: Float { a1 - a0 }
    }

    private struct Opening {
        var kind: FloorPlanData.SurfaceKind
        var a0: Float, a1: Float
        var y0: Float, y1: Float
        var isOpen: Bool?
    }

    static func extract(samples: [BlueprintSample], orientedNormals: Bool, options: BlueprintOptions = BlueprintOptions()) throws -> BlueprintResult {
        var notes: [String] = []

        // 1. Floor and ceiling heights.
        let floorY = try floorHeight(samples, orientedNormals: orientedNormals)
        var ceilingDetected = true
        var ceilingY: Float
        let ceilingClass = samples.filter { $0.surfaceClass == .ceiling }
        if ceilingClass.reduce(0, { $0 + $1.weight }) >= 0.5 {
            ceilingY = weightedMedian(ceilingClass.map { ($0.position.y, $0.weight) })
        } else if let level = majorLevel(samples.filter {
            (orientedNormals ? $0.normal.y < -0.85 : abs($0.normal.y) > 0.85) && $0.position.y > floorY + 1.8
        }, lowest: false) {
            ceilingY = level
        } else {
            ceilingDetected = false
            let heights = samples.filter { abs($0.normal.y) < 0.3 }.map(\.position.y).sorted()
            let top = heights.isEmpty ? floorY + 2.5 : heights[Int(Double(heights.count - 1) * 0.98)]
            ceilingY = max(floorY + 2.3, top)
            notes.append("The ceiling wasn't scanned, so wall height is estimated at \(String(format: "%.2f", ceilingY - floorY)) m.")
        }
        if ceilingY - floorY < 1.6 { ceilingY = floorY + 2.5 }

        // 2. Wall evidence and the dominant wall direction.
        let bandLow = floorY + options.bandBottom
        let bandHigh = max(bandLow + 0.8, ceilingY - options.bandTopMargin)
        let excluded: Set<SurfaceClass> = [.table, .seat, .floor, .ceiling, .door, .window]
        let vertical = samples.filter { abs($0.normal.y) < 0.3 && $0.position.y >= bandLow && $0.position.y <= bandHigh }
        let wallSamples = vertical.filter { $0.surfaceClass.map { !excluded.contains($0) } ?? true }
        guard wallSamples.reduce(0, { $0 + $1.weight }) >= 1.0 else { throw BlueprintError.noWalls }
        let theta = dominantAngle(wallSamples)
        let cosT = cos(theta), sinT = sin(theta)
        func align(_ p: SIMD3<Float>) -> SIMD2<Float> { SIMD2(cosT * p.x + sinT * p.z, -sinT * p.x + cosT * p.z) }
        func unalign(_ q: SIMD2<Float>) -> SIMD2<Float> { SIMD2(cosT * q.x - sinT * q.y, sinT * q.x + cosT * q.y) }
        func aligned(_ s: BlueprintSample) -> Aligned {
            let p = align(s.position), n = align(s.normal)
            return Aligned(u: p.x, v: p.y, y: s.position.y, nu: n.x, nv: n.y, ny: s.normal.y, weight: s.weight, surfaceClass: s.surfaceClass)
        }
        let walls = wallSamples.map(aligned)
        let openingEvidence = samples.filter { $0.surfaceClass == .door || $0.surfaceClass == .window }.map(aligned)
        let all = samples.map(aligned)

        // 3. Floor coverage raster (aligned frame).
        let cell = options.cellSize
        let uMin = (all.map(\.u).min() ?? 0) - 0.5, vMin = (all.map(\.v).min() ?? 0) - 0.5
        let uMax = (all.map(\.u).max() ?? 1) + 0.5, vMax = (all.map(\.v).max() ?? 1) + 0.5
        let nu = Int(((uMax - uMin) / cell).rounded(.up)) + 1, nv = Int(((vMax - vMin) / cell).rounded(.up)) + 1
        func cellOf(_ u: Float, _ v: Float) -> (Int, Int) { (Int((u - uMin) / cell), Int((v - vMin) / cell)) }
        var floorGrid = BinaryGrid(width: nu, height: nv)
        for s in all {
            let unlabeled = s.surfaceClass == nil || s.surfaceClass == SurfaceClass.none
            let isFloor = s.surfaceClass == .floor || (unlabeled && s.ny > 0.8 && abs(s.y - floorY) < 0.12)
            // Furniture hides the floor under it; count its footprint as floor.
            let isFurniture = s.surfaceClass == .table || s.surfaceClass == .seat
            if isFloor || isFurniture {
                let (i, j) = cellOf(s.u, s.v)
                floorGrid[i, j] = true
            }
        }
        let seenFloor = floorGrid.closed(2)

        // 4. Wall faces: peaks of the offset histogram per direction family (and facing side).
        var segments: [FaceSegment] = []
        for family in 0...1 {
            let candidates = walls.indices.filter { abs(family == 0 ? walls[$0].nu : walls[$0].nv) >= 0.94 }
            let sides = orientedNormals ? [1, -1] : [0]
            for side in sides {
                let subset = candidates.filter { side == 0 || ((family == 0 ? walls[$0].nu : walls[$0].nv) > 0) == (side > 0) }
                let offsets = subset.map { family == 0 ? walls[$0].u : walls[$0].v }
                for face in faces(offsets: offsets, weights: subset.map { walls[$0].weight }, minArea: options.minFaceArea) {
                    let members = face.members.map { subset[$0] }
                    segments += faceSegments(family: family, side: side, offset: face.offset, members: members, walls: walls,
                                             bandLow: bandLow, bandHigh: bandHigh, requireTop: ceilingDetected, options: options)
                }
            }
        }

        // 5. Pair the two faces of each wall (a face looking +offset above one looking −offset;
        //    unknown-facing faces pair by geometry alone) to measure its thickness.
        var lines: [WallLine] = []
        var used = Set<Int>()
        let order = segments.indices.sorted { segments[$0].a1 - segments[$0].a0 > segments[$1].a1 - segments[$1].a0 }
        for pIndex in order where segments[pIndex].sign >= 0 && !used.contains(pIndex) {
            let p = segments[pIndex]
            var best: (index: Int, overlap: Float)?
            for (qIndex, q) in segments.enumerated() where qIndex != pIndex && !used.contains(qIndex) && q.family == p.family && q.sign <= 0 {
                let thickness = p.offset - q.offset
                guard thickness >= 0.03, thickness <= options.maxWallThickness else { continue }
                let overlap = min(p.a1, q.a1) - max(p.a0, q.a0)
                guard overlap >= 0.4 * min(p.a1 - p.a0, q.a1 - q.a0) else { continue }
                if best == nil || overlap > best!.overlap { best = (qIndex, overlap) }
            }
            guard let best else { continue }
            let q = segments[best.index]
            used.insert(pIndex)
            used.insert(best.index)
            lines.append(WallLine(family: p.family, low: q.offset, high: p.offset, a0: min(p.a0, q.a0), a1: max(p.a1, q.a1),
                                  samples: p.samples + q.samples, paired: true))
        }
        // Single faces: the wall body lies behind the face, away from the room.
        for (index, face) in segments.enumerated() where !used.contains(index) {
            var sign = face.sign
            if sign == 0 {
                var plus = 0, minus = 0
                var a = face.a0
                while a <= face.a1 {
                    for (delta, isPlus) in [(Float(0.25), true), (Float(-0.25), false)] {
                        let o = face.offset + delta
                        let (i, j) = face.family == 0 ? cellOf(o, a) : cellOf(a, o)
                        if seenFloor[i, j] { if isPlus { plus += 1 } else { minus += 1 } }
                    }
                    a += 0.2
                }
                sign = plus > minus * 2 ? 1 : (minus > plus * 2 ? -1 : 0)
            }
            let t = options.defaultThickness
            let (low, high) = sign > 0 ? (face.offset - t, face.offset) : (sign < 0 ? (face.offset, face.offset + t) : (face.offset - t / 2, face.offset + t / 2))
            lines.append(WallLine(family: face.family, low: low, high: high, a0: face.a0, a1: face.a1, samples: face.samples, paired: false))
        }

        // 6. Merge collinear pieces, bridge doorways, snap corners.
        lines = mergeCollinear(lines, maxGap: options.mergeGap)
        lines = bridgeDoorways(lines, walls: walls, evidence: openingEvidence, floorY: floorY, options: options)
        for _ in 0..<2 { snapCorners(&lines, distance: options.snapDistance) }
        lines.removeAll { $0.length < options.minWallLength }

        // 7. Doors and windows inside walls.
        for k in lines.indices {
            lines[k].openings += detectOpenings(in: lines[k], walls: walls, evidence: openingEvidence, floorY: floorY, bandHigh: bandHigh)
        }

        // 8. Rooms: floor coverage split by walls.
        var barrier = BinaryGrid(width: nu, height: nv)
        for line in lines {
            var o = line.low - cell / 2
            while o <= line.high + cell / 2 {
                var a = line.a0
                while a <= line.a1 {
                    let (i, j) = line.family == 0 ? cellOf(o, a) : cellOf(a, o)
                    barrier[i, j] = true
                    a += cell / 2
                }
                o += cell / 2
            }
        }
        // Floor hidden under furniture or behind it counts when walls and seen floor enclose it.
        var enclosed = seenFloor
        for k in enclosed.cells.indices where barrier.cells[k] { enclosed.cells[k] = true }
        let free = enclosed.holesFilled() & barrier.inverted()
        let minCells = Int(options.minRoomArea / (cell * cell))
        let components = free.components(minCells: max(1, minCells)).sorted { $0.count > $1.count }

        // 9. Assemble the floor plan in world coordinates.
        var plan = FloorPlanData()
        let wallHeight = ceilingY - floorY
        func world(_ q: SIMD2<Float>) -> SIMD2<Float> { unalign(q) }
        func axes(family: Int) -> (x: SIMD3<Float>, z: SIMD3<Float>) {
            let d = unalign(family == 0 ? SIMD2(0, 1) : SIMD2(1, 0))
            let x = SIMD3(d.x, 0, d.y)
            return (x, simd_cross(x, SIMD3(0, 1, 0)))
        }
        func point(_ line: WallLine, along a: Float) -> SIMD2<Float> {
            world(line.family == 0 ? SIMD2(line.center, a) : SIMD2(a, line.center))
        }
        func transform(x: SIMD3<Float>, z: SIMD3<Float>, center: SIMD3<Float>) -> [Float] {
            simd_float4x4(SIMD4(x, 0), SIMD4(0, 1, 0, 0), SIMD4(z, 0), SIMD4(center, 1)).columnMajorArray
        }

        var doorCount = 0, windowCount = 0
        for line in lines {
            let (x, z) = axes(family: line.family)
            let mid = point(line, along: (line.a0 + line.a1) / 2)
            let wall = FloorPlanData.Surface(id: UUID(), kind: .wall,
                                             transform: transform(x: x, z: z, center: SIMD3(mid.x, floorY + wallHeight / 2, mid.y)),
                                             dimensions: [line.length, wallHeight, line.thickness])
            plan.surfaces.append(wall)
            for opening in line.openings {
                let center = point(line, along: (opening.a0 + opening.a1) / 2)
                plan.surfaces.append(FloorPlanData.Surface(
                    id: UUID(), kind: opening.kind,
                    transform: transform(x: x, z: z, center: SIMD3(center.x, (opening.y0 + opening.y1) / 2, center.y)),
                    dimensions: [opening.a1 - opening.a0, opening.y1 - opening.y0, 0], isOpen: opening.isOpen, parentID: wall.id))
                if opening.kind == .door || opening.kind == .opening { doorCount += 1 }
                if opening.kind == .window { windowCount += 1 }
            }
        }

        var rooms: [BlueprintResult.Room] = []
        let floorTransform = simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, -1, 0, 0), SIMD4(0, floorY, 0, 1)).columnMajorArray
        for (index, component) in components.enumerated() {
            let area = Double(component.count) * Double(cell * cell)
            let corners = free.outline(of: component).map { SIMD2(uMin + Float($0.x) * cell, vMin + Float($0.y) * cell) }
            let polygon = simplifyPolygon(corners, tolerance: cell * 0.75).map(world)
            guard polygon.count >= 3 else { continue }
            let name = "Room \(index + 1)"
            let inner = free.innermostCell(of: component)
            let label = world(SIMD2(uMin + (Float(inner % nu) + 0.5) * cell, vMin + (Float(inner / nu) + 0.5) * cell))
            let size = BoundingBox(points: polygon.map { SIMD3($0.x, 0, $0.y) }).size
            plan.surfaces.append(FloorPlanData.Surface(id: UUID(), kind: .floor, transform: floorTransform,
                                                       dimensions: [size.x, size.z, 0], polygon: polygon.map { [$0.x, $0.y, 0] }))
            plan.sections.append(FloorPlanData.Section(label: name, center: [label.x, floorY, label.y]))
            rooms.append(BlueprintResult.Room(name: name, area: area))
        }
        plan.objects = furniture(all, floorY: floorY, cellOf: cellOf, nu: nu, nv: nv, uMin: uMin, vMin: vMin, cell: cell, unalign: unalign)
        plan.roomCount = max(1, rooms.count)

        notes.insert("Found \(lines.count) walls, \(doorCount) doors or openings, \(windowCount) windows and \(rooms.count) rooms.", at: 0)
        if lines.contains(where: { !$0.paired }) {
            notes.append("Walls seen from one side only use a \(Int(options.defaultThickness * 100)) cm thickness.")
        }
        return BlueprintResult(plan: plan, floorHeight: floorY, ceilingHeight: ceilingY, ceilingDetected: ceilingDetected,
                               rotationDegrees: theta * 180 / .pi, rooms: rooms, notes: notes)
    }

    /// Floor height and dominant wall direction (radians, angle in the XZ plane): enough to level
    /// and square up a scan without building the whole plan.
    static func estimateFrame(samples: [BlueprintSample], orientedNormals: Bool) throws -> (floorHeight: Float, rotation: Float) {
        let floorY = try floorHeight(samples, orientedNormals: orientedNormals)
        let walls = samples.filter {
            abs($0.normal.y) < 0.3 && $0.position.y > floorY + 0.3 && $0.surfaceClass != .table && $0.surfaceClass != .seat
        }
        guard walls.reduce(0, { $0 + $1.weight }) >= 0.5 else { throw BlueprintError.noWalls }
        return (floorY, dominantAngle(walls))
    }

    // MARK: - Levels and orientation

    private static func floorHeight(_ samples: [BlueprintSample], orientedNormals: Bool) throws -> Float {
        let floorClass = samples.filter { $0.surfaceClass == .floor }
        if floorClass.reduce(0, { $0 + $1.weight }) >= 0.5 {
            return weightedMedian(floorClass.map { ($0.position.y, $0.weight) })
        }
        if let level = majorLevel(samples.filter { orientedNormals ? $0.normal.y > 0.85 : abs($0.normal.y) > 0.85 }, lowest: true) {
            return level
        }
        throw BlueprintError.noFloor
    }

    private static func weightedMedian(_ values: [(Float, Float)]) -> Float {
        let sorted = values.sorted { $0.0 < $1.0 }
        let half = sorted.reduce(0) { $0 + $1.1 } / 2
        var running: Float = 0
        for (value, weight) in sorted {
            running += weight
            if running >= half { return value }
        }
        return sorted.last?.0 ?? 0
    }

    /// Lowest (or highest) horizontal level holding at least 30% of the largest level's area.
    private static func majorLevel(_ samples: [BlueprintSample], lowest: Bool) -> Float? {
        guard let minY = samples.map(\.position.y).min(), let maxY = samples.map(\.position.y).max() else { return nil }
        let bin: Float = 0.02
        var histogram = [Float](repeating: 0, count: Int((maxY - minY) / bin) + 3)
        for s in samples { histogram[Int((s.position.y - minY) / bin)] += s.weight }
        let smoothed = histogram.indices.map { k in (max(0, k - 1)...min(histogram.count - 1, k + 1)).reduce(Float(0)) { $0 + histogram[$1] } }
        guard let peak = smoothed.max(), peak >= 0.2 else { return nil }
        let candidates = smoothed.indices.filter { smoothed[$0] >= peak * 0.3 }
        guard let chosen = lowest ? candidates.first : candidates.last else { return nil }
        let center = minY + (Float(chosen) + 0.5) * bin
        let near = samples.filter { abs($0.position.y - center) <= 0.04 }
        let total = near.reduce(0) { $0 + $1.weight }
        return total > 0 ? near.reduce(0) { $0 + $1.position.y * $1.weight } / total : center
    }

    /// Dominant horizontal wall-normal direction modulo 90°.
    private static func dominantAngle(_ samples: [BlueprintSample]) -> Float {
        var sx: Double = 0, sy: Double = 0
        for s in samples {
            let h = SIMD2(s.normal.x, s.normal.z)
            let length = simd_length(h)
            guard length > 0.5 else { continue }
            let angle = Double(atan2(h.y, h.x))
            sx += cos(4 * angle) * Double(s.weight * length)
            sy += sin(4 * angle) * Double(s.weight * length)
        }
        return Float(atan2(sy, sx) / 4)
    }

    // MARK: - Faces

    /// Histogram peaks of wall-plane offsets; returns each face's refined offset and members.
    private static func faces(offsets: [Float], weights: [Float], minArea: Float) -> [(offset: Float, members: [Int])] {
        guard let lo = offsets.min(), let hi = offsets.max() else { return [] }
        let bin: Float = 0.01
        let origin = lo - 0.05
        let count = Int((hi - origin + 0.05) / bin) + 1
        var histogram = [Float](repeating: 0, count: count)
        for (o, w) in zip(offsets, weights) { histogram[min(count - 1, max(0, Int((o - origin) / bin)))] += w }
        var prefix = [Float](repeating: 0, count: count + 1)
        for k in 0..<count { prefix[k + 1] = prefix[k] + histogram[k] }
        let window = (0..<count).map { prefix[min(count, $0 + 4)] - prefix[max(0, $0 - 3)] }
        var peaks: [Float] = []
        for k in 0..<count where window[k] >= minArea {
            var isPeak = true
            for d in -6...6 where d != 0 {
                let m = k + d
                if m >= 0, m < count, window[m] > window[k] || (window[m] == window[k] && m < k) {
                    isPeak = false
                    break
                }
            }
            if isPeak { peaks.append(origin + (Float(k) + 0.5) * bin) }
        }
        var refined = peaks.map { peak -> Float in
            var sum: Float = 0, total: Float = 0
            for (o, w) in zip(offsets, weights) where abs(o - peak) <= 0.035 {
                sum += o * w
                total += w
            }
            return total > 0 ? sum / total : peak
        }
        refined.sort()
        var members = [[Int]](repeating: [], count: refined.count)
        for (index, o) in offsets.enumerated() {
            var best = -1, bestDistance: Float = 0.04
            for (p, peak) in refined.enumerated() where abs(o - peak) <= bestDistance {
                best = p
                bestDistance = abs(o - peak)
            }
            if best >= 0 { members[best].append(index) }
        }
        return zip(refined, members).map { ($0, $1) }
    }

    private static func faceSegments(family: Int, side: Int, offset: Float, members: [Int], walls: [Aligned],
                                     bandLow: Float, bandHigh: Float, requireTop: Bool, options: BlueprintOptions) -> [FaceSegment] {
        func along(_ s: Aligned) -> Float { family == 0 ? s.v : s.u }
        guard let minA = members.map({ along(walls[$0]) }).min(), let maxA = members.map({ along(walls[$0]) }).max() else { return [] }
        let bin: Float = 0.05
        let count = Int((maxA - minA) / bin) + 1
        let bandBins = min(64, max(1, Int(((bandHigh - bandLow) / 0.1).rounded(.up))))
        var weight = [Float](repeating: 0, count: count)
        var mask = [UInt64](repeating: 0, count: count)
        for index in members {
            let s = walls[index]
            let b = min(count - 1, Int((along(s) - minA) / bin))
            weight[b] += s.weight
            let yb = min(bandBins - 1, max(0, Int((s.y - bandLow) / 0.1)))
            mask[b] |= 1 << UInt64(yb)
        }
        let occupied = (0..<count).filter { weight[$0] >= 0.003 }
        guard !occupied.isEmpty else { return [] }
        let maxGapBins = Int(options.mergeGap / bin)
        var runs: [(Int, Int)] = []
        var start = occupied[0], previous = occupied[0]
        for b in occupied.dropFirst() {
            if b - previous - 1 > maxGapBins {
                runs.append((start, previous))
                start = b
            }
            previous = b
        }
        runs.append((start, previous))

        let topMask: UInt64 = (0..<min(3, bandBins)).reduce(0) { $0 | (1 << UInt64(bandBins - 1 - $1)) }
        var result: [FaceSegment] = []
        for (b0, b1) in runs {
            var union: UInt64 = 0
            for b in b0...b1 { union |= mask[b] }
            let coverage = Float(union.nonzeroBitCount) / Float(bandBins)
            let a0 = minA + Float(b0) * bin, a1 = minA + Float(b1 + 1) * bin
            guard a1 - a0 >= 0.25, coverage >= options.minHeightCoverage, !requireTop || union & topMask != 0 else { continue }
            let runMembers = members.filter { along(walls[$0]) >= a0 - 0.01 && along(walls[$0]) <= a1 + 0.01 }
            result.append(FaceSegment(family: family, sign: side, offset: offset, a0: a0, a1: a1, samples: runMembers))
        }
        return result
    }

    // MARK: - Wall topology

    private static func mergeCollinear(_ lines: [WallLine], maxGap: Float) -> [WallLine] {
        var result: [WallLine] = []
        for line in lines.sorted(by: { ($0.family, $0.center, $0.a0) < ($1.family, $1.center, $1.a0) }) {
            if let index = result.lastIndex(where: {
                $0.family == line.family && abs($0.center - line.center) <= 0.08 && line.a0 <= $0.a1 + maxGap && line.a1 >= $0.a0 - maxGap
            }) {
                var merged = result[index]
                if line.paired && !merged.paired || (line.paired == merged.paired && line.length > merged.length) {
                    merged.low = line.low
                    merged.high = line.high
                }
                merged.paired = merged.paired || line.paired
                merged.a0 = min(merged.a0, line.a0)
                merged.a1 = max(merged.a1, line.a1)
                merged.samples += line.samples
                result[index] = merged
            } else {
                result.append(line)
            }
        }
        return result
    }

    /// Joins collinear walls separated by a door-sized gap when there is evidence of a doorway
    /// (door-labelled surfaces, or wall above the gap = a lintel).
    private static func bridgeDoorways(_ lines: [WallLine], walls: [Aligned], evidence: [Aligned], floorY: Float, options: BlueprintOptions) -> [WallLine] {
        var result = lines.sorted { ($0.family, $0.center, $0.a0) < ($1.family, $1.center, $1.a0) }
        var k = 0
        while k + 1 < result.count {
            let a = result[k], b = result[k + 1]
            let gap = b.a0 - a.a1
            guard a.family == b.family, abs(a.center - b.center) <= 0.1, gap >= 0.5, gap <= 1.8 else {
                k += 1
                continue
            }
            func inGap(_ s: Aligned) -> Bool {
                let o = a.family == 0 ? s.u : s.v, t = a.family == 0 ? s.v : s.u
                return abs(o - a.center) <= max(a.thickness, b.thickness) / 2 + 0.2 && t > a.a1 && t < b.a0
            }
            let doorLeaf = evidence.contains { $0.surfaceClass == .door && inGap($0) }
            let lintel = walls.contains { inGap($0) && $0.y > floorY + 1.95 }
            guard doorLeaf || lintel else {
                k += 1
                continue
            }
            var merged = a
            merged.a1 = b.a1
            merged.samples += b.samples
            merged.paired = a.paired || b.paired
            let top = lintel ? min(floorY + 2.1, walls.filter { inGap($0) }.map(\.y).min() ?? floorY + 2.05) : floorY + 2.05
            merged.openings.append(Opening(kind: .door, a0: a.a1, a1: b.a0, y0: floorY, y1: max(floorY + 1.8, top), isOpen: !doorLeaf))
            result[k] = merged
            result.remove(at: k + 1)
        }
        return result
    }

    private static func snapCorners(_ lines: inout [WallLine], distance: Float) {
        for i in lines.indices {
            for j in lines.indices where lines[i].family != lines[j].family {
                let crossing = lines[j].center
                let reach = lines[i].center
                guard reach >= lines[j].a0 - distance, reach <= lines[j].a1 + distance else { continue }
                if abs(lines[i].a0 - crossing) <= distance { lines[i].a0 = crossing }
                if abs(lines[i].a1 - crossing) <= distance { lines[i].a1 = crossing }
            }
        }
    }

    // MARK: - Openings

    private static func detectOpenings(in line: WallLine, walls: [Aligned], evidence: [Aligned], floorY: Float, bandHigh: Float) -> [Opening] {
        func offset(_ s: Aligned) -> Float { line.family == 0 ? s.u : s.v }
        func along(_ s: Aligned) -> Float { line.family == 0 ? s.v : s.u }
        let reach = line.thickness / 2 + 0.3
        var openings = line.openings

        // Labelled doors and windows near this wall.
        for kind in [SurfaceClass.door, .window] {
            let near = evidence.filter { $0.surfaceClass == kind && abs(offset($0) - line.center) <= reach && along($0) >= line.a0 && along($0) <= line.a1 }
            for cluster in clusters(near.map(along), gap: 0.3) where cluster.upperBound - cluster.lowerBound >= (kind == .door ? 0.45 : 0.3) {
                let members = near.filter { along($0) >= cluster.lowerBound && along($0) <= cluster.upperBound }
                let y0 = kind == .door ? floorY : (members.map(\.y).min() ?? floorY + 0.9)
                let y1 = max(y0 + 0.3, members.map(\.y).max() ?? floorY + 2)
                let candidate = Opening(kind: kind == .door ? .door : .window, a0: cluster.lowerBound, a1: cluster.upperBound,
                                        y0: y0, y1: y1, isOpen: kind == .door ? false : nil)
                if !openings.contains(where: { $0.a0 < candidate.a1 && candidate.a0 < $0.a1 }) { openings.append(candidate) }
            }
        }

        // Unlabelled doorways: nothing low or mid-height, but wall above (a lintel).
        let bin: Float = 0.05
        let count = Int(line.length / bin) + 1
        guard count > 2 else { return openings }
        var low = [Bool](repeating: false, count: count), mid = low, high = low
        for index in line.samples {
            let s = walls[index]
            let b = min(count - 1, max(0, Int((along(s) - line.a0) / bin)))
            let h = s.y - floorY
            if h >= 0.35 && h <= 0.85 { low[b] = true } else if h >= 1.0 && h <= 1.8 { mid[b] = true } else if h >= 2.15 { high[b] = true }
        }
        var b = 0
        while b < count {
            guard !low[b] && !mid[b] && high[b] else {
                b += 1
                continue
            }
            var e = b
            while e + 1 < count, !low[e + 1], !mid[e + 1] { e += 1 }
            let a0 = line.a0 + Float(b) * bin, a1 = line.a0 + Float(e + 1) * bin
            if a1 - a0 >= 0.55, a1 - a0 <= 2.2, !openings.contains(where: { $0.a0 < a1 && a0 < $0.a1 }) {
                openings.append(Opening(kind: .door, a0: a0, a1: a1, y0: floorY, y1: floorY + 2.05, isOpen: true))
            }
            b = e + 1
        }
        return openings.sorted { $0.a0 < $1.a0 }
    }

    private static func clusters(_ values: [Float], gap: Float) -> [ClosedRange<Float>] {
        let sorted = values.sorted()
        guard var lo = sorted.first else { return [] }
        var hi = lo
        var result: [ClosedRange<Float>] = []
        for value in sorted.dropFirst() {
            if value - hi > gap {
                result.append(lo...hi)
                lo = value
            }
            hi = value
        }
        result.append(lo...hi)
        return result
    }

    // MARK: - Furniture

    private static func furniture(_ samples: [Aligned], floorY: Float, cellOf: (Float, Float) -> (Int, Int), nu: Int, nv: Int,
                                  uMin: Float, vMin: Float, cell: Float, unalign: (SIMD2<Float>) -> SIMD2<Float>) -> [FloorPlanData.Object] {
        var objects: [FloorPlanData.Object] = []
        for kind in [SurfaceClass.table, .seat] {
            var grid = BinaryGrid(width: nu, height: nv)
            var top = [Float](repeating: floorY, count: nu * nv)
            for s in samples where s.surfaceClass == kind && s.y > floorY + 0.05 {
                let (i, j) = cellOf(s.u, s.v)
                guard i >= 0, j >= 0, i < nu, j < nv else { continue }
                grid[i, j] = true
                top[j * nu + i] = max(top[j * nu + i], s.y)
            }
            for component in grid.dilated(1).components(minCells: Int(0.15 / (cell * cell))) {
                let cellsInside = component.filter { grid.cells[$0] }
                guard !cellsInside.isEmpty else { continue }
                let columns = cellsInside.map { $0 % nu }, rows = cellsInside.map { $0 / nu }
                let u0 = uMin + Float(columns.min()!) * cell, u1 = uMin + Float(columns.max()! + 1) * cell
                let v0 = vMin + Float(rows.min()!) * cell, v1 = vMin + Float(rows.max()! + 1) * cell
                let height = max(0.3, (cellsInside.map { top[$0] }.max() ?? floorY + 0.5) - floorY)
                let center = unalign(SIMD2((u0 + u1) / 2, (v0 + v1) / 2))
                let x = unalign(SIMD2(1, 0)), z = unalign(SIMD2(0, 1))
                let matrix = simd_float4x4(SIMD4(x.x, 0, x.y, 0), SIMD4(0, 1, 0, 0), SIMD4(z.x, 0, z.y, 0),
                                           SIMD4(center.x, floorY + height / 2, center.y, 1))
                let footprint = (u1 - u0) * (v1 - v0)
                let category = kind == .table ? "table" : (footprint > 1.0 ? "sofa" : "chair")
                objects.append(FloorPlanData.Object(id: UUID(), category: category, transform: matrix.columnMajorArray,
                                                    dimensions: [u1 - u0, height, v1 - v0]))
            }
        }
        return objects
    }
}
