import AppKit
import Foundation
import Observation
import SceneKit
import UniformTypeIdentifiers

enum EditorMode: String, CaseIterable, Identifiable {
    case model, plan

    var id: String { rawValue }
    var title: String { self == .model ? "3D Model" : "Floor Plan" }
}

enum ViewportTool: String, CaseIterable, Identifiable {
    case orbit, measure, select

    var id: String { rawValue }

    var title: String {
        switch self {
        case .orbit: "Orbit"
        case .measure: "Measure"
        case .select: "Select"
        }
    }

    var systemImage: String {
        switch self {
        case .orbit: "rotate.3d"
        case .measure: "ruler"
        case .select: "rectangle.dashed"
        }
    }
}

enum StudioStyle: String, CaseIterable, Identifiable {
    case textured, solid, wire, labels, points, plan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .textured: "Texture"
        case .solid: "Solid"
        case .wire: "Wireframe"
        case .labels: "Surface Labels"
        case .points: "Point Cloud"
        case .plan: "Model from Plan"
        }
    }

    var systemImage: String {
        switch self {
        case .textured: "photo"
        case .solid: "cube.fill"
        case .wire: "square.grid.3x3"
        case .labels: "tag"
        case .points: "circle.grid.3x3.fill"
        case .plan: "house"
        }
    }

    var renderStyle: RenderStyle? {
        switch self {
        case .textured: .textured
        case .solid: .shaded
        case .wire: .wireframe
        case .labels: .classes
        case .points: .points
        case .plan: nil
        }
    }
}

enum StudioTextureQuality: String, CaseIterable, Identifiable {
    case standard, high, ultra, maximum

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "Standard — 2 × 4K"
        case .high: "High — 4 × 4K"
        case .ultra: "Ultra — 2 × 8K"
        case .maximum: "Maximum — 4 × 8K"
        }
    }

    var pages: Int { self == .standard || self == .ultra ? 2 : 4 }
    var pageSize: Int { self == .ultra || self == .maximum ? 8192 : 4096 }
}

/// What Studio can export from a project.
enum StudioExport: String, CaseIterable, Identifiable {
    case glb, usdz, obj, ply, stl, pointCloud, planPDF, planPNG, planSVG, planDXF, planGLB, planUSDZ

    var id: String { rawValue }

    var title: String {
        switch self {
        case .glb: "GLB (glTF)"
        case .usdz: "USDZ"
        case .obj: "OBJ + Textures (.zip)"
        case .ply: "PLY Mesh"
        case .stl: "STL (mm, Z-up)"
        case .pointCloud: "Point Cloud (.ply)"
        case .planPDF: "Floor Plan PDF"
        case .planPNG: "Floor Plan PNG"
        case .planSVG: "Floor Plan SVG"
        case .planDXF: "Floor Plan DXF (CAD)"
        case .planGLB: "3D Model from Plan (GLB)"
        case .planUSDZ: "3D Model from Plan (USDZ)"
        }
    }

    var fileExtension: String {
        switch self {
        case .glb, .planGLB: "glb"
        case .usdz, .planUSDZ: "usdz"
        case .obj: "zip"
        case .ply, .pointCloud: "ply"
        case .stl: "stl"
        case .planPDF: "pdf"
        case .planPNG: "png"
        case .planSVG: "svg"
        case .planDXF: "dxf"
        }
    }

    var isPlanExport: Bool { rawValue.hasPrefix("plan") }
}

/// A saved blueprint (floor plan extracted from the scan).
struct StoredBlueprint: Codable {
    struct Room: Codable {
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
    var createdAt = Date()

    var floorArea: Double { rooms.reduce(0) { $0 + $1.area } }
}

/// The open project: original data, the edit stack and derived working data, plus tool state.
@MainActor
@Observable
final class ProjectSession {
    let id: UUID
    let files: ScanFiles
    var scan: Scan
    @ObservationIgnored private weak var library: ProjectLibrary?

