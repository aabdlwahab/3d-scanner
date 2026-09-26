import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct InspectorView: View {
    @Bindable var session: ProjectSession

    var body: some View {
        VStack(spacing: 0) {
            Picker("Panel", selection: $session.inspectorTab) {
                ForEach(InspectorTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            Group {
                switch session.inspectorTab {
                case .info: InfoPanel(session: session)
                case .clean: CleanPanel(session: session)
                case .blueprint: BlueprintPanel(session: session)
                case .process: ProcessPanel(session: session)
                }
            }
            .formStyle(.grouped)
            .disabled(session.isBusy || session.isLoading)
        }
    }
}

// MARK: - Info

private struct InfoPanel: View {
    @Bindable var session: ProjectSession
    @AppStorage("units") private var units = MeasurementSystem.preferred
    @State private var name = ""

    var body: some View {
        Form {
            Section("Project") {
                TextField("Name", text: $name)
                    .onSubmit { ProjectLibrary.shared.rename(session.id, to: name) }
                LabeledContent("Type", value: session.scan.kind.title)
                LabeledContent("Captured", value: session.scan.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Status", value: status)
            }
            Section("Model") {
                if let mesh = session.mesh {
                    LabeledContent("Triangles", value: mesh.triangleCount.formatted())
                    LabeledContent("Vertices", value: mesh.vertexCount.formatted())
                    LabeledContent("Surface area", value: UnitFormat.area(MeshMath.surfaceArea(positions: mesh.positions, indices: mesh.groups.flatMap(\.indices)), units))
                    if mesh.textureCount > 0 { LabeledContent("Textures", value: "\(mesh.textureCount)") }
                }
                if let cloud = session.cloud { LabeledContent("Points", value: cloud.count.formatted()) }
                let size = session.bounds.size
                LabeledContent("Size (W × H × D)", value: UnitFormat.dimensions([Double(size.x), Double(size.y), Double(size.z)], units))
                if session.scan.stats.keyframeCount > 0 { LabeledContent("Photos", value: "\(session.scan.stats.keyframeCount)") }
            }
            if let plan = session.floorPlan {
                let geometry = FloorPlanGeometry(data: plan)
                Section("Floor Plan") {
                    LabeledContent("Floor area", value: UnitFormat.area(geometry.floorArea, units))
                    LabeledContent("Rooms", value: "\(plan.roomCount)")
                    LabeledContent("Walls", value: "\(plan.walls.count)")
                    LabeledContent("Doors · Windows", value: "\(plan.doors.count + plan.openings.count) · \(plan.windows.count)")
                }
            }
            Section("Edit History") {
                if session.edits.isEmpty {
                    Text("No edits. The original scan is untouched.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(session.edits.enumerated()), id: \.offset) { index, edit in
                        Label("\(index + 1). \(edit.title)", systemImage: edit.systemImage)
                    }
                    HStack {
                        Button("Undo") { Task { await session.undo() } }
                        Button("Revert All", role: .destructive) { Task { await session.revertAllEdits() } }
                    }
                }
            }
        }
        .onAppear { name = session.scan.name }
    }

    private var status: String {
        switch session.scan.status {
        case .ready: "Ready"
        case .processing: "Processing"
        case .needsProcessing: "Not processed"
        case .failed: "Failed — \(session.scan.failureReason ?? "")"
        }
    }
}

// MARK: - Clean

private struct CleanPanel: View {
    @Bindable var session: ProjectSession
    @AppStorage("units") private var units = MeasurementSystem.preferred
    @State private var minPieceArea: Double = 0.05
    @State private var smoothIterations = 3
    @State private var outlierNeighbors = 12
    @State private var outlierStrictness: Double = 2
    @State private var voxel: Double = 0.01

    var body: some View {
        Form {
            Section {
                if let _ = session.pendingSelection {
                    LabeledContent("Selected", value: session.selectionCount.formatted())
                    HStack {
                        Button("Delete Selection", role: .destructive) { Task { await session.deleteSelection() } }
                        Button("Clear") { session.pendingSelection = nil }
                    }
                } else {
                    Text("Choose the Select tool (⌘3) and drag over the model. Everything inside the rectangle is selected, front to back.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Use Select Tool") { session.tool = .select }
                }
            } header: {
                Text("Select & Delete")
            }

            Section {
                Toggle("Show crop box", isOn: $session.showCropBox)
                if session.showCropBox {
                    let box = session.bounds
                    ForEach(0..<3, id: \.self) { axis in
                        axisSliders(axis, box: box)
                    }
                    HStack {
                        Button("Crop to Box") { Task { await session.cropToBox() } }
                            .buttonStyle(.borderedProminent)
                        Button("Reset Box") { session.resetCropBox() }
                    }
                }
            } header: {
                Text("Crop")
            } footer: {
                Text("Keeps only what's inside the yellow box — handy for cutting away the outside of a room or the ceiling.")
            }

            if session.mesh != nil {
                Section("Mesh") {
                    VStack(alignment: .leading) {
                        Slider(value: $minPieceArea, in: 0.01...2) {
                            Text("Floating pieces")
                        }
                        Text("Removes loose pieces smaller than \(String(format: "%.2f", minPieceArea)) m²")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Remove Floating Pieces") { Task { await session.apply(.removeSmallPieces(minArea: Float(minPieceArea))) } }
                    Stepper("Smoothing passes: \(smoothIterations)", value: $smoothIterations, in: 1...10)
                    Button("Smooth Surface") { Task { await session.apply(.smooth(iterations: smoothIterations)) } }
                }
            }

            Section {
                Button("Level Floor & Square Up Walls") { Task { await session.levelAndAlign() } }
            } header: {
                Text("Align")
            } footer: {
                Text("Moves the floor to height 0 and rotates the scan so walls line up with the X and Z axes.")
            }

            if let cloud = session.cloud {
                Section {
                    Stepper("Neighbors: \(outlierNeighbors)", value: $outlierNeighbors, in: 4...40, step: 2)
                    VStack(alignment: .leading) {
                        Slider(value: $outlierStrictness, in: 0.5...4) { Text("Tolerance") }
                        Text("Lower removes more (\(String(format: "%.1f", outlierStrictness)) σ)").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Remove Outlier Points") {
                        Task { await session.apply(.removeOutlierPoints(neighbors: outlierNeighbors, stdRatio: Float(outlierStrictness))) }
                    }
                    VStack(alignment: .leading) {
                        Slider(value: $voxel, in: 0.005...0.1) { Text("Spacing") }
                        Text("One point per \(UnitFormat.length(voxel, units)) cell").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Downsample Points") { Task { await session.apply(.downsamplePoints(voxel: Float(voxel))) } }
                } header: {
                    Text("Point Cloud")
                } footer: {
                    Text("\(cloud.count.formatted()) points")
                }
            }

            Section("History") {
                HStack {
                    Button("Undo") { Task { await session.undo() } }.disabled(session.edits.isEmpty)
                    Button("Redo") { Task { await session.redo() } }.disabled(session.redoStack.isEmpty)
                    Spacer()
                    Button("Revert All", role: .destructive) { Task { await session.revertAllEdits() } }.disabled(session.edits.isEmpty)
                }
            }
        }
    }

    private func axisSliders(_ axis: Int, box: BoundingBox) -> some View {
        let names = ["X (width)", "Y (height)", "Z (depth)"]
        let lo = Double(box.min[axis]) - 0.2, hi = Double(box.max[axis]) + 0.2
        let minBinding = Binding<Double>(get: { Double(session.cropMin[axis]) }, set: { session.cropMin[axis] = Float($0) })
        let maxBinding = Binding<Double>(get: { Double(session.cropMax[axis]) }, set: { session.cropMax[axis] = Float($0) })
        return VStack(alignment: .leading, spacing: 2) {
            Text(names[axis]).font(.caption.weight(.semibold))
            Slider(value: minBinding, in: lo...max(lo + 0.01, hi)) { Text("Min") }
            Slider(value: maxBinding, in: lo...max(lo + 0.01, hi)) { Text("Max") }
        }
    }
}

// MARK: - Blueprint

private struct BlueprintPanel: View {
    @Bindable var session: ProjectSession
    @AppStorage("units") private var units = MeasurementSystem.preferred

    var body: some View {
        Form {
            if session.scan.kind == .room {
                Section("RoomPlan Apartment") {
                    Text("This apartment was captured room by room with RoomPlan, so its floor plan is already exact.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Show Floor Plan") { session.mode = .plan }
                }
            } else {
                Section {
                    Text("Finds the floor and ceiling, walls (with thickness where both sides were scanned), doors, windows, rooms and furniture, and draws a dimensioned plan.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button {
                        Task { await session.generateBlueprint() }
                    } label: {
                        Label(session.blueprint == nil ? "Generate Floor Plan" : "Regenerate Floor Plan", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!session.hasGeometry)
                    if session.blueprintIsStale {
                        Label("The model changed since this plan was made.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).font(.callout)
                    }
                } header: {
                    Text("Blueprint from Scan")
                }
                DisclosureGroup("Advanced") {
                    slider("Shortest wall", value: $session.blueprintOptions.minWallLength, range: 0.2...1.5, length: true)
                    slider("One-sided wall thickness", value: $session.blueprintOptions.defaultThickness, range: 0.05...0.35, length: true)
                    slider("Ignore surfaces below", value: $session.blueprintOptions.bandBottom, range: 0.1...1.2, length: true)
                    slider("Bridge gaps up to", value: $session.blueprintOptions.mergeGap, range: 0.1...1.0, length: true)
                    slider("Smallest room", value: $session.blueprintOptions.minRoomArea, range: 0.5...6, length: false)
                    Button("Restore Defaults") { session.blueprintOptions = BlueprintOptions() }
                }
            }

            if let blueprint = session.blueprint, session.scan.kind != .room {
                Section("Result") {
                    LabeledContent("Floor area", value: UnitFormat.area(blueprint.floorArea, units))
                    ForEach(Array(blueprint.rooms.enumerated()), id: \.offset) { _, room in
                        LabeledContent(room.name, value: UnitFormat.area(room.area, units))
                    }
                    LabeledContent("Ceiling height", value: UnitFormat.length(Double(blueprint.ceilingHeight - blueprint.floorHeight), units)
                                   + (blueprint.ceilingDetected ? "" : " (estimated)"))
                    ForEach(blueprint.notes, id: \.self) { note in
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Show Plan") { session.mode = .plan }
                        Button("Show 3D") {
                            session.mode = .model
                            session.style = .plan
                        }
                    }
                }
            }

            if session.floorPlan != nil {
                Section("Export Plan") {
                    ForEach([StudioExport.planPDF, .planSVG, .planDXF, .planPNG, .planGLB], id: \.self) { kind in
                        Button(kind.title) { export(kind) }
                    }
                }
            }
        }
    }

    private func slider(_ title: String, value: Binding<Float>, range: ClosedRange<Double>, length: Bool) -> some View {
        let binding = Binding<Double>(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Float($0) })
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(length ? UnitFormat.length(binding.wrappedValue, units) : UnitFormat.area(binding.wrappedValue, units))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.caption)
            Slider(value: binding, in: range)
        }
    }

    private func export(_ kind: StudioExport) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(ScanExporter.fileName(for: session.scan.name))-floor-plan.\(kind.fileExtension)"
        if let type = UTType(filenameExtension: kind.fileExtension) { panel.allowedContentTypes = [type] }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try await session.export(kind, to: url, units: units)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch {
                    session.errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Process

private struct ProcessPanel: View {
    @Bindable var session: ProjectSession

    var body: some View {
        Form {
            if session.canProcess {
                Section {
                    LabeledContent("Photos", value: "\(session.scan.stats.keyframeCount)")
                    Picker("Texture quality", selection: $session.textureQuality) {
                        ForEach(StudioTextureQuality.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Build point cloud", isOn: $session.buildPointCloud)
                    Button {
                        Task { await session.process() }
                    } label: {
                        Label(session.scan.status == .ready ? "Process Again" : "Process Capture", systemImage: "gearshape.2")
                    }
                    .buttonStyle(.borderedProminent)
                } header: {
                    Text("Textures")
                } footer: {
                    Text("Re-bakes the photo textures from the original LiDAR capture — a Mac can use much larger textures than the iPhone. Your edits are applied again afterwards.")
                }
            } else {
                Section("Textures") {
                    Text("This project has no raw capture (photos and depth), so it can't be re-processed. Import a “.scanspace” project or a raw capture from the iPhone app to process it here.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}
