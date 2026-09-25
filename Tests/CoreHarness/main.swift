import Foundation
import SceneKit
import simd

// Core pipeline test harness (macOS). Builds a synthetic LiDAR capture of a textured room,
// runs the real ScanProcessor on it and checks the baked textures against ground truth.
//
// Run with: scripts/dev/test-core.sh

let outputRoot = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tests/.out")
try? FileManager.default.removeItem(at: outputRoot)
try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)

var failures = 0
func check(_ condition: Bool, _ message: String) {
    print(condition ? "  PASS  \(message)" : "  FAIL  \(message)")
    if !condition { failures += 1 }
}

func timed<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
    let start = Date()
    let result = try body()
    print(String(format: "  %-28@ %.2fs", label as NSString, Date().timeIntervalSince(start)))
    return result
}

// MARK: - Synthetic capture

let room = SyntheticRoom()
let files = ScanFiles(root: outputRoot.appendingPathComponent("scan", isDirectory: true))
print("Synthetic capture")
try timed("render keyframes") { try room.writeCapture(to: files, frameCount: 64) }

// MARK: - Unit checks

print("Unit checks")
do {
    let camera = PinholeCamera(cameraToWorld: SyntheticRoom.Pose.looking(from: SIMD3(0.3, 1.2, 0.4), at: SIMD3(1, 0.5, -1)).cameraToWorld,
                               fx: 500, fy: 480, cx: 320, cy: 240, width: 640, height: 480)
    let p = SIMD3<Float>(0.9, 0.7, -0.8)
    let (pixel, depth) = camera.project(p)
    let back = camera.unproject(pixel: pixel, depth: depth)
    check(simd_distance(p, back) < 1e-4, "project/unproject round trip (error \(simd_distance(p, back)))")
    let center = camera.project(camera.position + camera.forward * 2)
    check(simd_distance(center.pixel, SIMD2(320, 240)) < 1e-3 && abs(center.depth - 2) < 1e-4, "forward axis projects to principal point")
    let up = camera.project(camera.position + camera.forward * 2 + camera.cameraToWorld.columns.1.xyz * 0.1)
    check(up.pixel.y < 240, "camera +Y maps to smaller image row (up)")

    let mesh = room.makeMesh()
    try mesh.write(to: outputRoot.appendingPathComponent("roundtrip.bin"))
    let read = try RawMesh.read(from: outputRoot.appendingPathComponent("roundtrip.bin"))
    check(read.positions == mesh.positions && read.indices == mesh.indices && read.classes == mesh.classes, "RawMesh binary round trip")

    let welded = MeshCleaner.weld(mesh)
    check(welded.positions.count < mesh.positions.count, "weld merges seam vertices (\(mesh.positions.count) -> \(welded.positions.count))")
    var flipped = welded
    for t in 0..<flipped.triangleCount { flipped.indices.swapAt(3 * t + 1, 3 * t + 2) }
    MeshCleaner.orientConsistently(&flipped)
    check(flipped.indices == welded.indices, "orientConsistently restores winding that disagrees with normals")

    var grid = VoxelGrid(voxelSize: 0.01, initialCapacity: 4)
    for i in 0..<10_000 { grid.add(SIMD3(Float(i % 100) * 0.01 + 0.005, 0, Float(i / 100) * 0.01 + 0.005), color: SIMD3(10, 20, 30)) }
    for i in 0..<10_000 { grid.add(SIMD3(Float(i % 100) * 0.01 + 0.005, 0, Float(i / 100) * 0.01 + 0.005), color: SIMD3(30, 40, 50)) }
    let cloud = grid.makeCloud()
    check(cloud.count == 10_000 && cloud.colors.allSatisfy { $0 == SIMD4(20, 30, 40, 255) }, "voxel grid averages duplicates (count \(cloud.count))")
}

// MARK: - Full pipeline

print("Pipeline")
var stages: [String] = []
let processor = ScanProcessor(files: files, options: ProcessingOptions(maxTexturePages: 2, texturePageSize: 2048, buildPointCloud: true))
let output = try timed("ScanProcessor.run") {
    try processor.run { progress in
        if stages.last != progress.stage { stages.append(progress.stage) }
    }
}
print("  stages: \(stages.joined(separator: " → "))")
print("  vertices \(output.vertexCount), triangles \(output.triangleCount), textures \(output.textureCount), points \(output.pointCount)")
print(String(format: "  surface %.2f m², textured %.1f%%, bounds %.2f × %.2f × %.2f m", output.surfaceArea,
             output.texturedTriangleRatio * 100, output.bounds.x, output.bounds.y, output.bounds.z))
check(output.textureCount >= 1 && output.textureCount <= 2, "texture pages within budget")
check(output.texturedTriangleRatio > 0.9, "most triangles are textured")
check(abs(output.surfaceArea - 2 * (4 * 3 + 4 * 2.6 + 3 * 2.6) - (1 * 0.6 + 2 * 1 * 0.75 + 2 * 0.6 * 0.75)) < 1.0, "surface area matches room")

// MARK: - Texture accuracy

let textured = try TexturedMesh.read(from: files.texturedMesh)
var pages: [(pixels: [UInt8], width: Int, height: Int)] = []
for i in 0..<textured.textureCount {
    let image = ImageFiles.loadImage(files.texture(i))!
    pages.append((ImageFiles.rgbaPixels(of: image, width: image.width, height: image.height)!, image.width, image.height))
    print("  page \(i): \(image.width)×\(image.height)")
}

