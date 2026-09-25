import ARKit
import RoomPlan
import UIKit

/// Hosts RoomPlan's `RoomCaptureView` and scans an apartment room by room. All rooms share one
/// ARSession, so they are captured in the same coordinate space and can be merged with
/// `StructureBuilder`.
@MainActor
final class RoomCaptureController: UIViewController, RoomCaptureViewDelegate, RoomCaptureSessionDelegate {
    struct LiveCounts: Equatable {
        var walls = 0, doors = 0, windows = 0, objects = 0
    }

    var onRoomCaptured: ((CapturedRoom) -> Void)?
    var onCounts: ((LiveCounts) -> Void)?
    var onFailure: ((String) -> Void)?

    private let arSession = ARSession()
    private lazy var captureView = RoomCaptureView(frame: .zero, arSession: arSession)
    private var isRunning = false

    static var isSupported: Bool { RoomCaptureSession.isSupported }

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        captureView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(captureView)
        NSLayoutConstraint.activate([
            captureView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            captureView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            captureView.topAnchor.constraint(equalTo: view.topAnchor),
            captureView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        captureView.delegate = self
        captureView.captureSession.delegate = self
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !isRunning { startRoom() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopEverything()
    }

    func startRoom() {
        var configuration = RoomCaptureSession.Configuration()
        configuration.isCoachingEnabled = true
        captureView.captureSession.run(configuration: configuration)
        isRunning = true
        onCounts?(LiveCounts())
    }

    /// Ends the current room; RoomPlan processes it and calls back with the result. The AR
    /// session keeps running so the next room stays aligned.
    func finishRoom() {
        captureView.captureSession.stop(pauseARSession: false)
        isRunning = false
    }

    func stopEverything() {
        if isRunning { captureView.captureSession.stop() }
        isRunning = false
        arSession.pause()
    }

    // MARK: - RoomCaptureViewDelegate

    nonisolated func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        true
    }

    nonisolated func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        let message = error?.localizedDescription
        Task { @MainActor in
            if let message {
                self.onFailure?(message)
            } else {
                self.onRoomCaptured?(processedResult)
            }
        }
    }

    // MARK: - RoomCaptureSessionDelegate

    nonisolated func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        let counts = LiveCounts(walls: room.walls.count, doors: room.doors.count, windows: room.windows.count, objects: room.objects.count)
        Task { @MainActor in self.onCounts?(counts) }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        guard let error else { return }
        let message = Self.message(for: error)
        Task { @MainActor in self.onFailure?(message) }
    }

    private nonisolated static func message(for error: Error) -> String {
        if let captureError = error as? RoomCaptureSession.CaptureError {
            switch captureError {
            case .exceedSceneSizeLimit: return "This room is larger than RoomPlan supports. Finish it and scan the rest as another room."
            case .worldTrackingFailure: return "Tracking was lost. Move more slowly and keep the camera pointed at walls."
            case .deviceTooHot: return "Your iPhone is too warm to keep scanning. Let it cool down and try again."
            case .deviceNotSupported: return "RoomPlan needs an iPhone or iPad with a LiDAR Scanner."
            default: break
            }
        }
        return error.localizedDescription
    }
}

extension FloorPlanData {
    init(structure: CapturedStructure) {
        self.init()
        surfaces = Self.surfaces(walls: structure.walls, doors: structure.doors, windows: structure.windows,
                                 openings: structure.openings, floors: structure.floors)
        objects = structure.objects.map(Object.init)
        sections = structure.sections.map(Section.init)
        roomCount = max(1, structure.rooms.count)
    }

    init(room: CapturedRoom) {
        self.init()
        surfaces = Self.surfaces(walls: room.walls, doors: room.doors, windows: room.windows,
                                 openings: room.openings, floors: room.floors)
        objects = room.objects.map(Object.init)
        sections = room.sections.map(Section.init)
        roomCount = 1
    }

    private static func surfaces(walls: [CapturedRoom.Surface], doors: [CapturedRoom.Surface], windows: [CapturedRoom.Surface],
                                 openings: [CapturedRoom.Surface], floors: [CapturedRoom.Surface]) -> [Surface] {
        walls.map { Surface($0, kind: .wall) } + doors.map { Surface($0, kind: .door) }
            + windows.map { Surface($0, kind: .window) } + openings.map { Surface($0, kind: .opening) }
            + floors.map { Surface($0, kind: .floor) }
    }
}

extension FloorPlanData.Surface {
    init(_ surface: CapturedRoom.Surface, kind: FloorPlanData.SurfaceKind) {
        var isOpen: Bool?
        if case .door(let open) = surface.category { isOpen = open }
        self.init(id: surface.identifier,
                  kind: kind,
                  transform: surface.transform.columnMajorArray,
                  dimensions: [surface.dimensions.x, surface.dimensions.y, surface.dimensions.z],
                  polygon: surface.polygonCorners.isEmpty ? nil : surface.polygonCorners.map { [$0.x, $0.y, $0.z] },
                  isOpen: isOpen,
                  parentID: surface.parentIdentifier,
                  story: surface.story)
    }
}

extension FloorPlanData.Object {
    init(_ object: CapturedRoom.Object) {
        self.init(id: object.identifier,
                  category: String(describing: object.category),
                  transform: object.transform.columnMajorArray,
                  dimensions: [object.dimensions.x, object.dimensions.y, object.dimensions.z],
                  story: object.story)
    }
}

extension FloorPlanData.Section {
    init(_ section: CapturedRoom.Section) {
        self.init(label: section.label.rawValue, center: [section.center.x, section.center.y, section.center.z], story: section.story)
    }
}
