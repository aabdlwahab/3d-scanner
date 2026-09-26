import AppKit
import CoreML
import Foundation
import SceneKit

/// Development tool: `ScanSpace Studio --ai-eval <dir> [--passes-only] [--steps N] [--seeds 1,2]`
/// renders the furnished sample apartment from an overview and from each room, writes the control
/// passes, the prompts (views.json) and Stable Diffusion results, then quits.
enum AIEvalRunner {
    static var isRequested: Bool { CommandLine.arguments.contains("--ai-eval") }

    static func run() {
        let arguments = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        guard let path = value("--ai-eval") else { return }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        let passesOnly = arguments.contains("--passes-only")
        let steps = value("--steps").flatMap(Int.init) ?? 25
        let seeds = (value("--seeds") ?? "7").split(separator: ",").compactMap { UInt32($0) }
        let computeUnits: MLComputeUnits = switch value("--units") {
        case "all": .all
        case "ane": .cpuAndNeuralEngine
        case "cpu": .cpuOnly
        default: .cpuAndGPU
        }
        let viewFilter = value("--views")?.split(separator: ",").map(String.init)
        setvbuf(stdout, nil, _IOLBF, 0)
        let styles = (value("--styles") ?? "scandinavian").split(separator: ",").compactMap { id in AIRenderStyle.all.first { $0.id == id } }

        Thread.detachNewThread {
            do {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                var plan = SyntheticApartment.standard().furnishedPlan()
                var scanNode: SCNNode?
                if let project = value("--project") {
                    // A real scan: replay its edits, then extract the blueprint from the labelled mesh.
                    let files = ScanFiles(root: URL(fileURLWithPath: project, isDirectory: true))
                    var mesh = try TexturedMesh.read(from: files.texturedMesh)
                    let edits = (try? JSONDecoder().decode([EditOperation].self, from: Data(contentsOf: files.root.appendingPathComponent("edits.json")))) ?? []
                    for edit in edits { MeshEditor.apply(edit, to: &mesh) }
                    let result = try BlueprintExtractor.extract(samples: BlueprintSample.samples(from: mesh), orientedNormals: true)
                    result.notes.forEach { print("blueprint: \($0)") }
                    print("rooms: " + result.rooms.map { String(format: "%@ %.1f m²", $0.name, $0.area) }.joined(separator: ", "))
                    print("furniture: \(result.plan.objects.map(\.category))")
                    plan = result.plan
                    try plan.write(to: output.appendingPathComponent("plan.json"))
                    let assets = TexturedMeshAssets(mesh: mesh, textureURLs: files.textureURLs(count: mesh.textureCount))
                    scanNode = SCNNode(geometry: assets.geometry(for: .textured))
                }
                let width = 768, height = 512, aspect = Float(width) / Float(height)
                let maxRooms = value("--max-rooms").flatMap(Int.init) ?? 8
                let cameras = [PlanCameras.overview(plan, aspect: aspect)] + PlanCameras.rooms(plan, aspect: aspect).prefix(maxRooms)
                var views: [[String: Any]] = []
                var passes: [(PlanCamera, PlanRenderPasses, URL)] = []
                for camera in cameras {
                    let start = Date()
                    let result = try PlanRenderer.render(plan, camera: camera, width: width, height: height)
                    let folder = output.appendingPathComponent(slug(camera.name), isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try ImageFiles.writePNG(result.clay, to: folder.appendingPathComponent("clay.png"))
                    try ImageFiles.writePNG(result.depth, to: folder.appendingPathComponent("depth.png"))
                    try ImageFiles.writePNG(result.segmentation, to: folder.appendingPathComponent("segmentation.png"))
                    try ImageFiles.writePNG(result.mask, to: folder.appendingPathComponent("mask.png"))
                    if arguments.contains("--furnished") {
                        for style in FurnishingStyle.all where style.id == (value("--furnish-style") ?? "scandinavian") {
                            let model = FurnishedModelBuilder.makeModel(for: plan, style: style, ceiling: camera.isInterior)
                            try ImageFiles.writePNG(try PlanRenderer.renderModel(model, camera: camera, width: 1152, height: 768),
                                                    to: folder.appendingPathComponent("furnished-\(style.id).png"))
                        }
                    }
                    if let scanNode {
                        try ImageFiles.writePNG(try PlanRenderer.renderScan(scanNode, camera: camera, width: width, height: height),
                                                to: folder.appendingPathComponent("scan.png"))
                    }
                    print(String(format: "passes %@ %.2fs, %d objects in view", camera.name, Date().timeIntervalSince(start), result.visibleObjects.count))
                    var entry: [String: Any] = ["name": camera.name, "folder": folder.lastPathComponent, "interior": camera.isInterior]
                    for style in styles {
                        entry["sd-\(style.id)"] = RenderPrompts.diffusionPrompt(camera: camera, objects: result.visibleObjects, context: plan.objects, style: style)
                        entry["edit-\(style.id)"] = RenderPrompts.editPrompt(camera: camera, visible: result.visible, context: plan.objects, style: style)
                    }
                    if scanNode != nil { entry["scan-edit"] = RenderPrompts.scanCleanupPrompt(camera: camera) }
                    views.append(entry)
                    passes.append((camera, result, folder))
                }
                let json = try JSONSerialization.data(withJSONObject: ["views": views, "negative": RenderPrompts.negative, "styles": styles.map(\.id)],
                                                      options: [.prettyPrinted, .sortedKeys])
                try json.write(to: output.appendingPathComponent("views.json"))
                if passesOnly { exit(0) }

                let models = AIModels.stableDiffusionDirectory
                var start = Date()
                let pipeline = try PlanDiffusion(directory: models, computeUnits: computeUnits)
                try pipeline.loadResources(controls: ["Segmentation-7x5", "Depth-7x5"])
                print(String(format: "models loaded in %.1fs", Date().timeIntervalSince(start)))
                for (camera, result, folder) in passes where viewFilter == nil || viewFilter!.contains(folder.lastPathComponent) {
                    for style in styles {
                        for seed in seeds {
                            start = Date()
                            let request = PlanDiffusion.Request(
                                prompt: RenderPrompts.diffusionPrompt(camera: camera, objects: result.visibleObjects, context: plan.objects, style: style),
                                negativePrompt: RenderPrompts.negative,
                                controls: [
                                    .init(model: "Segmentation-7x5", image: result.segmentation, weight: 1.0, end: 0.9),
                                    .init(model: "Depth-7x5", image: result.depth, weight: 0.75, end: 0.8),
                                ],
                                seed: seed, steps: steps, guidance: 7)
                            let image = try pipeline.generate(request)
                            let name = "sd-\(style.id)-\(seed).png"
                            try ImageFiles.writePNG(image, to: folder.appendingPathComponent(name))
                            print(String(format: "sd %@ %@ seed %u: %.1fs", camera.name, style.id, seed, Date().timeIntervalSince(start)))
                        }
                    }
                }
                exit(0)
            } catch {
                print("ai-eval failed: \(error.localizedDescription)")
                exit(1)
            }
        }
    }

    private static func slug(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: " ", with: "-")
    }
}

/// Where downloaded AI models live.
enum AIModels {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScanSpace Studio/Models", isDirectory: true)
    }

    static var stableDiffusionDirectory: URL { root.appendingPathComponent("sd15-realisticvision51-768x512", isDirectory: true) }
}
