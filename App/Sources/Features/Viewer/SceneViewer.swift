import Observation
import SceneKit
import SwiftUI

/// What the viewer shows.
enum ViewerContent {
    /// Processed LiDAR scan (textured mesh; the point cloud is loaded on demand).
    case lidar(TexturedMeshAssets, ScanFiles)
    /// Raw ARKit mesh shown while a scan is still being processed.
    case preview(TexturedMeshAssets)
    /// RoomPlan apartment model.
    case room(FloorPlanData)
}

struct CameraCommand: Equatable {
    enum Kind { case reset, top }
    let kind: Kind
    let id = UUID()
}

/// Viewer UI state shared between SwiftUI controls and the SceneKit coordinator.
@MainActor
@Observable
final class ViewerState {
    var style: RenderStyle = .textured
    var isMeasuring = false {
        didSet { if !isMeasuring { measurePoints = [] } }
    }
    var measurePoints: [SIMD3<Float>] = []
    /// Screen position for the distance label (updated while the camera moves).
    var measureLabelPosition: CGPoint?
    /// 1 = show everything; lower values hide geometry above that fraction of the model height.
    var cutFraction: Double = 1
    var cameraCommand: CameraCommand?

    var measuredDistance: Float? {
        measurePoints.count == 2 ? simd_distance(measurePoints[0], measurePoints[1]) : nil
    }
}

struct SceneViewer: UIViewRepresentable {
    let content: ViewerContent
    let state: ViewerState
    var style: RenderStyle
    var cutFraction: Double
    var isMeasuring: Bool
    var measureCount: Int
    var cameraCommand: CameraCommand?

    func makeCoordinator() -> SceneViewerCoordinator {
        SceneViewerCoordinator(state: state)
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        context.coordinator.attach(to: view, content: content)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let coordinator = context.coordinator
        coordinator.apply(style: style)
        coordinator.apply(cutFraction: cutFraction)
        coordinator.apply(measuring: isMeasuring, pointCount: measureCount)
        if let cameraCommand { coordinator.perform(cameraCommand) }
    }
}

