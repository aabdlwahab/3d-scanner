import Foundation

/// Fast text builder for large ASCII exports (OBJ, PLY headers). Formatting millions of floats
/// with `String(format:)` is slow, so numbers are written as fixed-point digits directly.
struct ASCIIBuffer {
    private(set) var bytes: [UInt8] = []

    init(reserving capacity: Int = 0) {
        bytes.reserveCapacity(capacity)
    }

    mutating func append(_ string: String) {
        bytes.append(contentsOf: string.utf8)
    }

    mutating func append(byte: UInt8) {
        bytes.append(byte)
    }

    mutating func append(_ value: Int) {
        if value < 0 {
            bytes.append(UInt8(ascii: "-"))
            appendUnsigned(UInt64(-value))
        } else {
            appendUnsigned(UInt64(value))
        }
    }

    /// Appends a float with `decimals` digits after the point (trailing zeros trimmed).
    mutating func append(_ value: Float, decimals: Int = 5) {
        guard value.isFinite else {
            bytes.append(UInt8(ascii: "0"))
            return
        }
        var scale: Double = 1
        for _ in 0..<decimals { scale *= 10 }
        var scaled = (Double(value) * scale).rounded()
        if scaled < 0 {
            bytes.append(UInt8(ascii: "-"))
            scaled = -scaled
        }
        let fixed = UInt64(scaled)
        let divisor = UInt64(scale)
        appendUnsigned(fixed / divisor)
        var fraction = fixed % divisor
        guard fraction != 0, decimals > 0 else { return }
        var digits = [UInt8](repeating: UInt8(ascii: "0"), count: decimals)
        var i = decimals - 1
        while i >= 0 {
            digits[i] = UInt8(ascii: "0") + UInt8(fraction % 10)
            fraction /= 10
            i -= 1
        }
        var end = decimals
        while end > 0 && digits[end - 1] == UInt8(ascii: "0") { end -= 1 }
        bytes.append(UInt8(ascii: "."))
        bytes.append(contentsOf: digits[0..<end])
    }

    private mutating func appendUnsigned(_ value: UInt64) {
        if value < 10 {
            bytes.append(UInt8(ascii: "0") + UInt8(value))
            return
        }
        var digits = [UInt8]()
        var v = value
        while v > 0 {
            digits.append(UInt8(ascii: "0") + UInt8(v % 10))
            v /= 10
        }
        bytes.append(contentsOf: digits.reversed())
    }

    var data: Data { Data(bytes) }
}
