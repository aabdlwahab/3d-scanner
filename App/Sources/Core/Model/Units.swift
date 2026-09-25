import Foundation

enum MeasurementSystem: String, CaseIterable, Identifiable {
    case metric, imperial

    var id: String { rawValue }
    var title: String { self == .metric ? "Metric (m)" : "Imperial (ft)" }

    static var preferred: MeasurementSystem {
        Locale.current.measurementSystem == .metric ? .metric : .imperial
    }
}

enum UnitFormat {
    static func length(_ meters: Double, _ system: MeasurementSystem) -> String {
        switch system {
        case .metric:
            if meters < 1 { return "\(Int((meters * 100).rounded())) cm" }
            return String(format: "%.2f m", meters)
        case .imperial:
            let totalInches = (meters / 0.0254).rounded()
            let feet = Int(totalInches / 12)
            let inches = Int(totalInches) - feet * 12
            if feet == 0 { return "\(inches)″" }
            return inches == 0 ? "\(feet)′" : "\(feet)′ \(inches)″"
        }
    }

    static func area(_ squareMeters: Double, _ system: MeasurementSystem) -> String {
        switch system {
        case .metric:
            return squareMeters < 10 ? String(format: "%.1f m²", squareMeters) : "\(Int(squareMeters.rounded())) m²"
        case .imperial:
            return "\(Int((squareMeters * 10.7639).rounded())) ft²"
        }
    }

    static func dimensions(_ size: [Double], _ system: MeasurementSystem) -> String {
        size.map { length($0, system) }.joined(separator: " × ")
    }

    static func count(_ n: Int) -> String {
        switch n {
        case 1_000_000...: String(format: "%.1fM", Double(n) / 1_000_000)
        case 10_000...: "\(n / 1000)K"
        case 1000...: String(format: "%.1fK", Double(n) / 1000)
        default: "\(n)"
        }
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
