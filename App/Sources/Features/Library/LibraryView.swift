import ARKit
import SwiftUI

struct LibraryView: View {
    @Environment(ScanStore.self) private var store
    @Environment(ProcessingCenter.self) private var processing
    @State private var path: [UUID] = []
    @State private var showNewScan = false
    @State private var showSettings = false
    @State private var capture: ScanKind?
    @State private var renameTarget: Scan?
    @State private var newName = ""
    @State private var deleteTarget: Scan?

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .bottom) {
                Theme.backdrop.ignoresSafeArea()
                if store.scans.isEmpty {
                    EmptyLibraryView { showNewScan = true }
                } else {
                    ScrollView {
                        if !LiDARSessionController.isSupported { unsupportedBanner }
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(store.scans) { scan in
                                NavigationLink(value: scan.id) {
                                    ScanCard(scan: scan, progress: processing.progress(for: scan.id),
                                             thumbnailRevision: store.thumbnailRevision[scan.id] ?? 0,
                                             thumbnailURL: store.files(for: scan.id).thumbnail)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button { newName = scan.name; renameTarget = scan } label: { Label("Rename", systemImage: "pencil") }
                                    Button(role: .destructive) { deleteTarget = scan } label: { Label("Delete", systemImage: "trash") }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 120)
                    }
                }
                NewScanButton { showNewScan = true }
                    .padding(.bottom, 18)
            }
            .navigationTitle("ScanSpace")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .navigationDestination(for: UUID.self) { ScanDetailView(scanID: $0) }
        }
        .sheet(isPresented: $showNewScan) {
            NewScanSheet { kind in
                showNewScan = false
                // Let the sheet finish dismissing before covering the screen.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { capture = kind }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .fullScreenCover(item: $capture) { kind in
            Group {
                switch kind {
                case .lidar: LiDARCaptureScreen { finishCapture($0, kind: kind) }
                case .room: RoomCaptureScreen { finishCapture($0, kind: kind) }
                }
            }
            .environment(store)
            .environment(processing)
        }
        .alert("Rename Scan", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") { if let target = renameTarget { store.rename(target.id, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(deleteTarget?.name ?? "")”?",
                            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Scan", role: .destructive) { if let target = deleteTarget { store.delete(target.id) } }
        }
    }

    private var unsupportedBanner: some View {
        Label("This device has no LiDAR Scanner, so it can view and export scans but not capture new ones.",
              systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel(cornerRadius: 16)
            .padding(.horizontal, 16)
    }

    private func finishCapture(_ id: UUID?, kind: ScanKind) {
        capture = nil
        guard let id else { return }
        if kind == .lidar { processing.process(id, store: store) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { path = [id] }
    }
}

struct ScanCard: View {
    let scan: Scan
    let progress: ProcessingProgress?
    let thumbnailRevision: Int
    let thumbnailURL: URL
    @AppStorage(AppSettings.unitsKey) private var units = MeasurementSystem.preferred

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.10), Color.white.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                if let image = ThumbnailCache.shared.image(for: thumbnailURL, revision: thumbnailRevision) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: scan.kind.systemImage)
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Theme.accentGradient)
                }
                if let progress {
                    Color.black.opacity(0.45)
                    VStack(spacing: 8) {
                        ProgressRing(progress: progress.fraction).frame(width: 36, height: 36)
                        Text(progress.stage).font(.caption2.weight(.semibold)).multilineTextAlignment(.center)
                    }
                    .padding(8)
                } else if scan.status == .failed {
                    Color.black.opacity(0.45)
                    Label("Failed", systemImage: "exclamationmark.triangle.fill").font(.caption.weight(.semibold))
                } else if scan.status == .needsProcessing {
                    Color.black.opacity(0.45)
                    Label("Not processed", systemImage: "wand.and.stars").font(.caption.weight(.semibold))
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .topLeading) {
                Image(systemName: scan.kind.systemImage)
                    .font(.caption.weight(.bold))
                    .padding(7)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(8)
            }
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.surfaceStroke))

            VStack(alignment: .leading, spacing: 2) {
                Text(scan.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
    }

    private var subtitle: String {
        let date = scan.createdAt.formatted(date: .abbreviated, time: .omitted)
        switch scan.kind {
        case .room:
            let area = scan.stats.floorArea.map { UnitFormat.area($0, units) } ?? ""
            let rooms = scan.stats.roomCount.map { "\($0) room\($0 == 1 ? "" : "s")" } ?? ""
            return [area, rooms, date].filter { !$0.isEmpty }.joined(separator: " · ")
        case .lidar:
            let area = scan.stats.surfaceArea > 0 ? UnitFormat.area(scan.stats.surfaceArea, units) : ""
            return [area, date].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }
}

struct NewScanButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("New Scan", systemImage: "viewfinder")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 26)
                .frame(height: 56)
                .background(Theme.accentGradient, in: Capsule())
                .shadow(color: Theme.accent.opacity(0.45), radius: 18, y: 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start a new scan")
    }
}

struct EmptyLibraryView: View {
    let action: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Theme.accent.opacity(0.14)).frame(width: 150, height: 150)
                Image(systemName: "cube.transparent")
                    .font(.system(size: 64, weight: .thin))
                    .foregroundStyle(Theme.accentGradient)
            }
            Text("Scan your first space").font(.title2.weight(.bold))
            Text("Capture a photo-textured 3D model with LiDAR, or map a whole apartment room by room with dimensions and a floor plan.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
        }
        .padding(.bottom, 90)
    }
}

extension ScanKind {
    var tagline: String {
        switch self {
        case .lidar: "Photo-textured 3D mesh of rooms, objects and spaces"
        case .room: "Clean apartment model with dimensions and a floor plan"
        }
    }
}
