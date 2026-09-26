import Foundation
import simd

/// A look for AI renders: materials and mood, phrased for the diffusion prompt.
struct AIRenderStyle: Identifiable, Hashable {
    let id: String
    let title: String
    /// Materials and colors, kept short (Stable Diffusion reads at most 77 tokens).
    let materials: String
    /// How to describe common furniture in this style.
    let sofa: String
    let wood: String

    static let scandinavian = AIRenderStyle(id: "scandinavian", title: "Scandinavian",
                                          materials: "light oak wood floor, white walls, linen textiles, green plants",
                                          sofa: "light grey fabric sofa", wood: "light oak")
    static let japandi = AIRenderStyle(id: "japandi", title: "Japandi",
                                     materials: "warm oak floor, beige plaster walls, rattan and paper lamps, minimal decor",
                                     sofa: "beige boucle sofa", wood: "walnut")
    static let modern = AIRenderStyle(id: "modern", title: "Modern Luxury",
                                    materials: "large marble tiles, warm white walls, brass accents, velvet",
                                    sofa: "dark green velvet sofa", wood: "dark walnut")
    static let industrial = AIRenderStyle(id: "industrial", title: "Industrial Loft",
                                        materials: "polished concrete floor, white brick walls, black metal, leather",
                                        sofa: "cognac leather sofa", wood: "reclaimed wood")

    static let all: [AIRenderStyle] = [.scandinavian, .japandi, .modern, .industrial]
}

enum RenderPrompts {
    static let negative = "cartoon, anime, illustration, painting, drawing, sketch, cgi, 3d render, lowres, blurry, "
        + "low quality, deformed, distorted, warped, text, watermark, signature, people, person, oversaturated"

    /// Human name for the kind of room a camera looks at.
    static func roomName(_ camera: PlanCamera, objects: [FloorPlanData.Object]) -> String {
        if let label = camera.roomLabel, label != "unidentified", !label.hasPrefix("Room") {
            return FloorPlanData.displayName(forSection: label).lowercased()
        }
        let categories = Set(objects.map(\.category))
        if categories.contains("bed") { return "bedroom" }
        if categories.contains("toilet") || categories.contains("bathtub") { return "bathroom" }
        if categories.contains("stove") || categories.contains("refrigerator") || categories.contains("oven") { return "kitchen" }
        if categories.contains("sofa") || categories.contains("television") { return "living room" }
        if categories.contains("table") { return "dining room" }
        return "room"
    }

    /// Short furniture phrases for the objects in view, in order, without repeats. `context` is
    /// every object in the plan (a sink next to a toilet is a washbasin, not a kitchen sink).
    static func furniture(_ objects: [FloorPlanData.Object], context: [FloorPlanData.Object], style: AIRenderStyle, limit: Int = 5) -> [String] {
        var phrases: [String] = []
        for object in objects {
            let phrase = self.phrase(for: object, context: context, style: style)
            if !phrases.contains(phrase) { phrases.append(phrase) }
            if phrases.count == limit { break }
        }
        return phrases
    }

    static func phrase(for object: FloorPlanData.Object, context: [FloorPlanData.Object], style: AIRenderStyle) -> String {
        let phrase: String
        switch object.category {
        case "sofa": phrase = style.sofa
        case "table": phrase = object.size.y < 0.6 ? "\(style.wood) coffee table" : "\(style.wood) dining table with chairs"
        case "chair": phrase = object.size.y < 0.85 && object.size.x > 0.7 ? "armchair" : "dining chairs"
        case "bed": phrase = "double bed with white bedding"
        case "storage":
            if object.size.y > 1.5 { phrase = min(object.size.x, object.size.z) >= 0.5 ? "tall \(style.wood) wardrobe" : "\(style.wood) bookshelf" }
            else if object.size.y < 0.7 { phrase = "\(style.wood) nightstand" }
            else { phrase = "\(style.wood) cabinets" }
        case "refrigerator", "stove", "oven", "dishwasher": phrase = "fitted kitchen with appliances"
        case "sink":
            let bathroom = context.contains { ($0.category == "toilet" || $0.category == "bathtub")
                && simd_distance($0.matrix.translation, object.matrix.translation) < 2.5 }
            phrase = bathroom ? "washbasin vanity" : "kitchen sink"
        case "toilet": phrase = "toilet"
        case "bathtub": phrase = "white bathtub"
        case "washerDryer": phrase = "washing machine"
        case "television": phrase = "wall-mounted tv"
        case "fireplace": phrase = "fireplace"
        default: phrase = object.category
        }
        return phrase
    }

