import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// Progress of a library-level job (importing, building the sample).
struct LibraryJob: Equatable {
    var title: String
    var progress: Double?
}

/// All projects on this Mac. Each project uses the same folder layout as the iPhone app
/// (``ScanFiles``), plus `edits.json` and `blueprint.json` written by Studio.
@MainActor
@Observable
final class ProjectLibrary {
    static let shared = ProjectLibrary()

    private(set) var projects: [Scan] = []
    private(set) var session: ProjectSession?
    private(set) var job: LibraryJob?
    private(set) var thumbnailRevision: [UUID: Int] = [:]
    var errorMessage: String?
    var selection: UUID? {
        didSet {
            guard selection != oldValue else { return }
            openSelection()
        }
    }

    let rootURL: URL

    static let importableTypes: [UTType] = {
        var types: [UTType] = [.zip]
        for ext in ["scanspace", "ply", "obj", "stl", "usdz", "usd", "usda", "usdc"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }()

    init(rootURL: URL? = nil) {
        let arguments = CommandLine.arguments
        if let rootURL {
            self.rootURL = rootURL
        } else if let index = arguments.firstIndex(of: "--library"), index + 1 < arguments.count {
            self.rootURL = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        } else {
            self.rootURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ScanSpace Studio/Projects", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        reload()
    }

    func files(for id: UUID) -> ScanFiles {
        ScanFiles(root: rootURL.appendingPathComponent(id.uuidString, isDirectory: true))
    }

    func project(_ id: UUID) -> Scan? {
        projects.first { $0.id == id }
    }

    func reload() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        projects = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: ScanFiles(root: folder).metadata) else { return nil }
            return try? JSONDecoder.scanSpace.decode(Scan.self, from: data)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ scan: Scan) {
        var scan = scan
        scan.updatedAt = Date()
        try? JSONEncoder.scanSpace.encode(scan).write(to: files(for: scan.id).metadata, options: .atomic)
        if let index = projects.firstIndex(where: { $0.id == scan.id }) {
            projects[index] = scan
        } else {
            projects.insert(scan, at: 0)
        }
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var scan = project(id), !trimmed.isEmpty else { return }
        scan.name = trimmed
        save(scan)
        if session?.id == id { session?.scan.name = trimmed }
    }

    func delete(_ id: UUID) {
        if selection == id { selection = nil }
        try? FileManager.default.removeItem(at: files(for: id).root)
        projects.removeAll { $0.id == id }
    }

    func revealInFinder(_ id: UUID) {
        NSWorkspace.shared.activateFileViewerSelecting([files(for: id).root])
    }

    func thumbnailDidChange(_ id: UUID) {
        thumbnailRevision[id, default: 0] += 1
    }

    private func openSelection() {
        guard let id = selection, let scan = project(id) else {
            session = nil
            return
        }
        let session = ProjectSession(scan: scan, files: files(for: id), library: self)
        self.session = session
        Task { await session.load() }
    }

    // MARK: - Importing