    // Data
    private(set) var isLoading = true
    @ObservationIgnored private var baseMesh: TexturedMesh?
    @ObservationIgnored private var baseCloud: PointCloud?
    private(set) var isPreviewMesh = false
    private(set) var mesh: TexturedMesh?
    private(set) var cloud: PointCloud?
    /// One normal per cloud point, borrowed from the mesh, so the viewer can hide points facing
    /// away from the camera (the way the mesh hides back faces, e.g. the ceiling seen from above).
    private(set) var cloudNormals: [SIMD3<Float>]?
    private(set) var roomPlan: FloorPlanData?
    private(set) var blueprint: StoredBlueprint?
    private(set) var blueprintIsStale = false
    private(set) var edits: [EditOperation] = []
    private(set) var redoStack: [EditOperation] = []
    private(set) var geometryRevision = 0
    private(set) var planRevision = 0

    // Viewer and tools
    var mode: EditorMode = .model
    var inspectorTab: InspectorTab = .info
    var style: StudioStyle = .textured
    var tool: ViewportTool = .orbit {
        didSet {
            if tool != .measure { measurePoints = [] }
            if tool != .select { pendingSelection = nil }
        }
    }
    var cutFraction: Double = 1
    var cameraCommand: CameraCommand?
    var measurePoints: [SIMD3<Float>] = []
    var measureLabelPosition: CGPoint?
    var pendingSelection: [SIMD4<Float>]?
    var selectionCount = 0
    var showCropBox = false
    var cropMin = SIMD3<Float>(repeating: -1)
    var cropMax = SIMD3<Float>(repeating: 1)
    var blueprintOptions = BlueprintOptions()
    /// Look of the 3D model built from the floor plan: a furnishing style id, or "simple" for blocks.
    var planLook: String = UserDefaults.standard.string(forKey: "planLook") ?? FurnishingStyle.scandinavian.id {
        didSet {
            UserDefaults.standard.set(planLook, forKey: "planLook")
            planRevision += 1
        }
    }
    var textureQuality: StudioTextureQuality = .high
    var buildPointCloud = true

    // Status
    private(set) var busy: LibraryJob?
    var errorMessage: String?

    init(scan: Scan, files: ScanFiles, library: ProjectLibrary) {
        id = scan.id
        self.scan = scan
        self.files = files
        self.library = library
    }

    private var editsURL: URL { files.root.appendingPathComponent("edits.json") }
    private var blueprintURL: URL { files.root.appendingPathComponent("blueprint.json") }

    var isBusy: Bool { busy != nil }

    /// The 3D model built from a floor plan in the chosen look.
    nonisolated static func planModel(for plan: FloorPlanData, look: String) -> ExportModel {
        if let style = FurnishingStyle.all.first(where: { $0.id == look }) {
            return FurnishedModelBuilder.makeModel(for: plan, style: style)
        }
        return RoomSceneBuilder.makeModel(for: plan)
    }
    var canProcess: Bool { files.hasRawCapture }
    var hasGeometry: Bool { mesh != nil || cloud != nil }
    var floorPlan: FloorPlanData? { scan.kind == .room ? roomPlan : blueprint?.plan }
    var measuredDistance: Float? {
        measurePoints.count == 2 ? simd_distance(measurePoints[0], measurePoints[1]) : nil
    }

    var bounds: BoundingBox {
        if let mesh, mesh.vertexCount > 0 { return BoundingBox(points: mesh.positions) }
        if let cloud, cloud.count > 0 { return BoundingBox(points: cloud.positions) }
        if let floorPlan { return RoomSceneBuilder.makeModel(for: floorPlan).bounds }
        return BoundingBox(min: SIMD3(-1, -1, -1), max: SIMD3(1, 1, 1))
    }

    var availableStyles: [StudioStyle] {
        var styles: [StudioStyle] = []
        if let mesh {
            if !isPreviewMesh && mesh.groups.contains(where: { $0.textureIndex >= 0 }) || mesh.colors.count == mesh.vertexCount && !isPreviewMesh {
                styles.append(.textured)
            }
            styles += [.solid, .wire]
            if mesh.classes.contains(where: { $0 != 0 }) { styles.append(.labels) }
        }
        if cloud != nil { styles.append(.points) }
        if floorPlan != nil { styles.append(.plan) }
        return styles
    }

    // MARK: - Loading

    private struct Loaded {
        var mesh: TexturedMesh?
        var isPreview = false
        var cloud: PointCloud?
        var roomPlan: FloorPlanData?
        var edits: [EditOperation] = []
        var isFirstOpen = false
        var blueprint: StoredBlueprint?
    }

    /// The working data: the originals with the edit stack applied.
    private struct Working {
        var mesh: TexturedMesh?
        var cloud: PointCloud?
        var cloudNormals: [SIMD3<Float>]?
    }

