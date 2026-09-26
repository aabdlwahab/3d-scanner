import Foundation
import simd

/// Uniform-grid spatial index over a point set (neighbors within one cell ring).
struct SpatialHash {
    let cellSize: Float
    private let points: [SIMD3<Float>]
    private let order: [Int32]
    private let cells: [Int64: Range<Int>]

    init(points: [SIMD3<Float>], cellSize: Float) {
        self.points = points
        self.cellSize = cellSize
        let inv = 1 / cellSize
        var keyed = points.indices.map { (key: Self.key(points[$0], inv), index: Int32($0)) }
        keyed.sort { $0.key < $1.key }
        order = keyed.map(\.index)
        var cells = [Int64: Range<Int>]()
        var start = 0
        while start < keyed.count {
            var end = start + 1
            while end < keyed.count && keyed[end].key == keyed[start].key { end += 1 }
            cells[keyed[start].key] = start..<end
            start = end
        }
        self.cells = cells
    }

    /// Calls `body` with the index of every point in the 3×3×3 cells around `p`.
    func forEachCandidate(near p: SIMD3<Float>, _ body: (Int) -> Void) {
        let inv = 1 / cellSize
        let cx = Int64((p.x * inv).rounded(.down)), cy = Int64((p.y * inv).rounded(.down)), cz = Int64((p.z * inv).rounded(.down))
        for dx in -1...1 {
            for dy in -1...1 {
                for dz in -1...1 {
                    guard let range = cells[Self.pack(cx + Int64(dx), cy + Int64(dy), cz + Int64(dz))] else { continue }
                    for k in range { body(Int(order[k])) }
                }
            }
        }
    }

    /// Mean distance from point `i` to its `k` nearest neighbors; infinity when too isolated.
    func meanNeighborDistance(_ i: Int, k: Int) -> Float {
        let p = points[i]
        var best = [Float](repeating: .infinity, count: k)
        var found = 0
        forEachCandidate(near: p) { j in
            guard j != i else { return }
            let d = simd_distance_squared(p, points[j])
            guard d < best[k - 1] else { return }
            var slot = k - 1
            while slot > 0 && best[slot - 1] > d {
                best[slot] = best[slot - 1]
                slot -= 1
            }
            best[slot] = d
            found += 1
        }
        let usable = min(found, k)
        guard usable >= max(1, k / 2) else { return .infinity }
        var sum: Float = 0
        for slot in 0..<usable { sum += best[slot].squareRoot() }
        return sum / Float(usable)
    }

    func neighbors(of p: SIMD3<Float>, radius: Float) -> [Int] {
        var result: [Int] = []
        let r2 = radius * radius
        forEachCandidate(near: p) { j in
            if simd_distance_squared(p, points[j]) <= r2 { result.append(j) }
        }
        return result
    }

    private static func key(_ p: SIMD3<Float>, _ inv: Float) -> Int64 {
        pack(Int64((p.x * inv).rounded(.down)), Int64((p.y * inv).rounded(.down)), Int64((p.z * inv).rounded(.down)))
    }

    private static func pack(_ x: Int64, _ y: Int64, _ z: Int64) -> Int64 {
        ((x & 0x1F_FFFF) << 42) | ((y & 0x1F_FFFF) << 21) | (z & 0x1F_FFFF)
    }
}

enum PointCloudFilters {
    static func downsample(_ cloud: PointCloud, voxel: Float) -> PointCloud {
        guard voxel > 0, cloud.count > 0 else { return cloud }
        var grid = VoxelGrid(voxelSize: voxel, initialCapacity: cloud.count / 4 + 16)
        let hasColors = cloud.colors.count == cloud.count
        for i in 0..<cloud.count {
            let c = hasColors ? cloud.colors[i] : SIMD4<UInt8>(200, 200, 200, 255)
            grid.add(cloud.positions[i], color: SIMD3(Float(c.x), Float(c.y), Float(c.z)))
        }
        return grid.makeCloud()
    }

    /// Statistical outlier removal: drops points whose mean distance to their `neighbors`
    /// nearest points is more than `stdRatio` standard deviations above the average.
    static func removeOutliers(_ cloud: PointCloud, neighbors k: Int, stdRatio: Float) -> PointCloud {
        let count = cloud.count
        guard count > k + 1, k > 0 else { return cloud }
        let spacing = averageSpacing(cloud.positions)
        let index = SpatialHash(points: cloud.positions, cellSize: max(spacing * 3, 0.004))
        var distances = [Float](repeating: .infinity, count: count)
        distances.withUnsafeMutableBufferPointer { out in
            let chunk = 4096
            DispatchQueue.concurrentPerform(iterations: (count + chunk - 1) / chunk) { c in
                for i in (c * chunk) ..< min(count, c * chunk + chunk) {
                    out[i] = index.meanNeighborDistance(i, k: k)
                }
            }
        }
        let finite = distances.filter(\.isFinite)
        guard !finite.isEmpty else { return cloud }
        let mean = finite.reduce(0, +) / Float(finite.count)
        let variance = finite.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(finite.count)
        let threshold = mean + stdRatio * variance.squareRoot()
        var result = PointCloud()
        let hasColors = cloud.colors.count == count
        for i in 0..<count where distances[i] <= threshold {
            result.positions.append(cloud.positions[i])
            if hasColors { result.colors.append(cloud.colors[i]) }
        }
        return result
    }

