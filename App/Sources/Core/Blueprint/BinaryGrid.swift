import Foundation
import simd

/// A 2D boolean raster with the morphology and tracing needed to turn scanned floor coverage
/// into room outlines.
struct BinaryGrid {
    let width: Int
    let height: Int
    var cells: [Bool]

    init(width: Int, height: Int, fill: Bool = false) {
        self.width = max(1, width)
        self.height = max(1, height)
        cells = [Bool](repeating: fill, count: self.width * self.height)
    }

    subscript(i: Int, j: Int) -> Bool {
        get { i >= 0 && j >= 0 && i < width && j < height && cells[j * width + i] }
        set { if i >= 0 && j >= 0 && i < width && j < height { cells[j * width + i] = newValue } }
    }

    var count: Int { cells.reduce(0) { $0 + ($1 ? 1 : 0) } }

    static func & (a: BinaryGrid, b: BinaryGrid) -> BinaryGrid {
        var out = a
        for k in out.cells.indices { out.cells[k] = a.cells[k] && b.cells[k] }
        return out
    }

    func inverted() -> BinaryGrid {
        var out = self
        for k in out.cells.indices { out.cells[k].toggle() }
        return out
    }

    /// Square dilation with radius `r` (separable, prefix sums).
    func dilated(_ r: Int) -> BinaryGrid {
        guard r > 0 else { return self }
        var horizontal = BinaryGrid(width: width, height: height)
        var prefix = [Int](repeating: 0, count: max(width, height) + 1)
        for j in 0..<height {
            for i in 0..<width { prefix[i + 1] = prefix[i] + (cells[j * width + i] ? 1 : 0) }
            for i in 0..<width {
                horizontal.cells[j * width + i] = prefix[min(width, i + r + 1)] - prefix[max(0, i - r)] > 0
            }
        }
        var out = BinaryGrid(width: width, height: height)
        for i in 0..<width {
            for j in 0..<height { prefix[j + 1] = prefix[j] + (horizontal.cells[j * width + i] ? 1 : 0) }
            for j in 0..<height {
                out.cells[j * width + i] = prefix[min(height, j + r + 1)] - prefix[max(0, j - r)] > 0
            }
        }
        return out
    }

    func eroded(_ r: Int) -> BinaryGrid {
        inverted().dilated(r).inverted()
    }

    func closed(_ r: Int) -> BinaryGrid {
        dilated(r).eroded(r)
    }

    /// Fills regions of `false` that can't be reached from the border (holes).
    func holesFilled() -> BinaryGrid {
        var outside = [Bool](repeating: false, count: cells.count)
        var queue: [Int] = []
        func push(_ i: Int, _ j: Int) {
            let k = j * width + i
            if !cells[k] && !outside[k] {
                outside[k] = true
                queue.append(k)
            }
        }
        for i in 0..<width { push(i, 0); push(i, height - 1) }
        for j in 0..<height { push(0, j); push(width - 1, j) }
        var head = 0
        while head < queue.count {
            let k = queue[head]
            head += 1
            let i = k % width, j = k / width
            if i > 0 { push(i - 1, j) }
            if i + 1 < width { push(i + 1, j) }
            if j > 0 { push(i, j - 1) }
            if j + 1 < height { push(i, j + 1) }
        }
        var out = self
        for k in out.cells.indices where !outside[k] { out.cells[k] = true }
        return out
    }

    /// 4-connected components of `true` cells with at least `minCells` cells.
    func components(minCells: Int = 1) -> [[Int]] {
        var label = [Int32](repeating: -1, count: cells.count)
        var result: [[Int]] = []
        for start in cells.indices where cells[start] && label[start] < 0 {
            var component = [start]
            label[start] = Int32(result.count)
            var head = 0
            while head < component.count {
                let k = component[head]
                head += 1
                let i = k % width, j = k / width
                for (ni, nj) in [(i - 1, j), (i + 1, j), (i, j - 1), (i, j + 1)] where ni >= 0 && nj >= 0 && ni < width && nj < height {
                    let n = nj * width + ni
                    if cells[n] && label[n] < 0 {
                        label[n] = label[start]
                        component.append(n)
                    }
                }
            }
            if component.count >= minCells { result.append(component) } else {
                for k in component { label[k] = -2 }
            }
        }
        return result
    }

    /// Cell of a component farthest from its boundary (a good label position).
    func innermostCell(of component: [Int]) -> Int {
        var inside = Set(component)
        var distance = [Int: Int]()
        var queue: [Int] = []
        for k in component {
            let i = k % width, j = k / width
            let boundary = [(i - 1, j), (i + 1, j), (i, j - 1), (i, j + 1)].contains { !inside.contains($0.1 * width + $0.0) || $0.0 < 0 || $0.1 < 0 || $0.0 >= width || $0.1 >= height }
            if boundary {
                distance[k] = 0
                queue.append(k)
            }
        }
        var head = 0
        while head < queue.count {
            let k = queue[head]
            head += 1
            let i = k % width, j = k / width
            for (ni, nj) in [(i - 1, j), (i + 1, j), (i, j - 1), (i, j + 1)] {
                let n = nj * width + ni
                if ni >= 0, nj >= 0, ni < width, nj < height, inside.contains(n), distance[n] == nil {
                    distance[n] = distance[k]! + 1
                    queue.append(n)
                }
            }
        }
        inside.removeAll()
        return distance.max { $0.value < $1.value }?.key ?? component[component.count / 2]
    }

