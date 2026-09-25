import SceneKit
import SwiftUI

/// 3D viewer for one scan with processing status, styles, measuring, AR and export.
struct ScanDetailView: View {
    let scanID: UUID
    @Environment(ScanStore.self) private var store
    @Environment(ProcessingCenter.self) private var processing
    @Environment(\.dismiss) private var dismiss
    @State private var viewer = ViewerState()
    @State private var content: ViewerContent?
    @State private var contentStatus: ScanStatus?
    @State private var showExport = false
    @State private var showInfo = false
    @State private var showFloorPlan = false
    @State private var showCut = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @State private var preparingAR = false
    @State private var errorMessage: String?
    @AppStorage(AppSettings.unitsKey) private var units = MeasurementSystem.preferred

    var body: some View {
        if let scan = store.scan(scanID) {
            detail(scan)
        } else {
            ContentUnavailableView("Scan not found", systemImage: "questionmark.square.dashed")
        }
    }

    private func detail(_ scan: Scan) -> some View {
        ZStack {
            Theme.backdrop.ignoresSafeArea()
            if let content {
                SceneViewer(content: content, state: viewer, style: viewer.style, cutFraction: viewer.cutFraction,
                            isMeasuring: viewer.isMeasuring, measureCount: viewer.measurePoints.count,
                            cameraCommand: viewer.cameraCommand)
                    .id(contentStatus)
                    .ignoresSafeArea()
            }
            if let position = viewer.measureLabelPosition, let distance = viewer.measuredDistance {
                Text(UnitFormat.length(Double(distance), units))
                    .font(.subheadline.weight(.bold)).monospacedDigit()
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.accentSecondary, in: Capsule())
                    .foregroundStyle(.black)
                    .position(x: position.x, y: position.y - 22)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
            }
            statusOverlay(scan)
            VStack(spacing: 10) {
                Spacer()
                if viewer.isMeasuring { measureHUD }
                if showCut { cutSlider }
                if content != nil, scan.status == .ready { bottomBar(scan) }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
        .navigationTitle(scan.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { newName = scan.name; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                    Button { showInfo = true } label: { Label("Details", systemImage: "info.circle") }
                    if scan.kind == .lidar, store.files(for: scan.id).hasRawCapture, !processing.isProcessing(scan.id) {
                        Button { reprocess(scan) } label: { Label("Process Again", systemImage: "arrow.triangle.2.circlepath") }
                    }
                    Divider()
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task(id: scan.status) { await load(scan) }
        .onAppear { viewer.style = scan.kind == .lidar ? .textured : .shaded }
        .sheet(isPresented: $showExport) { ExportSheet(scan: scan) }
        .sheet(isPresented: $showInfo) { ScanInfoSheet(scanID: scan.id) }
        .fullScreenCover(isPresented: $showFloorPlan) { FloorPlanScreen(scan: scan) }
        .alert("Rename Scan", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") { store.rename(scan.id, to: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(scan.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Scan", role: .destructive) {
                dismiss()
                store.delete(scan.id)
            }
        } message: {
            Text("This removes the model, photos and exports stored in the app.")
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Overlays

    @ViewBuilder
    private func statusOverlay(_ scan: Scan) -> some View {
        if let progress = processing.progress(for: scan.id) {
            ProgressCard(title: progress.stage, message: "Turning \(scan.stats.keyframeCount) photos into textures. You can leave this screen — processing continues.",
                         progress: progress.fraction)
        } else {
            switch scan.status {
            case .failed:
                MessageCard(systemImage: "exclamationmark.triangle.fill", title: "Processing failed",
                            message: scan.failureReason ?? "Unknown error", buttonTitle: "Try Again") { reprocess(scan) }
            case .needsProcessing:
                MessageCard(systemImage: "wand.and.stars", title: "Ready to process",
                            message: "Build the textured model from this capture.", buttonTitle: "Process") { reprocess(scan) }
            default:
                if content == nil { ProgressView().controlSize(.large).tint(.white) }
            }
        }
        if preparingAR {
            ProgressCard(title: "Preparing AR…", message: "Creating a USDZ file for AR Quick Look")
        }
    }

    private var measureHUD: some View {
        HStack(spacing: 12) {
            Image(systemName: "ruler").foregroundStyle(Theme.accentSecondary)
            if let distance = viewer.measuredDistance {
                Text(UnitFormat.length(Double(distance), units)).font(.headline).monospacedDigit()
                Spacer()
                Button("Clear") { viewer.measurePoints = [] }.font(.subheadline.weight(.semibold))
            } else {
                Text(viewer.measurePoints.isEmpty ? "Tap a point on the model" : "Tap a second point")
                    .font(.subheadline)
                Spacer()
            }
            Button {
                viewer.isMeasuring = false
            } label: {
                Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .glassPanel(cornerRadius: 18)
    }

    private var cutSlider: some View {
        HStack(spacing: 12) {
            Image(systemName: "scissors").foregroundStyle(Theme.accentSecondary)
            Slider(value: $viewer.cutFraction, in: 0.15...1)
            Text(viewer.cutFraction >= 0.999 ? "Off" : "\(Int(viewer.cutFraction * 100))%")
                .font(.caption.weight(.semibold)).monospacedDigit().frame(width: 38)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .glassPanel(cornerRadius: 18)
    }

    private func bottomBar(_ scan: Scan) -> some View {
        VStack(spacing: 10) {
            if scan.kind == .lidar {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(RenderStyle.allCases) { style in
                            let hasPoints = store.files(for: scan.id).hasPointCloud
                            if style != .points || hasPoints {
                                StyleChip(title: style.title, systemImage: style.systemImage, isSelected: viewer.style == style) {
                                    viewer.style = style
                                    Haptics.tap()
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            HStack(spacing: 0) {
                ToolbarButton(title: "Measure", systemImage: "ruler", isActive: viewer.isMeasuring) {
                    viewer.isMeasuring.toggle()
                }
                ToolbarButton(title: "Cut", systemImage: "scissors", isActive: showCut) {
                    showCut.toggle()
                    if !showCut { viewer.cutFraction = 1 }
                }
                ToolbarButton(title: "View", systemImage: "camera.viewfinder") {
                    viewer.cameraCommand = CameraCommand(kind: .reset)
                }
                ToolbarButton(title: "Top", systemImage: "square.dashed.inset.filled") {
                    viewer.cameraCommand = CameraCommand(kind: .top)
                }
                if scan.kind == .room {
                    ToolbarButton(title: "Plan", systemImage: "square.split.bottomrightquarter") { showFloorPlan = true }
                }
                ToolbarButton(title: "AR", systemImage: "arkit") { openAR(scan) }
                ToolbarButton(title: "Export", systemImage: "square.and.arrow.up") { showExport = true }
            }
            .padding(.vertical, 8)
            .glassPanel(cornerRadius: 22)
        }
    }

    // MARK: - Actions

    private func load(_ scan: Scan) async {
        let files = store.files(for: scan.id)
        switch scan.kind {
        case .lidar where scan.status == .ready:
            guard contentStatus != .ready else { return }
            let assets = await Task.detached(priority: .userInitiated) { try? TexturedMeshAssets(files: files) }.value
            if let assets {
                content = .lidar(assets, files)
                contentStatus = .ready
                viewer.style = .textured
            } else {
                errorMessage = "The processed model couldn't be loaded. Try processing the scan again."
            }
        case .lidar:
            guard content == nil, files.hasRawCapture else { return }
            let assets = await Task.detached(priority: .userInitiated) { () -> TexturedMeshAssets? in
                guard let raw = try? RawMesh.read(from: files.rawMesh) else { return nil }
                return TexturedMeshAssets(mesh: .preview(of: raw), textureURLs: [])
            }.value
            if let assets {
                content = .preview(assets)
                contentStatus = scan.status
                viewer.style = .classes
            }
        case .room:
            guard content == nil else { return }
            if let data = try? FloorPlanData.read(from: files.floorPlan) {
                content = .room(data)
                contentStatus = .ready
            } else {
                errorMessage = "The room model couldn't be loaded."
            }
        }
    }

    private func reprocess(_ scan: Scan) {
        processing.process(scan.id, store: store)
    }

    private func openAR(_ scan: Scan) {
        let files = store.files(for: scan.id)
        if scan.kind == .room, FileManager.default.fileExists(atPath: files.roomUSDZ.path) {
            Presenters.quickLook(files.roomUSDZ)
            return
        }
        preparingAR = true
        let exporter = ScanExporter(scan: scan, files: files)
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try exporter.export(.usdz) } }.value
            preparingAR = false
            switch result {
            case .success(let url): Presenters.quickLook(url)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
    }
}

extension TexturedMesh {
    /// Untextured stand-in for a raw capture, colored by surface class.
    static func preview(of raw: RawMesh) -> TexturedMesh {
        var mesh = TexturedMesh()
        mesh.positions = raw.positions
        mesh.normals = raw.normals.count == raw.positions.count ? raw.normals : MeshMath.vertexNormals(positions: raw.positions, indices: raw.indices)
        mesh.uvs = [SIMD2<Float>](repeating: .zero, count: raw.positions.count)
        var classes = [UInt8](repeating: 0, count: raw.positions.count)
        if raw.classes.count == raw.triangleCount {
            for t in 0..<raw.triangleCount {
                for corner in 0..<3 { classes[Int(raw.indices[3 * t + corner])] = raw.classes[t] }
            }
        }
        mesh.classes = classes
        mesh.groups = [Group(textureIndex: -1, indices: raw.indices)]
        return mesh
    }
}

struct StyleChip: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .foregroundStyle(isSelected ? Color.black : Color.white)
                .background {
                    if isSelected {
                        Capsule().fill(Color.white)
                    } else {
                        Capsule().fill(.ultraThinMaterial)
                    }
                }
                .overlay(Capsule().strokeBorder(Theme.surfaceStroke))
        }
        .buttonStyle(.plain)
    }
}

struct ToolbarButton: View {
    let title: String
    let systemImage: String
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 18, weight: .semibold))
                Text(title).font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(isActive ? Theme.accentSecondary : Color.white)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
