import SwiftUI

/// Renders a printable floor plan sheet (A3 landscape) as PDF or PNG.
@MainActor
enum FloorPlanExporter {
    enum RenderError: LocalizedError {
        case failed

        var errorDescription: String? { "The floor plan couldn't be rendered." }
    }

    static func render(_ data: FloorPlanData, format: ExportFormat, to url: URL, title: String, units: MeasurementSystem) throws {
        let sheet = FloorPlanSheet(plan: FloorPlanGeometry(data: data), roomCount: data.roomCount, title: title, units: units)
            .frame(width: 1190, height: 842)
        let renderer = ImageRenderer(content: sheet)
        if format == .floorPlanPDF {
            var rendered = false
            renderer.render { size, draw in
                var box = CGRect(origin: .zero, size: size)
                guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
                context.beginPDFPage(nil)
                draw(context)
                context.endPDFPage()
                context.closePDF()
                rendered = true
            }
            if !rendered { throw RenderError.failed }
        } else {
            renderer.scale = 2
            guard let image = renderer.cgImage else { throw RenderError.failed }
            try ImageFiles.writePNG(image, to: url)
        }
    }
}

struct FloorPlanSheet: View {
    let plan: FloorPlanGeometry
    let roomCount: Int
    let title: String
    let units: MeasurementSystem

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 28, weight: .bold))
                    Text("\(UnitFormat.area(plan.floorArea, units)) · \(roomCount) room\(roomCount == 1 ? "" : "s") · \(Date().formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(size: 15))
                        .foregroundColor(FloorPlanStyle.paper.secondaryText)
                }
                Spacer()
                Text("ScanSpace").font(.system(size: 15, weight: .semibold)).foregroundColor(FloorPlanStyle.paper.secondaryText)
            }
            FloorPlanCanvas(geometry: plan, style: .paper, system: units)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.08)))
            Text("Measurements are approximate (LiDAR scan). Wall lengths are measured along wall centerlines.")
                .font(.system(size: 11))
                .foregroundColor(FloorPlanStyle.paper.secondaryText)
        }
        .padding(36)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }
}
