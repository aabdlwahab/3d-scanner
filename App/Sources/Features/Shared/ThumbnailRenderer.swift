import CoreImage
import SceneKit
import UIKit

/// Creates library thumbnails: a quick one from a keyframe right after capture, and a 3D render
/// of the finished model.
enum ThumbnailRenderer {
    static let size = CGSize(width: 480, height: 480)

    /// Rotated, center-cropped keyframe (ARKit images are in landscape sensor orientation).
    /// Safe to call from any thread.
    static func writeKeyframeThumbnail(files: ScanFiles, records: [KeyframeRecord]) {
        guard !records.isEmpty else { return }
        let record = records[records.count / 2]
        guard let image = ImageFiles.loadImage(files.frameFile(record.image), maxPixelSize: 720) else { return }
        let rotated = CIImage(cgImage: image).oriented(.right)
        let side = min(rotated.extent.width, rotated.extent.height)
        let crop = CGRect(x: rotated.extent.midX - side / 2, y: rotated.extent.midY - side / 2, width: side, height: side)
        let context = CIContext()
        guard let cropped = context.createCGImage(rotated.cropped(to: crop), from: crop) else { return }
        try? ImageFiles.writeJPEG(cropped, to: files.thumbnail, quality: 0.85)
    }

    /// Renders the processed model (LiDAR or room) with SceneKit in the background and updates the
    /// library. Call while the app is active (iOS doesn't allow GPU work in the background).
    @MainActor
    static func renderModelThumbnail(for id: UUID, store: ScanStore) {
        guard let scan = store.scan(id) else { return }
        let files = store.files(for: id)
        let kind = scan.kind
        Task.detached(priority: .utility) {
            guard let image = renderModel(kind: kind, files: files), let cgImage = image.cgImage else { return }
            try? ImageFiles.writeJPEG(cgImage, to: files.thumbnail, quality: 0.85)
            await MainActor.run { store.thumbnailDidChange(id) }
        }
    }

    static func renderModel(kind: ScanKind, files: ScanFiles) -> UIImage? {
        let root = SCNNode()
        let bounds: BoundingBox
        switch kind {
        case .lidar:
            guard let assets = try? TexturedMeshAssets(files: files) else { return nil }
            root.addChildNode(SCNNode(geometry: assets.geometry(for: .textured)))
            bounds = assets.bounds
        case .room:
            guard let data = try? FloorPlanData.read(from: files.floorPlan) else { return nil }
            let model = RoomSceneBuilder.makeModel(for: data)
            root.addChildNode(SceneKitExport.node(for: model))
            bounds = model.bounds
        }
        guard !bounds.isEmpty else { return nil }
        return render(root, bounds: bounds, lit: kind == .room)
    }

    static func render(_ node: SCNNode, bounds: BoundingBox, lit: Bool) -> UIImage? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let scene = SCNScene()
        scene.background.contents = UIColor(red: 0.08, green: 0.09, blue: 0.13, alpha: 1)
        scene.rootNode.addChildNode(node)
        if lit { ScanSceneBuilder.addStudioLights(to: scene.rootNode) }
        let camera = ScanSceneBuilder.makeCamera(framing: bounds)
        scene.rootNode.addChildNode(camera)
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        // Load textures before taking the snapshot.
        renderer.prepare(scene.rootNode, shouldAbortBlock: nil)
        return renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
    }
}

/// In-memory thumbnail cache keyed by file path + revision.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()

    func image(for url: URL, revision: Int) -> UIImage? {
        let key = "\(url.path)#\(revision)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

enum Haptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func impact() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}
