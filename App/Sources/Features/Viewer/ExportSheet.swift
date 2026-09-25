import SwiftUI

struct ExportSheet: View {
    let scan: Scan
    @Environment(ScanStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var working: ExportFormat?
    @State private var errorMessage: String?
    @AppStorage(AppSettings.unitsKey) private var units = MeasurementSystem.preferred

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(ExportFormat.formats(for: scan.kind)) { format in
                        Button {
                            export(format)
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: format.systemImage)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(Theme.accentGradient)
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(format.title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                                    Text(format.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if working == format {
                                    ProgressView()
                                } else {
                                    Image(systemName: "square.and.arrow.up").foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .disabled(working != nil || !isAvailable(format))
                    }
                } footer: {
                    Text("Exported files are also kept in Files › On My iPhone › ScanSpace › Exports.")
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("Export failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func isAvailable(_ format: ExportFormat) -> Bool {
        let files = store.files(for: scan.id)
        switch format {
        case .pointCloud: return files.hasPointCloud
        case .rawCapture: return files.hasRawCapture
        default: return scan.kind == .room || files.hasTexturedModel
        }
    }

    private func export(_ format: ExportFormat) {
        working = format
        let title = scan.name
        let units = units
        let exporter = ScanExporter(
            scan: scan, files: store.files(for: scan.id), outputDirectory: AppSettings.exportsDirectory,
            floorPlanRenderer: { data, format, url in
                try MainActor.assumeIsolated {
                    try FloorPlanExporter.render(data, format: format, to: url, title: title, units: units)
                }
            })
        Task {
            let result: Result<URL, Error>
            if format == .floorPlanPDF || format == .floorPlanPNG {
                // Floor plans are drawn with SwiftUI, which has to happen on the main actor.
                result = Result { try exporter.export(format) }
            } else {
                result = await Task.detached(priority: .userInitiated) { Result { try exporter.export(format) } }.value
            }
            working = nil
            switch result {
            case .success(let url):
                Haptics.success()
                Presenters.share([url])
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }
}
