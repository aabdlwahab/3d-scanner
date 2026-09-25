import Foundation
import simd

struct ProcessingOptions: Codable, Equatable {
    var maxTexturePages = 2
    var texturePageSize = 4096
    var buildPointCloud = true
}

struct ProcessingProgress: Equatable {
    var fraction: Double
    var stage: String
}

struct ProcessingOutput {
    var vertexCount: Int
    var triangleCount: Int
    var textureCount: Int
    var keyframeCount: Int
    var pointCount: Int
    var surfaceArea: Double
    var bounds: SIMD3<Float>
    var texturedTriangleRatio: Double
}

enum ProcessingError: LocalizedError {
    case missingCapture
    case emptyMesh

    var errorDescription: String? {
        switch self {
        case .missingCapture: "The raw capture data for this scan is missing, so it can't be processed."
        case .emptyMesh: "No surfaces were captured. Scan again and move the phone slowly around the space."
        }
    }
}

/// Turns a raw LiDAR capture (ARKit mesh + keyframes) into a textured mesh and a point cloud.
/// Runs synchronously; call it from a background task.
final class ScanProcessor {
    private let files: ScanFiles
    private let options: ProcessingOptions

    init(files: ScanFiles, options: ProcessingOptions) {
        self.files = files
        self.options = options
    }

    func run(progress report: @escaping (ProcessingProgress) -> Void) throws -> ProcessingOutput {
        guard files.hasRawCapture else { throw ProcessingError.missingCapture }
        report(ProcessingProgress(fraction: 0.01, stage: "Loading capture"))
        let raw = try RawMesh.read(from: files.rawMesh)
        guard raw.triangleCount > 0 else { throw ProcessingError.emptyMesh }
        let frames = try ProcessingFrame.load(files: files)

        report(ProcessingProgress(fraction: 0.05, stage: "Cleaning up mesh"))
        let mesh = MeshCleaner.clean(raw)
        guard mesh.triangleCount > 0 else { throw ProcessingError.emptyMesh }
        let adjacency = MeshCleaner.edgeAdjacency(indices: mesh.indices)
        let faceNormals = MeshMath.faceNormalsAndAreas(positions: mesh.positions, indices: mesh.indices).normals

        report(ProcessingProgress(fraction: 0.10, stage: "Choosing the best photos"))
        let selector = ViewSelector(positions: mesh.positions, indices: mesh.indices, faceNormals: faceNormals, frames: frames)
        let selection = selector.select(adjacency: adjacency) { p in
            report(ProcessingProgress(fraction: 0.10 + 0.35 * p, stage: "Choosing the best photos"))
        }

        report(ProcessingProgress(fraction: 0.45, stage: "Baking textures"))
        try FileManager.default.createDirectory(at: files.modelDirectory, withIntermediateDirectories: true)
        removeOldTextures()
        var atlasOptions = TextureAtlasOptions()
        atlasOptions.pageSize = options.texturePageSize
        atlasOptions.maxPages = max(1, options.maxTexturePages)
        let builder = TextureAtlasBuilder(mesh: mesh, frames: frames, labels: selection.labels, options: atlasOptions)
        let textured = try builder.build(textureURL: files.texture) { p in
            report(ProcessingProgress(fraction: 0.45 + 0.4 * p, stage: "Baking textures"))
        }
        try textured.write(to: files.texturedMesh)

        let surfaceArea = MeshMath.surfaceArea(positions: mesh.positions, indices: mesh.indices)
        var pointCount = 0
        if options.buildPointCloud, !frames.isEmpty {
            report(ProcessingProgress(fraction: 0.86, stage: "Building point cloud"))
            let voxel = PointCloudBuilder.voxelSize(forSurfaceArea: surfaceArea)
            let cloud = PointCloudBuilder.build(frames: frames, voxelSize: voxel) { p in
                report(ProcessingProgress(fraction: 0.86 + 0.13 * p, stage: "Building point cloud"))
            }
            if cloud.count > 0 {
                try cloud.write(to: files.pointCloud)
                pointCount = cloud.count
            }
        }

        report(ProcessingProgress(fraction: 1, stage: "Done"))
        let labeled = selection.labeledCount
        return ProcessingOutput(vertexCount: textured.vertexCount,
                                triangleCount: textured.triangleCount,
                                textureCount: textured.textureCount,
                                keyframeCount: frames.count,
                                pointCount: pointCount,
                                surfaceArea: surfaceArea,
                                bounds: BoundingBox(points: mesh.positions).size,
                                texturedTriangleRatio: Double(labeled) / Double(max(1, mesh.triangleCount)))
    }

    private func removeOldTextures() {
        let fm = FileManager.default
        let existing = (try? fm.contentsOfDirectory(at: files.modelDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in existing where url.lastPathComponent.hasPrefix("texture_") {
            try? fm.removeItem(at: url)
        }
    }
}