    /// Outer boundary of a component as grid-corner coordinates (counter-clockwise with +i right
    /// and +j up), with collinear points removed.
    func outline(of component: [Int]) -> [SIMD2<Int32>] {
        let inside = Set(component)
        func isInside(_ i: Int, _ j: Int) -> Bool { i >= 0 && j >= 0 && i < width && j < height && inside.contains(j * width + i) }
        struct Edge { var from: SIMD2<Int32>; var to: SIMD2<Int32> }
        var edges: [Edge] = []
        for k in component {
            let i = Int32(k % width), j = Int32(k / width)
            let ii = Int(i), jj = Int(j)
            if !isInside(ii, jj - 1) { edges.append(Edge(from: SIMD2(i, j), to: SIMD2(i + 1, j))) }
            if !isInside(ii + 1, jj) { edges.append(Edge(from: SIMD2(i + 1, j), to: SIMD2(i + 1, j + 1))) }
            if !isInside(ii, jj + 1) { edges.append(Edge(from: SIMD2(i + 1, j + 1), to: SIMD2(i, j + 1))) }
            if !isInside(ii - 1, jj) { edges.append(Edge(from: SIMD2(i, j + 1), to: SIMD2(i, j))) }
        }
        var outgoing = [SIMD2<Int32>: [Int]]()
        for (index, edge) in edges.enumerated() { outgoing[edge.from, default: []].append(index) }
        var used = [Bool](repeating: false, count: edges.count)
        var loops: [[SIMD2<Int32>]] = []
        for first in edges.indices where !used[first] {
            var loop: [SIMD2<Int32>] = []
            var current = first
            while !used[current] {
                used[current] = true
                let edge = edges[current]
                loop.append(edge.from)
                let direction = edge.to &- edge.from
                let candidates = (outgoing[edge.to] ?? []).filter { !used[$0] }
                guard !candidates.isEmpty else { break }
                // Prefer the left-most turn so pinch points separate loops consistently.
                current = candidates.max { a, b in
                    turnScore(direction, edges[a].to &- edges[a].from) < turnScore(direction, edges[b].to &- edges[b].from)
                }!
            }
            if loop.count >= 4 { loops.append(loop) }
        }
        guard var best = loops.max(by: { abs(Self.area($0)) < abs(Self.area($1)) }) else { return [] }
        // Drop collinear points.
        var simplified: [SIMD2<Int32>] = []
        for (index, point) in best.enumerated() {
            let previous = best[(index + best.count - 1) % best.count], next = best[(index + 1) % best.count]
            let a = point &- previous, b = next &- point
            if a.x * b.y - a.y * b.x != 0 { simplified.append(point) }
        }
        best = simplified
        return best
    }

    private func turnScore(_ incoming: SIMD2<Int32>, _ outgoing: SIMD2<Int32>) -> Int32 {
        let cross = incoming.x * outgoing.y - incoming.y * outgoing.x
        let dot = incoming.x * outgoing.x + incoming.y * outgoing.y
        return cross > 0 ? 2 : (dot > 0 ? 1 : 0)
    }

    static func area(_ polygon: [SIMD2<Int32>]) -> Double {
        var sum = 0.0
        for index in polygon.indices {
            let a = polygon[index], b = polygon[(index + 1) % polygon.count]
            sum += Double(a.x) * Double(b.y) - Double(b.x) * Double(a.y)
        }
        return sum / 2
    }
}

/// Douglas–Peucker simplification of a closed polygon.
func simplifyPolygon(_ points: [SIMD2<Float>], tolerance: Float) -> [SIMD2<Float>] {
    guard points.count > 4 else { return points }
    func distance(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let ab = b - a
        let length = simd_length(ab)
        guard length > 1e-6 else { return simd_distance(p, a) }
        return abs(ab.x * (p.y - a.y) - ab.y * (p.x - a.x)) / length
    }
    func reduce(_ run: ArraySlice<SIMD2<Float>>) -> [SIMD2<Float>] {
        guard run.count > 2, let first = run.first, let last = run.last else { return Array(run) }
        var farthest = run.startIndex, maxDistance: Float = 0
        for index in run.indices.dropFirst().dropLast() {
            let d = distance(run[index], first, last)
            if d > maxDistance {
                maxDistance = d
                farthest = index
            }
        }
        guard maxDistance > tolerance else { return [first, last] }
        return reduce(run[run.startIndex...farthest]).dropLast() + reduce(run[farthest..<run.endIndex])
    }
    // Split the loop at its two most distant vertices.
    let start = points.indices.max { simd_length(points[$0] - points[0]) < simd_length(points[$1] - points[0]) } ?? 0
    let rotated = Array(points[start...] + points[..<start]) + [points[start]]
    let simplified = reduce(rotated[...])
    return Array(simplified.dropLast())
}
