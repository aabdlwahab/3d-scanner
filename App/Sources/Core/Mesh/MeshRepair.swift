import Foundation
import simd

/// Repairs a LiDAR mesh before texturing: patches holes the scanner missed and flattens the
/// bumps and waves on walls, floors and ceilings. Runs on the raw mesh so the texturing step then
/// paints the patches from the real photos (the camera usually saw what the depth sensor missed).
enum MeshRepair {
    struct Options {
        var fillHoles = true
        /// Holes larger than this are left open (doorways, windows, unscanned areas); long thin
        /// gaps (e.g. along a wall-ceiling edge) are filled as long as their area is small.
        var maxHoleArea: Float = 0.5
        var maxHolePerimeter: Float = 10
        var flattenSurfaces = true
        /// Vertices within this distance of a detected plane are moved onto it.
        var flattenTolerance: Float = 0.04
        /// Only planes with at least this much surface are used (m²).
        var minPlaneArea: Float = 0.6
    }

    struct Report {
        var holesFilled = 0
        var trianglesAdded = 0
        var planes = 0
        var verticesFlattened = 0
        /// Detected plane per triangle of the repaired mesh (-1 = none), and the planes.
        var triangleToPlane: [Int32] = []
        var planeList: [Plane] = []
    }

    static func repair(_ mesh: RawMesh, options: Options = Options()) -> (RawMesh, Report) {
        var result = mesh
        var report = Report()
        if options.fillHoles {
            let filled = fillHoles(result, maxPerimeter: options.maxHolePerimeter, maxArea: options.maxHoleArea)
            result = filled.mesh
            report.holesFilled = filled.holes
            report.trianglesAdded = filled.triangles
        }
        if options.flattenSurfaces {
            let flat = flatten(result, tolerance: options.flattenTolerance, minArea: options.minPlaneArea)
            result = flat.mesh
            report.planes = flat.planes.count
            report.verticesFlattened = flat.moved
            report.triangleToPlane = flat.assignment
            report.planeList = flat.planes
        }
        result.normals = MeshMath.vertexNormals(positions: result.positions, indices: result.indices)
        return (result, report)
    }

    // MARK: - Holes

    static func fillHoles(_ mesh: RawMesh, maxPerimeter: Float, maxArea: Float) -> (mesh: RawMesh, holes: Int, triangles: Int) {
        var out = mesh
        let adjacency = MeshCleaner.edgeAdjacency(indices: mesh.indices)
        let hasClasses = mesh.classes.count == mesh.triangleCount

        // Boundary edges, reversed so the patch winds the same way as its neighbours.
        var next = [UInt32: [UInt32]]()
        var edgeClass = [UInt64: UInt8]()
        func key(_ a: UInt32, _ b: UInt32) -> UInt64 { UInt64(a) << 32 | UInt64(b) }
        for t in 0..<mesh.triangleCount {
            for e in 0..<3 where adjacency[3 * t + e] < 0 {
                let a = mesh.indices[3 * t + e], b = mesh.indices[3 * t + (e + 1) % 3]
                next[b, default: []].append(a)
                if hasClasses { edgeClass[key(b, a)] = mesh.classes[t] }
            }
        }

        var used = Set<UInt64>()
        var holes = 0, added = 0
        for start in next.keys.sorted() {
            for first in next[start] ?? [] where !used.contains(key(start, first)) {
                // Walk the loop.
                var loop = [start]
                var current = first
                var previous = start
                var perimeter = simd_distance(mesh.positions[Int(start)], mesh.positions[Int(first)])
                used.insert(key(start, first))
                var closed = false
                while loop.count < 2000 && perimeter <= maxPerimeter * 1.5 {
                    if current == start { closed = true; break }
                    loop.append(current)
                    guard let candidates = next[current] else { break }
                    // At pinch vertices prefer the unused edge that turns least.
                    guard let step = candidates.first(where: { !used.contains(key(current, $0)) && $0 != previous })
                        ?? candidates.first(where: { !used.contains(key(current, $0)) }) else { break }
                    used.insert(key(current, step))
                    perimeter += simd_distance(mesh.positions[Int(current)], mesh.positions[Int(step)])
                    previous = current
                    current = step
                }
                guard closed, loop.count >= 3, perimeter <= maxPerimeter else { continue }
                // Vector area of the loop (Newell): skip big openings.
                var vectorArea = SIMD3<Float>.zero
                for i in loop.indices {
                    vectorArea += simd_cross(out.positions[Int(loop[i])], out.positions[Int(loop[(i + 1) % loop.count])])
                }
                guard simd_length(vectorArea) / 2 <= maxArea else { continue }
                var triangles = triangulate(loop, positions: out.positions)
                guard !triangles.isEmpty else { continue }
                triangles = refine(triangles, boundary: loop, positions: &out.positions, maxEdge: 0.15)
                // Label the patch like the surface around it.
                var votes = [UInt8: Int]()
                for i in loop.indices { votes[edgeClass[key(loop[i], loop[(i + 1) % loop.count])] ?? 0, default: 0] += 1 }
                let label = votes.max { $0.value < $1.value }?.key ?? 0
                for (a, b, c) in triangles {
                    out.indices += [a, b, c]
                    if hasClasses { out.classes.append(label) }
                }
                holes += 1
                added += triangles.count
            }
        }
        return (out, holes, added)
    }

