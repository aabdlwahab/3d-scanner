import CoreGraphics
import Foundation

/// Floor plans as SVG (web, design tools) and DXF R12 (AutoCAD, LibreCAD, FreeCAD, SketchUp).
/// Both use meters; SVG keeps the on-screen orientation, DXF flips Y so the plan reads the same.
enum FloorPlanVectorExport {
    // MARK: SVG

    static func svg(_ plan: FloorPlanGeometry, title: String, system: MeasurementSystem) -> String {
        let box = plan.bounds.insetBy(dx: -0.8, dy: -0.8)
        let header: Double = 0.7
        let minY = box.minY - header, height = box.height + header
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="\(f(box.minX)) \(f(minY)) \(f(box.width)) \(f(height))" \
        width="\(Int(box.width * 100))" height="\(Int(height * 100))" font-family="Helvetica, Arial, sans-serif">
        <rect x="\(f(box.minX))" y="\(f(minY))" width="\(f(box.width))" height="\(f(height))" fill="#ffffff"/>
        <text x="\(f(box.minX + 0.3))" y="\(f(minY + 0.42))" font-size="0.3" font-weight="bold" fill="#1a1b1f">\(escape(title))</text>
        <text x="\(f(box.maxX - 0.3))" y="\(f(minY + 0.42))" font-size="0.2" text-anchor="end" fill="#666">\(escape(UnitFormat.area(plan.floorArea, system)))</text>

        """
        out += "<g id=\"floors\" fill=\"#f6f3ee\" stroke=\"none\">\n"
        for polygon in plan.floors where polygon.count >= 3 {
            out += "<polygon points=\"\(points(polygon))\"/>\n"
        }
        out += "</g>\n<g id=\"furniture\" stroke-width=\"0.012\">\n"
        for object in plan.objects {
            let rgb = FloorPlanData.color(forCategory: object.category)
            let color = String(format: "#%02x%02x%02x", Int(rgb.x * 255), Int(rgb.y * 255), Int(rgb.z * 255))
            out += "<polygon points=\"\(points(object.corners))\" fill=\"\(color)\" fill-opacity=\"0.25\" stroke=\"\(color)\"/>\n"
            out += "<text x=\"\(f(object.center.x))\" y=\"\(f(object.center.y + 0.04))\" font-size=\"0.1\" text-anchor=\"middle\" fill=\"#555\">\(escape(FloorPlanData.displayName(forCategory: object.category)))</text>\n"
        }
        out += "</g>\n<g id=\"walls\" stroke=\"#22252b\" stroke-linecap=\"square\">\n"
        for wall in plan.wallPieces() {
            out += "<line x1=\"\(f(wall.start.x))\" y1=\"\(f(wall.start.y))\" x2=\"\(f(wall.end.x))\" y2=\"\(f(wall.end.y))\" stroke-width=\"\(f(wall.thickness))\"/>\n"
        }
        out += "</g>\n<g id=\"windows\" stroke=\"#2a8cd8\" stroke-width=\"0.02\">\n"
        for window in plan.windows {
            let n = normal(window)
            for side in [-1.0, 1.0] {
                let offset = window.thickness * 0.28 * side
                out += "<line x1=\"\(f(window.start.x + n.x * offset))\" y1=\"\(f(window.start.y + n.y * offset))\" x2=\"\(f(window.end.x + n.x * offset))\" y2=\"\(f(window.end.y + n.y * offset))\"/>\n"
            }
        }
        out += "</g>\n<g id=\"doors\" stroke=\"#8c5c38\" fill=\"none\">\n"
        for door in plan.doors {
            let s = door.segment, r = s.length, a = s.angle
            let open = CGPoint(x: s.start.x + cos(a + .pi / 2) * r, y: s.start.y + sin(a + .pi / 2) * r)
            out += "<line x1=\"\(f(s.start.x))\" y1=\"\(f(s.start.y))\" x2=\"\(f(open.x))\" y2=\"\(f(open.y))\" stroke-width=\"0.025\"/>\n"
            out += "<path d=\"M \(f(s.end.x)) \(f(s.end.y)) A \(f(r)) \(f(r)) 0 0 1 \(f(open.x)) \(f(open.y))\" stroke-width=\"0.01\" stroke-dasharray=\"0.04 0.04\"/>\n"
        }
        for opening in plan.openings {
            out += "<line x1=\"\(f(opening.start.x))\" y1=\"\(f(opening.start.y))\" x2=\"\(f(opening.end.x))\" y2=\"\(f(opening.end.y))\" stroke=\"#999\" stroke-width=\"0.01\" stroke-dasharray=\"0.05 0.04\"/>\n"
        }
        out += "</g>\n<g id=\"dimensions\" font-size=\"0.13\" fill=\"#666\" text-anchor=\"middle\">\n"
        let center = CGPoint(x: plan.bounds.midX, y: plan.bounds.midY)
        for wall in plan.walls where wall.length > 0.5 {
            let (position, degrees) = dimensionPlacement(wall, center: center)
            out += "<text x=\"\(f(position.x))\" y=\"\(f(position.y))\" transform=\"rotate(\(f(degrees)) \(f(position.x)) \(f(position.y)))\">\(escape(UnitFormat.length(wall.length, system)))</text>\n"
        }
        out += "</g>\n<g id=\"rooms\" text-anchor=\"middle\" fill=\"#1a1b1f\">\n"
        for room in plan.labels {
            out += "<text x=\"\(f(room.position.x))\" y=\"\(f(room.position.y))\" font-size=\"0.2\" font-weight=\"bold\">\(escape(room.name))</text>\n"
            if let area = room.area {
                out += "<text x=\"\(f(room.position.x))\" y=\"\(f(room.position.y + 0.24))\" font-size=\"0.15\" fill=\"#666\">\(escape(UnitFormat.area(area, system)))</text>\n"
            }
        }
        out += "</g>\n</svg>\n"
        return out
    }

    // MARK: DXF

    static func dxf(_ plan: FloorPlanGeometry, system: MeasurementSystem) -> String {
        var entities = DXFWriter()
        for polygon in plan.floors where polygon.count >= 3 { entities.polyline(polygon, layer: "FLOOR", closed: true) }
        for object in plan.objects {
            entities.polyline(object.corners, layer: "FURNITURE", closed: true)
            entities.text(FloorPlanData.displayName(forCategory: object.category), at: object.center, height: 0.1, layer: "FURNITURE")
        }
        for wall in plan.wallPieces() {
            let n = normal(wall), h = wall.thickness / 2
            let corners = [CGPoint(x: wall.start.x + n.x * h, y: wall.start.y + n.y * h), CGPoint(x: wall.end.x + n.x * h, y: wall.end.y + n.y * h),
                           CGPoint(x: wall.end.x - n.x * h, y: wall.end.y - n.y * h), CGPoint(x: wall.start.x - n.x * h, y: wall.start.y - n.y * h)]
            entities.polyline(corners, layer: "WALLS", closed: true)
        }
        for window in plan.windows {
            let n = normal(window)
            for side in [-1.0, 1.0] {
                let o = window.thickness * 0.28 * side
                entities.line(CGPoint(x: window.start.x + n.x * o, y: window.start.y + n.y * o),
                              CGPoint(x: window.end.x + n.x * o, y: window.end.y + n.y * o), layer: "WINDOWS")
            }
        }
        for door in plan.doors {
            let s = door.segment, r = s.length, a = s.angle
            let open = CGPoint(x: s.start.x + cos(a + .pi / 2) * r, y: s.start.y + sin(a + .pi / 2) * r)
            entities.line(s.start, open, layer: "DOORS")
            // Plan angles are measured with Y down; DXF is Y up, so angles flip sign.
            let startDegrees = -(a + .pi / 2) * 180 / .pi, endDegrees = -a * 180 / .pi
            entities.arc(center: s.start, radius: r, startDegrees: startDegrees, endDegrees: endDegrees, layer: "DOORS")
        }
        for opening in plan.openings { entities.line(opening.start, opening.end, layer: "OPENINGS") }
        let center = CGPoint(x: plan.bounds.midX, y: plan.bounds.midY)
        for wall in plan.walls where wall.length > 0.5 {
            let (position, degrees) = dimensionPlacement(wall, center: center)
            entities.text(UnitFormat.length(wall.length, system), at: position, height: 0.12, layer: "DIMENSIONS", degrees: -degrees)
        }
        for room in plan.labels {
            entities.text(room.name, at: room.position, height: 0.2, layer: "ROOMS")
            if let area = room.area {
                entities.text(UnitFormat.area(area, system), at: CGPoint(x: room.position.x, y: room.position.y + 0.28), height: 0.14, layer: "ROOMS")
            }
        }
        let layers: [(String, Int)] = [("WALLS", 7), ("DOORS", 30), ("WINDOWS", 4), ("OPENINGS", 8), ("FURNITURE", 8), ("FLOOR", 9), ("ROOMS", 3), ("DIMENSIONS", 2)]
        var out = "0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1009\n9\n$INSUNITS\n70\n6\n0\nENDSEC\n"
        out += "0\nSECTION\n2\nTABLES\n0\nTABLE\n2\nLAYER\n70\n\(layers.count)\n"
        for (name, color) in layers {
            out += "0\nLAYER\n2\n\(name)\n70\n0\n62\n\(color)\n6\nCONTINUOUS\n"
        }
        out += "0\nENDTAB\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n" + entities.body + "0\nENDSEC\n0\nEOF\n"
        return out
    }

    // MARK: Helpers

    private static func dimensionPlacement(_ wall: FloorPlanGeometry.Segment, center: CGPoint) -> (CGPoint, Double) {
        let mid = wall.midpoint
        var n = normal(wall)
        if (center.x - mid.x) * n.x + (center.y - mid.y) * n.y < 0 { n = CGPoint(x: -n.x, y: -n.y) }
        var angle = wall.angle
        if angle > .pi / 2 { angle -= .pi } else if angle <= -.pi / 2 { angle += .pi }
        let distance = wall.thickness / 2 + 0.18
        return (CGPoint(x: mid.x + n.x * distance, y: mid.y + n.y * distance + 0.04), angle * 180 / .pi)
    }

    private static func normal(_ segment: FloorPlanGeometry.Segment) -> CGPoint {
        CGPoint(x: -sin(segment.angle), y: cos(segment.angle))
    }

    private static func points(_ polygon: [CGPoint]) -> String {
        polygon.map { "\(f($0.x)),\(f($0.y))" }.joined(separator: " ")
    }

    private static func f(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Minimal DXF R12 entity writer (group code / value pairs). Plan Y is flipped for DXF.
private struct DXFWriter {
    private(set) var body = ""

    private mutating func pair(_ code: Int, _ value: String) {
        body += "\(code)\n\(value)\n"
    }

    private mutating func point(_ p: CGPoint, x: Int = 10) {
        pair(x, String(format: "%.4f", p.x))
        pair(x + 10, String(format: "%.4f", -p.y))
        pair(x + 20, "0.0")
    }

    mutating func line(_ a: CGPoint, _ b: CGPoint, layer: String) {
        pair(0, "LINE")
        pair(8, layer)
        point(a)
        point(b, x: 11)
    }

    mutating func polyline(_ points: [CGPoint], layer: String, closed: Bool) {
        pair(0, "POLYLINE")
        pair(8, layer)
        pair(66, "1")
        pair(70, closed ? "1" : "0")
        point(.zero)
        for p in points {
            pair(0, "VERTEX")
            pair(8, layer)
            point(p)
        }
        pair(0, "SEQEND")
        pair(8, layer)
    }

    mutating func arc(center: CGPoint, radius: Double, startDegrees: Double, endDegrees: Double, layer: String) {
        pair(0, "ARC")
        pair(8, layer)
        point(center)
        pair(40, String(format: "%.4f", radius))
        pair(50, String(format: "%.4f", startDegrees))
        pair(51, String(format: "%.4f", endDegrees))
    }

    mutating func text(_ value: String, at p: CGPoint, height: Double, layer: String, degrees: Double = 0) {
        pair(0, "TEXT")
        pair(8, layer)
        point(p)
        pair(40, String(format: "%.3f", height))
        // R12 DXF is plain ASCII.
        let ascii = value.replacingOccurrences(of: "²", with: "2").replacingOccurrences(of: "′", with: "'")
            .replacingOccurrences(of: "″", with: "\"").replacingOccurrences(of: "\n", with: " ")
        pair(1, ascii)
        if degrees != 0 { pair(50, String(format: "%.3f", degrees)) }
        pair(72, "1")
        point(p, x: 11)
    }
}
