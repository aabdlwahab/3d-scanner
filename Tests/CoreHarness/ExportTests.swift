import Foundation
import ModelIO
import SceneKit
import simd

/// Validates every exporter against a processed scan.
func runExportTests(files: ScanFiles, output: URL, check: (Bool, String) -> Void) throws {
    let scan = Scan(name: "Test Room / Scan #1", kind: .lidar, status: .ready)
    let exporter = ScanExporter(scan: scan, files: files)
    let model = try exporter.lidarModel()
    let expectedBounds = model.bounds

    // GLB
    let glbURL = try exporter.export(.glb)
    try validateGLB(Data(contentsOf: glbURL), check: check)

    // OBJ (zip)
    let objZip = try exporter.export(.obj)
    check(shell("/usr/bin/unzip", "-tq", objZip.path).status == 0, "OBJ zip passes unzip -t")
    let listing = shell("/usr/bin/unzip", "-l", objZip.path).output
    check(listing.contains(".obj") && listing.contains(".mtl") && listing.contains("texture_0.jpg"), "OBJ zip contains obj, mtl and textures")
    let unzipDir = output.appendingPathComponent("obj-unzipped")
    try? FileManager.default.removeItem(at: unzipDir)
    _ = shell("/usr/bin/unzip", "-q", objZip.path, "-d", unzipDir.path)
    if let objFile = try FileManager.default.contentsOfDirectory(at: unzipDir, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "obj" }) {
        let asset = MDLAsset(url: objFile)
        let box = asset.boundingBox
        check(asset.count > 0 && abs(box.maxBounds.x - expectedBounds.max.x) < 0.01 && abs(box.minBounds.y - expectedBounds.min.y) < 0.01,
              "OBJ loads in ModelIO with matching bounds")
        let text = try String(contentsOf: objFile, encoding: .utf8)
        let vts = text.split(separator: "\n").filter { $0.hasPrefix("vt ") }.prefix(2000)
        check(vts.allSatisfy { line in line.split(separator: " ").dropFirst().allSatisfy { (Double($0) ?? -1) >= 0 && (Double($0) ?? 2) <= 1 } },
              "OBJ texture coordinates are within 0...1")
    } else {
        check(false, "OBJ file found in zip")
    }

    // USDZ
    let usdzURL = try exporter.export(.usdz)
    let usdzListing = shell("/usr/bin/unzip", "-l", usdzURL.path).output
    check(usdzListing.contains(".usdc") && usdzListing.contains(".jpg"), "USDZ embeds geometry and textures")
    if let scene = try? SCNScene(url: usdzURL, options: nil) {
        let (lo, hi) = scene.rootNode.boundingBox
        let size = SIMD3<Float>(Float(hi.x - lo.x), Float(hi.y - lo.y), Float(hi.z - lo.z))
        check(simd_distance(size, expectedBounds.size) < 0.02, "USDZ reloads with the same size in meters (\(size))")
    } else {
        check(false, "USDZ reloads in SceneKit")
    }

    // PLY / point cloud / STL
    let plyURL = try exporter.export(.ply)
    let ply = MDLAsset(url: plyURL)
    check(ply.count > 0 && ply.boundingBox.maxBounds.y > 2.5, "PLY mesh loads in ModelIO")
    let pointsURL = try exporter.export(.pointCloud)
    let header = String(decoding: try Data(contentsOf: pointsURL).prefix(300), as: UTF8.self)
    check(header.contains("element vertex") && header.contains("property uchar red"), "point cloud PLY header")
    let stlURL = try exporter.export(.stl)
    let stlData = try Data(contentsOf: stlURL)
    let triangleCount = stlData.subdata(in: 80..<84).withUnsafeBytes { $0.load(as: UInt32.self) }
    check(Int(triangleCount) == model.triangleCount && stlData.count == 84 + Int(triangleCount) * 50, "STL triangle count and size")
    let stl = MDLAsset(url: stlURL)
    check(abs(stl.boundingBox.maxBounds.z - expectedBounds.max.y * 1000) < 20, "STL is Z-up in millimeters")

    // Raw capture
    let rawURL = try exporter.export(.rawCapture)
    check(shell("/usr/bin/unzip", "-tq", rawURL.path).status == 0, "raw capture zip passes unzip -t")
    check(shell("/usr/bin/unzip", "-l", rawURL.path).output.contains("frames/000001.jpg"), "raw zip keeps frames/ paths")

    check(ScanExporter.fileName(for: "Test Room / Scan #1") == "Test-Room-Scan-1", "export file names are sanitized")
}

func validateGLB(_ data: Data, check: (Bool, String) -> Void) throws {
    func u32(_ offset: Int) -> UInt32 { data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.load(as: UInt32.self) } }
    check(u32(0) == 0x4654_6C67 && u32(4) == 2 && Int(u32(8)) == data.count, "GLB header (magic, version, length)")
    let jsonLength = Int(u32(12))
    check(u32(16) == 0x4E4F_534A && jsonLength % 4 == 0, "GLB JSON chunk")
    let json = try JSONSerialization.jsonObject(with: data.subdata(in: 20..<20 + jsonLength)) as! [String: Any]
    let binOffset = 20 + jsonLength
    let binLength = Int(u32(binOffset))
    check(u32(binOffset + 4) == 0x004E_4942 && binOffset + 8 + binLength == data.count, "GLB BIN chunk")
    let bin = data.subdata(in: binOffset + 8 ..< binOffset + 8 + binLength)

    let views = json["bufferViews"] as! [[String: Any]]
    let accessors = json["accessors"] as! [[String: Any]]
    var ok = true
    for view in views {
        let offset = view["byteOffset"] as! Int, length = view["byteLength"] as! Int
        if offset % 4 != 0 || offset + length > binLength { ok = false }
    }
    let componentSize = [5126: 4, 5125: 4, 5121: 1, 5123: 2]
    let typeCount = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4]
    for accessor in accessors {
        let view = views[accessor["bufferView"] as! Int]
        let bytes = (accessor["count"] as! Int) * componentSize[accessor["componentType"] as! Int]! * typeCount[accessor["type"] as! String]!
        if bytes > view["byteLength"] as! Int { ok = false }
    }
    check(ok, "GLB buffer views and accessors are in bounds and aligned")

    var indicesOK = true
    for mesh in json["meshes"] as! [[String: Any]] {
        for primitive in mesh["primitives"] as! [[String: Any]] {
            let attributes = primitive["attributes"] as! [String: Int]
            let vertexCount = accessors[attributes["POSITION"]!]["count"] as! Int
            let indexAccessor = accessors[primitive["indices"] as! Int]
            let view = views[indexAccessor["bufferView"] as! Int]
            let start = view["byteOffset"] as! Int
            let count = indexAccessor["count"] as! Int
            let maxIndex = bin.subdata(in: start..<start + count * 4).withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)).max() ?? 0 }
            if Int(maxIndex) >= vertexCount || count % 3 != 0 { indicesOK = false }
        }
    }
    check(indicesOK, "GLB indices reference valid vertices")
    let images = json["images"] as? [[String: Any]] ?? []
    let textures = json["textures"] as? [[String: Any]] ?? []
    check(images.count == textures.count, "GLB images/textures (\(images.count))")
}

@discardableResult
func shell(_ args: String...) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: args[0])
    process.arguments = Array(args.dropFirst())
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}
