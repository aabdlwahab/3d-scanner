import Foundation
import simd

/// A non-destructive edit. Projects store a list of these and replay them on the original data,
/// so edits can be undone, and re-processing a capture reapplies them to the new result.
enum EditOperation: Codable, Equatable {
    /// Keep only geometry whose centroid lies inside the box.
    case crop(min: SIMD3<Float>, max: SIMD3<Float>)
    /// Delete geometry inside a convex region (e.g. a selection frustum): a point is inside when
    /// `dot(plane.xyz, p) + plane.w >= 0` for every plane.
    case deleteRegion(planes: [SIMD4<Float>])
    /// Remove disconnected pieces with less than `minArea` m² of surface.
    case removeSmallPieces(minArea: Float)
    /// Taubin smoothing (shrink-free Laplacian).
    case smooth(iterations: Int)
    /// Rigid transform (16 floats, column-major), e.g. level & align.
    case transform(matrix: [Float])
    /// Statistical outlier removal on the point cloud.
    case removeOutlierPoints(neighbors: Int, stdRatio: Float)
    /// Voxel downsampling of the point cloud.
    case downsamplePoints(voxel: Float)

    var title: String {
        switch self {
        case .crop: "Crop to Box"
        case .deleteRegion: "Delete Selection"
        case .removeSmallPieces(let area): "Remove Pieces < \(String(format: "%.2f", area)) m²"
        case .smooth(let iterations): "Smooth ×\(iterations)"
        case .transform: "Level & Align"
        case .removeOutlierPoints: "Remove Outlier Points"
        case .downsamplePoints(let voxel): "Downsample Points (\(Int((voxel * 1000).rounded())) mm)"
        }
    }

    var systemImage: String {
        switch self {
        case .crop: "crop"
        case .deleteRegion: "rectangle.dashed.badge.record"
        case .removeSmallPieces: "sparkles"
        case .smooth: "wand.and.rays"
        case .transform: "level"
        case .removeOutlierPoints: "circle.dotted"
        case .downsamplePoints: "square.grid.3x3.topleft.filled"
        }
    }
}

/// Applies ``EditOperation``s to every representation of a scan.
enum MeshEditor {
    // MARK: Textured mesh

    static func apply(_ operation: EditOperation, to mesh: inout TexturedMesh) {
        switch operation {
        case .crop(let lo, let hi):
            filterTriangles(&mesh) { c in all(c .>= lo) && all(c .<= hi) }
        case .deleteRegion(let planes):
            filterTriangles(&mesh) { !inside($0, planes) }
        case .removeSmallPieces(let minArea):
            let keep = componentKeepMask(positions: mesh.positions, triangles: triangleList(mesh), minArea: minArea)
            var t = 0
            filterTriangles(&mesh) { _ in
                defer { t += 1 }
                return keep[t]
            }
        case .smooth(let iterations):
            let indices = mesh.groups.flatMap(\.indices)
            let result = taubin(positions: mesh.positions, indices: indices, iterations: iterations)
            mesh.positions = result.positions
            mesh.normals = result.normals
        case .transform(let values):
            guard values.count == 16 else { return }
            let m = simd_float4x4(columnMajor: values)
            let r = m.upperLeft3x3
            mesh.positions = mesh.positions.map { m.transformPoint($0) }
            mesh.normals = mesh.normals.map { simd_normalize(r * $0) }
        case .removeOutlierPoints, .downsamplePoints:
            break
        }
    }

    // MARK: Raw ARKit mesh

    static func apply(_ operation: EditOperation, to mesh: inout RawMesh) {
        switch operation {
        case .crop(let lo, let hi):
            filterTriangles(&mesh) { c in all(c .>= lo) && all(c .<= hi) }
        case .deleteRegion(let planes):
            filterTriangles(&mesh) { !inside($0, planes) }
        case .removeSmallPieces(let minArea):
            var triangles: [(Int, Int, Int)] = []
            triangles.reserveCapacity(mesh.triangleCount)
            for t in 0..<mesh.triangleCount {
                let a = Int(mesh.indices[3 * t]), b = Int(mesh.indices[3 * t + 1]), c = Int(mesh.indices[3 * t + 2])
                triangles.append((a, b, c))
            }
            let keep = componentKeepMask(positions: mesh.positions, triangles: triangles, minArea: minArea)
            var t = 0
            filterTriangles(&mesh) { _ in
                defer { t += 1 }
                return keep[t]
            }
        case .smooth(let iterations):
            let result = taubin(positions: mesh.positions, indices: mesh.indices, iterations: iterations)
            mesh.positions = result.positions
            mesh.normals = result.normals
        case .transform(let values):
            guard values.count == 16 else { return }
            let m = simd_float4x4(columnMajor: values)
            let r = m.upperLeft3x3
            mesh.positions = mesh.positions.map { m.transformPoint($0) }
            mesh.normals = mesh.normals.map { simd_normalize(r * $0) }
        case .removeOutlierPoints, .downsamplePoints:
            break
        }
    }

