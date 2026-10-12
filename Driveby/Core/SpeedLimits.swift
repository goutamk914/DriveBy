//  SpeedLimits.swift — Driveby
//  Step 2.3: OpenStreetMap `maxspeed` via the Overpass API, with a highway-type
//  fallback, matched to each point by nearest way within 25 m AND heading
//  agreement within 45° (so the parallel service road never makes a 55 look
//  like 55-in-a-25). Mirrors processor/speedlimits.py.
//
//  Networking lives in the app (Services/OverpassClient.swift); this file is pure logic.

import Foundation

struct OSMWay: Codable, Equatable, Sendable {
    var id: Int64
    var highway: String
    var maxspeed: String?
    var name: String?
    var ref: String?
    var oneway: String?
    var geometry: [[Double]]      // [[lat, lon], ...]
    var nodeIds: [Int64]? = nil   // OSM node ids along the way (to know which road a stop sign belongs to)

    /// Speed limit in m/s: tagged `maxspeed` first, else the highway-type default.
    var limitMps: Double? {
        if let tagged = SpeedLimits.parseMaxspeed(maxspeed) { return tagged }
        if let mph = SpeedLimits.defaultLimitsMph[highway] { return mph / Units.mpsToMph }
        return nil
    }

    var limitIsTagged: Bool { SpeedLimits.parseMaxspeed(maxspeed) != nil }

    /// Human road label for coaching copy: "Route 7", "I-66", "US-15", or the street name.
    var displayName: String? { SpeedLimits.displayName(ref: ref, name: name) }
}

enum SpeedLimits {
    /// Build Guide Step 2.3 table, extended with the *_link and living_street types.
    static let defaultLimitsMph: [String: Double] = [
        "motorway": 65, "trunk": 55, "primary": 45,
        "secondary": 40, "tertiary": 35,
        "residential": 25, "unclassified": 30, "service": 15,
        "motorway_link": 45, "trunk_link": 40, "primary_link": 35,
        "secondary_link": 30, "tertiary_link": 30, "living_street": 15,
    ]

    static let drivableHighwayRegex =
        "^(motorway|trunk|primary|secondary|tertiary|unclassified|residential|service|motorway_link|trunk_link|primary_link|secondary_link|tertiary_link|living_street)$"

    /// Tile size used to split a route into cacheable Overpass queries.
    static let tileDeg = 0.02

    /// OSM convention: a bare number is km/h; "35 mph" is mph. "none"/"signals"/"variable" → nil.
    static func parseMaxspeed(_ raw: String?) -> Double? {
        guard var s = raw?.lowercased().trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if let semi = s.firstIndex(of: ";") { s = String(s[..<semi]).trimmingCharacters(in: .whitespaces) }
        let isMph = s.contains("mph")
        let digits = s.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(digits), value > 0 else { return nil }
        return isMph ? value / Units.mpsToMph : value / 3.6
    }

