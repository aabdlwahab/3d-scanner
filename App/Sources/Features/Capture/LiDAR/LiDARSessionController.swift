import ARKit
import AVFoundation
import SceneKit
import UIKit

/// Owns the ARSCNView/ARSession for LiDAR capture: runs scene reconstruction, draws the live
/// mesh and feeds frames to the ``KeyframeRecorder``.
@MainActor
final class LiDARSessionController: NSObject, ARSessionDelegate, ARSCNViewDelegate {
    struct Status: Equatable {
        var tracking: String?
        var guidance: String?
        var keyframes = 0
        var meshArea: Float = 0
    }

    struct Capture {
        var anchors: [ARMeshAnchor]
        var recorder: KeyframeRecorder?
    }

    let sceneView = ARSCNView(frame: .zero)
    let overlay = MeshOverlayRenderer()
    var onStatus: ((Status) -> Void)?
    var onFailure: ((String) -> Void)?

    private let coachingView = ARCoachingOverlayView()
    private var recorder: KeyframeRecorder?
    private var trackingMessage: String? = "Initializing…"
    private var lastStatusUpdate: TimeInterval = 0
    private var whiteBalanceLocked = false

    static var isSupported: Bool {
        ARWorldTrackingConfiguration.isSupported && ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    override init() {
        super.init()
        sceneView.delegate = self
        sceneView.session.delegate = self
        sceneView.automaticallyUpdatesLighting = true
        sceneView.autoenablesDefaultLighting = true
        sceneView.rendersCameraGrain = false
        sceneView.rendersMotionBlur = false
        sceneView.antialiasingMode = .multisampling4X
        sceneView.preferredFramesPerSecond = 60

        coachingView.session = sceneView.session
        coachingView.goal = .tracking
        coachingView.activatesAutomatically = true
        coachingView.translatesAutoresizingMaskIntoConstraints = false
        sceneView.addSubview(coachingView)
        NSLayoutConstraint.activate([
            coachingView.leadingAnchor.constraint(equalTo: sceneView.leadingAnchor),
            coachingView.trailingAnchor.constraint(equalTo: sceneView.trailingAnchor),
            coachingView.topAnchor.constraint(equalTo: sceneView.topAnchor),
            coachingView.bottomAnchor.constraint(equalTo: sceneView.bottomAnchor),
        ])
    }

    // MARK: - Session control

    /// Camera preview with tracking only (no meshing) while the user frames the first shot.
    func startPreview() {
        sceneView.session.run(configuration(reconstruction: false))
    }

    func startRecording(rawDirectory: URL, lockWhiteBalance: Bool) {
        overlay.reset()
        recorder = KeyframeRecorder(rawDirectory: rawDirectory)
        sceneView.session.run(configuration(reconstruction: true), options: [.resetSceneReconstruction, .removeExistingAnchors])
        if lockWhiteBalance { setWhiteBalanceLocked(true) }
    }

    /// Stops meshing and returns everything needed to save the scan.
    func stopRecording() -> Capture {
        let anchors = sceneView.session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
        let capture = Capture(anchors: anchors, recorder: recorder)
        recorder = nil
        sceneView.session.pause()
        setWhiteBalanceLocked(false)
        return capture
    }

    func pause() {
        recorder = nil
        sceneView.session.pause()
        setWhiteBalanceLocked(false)
    }

    private func configuration(reconstruction: Bool) -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        configuration.environmentTexturing = .none
        configuration.isLightEstimationEnabled = true
        if reconstruction {
            configuration.sceneReconstruction = ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
                ? .meshWithClassification : .mesh
            var semantics: ARConfiguration.FrameSemantics = []
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) { semantics.insert(.sceneDepth) }
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) { semantics.insert(.smoothedSceneDepth) }
            configuration.frameSemantics = semantics
        }
        return configuration
    }

    /// Locking white balance keeps colors consistent between keyframes (fewer texture seams).
    private func setWhiteBalanceLocked(_ locked: Bool) {
        guard locked != whiteBalanceLocked,
              let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else { return }
        do {
            try device.lockForConfiguration()
            if locked, device.isWhiteBalanceModeSupported(.locked) {
                device.whiteBalanceMode = .locked
            } else if !locked, device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            device.unlockForConfiguration()
            whiteBalanceLocked = locked
        } catch {
            whiteBalanceLocked = false
        }
    }

    // MARK: - ARSessionDelegate (main queue)

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        MainActor.assumeIsolated { handle(frame) }
    }

    // Observer callbacks can also arrive through ARSCNView's delegate forwarding, so hop to the
    // main actor explicitly instead of assuming the calling thread.
    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let message = Self.message(for: camera.trackingState)
        Task { @MainActor in self.trackingMessage = message }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let message = Self.message(for: error)
        Task { @MainActor in self.onFailure?(message) }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor in self.trackingMessage = "Paused — return to the app to continue" }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor in self.trackingMessage = "Resuming — point at an area you already scanned" }
    }

    nonisolated func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }

    private func handle(_ frame: ARFrame) {
        recorder?.process(frame)
        guard frame.timestamp - lastStatusUpdate > 0.25 else { return }
        lastStatusUpdate = frame.timestamp
        onStatus?(Status(tracking: trackingMessage, guidance: guidance(for: frame),
                         keyframes: recorder?.count ?? 0, meshArea: overlay.totalArea))
    }

    private func guidance(for frame: ARFrame) -> String? {
        guard let recorder else { return nil }
        if recorder.motion.angularSpeed > 1.2 || recorder.motion.linearSpeed > 0.8 { return "Slow down" }
        if let light = frame.lightEstimate, light.ambientIntensity < 180 { return "Turn on more lights" }
        if let depth = (frame.smoothedSceneDepth ?? frame.sceneDepth)?.depthMap, let center = Self.centerDepth(depth), center < 0.25 {
            return "Too close — step back"
        }
        if recorder.count >= KeyframeRecorder.maxKeyframes { return "Photo limit reached — finish soon" }
        return nil
    }

    // MARK: - ARSCNViewDelegate (render thread)

    nonisolated func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return nil }
        return overlay.makeNode(for: meshAnchor)
    }

    nonisolated func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return }
        overlay.update(node, for: meshAnchor)
    }

    nonisolated func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        overlay.remove(anchor.identifier)
    }

    nonisolated func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        overlay.applyStyleIfNeeded()
    }

    // MARK: - Messages

    private nonisolated static func message(for state: ARCamera.TrackingState) -> String? {
        switch state {
        case .normal: nil
        case .notAvailable: "Tracking unavailable"
        case .limited(.initializing): "Initializing — move the phone slowly"
        case .limited(.excessiveMotion): "Slow down"
        case .limited(.insufficientFeatures): "Point at surfaces with more detail or light"
        case .limited(.relocalizing): "Relocalizing — point at a scanned area"
        case .limited: "Tracking limited"
        }
    }

    private nonisolated static func message(for error: Error) -> String {
        if let arError = error as? ARError {
            switch arError.code {
            case .cameraUnauthorized:
                return "Camera access is off. Enable it in Settings › ScanSpace to scan."
            case .unsupportedConfiguration:
                return "This iPhone doesn't have a LiDAR scanner."
            case .sensorFailed, .sensorUnavailable:
                return "The camera or LiDAR sensor isn't available right now. Close other camera apps and try again."
            default:
                break
            }
        }
        return error.localizedDescription
    }

    private nonisolated static func centerDepth(_ depthMap: CVPixelBuffer) -> Float? {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let width = CVPixelBufferGetWidth(depthMap), height = CVPixelBufferGetHeight(depthMap)
        let row = base.advanced(by: (height / 2) * CVPixelBufferGetBytesPerRow(depthMap))
        return row.load(fromByteOffset: (width / 2) * 4, as: Float32.self)
    }
}
