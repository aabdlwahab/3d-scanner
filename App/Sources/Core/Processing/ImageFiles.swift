import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// ImageIO / CoreGraphics helpers shared by processing, exporting and thumbnails.
enum ImageFiles {
    enum ImageError: LocalizedError {
        case contextCreationFailed
        case encodeFailed(URL)

        var errorDescription: String? {
            switch self {
            case .contextCreationFailed: "Could not allocate image memory."
            case .encodeFailed(let url): "Could not write \(url.lastPathComponent)."
            }
        }
    }

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// Decodes a downscaled version of an image (fast path for thumbnails and point colors).
    static func loadImage(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double) throws {
        try write(image, to: url, type: UTType.jpeg, properties: [kCGImageDestinationLossyCompressionQuality: quality])
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        try write(image, to: url, type: UTType.png, properties: [:])
    }

    static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func write(_ image: CGImage, to url: URL, type: UTType, properties: [CFString: Any]) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ImageError.encodeFailed(url)
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageError.encodeFailed(url) }
    }

    /// Draws an image into a tightly packed RGBA8 buffer of the given size (resampling if needed).
    static func rgbaPixels(of image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: sRGB,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? pixels : nil
    }
}