    func load() async {
        isLoading = true
        let files = files, editsURL = editsURL, blueprintURL = blueprintURL
        let loaded = await Task.detached(priority: .userInitiated) { () -> Loaded in
            var loaded = Loaded()
            if files.hasTexturedModel {
                loaded.mesh = try? TexturedMesh.read(from: files.texturedMesh)
            } else if files.hasRawCapture, let raw = try? RawMesh.read(from: files.rawMesh) {
                loaded.mesh = TexturedMesh.preview(of: raw)
                loaded.isPreview = true
            }
            if files.hasPointCloud { loaded.cloud = try? PointCloud.read(from: files.pointCloud) }
            loaded.roomPlan = try? FloorPlanData.read(from: files.floorPlan)
            loaded.isFirstOpen = !FileManager.default.fileExists(atPath: editsURL.path)
            loaded.edits = (try? JSONDecoder().decode([EditOperation].self, from: Data(contentsOf: editsURL))) ?? []
            loaded.blueprint = try? JSONDecoder.scanSpace.decode(StoredBlueprint.self, from: Data(contentsOf: blueprintURL))
            return loaded
        }.value
        baseMesh = loaded.mesh
        baseCloud = loaded.cloud
        isPreviewMesh = loaded.isPreview
        roomPlan = loaded.roomPlan
        edits = loaded.edits
        blueprint = loaded.blueprint
        await rebuildWorkingData()
        chooseDefaultStyle()
        resetCropBox()
        planRevision += 1
        isLoading = false
        if loaded.isFirstOpen, scan.kind == .lidar, files.hasRawCapture {
            // Captures start in ARKit's arbitrary heading. Square them up once, as an ordinary
            // undoable edit, so crop boxes, views and exports line up with the walls.
            await levelAndAlign(automatic: true)
        }
        if scan.status == .needsProcessing, canProcess {
            await process()
        } else if !FileManager.default.fileExists(atPath: files.thumbnail.path) {
            renderThumbnail()
        }
    }

    private func chooseDefaultStyle() {
        let styles = availableStyles
        if scan.kind == .room {
            style = .plan
        } else if !styles.contains(style), let first = styles.first {
            style = styles.contains(.labels) && isPreviewMesh ? .labels : first
        }
    }

    func resetCropBox() {
        let box = bounds
        cropMin = box.min - 0.01
        cropMax = box.max + 0.01
    }

    private func rebuildWorkingData() async {
        let baseMesh = baseMesh, baseCloud = baseCloud, edits = edits
        let working = await Task.detached(priority: .userInitiated) {
            Self.applying(edits, mesh: baseMesh, cloud: baseCloud)
        }.value
        use(working)
    }

    private func use(_ working: Working) {
        mesh = working.mesh
        cloud = working.cloud
        cloudNormals = working.cloudNormals
        geometryRevision += 1
    }

    nonisolated private static func applying(_ operations: [EditOperation], mesh: TexturedMesh?, cloud: PointCloud?) -> Working {
        var working = Working(mesh: mesh, cloud: cloud)
        for operation in operations {
            if working.mesh != nil { MeshEditor.apply(operation, to: &working.mesh!) }
            if working.cloud != nil { MeshEditor.apply(operation, to: &working.cloud!) }
        }
        if let cloud = working.cloud, let mesh = working.mesh, cloud.count > 0, mesh.vertexCount > 0,
           mesh.normals.count == mesh.vertexCount {
            working.cloudNormals = PointCloudFilters.normalsFromMesh(points: cloud.positions, meshPositions: mesh.positions,
                                                                     meshNormals: mesh.normals)
        }
        return working
    }

    // MARK: - Editing

    func apply(_ operation: EditOperation) async {
        await perform(operation, clearRedo: true)
    }

    private func perform(_ operation: EditOperation, clearRedo: Bool) async {
        guard !isBusy else { return }
        busy = LibraryJob(title: operation.title + "…")
        await record(operation, clearRedo: clearRedo)
        busy = nil
    }

