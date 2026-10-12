//  DriveStore.swift — Driveby
//  Index of recorded drives + access to each drive folder's files.

import Foundation
import Observation

@MainActor
@Observable
final class DriveStore {
    private(set) var records: [DriveRecord] = []      // newest first
    private(set) var pendingCloudDeletes: [UUID] = []
    @ObservationIgnored private var analysisCache: [UUID: DriveAnalysis] = [:]

    private var indexURL: URL { Storage.documents.appendingPathComponent("drives_index.json") }

    private struct IndexFile: Codable { var records: [DriveRecord]; var pendingCloudDeletes: [UUID]? }

    init() { load() }

    func load() {
        if let f = Storage.readJSON(IndexFile.self, from: indexURL) {
            records = f.records.sorted { $0.startedAt > $1.startedAt }
            pendingCloudDeletes = f.pendingCloudDeletes ?? []
        }
        // Folders present on disk but missing from the index (e.g. crash before the index was written).
        let known = Set(records.map(\.folder))
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: Storage.drivesRoot.path)) ?? []
        for name in folders where name.hasPrefix("drive_") && !known.contains(name) {
            if let side = sidecar(folder: name) {
                records.append(DriveRecord(id: UUID(uuidString: side.driveId) ?? UUID(), folder: name,
                                           vehicleId: side.vehicleId.flatMap(UUID.init(uuidString:)),
                                           startedAt: side.startedAt, endedAt: side.endedAt,
                                           hasVideo: side.videoFile != nil))
            }
        }
        records.sort { $0.startedAt > $1.startedAt }
        save()
    }

    func save() {
        try? Storage.writeJSON(IndexFile(records: records, pendingCloudDeletes: pendingCloudDeletes), to: indexURL)
    }

    // MARK: Folders

    /// Next sequential folder name: drive_0001, drive_0002, …
    func nextFolderName() -> String {
        let existing = ((try? FileManager.default.contentsOfDirectory(atPath: Storage.drivesRoot.path)) ?? [])
            .compactMap { Int($0.replacingOccurrences(of: "drive_", with: "")) }
        return String(format: "drive_%04d", (existing.max() ?? 0) + 1)
    }

    func folderURL(_ r: DriveRecord) -> URL { Storage.folder(r.folder) }

    func sidecar(folder: String) -> DriveSidecar? {
        Storage.readJSON(DriveSidecar.self, from: Storage.folder(folder).appendingPathComponent("drive.json"),
                         decoder: DriveSidecar.decoder)
    }

    func sidecar(_ r: DriveRecord) -> DriveSidecar? { sidecar(folder: r.folder) }

    func videoURL(_ r: DriveRecord) -> URL? {
        guard let name = sidecar(r)?.videoFile else { return nil }
        let u = folderURL(r).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    func clipURL(_ r: DriveRecord, event: DriveEvent) -> URL? { clipURL(r, path: event.clipPath) }

    func clipURL(_ r: DriveRecord, path: String?) -> URL? {
        guard let p = path else { return nil }
        let u = folderURL(r).appendingPathComponent(p)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    func analysis(_ r: DriveRecord) -> DriveAnalysis? {
        if let a = analysisCache[r.id] { return a }
        let a = Storage.readJSON(DriveAnalysis.self, from: folderURL(r).appendingPathComponent("analysis.json"),
                                 decoder: DriveAnalysis.decoder)
        if let a { analysisCache[r.id] = a }
        return a
    }

    func record(_ id: UUID) -> DriveRecord? { records.first { $0.id == id } }

    // MARK: Mutations

    func add(_ r: DriveRecord) {
        records.removeAll { $0.id == r.id }
        records.insert(r, at: 0)
        records.sort { $0.startedAt > $1.startedAt }
        save()
    }

    func update(_ r: DriveRecord) {
        guard let i = records.firstIndex(where: { $0.id == r.id }) else { add(r); return }
        records[i] = r
        save()
    }

    func store(analysis: DriveAnalysis, for r: DriveRecord) throws {
        try Storage.writeJSON(analysis, to: folderURL(r).appendingPathComponent("analysis.json"), encoder: DriveAnalysis.encoder)
        analysisCache[r.id] = analysis
    }

    func invalidateCache(_ id: UUID) { analysisCache[id] = nil }

    func delete(_ r: DriveRecord, keepCloudCopy: Bool = false) {
        try? FileManager.default.removeItem(at: folderURL(r))
        records.removeAll { $0.id == r.id }
        analysisCache[r.id] = nil
        if !keepCloudCopy && r.syncedAt != nil { pendingCloudDeletes.append(r.id) }
        save()
    }

    func clearCloudDeletes(_ ids: [UUID]) { pendingCloudDeletes.removeAll { ids.contains($0) }; save() }

    func markAllUnsynced() {
        for i in records.indices { records[i].syncedAt = nil }
        save()
    }

    func wipe() {
        try? FileManager.default.removeItem(at: Storage.drivesRoot)
        try? FileManager.default.removeItem(at: indexURL)
        records = []; analysisCache = [:]; pendingCloudDeletes = []
    }

    // MARK: Derived

    var processed: [DriveRecord] { records.filter(\.processed) }

    func hardBrakeCounts() -> [UUID: Int] {
        var out: [UUID: Int] = [:]
        for r in processed { out[r.id] = analysis(r)?.events.filter { $0.kind == .hardBrake }.count ?? 0 }
        return out
    }

    /// Deletes full-length videos older than `days` (event clips are kept). Returns bytes freed.
    @discardableResult
    func pruneOldVideos(olderThanDays days: Int) -> Int64 {
        guard days > 0 else { return 0 }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var freed: Int64 = 0
        for r in records where r.startedAt < cutoff && r.processed {
            if let v = videoURL(r) {
                freed += Int64((try? v.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                try? FileManager.default.removeItem(at: v)
            }
        }
        return freed
    }

    func totalBytes() -> Int64 { Storage.directorySize(Storage.drivesRoot) }
}