    // MARK: Point cloud

    static func apply(_ operation: EditOperation, to cloud: inout PointCloud) {
        switch operation {
        case .crop(let lo, let hi):
            filterPoints(&cloud) { all($0 .>= lo) && all($0 .<= hi) }
        case .deleteRegion(let planes):
            filterPoints(&cloud) { !inside($0, planes) }
        case .transform(let values):
            guard values.count == 16 else { return }
            let m = simd_float4x4(columnMajor: values)
            cloud.positions = cloud.positions.map { m.transformPoint($0) }
        case .removeOutlierPoints(let neighbors, let ratio):
            cloud = PointCloudFilters.removeOutliers(cloud, neighbors: neighbors, stdRatio: ratio)
        case .downsamplePoints(let voxel):
            cloud = PointCloudFilters.downsample(cloud, voxel: voxel)
        case .removeSmallPieces, .smooth:
            break
        }
    }

    // MARK: Keyframes (so re-processing sees the same coordinate frame)

    static func apply(_ operation: EditOperation, to frames: inout [KeyframeRecord]) {
        guard case .transform(let values) = operation, values.count == 16 else { return }
        let m = simd_float4x4(columnMajor: values)
        for i in frames.indices where frames[i].transform.count == 16 {
            frames[i].transform = (m * simd_float4x4(columnMajor: frames[i].transform)).columnMajorArray
        }
    }

    // MARK: - Geometry helpers

    @inline(__always)
    static func inside(_ p: SIMD3<Float>, _ planes: [SIMD4<Float>]) -> Bool {
        for plane in planes where simd_dot(SIMD3(plane.x, plane.y, plane.z), p) + plane.w < 0 { return false }
        return true
    }

    /// Planes of the region swept by a screen-space rectangle: `corners` are the rectangle's four
    /// view rays (near and far points, in order around the rectangle).
    static func frustumPlanes(near: [SIMD3<Float>], far: [SIMD3<Float>]) -> [SIMD4<Float>] {
        guard near.count == 4, far.count == 4 else { return [] }
        let center = (near.reduce(.zero, +) + far.reduce(.zero, +)) / 8
        var planes: [SIMD4<Float>] = []
        for i in 0..<4 {
            let a = near[i], b = near[(i + 1) % 4], c = far[i]
            var n = simd_normalize(simd_cross(b - a, c - a))
            var d = -simd_dot(n, a)
            if simd_dot(n, center) + d < 0 {
                n = -n
                d = -d
            }
            planes.append(SIMD4(n, d))
        }
        return planes
    }

    /// Rotation about +Y (and a vertical offset) that aligns the dominant wall direction with the
    /// X/Z axes and puts the floor at y = 0.
    static func levelingTransform(rotation radians: Float, floorHeight: Float, pivot: SIMD3<Float>) -> simd_float4x4 {
        // Rotating about +Y by θ turns a direction at angle θ in the XZ plane (atan2(z, x)) to 0.
        let rotation = simd_float4x4(simd_quatf(angle: radians, axis: SIMD3(0, 1, 0)))
        var toPivot = matrix_identity_float4x4
        toPivot.columns.3 = SIMD4(-pivot.x, -floorHeight, -pivot.z, 1)
        var back = matrix_identity_float4x4
        back.columns.3 = SIMD4(pivot.x, 0, pivot.z, 1)
        return back * rotation * toPivot
    }

    private static func triangleList(_ mesh: TexturedMesh) -> [(Int, Int, Int)] {
        var result: [(Int, Int, Int)] = []
        result.reserveCapacity(mesh.triangleCount)
        for group in mesh.groups {
            var i = 0
            while i + 2 < group.indices.count {
                result.append((Int(group.indices[i]), Int(group.indices[i + 1]), Int(group.indices[i + 2])))
                i += 3
            }
        }
        return result
    }