    /// Applies `operation` to the working data and adds it to the edit stack (callers set `busy`).
    private func record(_ operation: EditOperation, clearRedo: Bool) async {
        let mesh = mesh, cloud = cloud
        let working = await Task.detached(priority: .userInitiated) {
            Self.applying([operation], mesh: mesh, cloud: cloud)
        }.value
        edits.append(operation)
        if clearRedo { redoStack.removeAll() }
        if case .transform(let values) = operation, var stored = blueprint {
            stored.plan = stored.plan.transformed(by: simd_float4x4(columnMajor: values))
            blueprint = stored
            saveBlueprint()
            planRevision += 1
        } else if blueprint != nil {
            blueprintIsStale = true
        }
        saveEdits()
        pendingSelection = nil
        measurePoints = []
        use(working)
    }

    func undo() async {
        guard !isBusy, let last = edits.popLast() else { return }
        redoStack.append(last)
        if case .transform(let values) = last, var stored = blueprint {
            stored.plan = stored.plan.transformed(by: simd_float4x4(columnMajor: values).inverse)
            blueprint = stored
            saveBlueprint()
            planRevision += 1
        }
        saveEdits()
        busy = LibraryJob(title: "Undoing…")
        await rebuildWorkingData()
        busy = nil
    }

    func redo() async {
        guard let operation = redoStack.popLast() else { return }
        await perform(operation, clearRedo: false)
    }

    func revertAllEdits() async {
        guard !isBusy, !edits.isEmpty else { return }
        edits.removeAll()
        redoStack.removeAll()
        saveEdits()
        busy = LibraryJob(title: "Reverting…")
        await rebuildWorkingData()
        resetCropBox()
        busy = nil
    }

    func cropToBox() async {
        await apply(.crop(min: simd_min(cropMin, cropMax), max: simd_max(cropMin, cropMax)))
        showCropBox = false
        resetCropBox()
    }

    func deleteSelection() async {
        guard let planes = pendingSelection else { return }
        await apply(.deleteRegion(planes: planes))
    }

    /// Puts the floor at height 0 and turns the scan so its main walls run along the X and Z axes.
    /// `automatic` is the quiet variant used when a scan is first opened: it leaves scans that are
    /// already square alone and doesn't report failures.
    func levelAndAlign(automatic: Bool = false) async {
        guard !isBusy, hasGeometry else { return }
        busy = LibraryJob(title: "Leveling and aligning…")
        let mesh = mesh, cloud = cloud, pivot = bounds.center
        do {
            let frame = try await Task.detached(priority: .userInitiated) {
                let (samples, oriented) = Self.samples(mesh: mesh, cloud: cloud)
                return try BlueprintExtractor.estimateFrame(samples: samples, orientedNormals: oriented)
            }.value
            let alreadySquare = abs(frame.rotation) < 0.5 * .pi / 180 && abs(frame.floorHeight) < 0.01
            if !(automatic && alreadySquare) {
                let transform = MeshEditor.levelingTransform(rotation: frame.rotation, floorHeight: frame.floorHeight, pivot: pivot)
                await record(.transform(matrix: transform.columnMajorArray), clearRedo: true)
                resetCropBox()
                cameraCommand = CameraCommand(kind: .reset)
            }
        } catch {
            if !automatic { errorMessage = error.localizedDescription }
        }
        // Also marks the project as opened, so the automatic pass runs only once.
        saveEdits()
        busy = nil
    }

    private func saveEdits() {
        try? JSONEncoder().encode(edits).write(to: editsURL, options: .atomic)
    }

    nonisolated private static func samples(mesh: TexturedMesh?, cloud: PointCloud?) -> ([BlueprintSample], Bool) {
        if let mesh, mesh.triangleCount > 0 {
            // ScanSpace meshes have consistent winding and ARKit labels; other files may not.
            let labelled = mesh.classes.contains { $0 != 0 }
            return (BlueprintSample.samples(from: mesh), labelled)
        }
        if let cloud { return (BlueprintSample.samples(from: cloud), false) }
        return ([], false)
    }

    // MARK: - Processing