    /// Median nearest-neighbor distance (sampled).
    static func averageSpacing(_ positions: [SIMD3<Float>]) -> Float {
        guard positions.count > 2 else { return 0.01 }
        let box = BoundingBox(points: positions)
        let size = simd_max(box.size, SIMD3(repeating: 0.01))
        var cell = max(0.002, cbrt((size.x * size.y * size.z) / Float(positions.count)))
        let step = max(1, positions.count / 2000)
        for _ in 0..<6 {
            let index = SpatialHash(points: positions, cellSize: cell)
            var nearest: [Float] = []
            var i = 0
            while i < positions.count {
                var best = Float.infinity
                index.forEachCandidate(near: positions[i]) { j in
                    guard j != i else { return }
                    best = min(best, simd_distance(positions[i], positions[j]))
                }
                if best.isFinite { nearest.append(best) }
                i += step
            }
            if nearest.count * 2 > (positions.count + step - 1) / step {
                nearest.sort()
                return max(0.001, nearest[nearest.count / 2])
            }
            cell *= 2
        }
        return cell
    }

    /// PCA normals from neighbors within `radius` (unoriented — the sign is arbitrary).
    static func estimateNormals(_ positions: [SIMD3<Float>], radius: Float) -> [SIMD3<Float>] {
        let index = SpatialHash(points: positions, cellSize: radius)
        var normals = [SIMD3<Float>](repeating: SIMD3(0, 1, 0), count: positions.count)
        normals.withUnsafeMutableBufferPointer { out in
            let chunk = 2048
            DispatchQueue.concurrentPerform(iterations: (positions.count + chunk - 1) / chunk) { c in
                for i in (c * chunk) ..< min(positions.count, c * chunk + chunk) {
                    let neighbors = index.neighbors(of: positions[i], radius: radius)
                    guard neighbors.count >= 5 else { continue }
                    var mean = SIMD3<Float>.zero
                    for j in neighbors { mean += positions[j] }
                    mean /= Float(neighbors.count)
                    var cov = simd_float3x3()
                    for j in neighbors {
                        let d = positions[j] - mean
                        cov.columns.0 += d * d.x
                        cov.columns.1 += d * d.y
                        cov.columns.2 += d * d.z
                    }
                    out[i] = SymmetricEigen.smallestEigenvector(cov)
                }
            }
        }
        return normals
    }

    /// Normals taken from the nearest vertex of a mesh of the same surfaces. Unlike PCA normals
    /// these are oriented: the mesh knows which side of a wall was scanned. Points with no mesh
    /// vertex within about `searchRadius` face the middle of the cloud.
    static func normalsFromMesh(points: [SIMD3<Float>], meshPositions: [SIMD3<Float>], meshNormals: [SIMD3<Float>],
                                searchRadius: Float = 0.08) -> [SIMD3<Float>] {
        guard !points.isEmpty, !meshPositions.isEmpty, meshNormals.count == meshPositions.count else { return [] }
        let index = SpatialHash(points: meshPositions, cellSize: searchRadius)
        let center = BoundingBox(points: points).center
        var normals = [SIMD3<Float>](repeating: SIMD3(0, 1, 0), count: points.count)
        normals.withUnsafeMutableBufferPointer { out in
            let chunk = 4096
            DispatchQueue.concurrentPerform(iterations: (points.count + chunk - 1) / chunk) { c in
                for i in (c * chunk) ..< min(points.count, c * chunk + chunk) {
                    let p = points[i]
                    var best = Float.infinity
                    var normal = SIMD3<Float>.zero
                    index.forEachCandidate(near: p) { j in
                        let d = simd_distance_squared(p, meshPositions[j])
                        if d < best {
                            best = d
                            normal = meshNormals[j]
                        }
                    }
                    if simd_length_squared(normal) > 1e-8 {
                        out[i] = simd_normalize(normal)
                    } else if simd_distance_squared(center, p) > 1e-8 {
                        out[i] = simd_normalize(center - p)
                    }
                }
            }
        }
        return normals
    }
}

/// Jacobi eigen-decomposition for symmetric 3×3 matrices.
enum SymmetricEigen {
    static func smallestEigenvector(_ matrix: simd_float3x3) -> SIMD3<Float> {
        var a = [[Double]](repeating: [0, 0, 0], count: 3)
        for r in 0..<3 { for c in 0..<3 { a[r][c] = Double(matrix[c][r]) } }
        var v: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        for _ in 0..<32 {
            var p = 0, q = 1
            var largest = abs(a[0][1])
            if abs(a[0][2]) > largest { p = 0; q = 2; largest = abs(a[0][2]) }
            if abs(a[1][2]) > largest { p = 1; q = 2; largest = abs(a[1][2]) }
            if largest < 1e-12 { break }
            let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
            let t = (theta >= 0 ? 1 : -1) / (abs(theta) + (theta * theta + 1).squareRoot())
            let c = 1 / (t * t + 1).squareRoot(), s = t * c
            for k in 0..<3 {
                let akp = a[k][p], akq = a[k][q]
                a[k][p] = c * akp - s * akq
                a[k][q] = s * akp + c * akq
            }
            for k in 0..<3 {
                let apk = a[p][k], aqk = a[q][k]
                a[p][k] = c * apk - s * aqk
                a[q][k] = s * apk + c * aqk
            }
            for k in 0..<3 {
                let vkp = v[k][p], vkq = v[k][q]
                v[k][p] = c * vkp - s * vkq
                v[k][q] = s * vkp + c * vkq
            }
        }
        var smallest = 0
        for i in 1..<3 where a[i][i] < a[smallest][smallest] { smallest = i }
        let n = SIMD3(Float(v[0][smallest]), Float(v[1][smallest]), Float(v[2][smallest]))
        let length = simd_length(n)
        return length > 0 ? n / length : SIMD3(0, 1, 0)
    }
}
