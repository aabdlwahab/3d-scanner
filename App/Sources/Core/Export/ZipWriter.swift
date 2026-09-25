import Foundation

/// Minimal ZIP writer (deflate or stored entries, no ZIP64) for bundling multi-file exports
/// such as OBJ + MTL + textures.
enum ZipWriter {
    struct Entry {
        var name: String
        var source: URL
    }

    enum ZipError: LocalizedError {
        case tooLarge

        var errorDescription: String? { "The export is too large to zip (over 4 GB)." }
    }

    static func write(_ entries: [Entry], to url: URL) throws {
        var archive = Data()
        var central = Data()
        let (dosTime, dosDate) = dosTimestamp(Date())

        for entry in entries {
            let contents = try Data(contentsOf: entry.source, options: .mappedIfSafe)
            let crc = CRC32.checksum(contents)
            // Already-compressed images are stored; everything else is deflated when it helps.
            var method: UInt16 = 0
            var payload = contents
            let ext = entry.source.pathExtension.lowercased()
            if !["jpg", "jpeg", "png", "heic", "usdz", "zip", "glb"].contains(ext),
               let deflated = try? (contents as NSData).compressed(using: .zlib) as Data,
               deflated.count < contents.count {
                method = 8
                payload = deflated
            }
            guard archive.count < Int(UInt32.max) - payload.count else { throw ZipError.tooLarge }
            let nameBytes = Array(entry.name.utf8)
            let localOffset = UInt32(archive.count)

            var local = BinaryWriter()
            local.write(UInt32(0x0403_4B50))
            local.write(UInt16(20))            // version needed
            local.write(UInt16(0x0800))        // UTF-8 names
            local.write(method)
            local.write(dosTime)
            local.write(dosDate)
            local.write(crc)
            local.write(UInt32(payload.count))
            local.write(UInt32(contents.count))
            local.write(UInt16(nameBytes.count))
            local.write(UInt16(0))
            local.writeRaw(nameBytes)
            archive.append(local.data)
            archive.append(payload)

            var header = BinaryWriter()
            header.write(UInt32(0x0201_4B50))
            header.write(UInt16(0x031E))       // made by: Unix, spec 3.0
            header.write(UInt16(20))
            header.write(UInt16(0x0800))
            header.write(method)
            header.write(dosTime)
            header.write(dosDate)
            header.write(crc)
            header.write(UInt32(payload.count))
            header.write(UInt32(contents.count))
            header.write(UInt16(nameBytes.count))
            header.write(UInt16(0))            // extra length
            header.write(UInt16(0))            // comment length
            header.write(UInt16(0))            // disk number
            header.write(UInt16(0))            // internal attributes
            header.write(UInt32(0o100644) << 16) // external attributes: regular file, rw-r--r--
            header.write(localOffset)
            header.writeRaw(nameBytes)
            central.append(header.data)
        }

        let centralOffset = UInt32(archive.count)
        archive.append(central)
        var end = BinaryWriter()
        end.write(UInt32(0x0605_4B50))
        end.write(UInt16(0))
        end.write(UInt16(0))
        end.write(UInt16(entries.count))
        end.write(UInt16(entries.count))
        end.write(UInt32(central.count))
        end.write(centralOffset)
        end.write(UInt16(0))
        archive.append(end.data)
        try archive.write(to: url, options: .atomic)
    }

    private static func dosTimestamp(_ date: Date) -> (UInt16, UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let date = UInt16(max(0, (c.year ?? 1980) - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, date)
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { raw in
            table.withUnsafeBufferPointer { t in
                for byte in raw.bindMemory(to: UInt8.self) {
                    crc = t[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
                }
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
