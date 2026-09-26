import AppKit
import SceneKit
import SwiftUI

/// Automated UI tour used in development: `ScanSpace Studio --library <dir> --snapshot <dir>`
/// builds the sample apartment in a scratch library, walks through the main screens and writes
/// a PNG of the window for each, then quits.
@MainActor
enum SnapshotRunner {
    static func run() async {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else { return }
        let output = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let library = ProjectLibrary.shared
        await pause(1.5)
        NSApp.windows.first { $0.isVisible }?.setContentSize(NSSize(width: 1440, height: 900))
        await pause(0.8)
        capture(output, "01-welcome")

        library.createSampleApartment(width: 320, height: 240)
        let ready = await waitUntil(timeout: 300) {
            guard let session = library.session else { return false }
            return library.job == nil && !session.isLoading && session.busy == nil && session.scan.status == .ready
        }
        guard ready, let session = library.session else {
            print("snapshot: sample project never became ready")
            exit(1)
        }
        await pause(2)
        capture(output, "02-textured")

        session.style = .labels
        session.inspectorTab = .clean
        session.showCropBox = true
        let box = session.bounds
        session.cropMin = box.min + (box.max - box.min) * SIMD3(0.05, -0.05, 0.05)
        session.cropMax = box.max - (box.max - box.min) * SIMD3(0.05, 0.2, 0.05)
        await pause(1.5)
        capture(output, "03-clean-crop")

        session.showCropBox = false
        session.style = .textured
        session.tool = .select
        let center = box.center
        let lo = center - SIMD3(0.8, 3, 0.8), hi = center + SIMD3(0.8, 3, 0.8)
        session.pendingSelection = [SIMD4(1, 0, 0, -lo.x), SIMD4(-1, 0, 0, hi.x), SIMD4(0, 1, 0, -lo.y),
                                    SIMD4(0, -1, 0, hi.y), SIMD4(0, 0, 1, -lo.z), SIMD4(0, 0, -1, hi.z)]
        await pause(1.5)
        capture(output, "04-selection")
        session.tool = .orbit

        session.inspectorTab = .blueprint
        await session.generateBlueprint()
        await pause(1.5)
        capture(output, "05-floor-plan")

        session.mode = .model
        session.style = .plan
        await pause(1.5)
        capture(output, "06-plan-model")

        session.style = .points
        session.inspectorTab = .process
        await pause(1.5)
        capture(output, "07-points-process")

        session.style = .textured
        session.inspectorTab = .info
        session.cutFraction = 0.55
        session.cameraCommand = CameraCommand(kind: .top)
        await pause(1.8)
        capture(output, "08-top-cut")
        print("snapshot: wrote screenshots to \(output.path)")
        exit(0)
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func waitUntil(timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await pause(0.25)
        }
        return false
    }

    /// Renders the window's content (SwiftUI via `cacheDisplay`, SceneKit views via their own
    /// snapshots, since Metal layers don't draw through `cacheDisplay`).
    private static func capture(_ folder: URL, _ name: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }), let content = window.contentView else { return }
        // The frame view also contains the toolbar; the window background isn't part of either,
        // so paint it first (otherwise dark-mode text lands on transparency).
        let root = content.superview ?? content
        let bounds = root.bounds
        guard let rep = root.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        root.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: bounds.size).fill()
        }
        rep.draw(in: NSRect(origin: .zero, size: bounds.size))
        for view in sceneViews(in: root) {
            var frame = view.convert(view.bounds, to: root)
            if root.isFlipped { frame.origin.y = bounds.height - frame.maxY }
            view.snapshot().draw(in: frame)
        }
        image.unlockFocus()
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        try? ImageFiles.writePNG(cgImage, to: folder.appendingPathComponent("\(name).png"))
    }

    private static func sceneViews(in view: NSView) -> [SCNView] {
        var result: [SCNView] = []
        if let scene = view as? SCNView, !scene.isHiddenOrHasHiddenAncestor { result.append(scene) }
        for subview in view.subviews { result += sceneViews(in: subview) }
        return result
    }
}
