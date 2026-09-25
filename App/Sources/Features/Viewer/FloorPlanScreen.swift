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

/// Renders a printable floor plan sheet (A3 landscape) as PDF or PNG.
@MainActor
enum FloorPlanExporter {
    enum RenderError: LocalizedError {
        case failed

        var errorDescription: String? { "The floor plan couldn't be rendered." }
    }

    static func render(_ data: FloorPlanData, format: ExportFormat, to url: URL, title: String, units: MeasurementSystem) throws {
        let sheet = FloorPlanSheet(plan: FloorPlanGeometry(data: data), roomCount: data.roomCount, title: title, units: units)
            .frame(width: 1190, height: 842)
        let renderer = ImageRenderer(content: sheet)
        if format == .floorPlanPDF {
            var rendered = false
            renderer.render { size, draw in
                var box = CGRect(origin: .zero, size: size)
                guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
                context.beginPDFPage(nil)
                draw(context)
                context.endPDFPage()
                context.closePDF()
                rendered = true
            }
            if !rendered { throw RenderError.failed }
        } else {
            renderer.scale = 2
            guard let image = renderer.cgImage else { throw RenderError.failed }
            try ImageFiles.writePNG(image, to: url)
        }
    }
}

struct FloorPlanSheet: View {
    let plan: FloorPlanGeometry
    let roomCount: Int
    let title: String
    let units: MeasurementSystem

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 28, weight: .bold))
                    Text("\(UnitFormat.area(plan.floorArea, units)) · \(roomCount) room\(roomCount == 1 ? "" : "s") · \(Date().formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(size: 15))
                        .foregroundColor(FloorPlanStyle.paper.secondaryText)
                }
                Spacer()
                Text("ScanSpace").font(.system(size: 15, weight: .semibold)).foregroundColor(FloorPlanStyle.paper.secondaryText)
            }
            FloorPlanCanvas(geometry: plan, style: .paper, system: units)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.08)))
            Text("Measurements are approximate (LiDAR scan). Wall lengths are measured along wall centerlines.")
                .font(.system(size: 11))
                .foregroundColor(FloorPlanStyle.paper.secondaryText)
        }
        .padding(36)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }
}
