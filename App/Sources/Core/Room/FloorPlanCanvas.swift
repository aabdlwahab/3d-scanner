import SwiftUI

struct FloorPlanStyle {
    var background: Color
    var floor: Color
    var wall: Color
    var window: Color
    var door: Color
    var text: Color
    var secondaryText: Color
    var objectAlpha: Double

    static let dark = FloorPlanStyle(background: Color(red: 0.035, green: 0.04, blue: 0.07),
                                     floor: Color(red: 0.12, green: 0.13, blue: 0.19),
                                     wall: Color(red: 0.93, green: 0.94, blue: 0.97),
                                     window: Color(red: 0.45, green: 0.85, blue: 0.98),
                                     door: Color(red: 0.98, green: 0.72, blue: 0.45),
                                     text: .white, secondaryText: Color(white: 0.7), objectAlpha: 0.30)

    static let paper = FloorPlanStyle(background: .white,
                                      floor: Color(red: 0.965, green: 0.955, blue: 0.94),
                                      wall: Color(red: 0.13, green: 0.14, blue: 0.17),
                                      window: Color(red: 0.15, green: 0.55, blue: 0.85),
                                      door: Color(red: 0.55, green: 0.36, blue: 0.22),
                                      text: Color(red: 0.1, green: 0.1, blue: 0.12), secondaryText: Color(white: 0.4),
                                      objectAlpha: 0.22)
}

/// Draws a dimensioned top-down floor plan. Pan/zoom is applied by the caller through `zoom`
/// and `offset` (in view points).
struct FloorPlanCanvas: View {
    let geometry: FloorPlanGeometry
    var style: FloorPlanStyle = .dark
    var system: MeasurementSystem = .metric
    var zoom: CGFloat = 1
    var offset: CGSize = .zero
    var showDimensions = true
    var showObjects = true

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
        .background(style.background)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let bounds = geometry.bounds.insetBy(dx: -0.6, dy: -0.6)
        let fit = min(size.width / max(bounds.width, 0.1), size.height / max(bounds.height, 0.1))
        let scale = fit * zoom
        let origin = CGPoint(x: size.width / 2 - bounds.midX * scale + offset.width,
                             y: size.height / 2 - bounds.midY * scale + offset.height)
        func p(_ point: CGPoint) -> CGPoint { CGPoint(x: origin.x + point.x * scale, y: origin.y + point.y * scale) }

        // Floors.
        for polygon in geometry.floors where polygon.count >= 3 {
            var path = Path()
            path.addLines(polygon.map(p))
            path.closeSubpath()
            context.fill(path, with: .color(style.floor))
        }

        // Furniture footprints.
        if showObjects {
            for object in geometry.objects {
                var path = Path()
                path.addLines(object.corners.map(p))
                path.closeSubpath()
                let rgb = FloorPlanData.color(forCategory: object.category)
                let color = Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
                context.fill(path, with: .color(color.opacity(style.objectAlpha)))
                context.stroke(path, with: .color(color.opacity(0.9)), lineWidth: max(0.75, scale * 0.012))
                let width = hypot(object.corners[1].x - object.corners[0].x, object.corners[1].y - object.corners[0].y) * scale
                let depth = hypot(object.corners[2].x - object.corners[1].x, object.corners[2].y - object.corners[1].y) * scale
                if width > 44, depth > 22 {
                    let label = Text(FloorPlanData.displayName(forCategory: object.category))
                        .font(.system(size: min(12, max(8, scale * 0.09)), weight: .medium))
                        .foregroundColor(style.secondaryText)
                    context.draw(label, at: p(object.center))
                }
            }
        }

        // Walls.
        let wallWidth = max(2, CGFloat(RoomSceneBuilder.wallThickness) * 1.4 * scale)
        var walls = Path()
        for wall in geometry.walls {
            walls.move(to: p(wall.start))
            walls.addLine(to: p(wall.end))
        }
        context.stroke(walls, with: .color(style.wall), style: StrokeStyle(lineWidth: wallWidth, lineCap: .square))

