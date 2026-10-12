//  Hazard.swift — Driveby
//  Phase 7: the civic payload. Private trips → anonymised aggregate → a public
//  map of where drivers brake hardest. k-anonymity: a cell is published only
//  when it has ≥ 5 events from ≥ 3 distinct drivers, and the published row holds
//  counts only — never user IDs, never trip-level timestamps.
//  The server-side twin is `publish_hazard_cells()` in db/schema.sql;
//  the Python twin is processor/hazard.py. All three compute the SAME cell key.

import Foundation

enum HazardGrid {
    /// cell_key = f"{round(lat/CELL)*CELL:.4f}_{round(lon/CELL)*CELL:.4f}"  (Python round = half-to-even)
    static func cellKey(lat: Double, lon: Double, cell: Double = Thresholds.hazardCell) -> String {
        let (clat, clon) = cellCenter(lat: lat, lon: lon, cell: cell)
        return String(format: "%.4f_%.4f", clat, clon)
    }

    static func cellCenter(lat: Double, lon: Double, cell: Double = Thresholds.hazardCell) -> (Double, Double) {
        ((lat / cell).rounded(.toNearestOrEven) * cell, (lon / cell).rounded(.toNearestOrEven) * cell)
    }
}

/// A row of the public `hazard_cells` table (no user linkage by design).
struct HazardCell: Codable, Identifiable, Hashable, Sendable {
    var cellKey: String
    var lat: Double
    var lon: Double
    var eventCount: Int
    var distinctUsers: Int
    var dominantKind: String?
    var updatedAt: Date?

    var id: String { cellKey }

    /// UI copy straight from the Build Guide: "This intersection: 7 hard-braking events from 3 drivers".
    var summary: String {
        let kind = dominantKind.flatMap(EventKind.init(rawValue:))
        let noun = kind == .harshCorner ? "sharp-turn" : "hard-braking"
        return "This intersection: \(eventCount) \(noun) event\(eventCount == 1 ? "" : "s") from \(distinctUsers) driver\(distinctUsers == 1 ? "" : "s")"
    }

    enum CodingKeys: String, CodingKey {
        case cellKey = "cell_key", lat, lon, eventCount = "event_count", distinctUsers = "distinct_users"
        case dominantKind = "dominant_kind", updatedAt = "updated_at"
    }
}

/// Your own contribution to a cell — visible only to you, used to show the mechanic working honestly.
struct LocalHazardCell: Identifiable, Hashable, Sendable {
    var cellKey: String
    var lat: Double
    var lon: Double
    var eventCount: Int
    var driveCount: Int
    var kindCounts: [EventKind: Int]
    var id: String { cellKey }

    var dominantKind: EventKind? { kindCounts.max { a, b in a.value == b.value ? a.key.rawValue > b.key.rawValue : a.value < b.value }?.key }

    /// Progress toward the k-anonymity publication threshold (your data alone can't publish a cell:
    /// it is one driver, and k requires 3).
    var eventsTowardK: String { "\(min(eventCount, Thresholds.kEvents))/\(Thresholds.kEvents) events" }
}

enum HazardAggregator {
    struct Contribution: Sendable {
        var lat: Double
        var lon: Double
        var kind: EventKind
        var driveId: UUID
        var userKey: String   // only used for counting distinct users; never stored in output
    }

    /// Local aggregation of your own events (all cells, regardless of k).
    static func localCells(_ contributions: [Contribution]) -> [LocalHazardCell] {
        var cells: [String: LocalHazardCell] = [:]
        var drives: [String: Set<UUID>] = [:]
        for c in contributions where EventKind.hazardKinds.contains(c.kind) {
            let key = HazardGrid.cellKey(lat: c.lat, lon: c.lon)
            let (clat, clon) = HazardGrid.cellCenter(lat: c.lat, lon: c.lon)
            var cell = cells[key] ?? LocalHazardCell(cellKey: key, lat: clat, lon: clon, eventCount: 0, driveCount: 0, kindCounts: [:])
            cell.eventCount += 1
            cell.kindCounts[c.kind, default: 0] += 1
            drives[key, default: []].insert(c.driveId)
            cell.driveCount = drives[key]!.count
            cells[key] = cell
        }
        return cells.values.sorted { $0.eventCount > $1.eventCount }
    }

