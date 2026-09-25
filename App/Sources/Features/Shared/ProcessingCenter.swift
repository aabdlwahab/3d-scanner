import Foundation
import Observation
import UIKit

/// Runs the texturing pipeline for LiDAR scans in the background and publishes progress.
@MainActor
@Observable
final class ProcessingCenter {
    private(set) var jobs: [UUID: ProcessingProgress] = [:]

    func progress(for id: UUID) -> ProcessingProgress? {
        jobs[id]
    }

    func isProcessing(_ id: UUID) -> Bool {
        jobs[id] != nil
    }

    func process(_ id: UUID, store: ScanStore) {
        guard jobs[id] == nil, let scan = store.scan(id), scan.kind == .lidar else { return }
        let files = store.files(for: id)
        let options = AppSettings.processingOptions
        jobs[id] = ProcessingProgress(fraction: 0, stage: "Preparing")
        store.update(id) {
            $0.status = .processing
            $0.failureReason = nil
        }
        // Texture baking is CPU work and may continue for a while if the user leaves the app.
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Process scan")

        Task.detached(priority: .userInitiated) { [self] in
            let result: Result<ProcessingOutput, Error>
            do {
                let output = try ScanProcessor(files: files, options: options).run { progress in
                    Task { @MainActor in self.report(progress, for: id) }
                }
                result = .success(output)
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                self.finish(id, result: result, store: store)
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }
    }

    private func report(_ progress: ProcessingProgress, for id: UUID) {
        guard jobs[id] != nil else { return }
        jobs[id] = progress
    }

    private func finish(_ id: UUID, result: Result<ProcessingOutput, Error>, store: ScanStore) {
        jobs[id] = nil
        switch result {
        case .success(let output):
            store.update(id) { scan in
                scan.status = .ready
                scan.stats.vertexCount = output.vertexCount
                scan.stats.triangleCount = output.triangleCount
                scan.stats.textureCount = output.textureCount
                scan.stats.keyframeCount = output.keyframeCount
                scan.stats.pointCount = output.pointCount
                scan.stats.surfaceArea = output.surfaceArea
                scan.stats.bounds = [Double(output.bounds.x), Double(output.bounds.y), Double(output.bounds.z)]
            }
            Haptics.success()
            if UIApplication.shared.applicationState == .active {
                ThumbnailRenderer.renderModelThumbnail(for: id, store: store)
            }
        case .failure(let error):
            store.update(id) {
                $0.status = .failed
                $0.failureReason = error.localizedDescription
            }
            Haptics.warning()
        }
    }
}
