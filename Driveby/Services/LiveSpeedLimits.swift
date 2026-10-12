//  LiveSpeedLimits.swift — Driveby
//  The speed limit where the car is right now, for the live coach. Loads OpenStreetMap tiles through
//  the same Overpass client + disk cache the post-drive scorer uses (so this also prefetches the tiles
//  it will need) — the car's tile plus the one ~600 m ahead — and matches each GPS fix with the shared
//  RoadIndex. Only the 3×3 tiles around the car are indexed and the index is built off the main thread,
//  so a long drive never piles up roads or stalls the UI. Unknown (.empty) until a tile arrives.

import Foundation

@MainActor
final class LiveSpeedLimits {
    /// Look this far ahead (m) along the heading so the next tile is loading before the car reaches it.
    private static let lookahead = 600.0
    private static let metresPerDegreeLat = 111_320.0
    /// Tiles indexed around the car's tile (1 → 3×3); one ring further is kept in memory, the rest dropped.
    private static let indexRadius = 1
    /// Don't re-ask Overpass for a tile that just failed.
    private static let retryAfter: TimeInterval = 60

    private var tileWays: [SpeedLimits.Tile: [OSMWay]] = [:]
    private var loading: Set<SpeedLimits.Tile> = []
    private var failedAt: [SpeedLimits.Tile: Date] = [:]
    private var index: SpeedLimits.RoadIndex?
    private var indexedTiles: Set<SpeedLimits.Tile> = []
    private var building = false
    private var generation = 0

    /// Forget everything (start of a drive, or after it ends — replies still in flight are ignored).
    func reset() {
        generation += 1
        tileWays = [:]; loading = []; failedAt = [:]
        index = nil; indexedTiles = []; building = false
    }

    /// The road and its limit at this fix (`.empty` while tiles are still loading or offline).
    func match(lat: Double, lon: Double, heading: Double, speed: Double) -> SpeedLimits.Match {
        requestTiles(lat: lat, lon: lon, heading: heading)
        let here = Self.tile(lat: lat, lon: lon)
        let wanted = Set(tileWays.keys.filter { Self.distance($0, here) <= Self.indexRadius })
        if wanted != indexedTiles && !building { rebuild(wanted, around: here, lat: lat, lon: lon) }
        return index?.match(lat: lat, lon: lon, heading: heading, speed: speed) ?? .empty
    }

    // MARK: Loading

    private func requestTiles(lat: Double, lon: Double, heading: Double) {
        var lats = [lat], lons = [lon]
        if heading.isFinite {
            let rad = heading * .pi / 180
            lats.append(lat + Self.lookahead * cos(rad) / Self.metresPerDegreeLat)
            lons.append(lon + Self.lookahead * sin(rad) / (Self.metresPerDegreeLat * cos(lat * .pi / 180)))
        }
        let now = Date()
        let needed = SpeedLimits.tiles(lat: lats, lon: lons).filter { tile in
            tileWays[tile] == nil && !loading.contains(tile)
                && (failedAt[tile].map { now.timeIntervalSince($0) > Self.retryAfter } ?? true)
        }
        let gen = generation
        for tile in needed {
            loading.insert(tile)
            Task { [weak self] in
                let data = await OverpassClient.shared.mapData(for: [tile])
                self?.didLoad(tile, data: data, generation: gen)
            }
        }
    }

    private func didLoad(_ tile: SpeedLimits.Tile, data: OverpassClient.MapData?, generation gen: Int) {
        guard gen == generation else { return }
        loading.remove(tile)
        guard let data else { failedAt[tile] = Date(); return }
        tileWays[tile] = data.ways
    }

    // MARK: Index

    private func rebuild(_ tiles: Set<SpeedLimits.Tile>, around here: SpeedLimits.Tile, lat: Double, lon: Double) {
        tileWays = tileWays.filter { Self.distance($0.key, here) <= Self.indexRadius + 1 }
        var byId: [Int64: OSMWay] = [:]          // a way crossing a tile edge comes back in both tiles
        for t in tiles { for w in tileWays[t] ?? [] { byId[w.id] = w } }
        let ways = Array(byId.values)
        building = true
        let gen = generation
        Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) {
                ways.isEmpty ? nil : SpeedLimits.RoadIndex(ways: ways, lat0: lat, lon0: lon)
            }.value
            guard let self, gen == self.generation else { return }
            self.index = built
            self.indexedTiles = tiles
            self.building = false
        }
    }

    private static func tile(lat: Double, lon: Double) -> SpeedLimits.Tile {
        SpeedLimits.Tile(x: Int((lon / SpeedLimits.tileDeg).rounded(.down)), y: Int((lat / SpeedLimits.tileDeg).rounded(.down)))
    }

    /// Chebyshev distance in tiles.
    private static func distance(_ a: SpeedLimits.Tile, _ b: SpeedLimits.Tile) -> Int {
        max(abs(a.x - b.x), abs(a.y - b.y))
    }
}
