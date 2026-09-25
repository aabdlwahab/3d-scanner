import Foundation

enum TextureQuality: String, CaseIterable, Identifiable {
    case compact, standard, high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: "Compact"
        case .standard: "Standard"
        case .high: "High"
        }
    }

    var detail: String {
        switch self {
        case .compact: "One 4K texture — small files, quick sharing"
        case .standard: "Two 4K textures — best balance"
        case .high: "Four 4K textures — sharpest, larger files"
        }
    }

    var pages: Int {
        switch self {
        case .compact: 1
        case .standard: 2
        case .high: 4
        }
    }
}

/// Keys and typed accessors for user preferences (`@AppStorage` in views uses the same keys).
enum AppSettings {
    static let unitsKey = "units"
    static let textureQualityKey = "textureQuality"
    static let pointCloudKey = "buildPointCloud"
    static let lockWhiteBalanceKey = "lockWhiteBalance"
    static let showMeshTipsKey = "showCaptureTips"

    static var units: MeasurementSystem {
        UserDefaults.standard.string(forKey: unitsKey).flatMap(MeasurementSystem.init) ?? .preferred
    }

    static var textureQuality: TextureQuality {
        UserDefaults.standard.string(forKey: textureQualityKey).flatMap(TextureQuality.init) ?? .standard
    }

    static var buildPointCloud: Bool {
        UserDefaults.standard.object(forKey: pointCloudKey) as? Bool ?? true
    }

    static var lockWhiteBalance: Bool {
        UserDefaults.standard.object(forKey: lockWhiteBalanceKey) as? Bool ?? true
    }

    static var processingOptions: ProcessingOptions {
        ProcessingOptions(maxTexturePages: textureQuality.pages, texturePageSize: 4096, buildPointCloud: buildPointCloud)
    }

    /// Where exported files go. Documents is visible in the Files app ("On My iPhone › ScanSpace").
    static var exportsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Exports", isDirectory: true)
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