    /// Splits the patch's inner edges until none is longer than `maxEdge` (the loop's own edges are
    /// shared with the mesh and never split, so no cracks appear).
    private static func refine(_ input: [(UInt32, UInt32, UInt32)], boundary: [UInt32], positions: inout [SIMD3<Float>],
                               maxEdge: Float) -> [(UInt32, UInt32, UInt32)] {
        func key(_ a: UInt32, _ b: UInt32) -> UInt64 { UInt64(min(a, b)) << 32 | UInt64(max(a, b)) }
        var fixed = Set<UInt64>()
        for i in boundary.indices { fixed.insert(key(boundary[i], boundary[(i + 1) % boundary.count])) }
        var triangles = input
        for _ in 0..<12 {
            var midpoints = [UInt64: UInt32]()
            for (a, b, c) in triangles {
                for (u, v) in [(a, b), (b, c), (c, a)] where !fixed.contains(key(u, v)) && midpoints[key(u, v)] == nil {
                    if simd_distance(positions[Int(u)], positions[Int(v)]) > maxEdge {
                        positions.append((positions[Int(u)] + positions[Int(v)]) / 2)
                        midpoints[key(u, v)] = UInt32(positions.count - 1)
                    }
                }
            }
            if midpoints.isEmpty { break }
            var next: [(UInt32, UInt32, UInt32)] = []
            for (a, b, c) in triangles {
                let ab = midpoints[key(a, b)], bc = midpoints[key(b, c)], ca = midpoints[key(c, a)]
                switch (ab, bc, ca) {
                case let (ab?, bc?, ca?): next += [(a, ab, ca), (ab, b, bc), (ca, bc, c), (ab, bc, ca)]
                case let (ab?, nil, nil): next += [(a, ab, c), (ab, b, c)]
                case let (nil, bc?, nil): next += [(a, b, bc), (a, bc, c)]
                case let (nil, nil, ca?): next += [(a, b, ca), (ca, b, c)]
                case let (ab?, bc?, nil): next += [(ab, b, bc), (a, ab, bc), (a, bc, c)]
                case let (nil, bc?, ca?): next += [(ca, bc, c), (a, b, bc), (a, bc, ca)]
                case let (ab?, nil, ca?): next += [(a, ab, ca), (ab, b, c), (ab, c, ca)]
                case (nil, nil, nil): next.append((a, b, c))
                }
            }
            triangles = next
        }
        return triangles
    }

