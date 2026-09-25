import CoreGraphics
import Foundation
import simd

struct TextureAtlasOptions {
    var pageSize = 4096
    var maxPages = 2
    /// Padding around each chart in atlas pixels (filled with real neighboring image content).
    var padding: Float = 3
    /// Charts larger than this (in source pixels) are split to pack better.
    var maxChartSize: Float = 1024
    /// Charts whose triangles cover less than this fraction of their bounding box are split.
    var minFillRatio: Float = 0.35
    var jpegQuality: Double = 0.88
}

/// Turns per-triangle keyframe labels into a textured mesh:
///
/// 1. Triangles sharing a keyframe are grouped into compact *charts*; a chart's texture is a
///    crop of its keyframe image, and its UVs are simply the triangles' projections into that image.
/// 2. Chart crops are scaled to fit the texture budget and shelf-packed into atlas pages.
/// 3. Pages are baked by copying the crops out of the keyframe JPEGs.
final class TextureAtlasBuilder {
    private struct PixelRect {
        var x = 0, y = 0, width = 0, height = 0
    }

    private struct Chart {
        let frame: Int
        let triangles: [Int32]
        let minPixel: SIMD2<Float>
        let maxPixel: SIMD2<Float>
        var crop = PixelRect()
        var dest = PixelRect()
        var page = 0
    }

    private let mesh: RawMesh
    private let frames: [ProcessingFrame]
    private let labels: [Int32]
    private let options: TextureAtlasOptions
    /// Projection of each triangle corner into its labeled keyframe (3 per triangle).
    private var projected: [SIMD2<Float>]
    /// Source (welded) vertex of every output vertex.
    private var sourceOf: [UInt32] = []

    init(mesh: RawMesh, frames: [ProcessingFrame], labels: [Int32], options: TextureAtlasOptions = TextureAtlasOptions()) {
        self.mesh = mesh
        self.frames = frames
        self.labels = labels
        self.options = options
        self.projected = []
    }

    func build(textureURL: (Int) -> URL, progress: @escaping (Double) -> Void) throws -> TexturedMesh {
        projectCorners()
        var charts = makeCharts()
        progress(0.1)

        let pageHeights = packCharts(&charts)
        var textured = assembleMesh(charts: charts, pageHeights: pageHeights)
        progress(0.2)

        var vertexPage = [Int32](repeating: -1, count: textured.vertexCount)
        for group in textured.groups where group.textureIndex >= 0 {
            for index in group.indices { vertexPage[Int(index)] = Int32(group.textureIndex) }
        }
        textured.colors = [SIMD4<UInt8>](repeating: SIMD4(150, 150, 150, 255), count: textured.vertexCount)

        for page in pageHeights.indices {
            try autoreleasepool {
                try bakePage(page, height: pageHeights[page], charts: charts, to: textureURL(page)) { pixels in
                    sampleColors(into: &textured, vertexPage: vertexPage, page: page,
                                 pixels: pixels, width: options.pageSize, height: pageHeights[page])
                }
            }
            progress(0.2 + 0.8 * Double(page + 1) / Double(max(1, pageHeights.count)))
        }
        fillUntexturedColors(&textured)
        textured.textureCount = pageHeights.count
        return textured
    }

    // MARK: - Charts