    /// Visits triangles in group order; `keep` receives the centroid.
    private static func filterTriangles(_ mesh: inout TexturedMesh, keep: (SIMD3<Float>) -> Bool) {
        var used = [Bool](repeating: false, count: mesh.vertexCount)
        for g in mesh.groups.indices {
            var kept: [UInt32] = []
            kept.reserveCapacity(mesh.groups[g].indices.count)
            let indices = mesh.groups[g].indices
            var i = 0
            while i + 2 < indices.count {
                let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
                if keep((mesh.positions[a] + mesh.positions[b] + mesh.positions[c]) / 3) {
                    kept.append(contentsOf: [indices[i], indices[i + 1], indices[i + 2]])
                    used[a] = true
                    used[b] = true
                    used[c] = true
                }
                i += 3
            }
            mesh.groups[g].indices = kept
        }
        mesh.groups.removeAll { $0.indices.isEmpty }
        compact(&mesh, used: used)
    }

    private static func compact(_ mesh: inout TexturedMesh, used: [Bool]) {
        guard used.contains(false) else { return }
        var remap = [UInt32](repeating: 0, count: used.count)
        var next: UInt32 = 0
        for v in used.indices where used[v] {
            remap[v] = next
            next += 1
        }
        func pick<T>(_ array: [T]) -> [T] {
            guard array.count == used.count else { return array }
            var out: [T] = []
            out.reserveCapacity(Int(next))
            for v in array.indices where used[v] { out.append(array[v]) }
            return out
        }
        mesh.positions = pick(mesh.positions)
        mesh.normals = pick(mesh.normals)
        mesh.uvs = pick(mesh.uvs)
        mesh.colors = pick(mesh.colors)
        mesh.classes = pick(mesh.classes)
        for g in mesh.groups.indices {
            mesh.groups[g].indices = mesh.groups[g].indices.map { remap[Int($0)] }
        }
    }

    private static func filterTriangles(_ mesh: inout RawMesh, keep: (SIMD3<Float>) -> Bool) {
        var indices: [UInt32] = []
        var classes: [UInt8] = []
        let hasClasses = mesh.classes.count == mesh.triangleCount
        for t in 0..<mesh.triangleCount {
            let a = Int(mesh.indices[3 * t]), b = Int(mesh.indices[3 * t + 1]), c = Int(mesh.indices[3 * t + 2])
            guard keep((mesh.positions[a] + mesh.positions[b] + mesh.positions[c]) / 3) else { continue }
            indices.append(contentsOf: mesh.indices[(3 * t)..<(3 * t + 3)])
            if hasClasses { classes.append(mesh.classes[t]) }
        }
        mesh = MeshCleaner.compact(RawMesh(positions: mesh.positions, normals: mesh.normals, indices: indices, classes: classes))
    }

    private static func filterPoints(_ cloud: inout PointCloud, keep: (SIMD3<Float>) -> Bool) {
        var result = PointCloud()
        let hasColors = cloud.colors.count == cloud.count
        for i in 0..<cloud.count where keep(cloud.positions[i]) {
            result.positions.append(cloud.positions[i])
            if hasColors { result.colors.append(cloud.colors[i]) }
        }
        cloud = result
    }

    /// Welds vertices that share a position (0.5 mm grid) so chart seams and ARKit chunk
    /// boundaries count as connected.
    static func weldIDs(_ positions: [SIMD3<Float>]) -> (ids: [Int32], count: Int) {
        var lookup = [Int64: Int32]()
        lookup.reserveCapacity(positions.count)
        var ids = [Int32](repeating: 0, count: positions.count)
        for (i, p) in positions.enumerated() {
            let key = cellKey(p, 2000)
            if let existing = lookup[key] {
                ids[i] = existing
            } else {
                let id = Int32(lookup.count)
                lookup[key] = id
                ids[i] = id
            }
        }
        return (ids, lookup.count)
    }

    /// For each triangle, whether its connected piece has at least `minArea` m² of surface.
    private static func componentKeepMask(positions: [SIMD3<Float>], triangles: [(Int, Int, Int)], minArea: Float) -> [Bool] {
        let (ids, count) = weldIDs(positions)
        var uf = UnionFind(count: count)
        for (a, b, c) in triangles {
            uf.union(Int(ids[a]), Int(ids[b]))
            uf.union(Int(ids[a]), Int(ids[c]))
        }
        var area = [Int: Float]()
        var roots = [Int](repeating: 0, count: triangles.count)
        for (t, (a, b, c)) in triangles.enumerated() {
            let root = uf.find(Int(ids[a]))
            roots[t] = root
            area[root, default: 0] += MeshMath.triangleArea(positions[a], positions[b], positions[c])
        }
        return roots.map { (area[$0] ?? 0) >= minArea }
    }

