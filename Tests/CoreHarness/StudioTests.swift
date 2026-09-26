import Foundation
import SceneKit
import simd

/// Tests for the ScanSpace Studio engine: blueprint extraction, editing, vector exports,
/// importing and project archives — driven by the synthetic three-room apartment.
@MainActor
func runStudioTests(output: URL, check: (Bool, String) -> Void) throws {
    let apartment = SyntheticApartment.standard()
    let files = ScanFiles(root: output.appendingPathComponent("apartment", isDirectory: true))
    var start = Date()
    try apartment.writeCapture(to: files, width: 192, height: 144, cell: 0.06)
    print(String(format: "  apartment capture          %.2fs", Date().timeIntervalSince(start)))
    let raw = try RawMesh.read(from: files.rawMesh)
    check(raw.triangleCount > 40_000, "apartment mesh has \(raw.triangleCount) triangles")

    start = Date()
    let output1 = try ScanProcessor(files: files, options: ProcessingOptions(maxTexturePages: 1, texturePageSize: 2048, buildPointCloud: true)).run { _ in }
    print(String(format: "  apartment processing       %.2fs (%d triangles, %.0f%% textured)", Date().timeIntervalSince(start),
                 output1.triangleCount, output1.texturedTriangleRatio * 100))
    let textured = try TexturedMesh.read(from: files.texturedMesh)

    // MARK: Blueprint from the labelled mesh

    start = Date()
    let result = try BlueprintExtractor.extract(samples: BlueprintSample.samples(from: textured), orientedNormals: true)
    print(String(format: "  blueprint (mesh)           %.2fs", Date().timeIntervalSince(start)))
    result.notes.forEach { print("    · \($0)") }
    let expectedFloor = apartment.offset.y
    check(abs(result.floorHeight - expectedFloor) < 0.03, "floor height \(result.floorHeight) ≈ \(expectedFloor)")
    check(abs(result.ceilingHeight - (expectedFloor + apartment.height)) < 0.05, "ceiling height \(result.ceilingHeight)")
    // Rotating the apartment by +23° about Y turns its wall normals to −23° in the XZ plane.
    let rotationError = abs(remainder(result.rotationDegrees + 23, 90))
    check(rotationError < 1, "wall direction \(result.rotationDegrees)° ≈ −23° (mod 90)")
    let plan = result.plan
    let wallLengths = plan.walls.map { $0.size.x }.sorted(by: >)
    print("    walls: " + wallLengths.map { String(format: "%.2f", $0) }.joined(separator: ", "))
    check((5...8).contains(plan.walls.count), "\(plan.walls.count) walls (expected about 6)")
    let totalLength = wallLengths.reduce(0, +), expectedLength = apartment.expectedWallLengths.reduce(0, +)
    check(abs(totalLength - expectedLength) / expectedLength < 0.15, String(format: "total wall length %.1f m ≈ %.1f m", totalLength, expectedLength))
    let thin = plan.walls.filter { $0.dimensions[2] > 0.08 && $0.dimensions[2] < 0.2 }
    check(thin.count >= 2, "interior walls measured thin (\(thin.map { String(format: "%.2f", $0.dimensions[2]) }))")
    check(result.rooms.count == apartment.expectedRooms, "\(result.rooms.count) rooms: " + result.rooms.map { String(format: "%.1f m²", $0.area) }.joined(separator: ", "))
    check(abs(result.floorArea - apartment.expectedFloorArea) / apartment.expectedFloorArea < 0.07,
          String(format: "floor area %.1f m² ≈ %.1f m²", result.floorArea, apartment.expectedFloorArea))
    check(plan.doors.count + plan.openings.count >= 3, "\(plan.doors.count) doors, \(plan.openings.count) openings (expected 3)")
    check(plan.windows.count >= 3, "\(plan.windows.count) windows (expected 3)")
    check(plan.objects.contains { $0.category == "sofa" } && plan.objects.contains { $0.category == "table" }, "furniture: \(plan.objects.map(\.category))")
    let geometry = FloorPlanGeometry(data: plan)
    try renderFloorPlan(geometry, style: .paper, to: output.appendingPathComponent("blueprint-mesh.png"))
    renderRoom(node: RoomSceneBuilder.makeNode(for: plan), bounds: RoomSceneBuilder.makeModel(for: plan).bounds,
               to: output.appendingPathComponent("blueprint-3d.png"))
    let assets = TexturedMeshAssets(mesh: textured, textureURLs: files.textureURLs(count: textured.textureCount))
    renderRoom(node: SCNNode(geometry: assets.geometry(for: .textured)), bounds: assets.bounds,
               to: output.appendingPathComponent("apartment-textured.png"))

    // MARK: Photo color matching

    do {
        // Brighten every other keyframe by 35% (as if the camera's exposure drifted) and check the
        // solver asks for the inverse.
        let drift = ScanFiles(root: output.appendingPathComponent("apartment-drift", isDirectory: true))
        try? FileManager.default.removeItem(at: drift.root)
        try FileManager.default.copyItem(at: files.root, to: drift.root)
        var frames = try ProcessingFrame.load(files: drift)
        for frame in frames where frame.index % 2 == 1 {
            if let image = ImageFiles.loadImage(frame.imageURL) {
                try ImageFiles.writeJPEG(ColorHarmonizer.apply(SIMD3(repeating: 1.35), to: image), to: frame.imageURL, quality: 0.95)
            }
        }
        frames = try ProcessingFrame.load(files: drift)
        let cleaned = MeshCleaner.clean(try RawMesh.read(from: drift.rawMesh))
        let adjacency = MeshCleaner.edgeAdjacency(indices: cleaned.indices)
        let normals = MeshMath.faceNormalsAndAreas(positions: cleaned.positions, indices: cleaned.indices).normals
        let labels = ViewSelector(positions: cleaned.positions, indices: cleaned.indices, faceNormals: normals, frames: frames)
            .select(adjacency: adjacency) { _ in }.labels
        start = Date()
        let gains = ColorHarmonizer.gains(positions: cleaned.positions, indices: cleaned.indices, adjacency: adjacency, labels: labels,
                                          frames: frames, options: ColorHarmonizer.Options(neutralize: 0))
        print(String(format: "  color matching             %.2fs", Date().timeIntervalSince(start)))
        let used = Set(labels.filter { $0 >= 0 }.map(Int.init))
        func mean(_ odd: Bool) -> Float {
            let g = used.filter { frames[$0].index % 2 == (odd ? 1 : 0) }.map { (gains[$0].x + gains[$0].y + gains[$0].z) / 3 }
            return g.reduce(0, +) / Float(max(1, g.count))
        }
        let ratio = mean(true) / mean(false)
        check(abs(ratio - 1 / 1.35) < 0.08, String(format: "color matching undoes a 35%% exposure drift (gain ratio %.2f, ideal %.2f)", ratio, 1 / 1.35))
    }

    // MARK: Mesh repair

    do {
        // A 4 × 3 m wall grid with bumps and a hole in the middle.
        var wall = RawMesh()
        let nx = 40, ny = 30
        var noise = SampleRandom(seed: 3)
        for j in 0...ny {
            for i in 0...nx {
                wall.positions.append(SIMD3(Float(i) * 0.1, Float(j) * 0.1, (noise.nextFloat() - 0.5) * 0.04))
            }
        }
        func vertex(_ i: Int, _ j: Int) -> UInt32 { UInt32(j * (nx + 1) + i) }
        for j in 0..<ny {
            for i in 0..<nx where !(i >= 18 && i < 22 && j >= 13 && j < 17) {
                wall.indices += [vertex(i, j), vertex(i + 1, j), vertex(i + 1, j + 1), vertex(i, j), vertex(i + 1, j + 1), vertex(i, j + 1)]
                wall.classes += [SurfaceClass.wall.rawValue, SurfaceClass.wall.rawValue]
            }
        }
        wall.normals = MeshMath.vertexNormals(positions: wall.positions, indices: wall.indices)
        let (repaired, repairReport) = MeshRepair.repair(wall)
        let openEdges = MeshCleaner.edgeAdjacency(indices: repaired.indices).filter { $0 < 0 }.count
        check(repairReport.holesFilled == 1 && openEdges == 2 * (nx + ny), "hole filled (\(repairReport.holesFilled) holes, \(openEdges) open edges = outer border only)")
        let deviations = repaired.positions.map { abs($0.z) }.sorted()
        let roughness = deviations[deviations.count * 95 / 100]
        check(repairReport.planes == 1 && roughness < 0.003, String(format: "bumpy wall flattened onto one plane (95%% within %.1f mm, %d planes, %d of %d vertices moved)", roughness * 1000, repairReport.planes, repairReport.verticesFlattened, repaired.vertexCount))
    }

    // MARK: Furnished model from a plan

    let furnishedPlan = apartment.furnishedPlan()
    start = Date()
    let blocks = RoomSceneBuilder.makeModel(for: furnishedPlan)
    let furnished = FurnishedModelBuilder.makeModel(for: furnishedPlan, style: .scandinavian)
    print(String(format: "  furnished model            %.2fs (%d triangles, %d materials)", Date().timeIntervalSince(start),
                 furnished.triangleCount, furnished.materials.count))
    let furnishedMesh = furnished.meshes.first
    check(furnished.triangleCount > blocks.triangleCount * 5, "furnished model has detail (\(furnished.triangleCount) vs \(blocks.triangleCount) triangles)")
    check(furnishedMesh?.hasUVs == true && furnishedMesh?.hasNormals == true, "furnished model has normals and texture coordinates")
    let tiledMaterials = furnished.materials.filter { $0.texture != nil }
    check(tiledMaterials.count >= 8 && tiledMaterials.allSatisfy { $0.repeats && FileManager.default.fileExists(atPath: $0.texture!.path) },
          "furnished materials use \(tiledMaterials.count) generated tiling textures")
    check(furnishedMesh.map { $0.primitives.allSatisfy { $0.indices.allSatisfy { Int($0) < furnishedMesh!.positions.count } } } ?? false,
          "furnished model indices are valid")
    let furnishedBox = furnished.bounds, blocksBox = blocks.bounds
    check(simd_distance(furnishedBox.min, blocksBox.min) < 0.3 && simd_distance(furnishedBox.max, blocksBox.max) < 0.3,
          "furnished model keeps the plan's extent")
    let furnishedGLB = output.appendingPathComponent("furnished.glb")
    try GLBWriter.write(furnished, to: furnishedGLB)
    let glbSize = (try? FileManager.default.attributesOfItem(atPath: furnishedGLB.path)[.size] as? Int) ?? 0
    check(glbSize > 500_000, "furnished GLB written with embedded textures (\(glbSize / 1024) KB)")
    renderRoom(node: SceneKitExport.node(for: furnished), bounds: furnished.bounds, to: output.appendingPathComponent("furnished-3d.png"))

    // MARK: Blueprint from an unlabelled point cloud

    var rng = SampleRandom(seed: 5)
    var cloud = PointCloud()
    for group in textured.groups {
        var i = 0
        while i + 2 < group.indices.count {
            let a = textured.positions[Int(group.indices[i])], b = textured.positions[Int(group.indices[i + 1])]
            let c = textured.positions[Int(group.indices[i + 2])]
            let samplesHere = MeshMath.triangleArea(a, b, c) / 0.0009 // ≈ one point per 3 × 3 cm
            var n = Int(samplesHere)
            if rng.nextFloat() < samplesHere - Float(n) { n += 1 }
            for _ in 0..<n {
                var r1 = rng.nextFloat(), r2 = rng.nextFloat()
                if r1 + r2 > 1 { r1 = 1 - r1; r2 = 1 - r2 }
                cloud.positions.append(a + (b - a) * r1 + (c - a) * r2)
                cloud.colors.append(SIMD4(200, 200, 200, 255))
            }
            i += 3
        }
    }
    start = Date()
    let pointResult = try BlueprintExtractor.extract(samples: BlueprintSample.samples(from: cloud), orientedNormals: false)
    print(String(format: "  blueprint (%d points)   %.2fs", cloud.count, Date().timeIntervalSince(start)))
    pointResult.notes.forEach { print("    · \($0)") }
    check(pointResult.rooms.count >= 2, "point cloud blueprint finds rooms (\(pointResult.rooms.count))")
    check(abs(pointResult.floorArea - apartment.expectedFloorArea) / apartment.expectedFloorArea < 0.12,
          String(format: "point cloud floor area %.1f m²", pointResult.floorArea))
    try renderFloorPlan(FloorPlanGeometry(data: pointResult.plan), style: .paper, to: output.appendingPathComponent("blueprint-points.png"))

    // MARK: Editing

    let box = BoundingBox(points: textured.positions)
    var cropped = textured
    let cropMin = box.min + (box.max - box.min) * SIMD3(0.25, 0, 0.25), cropMax = box.max - (box.max - box.min) * SIMD3(0.25, 0, 0.25)
    MeshEditor.apply(.crop(min: cropMin, max: cropMax), to: &cropped)
    let croppedBox = BoundingBox(points: cropped.positions)
    check(cropped.triangleCount < textured.triangleCount && all(croppedBox.min .>= cropMin - 0.1) && all(croppedBox.max .<= cropMax + 0.1),
          "crop keeps only the box (\(textured.triangleCount) → \(cropped.triangleCount) triangles)")
    check(cropped.uvs.count == cropped.vertexCount && cropped.groups.allSatisfy { $0.indices.allSatisfy { Int($0) < cropped.vertexCount } },
          "crop keeps textures and valid indices")

    var region = textured
    let lo = box.center - SIMD3(0.5, 5, 0.5), hi = box.center + SIMD3(0.5, 5, 0.5)
    let planes: [SIMD4<Float>] = [SIMD4(1, 0, 0, -lo.x), SIMD4(-1, 0, 0, hi.x), SIMD4(0, 1, 0, -lo.y),
                                   SIMD4(0, -1, 0, hi.y), SIMD4(0, 0, 1, -lo.z), SIMD4(0, 0, -1, hi.z)]
    MeshEditor.apply(.deleteRegion(planes: planes), to: &region)
    let leftover = region.groups.flatMap(\.indices).enumerated().filter { $0.offset % 3 == 0 }.contains { entry in
        let t = entry.offset
        let indices = region.groups.flatMap(\.indices)
        let c = (region.positions[Int(indices[t])] + region.positions[Int(indices[t + 1])] + region.positions[Int(indices[t + 2])]) / 3
        return MeshEditor.inside(c, planes)
    }
    check(!leftover && region.triangleCount < textured.triangleCount, "delete selection removes everything inside the region")

    var noisy = textured
    let piece = TexturedMesh(positions: [SIMD3(50, 0, 50), SIMD3(50.05, 0, 50), SIMD3(50, 0.05, 50)], normals: [SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 0, 1)],
                             uvs: [.zero, .zero, .zero], colors: [SIMD4(1, 1, 1, 255), SIMD4(1, 1, 1, 255), SIMD4(1, 1, 1, 255)],
                             classes: [0, 0, 0], groups: [TexturedMesh.Group(textureIndex: -1, indices: [0, 1, 2])], textureCount: 0)
    let base = UInt32(noisy.vertexCount)
    noisy.positions += piece.positions; noisy.normals += piece.normals; noisy.uvs += piece.uvs; noisy.colors += piece.colors; noisy.classes += piece.classes
    noisy.groups.append(TexturedMesh.Group(textureIndex: -1, indices: [base, base + 1, base + 2]))
    MeshEditor.apply(.removeSmallPieces(minArea: 0.05), to: &noisy)
    check(!noisy.positions.contains { $0.x > 40 } && noisy.triangleCount >= textured.triangleCount - 10, "remove small pieces drops floating noise only")

    var smooth = MeshCleaner.weld(raw)
    // Floor-slab vertices (facing up), measured again after smoothing.
    let floorVertices = smooth.positions.indices.filter { abs(smooth.positions[$0].y - expectedFloor) < 0.02 && smooth.normals[$0].y > 0.9 }
    func floorRoughness(_ mesh: RawMesh) -> Float {
        let offsets = floorVertices.map { mesh.positions[$0].y - expectedFloor }
        return (offsets.reduce(0) { $0 + $1 * $1 } / Float(max(1, offsets.count))).squareRoot()
    }
    let roughBefore = floorRoughness(smooth)
    MeshEditor.apply(.smooth(iterations: 4), to: &smooth)
    let roughAfter = floorRoughness(smooth)
    check(roughAfter < roughBefore * 0.8, String(format: "smoothing reduces floor noise (%.1f → %.1f mm)", roughBefore * 1000, roughAfter * 1000))

    let pivot = box.center
    let level = MeshEditor.levelingTransform(rotation: result.rotationDegrees * .pi / 180, floorHeight: result.floorHeight, pivot: pivot)
    var leveled = textured
    MeshEditor.apply(.transform(matrix: level.columnMajorArray), to: &leveled)
    let leveledResult = try BlueprintExtractor.extract(samples: BlueprintSample.samples(from: leveled), orientedNormals: true)
    check(abs(leveledResult.floorHeight) < 0.02 && abs(remainder(leveledResult.rotationDegrees, 90)) < 0.5,
          String(format: "level & align puts the floor at 0 (%.3f) and walls on axes (%.2f°)", leveledResult.floorHeight, leveledResult.rotationDegrees))
    var frames = try KeyframeIndex.read(from: files.framesIndex).frames
    let before = simd_float4x4(columnMajor: frames[0].transform).translation
    MeshEditor.apply(.transform(matrix: level.columnMajorArray), to: &frames)
    check(simd_distance(simd_float4x4(columnMajor: frames[0].transform).translation, level.transformPoint(before)) < 1e-4,
          "level & align also moves camera poses")

    var outlierCloud = cloud
    let inliers = outlierCloud.count
    for _ in 0..<2000 {
        outlierCloud.positions.append(box.center + SIMD3(rng.nextFloat() - 0.5, rng.nextFloat() - 0.5, rng.nextFloat() - 0.5) * 20)
        outlierCloud.colors.append(SIMD4(255, 0, 0, 255))
    }
    start = Date()
    MeshEditor.apply(.removeOutlierPoints(neighbors: 8, stdRatio: 2), to: &outlierCloud)
    let redLeft = outlierCloud.colors.filter { $0 == SIMD4(255, 0, 0, 255) }.count
    print(String(format: "  outlier removal            %.2fs", Date().timeIntervalSince(start)))
    check(redLeft < 200 && outlierCloud.count - redLeft > Int(Double(inliers) * 0.95), "outlier removal: \(2000 - redLeft)/2000 outliers removed, \(outlierCloud.count - redLeft)/\(inliers) inliers kept")
    var sparse = cloud
    MeshEditor.apply(.downsamplePoints(voxel: 0.1), to: &sparse)
    check(sparse.count < cloud.count / 4 && sparse.count > 0, "downsample \(cloud.count) → \(sparse.count) points")

    // Display normals for the fused cloud: floor points face up, ceiling points face down, so the
    // viewer can hide the ceiling when looking in from above.
    let fused = try PointCloud.read(from: files.pointCloud)
    start = Date()
    let pointNormals = PointCloudFilters.normalsFromMesh(points: fused.positions, meshPositions: textured.positions, meshNormals: textured.normals)
    print(String(format: "  point normals from mesh    %.2fs (%d points)", Date().timeIntervalSince(start), fused.count))
    var floorUp = 0, floorTotal = 0, ceilingDown = 0, ceilingTotal = 0
    for (p, n) in zip(fused.positions, pointNormals) {
        if abs(p.y - expectedFloor) < 0.02 {
            floorTotal += 1
            if n.y > 0.7 { floorUp += 1 }
        } else if abs(p.y - (expectedFloor + apartment.height)) < 0.02 {
            ceilingTotal += 1
            if n.y < -0.7 { ceilingDown += 1 }
        }
    }
    check(pointNormals.count == fused.count && floorTotal > 100 && ceilingTotal > 100
          && Double(floorUp) > Double(floorTotal) * 0.9 && Double(ceilingDown) > Double(ceilingTotal) * 0.9,
          "point normals from the mesh face into the rooms (floor \(floorUp)/\(floorTotal) up, ceiling \(ceilingDown)/\(ceilingTotal) down)")

    let operations: [EditOperation] = [.crop(min: cropMin, max: cropMax), .deleteRegion(planes: planes), .removeSmallPieces(minArea: 0.05),
                                       .smooth(iterations: 2), .transform(matrix: level.columnMajorArray),
                                       .removeOutlierPoints(neighbors: 8, stdRatio: 2), .downsamplePoints(voxel: 0.02)]
    let decoded = try JSONDecoder().decode([EditOperation].self, from: JSONEncoder().encode(operations))
    check(decoded == operations, "edit operations round-trip through JSON")

    // MARK: Vector floor plans

    let svg = FloorPlanVectorExport.svg(geometry, title: "Apartment & Test", system: .metric)
    let svgURL = output.appendingPathComponent("blueprint.svg")
    try svg.write(to: svgURL, atomically: true, encoding: .utf8)
    let parser = XMLParser(data: Data(svg.utf8))
    check(parser.parse(), "SVG is well-formed XML")
    check(svg.components(separatedBy: "<line").count - 1 >= geometry.wallPieces().count, "SVG draws every wall piece")
    let dxf = FloorPlanVectorExport.dxf(geometry, system: .imperial)
    try dxf.write(to: output.appendingPathComponent("blueprint.dxf"), atomically: true, encoding: .ascii)
    let lines = dxf.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
    let codesValid = stride(from: 0, to: lines.count - 1, by: 2).allSatisfy { Int(lines[$0].trimmingCharacters(in: .whitespaces)) != nil }
    check(lines.count % 2 == 0 && codesValid && dxf.hasPrefix("0\nSECTION") && dxf.hasSuffix("0\nEOF\n") && dxf.canBeConverted(to: .ascii),
          "DXF has valid group codes, sections and ASCII text")
    check(dxf.components(separatedBy: "\nPOLYLINE\n").count - 1 >= geometry.wallPieces().count, "DXF has a polyline per wall piece")

    // MARK: Importing our own exports

    let scan = Scan(name: "Synthetic Apartment", kind: .lidar, status: .ready)
    try JSONEncoder.scanSpace.encode(scan).write(to: files.metadata)
    let exporter = ScanExporter(scan: scan, files: files)
    let plyImport = try ModelImporter.load(try exporter.export(.ply))
    check(plyImport.mesh?.triangleCount == textured.triangleCount, "PLY mesh re-imports with all triangles (\(plyImport.mesh?.triangleCount ?? 0))")
    check(plyImport.mesh.map { $0.colors.contains { $0 != SIMD4(185, 185, 190, 255) } } ?? false, "PLY import keeps vertex colors")
    let pointsImport = try ModelImporter.load(try exporter.export(.pointCloud))
    check(pointsImport.points?.count == (try PointCloud.read(from: files.pointCloud)).count && pointsImport.mesh == nil, "point cloud PLY re-imports as points")
    let objZip = try exporter.export(.obj)
    let objDir = output.appendingPathComponent("obj-import")
    try? FileManager.default.removeItem(at: objDir)
    _ = shell("/usr/bin/ditto", "-x", "-k", objZip.path, objDir.path)
    if let objFile = try FileManager.default.contentsOfDirectory(at: objDir, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "obj" }) {
        let objImport = try ModelImporter.load(objFile)
        let importedBox = BoundingBox(points: objImport.mesh?.positions ?? [])
        check(objImport.mesh?.triangleCount == textured.triangleCount && simd_distance(importedBox.size, box.size) < 0.01, "OBJ re-imports with the same size")
    }

    // MARK: Project archive

    let archive = output.appendingPathComponent("apartment.scanspace")
    try ProjectArchive.export(files: files, to: archive)
    let unpacked = output.appendingPathComponent("apartment-unpacked")
    try? FileManager.default.removeItem(at: unpacked)
    check(shell("/usr/bin/ditto", "-x", "-k", archive.path, unpacked.path).status == 0, ".scanspace unzips with ditto")
    let originalFiles = Set(ZipWriter.entries(in: files.root, excluding: [files.exportsDirectory]).map(\.name))
    let unpackedFiles = Set(ZipWriter.entries(in: unpacked).map(\.name))
    check(originalFiles == unpackedFiles && unpackedFiles.contains("raw/frames.json"), ".scanspace contains the whole scan (\(unpackedFiles.count) files)")
    check((try? TexturedMesh.read(from: ScanFiles(root: unpacked).texturedMesh).triangleCount) == textured.triangleCount, "unpacked model is intact")
}
