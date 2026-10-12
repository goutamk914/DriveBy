//  Storage.swift — Driveby
//  On-device layout (the user's data lives here and belongs to them):
//
//    Documents/Drives/drive_0007/
//        drive.json          sidecar (data contract)
//        drive_0007.jsonl    sensor log (data contract)
//        drive_0007.mov      ALREADY-BLURRED video (raw frames never touch disk)
//        analysis.json       events + scores (same shape as processor/run.py output)
//        clips/<event>.mov   blurred event clips (cut from the blurred video)
//    Documents/garage.json   vehicles + fuel log
//    Documents/drives_index.json
//    Library/Application Support/scoring_model.json
//    Library/Caches/overpass/<tile>.json

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

    /// Free space available for important data (used before starting a camera recording).
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

/// Monotonic clock shared by CoreMotion timestamps, AVFoundation capture PTS and our own
/// bookkeeping (all are mach_absolute_time based) — Decision 1: one clock, no drift.
enum MonotonicClock {
    @inline(__always) static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}