    func importFiles(_ urls: [URL]) {
        Task {
            var last: UUID?
            for url in urls {
                job = LibraryJob(title: "Importing \(url.lastPathComponent)…")
                do {
                    let scan = try await Self.importItem(url, into: rootURL)
                    save(scan)
                    last = scan.id
                } catch {
                    errorMessage = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
            job = nil
            if let last { selection = last }
        }
    }

    func importDropped(_ providers: [NSItemProvider]) {
        Task {
            var urls: [URL] = []
            for provider in providers where provider.canLoadObject(ofClass: URL.self) {
                if let url = await withCheckedContinuation({ continuation in
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                }) {
                    urls.append(url)
                }
            }
            importFiles(urls)
        }
    }

    /// Builds the synthetic three-room apartment as a raw capture, then selects it (the editor
    /// processes it automatically).
    func createSampleApartment(width: Int = 640, height: Int = 480) {
        Task {
            var scan = Scan(name: "Sample Apartment", kind: .lidar, status: .needsProcessing)
            let files = files(for: scan.id)
            job = LibraryJob(title: "Building the sample apartment…", progress: 0)
            do {
                try await Task.detached(priority: .userInitiated) {
                    try SyntheticApartment.standard().writeCapture(to: files, width: width, height: height) { progress in
                        Task { @MainActor in ProjectLibrary.shared.job?.progress = progress }
                    }
                }.value
                let frames = (try? KeyframeIndex.read(from: files.framesIndex).frames.count) ?? 0
                scan.stats.keyframeCount = frames
                scan.stats.triangleCount = (try? RawMesh.read(from: files.rawMesh).triangleCount) ?? 0
                save(scan)
                job = nil
                selection = scan.id
            } catch {
                job = nil
                errorMessage = "Couldn't build the sample: \(error.localizedDescription)"
            }
        }
    }

    enum ImportError: LocalizedError {
        case notAProject
        case unknownArchive

        var errorDescription: String? {
            switch self {
            case .notAProject: "This isn't a ScanSpace project."
            case .unknownArchive: "The zip file doesn't contain a ScanSpace raw capture (mesh.bin and frames.json)."
            }
        }
    }

    nonisolated private static func importItem(_ url: URL, into root: URL) async throws -> Scan {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let ext = url.pathExtension.lowercased()
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            if ext == ProjectArchive.fileExtension || ext == "zip" {
                let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                defer { try? fm.removeItem(at: temp) }
                try unzip(url, to: temp)
                let unpacked = ScanFiles(root: temp)
                if let data = try? Data(contentsOf: unpacked.metadata), var scan = try? JSONDecoder.scanSpace.decode(Scan.self, from: data) {
                    // A project from the iPhone app. Keep its identity unless it's already here.
                    if fm.fileExists(atPath: root.appendingPathComponent(scan.id.uuidString).path) {
                        scan.id = UUID()
                        scan.name += " (copy)"
                    }
                    if scan.status == .processing { scan.status = .needsProcessing }
                    let destination = root.appendingPathComponent(scan.id.uuidString, isDirectory: true)
                    try fm.moveItem(at: temp, to: destination)
                    try JSONEncoder.scanSpace.encode(scan).write(to: ScanFiles(root: destination).metadata, options: .atomic)
                    return scan
                }
                // A raw capture zip ("Raw Capture" export): mesh.bin + frames.json + frames/.
                guard let rawRoot = findRawCapture(in: temp) else { throw ext == "zip" ? ImportError.unknownArchive : ImportError.notAProject }
                var scan = Scan(name: url.deletingPathExtension().lastPathComponent, kind: .lidar, status: .needsProcessing)
                let files = ScanFiles(root: root.appendingPathComponent(scan.id.uuidString, isDirectory: true))
                try files.createDirectories()
                try fm.removeItem(at: files.rawDirectory)
                try fm.moveItem(at: rawRoot, to: files.rawDirectory)
                scan.stats.triangleCount = (try? RawMesh.read(from: files.rawMesh).triangleCount) ?? 0
                scan.stats.keyframeCount = (try? KeyframeIndex.read(from: files.framesIndex).frames.count) ?? 0
                try JSONEncoder.scanSpace.encode(scan).write(to: files.metadata, options: .atomic)
                return scan
            }

            // A mesh or point cloud from another app.
            let imported = try ModelImporter.load(url)
            var scan = Scan(name: url.deletingPathExtension().lastPathComponent, kind: .lidar, status: .ready)
            let files = ScanFiles(root: root.appendingPathComponent(scan.id.uuidString, isDirectory: true))
            try files.createDirectories()
            if let mesh = imported.mesh {
                try mesh.write(to: files.texturedMesh)
                scan.stats.vertexCount = mesh.vertexCount
                scan.stats.triangleCount = mesh.triangleCount
                scan.stats.surfaceArea = MeshMath.surfaceArea(positions: mesh.positions, indices: mesh.groups.flatMap(\.indices))
                let size = BoundingBox(points: mesh.positions).size
                scan.stats.bounds = [Double(size.x), Double(size.y), Double(size.z)]
            }
            if let points = imported.points {
                try points.write(to: files.pointCloud)
                scan.stats.pointCount = points.count
                if imported.mesh == nil {
                    let size = BoundingBox(points: points.positions).size
                    scan.stats.bounds = [Double(size.x), Double(size.y), Double(size.z)]
                }
            }
            try JSONEncoder.scanSpace.encode(scan).write(to: files.metadata, options: .atomic)
            return scan
        }.value
    }

    nonisolated private static func unzip(_ archive: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ImportError.notAProject }
    }

    nonisolated private static func findRawCapture(in folder: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.appendingPathComponent("mesh.bin").path),
           fm.fileExists(atPath: folder.appendingPathComponent("frames.json").path) {
            return folder
        }
        let children = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for child in children where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if let found = findRawCapture(in: child) { return found }
        }
        return nil
    }
}