    /// Reference implementation of the server function: only cells clearing BOTH thresholds survive,
    /// and the output carries counts only.
    static func publish(_ contributions: [Contribution], kEvents: Int = Thresholds.kEvents, kUsers: Int = Thresholds.kUsers,
                        now: Date = Date()) -> [HazardCell] {
        var events: [String: Int] = [:]
        var users: [String: Set<String>] = [:]
        var kinds: [String: [String: Int]] = [:]
        var centers: [String: (Double, Double)] = [:]
        for c in contributions where EventKind.hazardKinds.contains(c.kind) {
            let key = HazardGrid.cellKey(lat: c.lat, lon: c.lon)
            events[key, default: 0] += 1
            users[key, default: []].insert(c.userKey)
            kinds[key, default: [:]][c.kind.rawValue, default: 0] += 1
            centers[key] = HazardGrid.cellCenter(lat: c.lat, lon: c.lon)
        }
        return events.compactMap { key, count in
            let u = users[key]?.count ?? 0
            guard count >= kEvents, u >= kUsers, let center = centers[key] else { return nil }
            let dominant = kinds[key]?.max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }?.key
            return HazardCell(cellKey: key, lat: center.0, lon: center.1, eventCount: count, distinctUsers: u,
                              dominantKind: dominant, updatedAt: now)
        }.sorted { $0.eventCount > $1.eventCount }
    }
}

// MARK: - GeoJSON export (Step 7.3 — "the format county traffic engineering already uses")

enum GeoJSON {
    /// FeatureCollection of square polygons (one per published cell), properties = counts only.
    static func hazardFeatureCollection(_ cells: [HazardCell], cell: Double = Thresholds.hazardCell,
                                        generatedAt: Date = Date()) -> Data {
        let iso = ISO8601DateFormatter()
        let h = cell / 2
        let features: [[String: Any]] = cells.map { c in
            let ring: [[Double]] = [
                [c.lon - h, c.lat - h], [c.lon + h, c.lat - h], [c.lon + h, c.lat + h], [c.lon - h, c.lat + h], [c.lon - h, c.lat - h],
            ].map { [round6($0[0]), round6($0[1])] }
            var props: [String: Any] = [
                "cell_key": c.cellKey,
                "center_lat": round6(c.lat),
                "center_lon": round6(c.lon),
                "event_count": c.eventCount,
                "distinct_users": c.distinctUsers,
            ]
            if let k = c.dominantKind { props["dominant_kind"] = k }
            if let u = c.updatedAt { props["updated_at"] = iso.string(from: u) }
            return ["type": "Feature", "geometry": ["type": "Polygon", "coordinates": [ring]], "properties": props]
        }
        let root: [String: Any] = [
            "type": "FeatureCollection",
            "name": "driveby_hazard_cells",
            "metadata": [
                "generator": "Driveby",
                "generated_at": iso.string(from: generatedAt),
                "description": "Anonymised aggregate of hard-braking and sharp-turn events. A cell is published only with at least \(Thresholds.kEvents) events from at least \(Thresholds.kUsers) distinct drivers (k-anonymity). No user identifiers or trip timestamps are included.",
                "cell_size_deg": cell,
                "k_events": Thresholds.kEvents,
                "k_users": Thresholds.kUsers,
                "crs": "EPSG:4326",
            ] as [String: Any],
            "features": features,
        ]
        return (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    static func hazardCSV(_ cells: [HazardCell]) -> String {
        var s = "cell_key,center_lat,center_lon,event_count,distinct_users,dominant_kind\n"
        for c in cells {
            s += "\(c.cellKey),\(String(format: "%.6f", c.lat)),\(String(format: "%.6f", c.lon)),\(c.eventCount),\(c.distinctUsers),\(c.dominantKind ?? "")\n"
        }
        return s
    }

    private static func round6(_ v: Double) -> Double { (v * 1e6).rounded() / 1e6 }
}
