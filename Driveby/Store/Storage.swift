import Foundation

enum Storage {
    static let fm = FileManager.default

    static var documents: URL { fm.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var appSupport: URL {
        let u = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var caches: URL { fm.urls(for: .cachesDirectory, in: .userDomainMask)[0] }

    static var drivesRoot: URL {
        let u = documents.appendingPathComponent("Drives", isDirectory: true)
        if !fm.fileExists(atPath: u.path) {
            try? fm.createDirectory(at: u, withIntermediateDirectories: true,
                                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
        return u
    }

    static var exportsRoot: URL {
        let u = fm.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
        try? fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func folder(_ name: String) -> URL { drivesRoot.appendingPathComponent(name, isDirectory: true) }

    static func freeBytes() -> Int64 {
        let values = try? documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    static func writeJSON<T: Encodable>(_ value: T, to url: URL, encoder: JSONEncoder = JSONCoding.encoder) throws {
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func readJSON<T: Decodable>(_ type: T.Type, from url: URL, decoder: JSONDecoder = JSONCoding.decoder) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    static func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

enum MonotonicClock {
    @inline(__always) static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}