    static func displayName(ref: String?, name: String?) -> String? {
        if let ref = ref?.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces), !ref.isEmpty {
            let parts = ref.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                switch parts[0].uppercased() {
                case "I": return "I-\(parts[1])"
                case "US": return "US-\(parts[1])"
                case "VA", "SR", "MD", "DC": return "Route \(parts[1])"
                default: return ref
                }
            }
            return ref
        }
        if let name, !name.isEmpty { return name }
        return nil
    }

    // MARK: Overpass

    struct Tile: Hashable, Sendable {
        var x: Int, y: Int
        var south: Double { Double(y) * SpeedLimits.tileDeg }
        var west: Double { Double(x) * SpeedLimits.tileDeg }
        var north: Double { south + SpeedLimits.tileDeg }
        var east: Double { west + SpeedLimits.tileDeg }
        var key: String { "\(x)_\(y)" }
    }

    /// Tiles touched by the route, padded so ways just across a tile edge still match.
    static func tiles(lat: [Double], lon: [Double]) -> [Tile] {
        var set = Set<Tile>()
        let pad = 0.0005 // ≈ 55 m
        for (a, b) in zip(lat, lon) {
            for dy in [-pad, pad] { for dx in [-pad, pad] {
                set.insert(Tile(x: Int(((b + dx) / tileDeg).rounded(.down)), y: Int(((a + dy) / tileDeg).rounded(.down))))
            } }
        }
        return set.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
    }

    /// Overpass QL for one tile: all drivable ways (tagged maxspeed or not, for the fallback) plus
    /// stop-sign and traffic-signal nodes (for the stop-sign skill). `out body geom` returns each way's
    /// node ids, so a stop sign can be tied to the road it controls.
    static func overpassQuery(for tile: Tile) -> String {
        let bbox = String(format: "%.4f,%.4f,%.4f,%.4f", tile.south, tile.west, tile.north, tile.east)
        return "[out:json][timeout:25];(way[\"highway\"~\"\(drivableHighwayRegex)\"](\(bbox));node[\"highway\"~\"^(stop|traffic_signals)$\"](\(bbox)););out body geom;"
    }

    /// Cache-file version: bump when the query changes so stale tiles are refetched.
    static let overpassCacheVersion = "v2"

    /// Parse an Overpass JSON response into ways.
    static func parseOverpass(_ data: Data) -> [OSMWay] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let elements = root["elements"] as? [[String: Any]] else { return [] }
        var ways: [OSMWay] = []
        for e in elements where (e["type"] as? String) == "way" {
            guard let tags = e["tags"] as? [String: Any], let highway = tags["highway"] as? String,
                  let geom = e["geometry"] as? [[String: Any]], geom.count >= 2 else { continue }
            let pts: [[Double]] = geom.compactMap { p in
                guard let la = (p["lat"] as? NSNumber)?.doubleValue ?? (p["lat"] as? Double),
                      let lo = (p["lon"] as? NSNumber)?.doubleValue ?? (p["lon"] as? Double) else { return nil }
                return [la, lo]
            }
            let id = (e["id"] as? NSNumber)?.int64Value ?? Int64((e["id"] as? Int) ?? 0)
            let nodes = (e["nodes"] as? [Any])?.compactMap { ($0 as? NSNumber)?.int64Value ?? ($0 as? Int).map(Int64.init) }
            ways.append(OSMWay(id: id, highway: highway, maxspeed: tags["maxspeed"] as? String,
                               name: tags["name"] as? String, ref: tags["ref"] as? String,
                               oneway: tags["oneway"] as? String, geometry: pts, nodeIds: nodes))
        }
        return ways
    }

    /// Stop signs and traffic signals from an Overpass response, each tied to the ways that contain it.
    static func parseControls(_ data: Data, ways: [OSMWay]) -> [OSMControl] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let elements = root["elements"] as? [[String: Any]] else { return [] }
        var membership: [Int64: [Int64]] = [:]
        for w in ways { for n in w.nodeIds ?? [] { membership[n, default: []].append(w.id) } }
        var out: [OSMControl] = []
        for e in elements where (e["type"] as? String) == "node" {
            guard let tags = e["tags"] as? [String: Any], let hw = tags["highway"] as? String,
                  let kind = OSMControl.Kind(rawValue: hw),
                  let lat = (e["lat"] as? NSNumber)?.doubleValue, let lon = (e["lon"] as? NSNumber)?.doubleValue else { continue }
            let id = (e["id"] as? NSNumber)?.int64Value ?? 0
            out.append(OSMControl(id: id, lat: lat, lon: lon, kind: kind,
                                  allWay: (tags["stop"] as? String) == "all",
                                  wayIds: membership[id] ?? []))
        }
        return out
    }

    // MARK: Matching

    struct Match: Equatable, Sendable {
        var limitMps: Double?
        var road: String?
        var tagged: Bool
        var wayId: Int64?

        static let empty = Match(limitMps: nil, road: nil, tagged: false, wayId: nil)
    }

    /// Below this speed (m/s) GPS heading is noise, so it isn't used to pick the road.
    static let headingMinSpeed = 2.0

    /// Way segments projected to local metres and bucketed on a 100 m grid, for nearest-road lookups.
    /// Shared by the post-drive matcher (every sample of a series) and the live coach (one fix at a time).
    struct RoadIndex: Sendable {
        private struct Seg: Sendable { var ax, ay, bx, by: Double; var way: Int }
        private static let cell = 100.0

        private let ways: [OSMWay]
        private let proj: Geo.LocalProjection
        private var segs: [Seg] = []
        private var buckets: [Int64: [Int]] = [:]

        /// `lat0`/`lon0`: projection origin — anywhere near the area being matched.
        init(ways: [OSMWay], lat0: Double, lon0: Double) {
            self.ways = ways
            proj = Geo.LocalProjection(lat0: lat0, lon0: lon0)
            let r = Thresholds.wayMatchRadius
            for (wi, w) in ways.enumerated() where w.geometry.count >= 2 {
                for k in 1..<w.geometry.count {
                    let (ax, ay) = proj.xy(w.geometry[k - 1][0], w.geometry[k - 1][1])
                    let (bx, by) = proj.xy(w.geometry[k][0], w.geometry[k][1])
                    let idx = segs.count
                    segs.append(Seg(ax: ax, ay: ay, bx: bx, by: by, way: wi))
                    var gx = ((min(ax, bx) - r) / Self.cell).rounded(.down)
                    while gx <= ((max(ax, bx) + r) / Self.cell).rounded(.down) {
                        var gy = ((min(ay, by) - r) / Self.cell).rounded(.down)
                        while gy <= ((max(ay, by) + r) / Self.cell).rounded(.down) {
                            buckets[Self.bucketKey(gx * Self.cell, gy * Self.cell), default: []].append(idx)
                            gy += 1
                        }
                        gx += 1
                    }
                }
            }
        }

        private static func bucketKey(_ x: Double, _ y: Double) -> Int64 {
            (Int64((x / cell).rounded(.down)) << 32) ^ (Int64((y / cell).rounded(.down)) & 0xffffffff)
        }

        /// Nearest way within `wayMatchRadius` whose direction agrees with `heading` (degrees) when moving.
        func match(lat: Double, lon: Double, heading: Double, speed: Double) -> Match {
            let (px, py) = proj.xy(lat, lon)
            let checkHeading = heading.isFinite && speed > SpeedLimits.headingMinSpeed
            var best: (dist: Double, way: Int)?
            for si in buckets[Self.bucketKey(px, py)] ?? [] {
                let seg = segs[si]
                let r = Geo.pointSegment(px: px, py: py, ax: seg.ax, ay: seg.ay, bx: seg.bx, by: seg.by)
                guard r.dist <= Thresholds.wayMatchRadius else { continue }
                if checkHeading && !Self.headingAgrees(heading, bearing: r.bearing, oneway: ways[seg.way].oneway) { continue }
                if best == nil || r.dist < best!.dist { best = (r.dist, seg.way) }
            }
            guard let wi = best?.way else { return .empty }
            let w = ways[wi]
            return Match(limitMps: w.limitMps, road: w.displayName, tagged: w.limitIsTagged, wayId: w.id)
        }

        private static func headingAgrees(_ heading: Double, bearing: Double, oneway: String?) -> Bool {
            let fwd = Geo.headingDelta(heading, bearing)
            let rev = Geo.headingDelta(heading, bearing + 180)
            switch oneway {
            case "yes", "true", "1": return fwd <= Thresholds.wayHeadingTolerance
            case "-1", "reverse": return rev <= Thresholds.wayHeadingTolerance
            default: return min(fwd, rev) <= Thresholds.wayHeadingTolerance
            }
        }
    }

    /// Matches every series sample to a way. Evaluated once per second and forward-filled.
    static func match(series s: DriveSeries, ways: [OSMWay]) -> [Match] {
        guard s.count > 0, !ways.isEmpty else { return [Match](repeating: .empty, count: s.count) }
        let index = RoadIndex(ways: ways, lat0: s.lat[s.count / 2], lon0: s.lon[s.count / 2])
        var out = [Match](repeating: .empty, count: s.count)
        let step = max(Int((1.0 / s.dt).rounded()), 1)
        var last = Match.empty
        for i in 0..<s.count {
            if i % step == 0 { last = index.match(lat: s.lat[i], lon: s.lon[i], heading: s.heading[i], speed: s.v[i]) }
            out[i] = last
        }
        return out
    }
}

/// A stop sign or traffic signal from OpenStreetMap.
struct OSMControl: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case stop, trafficSignals = "traffic_signals" }
    var id: Int64
    var lat: Double
    var lon: Double
    var kind: Kind
    var allWay: Bool
    var wayIds: [Int64]
}
