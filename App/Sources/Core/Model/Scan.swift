import Foundation

/// The kind of capture a scan was made with.
enum ScanKind: String, Codable, CaseIterable, Identifiable {
    /// ARKit LiDAR mesh + camera keyframes, processed into a textured mesh.
    case lidar
    /// RoomPlan capture of one or more rooms, merged into an apartment structure.
    case room

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lidar: "LiDAR Mesh"
        case .room: "Room Plan"
        }
    }

    var systemImage: String {
        switch self {
        case .lidar: "cube.transparent"
        case .room: "square.split.bottomrightquarter"
        }
    }

    var defaultNamePrefix: String {
        switch self {
        case .lidar: "Scan"
        case .room: "Apartment"
        }
    }
}

enum ScanStatus: String, Codable {
    /// Raw capture saved; the texturing pipeline has not run yet (or was interrupted).
    case needsProcessing
    case processing
    case ready
    case failed
}

struct ScanStats: Codable, Hashable {
    var vertexCount = 0
    var triangleCount = 0
    var keyframeCount = 0
    var textureCount = 0
    var pointCount = 0
    /// Total mesh surface area in m².
    var surfaceArea: Double = 0
    /// Floor area in m² (room scans).
    var floorArea: Double?
    /// Bounding box size (width, height, depth) in meters.
    var bounds: [Double]?
    var roomCount: Int?
    var wallCount: Int?
    var doorCount: Int?
    var windowCount: Int?
    var objectCount: Int?
    /// Seconds spent capturing.
    var captureDuration: Double = 0
}

struct Scan: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var kind: ScanKind
    var createdAt: Date
    var updatedAt: Date
    var status: ScanStatus
    var stats = ScanStats()
    var failureReason: String?

    init(id: UUID = UUID(), name: String, kind: ScanKind, createdAt: Date = Date(), status: ScanStatus) {
        self.id = id
        self.name = name
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.status = status
    }

    static func defaultName(for kind: ScanKind, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return "\(kind.defaultNamePrefix) \(formatter.string(from: date))"
    }
}

extension JSONEncoder {
    static var scanSpace: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var scanSpace: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
