import Foundation

/// Minimal ZIP writer (deflate or stored entries, no ZIP64) that streams entries to disk, so
/// large archives (a scan with hundreds of photos) never have to fit in memory.
enum ZipWriter {
    struct Entry {
        var name: String
        var source: URL
    }

    enum ZipError: LocalizedError {
        case tooLarge
        case cannotCreate(URL)

        var errorDescription: String? {
            switch self {
            case .tooLarge: "The export is too large to zip (over 4 GB)."
            case .cannotCreate(let url): "Couldn't create \(url.lastPathComponent)."
            }
        }
    }

    /// File types that are already compressed and are stored as-is.
    private static let storedExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "usdz", "zip", "glb", "scanspace"]

    static func write(_ entries: [Entry], to url: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        guard fm.createFile(atPath: url.path, contents: nil) else { throw ZipError.cannotCreate(url) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var central = Data()
        var offset: UInt64 = 0
        let (dosTime, dosDate) = dosTimestamp(Date())

        for entry in entries {
            try autoreleasepool {
                let contents = try Data(contentsOf: entry.source, options: .alwaysMapped)
                let crc = CRC32.checksum(contents)
                var method: UInt16 = 0
                var payload = contents
                if !storedExtensions.contains(entry.source.pathExtension.lowercased()),
                   let deflated = try? (contents as NSData).compressed(using: .zlib) as Data,
                   deflated.count < contents.count {
                    method = 8
                    payload = deflated
                }
                let nameBytes = Array(entry.name.utf8)

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

                let localOffset = offset
                offset += UInt64(local.data.count) + UInt64(payload.count)
                guard offset < UInt64(UInt32.max) else { throw ZipError.tooLarge }
                try handle.write(contentsOf: local.data)
                try handle.write(contentsOf: payload)

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
                header.write(UInt32(localOffset))
                header.writeRaw(nameBytes)
                central.append(header.data)
            }
        }

        guard entries.count < Int(UInt16.max), offset + UInt64(central.count) < UInt64(UInt32.max) else { throw ZipError.tooLarge }
        var end = BinaryWriter()
        end.write(UInt32(0x0605_4B50))
        end.write(UInt16(0))
        end.write(UInt16(0))
        end.write(UInt16(entries.count))
        end.write(UInt16(entries.count))
        end.write(UInt32(central.count))
        end.write(UInt32(offset))
        end.write(UInt16(0))
        try handle.write(contentsOf: central)
        try handle.write(contentsOf: end.data)
    }

    /// All regular files below `directory`, named by their path relative to it.
    static func entries(in directory: URL, excluding excluded: [URL] = []) -> [Entry] {
        let rootComponents = directory.standardizedFileURL.pathComponents
        let excludedPaths = excluded.map { $0.standardizedFileURL.pathComponents }
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var result: [Entry] = []
        for case let file as URL in enumerator {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let components = file.standardizedFileURL.pathComponents
            guard components.starts(with: rootComponents) else { continue }
            if excludedPaths.contains(where: { components.starts(with: $0) }) { continue }
            result.append(Entry(name: components.dropFirst(rootComponents.count).joined(separator: "/"), source: file))
        }
        return result.sorted { $0.name < $1.name }
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

/// `.scanspace` project files: a scan folder (metadata, raw capture, processed model, room data)
/// zipped into one file, used to move scans from the iPhone to ScanSpace Studio on the Mac.
enum ProjectArchive {
    static let fileExtension = "scanspace"

    static func export(files: ScanFiles, to url: URL) throws {
        var entries = ZipWriter.entries(in: files.root, excluding: [files.exportsDirectory])
        guard entries.contains(where: { $0.name == "scan.json" }) else { throw ExportError.missingData("scan metadata") }
        // Put the metadata first so readers can identify the archive quickly.
        entries.sort { $0.name == "scan.json" ? true : ($1.name == "scan.json" ? false : $0.name < $1.name) }
        try ZipWriter.write(entries, to: url)
    }
}
