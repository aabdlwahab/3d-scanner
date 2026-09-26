import AppKit
import SceneKit
import SwiftUI

/// SceneKit view with Studio's mouse tools: orbit (SceneKit camera control), click-to-measure
/// and drag-to-select.
final class StudioSceneView: SCNView {
    var tool: ViewportTool = .orbit {
        didSet { allowsCameraControl = tool != .select }
    }
    var onClick: ((CGPoint) -> Void)?
    var onSelect: ((CGRect) -> Void)?
    var onDelete: (() -> Void)?
    var onEscape: (() -> Void)?

    private var mouseDownPoint: CGPoint?
    private var selectionStart: CGPoint?
    private let selectionOverlay = SelectionOverlay()

    override init(frame: NSRect, options: [String: Any]? = nil) {
        super.init(frame: frame, options: options)
        selectionOverlay.frame = bounds
        selectionOverlay.autoresizingMask = [.width, .height]
        addSubview(selectionOverlay)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        mouseDownPoint = point
        if tool == .select {
            selectionStart = point
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if tool == .select, let start = selectionStart {
            selectionOverlay.rect = rect(start, convert(event.locationInWindow, from: nil))
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if tool == .select, let start = selectionStart {
            selectionStart = nil
            selectionOverlay.rect = nil
            let selection = rect(start, point)
            if selection.width > 3, selection.height > 3 { onSelect?(selection) }
            return
        }
        super.mouseUp(with: event)
        if tool == .measure, let down = mouseDownPoint, hypot(point.x - down.x, point.y - down.y) < 4 {
            onClick?(point)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: onDelete?()        // delete, forward delete
        case 53: onEscape?()             // escape
        default: super.keyDown(with: event)
        }
    }

    private func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

/// Draws the rubber-band selection rectangle.
private final class SelectionOverlay: NSView {
    var rect: CGRect? {
        didSet { needsDisplay = true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let rect else { return }
        NSColor.systemRed.withAlphaComponent(0.12).setFill()
        rect.fill()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1.5
        path.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.systemRed.setStroke()
        path.stroke()
    }
}

struct Viewport: NSViewRepresentable {
    let session: ProjectSession
    // Observed values passed in so SwiftUI updates the view when they change.
    var geometryRevision: Int
    var planRevision: Int
    var style: StudioStyle
    var tool: ViewportTool
    var cutFraction: Double
    var showCropBox: Bool
    var cropMin: SIMD3<Float>
    var cropMax: SIMD3<Float>
    var selectionID: Int
    var measureCount: Int
    var cameraCommand: CameraCommand?

    func makeCoordinator() -> ViewportCoordinator {
        ViewportCoordinator(session: session)
    }

    func makeNSView(context: Context) -> StudioSceneView {
        let view = StudioSceneView(frame: .zero, options: nil)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: StudioSceneView, context: Context) {
        context.coordinator.sync()
    }
}

@MainActor
final class ViewportCoordinator: NSObject, SCNSceneRendererDelegate {
    private let session: ProjectSession
    private weak var view: StudioSceneView?
    private let scene = SCNScene()
    private let content = SCNNode()
    private let meshNode = SCNNode()
    private let pointsNode = SCNNode()
    private let planNode = SCNNode()
    private let cropNode = SCNNode()
    private let selectionNode = SCNNode()
    private let measureNode = SCNNode()
    private let cameraNode: SCNNode
    private var assets: TexturedMeshAssets?
    private var appliedGeometry = -1
    private var appliedPlan = -1
    private var appliedStyle: StudioStyle?
    private var appliedCut: Double = 1
    private var appliedSelection: [SIMD4<Float>]?
    private var appliedMeasure = -1
    private var lastCommand: UUID?
    private var framed = false

    private static let pickable = 2
    private static let cutModifier = """
    #pragma arguments
    float clipHeight;
    #pragma body
    float4 worldPosition = scn_frame.inverseViewTransform * float4(_surface.position, 1.0);
    if (worldPosition.y > clipHeight) { discard_fragment(); }
    """
    /// The height cut plus back-face culling for points (view space: the camera is at the origin).
    private static let pointsModifier = """
    #pragma arguments
    float clipHeight;
    #pragma body
    float4 worldPosition = scn_frame.inverseViewTransform * float4(_surface.position, 1.0);
    if (worldPosition.y > clipHeight || dot(_surface.normal, _surface.position) > 0.0) { discard_fragment(); }
    """

    init(session: ProjectSession) {
        self.session = session
        cameraNode = ScanSceneBuilder.makeCamera(framing: BoundingBox(min: SIMD3(-1, -1, -1), max: SIMD3(1, 1, 1)))
        super.init()
    }

    func attach(to view: StudioSceneView) {
        self.view = view
        view.scene = scene
        view.delegate = self
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.rendersContinuously = false
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        view.backgroundColor = .clear
        scene.background.contents = Self.backgroundImage()
        for node in [meshNode, pointsNode, planNode] {
            node.categoryBitMask = Self.pickable
            content.addChildNode(node)
        }
        scene.rootNode.addChildNode(content)
        scene.rootNode.addChildNode(cropNode)
        scene.rootNode.addChildNode(selectionNode)
        scene.rootNode.addChildNode(measureNode)
        ScanSceneBuilder.addStudioLights(to: scene.rootNode)
        scene.rootNode.addChildNode(cameraNode)
        view.pointOfView = cameraNode

        view.onClick = { [weak self] point in self?.measure(at: point) }
        view.onSelect = { [weak self] rect in self?.select(rect) }
        view.onDelete = { [weak self] in
            guard let self, self.session.pendingSelection != nil else { return }
            Task { await self.session.deleteSelection() }
        }
        view.onEscape = { [weak self] in
            self?.session.pendingSelection = nil
            self?.session.measurePoints = []
        }
        sync()
    }

    // MARK: - Sync with the session

    func sync() {
        guard let view else { return }
        view.tool = session.tool
        if appliedGeometry != session.geometryRevision {
            appliedGeometry = session.geometryRevision
            rebuildGeometry()
        }
        if appliedPlan != session.planRevision {
            appliedPlan = session.planRevision
            planNode.childNodes.forEach { $0.removeFromParentNode() }
            if let plan = session.floorPlan {
                let node = RoomSceneBuilder.makeNode(for: plan)
                node.enumerateHierarchy { child, _ in child.categoryBitMask = Self.pickable }
                planNode.addChildNode(node)
            }
            appliedStyle = nil
        }
        if appliedStyle != session.style {
            appliedStyle = session.style
            applyStyle()
        }
        if appliedCut != session.cutFraction {
            appliedCut = session.cutFraction
            applyCut()
        }
        updateCropBox()
        if appliedSelection != session.pendingSelection {
            appliedSelection = session.pendingSelection
            updateSelection()
        }
        if appliedMeasure != session.measurePoints.count {
            appliedMeasure = session.measurePoints.count
            updateMeasurement()
        }
        if let command = session.cameraCommand, command.id != lastCommand {
            lastCommand = command.id
            perform(command.kind)
        }
        if !framed, !session.isLoading {
            framed = true
            perform(.reset, animated: false)
        }
        view.setNeedsDisplay(view.bounds)
    }

    private func rebuildGeometry() {
        if let mesh = session.mesh, mesh.triangleCount > 0 {
            assets = TexturedMeshAssets(mesh: mesh, textureURLs: session.files.textureURLs(count: mesh.textureCount))
        } else {
            assets = nil
        }
        pointsNode.childNodes.forEach { $0.removeFromParentNode() }
        if let cloud = session.cloud, cloud.count > 0 {
            let box = BoundingBox(points: cloud.positions)
            let size = box.size
            let area = 2 * (size.x * size.y + size.x * size.z + size.y * size.z)
            let spacing = (area / Float(max(1, cloud.count))).squareRoot()
            let node = ScanSceneBuilder.pointCloudNode(cloud, pointSize: CGFloat(min(0.05, max(0.004, spacing * 1.6))),
                                                       normals: session.cloudNormals)
            node.categoryBitMask = Self.pickable
            pointsNode.addChildNode(node)
        }
        appliedStyle = nil
        appliedSelection = nil
        if framed { applyStyle() }
    }

    private func applyStyle() {
        let style = session.style
        meshNode.isHidden = true
        pointsNode.isHidden = true
        planNode.isHidden = true
        switch style {
        case .points:
            pointsNode.isHidden = false
        case .plan:
            planNode.isHidden = false
        default:
            if let assets, let renderStyle = style.renderStyle {
                meshNode.geometry = assets.geometry(for: renderStyle)
                meshNode.isHidden = false
            } else if session.cloud != nil {
                pointsNode.isHidden = false
            }
        }
        applyCut()
    }

    private func applyCut() {
        let box = session.bounds
        let active = session.cutFraction < 0.999
        let height = active ? box.min.y + Float(session.cutFraction) * (box.max.y - box.min.y) : 1e9
        content.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry else { return }
            // Points with normals always hide the ones facing away, like the mesh's back faces.
            let orientedPoints = node.name == "points" && !geometry.sources(for: .normal).isEmpty
            let modifier = orientedPoints ? Self.pointsModifier : active ? Self.cutModifier : nil
            for material in geometry.materials {
                if material.shaderModifiers?[.fragment] != modifier {
                    var modifiers = material.shaderModifiers ?? [:]
                    modifiers[.fragment] = modifier
                    material.shaderModifiers = modifiers.isEmpty ? nil : modifiers
                }
                if modifier != nil { material.setValue(NSNumber(value: height), forKey: "clipHeight") }
            }
        }
    }

    // MARK: - Overlays

    private func updateCropBox() {
        cropNode.childNodes.forEach { $0.removeFromParentNode() }
        guard session.showCropBox else { return }
        let lo = simd_min(session.cropMin, session.cropMax), hi = simd_max(session.cropMin, session.cropMax)
        let size = hi - lo
        let box = SCNBox(width: CGFloat(size.x), height: CGFloat(size.y), length: CGFloat(size.z), chamferRadius: 0)
        let fill = SCNMaterial()
        fill.lightingModel = .constant
        fill.diffuse.contents = NSColor.systemYellow.withAlphaComponent(0.12)
        fill.isDoubleSided = true
        fill.writesToDepthBuffer = false
        let edges = SCNMaterial()
        edges.lightingModel = .constant
        edges.fillMode = .lines
        edges.diffuse.contents = NSColor.systemYellow
        edges.readsFromDepthBuffer = false
        box.materials = [fill]
        let fillNode = SCNNode(geometry: box)
        let edgeBox = box.copy() as! SCNBox
        edgeBox.materials = [edges]
        let edgeNode = SCNNode(geometry: edgeBox)
        for node in [fillNode, edgeNode] {
            node.simdPosition = (lo + hi) / 2
            node.renderingOrder = 50
            cropNode.addChildNode(node)
        }
    }

    private func updateSelection() {
        selectionNode.childNodes.forEach { $0.removeFromParentNode() }
        guard let planes = session.pendingSelection else {
            session.selectionCount = 0
            return
        }
        var positions: [SIMD3<Float>] = []
        var count = 0
        if let mesh = session.mesh, session.style != .points {
            for group in mesh.groups {
                var i = 0
                while i + 2 < group.indices.count {
                    let a = mesh.positions[Int(group.indices[i])], b = mesh.positions[Int(group.indices[i + 1])]
                    let c = mesh.positions[Int(group.indices[i + 2])]
                    if MeshEditor.inside((a + b + c) / 3, planes) {
                        positions += [a, b, c]
                        count += 1
                    }
                    i += 3
                }
            }
        }
        var pointPositions: [SIMD3<Float>] = []
        if let cloud = session.cloud, session.style == .points || session.mesh == nil {
            pointPositions = cloud.positions.filter { MeshEditor.inside($0, planes) }
            count += pointPositions.count
        }
        session.selectionCount = count
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.systemRed.withAlphaComponent(0.55)
        material.isDoubleSided = true
        material.readsFromDepthBuffer = false
        if !positions.isEmpty {
            let source = TexturedMeshAssets.vectorSource(positions, semantic: .vertex)
            let indices = (0..<UInt32(positions.count)).map { $0 }
            let element = indices.withUnsafeBytes {
                SCNGeometryElement(data: Data($0), primitiveType: .triangles, primitiveCount: positions.count / 3, bytesPerIndex: 4)
            }
            let geometry = SCNGeometry(sources: [source], elements: [element])
            geometry.materials = [material]
            let node = SCNNode(geometry: geometry)
            node.renderingOrder = 60
            selectionNode.addChildNode(node)
        }
        if !pointPositions.isEmpty {
            let cloud = PointCloud(positions: pointPositions, colors: [SIMD4<UInt8>](repeating: SIMD4(255, 60, 60, 255), count: pointPositions.count))
            let node = ScanSceneBuilder.pointCloudNode(cloud, pointSize: 0.015)
            node.geometry?.materials.first?.readsFromDepthBuffer = false
            node.renderingOrder = 60
            selectionNode.addChildNode(node)
        }
    }

    private func updateMeasurement() {
        measureNode.childNodes.forEach { $0.removeFromParentNode() }
        let points = session.measurePoints
        let radius = CGFloat(max(0.008, session.bounds.radius * 0.006))
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.white
        material.readsFromDepthBuffer = false
        for point in points {
            let sphere = SCNSphere(radius: radius)
            sphere.materials = [material]
            let node = SCNNode(geometry: sphere)
            node.simdPosition = point
            node.renderingOrder = 100
            measureNode.addChildNode(node)
        }
        if points.count == 2 {
            let cylinder = SCNCylinder(radius: radius * 0.35, height: CGFloat(simd_distance(points[0], points[1])))
            let line = SCNMaterial()
            line.lightingModel = .constant
            line.diffuse.contents = NSColor(red: 0.24, green: 0.84, blue: 0.96, alpha: 1)
            line.readsFromDepthBuffer = false
            cylinder.materials = [line]
            let node = SCNNode(geometry: cylinder)
            node.simdPosition = (points[0] + points[1]) / 2
            node.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: simd_normalize(points[1] - points[0]))
            node.renderingOrder = 99
            measureNode.addChildNode(node)
        }
        updateLabel()
    }

    // MARK: - Tools

    private func measure(at point: CGPoint) {
        guard let view else { return }
        let hits = view.hitTest(point, options: [
            .searchMode: SCNHitTestSearchMode.closest.rawValue,
            .ignoreHiddenNodes: true,
            .categoryBitMask: Self.pickable,
        ])
        guard let hit = hits.first else { return }
        if session.measurePoints.count >= 2 { session.measurePoints = [] }
        session.measurePoints.append(hit.worldCoordinates.simd)
    }

    private func select(_ rect: CGRect) {
        guard let view else { return }
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        let near = corners.map { view.unprojectPoint(SCNVector3(Float($0.x), Float($0.y), 0)).simd }
        let far = corners.map { view.unprojectPoint(SCNVector3(Float($0.x), Float($0.y), 1)).simd }
        session.pendingSelection = MeshEditor.frustumPlanes(near: near, far: far)
    }

    // MARK: - Camera

    private func perform(_ kind: CameraCommand.Kind, animated: Bool = true) {
        let box = session.bounds
        view?.pointOfView = cameraNode
        cameraNode.camera?.zFar = Double(max(50, box.radius * 30))
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.5 : 0
        switch kind {
        case .reset:
            ScanSceneBuilder.frame(cameraNode, on: box)
        case .top:
            let distance = max(box.radius, 0.2) / tan(Float(27.5) * .pi / 180) * 1.1
            cameraNode.simdPosition = box.center + SIMD3(0, distance, 0.001)
            cameraNode.simdLook(at: box.center, up: SIMD3(0, 0, -1), localFront: SIMD3(0, 0, -1))
        case .front:
            ScanSceneBuilder.frame(cameraNode, on: box, direction: SIMD3(0, 0.25, 1))
        }
        SCNTransaction.commit()
        view?.defaultCameraController.target = SCNVector3(box.center)
    }

    private func updateLabel() {
        guard let view, session.measurePoints.count == 2 else {
            if session.measureLabelPosition != nil { session.measureLabelPosition = nil }
            return
        }
        let mid = (session.measurePoints[0] + session.measurePoints[1]) / 2
        let projected = view.projectPoint(SCNVector3(mid))
        // AppKit's origin is bottom-left; SwiftUI overlays use top-left.
        let position = CGPoint(x: CGFloat(projected.x), y: view.bounds.height - CGFloat(projected.y))
        if session.measureLabelPosition != position { session.measureLabelPosition = position }
    }

    nonisolated func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        Task { @MainActor [weak self] in self?.updateLabel() }
    }

    private static func backgroundImage() -> NSImage {
        let size = NSSize(width: 64, height: 512)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(colors: [NSColor(red: 0.15, green: 0.16, blue: 0.22, alpha: 1), NSColor(red: 0.05, green: 0.055, blue: 0.08, alpha: 1)])?
            .draw(in: NSRect(origin: .zero, size: size), angle: -90)
        image.unlockFocus()
        return image
    }
}
