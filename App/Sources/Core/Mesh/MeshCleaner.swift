import Foundation
import simd

/// Topology clean-up for meshes stitched together from ARKit mesh anchors.
enum MeshCleaner {
    /// Full clean-up pass used before texturing.
    static func clean(_ mesh: RawMesh) -> RawMesh {
        var result = weld(mesh)
        orientConsistently(&result)
        result = removeSmallComponents(result, minTriangles: 24, minArea: 0.01)
        result.normals = MeshMath.vertexNormals(positions: result.positions, indices: result.indices)
        return result
    }

    /// Merges vertices that fall into the same `tolerance`-sized cell and drops degenerate triangles.
    static func weld(_ mesh: RawMesh, tolerance: Float = 0.0005) -> RawMesh {
        var remap = [UInt32](repeating: 0, count: mesh.positions.count)
        var lookup = [Int64: UInt32]()
        lookup.reserveCapacity(mesh.positions.count)
        var positions = [SIMD3<Float>]()
        var normals = [SIMD3<Float>]()
        positions.reserveCapacity(mesh.positions.count)
        let hasNormals = mesh.normals.count == mesh.positions.count
        let inv = 1 / tolerance

        for (i, p) in mesh.positions.enumerated() {
            let key = cellKey(p, inverseCellSize: inv)
            if let existing = lookup[key] {
                remap[i] = existing
                if hasNormals { normals[Int(existing)] += mesh.normals[i] }
            } else {
                let index = UInt32(positions.count)
                lookup[key] = index
                remap[i] = index
                positions.append(p)
                if hasNormals { normals.append(mesh.normals[i]) }
            }
        }

        var indices = [UInt32]()
        indices.reserveCapacity(mesh.indices.count)
        var classes = [UInt8]()
        let hasClasses = mesh.classes.count == mesh.triangleCount
        for t in 0..<mesh.triangleCount {
            let a = remap[Int(mesh.indices[3 * t])]
            let b = remap[Int(mesh.indices[3 * t + 1])]
            let c = remap[Int(mesh.indices[3 * t + 2])]
            guard a != b, b != c, a != c else { continue }
            if MeshMath.triangleArea(positions[Int(a)], positions[Int(b)], positions[Int(c)]) < 1e-9 { continue }
            indices.append(contentsOf: [a, b, c])
            if hasClasses { classes.append(mesh.classes[t]) }
        }

        for i in normals.indices {
            let len = simd_length(normals[i])
            normals[i] = len > 1e-9 ? normals[i] / len : SIMD3(0, 1, 0)
        }
        return RawMesh(positions: positions, normals: normals, indices: indices, classes: classes)
    }

    /// ARKit reports per-vertex normals facing the observed side. If most triangles wind the
    /// other way, flip them all so that counter-clockwise winding means "front".
    static func orientConsistently(_ mesh: inout RawMesh) {
        guard mesh.normals.count == mesh.positions.count, mesh.triangleCount > 0 else { return }
        var agree = 0, disagree = 0
        let stride = max(1, mesh.triangleCount / 20_000)
        var t = 0
        while t < mesh.triangleCount {
            let i0 = Int(mesh.indices[3 * t]), i1 = Int(mesh.indices[3 * t + 1]), i2 = Int(mesh.indices[3 * t + 2])
            let p0 = mesh.positions[i0]
            let faceNormal = simd_cross(mesh.positions[i1] - p0, mesh.positions[i2] - p0)
            let vertexNormal = mesh.normals[i0] + mesh.normals[i1] + mesh.normals[i2]
            if simd_dot(faceNormal, vertexNormal) >= 0 { agree += 1 } else { disagree += 1 }
            t += stride
        }
        guard disagree > agree else { return }
        for t in 0..<mesh.triangleCount {
            mesh.indices.swapAt(3 * t + 1, 3 * t + 2)
        }
    }

