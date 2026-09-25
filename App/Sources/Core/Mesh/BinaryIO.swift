import Foundation
import simd

enum BinaryIOError: LocalizedError {
    case badMagic(expected: String)
    case truncated
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .badMagic(let expected): "The file is not a valid \(expected) file."
        case .truncated: "The file ended unexpectedly."
        case .unsupportedVersion(let v): "Unsupported file version \(v)."
        }
    }
}

/// Little-endian binary writer. All Apple platforms are little-endian, so arrays are
/// written as raw memory.
struct BinaryWriter {
    private(set) var data = Data()

    init(reserving capacity: Int = 0) {
        data.reserveCapacity(capacity)
    }

    mutating func writeMagic(_ magic: String) {
        data.append(contentsOf: Array(magic.utf8))
    }

    mutating func write<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    mutating func write(_ value: Float) {
        write(value.bitPattern)
    }

    /// Writes a trivially-copyable array as raw bytes.
    mutating func writeRaw<T>(_ array: [T]) {
        array.withUnsafeBytes { data.append(contentsOf: $0) }
    }

    /// Writes 3-component vectors packed as 12 bytes each (SIMD3<Float> is 16 bytes in memory).
    mutating func writePacked(_ vectors: [SIMD3<Float>]) {
        var packed = [Float]()
        packed.reserveCapacity(vectors.count * 3)
        for v in vectors {
            packed.append(v.x)
            packed.append(v.y)
            packed.append(v.z)
        }
        writeRaw(packed)
    }
}

struct BinaryReader {
    let data: Data
    private(set) var offset = 0

    init(data: Data) {
        self.data = data
    }

    var remaining: Int { data.count - offset }

    mutating func expectMagic(_ magic: String) throws {
        let bytes = Array(magic.utf8)
        guard remaining >= bytes.count else { throw BinaryIOError.truncated }
        let actual = data.subdata(in: data.startIndex + offset ..< data.startIndex + offset + bytes.count)
        guard Array(actual) == bytes else { throw BinaryIOError.badMagic(expected: magic) }
        offset += bytes.count
    }

    mutating func read<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { throw BinaryIOError.truncated }
        var value: T = 0
        _ = withUnsafeMutableBytes(of: &value) { dst in
            data.copyBytes(to: dst, from: data.startIndex + offset ..< data.startIndex + offset + size)
        }
        offset += size
        return T(littleEndian: value)
    }

    mutating func readFloat() throws -> Float {
        Float(bitPattern: try read(UInt32.self))
    }

    mutating func readRaw<T>(_: T.Type, count: Int) throws -> [T] {
        let byteCount = count * MemoryLayout<T>.stride
        guard count >= 0, remaining >= byteCount else { throw BinaryIOError.truncated }
        let start = data.startIndex + offset
        let result = [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            let raw = UnsafeMutableRawBufferPointer(buffer)
            data.copyBytes(to: raw, from: start ..< start + byteCount)
            initialized = count
        }
        offset += byteCount
        return result
    }

    mutating func readPacked3(count: Int) throws -> [SIMD3<Float>] {
        let floats = try readRaw(Float.self, count: count * 3)
        var result = [SIMD3<Float>]()
        result.reserveCapacity(count)
        var i = 0
        while i < floats.count {
            result.append(SIMD3(floats[i], floats[i + 1], floats[i + 2]))
            i += 3
        }
        return result
    }
}

// MARK: - File formats

extension RawMesh {
    private static let magic = "SSRM"

    func write(to url: URL) throws {
        var w = BinaryWriter(reserving: positions.count * 24 + indices.count * 4 + classes.count + 64)
        w.writeMagic(Self.magic)
        w.write(UInt32(1))
        w.write(UInt32(positions.count))
        w.write(UInt32(triangleCount))
        let hasNormals = normals.count == positions.count && !normals.isEmpty
        let hasClasses = classes.count == triangleCount && !classes.isEmpty
        w.write(UInt32((hasNormals ? 1 : 0) | (hasClasses ? 2 : 0)))
        w.writePacked(positions)
        if hasNormals { w.writePacked(normals) }
        w.writeRaw(indices)
        if hasClasses { w.writeRaw(classes) }
        try w.data.write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> RawMesh {
        var r = BinaryReader(data: try Data(contentsOf: url, options: .mappedIfSafe))
        try r.expectMagic(magic)
        let version = try r.read(UInt32.self)
        guard version == 1 else { throw BinaryIOError.unsupportedVersion(Int(version)) }
        let vertexCount = Int(try r.read(UInt32.self))
        let triangleCount = Int(try r.read(UInt32.self))
        let flags = try r.read(UInt32.self)
        var mesh = RawMesh()
        mesh.positions = try r.readPacked3(count: vertexCount)
        if flags & 1 != 0 { mesh.normals = try r.readPacked3(count: vertexCount) }
        mesh.indices = try r.readRaw(UInt32.self, count: triangleCount * 3)
        if flags & 2 != 0 { mesh.classes = try r.readRaw(UInt8.self, count: triangleCount) }
        return mesh
    }
}

extension TexturedMesh {
    private static let magic = "SSTM"

