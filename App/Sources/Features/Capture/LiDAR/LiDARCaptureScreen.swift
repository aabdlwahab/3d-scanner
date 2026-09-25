import ARKit
import Observation
import SwiftUI

@MainActor
@Observable
final class LiDARCaptureModel {
    enum Phase: Equatable {
        case unsupported, ready, recording, saving
        case failed(String)
    }

    private(set) var phase: Phase
    private(set) var status = LiDARSessionController.Status()
    private(set) var elapsed: TimeInterval = 0
    var overlayStyle: MeshOverlayStyle = .mesh {
        didSet { controller.overlay.setStyle(overlayStyle) }
    }

    /// Created on first use: SwiftUI may evaluate `@State` initial values more than once, and an
    /// ARSCNView is expensive to create.
    @ObservationIgnored private(set) lazy var controller: LiDARSessionController = {
        let controller = LiDARSessionController()
        controller.onStatus = { [weak self] status in self?.status = status }
        controller.onFailure = { [weak self] message in self?.phase = .failed(message) }
        return controller
    }()
    @ObservationIgnored private var pending: (scan: Scan, files: ScanFiles)?
    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private var timer: Timer?

    init() {
        phase = LiDARSessionController.isSupported ? .ready : .unsupported
    }

    func appear() {
        guard phase != .unsupported else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        controller.startPreview()
    }

    func disappear() {
        UIApplication.shared.isIdleTimerDisabled = false
        timer?.invalidate()
        controller.pause()
    }

    func startRecording(store: ScanStore) {
        guard phase == .ready else { return }
        do {
            pending = try store.prepareCapture(kind: .lidar)
        } catch {
            phase = .failed("Couldn't create the scan: \(error.localizedDescription)")
            return
        }
        controller.startRecording(rawDirectory: pending!.files.rawDirectory, lockWhiteBalance: AppSettings.lockWhiteBalance)
        startedAt = Date()
        elapsed = 0
        phase = .recording
        Haptics.impact()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    /// Saves the raw capture and adds the scan to the library. Returns its id.
    func finish(store: ScanStore) async -> UUID? {
        guard phase == .recording, let pending else { return nil }
        phase = .saving
        timer?.invalidate()
        Haptics.impact()
        let capture = controller.stopRecording()
        let duration = elapsed
        let files = pending.files
        do {
            let summary = try await Task.detached(priority: .userInitiated) { () -> (triangles: Int, keyframes: Int, area: Double) in
                let mesh = MeshExtractor.rawMesh(from: capture.anchors)
                guard mesh.triangleCount > 0 else { throw ProcessingError.emptyMesh }
                try mesh.write(to: files.rawMesh)
                let frames = capture.recorder?.finish() ?? []
                try KeyframeIndex(frames: frames).write(to: files.framesIndex)
                ThumbnailRenderer.writeKeyframeThumbnail(files: files, records: frames)
                return (mesh.triangleCount, frames.count, MeshMath.surfaceArea(positions: mesh.positions, indices: mesh.indices))
            }.value
            var scan = pending.scan
            scan.status = .needsProcessing
            scan.stats.triangleCount = summary.triangles
            scan.stats.keyframeCount = summary.keyframes
            scan.stats.surfaceArea = summary.area
            scan.stats.captureDuration = duration
            store.add(scan)
            self.pending = nil
            return scan.id
        } catch {
            store.discardCapture(pending.scan.id)
            self.pending = nil
            phase = .failed(error.localizedDescription)
            return nil
        }
    }

    func cancel(store: ScanStore) {
        timer?.invalidate()
        _ = controller.stopRecording()
        if let pending { store.discardCapture(pending.scan.id) }
        pending = nil
    }
}

/// Full-screen LiDAR scanning: camera feed with the live mesh, stats and a record button.
struct LiDARCaptureScreen: View {
    let onFinish: (UUID?) -> Void
    @Environment(ScanStore.self) private var store
    @State private var model = LiDARCaptureModel()
    @State private var confirmDiscard = false
    @AppStorage(AppSettings.unitsKey) private var units = MeasurementSystem.preferred

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.phase != .unsupported {
                ARSceneViewContainer(view: model.controller.sceneView).ignoresSafeArea()
            }
            VStack(spacing: 12) {
                topBar
                Spacer()
                guidance
                bottomBar
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            overlays
        }
        .statusBarHidden()
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
        .confirmationDialog("Discard this scan?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard Scan", role: .destructive) {
                model.cancel(store: store)
                onFinish(nil)
            }
            Button("Keep Scanning", role: .cancel) {}
        }
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            CircleIconButton(systemImage: "xmark") {
                if model.phase == .recording { confirmDiscard = true } else { onFinish(nil) }
            }
            Spacer()
            if model.phase == .recording || model.phase == .saving {
                VStack(spacing: 6) {
                    StatPill(systemImage: "record.circle", text: UnitFormat.duration(model.elapsed))
                    HStack(spacing: 6) {
                        StatPill(systemImage: "square.dashed", text: UnitFormat.area(Double(model.status.meshArea), units))
                        StatPill(systemImage: "photo.stack", text: "\(model.status.keyframes)")
                    }
                }
            }
            Spacer()
            Menu {
                Picker("Overlay", selection: $model.overlayStyle) {
                    ForEach(MeshOverlayStyle.allCases) { style in
                        Label(style.title, systemImage: style.systemImage).tag(style)
                    }
                }
            } label: {
                Image(systemName: model.overlayStyle.systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.surfaceStroke))
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var guidance: some View {
        if let message = model.status.guidance ?? model.status.tracking, model.phase == .recording || model.phase == .ready {
            Label(message, systemImage: model.status.guidance != nil ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
                .transition(.opacity)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 14) {
            Text(hint)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 24)
            RecordButton(isRecording: model.phase == .recording, isEnabled: model.phase == .ready || model.phase == .recording) {
                switch model.phase {
                case .ready:
                    model.startRecording(store: store)
                case .recording:
                    Task {
                        if let id = await model.finish(store: store) { onFinish(id) }
                    }
                default:
                    break
                }
            }
        }
        .padding(.bottom, 12)
    }