    /// Removes small floating pieces (typical LiDAR noise) that have fewer than `minTriangles`
    /// triangles *and* less than `minArea` m² of surface.
    static func removeSmallComponents(_ mesh: RawMesh, minTriangles: Int, minArea: Float) -> RawMesh {
        let triangleCount = mesh.triangleCount
        guard triangleCount > 0 else { return mesh }
        var uf = UnionFind(count: mesh.positions.count)
        for t in 0..<triangleCount {
            let a = Int(mesh.indices[3 * t]), b = Int(mesh.indices[3 * t + 1]), c = Int(mesh.indices[3 * t + 2])
            uf.union(a, b)
            uf.union(a, c)
        }
        var triCount = [Int: Int]()
        var area = [Int: Float]()
        var roots = [Int](repeating: 0, count: triangleCount)
        for t in 0..<triangleCount {
            let i0 = Int(mesh.indices[3 * t])
            let root = uf.find(i0)
            roots[t] = root
            triCount[root, default: 0] += 1
            area[root, default: 0] += MeshMath.triangleArea(mesh.positions[i0], mesh.positions[Int(mesh.indices[3 * t + 1])],
                                                            mesh.positions[Int(mesh.indices[3 * t + 2])])
        }

        var keptIndices = [UInt32]()
        keptIndices.reserveCapacity(mesh.indices.count)
        var keptClasses = [UInt8]()
        let hasClasses = mesh.classes.count == triangleCount
        for t in 0..<triangleCount {
            let root = roots[t]
            if (triCount[root] ?? 0) < minTriangles && (area[root] ?? 0) < minArea { continue }
            keptIndices.append(contentsOf: mesh.indices[(3 * t)..<(3 * t + 3)])
            if hasClasses { keptClasses.append(mesh.classes[t]) }
        }
        guard keptIndices.count != mesh.indices.count else { return mesh }
        return compact(RawMesh(positions: mesh.positions, normals: mesh.normals, indices: keptIndices, classes: keptClasses))
    }

    /// Drops unreferenced vertices.
    static func compact(_ mesh: RawMesh) -> RawMesh {
        var remap = [Int32](repeating: -1, count: mesh.positions.count)
        var result = RawMesh()
        result.classes = mesh.classes
        result.indices.reserveCapacity(mesh.indices.count)
        let hasNormals = mesh.normals.count == mesh.positions.count
        for index in mesh.indices {
            let i = Int(index)
            if remap[i] < 0 {
                remap[i] = Int32(result.positions.count)
                result.positions.append(mesh.positions[i])
                if hasNormals { result.normals.append(mesh.normals[i]) }
            }
            result.indices.append(UInt32(remap[i]))
        }
        return result
    }

    /// For every triangle edge (3 per triangle, edge e goes from corner e to corner e+1),
    /// the index of the neighboring triangle sharing that edge, or -1.
    static func edgeAdjacency(indices: [UInt32]) -> [Int32] {
        let triangleCount = indices.count / 3
        var adjacency = [Int32](repeating: -1, count: triangleCount * 3)
        var edges = [(key: UInt64, slot: Int32)]()
        edges.reserveCapacity(triangleCount * 3)
        for t in 0..<triangleCount {
            for e in 0..<3 {
                let a = indices[3 * t + e], b = indices[3 * t + (e + 1) % 3]
                let key = (UInt64(min(a, b)) << 32) | UInt64(max(a, b))
                edges.append((key, Int32(3 * t + e)))
            }
        }
        edges.sort { $0.key < $1.key }
        var i = 0
        while i < edges.count {
            var j = i + 1
            while j < edges.count && edges[j].key == edges[i].key { j += 1 }
            if j - i == 2 {
                let s0 = Int(edges[i].slot), s1 = Int(edges[i + 1].slot)
                adjacency[s0] = Int32(s1 / 3)
                adjacency[s1] = Int32(s0 / 3)
            }
            i = j
        }
        return adjacency
    }

    @inline(__always)
    private static func cellKey(_ p: SIMD3<Float>, inverseCellSize inv: Float) -> Int64 {
        let x = Int64((p.x * inv).rounded()) & 0x1F_FFFF
        let y = Int64((p.y * inv).rounded()) & 0x1F_FFFF
        let z = Int64((p.z * inv).rounded()) & 0x1F_FFFF
        return (x << 42) | (y << 21) | z
    }
}

struct UnionFind {
    private var parent: [Int32]
    private var rank: [UInt8]

    init(count: Int) {
        parent = (0..<Int32(count)).map { $0 }
        rank = [UInt8](repeating: 0, count: count)
    }

    mutating func find(_ x: Int) -> Int {
        var root = x
        while Int(parent[root]) != root { root = Int(parent[root]) }
        var node = x
        while Int(parent[node]) != root {
            let next = Int(parent[node])
            parent[node] = Int32(root)
            node = next
        }
        return root
    }

    mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a), rb = find(b)
        guard ra != rb else { return }
        if rank[ra] < rank[rb] {
            parent[ra] = Int32(rb)
        } else if rank[ra] > rank[rb] {
            parent[rb] = Int32(ra)
        } else {
            parent[rb] = Int32(ra)
            rank[ra] += 1
        }
    }
}