    func process() async {
        guard canProcess, !isBusy else { return }
        busy = LibraryJob(title: "Preparing…", progress: 0)
        scan.status = .processing
        library?.save(scan)
        let options = ProcessingOptions(maxTexturePages: textureQuality.pages, texturePageSize: textureQuality.pageSize,
                                        buildPointCloud: buildPointCloud)
        let files = files
        do {
            let output = try await Task.detached(priority: .userInitiated) {
                try ScanProcessor(files: files, options: options).run { progress in
                    Task { @MainActor in self.busy = LibraryJob(title: progress.stage, progress: progress.fraction) }
                }
            }.value
            scan.status = .ready
            scan.failureReason = nil
            scan.stats.vertexCount = output.vertexCount
            scan.stats.triangleCount = output.triangleCount
            scan.stats.textureCount = output.textureCount
            scan.stats.keyframeCount = output.keyframeCount
            scan.stats.pointCount = output.pointCount
            scan.stats.surfaceArea = output.surfaceArea
            scan.stats.bounds = [Double(output.bounds.x), Double(output.bounds.y), Double(output.bounds.z)]
            library?.save(scan)
            let reloaded = await Task.detached { (try? TexturedMesh.read(from: files.texturedMesh), try? PointCloud.read(from: files.pointCloud)) }.value
            baseMesh = reloaded.0
            baseCloud = reloaded.1
            isPreviewMesh = false
            await rebuildWorkingData()
            style = .textured
            renderThumbnail()
        } catch {
            scan.status = .failed
            scan.failureReason = error.localizedDescription
            library?.save(scan)
            errorMessage = error.localizedDescription
        }
        busy = nil
    }

    // MARK: - Blueprint

    func generateBlueprint() async {
        guard !isBusy else { return }
        busy = LibraryJob(title: "Finding walls, doors and rooms…")
        let mesh = mesh, cloud = cloud, options = blueprintOptions
        do {
            let result = try await Task.detached(priority: .userInitiated) { () -> BlueprintResult in
                let (samples, oriented) = Self.samples(mesh: mesh, cloud: cloud)
                return try BlueprintExtractor.extract(samples: samples, orientedNormals: oriented, options: options)
            }.value
            blueprint = StoredBlueprint(plan: result.plan, floorHeight: result.floorHeight, ceilingHeight: result.ceilingHeight,
                                        ceilingDetected: result.ceilingDetected, rotationDegrees: result.rotationDegrees,
                                        rooms: result.rooms.map { StoredBlueprint.Room(name: $0.name, area: $0.area) }, notes: result.notes)
            blueprintIsStale = false
            saveBlueprint()
            planRevision += 1
            mode = .plan
        } catch {
            errorMessage = error.localizedDescription
        }
        busy = nil
    }

    private func saveBlueprint() {
        guard let blueprint else { return }
        try? JSONEncoder.scanSpace.encode(blueprint).write(to: blueprintURL, options: .atomic)
    }

    // MARK: - Export

    func isAvailable(_ export: StudioExport) -> Bool {
        switch export {
        case .glb, .usdz, .obj, .stl: return mesh != nil || floorPlan != nil
        case .ply: return mesh != nil
        case .pointCloud: return cloud != nil
        case .planPDF, .planPNG, .planSVG, .planDXF, .planGLB, .planUSDZ: return floorPlan != nil
        }
    }

    func export(_ kind: StudioExport, to url: URL, units: MeasurementSystem) async throws {
        busy = LibraryJob(title: "Exporting \(kind.title)…")
        defer { busy = nil }
        let name = ScanExporter.fileName(for: scan.name)
        if kind == .planPDF || kind == .planPNG {
            guard let plan = floorPlan else { throw ExportError.missingData("floor plan") }
            try FloorPlanExporter.render(plan, format: kind == .planPDF ? .floorPlanPDF : .floorPlanPNG, to: url, title: scan.name, units: units)
            return
        }
        let mesh = mesh, cloud = cloud, plan = floorPlan, textureURLs = files.textureURLs(count: mesh?.textureCount ?? 0)
        let title = scan.name, look = planLook
        try await Task.detached(priority: .userInitiated) {
            func meshModel() throws -> ExportModel {
                if let mesh { return ExportModel(textured: mesh, textureURLs: textureURLs, name: name) }
                if let plan { return RoomSceneBuilder.makeModel(for: plan) }
                throw ExportError.missingData("geometry")
            }
            func planModel() throws -> ExportModel {
                guard let plan else { throw ExportError.missingData("floor plan") }
                return ProjectSession.planModel(for: plan, look: look)
            }
            switch kind {
            case .glb: try GLBWriter.write(try meshModel(), to: url)
            case .planGLB: try GLBWriter.write(try planModel(), to: url)
            case .usdz: try SceneKitExport.writeUSDZ(try meshModel(), to: url)
            case .planUSDZ: try SceneKitExport.writeUSDZ(try planModel(), to: url)
            case .stl: try STLWriter.write(try meshModel(), to: url)
            case .obj:
                let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                defer { try? FileManager.default.removeItem(at: staging) }
                let written = try OBJWriter.write(try meshModel(), to: staging, baseName: name)
                try ZipWriter.write(written.map { ZipWriter.Entry(name: $0.lastPathComponent, source: $0) }, to: url)
            case .ply:
                guard let mesh else { throw ExportError.missingData("mesh") }
                try PLYWriter.writeMesh(positions: mesh.positions, normals: mesh.normals, colors: mesh.colors,
                                        indices: mesh.groups.flatMap(\.indices), to: url)
            case .pointCloud:
                guard let cloud else { throw ExportError.missingData("point cloud") }
                try PLYWriter.writePoints(cloud, to: url)
            case .planSVG:
                guard let plan else { throw ExportError.missingData("floor plan") }
                try FloorPlanVectorExport.svg(FloorPlanGeometry(data: plan), title: title, system: units).write(to: url, atomically: true, encoding: .utf8)
            case .planDXF:
                guard let plan else { throw ExportError.missingData("floor plan") }
                try FloorPlanVectorExport.dxf(FloorPlanGeometry(data: plan), system: units).write(to: url, atomically: true, encoding: .ascii)
            case .planPDF, .planPNG:
                break
            }
        }.value
    }