@MainActor
final class SceneViewerCoordinator: NSObject, SCNSceneRendererDelegate {
    private let state: ViewerState
    private weak var view: SCNView?
    private let scene = SCNScene()
    private let modelNode = SCNNode()
    private var pointsNode: SCNNode?
    private let measureNode = SCNNode()
    private let lightsNode = SCNNode()
    private let cameraNode: SCNNode
    private var content: ViewerContent?
    private var bounds = BoundingBox(min: SIMD3(-1, -1, -1), max: SIMD3(1, 1, 1))
    private var appliedStyle: RenderStyle?
    private var appliedCut: Double = 1
    private var appliedMeasureCount = -1
    private var lastCommandID: UUID?
    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))

    private static let modelCategory = 2
    private static let cutModifier = """
    #pragma arguments
    float clipHeight;
    #pragma body
    float4 worldPosition = scn_frame.inverseViewTransform * float4(_surface.position, 1.0);
    if (worldPosition.y > clipHeight) { discard_fragment(); }
    """

    init(state: ViewerState) {
        self.state = state
        cameraNode = ScanSceneBuilder.makeCamera(framing: BoundingBox(min: SIMD3(-1, -1, -1), max: SIMD3(1, 1, 1)))
        super.init()
    }

    func attach(to view: SCNView, content: ViewerContent) {
        self.view = view
        self.content = content
        view.scene = scene
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.rendersContinuously = false
        view.delegate = self
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        tap.isEnabled = false
        view.addGestureRecognizer(tap)

        modelNode.name = "model"
        scene.rootNode.addChildNode(modelNode)
        scene.rootNode.addChildNode(lightsNode)
        scene.rootNode.addChildNode(measureNode)
        ScanSceneBuilder.addStudioLights(to: lightsNode)

        switch content {
        case .lidar(let assets, _), .preview(let assets):
            bounds = assets.bounds
            modelNode.geometry = assets.geometry(for: .textured)
        case .room(let data):
            let model = RoomSceneBuilder.makeModel(for: data)
            bounds = model.bounds
            modelNode.addChildNode(SceneKitExport.node(for: model))
        }
        setCategory(modelNode, Self.modelCategory)

        cameraNode.camera?.zFar = Double(max(50, bounds.radius * 30))
        scene.rootNode.addChildNode(cameraNode)
        view.pointOfView = cameraNode
        frameModel(animated: false)
    }

    // MARK: - State sync

    func apply(style: RenderStyle) {
        guard style != appliedStyle, let content else { return }
        appliedStyle = style
        switch content {
        case .lidar(let assets, let files):
            if style == .points {
                modelNode.isHidden = true
                showPoints(files: files)
            } else {
                pointsNode?.isHidden = true
                modelNode.isHidden = false
                modelNode.geometry = assets.geometry(for: style)
            }
        case .preview(let assets):
            modelNode.geometry = assets.geometry(for: style == .wireframe ? .wireframe : (style == .shaded ? .shaded : .classes))
        case .room:
            break
        }
        applyCut()
        view?.setNeedsDisplay()
    }

    func apply(cutFraction: Double) {
        guard cutFraction != appliedCut else { return }
        appliedCut = cutFraction
        applyCut()
    }

    func apply(measuring: Bool, pointCount: Int) {
        tap.isEnabled = measuring
        guard pointCount != appliedMeasureCount else { return }
        appliedMeasureCount = pointCount
        rebuildMeasurement()
    }

    func perform(_ command: CameraCommand) {
        guard command.id != lastCommandID else { return }
        lastCommandID = command.id
        switch command.kind {
        case .reset: frameModel(animated: true)
        case .top: topView()
        }
    }

    // MARK: - Content helpers

    private func showPoints(files: ScanFiles) {
        if let pointsNode {
            pointsNode.isHidden = false
            return
        }
        guard files.hasPointCloud else { return }
        Task { [weak self] in
            let cloud = await Task.detached(priority: .userInitiated) { try? PointCloud.read(from: files.pointCloud) }.value
            guard let self, let cloud else { return }
            // Approximate point spacing from the model's surface and the number of points.
            let size = self.bounds.size
            let area = 2 * (size.x * size.y + size.x * size.z + size.y * size.z)
            let spacing = (area / Float(max(1, cloud.count))).squareRoot()
            let node = ScanSceneBuilder.pointCloudNode(cloud, pointSize: CGFloat(min(0.05, max(0.004, spacing * 1.5))))
            node.isHidden = self.appliedStyle != .points
            self.setCategory(node, Self.modelCategory)
            self.scene.rootNode.addChildNode(node)
            self.pointsNode = node
            self.applyCut()
            self.view?.setNeedsDisplay()
        }
    }

    private func applyCut() {
        let active = appliedCut < 0.999
        let height = bounds.min.y + Float(appliedCut) * (bounds.max.y - bounds.min.y)
        var materials: [SCNMaterial] = []
        modelNode.enumerateHierarchy { node, _ in materials += node.geometry?.materials ?? [] }
        pointsNode?.enumerateHierarchy { node, _ in materials += node.geometry?.materials ?? [] }
        for material in materials {
            if active {
                if material.shaderModifiers?[.fragment] == nil {
                    var modifiers = material.shaderModifiers ?? [:]
                    modifiers[.fragment] = Self.cutModifier
                    material.shaderModifiers = modifiers
                }
                material.setValue(NSNumber(value: height), forKey: "clipHeight")
            } else if material.shaderModifiers?[.fragment] != nil {
                var modifiers = material.shaderModifiers ?? [:]
                modifiers[.fragment] = nil
                material.shaderModifiers = modifiers.isEmpty ? nil : modifiers
            }
        }
        view?.setNeedsDisplay()
    }

    private func setCategory(_ node: SCNNode, _ mask: Int) {
        node.enumerateHierarchy { child, _ in child.categoryBitMask = mask }
    }

    // MARK: - Camera

    private func frameModel(animated: Bool) {
        // Camera control may have swapped in its own camera node; take ours back.
        view?.pointOfView = cameraNode
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.6 : 0
        ScanSceneBuilder.frame(cameraNode, on: bounds)
        SCNTransaction.commit()
        view?.defaultCameraController.target = SCNVector3(bounds.center)
        view?.setNeedsDisplay()
    }

    private func topView() {
        let center = bounds.center
        let radius = max(bounds.radius, 0.2)
        let distance = radius / tan(Float(27.5) * .pi / 180) * 1.1
        view?.pointOfView = cameraNode
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.6
        cameraNode.simdPosition = center + SIMD3(0, distance, 0.001)
        cameraNode.simdLook(at: center, up: SIMD3(0, 0, -1), localFront: SIMD3(0, 0, -1))
        SCNTransaction.commit()
        view?.defaultCameraController.target = SCNVector3(center)
        view?.setNeedsDisplay()
    }

    // MARK: - Measuring

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let view, state.isMeasuring else { return }
        let location = gesture.location(in: view)
        let hits = view.hitTest(location, options: [
            .searchMode: SCNHitTestSearchMode.closest.rawValue,
            .ignoreHiddenNodes: true,
            .categoryBitMask: Self.modelCategory,
        ])
        guard let hit = hits.first else { return }
        let point = hit.worldCoordinates.simd
        if state.measurePoints.count >= 2 { state.measurePoints = [] }
        state.measurePoints.append(point)
        Haptics.tap()
    }

    private func rebuildMeasurement() {
        measureNode.childNodes.forEach { $0.removeFromParentNode() }
        let points = state.measurePoints
        let radius = CGFloat(max(0.006, bounds.radius * 0.006))
        for point in points {
            let sphere = SCNSphere(radius: radius)
            sphere.materials = [Self.overlayMaterial(.white)]
            let node = SCNNode(geometry: sphere)
            node.simdPosition = point
            node.renderingOrder = 100
            measureNode.addChildNode(node)
        }
        if points.count == 2 {
            let length = simd_distance(points[0], points[1])
            let cylinder = SCNCylinder(radius: radius * 0.35, height: CGFloat(length))
            cylinder.materials = [Self.overlayMaterial(UIColor(Theme.accentSecondary))]
            let line = SCNNode(geometry: cylinder)
            line.simdPosition = (points[0] + points[1]) / 2
            let direction = simd_normalize(points[1] - points[0])
            line.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: direction)
            line.renderingOrder = 99
            measureNode.addChildNode(line)
        }
        updateLabelPosition()
        view?.setNeedsDisplay()
    }

    private static func overlayMaterial(_ color: UIColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        return material
    }

    private func updateLabelPosition() {
        guard let view, state.measurePoints.count == 2 else {
            if state.measureLabelPosition != nil { state.measureLabelPosition = nil }
            return
        }
        let mid = (state.measurePoints[0] + state.measurePoints[1]) / 2
        let projected = view.projectPoint(SCNVector3(mid))
        guard projected.z > 0, projected.z < 1 else {
            state.measureLabelPosition = nil
            return
        }
        state.measureLabelPosition = CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
    }

    nonisolated func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        Task { @MainActor [weak self] in self?.updateLabelPosition() }
    }
}
