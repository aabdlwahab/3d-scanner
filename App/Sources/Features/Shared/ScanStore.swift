import Foundation
import Observation

/// The scan library. Each scan is a folder in Application Support (see ``ScanFiles``).
@MainActor
@Observable
final class ScanStore {
    private(set) var scans: [Scan] = []
    /// Bumped whenever a thumbnail is rewritten so views reload it.
    private(set) var thumbnailRevision: [UUID: Int] = [:]
    let rootURL: URL

    init(rootURL: URL = ScanStore.defaultRoot) {
        self.rootURL = rootURL
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        reload()
    }

    nonisolated static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scans", isDirectory: true)
    }

    func files(for id: UUID) -> ScanFiles {
        ScanFiles(root: rootURL.appendingPathComponent(id.uuidString, isDirectory: true))
    }

    func scan(_ id: UUID) -> Scan? {
        scans.first { $0.id == id }
    }

    func reload() {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        var loaded: [Scan] = []
        for folder in folders {
            let files = ScanFiles(root: folder)
            guard let data = try? Data(contentsOf: files.metadata),
                  var scan = try? JSONDecoder.scanSpace.decode(Scan.self, from: data) else {
                // Leftovers of a capture that never finished saving.
                if !fm.fileExists(atPath: files.metadata.path) { try? fm.removeItem(at: folder) }
                continue
            }
            if scan.status == .processing { scan.status = .needsProcessing }
            loaded.append(scan)
        }
        scans = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    /// Creates the folder for a capture that is about to start. The scan only shows up in the
    /// library once ``add(_:)`` is called after the capture was saved.
    func prepareCapture(kind: ScanKind) throws -> (Scan, ScanFiles) {
        let scan = Scan(name: Scan.defaultName(for: kind), kind: kind, status: kind == .lidar ? .needsProcessing : .ready)
        let files = files(for: scan.id)
        try files.createDirectories()
        return (scan, files)
    }

    func discardCapture(_ id: UUID) {
        try? FileManager.default.removeItem(at: files(for: id).root)
    }

    func add(_ scan: Scan) {
        persist(scan)
        scans.removeAll { $0.id == scan.id }
        scans.insert(scan, at: 0)
    }

    func update(_ id: UUID, _ change: (inout Scan) -> Void) {
        guard let index = scans.firstIndex(where: { $0.id == id }) else { return }
        change(&scans[index])
        scans[index].updatedAt = Date()
        persist(scans[index])
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.name = trimmed }
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: files(for: id).root)
        scans.removeAll { $0.id == id }
    }

    func thumbnailDidChange(_ id: UUID) {
        thumbnailRevision[id, default: 0] += 1
    }

    /// Frees space by deleting keyframes and the raw mesh (the scan can no longer be reprocessed).
    func deleteRawData(_ id: UUID) {
        try? FileManager.default.removeItem(at: files(for: id).rawDirectory)
        update(id) { _ in }
    }

    private func persist(_ scan: Scan) {
        let files = files(for: scan.id)
        try? FileManager.default.createDirectory(at: files.root, withIntermediateDirectories: true)
        try? JSONEncoder.scanSpace.encode(scan).write(to: files.metadata, options: .atomic)
    }
}