    /// Taubin λ|μ smoothing on welded vertices; duplicated vertices move together.
    static func taubin(positions: [SIMD3<Float>], indices: [UInt32], iterations: Int) -> (positions: [SIMD3<Float>], normals: [SIMD3<Float>]) {
        let (ids, count) = weldIDs(positions)
        var welded = [SIMD3<Float>](repeating: .zero, count: count)
        for (i, id) in ids.enumerated() { welded[Int(id)] = positions[i] }

        // Unique neighbor lists in CSR form.
        var pairs: [UInt64] = []
        pairs.reserveCapacity(indices.count * 2)
        var t = 0
        while t + 2 < indices.count {
            let a = ids[Int(indices[t])], b = ids[Int(indices[t + 1])], c = ids[Int(indices[t + 2])]
            for (x, y) in [(a, b), (b, c), (c, a)] where x != y {
                pairs.append(UInt64(UInt32(x)) << 32 | UInt64(UInt32(y)))
                pairs.append(UInt64(UInt32(y)) << 32 | UInt64(UInt32(x)))
            }
            t += 3
        }
        pairs.sort()
        var start = [Int](repeating: 0, count: count + 1)
        var neighbors: [Int32] = []
        neighbors.reserveCapacity(pairs.count / 2)
        var previous: UInt64 = .max
        for pair in pairs where pair != previous {
            previous = pair
            start[Int(pair >> 32) + 1] += 1
            neighbors.append(Int32(truncatingIfNeeded: pair & 0xFFFF_FFFF))
        }
        for v in 0..<count { start[v + 1] += start[v] }

        // Vertices on open edges (scan holes, chunk borders) stay put so holes don't grow.
        var edgeUse = [UInt64: UInt8]()
        t = 0
        while t + 2 < indices.count {
            let a = ids[Int(indices[t])], b = ids[Int(indices[t + 1])], c = ids[Int(indices[t + 2])]
            for (x, y) in [(a, b), (b, c), (c, a)] where x != y {
                let key = UInt64(UInt32(min(x, y))) << 32 | UInt64(UInt32(max(x, y)))
                edgeUse[key, default: 0] &+= 1
            }
            t += 3
        }
        var boundary = [Bool](repeating: false, count: count)
        for (key, uses) in edgeUse where uses == 1 {
            boundary[Int(key >> 32)] = true
            boundary[Int(key & 0xFFFF_FFFF)] = true
        }

        func step(_ factor: Float) {
            var next = welded
            for v in 0..<count where start[v + 1] > start[v] && !boundary[v] {
                var sum = SIMD3<Float>.zero
                for k in start[v]..<start[v + 1] { sum += welded[Int(neighbors[k])] }
                let average = sum / Float(start[v + 1] - start[v])
                next[v] = welded[v] + factor * (average - welded[v])
            }
            welded = next
        }
        for _ in 0..<max(0, iterations) {
            step(0.5)
            step(-0.53)
        }

        var normalSums = [SIMD3<Float>](repeating: .zero, count: count)
        t = 0
        while t + 2 < indices.count {
            let a = Int(ids[Int(indices[t])]), b = Int(ids[Int(indices[t + 1])]), c = Int(ids[Int(indices[t + 2])])
            let n = simd_cross(welded[b] - welded[a], welded[c] - welded[a])
            normalSums[a] += n
            normalSums[b] += n
            normalSums[c] += n
            t += 3
        }
        let normals = normalSums.map { n -> SIMD3<Float> in
            let length = simd_length(n)
            return length > 1e-12 ? n / length : SIMD3(0, 1, 0)
        }
        return (ids.map { welded[Int($0)] }, ids.map { normals[Int($0)] })
    }

    @inline(__always)
    private static func cellKey(_ p: SIMD3<Float>, _ inv: Float) -> Int64 {
        let x = Int64((p.x * inv).rounded()) & 0x1F_FFFF
        let y = Int64((p.y * inv).rounded()) & 0x1F_FFFF
        let z = Int64((p.z * inv).rounded()) & 0x1F_FFFF
        return (x << 42) | (y << 21) | z
    }
}
