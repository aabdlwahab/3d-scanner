import Foundation
import simd

/// RoomPlan results in a simple Codable form (so the viewer, floor plan and exporters don't
/// depend on RoomPlan types, which only exist on devices).
struct FloorPlanData: Codable {
    enum SurfaceKind: String, Codable {
        case wall, door, window, opening, floor
    }

    struct Surface: Codable, Identifiable {
        var id: UUID
        var kind: SurfaceKind
        /// 16 floats, column-major. The surface lies in its local XY plane; local X runs along
        /// its width, local Y along its height.
        var transform: [Float]
        /// Width, height, depth in meters.
        var dimensions: [Float]
        /// Corners in the surface's local space (RoomPlan `polygonCorners`), when available.
        var polygon: [[Float]]?
        var isOpen: Bool?
        var parentID: UUID?
        var story: Int = 0

        var matrix: simd_float4x4 { simd_float4x4(columnMajor: transform) }
        var size: SIMD3<Float> { SIMD3(dimensions[0], dimensions[1], dimensions[2]) }
    }

    struct Object: Codable, Identifiable {
        var id: UUID
        /// RoomPlan object category, e.g. "bed", "sofa", "storage".
        var category: String
        var transform: [Float]
        var dimensions: [Float]
        var story: Int = 0

        var matrix: simd_float4x4 { simd_float4x4(columnMajor: transform) }
        var size: SIMD3<Float> { SIMD3(dimensions[0], dimensions[1], dimensions[2]) }
    }

    struct Section: Codable {
        /// RoomPlan section label, e.g. "bedroom", "kitchen".
        var label: String
        var center: [Float]
        var story: Int = 0

        var position: SIMD3<Float> { SIMD3(center[0], center[1], center[2]) }
    }

    var version = 1
    var surfaces: [Surface] = []
    var objects: [Object] = []
    var sections: [Section] = []
    var roomCount = 1

    var walls: [Surface] { surfaces.filter { $0.kind == .wall } }
    var doors: [Surface] { surfaces.filter { $0.kind == .door } }
    var windows: [Surface] { surfaces.filter { $0.kind == .window } }
    var openings: [Surface] { surfaces.filter { $0.kind == .opening } }
    var floors: [Surface] { surfaces.filter { $0.kind == .floor } }

    func write(to url: URL) throws {
        try JSONEncoder.scanSpace.encode(self).write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> FloorPlanData {
        try JSONDecoder.scanSpace.decode(FloorPlanData.self, from: Data(contentsOf: url))
    }
}

extension FloorPlanData {
    static func displayName(forCategory category: String) -> String {
        switch category {
        case "washerDryer": "Washer/Dryer"
        case "television": "TV"
        default: category.prefix(1).uppercased() + category.dropFirst()
        }
    }

    static func displayName(forSection label: String) -> String {
        switch label {
        case "livingRoom": "Living Room"
        case "diningRoom": "Dining Room"
        case "unidentified": "Room"
        default: label.prefix(1).uppercased() + label.dropFirst()
        }
    }

    /// sRGB display color for an object category.
    static func color(forCategory category: String) -> SIMD3<Float> {
        switch category {
        case "bed": SIMD3(0.52, 0.66, 0.95)
        case "sofa": SIMD3(0.64, 0.54, 0.90)
        case "chair": SIMD3(0.96, 0.66, 0.40)
        case "table": SIMD3(0.88, 0.62, 0.42)
        case "storage": SIMD3(0.70, 0.75, 0.82)
        case "refrigerator", "stove", "oven", "dishwasher", "washerDryer": SIMD3(0.82, 0.86, 0.90)
        case "sink", "toilet", "bathtub": SIMD3(0.70, 0.88, 0.96)
        case "television": SIMD3(0.28, 0.30, 0.36)
        case "fireplace": SIMD3(0.88, 0.46, 0.36)
        case "stairs": SIMD3(0.78, 0.72, 0.62)
        default: SIMD3(0.75, 0.75, 0.78)
        }
    }
}
