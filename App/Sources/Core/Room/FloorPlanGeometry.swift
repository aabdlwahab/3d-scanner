import CoreGraphics
import Foundation
import simd

/// 2D top-down geometry derived from ``FloorPlanData`` (plan X = world X, plan Y = world Z),
/// rotated so the dominant wall direction is axis-aligned.
struct FloorPlanGeometry {
    struct Segment {
        var start: CGPoint
        var end: CGPoint
        var length: Double { hypot(end.x - start.x, end.y - start.y) }
        var midpoint: CGPoint { CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2) }
        var angle: Double { atan2(end.y - start.y, end.x - start.x) }
    }

    struct Door {
        var segment: Segment
        var isOpen: Bool
    }

    struct Footprint {
        var category: String
        var corners: [CGPoint]
        var center: CGPoint
    }

    struct RoomLabel {
        var name: String
        var position: CGPoint
        var area: Double?
    }

    var walls: [Segment] = []
    var doors: [Door] = []
    var windows: [Segment] = []
    var openings: [Segment] = []
    var floors: [[CGPoint]] = []
    var objects: [Footprint] = []
    var labels: [RoomLabel] = []
    /// Rotation applied to world XZ (radians).
    var rotation: Double = 0
    var bounds: CGRect = .zero

    /// Total floor area in m² (from floor polygons, or estimated from the walls).
    var floorArea: Double {
        let fromFloors = floors.reduce(0) { $0 + abs(Self.signedArea($1)) }
        if fromFloors > 0.5 { return fromFloors }
        return abs(Self.signedArea(Self.convexHull(walls.flatMap { [$0.start, $0.end] })))
    }

    var totalWallLength: Double { walls.reduce(0) { $0 + $1.length } }

    init(data: FloorPlanData, story: Int? = nil) {
        let include: (Int) -> Bool = { story == nil || $0 == story }
        rotation = Self.dominantAngle(of: data.walls.filter { include($0.story) })
        let r = rotation

        func project(_ p: SIMD3<Float>) -> CGPoint {
            let x = Double(p.x), y = Double(p.z)
            return CGPoint(x: x * cos(-r) - y * sin(-r), y: x * sin(-r) + y * cos(-r))
        }
        func segment(_ s: FloorPlanData.Surface) -> Segment {
            let m = s.matrix
            let half = s.size.x / 2
            return Segment(start: project(m.transformPoint(SIMD3(-half, 0, 0))), end: project(m.transformPoint(SIMD3(half, 0, 0))))
        }

        for s in data.surfaces where include(s.story) {
            switch s.kind {
            case .wall: walls.append(segment(s))
            case .door: doors.append(Door(segment: segment(s), isOpen: s.isOpen ?? false))
            case .window: windows.append(segment(s))
            case .opening: openings.append(segment(s))
            case .floor:
                if let polygon = s.polygon, polygon.count >= 3 {
                    let m = s.matrix
                    floors.append(polygon.map { project(m.transformPoint(SIMD3($0[0], $0[1], $0.count > 2 ? $0[2] : 0))) })
                } else {
                    let m = s.matrix, w = s.size.x / 2, h = s.size.y / 2
                    floors.append([SIMD3(-w, -h, 0), SIMD3(w, -h, 0), SIMD3(w, h, 0), SIMD3(-w, h, 0)].map { project(m.transformPoint($0)) })
                }
            }
        }
        for o in data.objects where include(o.story) {
            let m = o.matrix, w = o.size.x / 2, d = o.size.z / 2
            let corners = [SIMD3(-w, 0, -d), SIMD3(w, 0, -d), SIMD3(w, 0, d), SIMD3(-w, 0, d)].map { project(m.transformPoint($0)) }
            objects.append(Footprint(category: o.category, corners: corners, center: project(m.translation)))
        }
        for section in data.sections where include(section.story) {
            let position = project(section.position)
            let area = floors.first { Self.contains($0, position) }.map { abs(Self.signedArea($0)) }
            labels.append(RoomLabel(name: FloorPlanData.displayName(forSection: section.label), position: position, area: area))
        }

        var box = CGRect.null
        for p in walls.flatMap({ [$0.start, $0.end] }) + floors.flatMap({ $0 }) + objects.flatMap(\.corners) {
            box = box.union(CGRect(origin: p, size: .zero))
        }
        bounds = box.isNull ? CGRect(x: -1, y: -1, width: 2, height: 2) : box
    }

    // MARK: Geometry helpers

    /// Length-weighted dominant wall direction modulo 90°.
    static func dominantAngle(of walls: [FloorPlanData.Surface]) -> Double {
        var sx = 0.0, sy = 0.0
        for wall in walls {
            let axis = wall.matrix.columns.0
            let angle = atan2(Double(axis.z), Double(axis.x))
            let weight = Double(wall.size.x)
            sx += cos(4 * angle) * weight
            sy += sin(4 * angle) * weight
        }
        guard sx != 0 || sy != 0 else { return 0 }
        return atan2(sy, sx) / 4
    }

    static func signedArea(_ polygon: [CGPoint]) -> Double {
        guard polygon.count >= 3 else { return 0 }
        var sum = 0.0
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    static func contains(_ polygon: [CGPoint], _ p: CGPoint) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard sorted.count >= 3 else { return sorted }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [CGPoint] = [], upper: [CGPoint] = []
        for p in sorted {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        for p in sorted.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }
}
