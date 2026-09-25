import Observation
import RoomPlan
import SwiftUI

@MainActor
@Observable
final class RoomCaptureModel {
    enum Phase: Equatable {
        case unsupported, scanning, processingRoom, reviewing, building
        case failed(String)
    }

    private(set) var phase: Phase
    private(set) var rooms: [CapturedRoom] = []
    private(set) var counts = RoomCaptureController.LiveCounts()
    let controller = RoomCaptureController()
    private let startedAt = Date()

    init() {
        phase = RoomCaptureController.isSupported ? .scanning : .unsupported
        controller.onCounts = { [weak self] counts in self?.counts = counts }
        controller.onRoomCaptured = { [weak self] room in
            guard let self else { return }
            self.rooms.append(room)
            self.phase = .reviewing
            Haptics.success()
        }
        controller.onFailure = { [weak self] message in
            guard let self else { return }
            // A failed room shouldn't lose the rooms already captured.
            self.phase = self.rooms.isEmpty ? .failed(message) : .reviewing
        }
    }

    func appear() {
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func disappear() {
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func finishRoom() {
        guard phase == .scanning else { return }
        phase = .processingRoom
        Haptics.impact()
        controller.finishRoom()
    }

    func scanNextRoom() {
        guard phase == .reviewing else { return }
        counts = RoomCaptureController.LiveCounts()
        phase = .scanning
        controller.startRoom()
    }

    /// Merges all rooms into one structure, exports it and adds it to the library.
    func save(store: ScanStore) async -> UUID? {
        guard !rooms.isEmpty else { return nil }
        phase = .building
        controller.stopEverything()
        let rooms = self.rooms
        let duration = Date().timeIntervalSince(startedAt)
        let scan: Scan, files: ScanFiles
        do {
            (scan, files) = try store.prepareCapture(kind: .room)
        } catch {
            phase = .failed("Couldn't create the scan: \(error.localizedDescription)")
            return nil
        }
        do {
            let data: FloorPlanData
            do {
                data = try await Self.exportStructure(of: rooms, to: files)
            } catch where rooms.count == 1 {
                // Merging can fail for a single room — export it on its own.
                data = try await Self.exportRoom(rooms[0], to: files)
            }
            try data.write(to: files.floorPlan)

            let plan = FloorPlanGeometry(data: data)
            let bounds = RoomSceneBuilder.makeModel(for: data).bounds.size
            var saved = scan
            saved.status = .ready
            saved.stats.floorArea = plan.floorArea
            saved.stats.roomCount = data.roomCount
            saved.stats.wallCount = data.walls.count
            saved.stats.doorCount = data.doors.count
            saved.stats.windowCount = data.windows.count
            saved.stats.objectCount = data.objects.count
            saved.stats.bounds = [Double(bounds.x), Double(bounds.y), Double(bounds.z)]
            saved.stats.captureDuration = duration
            store.add(saved)
            ThumbnailRenderer.renderModelThumbnail(for: saved.id, store: store)
            return saved.id
        } catch {
            store.discardCapture(scan.id)
            phase = .failed("Couldn't build the apartment model: \(error.localizedDescription)")
            return nil
        }
    }

    /// Merges the rooms and writes the RoomPlan USDZ and JSON.
    private static func exportStructure(of rooms: [CapturedRoom], to files: ScanFiles) async throws -> FloorPlanData {
        let structure = try await StructureBuilder(options: [.beautifyObjects]).capturedStructure(from: rooms)
        try await Task.detached(priority: .userInitiated) {
            try structure.export(to: files.roomUSDZ, exportOptions: .mesh)
            try JSONEncoder().encode(structure).write(to: files.roomStructure, options: .atomic)
        }.value
        return FloorPlanData(structure: structure)
    }

    private static func exportRoom(_ room: CapturedRoom, to files: ScanFiles) async throws -> FloorPlanData {
        try await Task.detached(priority: .userInitiated) {
            try room.export(to: files.roomUSDZ, exportOptions: .mesh)
            try JSONEncoder().encode(room).write(to: files.roomStructure, options: .atomic)
        }.value
        return FloorPlanData(room: room)
    }
}

/// Room-by-room apartment capture with RoomPlan.
struct RoomCaptureScreen: View {
    let onFinish: (UUID?) -> Void
    @Environment(ScanStore.self) private var store
    @State private var model = RoomCaptureModel()
    @State private var confirmDiscard = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.phase != .unsupported {
                RoomCaptureRepresentable(controller: model.controller).ignoresSafeArea()
            }
            VStack(spacing: 12) {
                topBar
                Spacer()
                bottomPanel
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            overlay
        }
        .statusBarHidden()
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
        .confirmationDialog("Discard \(model.rooms.count == 1 ? "the captured room" : "\(model.rooms.count) captured rooms")?",
                            isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { onFinish(nil) }
            Button("Keep Scanning", role: .cancel) {}
        }
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            CircleIconButton(systemImage: "xmark") {
                if model.rooms.isEmpty { onFinish(nil) } else { confirmDiscard = true }
            }
            Spacer()
            if model.phase == .scanning {
                VStack(spacing: 6) {
                    StatPill(systemImage: "door.left.hand.open", text: "Room \(model.rooms.count + 1)")
                    HStack(spacing: 6) {
                        StatPill(systemImage: "square.split.bottomrightquarter", text: "\(model.counts.walls)")
                        StatPill(systemImage: "door.left.hand.closed", text: "\(model.counts.doors)")
                        StatPill(systemImage: "window.vertical.closed", text: "\(model.counts.windows)")
                        StatPill(systemImage: "sofa", text: "\(model.counts.objects)")
                    }
                }
            }
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var bottomPanel: some View {
        switch model.phase {
        case .scanning:
            VStack(spacing: 12) {
                Text("Walk around the room and point at every wall, door, window and piece of furniture.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center)
                Button {
                    model.finishRoom()
                } label: {
                    Label("Done with this room", systemImage: "checkmark")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Capsule())
            }
            .padding(.bottom, 8)
        case .reviewing:
            VStack(spacing: 12) {
                Text("\(model.rooms.count) room\(model.rooms.count == 1 ? "" : "s") captured")
                    .font(.headline)
                Text("To add another room, walk there with the camera pointed at the floor so the rooms stay aligned, then tap Scan Next Room.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button {
                        model.scanNextRoom()
                    } label: {
                        Label("Scan Next Room", systemImage: "plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        Task {
                            if let id = await model.save(store: store) { onFinish(id) }
                        }
                    } label: {
                        Label("Finish", systemImage: "checkmark")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(18)
            .glassPanel(cornerRadius: 24)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch model.phase {
        case .processingRoom:
            ProgressCard(title: "Processing room…", message: "RoomPlan is straightening walls and detecting furniture")
        case .building:
            ProgressCard(title: "Building your apartment…", message: "Merging \(model.rooms.count) room\(model.rooms.count == 1 ? "" : "s") into one model")
        case .failed(let message):
            MessageCard(systemImage: "exclamationmark.triangle.fill", title: "Scan stopped", message: message, buttonTitle: "Close") {
                onFinish(nil)
            }
        case .unsupported:
            MessageCard(systemImage: "sensor.tag.radiowaves.forward", title: "LiDAR required",
                        message: "Room Plan needs an iPhone or iPad Pro with a LiDAR Scanner.", buttonTitle: "Close") {
                onFinish(nil)
            }
        default:
            EmptyView()
        }
    }
}

struct RoomCaptureRepresentable: UIViewControllerRepresentable {
    let controller: RoomCaptureController

    func makeUIViewController(context: Context) -> RoomCaptureController { controller }
    func updateUIViewController(_ uiViewController: RoomCaptureController, context: Context) {}
}