    func write(to url: URL) throws {
        var w = BinaryWriter(reserving: positions.count * 40 + triangleCount * 12 + 64)
        w.writeMagic(Self.magic)
        w.write(UInt32(1))
        w.write(UInt32(positions.count))
        w.write(UInt32(groups.count))
        w.write(UInt32(textureCount))
        let hasColors = colors.count == positions.count && !colors.isEmpty
        let hasClasses = classes.count == positions.count && !classes.isEmpty
        w.write(UInt32((hasColors ? 1 : 0) | (hasClasses ? 2 : 0)))
        w.writePacked(positions)
        w.writePacked(normals.count == positions.count ? normals : [SIMD3<Float>](repeating: SIMD3(0, 1, 0), count: positions.count))
        w.writeRaw(uvs.count == positions.count ? uvs : [SIMD2<Float>](repeating: .zero, count: positions.count))
        if hasColors { w.writeRaw(colors) }
        if hasClasses { w.writeRaw(classes) }
        for group in groups {
            w.write(Int32(group.textureIndex))
            w.write(UInt32(group.indices.count))
            w.writeRaw(group.indices)
        }
        try w.data.write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> TexturedMesh {
        var r = BinaryReader(data: try Data(contentsOf: url, options: .mappedIfSafe))
        try r.expectMagic(magic)
        let version = try r.read(UInt32.self)
        guard version == 1 else { throw BinaryIOError.unsupportedVersion(Int(version)) }
        let vertexCount = Int(try r.read(UInt32.self))
        let groupCount = Int(try r.read(UInt32.self))
        var mesh = TexturedMesh()
        mesh.textureCount = Int(try r.read(UInt32.self))
        let flags = try r.read(UInt32.self)
        mesh.positions = try r.readPacked3(count: vertexCount)
        mesh.normals = try r.readPacked3(count: vertexCount)
        mesh.uvs = try r.readRaw(SIMD2<Float>.self, count: vertexCount)
        if flags & 1 != 0 { mesh.colors = try r.readRaw(SIMD4<UInt8>.self, count: vertexCount) }
        if flags & 2 != 0 { mesh.classes = try r.readRaw(UInt8.self, count: vertexCount) }
        for _ in 0..<groupCount {
            let texture = Int(try r.read(Int32.self))
            let count = Int(try r.read(UInt32.self))
            mesh.groups.append(Group(textureIndex: texture, indices: try r.readRaw(UInt32.self, count: count)))
        }
        return mesh
    }
}

extension PointCloud {
    private static let magic = "SSPC"

    func write(to url: URL) throws {
        var w = BinaryWriter(reserving: positions.count * 16 + 16)
        w.writeMagic(Self.magic)
        w.write(UInt32(1))
        w.write(UInt32(positions.count))
        w.writePacked(positions)
        w.writeRaw(colors.count == positions.count ? colors : [SIMD4<UInt8>](repeating: SIMD4(200, 200, 200, 255), count: positions.count))
        try w.data.write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> PointCloud {
        var r = BinaryReader(data: try Data(contentsOf: url, options: .mappedIfSafe))
        try r.expectMagic(magic)
        let version = try r.read(UInt32.self)
        guard version == 1 else { throw BinaryIOError.unsupportedVersion(Int(version)) }
        let count = Int(try r.read(UInt32.self))
        var cloud = PointCloud()
        cloud.positions = try r.readPacked3(count: count)
        cloud.colors = try r.readRaw(SIMD4<UInt8>.self, count: count)
        return cloud
    }
}