    /// Triangulates a boundary loop: ear clipping in its best-fit plane, or a fan around a new
    /// centre vertex when the projected loop isn't simple.
    private static func triangulate(_ loop: [UInt32], positions: [SIMD3<Float>]) -> [(UInt32, UInt32, UInt32)] {
        let points = loop.map { positions[Int($0)] }
        if loop.count == 3 { return [(loop[0], loop[1], loop[2])] }
        // Newell normal.
        var normal = SIMD3<Float>.zero
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            normal += SIMD3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
        }
        guard simd_length(normal) > 1e-9 else { return [] }
        normal = simd_normalize(normal)
        let u = simd_normalize(abs(normal.x) < 0.9 ? simd_cross(normal, SIMD3(1, 0, 0)) : simd_cross(normal, SIMD3(0, 1, 0)))
        let v = simd_cross(normal, u)
        let flat = points.map { SIMD2(simd_dot($0, u), simd_dot($0, v)) }
        // Ear clipping expects counter-clockwise order.
        var area: Float = 0
        for i in flat.indices {
            let a = flat[i], b = flat[(i + 1) % flat.count]
            area += a.x * b.y - b.x * a.y
        }
        let ccw = area > 0
        let ordered = ccw ? flat : Array(flat.reversed())
        let ears = Triangulator.earClip(ordered)
        let map: (Int) -> UInt32 = { ccw ? loop[$0] : loop[loop.count - 1 - $0] }
        return ears.map { ccw ? (map($0.0), map($0.1), map($0.2)) : (map($0.0), map($0.2), map($0.1)) }
    }

    // MARK: - Planes

    struct Plane {
        var normal: SIMD3<Float>
        var offset: Float // dot(normal, p) = offset
        func distance(_ p: SIMD3<Float>) -> Float { simd_dot(normal, p) - offset }
        func project(_ p: SIMD3<Float>) -> SIMD3<Float> { p - normal * distance(p) }
    }

    static func flatten(_ mesh: RawMesh, tolerance: Float, minArea: Float) -> (mesh: RawMesh, planes: [Plane], moved: Int, assignment: [Int32]) {
        let n = mesh.triangleCount
        guard n > 0 else { return (mesh, [], 0, []) }
        let (normals, areas) = MeshMath.faceNormalsAndAreas(positions: mesh.positions, indices: mesh.indices)
        let hasClasses = mesh.classes.count == n
        let structural: Set<UInt8> = [SurfaceClass.wall.rawValue, SurfaceClass.floor.rawValue, SurfaceClass.ceiling.rawValue]
        var centroids = [SIMD3<Float>](repeating: .zero, count: n)
        for t in 0..<n {
            centroids[t] = (mesh.positions[Int(mesh.indices[3 * t])] + mesh.positions[Int(mesh.indices[3 * t + 1])]
                + mesh.positions[Int(mesh.indices[3 * t + 2])]) / 3
        }

        // Bucket candidate triangles by dominant axis (±x, ±y, ±z) and sort each bucket by the
        // centroid's coordinate on that axis, so a plane's members are found by a range search.
        // Turn the horizontal axes to the dominant wall direction so walls line up with them.
        var histogram = [Float](repeating: 0, count: 90)
        for t in 0..<n where abs(normals[t].y) < 0.3 && areas[t] > 0 {
            var angle = atan2(normals[t].z, normals[t].x) * 180 / .pi
            angle = angle.truncatingRemainder(dividingBy: 90)
            if angle < 0 { angle += 90 }
            histogram[min(89, Int(angle))] += areas[t]
        }
        let peak = histogram.indices.max { histogram[$0] < histogram[$1] } ?? 0
        let theta = (Float(peak) + 0.5) * .pi / 180
        let ax = SIMD3<Float>(cos(theta), 0, sin(theta)), az = SIMD3<Float>(-sin(theta), 0, cos(theta))
        let axes: [SIMD3<Float>] = [ax, -ax, SIMD3(0, 1, 0), SIMD3(0, -1, 0), az, -az]
        var buckets = [[Int]](repeating: [], count: 6)
        for t in 0..<n where areas[t] > 0 && (!hasClasses || structural.contains(mesh.classes[t])) {
            let nrm = normals[t]
            var best = 0
            for i in 1..<6 where simd_dot(nrm, axes[i]) > simd_dot(nrm, axes[best]) { best = i }
            buckets[best].append(t)
        }
        var keys = [[Float]](repeating: [], count: 6)
        for i in 0..<6 {
            buckets[i].sort { simd_dot(centroids[$0], axes[i]) < simd_dot(centroids[$1], axes[i]) }
            keys[i] = buckets[i].map { simd_dot(centroids[$0], axes[i]) }
        }
        func lowerBound(_ a: [Float], _ x: Float) -> Int {
            var lo = 0, hi = a.count
            while lo < hi { let m = (lo + hi) / 2; if a[m] < x { lo = m + 1 } else { hi = m } }
            return lo
        }

        var assignment = [Int32](repeating: -1, count: n)
        var planes: [Plane] = []
        for bucket in 0..<6 {
            let order = buckets[bucket].sorted { areas[$0] > areas[$1] }
            let axis = axes[bucket]
            for seed in order where assignment[seed] == -1 && planes.count < 600 {
                var plane = Plane(normal: normals[seed], offset: simd_dot(normals[seed], centroids[seed]))
                var members: [Int] = []
                for _ in 0..<3 {
                    // Walls can be turned up to ~45° from the axis; search a generous offset window.
                    let k = simd_dot(centroids[seed], axis)
                    let window = tolerance * 1.5 + 0.1
                    let lo = lowerBound(keys[bucket], k - window), hi = lowerBound(keys[bucket], k + window)
                    members = []
                    for j in lo..<hi {
                        let t = buckets[bucket][j]
                        if assignment[t] < 0, simd_dot(normals[t], plane.normal) > 0.9, abs(plane.distance(centroids[t])) < tolerance * 1.5 {
                            members.append(t)
                        }
                    }
                    guard members.count >= 3 else { break }
                    plane = fit(members, centroids: centroids, areas: areas, fallback: plane)
                }
                let area = members.reduce(Float(0)) { $0 + areas[$1] }
                guard area >= minArea else {
                    // Too small: don't seed from these again (they may still join a later plane).
                    assignment[seed] = -2
                    for t in members { assignment[t] = -2 }
                    continue
                }
                let id = Int32(planes.count)
                planes.append(plane)
                for t in members { assignment[t] = id }
            }
        }
        for t in 0..<n where assignment[t] == -2 { assignment[t] = -1 }
        guard !planes.isEmpty else { return (mesh, [], 0, assignment) }

        // Bumps: steep little facets next to a plane join it when they sit close to it.
        let adjacency = MeshCleaner.edgeAdjacency(indices: mesh.indices)
        for _ in 0..<4 {
            var changed = false
            for t in 0..<n where assignment[t] < 0 && (!hasClasses || structural.contains(mesh.classes[t])) {
                for e in 0..<3 {
                    let m = Int(adjacency[3 * t + e])
                    guard m >= 0, assignment[m] >= 0 else { continue }
                    let plane = planes[Int(assignment[m])]
                    if abs(plane.distance(centroids[t])) < tolerance, simd_dot(normals[t], plane.normal) > 0.5 {
                        assignment[t] = assignment[m]
                        changed = true
                        break
                    }
                }
            }
            if !changed { break }
        }

        // Move vertices onto the planes of their triangles (alternating projection at corners).
        var vertexPlanes = [[Int32]](repeating: [], count: mesh.vertexCount)
        for t in 0..<n where assignment[t] >= 0 {
            for c in 0..<3 {
                let v = Int(mesh.indices[3 * t + c])
                if !vertexPlanes[v].contains(assignment[t]) { vertexPlanes[v].append(assignment[t]) }
            }
        }
        var out = mesh
        var moved = 0
        for v in 0..<mesh.vertexCount where !vertexPlanes[v].isEmpty {
            var p = mesh.positions[v]
            let ids = vertexPlanes[v].prefix(3)
            for _ in 0..<(ids.count == 1 ? 1 : 6) {
                for id in ids { p = planes[Int(id)].project(p) }
            }
            // Never pull a vertex far (a bad fit would tear the surface).
            if simd_distance(p, mesh.positions[v]) <= tolerance * 2 {
                out.positions[v] = p
                moved += 1
            }
        }
        return (out, planes, moved, assignment)
    }

    /// Area-weighted least-squares plane through the members' centroids.
    private static func fit(_ triangles: [Int], centroids: [SIMD3<Float>], areas: [Float], fallback: Plane) -> Plane {
        var centre = SIMD3<Float>.zero, total: Float = 0
        for t in triangles {
            centre += centroids[t] * areas[t]
            total += areas[t]
        }
        guard total > 0 else { return fallback }
        centre /= total
        var cov = simd_float3x3()
        for t in triangles {
            let d = (centroids[t] - centre) * areas[t].squareRoot()
            cov.columns.0 += d * d.x
            cov.columns.1 += d * d.y
            cov.columns.2 += d * d.z
        }
        var normal = SymmetricEigen.smallestEigenvector(cov)
        guard simd_length(normal) > 0.5 else { return fallback }
        if simd_dot(normal, fallback.normal) < 0 { normal = -normal }
        normal = simd_normalize(normal)
        return Plane(normal: normal, offset: simd_dot(normal, centre))
    }
}
