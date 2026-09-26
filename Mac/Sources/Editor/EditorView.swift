import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum InspectorTab: String, CaseIterable, Identifiable {
    case info, clean, blueprint, process

    var id: String { rawValue }

    var title: String {
        switch self {
        case .info: "Info"
        case .clean: "Clean"
        case .blueprint: "Blueprint"
        case .process: "Process"
        }
    }

    var systemImage: String {
        switch self {
        case .info: "info.circle"
        case .clean: "wand.and.stars"
        case .blueprint: "square.split.bottomrightquarter"
        case .process: "gearshape.2"
        }
    }
}

struct EditorView: View {
    @Bindable var session: ProjectSession
    @AppStorage("units") private var units = MeasurementSystem.preferred
    @State private var showInspector = true
    @State private var showCut = false

    var body: some View {
        ZStack {
            switch session.mode {
            case .model: modelArea
            case .plan: FloorPlanPane(session: session)
            }
            if session.isLoading {
                ProgressView("Loading \(session.scan.name)…")
            }
            if let busy = session.busy {
                BusyCard(job: busy)
            }
        }
        .navigationTitle(session.scan.name)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .inspector(isPresented: $showInspector) {
            InspectorView(session: session)
                .inspectorColumnWidth(min: 290, ideal: 320, max: 400)
        }
        .alert("Something went wrong", isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.errorMessage ?? "")
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let mesh = session.mesh { parts.append("\(UnitFormat.count(mesh.triangleCount)) triangles") }
        if let cloud = session.cloud { parts.append("\(UnitFormat.count(cloud.count)) points") }
        if let plan = session.floorPlan { parts.append(UnitFormat.area(FloorPlanGeometry(data: plan).floorArea, units)) }
        if !session.edits.isEmpty { parts.append("\(session.edits.count) edit\(session.edits.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    // MARK: 3D area

    @ViewBuilder
    private var modelArea: some View {
        if session.hasGeometry || session.floorPlan != nil {
            ZStack {
                Viewport(session: session, geometryRevision: session.geometryRevision, planRevision: session.planRevision,
                         style: session.style, tool: session.tool, cutFraction: session.cutFraction,
                         showCropBox: session.showCropBox, cropMin: session.cropMin, cropMax: session.cropMax,
                         selectionID: session.pendingSelection?.hashValue ?? 0, measureCount: session.measurePoints.count,
                         cameraCommand: session.cameraCommand)
                if let position = session.measureLabelPosition, let distance = session.measuredDistance {
                    Text(UnitFormat.length(Double(distance), units))
                        .font(.callout.weight(.bold)).monospacedDigit()
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color(red: 0.24, green: 0.84, blue: 0.96), in: Capsule())
                        .foregroundStyle(.black)
                        .position(x: position.x, y: position.y - 20)
                        .allowsHitTesting(false)
                }
                VStack {
                    Spacer()
                    toolHint
                }
                .padding(16)
            }
        } else if !session.isLoading {
            ContentUnavailableView("Nothing to show", systemImage: "cube.transparent",
                                   description: Text("This project has no mesh or point cloud yet."))
        }
    }

    @ViewBuilder
    private var toolHint: some View {
        switch session.tool {
        case .select:
            HStack(spacing: 12) {
                if session.pendingSelection != nil {
                    Text("\(session.selectionCount.formatted()) selected").font(.callout.weight(.semibold))
                    Button("Delete Selection") { Task { await session.deleteSelection() } }
                        .keyboardShortcut(.delete, modifiers: [])
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    Button("Clear") { session.pendingSelection = nil }
                } else {
                    Label("Drag over the model to select what to remove. Everything inside the rectangle is selected, front to back.",
                          systemImage: "rectangle.dashed")
                        .font(.callout)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .measure:
            HStack(spacing: 12) {
                Image(systemName: "ruler")
                if let distance = session.measuredDistance {
                    Text(UnitFormat.length(Double(distance), units)).font(.headline).monospacedDigit()
                    Button("Clear") { session.measurePoints = [] }
                } else {
                    Text(session.measurePoints.isEmpty ? "Click a point on the model" : "Click a second point").font(.callout)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .orbit:
            EmptyView()
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Mode", selection: $session.mode) {
                ForEach(EditorMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if session.mode == .model {
                Menu {
                    Picker("Style", selection: $session.style) {
                        ForEach(session.availableStyles) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(session.style.title, systemImage: session.style.systemImage)
                }
                .help("Render style")
                Picker("Tool", selection: $session.tool) {
                    ForEach(ViewportTool.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .help("Orbit, measure or select")
                Button {
                    showCut.toggle()
                } label: {
                    Label("Height Cut", systemImage: "scissors")
                }
                .help("Hide everything above a height to look into rooms")
                .popover(isPresented: $showCut, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Height Cut").font(.headline)
                        Slider(value: $session.cutFraction, in: 0.1...1) {
                            Text("Height")
                        }
                        .frame(width: 220)
                        Text(session.cutFraction >= 0.999 ? "Showing everything" : "Hiding the top \(Int((1 - session.cutFraction) * 100))%")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(14)
                }
                Button {
                    session.cameraCommand = CameraCommand(kind: .reset)
                } label: {
                    Label("Reset View", systemImage: "arrow.counterclockwise")
                }
                Button {
                    session.cameraCommand = CameraCommand(kind: .top)
                } label: {
                    Label("Top View", systemImage: "square.dashed.inset.filled")
                }
            }
            Menu {
                Section("Model") {
                    ForEach(StudioExport.allCases.filter { !$0.isPlanExport }) { kind in
                        Button(kind.title) { export(kind) }.disabled(!session.isAvailable(kind))
                    }
                }
                Section("Floor Plan") {
                    ForEach(StudioExport.allCases.filter(\.isPlanExport)) { kind in
                        Button(kind.title) { export(kind) }.disabled(!session.isAvailable(kind))
                    }
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(session.isBusy || session.isLoading)
            Button {
                showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
        }
    }

    private func export(_ kind: StudioExport) {
        let panel = NSSavePanel()
        let suffix = kind.isPlanExport ? (kind == .planGLB || kind == .planUSDZ ? "-plan-model" : "-floor-plan") : ""
        panel.nameFieldStringValue = "\(ScanExporter.fileName(for: session.scan.name))\(suffix).\(kind.fileExtension)"
        if let type = UTType(filenameExtension: kind.fileExtension) { panel.allowedContentTypes = [type] }
        panel.canCreateDirectories = true
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

struct BusyCard: View {
    let job: LibraryJob

    var body: some View {
        VStack(spacing: 12) {
            if let progress = job.progress {
                ProgressView(value: progress).frame(width: 240)
            } else {
                ProgressView().controlSize(.large)
            }
            Text(job.title).font(.headline)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 20, y: 6)
    }
}

struct FloorPlanPane: View {
    @Bindable var session: ProjectSession
    @AppStorage("units") private var units = MeasurementSystem.preferred
    @State private var paper = false
    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero
    @State private var showDimensions = true
    @State private var showFurniture = true

    var body: some View {
        if let plan = session.floorPlan {
            let geometry = FloorPlanGeometry(data: plan)
            FloorPlanCanvas(geometry: geometry, style: paper ? .paper : .dark, system: units, zoom: zoom, offset: offset,
                            showDimensions: showDimensions, showObjects: showFurniture)
                .gesture(
                    MagnifyGesture()
                        .onChanged { zoom = min(10, max(0.4, committedZoom * $0.magnification)) }
                        .onEnded { _ in committedZoom = zoom }
                        .simultaneously(with: DragGesture()
                            .onChanged { offset = CGSize(width: committedOffset.width + $0.translation.width,
                                                         height: committedOffset.height + $0.translation.height) }
                            .onEnded { _ in committedOffset = offset })
                )
                .overlay(alignment: .topLeading) { legend(geometry) }
                .overlay(alignment: .bottomTrailing) { controls }
        } else {
            ContentUnavailableView {
                Label("No floor plan yet", systemImage: "square.split.bottomrightquarter")
            } description: {
                Text("Studio can find the walls, doors, windows and rooms in this scan and draw a dimensioned plan.")
            } actions: {
                Button("Generate Floor Plan") { Task { await session.generateBlueprint() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!session.hasGeometry || session.isBusy)
            }
        }
    }

    private func legend(_ geometry: FloorPlanGeometry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(UnitFormat.area(geometry.floorArea, units)).font(.title2.weight(.bold))
            ForEach(Array(geometry.labels.enumerated()), id: \.offset) { _, room in
                HStack {
                    Text(room.name)
                    Spacer(minLength: 16)
                    Text(room.area.map { UnitFormat.area($0, units) } ?? "—").monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            if session.blueprintIsStale {
                Label("The model changed — regenerate the plan", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(14)
        .frame(width: 240, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(16)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Toggle("Dimensions", isOn: $showDimensions)
            Toggle("Furniture", isOn: $showFurniture)
            Picker("Style", selection: $paper) {
                Text("Dark").tag(false)
                Text("Paper").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
            Divider().frame(height: 18)
            Button { setZoom(zoom / 1.3) } label: { Image(systemName: "minus.magnifyingglass") }
            Button { setZoom(zoom * 1.3) } label: { Image(systemName: "plus.magnifyingglass") }
            Button {
                withAnimation(.snappy) {
                    zoom = 1; committedZoom = 1; offset = .zero; committedOffset = .zero
                }
            } label: {
                Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
            }
        }
        .toggleStyle(.checkbox)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(16)
    }

    private func setZoom(_ value: CGFloat) {
        withAnimation(.snappy) {
            zoom = min(10, max(0.4, value))
            committedZoom = zoom
        }
    }
}
