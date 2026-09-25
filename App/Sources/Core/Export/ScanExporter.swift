import Foundation
import SceneKit

enum ExportFormat: String, CaseIterable, Identifiable {
    case glb, usdz, obj, ply, pointCloud, stl, floorPlanPDF, floorPlanPNG, roomJSON, rawCapture

    var id: String { rawValue }

    var title: String {
        switch self {
        case .glb: "GLB"
        case .usdz: "USDZ"
        case .obj: "OBJ"
        case .ply: "PLY Mesh"
        case .pointCloud: "Point Cloud"
        case .stl: "STL"
        case .floorPlanPDF: "Floor Plan PDF"
        case .floorPlanPNG: "Floor Plan Image"
        case .roomJSON: "RoomPlan JSON"
        case .rawCapture: "Raw Capture"
        }
    }

    var detail: String {
        switch self {
        case .glb: "Textured glTF — Blender, web viewers, Sketchfab"
        case .usdz: "Apple AR Quick Look, Reality Composer, Keynote"
        case .obj: "OBJ + MTL + textures in a .zip — works everywhere"
        case .ply: "Vertex-colored mesh — MeshLab, CloudCompare"
        case .pointCloud: "Colored points (.ply) — CloudCompare, Potree"
        case .stl: "Geometry for 3D printing & CAD (mm, Z-up)"
        case .floorPlanPDF: "Dimensioned 2D plan, vector PDF"
        case .floorPlanPNG: "Dimensioned 2D plan, high-res PNG"
        case .roomJSON: "Walls, doors, windows & furniture data"
        case .rawCapture: "Photos, LiDAR depth & camera poses (.zip)"
        }
    }

    var systemImage: String {
        switch self {
        case .glb, .obj: "cube"
        case .usdz: "arkit"
        case .ply: "cube.transparent"
        case .pointCloud: "circle.grid.3x3.fill"
        case .stl: "printer"
        case .floorPlanPDF: "doc.richtext"
        case .floorPlanPNG: "photo"
        case .roomJSON: "curlybraces"
        case .rawCapture: "camera.aperture"
        }
    }

    static func formats(for kind: ScanKind) -> [ExportFormat] {
        switch kind {
        case .lidar: [.glb, .usdz, .obj, .ply, .pointCloud, .stl, .rawCapture]
        case .room: [.floorPlanPDF, .floorPlanPNG, .usdz, .glb, .obj, .stl, .roomJSON]
        }
    }
}

enum ExportError: LocalizedError {
    case notProcessed
    case missingData(String)
    case unsupported

    var errorDescription: String? {
        switch self {
        case .notProcessed: "Process the scan before exporting it."
        case .missingData(let what): "This scan has no \(what)."
        case .unsupported: "This format isn't available for this scan."
        }
    }
}

/// Produces shareable files for a scan. Runs synchronously; call from a background task.
struct ScanExporter {
    let scan: Scan
    let files: ScanFiles
    /// Where exported files are written (defaults to the scan's own `exports/` folder).
    var outputDirectory: URL?
    /// Draws the floor plan into a PDF or PNG (provided by the UI layer, which owns SwiftUI rendering).
    var floorPlanRenderer: ((FloorPlanData, ExportFormat, URL) throws -> Void)?

