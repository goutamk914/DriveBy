//  GarageStore.swift — Driveby
//  Vehicles and the fuel log (validation ground truth). Persisted to Documents/garage.json.

import Foundation
import Observation

@MainActor
@Observable
final class GarageStore {
    private struct File: Codable {
        var vehicles: [Vehicle] = []
        var fuelLogs: [FuelLog] = []
        var dirty: [UUID] = []      // ids modified since last cloud sync
        var deleted: [String] = []  // "table:id" pending cloud deletion
    }

    private(set) var vehicles: [Vehicle] = []
    private(set) var fuelLogs: [FuelLog] = []
    private(set) var dirty: Set<UUID> = []
    private(set) var pendingDeletes: [String] = []

    private var url: URL { Storage.documents.appendingPathComponent("garage.json") }

    init() { load() }

    func load() {
        guard let f = Storage.readJSON(File.self, from: url) else { return }
        vehicles = f.vehicles
        fuelLogs = f.fuelLogs.sorted { $0.loggedAt > $1.loggedAt }
        dirty = Set(f.dirty)
        pendingDeletes = f.deleted
    }

    private func save() {
        try? Storage.writeJSON(File(vehicles: vehicles, fuelLogs: fuelLogs, dirty: Array(dirty), deleted: pendingDeletes), to: url)
    }

    func vehicle(_ id: UUID?) -> Vehicle? { id.flatMap { id in vehicles.first { $0.id == id } } }

    func upsert(_ v: Vehicle) {
        if let i = vehicles.firstIndex(where: { $0.id == v.id }) { vehicles[i] = v } else { vehicles.append(v) }
        dirty.insert(v.id); save()
    }

    func deleteVehicle(_ id: UUID) {
        vehicles.removeAll { $0.id == id }
        pendingDeletes.append("vehicles:\(id.uuidString)")
        save()
    }

    func upsert(_ log: FuelLog) {
        if let i = fuelLogs.firstIndex(where: { $0.id == log.id }) { fuelLogs[i] = log } else { fuelLogs.append(log) }
        fuelLogs.sort { $0.loggedAt > $1.loggedAt }
        dirty.insert(log.id); save()
    }

    func deleteFuelLog(_ id: UUID) {
        fuelLogs.removeAll { $0.id == id }
        pendingDeletes.append("fuel_logs:\(id.uuidString)")
        save()
    }

    func markSynced(_ ids: [UUID]) { dirty.subtract(ids); save() }
    func clearPendingDeletes(_ done: [String]) { pendingDeletes.removeAll { done.contains($0) }; save() }
    func markAllDirty() { dirty = Set(vehicles.map(\.id) + fuelLogs.map(\.id)); save() }

    /// Price per gallon from the most recent fill-up that recorded a price (for the "about 4¢" copy).
    func latestPricePerGallon(vehicleId: UUID?) -> Double? {
        fuelLogs.first { ($0.vehicleId == vehicleId || vehicleId == nil) && $0.pricePerGallon != nil }?.pricePerGallon
    }

    func logs(for vehicleId: UUID?) -> [FuelLog] { fuelLogs.filter { vehicleId == nil || $0.vehicleId == vehicleId } }

    func wipe() {
        vehicles = []; fuelLogs = []; dirty = []; pendingDeletes = []
        try? FileManager.default.removeItem(at: url)
    }

    /// CSV in the Day-1 spreadsheet format: date, odometer, gallons, price_total, car_id (+ filled_to_full).
    func fuelCSV() -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"; df.locale = Locale(identifier: "en_US_POSIX")
        var s = "date,odometer,gallons,price_total,car_id,filled_to_full\n"
        for l in fuelLogs.sorted(by: { $0.odometerMi < $1.odometerMi }) {
            s += "\(df.string(from: l.loggedAt)),\(l.odometerMi),\(l.gallons),\(l.priceTotal.map { String($0) } ?? ""),\(l.vehicleId?.uuidString ?? ""),\(l.filledToFull)\n"
        }
        return s
    }
}
