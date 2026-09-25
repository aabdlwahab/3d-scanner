import SwiftUI

struct SettingsView: View {
    @Environment(ScanStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.unitsKey) private var units = MeasurementSystem.preferred
    @AppStorage(AppSettings.textureQualityKey) private var textureQuality = TextureQuality.standard
    @AppStorage(AppSettings.pointCloudKey) private var buildPointCloud = true
    @AppStorage(AppSettings.lockWhiteBalanceKey) private var lockWhiteBalance = true
    @State private var libraryUsage: Int64?
    @State private var exportsUsage: Int64?
    @State private var showTips = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Units") {
                    Picker("Measurements", selection: $units) {
                        ForEach(MeasurementSystem.allCases) { Text($0.title).tag($0) }
                    }
                }
                Section {
                    Picker("Texture quality", selection: $textureQuality) {
                        ForEach(TextureQuality.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Build point cloud", isOn: $buildPointCloud)
                    Toggle("Lock white balance while scanning", isOn: $lockWhiteBalance)
                } header: {
                    Text("LiDAR Processing")
                } footer: {
                    Text("\(textureQuality.detail). Locking white balance keeps colors consistent between photos. Changes apply to the next processed scan — use “Process Again” to update an existing one.")
                }
                Section {
                    LabeledContent("Scans", value: libraryUsage.map(UnitFormat.bytes) ?? "…")
                    LabeledContent("Exported files", value: exportsUsage.map(UnitFormat.bytes) ?? "…")
                    Button("Clear Exported Files", role: .destructive) {
                        try? FileManager.default.removeItem(at: AppSettings.exportsDirectory)
                        Task { await measure() }
                    }
                    .disabled((exportsUsage ?? 0) == 0)
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Exports are kept in Files › On My iPhone › ScanSpace › Exports until you clear them.")
                }
                Section("Help") {
                    Button("Scanning Tips") { showTips = true }
                    LabeledContent("Version", value: AppSettings.appVersion)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await measure() }
            .sheet(isPresented: $showTips) { ScanTipsView() }
        }
    }

    private func measure() async {
        let root = store.rootURL
        let usage = await Task.detached {
            (ScanFiles(root: root).diskUsage(), ScanFiles(root: AppSettings.exportsDirectory).diskUsage())
        }.value
        libraryUsage = usage.0
        exportsUsage = usage.1
    }
}