    /// Prompt for Stable Diffusion with ControlNets (the geometry comes from the control images).
    static func diffusionPrompt(camera: PlanCamera, objects: [FloorPlanData.Object], context: [FloorPlanData.Object], style: AIRenderStyle) -> String {
        let things = furniture(objects, context: context, style: style).joined(separator: ", ")
        if !camera.isInterior {
            return "photorealistic 3d floor plan of a furnished apartment, cutaway view from above, \(style.title.lowercased()) style, "
                + "\(style.materials), \(things), soft daylight, architectural visualization, highly detailed"
        }
        let room = roomName(camera, objects: objects)
        return "RAW photo, interior photography of a \(style.title.lowercased()) \(room), \(style.materials), \(things), "
            + "large window, soft natural light, wide angle, realistic, highly detailed, 8k"
    }

    /// Instruction for image-editing models that repaint the clay render. Objects get rough screen
    /// positions ("on the left", "in the foreground") so the model knows which block is which.
    static func editPrompt(camera: PlanCamera, visible: [VisibleObject], context: [FloorPlanData.Object], style: AIRenderStyle) -> String {
        var placed: [String] = []
        var seen = Set<String>()
        for item in visible where placed.count < 7 {
            let phrase = self.phrase(for: item.object, context: context, style: style)
            guard seen.insert(phrase).inserted else { continue }
            let x = item.center.x, y = item.center.y
            let side = x < 0.36 ? "on the left" : x > 0.64 ? "on the right" : "in the middle"
            let depth = y > 0.72 ? " in the foreground" : y < 0.45 ? " at the back" : ""
            placed.append("\(phrase) \(side)\(depth)")
        }
        let list = placed.isEmpty ? "" : " The grey blocks are: \(placed.joined(separator: "; "))."
        if !camera.isInterior {
            return "Turn this plain 3D clay model into a photorealistic 3D floor plan render of a furnished apartment, cutaway "
                + "dollhouse view from above. Keep the exact camera angle, layout, walls, doors, windows and the position and "
                + "size of every piece of furniture.\(list) \(style.title) style: \(style.materials). Realistic materials and "
                + "textures, soft daylight with gentle shadows, white background."
        }
        let room = roomName(camera, objects: visible.map(\.object))
        return "Turn this plain 3D clay render into a photorealistic interior photograph of a \(room). Keep the exact camera "
            + "angle, room shape, walls, doors, windows and the position and size of every piece of furniture; do not add "
            + "or move furniture.\(list) \(style.title) style: \(style.materials). Realistic materials, soft natural daylight "
            + "through the windows, professional interior photography."
    }

    /// Instruction for cleaning up a render of the raw textured scan into a photo of the same room.
    static func scanCleanupPrompt(camera: PlanCamera) -> String {
        let subject = camera.isInterior ? "an interior photograph of this exact room" : "a photorealistic 3D cutaway render of this exact apartment, seen from above"
        return "This is a rough 3D scan with holes, stretched textures and missing patches. Turn it into \(subject). Keep the "
            + "exact camera angle, walls, doors, windows, floor, colors, materials and any furniture; fill the holes and "
            + "straighten the surfaces. Clean, realistic lighting, sharp details, professional photography."
    }
}
