import Foundation
import Observation

private func orNull(_ v: Any?) -> Any { v ?? NSNull() }

@MainActor
@Observable
final class SyncService {
    enum Status: Equatable { case idle, syncing, done(Date), failed(String) }

    private(set) var status: Status = .idle
    private(set) var hazardCells: [HazardCell] = []
    private(set) var hazardFetchedAt: Date?
    private(set) var hazardError: String?
    private(set) var client: SupabaseClient?
    private(set) var signedInEmail: String?

    @ObservationIgnored private let drives: DriveStore
    @ObservationIgnored private let garage: GarageStore
    @ObservationIgnored private let practiceLog: PracticeLogStore
    @ObservationIgnored private let settings: AppSettings

    init(drives: DriveStore, garage: GarageStore, practiceLog: PracticeLogStore, settings: AppSettings) {
        self.drives = drives
        self.garage = garage
        self.practiceLog = practiceLog
        self.settings = settings
        reconfigure()
    }

    var isConfigured: Bool { client != nil }
    var isSignedIn: Bool { client?.session != nil }
    var userId: String? { client?.session?.userId }

    func reconfigure() {
        if let cfg = SupabaseConfig.current(settings: settings) {
            if client?.config != cfg { client = SupabaseClient(config: cfg) }
        } else {
            client = nil
        }
        signedInEmail = client?.session?.email
    }

    func signIn(email: String, password: String, create: Bool) async throws {
        guard let client else { throw SupabaseError.notConfigured }
        let s = create ? try await client.signUp(email: email, password: password)
                       : try await client.signIn(email: email, password: password)
        signedInEmail = s.email
        drives.markAllUnsynced()
        garage.markAllDirty()
        practiceLog.markAllDirty()
        await syncNow()
    }

    func signOut() async {
        await client?.signOut()
        signedInEmail = nil
        status = .idle
    }

    func deleteAccount() async throws {
        guard let client, let uid = client.session?.userId else { throw SupabaseError.notSignedIn }
        let clipPaths = (try? await allClipPaths(uid: uid)) ?? []
        try? await client.removeObjects(bucket: "clips", paths: clipPaths)
        _ = try await client.rpc("delete_my_account")
        client.session = nil
        signedInEmail = nil
        drives.markAllUnsynced()
    }

    private func allClipPaths(uid: String) async throws -> [String] {
        guard let client else { return [] }
        var out: [String] = []
        for folder in try await client.listObjects(bucket: "clips", prefix: uid) {
            out += try await client.listObjects(bucket: "clips", prefix: folder)
        }
        return out
    }