    private var hint: String {
        switch model.phase {
        case .ready: "Stand in the room and tap record. Walk slowly and sweep walls, floor, ceiling and furniture from a few heights."
        case .recording: "Keep surfaces 0.5–3 m away and cover gaps in the mesh. Tap stop when everything is covered."
        default: ""
        }
    }

    @ViewBuilder
    private var overlays: some View {
        switch model.phase {
        case .saving:
            ProgressCard(title: "Saving scan…", message: "Packing the mesh and \(model.status.keyframes) photos")
        case .failed(let message):
            MessageCard(systemImage: "exclamationmark.triangle.fill", title: "Scan stopped", message: message, buttonTitle: "Close") {
                onFinish(nil)
            }
        case .unsupported:
            MessageCard(systemImage: "sensor.tag.radiowaves.forward", title: "LiDAR required",
                        message: "LiDAR scanning needs an iPhone or iPad Pro with a LiDAR Scanner (iPhone 12 Pro or newer Pro models).",
                        buttonTitle: "Close") { onFinish(nil) }
        default:
            EmptyView()
        }
    }
}

struct RecordButton: View {
    let isRecording: Bool
    var isEnabled = true
    let action: () -> Void
    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 4).frame(width: 78, height: 78)
                if isRecording {
                    Circle().stroke(Theme.recording.opacity(0.5), lineWidth: 3)
                        .frame(width: 92, height: 92)
                        .scaleEffect(pulse ? 1.12 : 0.95)
                        .opacity(pulse ? 0 : 1)
                        .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: pulse)
                }
                RoundedRectangle(cornerRadius: isRecording ? 8 : 32, style: .continuous)
                    .fill(Theme.recording)
                    .frame(width: isRecording ? 30 : 64, height: isRecording ? 30 : 64)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isRecording)
            }
            .frame(width: 96, height: 96)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(isRecording ? "Stop scanning" : "Start scanning")
        .onAppear { pulse = true }
    }
}

struct ProgressCard: View {
    let title: String
    let message: String
    var progress: Double?

    var body: some View {
        VStack(spacing: 14) {
            if let progress {
                ProgressRing(progress: progress, lineWidth: 5).frame(width: 54, height: 54)
            } else {
                ProgressView().controlSize(.large).tint(.white)
            }
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: 300)
        .glassPanel(cornerRadius: 24)
    }
}

struct MessageCard: View {
    let systemImage: String
    let title: String
    let message: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(Theme.accentGradient)
            Text(title).font(.title3.weight(.bold))
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 4)
        }
        .padding(26)
        .frame(maxWidth: 320)
        .glassPanel(cornerRadius: 26)
        .padding(24)
    }
}

/// Hosts an existing UIKit view (the controller owns it so it survives SwiftUI updates).
struct ARSceneViewContainer: UIViewRepresentable {
    let view: UIView

    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
