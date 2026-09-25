import SceneKit

#if canImport(UIKit)
import UIKit
typealias PlatformColor = UIColor
typealias PlatformImage = UIImage
typealias PlatformBezierPath = UIBezierPath
#else
import AppKit
typealias PlatformColor = NSColor
typealias PlatformImage = NSImage
typealias PlatformBezierPath = NSBezierPath
#endif

extension PlatformColor {
    convenience init(rgb: SIMD3<Float>, alpha: CGFloat = 1) {
        self.init(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: alpha)
    }

    static func from(cgColor: CGColor) -> PlatformColor? {
        #if canImport(UIKit)
        return UIColor(cgColor: cgColor)
        #else
        return NSColor(cgColor: cgColor)
        #endif
    }

    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension PlatformImage {
    /// CGImage backing the platform image.
    var cgImageRepresentation: CGImage? {
        #if canImport(UIKit)
        return cgImage
        #else
        return cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }
}

extension SCNVector3 {
    init(_ v: SIMD3<Float>) {
        self.init(v.x, v.y, v.z)
    }

    var simd: SIMD3<Float> { SIMD3(Float(x), Float(y), Float(z)) }
}