    private func projectCorners() {
        let triangleCount = mesh.triangleCount
        var result = [SIMD2<Float>](repeating: .zero, count: triangleCount * 3)
        result.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: (triangleCount + 4095) / 4096) { chunk in
                for t in (chunk * 4096) ..< min(triangleCount, chunk * 4096 + 4096) {
                    let label = labels[t]
                    guard label >= 0 else { continue }
                    let camera = frames[Int(label)].camera
                    for corner in 0..<3 {
                        out[3 * t + corner] = camera.project(mesh.positions[Int(mesh.indices[3 * t + corner])]).pixel
                    }
                }
            }
        }
        projected = result
    }

    private func makeCharts() -> [Chart] {
        var byFrame = [[Int32]](repeating: [], count: frames.count)
        for (t, label) in labels.enumerated() where label >= 0 {
            byFrame[Int(label)].append(Int32(t))
        }
        var charts = [Chart]()
        for (frame, triangles) in byFrame.enumerated() where !triangles.isEmpty {
            for piece in split(triangles) {
                let (minPixel, maxPixel) = bounds(of: piece)
                charts.append(Chart(frame: frame, triangles: piece, minPixel: minPixel, maxPixel: maxPixel))
            }
        }
        return charts
    }

    /// Recursively splits a triangle set along the longer axis of its image-space bounding box
    /// until each piece is compact (well filled) and not too large.
    private func split(_ triangles: [Int32]) -> [[Int32]] {
        var result = [[Int32]]()
        var stack = [triangles]
        while let current = stack.popLast() {
            let (minPixel, maxPixel) = bounds(of: current)
            let size = maxPixel - minPixel
            let boxArea = max(1, (size.x + 2) * (size.y + 2))
            var filled: Float = 0
            for t in current { filled += projectedArea(Int(t)) }
            let fill = filled / boxArea
            let isCompact = fill >= options.minFillRatio && max(size.x, size.y) <= options.maxChartSize
            if current.count <= 2 || isCompact {
                result.append(current)
                continue
            }
            let axis = size.x >= size.y ? 0 : 1
            let sorted = current.sorted { centroid(Int($0))[axis] < centroid(Int($1))[axis] }
            let mid = sorted.count / 2
            stack.append(Array(sorted[..<mid]))
            stack.append(Array(sorted[mid...]))
        }
        return result
    }

    private func bounds(of triangles: [Int32]) -> (SIMD2<Float>, SIMD2<Float>) {
        var lo = SIMD2<Float>(repeating: .infinity)
        var hi = SIMD2<Float>(repeating: -.infinity)
        for t in triangles {
            let base = 3 * Int(t)
            for corner in 0..<3 {
                lo = simd_min(lo, projected[base + corner])
                hi = simd_max(hi, projected[base + corner])
            }
        }
        return (lo, hi)
    }

    @inline(__always)
    private func projectedArea(_ t: Int) -> Float {
        let a = projected[3 * t], b = projected[3 * t + 1], c = projected[3 * t + 2]
        return abs((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)) * 0.5
    }

    @inline(__always)
    private func centroid(_ t: Int) -> SIMD2<Float> {
        (projected[3 * t] + projected[3 * t + 1] + projected[3 * t + 2]) / 3
    }

    // MARK: - Packing

    /// Chooses a scale so all charts fit into `maxPages` pages and assigns atlas positions.
    /// Returns the used height of each page.
    private func packCharts(_ charts: inout [Chart]) -> [Int] {
        guard !charts.isEmpty else { return [] }
        let pageSize = Float(options.pageSize)
        var totalArea: Float = 0
        for chart in charts {
            let size = chart.maxPixel - chart.minPixel + 2 * options.padding
            totalArea += max(1, size.x) * max(1, size.y)
        }
        let capacity = Float(options.maxPages) * pageSize * pageSize * 0.8
        var scale = min(1, (capacity / totalArea).squareRoot())
        var heights: [Int] = []
        for _ in 0..<16 {
            heights = shelfPack(&charts, scale: scale)
            if heights.count <= options.maxPages || scale < 0.05 { break }
            scale *= 0.9
        }
        return heights
    }

    private func shelfPack(_ charts: inout [Chart], scale: Float) -> [Int] {
        let pageSize = options.pageSize
        let padSource = options.padding / scale
        for i in charts.indices {
            let camera = frames[charts[i].frame].camera
            let x0 = max(0, Int((charts[i].minPixel.x - padSource).rounded(.down)))
            let y0 = max(0, Int((charts[i].minPixel.y - padSource).rounded(.down)))
            let x1 = min(camera.width, Int((charts[i].maxPixel.x + padSource).rounded(.up)))
            let y1 = min(camera.height, Int((charts[i].maxPixel.y + padSource).rounded(.up)))
            charts[i].crop = PixelRect(x: x0, y: y0, width: max(1, x1 - x0), height: max(1, y1 - y0))
            charts[i].dest.width = min(pageSize, max(1, Int((Float(charts[i].crop.width) * scale).rounded(.up))))
            charts[i].dest.height = min(pageSize, max(1, Int((Float(charts[i].crop.height) * scale).rounded(.up))))
        }

        let order = charts.indices.sorted { charts[$0].dest.height > charts[$1].dest.height }
        var heights: [Int] = []
        var page = 0, x = 0, y = 0, shelfHeight = 0, usedHeight = 0
        for i in order {
            let w = charts[i].dest.width, h = charts[i].dest.height
            if x + w > pageSize {
                y += shelfHeight
                x = 0
                shelfHeight = 0
            }
            if y + h > pageSize {
                heights.append(usedHeight)
                page += 1
                x = 0
                y = 0
                shelfHeight = 0
                usedHeight = 0
            }
            charts[i].page = page
            charts[i].dest.x = x
            charts[i].dest.y = y
            x += w
            shelfHeight = max(shelfHeight, h)
            usedHeight = max(usedHeight, y + h)
        }
        heights.append(usedHeight)
        // Round heights up to a multiple of 4 pixels (friendlier for GPUs and JPEG blocks).
        return heights.map { max(4, ($0 + 3) / 4 * 4) }
    }

    // MARK: - Mesh assembly

    private func assembleMesh(charts: [Chart], pageHeights: [Int]) -> TexturedMesh {
        var out = TexturedMesh()
        let hasClasses = mesh.classes.count == mesh.triangleCount
        let normals = mesh.normals.count == mesh.positions.count
            ? mesh.normals : MeshMath.vertexNormals(positions: mesh.positions, indices: mesh.indices)
        var groups = pageHeights.indices.map { TexturedMesh.Group(textureIndex: $0, indices: []) }
        let pageWidth = Float(options.pageSize)

        sourceOf.removeAll(keepingCapacity: true)
        func addVertex(_ source: Int, uv: SIMD2<Float>, triangle: Int) -> UInt32 {
            let index = UInt32(out.positions.count)
            sourceOf.append(UInt32(source))
            out.positions.append(mesh.positions[source])
            out.normals.append(normals[source])
            out.uvs.append(uv)
            out.classes.append(hasClasses ? mesh.classes[triangle] : 0)
            return index
        }

        var local = [UInt32: UInt32]()
        for chart in charts {
            local.removeAll(keepingCapacity: true)
            let pageHeight = Float(pageHeights[chart.page])
            let sx = Float(chart.dest.width) / Float(chart.crop.width)
            let sy = Float(chart.dest.height) / Float(chart.crop.height)
            for t32 in chart.triangles {
                let t = Int(t32)
                for corner in 0..<3 {
                    let source = mesh.indices[3 * t + corner]
                    if let existing = local[source] {
                        groups[chart.page].indices.append(existing)
                        continue
                    }
                    let p = projected[3 * t + corner]
                    let ax = Float(chart.dest.x) + (p.x - Float(chart.crop.x)) * sx
                    let ay = Float(chart.dest.y) + (p.y - Float(chart.crop.y)) * sy
                    let index = addVertex(Int(source), uv: SIMD2(ax / pageWidth, ay / pageHeight), triangle: t)
                    local[source] = index
                    groups[chart.page].indices.append(index)
                }
            }
        }

        // Triangles no keyframe could texture.
        var untextured = TexturedMesh.Group(textureIndex: -1, indices: [])
        local.removeAll(keepingCapacity: true)
        for (t, label) in labels.enumerated() where label < 0 {
            for corner in 0..<3 {
                let source = mesh.indices[3 * t + corner]
                if let existing = local[source] {
                    untextured.indices.append(existing)
                } else {
                    let index = addVertex(Int(source), uv: .zero, triangle: t)
                    local[source] = index
                    untextured.indices.append(index)
                }
            }
        }
        out.groups = groups.filter { !$0.indices.isEmpty }
        if !untextured.indices.isEmpty { out.groups.append(untextured) }
        return out
    }

    // MARK: - Baking

    private func bakePage(_ page: Int, height: Int, charts: [Chart], to url: URL, inspect: (UnsafePointer<UInt8>) -> Void) throws {
        let width = options.pageSize
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: ImageFiles.sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ImageFiles.ImageError.contextCreationFailed
        }
        context.setFillColor(CGColor(srgbRed: 0.55, green: 0.55, blue: 0.55, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high

        var byFrame = [Int: [Int]]()
        for (i, chart) in charts.enumerated() where chart.page == page {
            byFrame[chart.frame, default: []].append(i)
        }
        for frame in byFrame.keys.sorted() {
            autoreleasepool {
                guard let image = ImageFiles.loadImage(frames[frame].imageURL) else { return }
                let camera = frames[frame].camera
                // Keyframe JPEGs are normally stored at camera resolution; tolerate downscaled ones.
                let ix = Double(image.width) / Double(camera.width)
                let iy = Double(image.height) / Double(camera.height)
                for i in byFrame[frame] ?? [] {
                    let c = charts[i]
                    let cropRect = CGRect(x: Double(c.crop.x) * ix, y: Double(c.crop.y) * iy,
                                          width: Double(c.crop.width) * ix, height: Double(c.crop.height) * iy).integral
                    guard let cropped = image.cropping(to: cropRect) else { continue }
                    // CoreGraphics' origin is bottom-left; atlas rows are counted from the top.
                    let destRect = CGRect(x: c.dest.x, y: height - c.dest.y - c.dest.height,
                                          width: c.dest.width, height: c.dest.height)
                    context.draw(cropped, in: destRect)
                }
            }
        }

        guard let pageImage = context.makeImage() else { throw ImageFiles.ImageError.contextCreationFailed }
        try ImageFiles.writeJPEG(pageImage, to: url, quality: options.jpegQuality)
        if let data = context.data {
            inspect(UnsafePointer(data.assumingMemoryBound(to: UInt8.self)))
        }
    }

    /// Gives untextured vertices the colors of the nearest textured surface by flood-filling
    /// averaged colors across the source mesh, so small gaps blend in instead of showing gray.
    private func fillUntexturedColors(_ textured: inout TexturedMesh) {
        guard let fillGroup = textured.groups.first(where: { $0.textureIndex < 0 }) else { return }
        let sourceCount = mesh.positions.count
        var isFill = [Bool](repeating: false, count: textured.vertexCount)
        for index in fillGroup.indices { isFill[Int(index)] = true }

        var value = [SIMD3<Float>](repeating: .zero, count: sourceCount)
        var weight = [Float](repeating: 0, count: sourceCount)
        for v in 0..<textured.vertexCount where !isFill[v] {
            let c = textured.colors[v]
            value[Int(sourceOf[v])] += SIMD3(Float(c.x), Float(c.y), Float(c.z))
            weight[Int(sourceOf[v])] += 1
        }
        var colored = [Bool](repeating: false, count: sourceCount)
        var queue = [Int32]()
        for s in 0..<sourceCount where weight[s] > 0 {
            value[s] /= weight[s]
            colored[s] = true
            queue.append(Int32(s))
        }
        guard !queue.isEmpty else { return }

        // Vertex adjacency in CSR form.
        var degree = [Int32](repeating: 0, count: sourceCount + 1)
        for index in mesh.indices { degree[Int(index)] += 2 }
        var start = [Int32](repeating: 0, count: sourceCount + 1)
        for s in 0..<sourceCount { start[s + 1] = start[s] + degree[s] }
        var fillPosition = start
        var neighbors = [Int32](repeating: 0, count: Int(start[sourceCount]))
        for t in 0..<mesh.triangleCount {
            for corner in 0..<3 {
                let a = Int(mesh.indices[3 * t + corner])
                let b = Int32(mesh.indices[3 * t + (corner + 1) % 3])
                let c = Int32(mesh.indices[3 * t + (corner + 2) % 3])
                neighbors[Int(fillPosition[a])] = b
                neighbors[Int(fillPosition[a]) + 1] = c
                fillPosition[a] += 2
            }
        }

        var head = 0
        while head < queue.count {
            let u = Int(queue[head])
            head += 1
            for i in Int(start[u])..<Int(start[u + 1]) {
                let w = Int(neighbors[i])
                guard !colored[w] else { continue }
                var sum = SIMD3<Float>.zero
                var count: Float = 0
                for j in Int(start[w])..<Int(start[w + 1]) where colored[Int(neighbors[j])] {
                    sum += value[Int(neighbors[j])]
                    count += 1
                }
                value[w] = sum / max(1, count)
                colored[w] = true
                queue.append(Int32(w))
            }
        }

        for v in 0..<textured.vertexCount where isFill[v] {
            let s = Int(sourceOf[v])
            guard colored[s] else { continue }
            let c = simd_clamp(value[s], SIMD3(repeating: 0), SIMD3(repeating: 255))
            textured.colors[v] = SIMD4(UInt8(c.x), UInt8(c.y), UInt8(c.z), 255)
        }
    }

    private func sampleColors(into mesh: inout TexturedMesh, vertexPage: [Int32], page: Int,
                              pixels: UnsafePointer<UInt8>, width: Int, height: Int) {
        for v in 0..<mesh.vertexCount where vertexPage[v] == Int32(page) {
            let uv = mesh.uvs[v]
            let x = min(width - 1, max(0, Int(uv.x * Float(width))))
            let y = min(height - 1, max(0, Int(uv.y * Float(height))))
            let o = (y * width + x) * 4
            mesh.colors[v] = SIMD4(pixels[o], pixels[o + 1], pixels[o + 2], 255)
        }
    }
}