    func syncNow() async {
        guard !settings.isDemo, let client, let uid = client.session?.userId else { return }
        if status == .syncing { return }
        status = .syncing
        do {
            let iso = ISO8601DateFormatter()
            let dayFormatter = DateFormatter()
            dayFormatter.dateFormat = "yyyy-MM-dd"
            dayFormatter.locale = Locale(identifier: "en_US_POSIX")

            var doneDeletes: [String] = []
            for item in garage.pendingDeletes {
                let parts = item.split(separator: ":").map(String.init)
                guard parts.count == 2 else { continue }
                try await client.delete(parts[0], equals: parts[1])
                doneDeletes.append(item)
            }
            garage.clearPendingDeletes(doneDeletes)
            var deletedDrives: [UUID] = []
            for id in drives.pendingCloudDeletes {
                let paths = (try? await client.listObjects(bucket: "clips", prefix: "\(uid)/\(id.uuidString.lowercased())")) ?? []
                try? await client.removeObjects(bucket: "clips", paths: paths)
                try await client.delete("drives", equals: id.uuidString.lowercased())
                deletedDrives.append(id)
            }
            drives.clearCloudDeletes(deletedDrives)

            let vehicleRows: [[String: Any]] = garage.vehicles.filter { garage.dirty.contains($0.id) }.map { v -> [String: Any] in
                var r: [String: Any] = ["id": v.id.uuidString.lowercased(), "user_id": uid, "make": v.make, "model": v.model,
                                        "year": v.year, "mass_kg": v.massKg, "regen_factor": v.regenFactor]
                r["epa_city"] = orNull(v.epaCity); r["epa_hwy"] = orNull(v.epaHwy); r["epa_combined"] = orNull(v.epaCombined)
                r["epa_id"] = orNull(v.epaId); r["fuel_type"] = orNull(v.fuelType); r["atv_type"] = orNull(v.atvType)
                return r
            }
            try await client.upsert("vehicles", rows: vehicleRows)
            let fuelRows: [[String: Any]] = garage.fuelLogs.filter { garage.dirty.contains($0.id) }.map { l -> [String: Any] in
                ["id": l.id.uuidString.lowercased(), "user_id": uid, "vehicle_id": orNull(l.vehicleId?.uuidString.lowercased()),
                 "logged_at": dayFormatter.string(from: l.loggedAt), "odometer_mi": l.odometerMi, "gallons": l.gallons,
                 "price_total": orNull(l.priceTotal), "filled_to_full": l.filledToFull]
            }
            try await client.upsert("fuel_logs", rows: fuelRows)
            garage.markSynced(garage.vehicles.map(\.id) + garage.fuelLogs.map(\.id))

            var doneLogDeletes: [UUID] = []
            for id in practiceLog.pendingDeletes {
                try await client.delete("practice_logs", equals: id.uuidString.lowercased())
                doneLogDeletes.append(id)
            }
            practiceLog.clearPendingDeletes(doneLogDeletes)
            let logRows: [[String: Any]] = practiceLog.entries.filter { practiceLog.dirty.contains($0.id) }.map { e -> [String: Any] in
                ["id": e.id.uuidString.lowercased(), "user_id": uid, "drive_id": orNull(e.driveId?.uuidString.lowercased()),
                 "started_at": iso.string(from: e.startedAt),
                 "duration_s": e.durationS, "night_s": e.nightS, "supervisor": e.supervisor, "notes": e.notes,
                 "manual": e.manual]
            }
            try await client.upsert("practice_logs", rows: logRows)
            practiceLog.markSynced(practiceLog.entries.map(\.id))

            let knownVehicles = Set(garage.vehicles.map(\.id))
            for r in drives.records where r.processed && r.syncedAt == nil {
                guard let a = drives.analysis(r) else { continue }
                let driveId = r.id.uuidString.lowercased()
                var row: [String: Any] = ["id": driveId, "user_id": uid, "started_at": iso.string(from: r.startedAt),
                                          "distance_m": a.distanceM, "duration_s": a.durationS, "processed": true,
                                          "safety_score": a.safety.score, "hazard_opt_in": settings.contributeToHazardMap]
                row["vehicle_id"] = orNull(r.vehicleId.flatMap { knownVehicles.contains($0) ? $0.uuidString.lowercased() : nil })
                row["ended_at"] = orNull(r.endedAt.map { iso.string(from: $0) })
                row["efficiency_score"] = orNull(r.efficiencyScore)
                row["fuel_gal"] = orNull(a.obdFuelGal)
                try await client.upsert("drives", rows: [row])
                try await client.delete("events", column: "drive_id", equals: driveId)

                var eventRows: [[String: Any]] = []
                for e in a.events {
                    var detail: [String: Any] = [:]
                    if let d = try? JSONEncoder().encode(e.detail),
                       let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { detail = o }
                    detail["t_end_s"] = e.tEndS
                    detail["t_peak_s"] = e.tPeakS
                    var clipKey: Any = NSNull()
                    if settings.uploadClips, let local = drives.clipURL(r, event: e) {
                        let key = "\(uid)/\(driveId)/\(e.id.uuidString.lowercased()).mov"
                        try await client.upload(bucket: "clips", path: key, file: local, contentType: "video/quicktime")
                        clipKey = key
                    }
                    eventRows.append(["id": e.id.uuidString.lowercased(), "drive_id": driveId, "t_offset_s": e.tOffsetS,
                                      "kind": e.kind.rawValue, "severity": e.severity, "lat": orNull(e.lat),
                                      "lon": orNull(e.lon), "detail": detail, "clip_path": clipKey])
                }
                try await client.insert("events", rows: eventRows)
                var updated = r
                updated.syncedAt = Date()
                drives.update(updated)
            }

            _ = try? await client.rpc("publish_hazard_cells")
            status = .done(Date())
            await refreshHazardCells()
        } catch SupabaseError.notSignedIn {
            signedInEmail = nil
            status = .failed("Signed out. Sign in again to sync.")
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func refreshHazardCells() async {
        guard let client else { hazardError = nil; return }
        do {
            hazardCells = try await client.hazardCells()
            hazardFetchedAt = Date()
            hazardError = nil
        } catch {
            hazardError = error.localizedDescription
        }
    }
}
