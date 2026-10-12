import Foundation
import Observation

@MainActor
@Observable
final class PracticeLogStore {
    private struct File: Codable { var entries: [PracticeLogEntry]; var dirty: [UUID]?; var deleted: [UUID]?; var removedDrives: [UUID]? }

    private(set) var entries: [PracticeLogEntry] = []
    private(set) var dirty: Set<UUID> = []
    private(set) var pendingDeletes: [UUID] = []
    private(set) var removedDrives: Set<UUID> = []

    private var url: URL { Storage.documents.appendingPathComponent("practice_log.json") }

    init() {
        if let f = Storage.readJSON(File.self, from: url) {
            entries = f.entries.sorted { $0.startedAt > $1.startedAt }
            dirty = Set(f.dirty ?? [])
            pendingDeletes = f.deleted ?? []
            removedDrives = Set(f.removedDrives ?? [])
        }
    }

    private func save() {
        try? Storage.writeJSON(File(entries: entries, dirty: Array(dirty), deleted: pendingDeletes,
                                 removedDrives: Array(removedDrives)), to: url)
    }

    func upsert(_ e: PracticeLogEntry) {
        if let i = entries.firstIndex(where: { $0.id == e.id }) { entries[i] = e } else { entries.append(e) }
        entries.sort { $0.startedAt > $1.startedAt }
        dirty.insert(e.id)
        save()
    }

    func entry(forDrive id: UUID) -> PracticeLogEntry? { entries.first { $0.driveId == id } }

    func delete(_ id: UUID) {
        if let driveId = entries.first(where: { $0.id == id })?.driveId { removedDrives.insert(driveId) }
        entries.removeAll { $0.id == id }
        pendingDeletes.append(id)
        save()
    }

    func markSynced(_ ids: [UUID]) { dirty.subtract(ids); save() }
    func clearPendingDeletes(_ ids: [UUID]) { pendingDeletes.removeAll { ids.contains($0) }; save() }
    func markAllDirty() { dirty = Set(entries.map(\.id)); save() }

    func summary(_ req: HoursRequirement) -> HoursSummary { HoursSummary(entries: entries, requirement: req) }

    func wipe() {
        entries = []; dirty = []; pendingDeletes = []; removedDrives = []
        try? FileManager.default.removeItem(at: url)
    }
}