    // MARK: - Thumbnails

    func renderThumbnail() {
        let mesh = mesh, cloud = cloud, plan = floorPlan, files = files, id = id
        let textureURLs = files.textureURLs(count: mesh?.textureCount ?? 0)
        Task.detached(priority: .utility) {
            guard let image = StudioThumbnails.render(mesh: mesh, textureURLs: textureURLs, cloud: cloud, plan: plan),
                  let cgImage = image.cgImageRepresentation else { return }
            try? ImageFiles.writeJPEG(cgImage, to: files.thumbnail, quality: 0.85)
            await MainActor.run { ProjectLibrary.shared.thumbnailDidChange(id) }
        }
    }
}

enum StudioThumbnails {
    static func render(mesh: TexturedMesh?, textureURLs: [URL], cloud: PointCloud?, plan: FloorPlanData?, size: CGSize = CGSize(width: 480, height: 360)) -> NSImage? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let scene = SCNScene()
        scene.background.contents = NSColor(red: 0.08, green: 0.09, blue: 0.13, alpha: 1)
        let bounds: BoundingBox
        if let mesh, mesh.triangleCount > 0 {
            let assets = TexturedMeshAssets(mesh: mesh, textureURLs: textureURLs)
            scene.rootNode.addChildNode(SCNNode(geometry: assets.geometry(for: textureURLs.isEmpty && mesh.colors.isEmpty ? .shaded : .textured)))
            bounds = assets.bounds
        } else if let cloud, cloud.count > 0 {
            scene.rootNode.addChildNode(ScanSceneBuilder.pointCloudNode(cloud, pointSize: 0.02))
            bounds = BoundingBox(points: cloud.positions)
        } else if let plan {
            let model = RoomSceneBuilder.makeModel(for: plan)
            scene.rootNode.addChildNode(SceneKitExport.node(for: model))
            bounds = model.bounds
        } else {
            return nil
        }
        ScanSceneBuilder.addStudioLights(to: scene.rootNode)
        let camera = ScanSceneBuilder.makeCamera(framing: bounds)
        scene.rootNode.addChildNode(camera)
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        renderer.prepare(scene.rootNode, shouldAbortBlock: nil)
        return renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
    }
}

struct CameraCommand: Equatable {
    enum Kind { case reset, top, front }
    let kind: Kind
    let id = UUID()
}

extension FloorPlanData {
    /// The plan moved by a rigid transform (keeps it aligned with a leveled/aligned scan).
    func transformed(by m: simd_float4x4) -> FloorPlanData {
        var copy = self
        for i in copy.surfaces.indices {
            copy.surfaces[i].transform = (m * copy.surfaces[i].matrix).columnMajorArray
        }
        for i in copy.objects.indices {
            copy.objects[i].transform = (m * copy.objects[i].matrix).columnMajorArray
        }
        for i in copy.sections.indices {
            let p = m.transformPoint(copy.sections[i].position)
            copy.sections[i].center = [p.x, p.y, p.z]
        }
        return copy
    }
}