var rng = SplitMix(seed: 42)
var samples = 0, good = 0
var errorSum: Float = 0
var errors: [Float] = []
for group in textured.groups where group.textureIndex >= 0 {
    let page = pages[group.textureIndex]
    let triangleCount = group.indices.count / 3
    for _ in 0..<(4000 * triangleCount / max(1, textured.triangleCount) + 1) {
        let t = Int(rng.next() % UInt64(triangleCount))
        var b0 = rng.nextFloat(), b1 = rng.nextFloat()
        if b0 + b1 > 1 { b0 = 1 - b0; b1 = 1 - b1 }
        let b2 = 1 - b0 - b1
        let i0 = Int(group.indices[3 * t]), i1 = Int(group.indices[3 * t + 1]), i2 = Int(group.indices[3 * t + 2])
        let p = textured.positions[i0] * b0 + textured.positions[i1] * b1 + textured.positions[i2] * b2
        let uv = textured.uvs[i0] * b0 + textured.uvs[i1] * b1 + textured.uvs[i2] * b2
        let x = min(page.width - 1, max(0, Int(uv.x * Float(page.width))))
        let y = min(page.height - 1, max(0, Int(uv.y * Float(page.height))))
        let o = (y * page.width + x) * 4
        let sampled = SIMD3<Float>(Float(page.pixels[o]), Float(page.pixels[o + 1]), Float(page.pixels[o + 2]))
        let truth = room.color(at: p)
        let error = simd_reduce_max(simd_abs(sampled - truth))
        errors.append(error)
        errorSum += error
        samples += 1
        if error < 45 { good += 1 }
    }
}
errors.sort()
let goodRatio = Float(good) / Float(max(1, samples))
print(String(format: "  %d samples: %.1f%% within tolerance, median error %.0f, mean %.1f", samples, goodRatio * 100,
             errors.isEmpty ? 0 : errors[errors.count / 2], errorSum / Float(max(1, samples))))
check(goodRatio > 0.9, "baked texture matches ground truth colors")

// Vertex colors sampled from the atlas should also match.
var vertexGood = 0, vertexCount = 0
for group in textured.groups where group.textureIndex >= 0 {
    for index in group.indices.prefix(3000) {
        let v = Int(index)
        let c = textured.colors[v]
        let error = simd_reduce_max(simd_abs(SIMD3<Float>(Float(c.x), Float(c.y), Float(c.z)) - room.color(at: textured.positions[v])))
        vertexCount += 1
        if error < 70 { vertexGood += 1 }
    }
}
check(Float(vertexGood) / Float(max(1, vertexCount)) > 0.75, "vertex colors roughly match (\(vertexGood)/\(vertexCount))")

// MARK: - Point cloud accuracy

let cloud = try PointCloud.read(from: files.pointCloud)
var cloudGood = 0
for i in stride(from: 0, to: cloud.count, by: max(1, cloud.count / 3000)) {
    let c = cloud.colors[i]
    let truth = room.color(at: cloud.positions[i])
    if simd_reduce_max(simd_abs(SIMD3<Float>(Float(c.x), Float(c.y), Float(c.z)) - truth)) < 60 { cloudGood += 1 }
}
let cloudSamples = (cloud.count + max(1, cloud.count / 3000) - 1) / max(1, cloud.count / 3000)
check(Float(cloudGood) / Float(max(1, cloudSamples)) > 0.8, "point cloud colors match (\(cloudGood)/\(cloudSamples))")

// MARK: - Renders

print("Renders")
func render(_ node: SCNNode, bounds: BoundingBox, name: String, direction: SIMD3<Float> = SIMD3(0.55, 0.95, 0.85), lights: Bool = false) {
    let scene = SCNScene()
    scene.background.contents = PlatformColor(hex: 0x14161F)
    scene.rootNode.addChildNode(node)
    if lights { ScanSceneBuilder.addStudioLights(to: scene.rootNode) }
    let camera = ScanSceneBuilder.makeCamera(framing: bounds)
    ScanSceneBuilder.frame(camera, on: bounds, direction: direction)
    scene.rootNode.addChildNode(camera)
    guard let device = MTLCreateSystemDefaultDevice() else { print("  (no Metal device; skipping renders)"); return }
    let renderer = SCNRenderer(device: device, options: nil)
    renderer.scene = scene
    renderer.pointOfView = camera
    let image = renderer.snapshot(atTime: 0, with: CGSize(width: 900, height: 700), antialiasingMode: .multisampling4X)
    if let cg = image.cgImageRepresentation {
        let url = outputRoot.appendingPathComponent("\(name).png")
        try? ImageFiles.writePNG(cg, to: url)
        print("  wrote \(url.path)")
    }
}

let assets = TexturedMeshAssets(mesh: textured, textureURLs: files.textureURLs(count: textured.textureCount))
render(SCNNode(geometry: assets.geometry(for: .textured)), bounds: assets.bounds, name: "render-textured")
render(SCNNode(geometry: assets.geometry(for: .textured)), bounds: assets.bounds, name: "render-textured-side", direction: SIMD3(-1, 0.5, 0.2))
render(SCNNode(geometry: assets.geometry(for: .classes)), bounds: assets.bounds, name: "render-classes", lights: true)
render(ScanSceneBuilder.pointCloudNode(cloud, pointSize: 0.02), bounds: assets.bounds, name: "render-points")

// MARK: - Exports

print("Exports")
try timed("all formats") { try runExportTests(files: files, output: outputRoot, check: check) }

// MARK: - Rooms

print("Room plan")
try MainActor.assumeIsolated { try runRoomTests(output: outputRoot, check: check) }

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
