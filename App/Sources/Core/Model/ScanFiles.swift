import Foundation

/// File layout of one scan folder (`Documents/Scans/<uuid>/`).
///
///     scan.json            metadata (``Scan``)
///     thumbnail.jpg
///     raw/mesh.bin         ARKit mesh in world space (``RawMesh``)
///     raw/frames.json      keyframe poses + intrinsics (``KeyframeIndex``)
///     raw/frames/*.jpg     keyframe camera images
///     raw/frames/*.depth   Float32 LiDAR depth maps, *.conf confidence maps
///     model/textured.bin   processed textured mesh (``TexturedMesh``)
///     model/texture_N.jpg  texture atlas pages
///     model/points.bin     colored point cloud (``PointCloud``)
///     room/Room.usdz       RoomPlan export
///     room/structure.json  RoomPlan `CapturedStructure` (Codable)
///     room/floorplan.json  ``FloorPlanData`` used by the viewer
///     exports/             files generated for sharing
struct ScanFiles {
    let root: URL

    var metadata: URL { root.appendingPathComponent("scan.json") }
    var thumbnail: URL { root.appendingPathComponent("thumbnail.jpg") }

    var rawDirectory: URL { root.appendingPathComponent("raw", isDirectory: true) }
    var framesDirectory: URL { rawDirectory.appendingPathComponent("frames", isDirectory: true) }
    var framesIndex: URL { rawDirectory.appendingPathComponent("frames.json") }
    var rawMesh: URL { rawDirectory.appendingPathComponent("mesh.bin") }

    var modelDirectory: URL { root.appendingPathComponent("model", isDirectory: true) }
    var texturedMesh: URL { modelDirectory.appendingPathComponent("textured.bin") }
    var pointCloud: URL { modelDirectory.appendingPathComponent("points.bin") }
    func texture(_ index: Int) -> URL { modelDirectory.appendingPathComponent("texture_\(index).jpg") }

    var roomDirectory: URL { root.appendingPathComponent("room", isDirectory: true) }
    var roomUSDZ: URL { roomDirectory.appendingPathComponent("Room.usdz") }
    var roomStructure: URL { roomDirectory.appendingPathComponent("structure.json") }
    var floorPlan: URL { roomDirectory.appendingPathComponent("floorplan.json") }

    var exportsDirectory: URL { root.appendingPathComponent("exports", isDirectory: true) }

    func frameFile(_ relativePath: String) -> URL { rawDirectory.appendingPathComponent(relativePath) }

    func textureURLs(count: Int) -> [URL] { (0..<count).map(texture) }

    var hasRawCapture: Bool { FileManager.default.fileExists(atPath: rawMesh.path) }
    var hasTexturedModel: Bool { FileManager.default.fileExists(atPath: texturedMesh.path) }
    var hasPointCloud: Bool { FileManager.default.fileExists(atPath: pointCloud.path) }

    func createDirectories() throws {
        let fm = FileManager.default
        for dir in [root, rawDirectory, framesDirectory, modelDirectory, roomDirectory, exportsDirectory] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Total bytes used by the scan folder.
    func diskUsage() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Bytes used by raw capture data (keyframes), which can be deleted after processing.
    func rawDataUsage() -> Int64 {
        ScanFiles(root: rawDirectory).diskUsage()
    }
}