    func export(_ format: ExportFormat) throws -> URL {
        let fm = FileManager.default
        let dir = outputDirectory ?? files.exportsDirectory
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = Self.fileName(for: scan.name)

        switch (scan.kind, format) {
        case (.lidar, .glb):
            let url = dir.appendingPathComponent("\(base).glb")
            try GLBWriter.write(try lidarModel(), to: url)
            return url
        case (.lidar, .usdz):
            let url = dir.appendingPathComponent("\(base).usdz")
            try SceneKitExport.writeUSDZ(try lidarModel(), to: url)
            return url
        case (.lidar, .obj), (.room, .obj):
            let model = scan.kind == .lidar ? try lidarModel() : try roomModel()
            let staging = dir.appendingPathComponent("obj", isDirectory: true)
            try? fm.removeItem(at: staging)
            let written = try OBJWriter.write(model, to: staging, baseName: base)
            let url = dir.appendingPathComponent("\(base)-obj.zip")
            try ZipWriter.write(written.map { ZipWriter.Entry(name: $0.lastPathComponent, source: $0) }, to: url)
            try? fm.removeItem(at: staging)
            return url
        case (.lidar, .ply):
            let mesh = try texturedMesh()
            let url = dir.appendingPathComponent("\(base)-mesh.ply")
            try PLYWriter.writeMesh(positions: mesh.positions, normals: mesh.normals, colors: mesh.colors,
                                    indices: mesh.groups.flatMap(\.indices), to: url)
            return url
        case (.lidar, .pointCloud):
            guard files.hasPointCloud else { throw ExportError.missingData("point cloud") }
            let url = dir.appendingPathComponent("\(base)-points.ply")
            try PLYWriter.writePoints(try PointCloud.read(from: files.pointCloud), to: url)
            return url
        case (.lidar, .stl), (.room, .stl):
            let url = dir.appendingPathComponent("\(base).stl")
            try STLWriter.write(scan.kind == .lidar ? try lidarModel() : try roomModel(), to: url)
            return url
        case (.lidar, .rawCapture):
            guard files.hasRawCapture else { throw ExportError.missingData("raw capture data") }
            return try zipRawCapture(to: dir.appendingPathComponent("\(base)-raw.zip"))
        case (.room, .glb):
            let url = dir.appendingPathComponent("\(base).glb")
            try GLBWriter.write(try roomModel(), to: url)
            return url
        case (.room, .usdz):
            let url = dir.appendingPathComponent("\(base).usdz")
            try? fm.removeItem(at: url)
            if fm.fileExists(atPath: files.roomUSDZ.path) {
                try fm.copyItem(at: files.roomUSDZ, to: url)
            } else {
                let scene = SCNScene()
                scene.rootNode.addChildNode(RoomSceneBuilder.makeNode(for: try floorPlan()))
                try SceneKitExport.writeUSDZ(scene, to: url)
            }
            return url
        case (.room, .roomJSON):
            let url = dir.appendingPathComponent("\(base).json")
            try? fm.removeItem(at: url)
            try fm.copyItem(at: fm.fileExists(atPath: files.roomStructure.path) ? files.roomStructure : files.floorPlan, to: url)
            return url
        case (.room, .floorPlanPDF), (.room, .floorPlanPNG):
            guard let floorPlanRenderer else { throw ExportError.unsupported }
            let url = dir.appendingPathComponent("\(base)-floor-plan.\(format == .floorPlanPDF ? "pdf" : "png")")
            try floorPlanRenderer(try floorPlan(), format, url)
            return url
        default:
            throw ExportError.unsupported
        }
    }

    // MARK: Sources

    func texturedMesh() throws -> TexturedMesh {
        guard files.hasTexturedModel else { throw ExportError.notProcessed }
        return try TexturedMesh.read(from: files.texturedMesh)
    }

    func lidarModel() throws -> ExportModel {
        let mesh = try texturedMesh()
        return ExportModel(textured: mesh, textureURLs: files.textureURLs(count: mesh.textureCount), name: Self.fileName(for: scan.name))
    }

    func floorPlan() throws -> FloorPlanData {
        guard FileManager.default.fileExists(atPath: files.floorPlan.path) else { throw ExportError.missingData("floor plan") }
        return try FloorPlanData.read(from: files.floorPlan)
    }

    func roomModel() throws -> ExportModel {
        RoomSceneBuilder.makeModel(for: try floorPlan())
    }

    private func zipRawCapture(to url: URL) throws -> URL {
        let fm = FileManager.default
        var entries: [ZipWriter.Entry] = []
        let readme = FileManager.default.temporaryDirectory.appendingPathComponent("ScanSpace-raw-README.txt")
        try Self.rawReadme.write(to: readme, atomically: true, encoding: .utf8)
        entries.append(ZipWriter.Entry(name: "README.txt", source: readme))
        if let enumerator = fm.enumerator(at: files.rawDirectory, includingPropertiesForKeys: [.isRegularFileKey]) {
            let prefix = files.rawDirectory.standardizedFileURL.path + "/"
            for case let file as URL in enumerator where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                let relative = file.standardizedFileURL.path.replacingOccurrences(of: prefix, with: "")
                entries.append(ZipWriter.Entry(name: relative, source: file))
            }
        }
        try ZipWriter.write(entries, to: url)
        try? fm.removeItem(at: readme)
        return url
    }

    static func fileName(for name: String) -> String {
        let allowed = name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
        let collapsed = String(allowed).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return collapsed.isEmpty ? "scan" : String(collapsed.prefix(60))
    }

    static let rawReadme = """
    ScanSpace raw LiDAR capture
    ===========================

    mesh.bin      ARKit scene-reconstruction mesh in world space (meters, +Y up).
                  Little-endian: "SSRM", u32 version, u32 vertexCount, u32 triangleCount, u32 flags,
                  float32[3*vertexCount] positions, [float32[3*vertexCount] normals if flags&1],
                  u32[3*triangleCount] indices, [u8[triangleCount] ARMeshClassification if flags&2].
    frames.json   One record per keyframe:
                  image        JPEG, sensor landscape orientation
                  depth        Float32 depth map in meters (row-major, depthWidth x depthHeight)
                  confidence   UInt8 ARKit confidence map (0 low, 1 medium, 2 high)
                  intrinsics   [fx, fy, cx, cy] in image pixels
                  transform    camera-to-world 4x4, column-major, ARKit convention
                               (camera looks down -Z, +Y up, +X right in image space)
    """
}