        // Openings cut into walls.
        let cutWidth = wallWidth + 2
        for opening in geometry.openings {
            cut(opening, in: &context, p: p, width: cutWidth)
            context.stroke(line(opening, p: p), with: .color(style.secondaryText.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        for window in geometry.windows {
            cut(window, in: &context, p: p, width: cutWidth)
            let normal = CGPoint(x: -sin(window.angle), y: cos(window.angle))
            let gap = wallWidth * 0.28
            for side in [-1.0, 1.0] {
                var path = Path()
                path.move(to: p(window.start) + normal * (gap * side))
                path.addLine(to: p(window.end) + normal * (gap * side))
                context.stroke(path, with: .color(style.window), lineWidth: max(1, wallWidth * 0.18))
            }
        }
        for door in geometry.doors {
            cut(door.segment, in: &context, p: p, width: cutWidth)
            let hinge = p(door.segment.start)
            let radius = door.segment.length * scale
            let angle = door.segment.angle
            let normal = CGPoint(x: -sin(angle), y: cos(angle))
            let open = hinge + normal * radius
            var leaf = Path()
            leaf.move(to: hinge)
            leaf.addLine(to: open)
            context.stroke(leaf, with: .color(style.door), lineWidth: max(1.2, wallWidth * 0.22))
            var arc = Path()
            arc.addArc(center: hinge, radius: radius, startAngle: .radians(angle), endAngle: .radians(angle + .pi / 2), clockwise: false)
            context.stroke(arc, with: .color(style.door.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }

        // Wall dimensions.
        if showDimensions {
            let center = CGPoint(x: geometry.bounds.midX, y: geometry.bounds.midY)
            for wall in geometry.walls where wall.length * Double(scale) > 46 {
                let mid = wall.midpoint
                var normal = CGPoint(x: -sin(wall.angle), y: cos(wall.angle))
                // Put the label on the side facing the plan center.
                if (center.x - mid.x) * normal.x + (center.y - mid.y) * normal.y < 0 { normal = normal * -1 }
                let position = p(mid) + normal * (wallWidth / 2 + 9)
                var angle = wall.angle
                if angle > .pi / 2 { angle -= .pi } else if angle <= -.pi / 2 { angle += .pi }
                var label = context
                label.translateBy(x: position.x, y: position.y)
                label.rotate(by: .radians(angle))
                label.draw(Text(UnitFormat.length(wall.length, system))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(style.secondaryText), at: .zero)
            }
        }

        // Room names and areas.
        for room in geometry.labels {
            let center = p(room.position)
            let name = Text(room.name).font(.system(size: 13, weight: .bold)).foregroundColor(style.text)
            guard let area = room.area else {
                context.draw(name, at: center)
                continue
            }
            context.draw(name, at: CGPoint(x: center.x, y: center.y - 8))
            context.draw(Text(UnitFormat.area(area, system)).font(.system(size: 11, weight: .medium))
                .foregroundColor(style.secondaryText), at: CGPoint(x: center.x, y: center.y + 9))
        }

        drawScaleBar(in: &context, size: size, scale: scale)
    }

    private func line(_ segment: FloorPlanGeometry.Segment, p: (CGPoint) -> CGPoint) -> Path {
        var path = Path()
        path.move(to: p(segment.start))
        path.addLine(to: p(segment.end))
        return path
    }

    private func cut(_ segment: FloorPlanGeometry.Segment, in context: inout GraphicsContext, p: (CGPoint) -> CGPoint, width: CGFloat) {
        context.stroke(line(segment, p: p), with: .color(style.floor), style: StrokeStyle(lineWidth: width, lineCap: .butt))
    }

    private func drawScaleBar(in context: inout GraphicsContext, size: CGSize, scale: CGFloat) {
        let unit: Double = system == .metric ? 1 : 0.3048 * 3
        var length = unit
        while length * Double(scale) < 50 { length *= 2 }
        while length * Double(scale) > 140 && length > unit / 4 { length /= 2 }
        let barWidth = CGFloat(length) * scale
        let start = CGPoint(x: 18, y: size.height - 22)
        var path = Path()
        path.move(to: CGPoint(x: start.x, y: start.y - 5))
        path.addLine(to: start)
        path.addLine(to: CGPoint(x: start.x + barWidth, y: start.y))
        path.addLine(to: CGPoint(x: start.x + barWidth, y: start.y - 5))
        context.stroke(path, with: .color(style.secondaryText), lineWidth: 1.5)
        context.draw(Text(UnitFormat.length(length, system)).font(.system(size: 10, weight: .medium))
            .foregroundColor(style.secondaryText), at: CGPoint(x: start.x + barWidth / 2, y: start.y - 12))
    }
}

private func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
private func * (a: CGPoint, s: CGFloat) -> CGPoint { CGPoint(x: a.x * s, y: a.y * s) }
