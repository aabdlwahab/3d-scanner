import AppKit
import SwiftUI

struct SidebarView: View {
    @Binding var showImporter: Bool
    @Environment(ProjectLibrary.self) private var library
    @State private var renaming: Scan?
    @State private var newName = ""
    @State private var deleting: Scan?

    var body: some View {
        @Bindable var library = library
        List(selection: $library.selection) {
            section("LiDAR Scans", library.projects.filter { $0.kind == .lidar })
            section("Apartments", library.projects.filter { $0.kind == .room })
        }
        .listStyle(.sidebar)
        .overlay {
            if library.projects.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("No projects yet").foregroundStyle(.secondary)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Menu {
                    Button("Import…") { showImporter = true }
                    Button("New Sample Apartment") { library.createSampleApartment() }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                Text("\(library.projects.count) project\(library.projects.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .alert("Rename Project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let renaming { library.rename(renaming.id, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Project", role: .destructive) { if let deleting { library.delete(deleting.id) } }
        } message: {
            Text("The project and its edits are removed from this Mac.")
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ scans: [Scan]) -> some View {
        if !scans.isEmpty {
            Section(title) {
                ForEach(scans) { scan in
                    ProjectRow(scan: scan, thumbnail: library.files(for: scan.id).thumbnail,
                               revision: library.thumbnailRevision[scan.id] ?? 0)
                        .tag(scan.id)
                        .contextMenu {
                            Button("Rename…") { newName = scan.name; renaming = scan }
                            Button("Show in Finder") { library.revealInFinder(scan.id) }
                            Divider()
                            Button("Delete…", role: .destructive) { deleting = scan }
                        }
                }
            }
        }
    }
}

struct ProjectRow: View {
    let scan: Scan
    let thumbnail: URL
    let revision: Int
    @AppStorage("units") private var units = MeasurementSystem.preferred

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let image = NSImage(contentsOf: thumbnail), revision >= 0 {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: scan.kind.systemImage).font(.title3).foregroundStyle(.secondary)
                }
            }
            .frame(width: 52, height: 40)
            .background(Color.black.opacity(0.25))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(scan.name).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    private var subtitle: String {
        switch scan.status {
        case .needsProcessing: return "Not processed"
        case .processing: return "Processing…"
        case .failed: return "Processing failed"
        case .ready: break
        }
        if let area = scan.stats.floorArea { return UnitFormat.area(area, units) + " · " + scan.createdAt.formatted(date: .abbreviated, time: .omitted) }
        if scan.stats.triangleCount > 0 { return "\(UnitFormat.count(scan.stats.triangleCount)) triangles" }
        if scan.stats.pointCount > 0 { return "\(UnitFormat.count(scan.stats.pointCount)) points" }
        return scan.createdAt.formatted(date: .abbreviated, time: .shortened)
    }
}

struct WelcomeView: View {
    @Binding var showImporter: Bool
    @Environment(ProjectLibrary.self) private var library

    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
            VStack(spacing: 6) {
                Text("ScanSpace Studio").font(.largeTitle.weight(.bold))
                Text("View, clean and measure your LiDAR scans, and turn them into floor plans.")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button {
                    showImporter = true
                } label: {
                    Label("Import…", systemImage: "square.and.arrow.down").frame(minWidth: 150)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                Button {
                    library.createSampleApartment()
                } label: {
                    Label("Open the Sample Apartment", systemImage: "house").frame(minWidth: 200)
                }
                .controlSize(.large)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("On your iPhone, open a scan in ScanSpace and choose **Export › ScanSpace Studio (Mac)**.", systemImage: "iphone")
                    Label("AirDrop the `.scanspace` file to this Mac, then drop it on this window or double-click it.", systemImage: "airplayaudio")
                    Label("PLY, OBJ, STL and USDZ files from other apps work too.", systemImage: "cube")
                }
                .font(.callout)
                .padding(6)
                .frame(maxWidth: 520, alignment: .leading)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
