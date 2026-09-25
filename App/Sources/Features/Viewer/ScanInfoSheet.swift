import SwiftUI

struct ScanInfoSheet: View {
    let scanID: UUID
    @Environment(ScanStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.unitsKey) private var units = MeasurementSystem.preferred
    @State private var diskUsage: Int64?
    @State private var rawUsage: Int64?
    @State private var confirmDeleteRaw = false

    var body: some View {
        NavigationStack {
            if let scan = store.scan(scanID) {
                List {
                    Section("Scan") {
                        row("Type", scan.kind.title)
                        row("Captured", scan.createdAt.formatted(date: .abbreviated, time: .shortened))
                        if scan.stats.captureDuration > 0 { row("Capture time", UnitFormat.duration(scan.stats.captureDuration)) }
                        if let bounds = scan.stats.bounds, bounds.count == 3 {
                            row("Size (W × H × D)", UnitFormat.dimensions(bounds, units))
                        }
                    }
                    if scan.kind == .room {
                        Section("Apartment") {
                            if let area = scan.stats.floorArea { row("Floor area", UnitFormat.area(area, units)) }
                            if let rooms = scan.stats.roomCount { row("Rooms", "\(rooms)") }
                            if let walls = scan.stats.wallCount { row("Walls", "\(walls)") }
                            if let doors = scan.stats.doorCount { row("Doors", "\(doors)") }
                            if let windows = scan.stats.windowCount { row("Windows", "\(windows)") }
                            if let objects = scan.stats.objectCount { row("Furniture", "\(objects)") }
                        }
                    } else {
                        Section("Model") {
                            row("Surface area", UnitFormat.area(scan.stats.surfaceArea, units))
                            row("Triangles", UnitFormat.count(scan.stats.triangleCount))
                            if scan.stats.vertexCount > 0 { row("Vertices", UnitFormat.count(scan.stats.vertexCount)) }
                            row("Photos", "\(scan.stats.keyframeCount)")
                            if scan.stats.textureCount > 0 { row("Textures", "\(scan.stats.textureCount) × 4K") }
                            if scan.stats.pointCount > 0 { row("Points", UnitFormat.count(scan.stats.pointCount)) }
                        }
                    }
                    Section {
                        row("Storage", diskUsage.map(UnitFormat.bytes) ?? "…")
                        if scan.kind == .lidar, let rawUsage, rawUsage > 0 {
                            row("Raw capture", UnitFormat.bytes(rawUsage))
                            Button("Delete Raw Capture…", role: .destructive) { confirmDeleteRaw = true }
                        }
                    } header: {
                        Text("Storage")
                    } footer: {
                        if scan.kind == .lidar {
                            Text("The raw capture (photos and depth) is needed to process the scan again with different settings.")
                        }
                    }
                }
                .navigationTitle(scan.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .task { await measure() }
                .confirmationDialog("Delete the raw capture?", isPresented: $confirmDeleteRaw, titleVisibility: .visible) {
                    Button("Delete Raw Capture", role: .destructive) {
                        store.deleteRawData(scanID)
                        Task { await measure() }
                    }
                } message: {
                    Text("The model stays, but you won't be able to process this scan again.")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }

    private func measure() async {
        let files = store.files(for: scanID)
        let usage = await Task.detached { (files.diskUsage(), files.rawDataUsage()) }.value
        diskUsage = usage.0
        rawUsage = usage.1
    }
}
