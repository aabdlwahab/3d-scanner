import SwiftUI

/// Full-screen, zoomable 2D floor plan for room scans.
struct FloorPlanScreen: View {
    let scan: Scan
    @Environment(ScanStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.unitsKey) private var units = MeasurementSystem.preferred
    @State private var plan: FloorPlanGeometry?
    @State private var data: FloorPlanData?
    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero
    @State private var showDimensions = true
    @State private var showFurniture = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                FloorPlanStyle.dark.background.ignoresSafeArea()
                if let plan {
                    FloorPlanCanvas(geometry: plan, style: .dark, system: units, zoom: zoom, offset: offset,
                                    showDimensions: showDimensions, showObjects: showFurniture)
                        .ignoresSafeArea(edges: .bottom)
                        .gesture(
                            MagnifyGesture()
                                .onChanged { zoom = min(8, max(0.5, committedZoom * $0.magnification)) }
                                .onEnded { _ in committedZoom = zoom }
                                .simultaneously(with: DragGesture()
                                    .onChanged { offset = CGSize(width: committedOffset.width + $0.translation.width,
                                                                 height: committedOffset.height + $0.translation.height) }
                                    .onEnded { _ in committedOffset = offset })
                        )
                        .onTapGesture(count: 2) {
                            withAnimation(.spring) {
                                zoom = 1; committedZoom = 1; offset = .zero; committedOffset = .zero
                            }
                        }
                    VStack {
                        summary(plan)
                        Spacer()
                    }
                    .padding()
                } else {
                    ProgressView().tint(.white)
                }
            }
            .navigationTitle("Floor Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Units", selection: $units) {
                            ForEach(MeasurementSystem.allCases) { Text($0.title).tag($0) }
                        }
                        Toggle("Dimensions", isOn: $showDimensions)
                        Toggle("Furniture", isOn: $showFurniture)
                        Divider()
                        Button { share(.floorPlanPDF) } label: { Label("Share PDF", systemImage: "doc.richtext") }
                        Button { share(.floorPlanPNG) } label: { Label("Share Image", systemImage: "photo") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .alert("Couldn't export", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .task {
            if let loaded = try? FloorPlanData.read(from: store.files(for: scan.id).floorPlan) {
                data = loaded
                plan = FloorPlanGeometry(data: loaded)
            }
        }
    }

    private func summary(_ plan: FloorPlanGeometry) -> some View {
        HStack(spacing: 8) {
            StatPill(systemImage: "square.dashed", text: UnitFormat.area(plan.floorArea, units))
            if let rooms = data?.roomCount {
                StatPill(systemImage: "door.left.hand.open", text: "\(rooms) room\(rooms == 1 ? "" : "s")")
            }
            StatPill(systemImage: "ruler", text: UnitFormat.length(plan.totalWallLength, units) + " walls")
        }
    }

    private func share(_ format: ExportFormat) {
        guard let data else { return }
        let url = AppSettings.exportsDirectory.appendingPathComponent(
            "\(ScanExporter.fileName(for: scan.name))-floor-plan.\(format == .floorPlanPDF ? "pdf" : "png")")
        do {
            try FileManager.default.createDirectory(at: AppSettings.exportsDirectory, withIntermediateDirectories: true)
            try FloorPlanExporter.render(data, format: format, to: url, title: scan.name, units: units)
            Presenters.share([url])
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
