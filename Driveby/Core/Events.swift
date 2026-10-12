import Foundation

struct EventDetail: Codable, Hashable, Sendable {
    var durationS: Double?
    var vStartMps: Double?
    var vEndMps: Double?
    var peak: Double?
    var limitMps: Double?
    var road: String?
    var headwayS: Double?
    var leadDistM: Double?
    var energyJ: Double?

    enum CodingKeys: String, CodingKey {
        case durationS = "duration_s", vStartMps = "v_start_mps", vEndMps = "v_end_mps", peak
        case limitMps = "limit_mps", road, headwayS = "headway_s", leadDistM = "lead_dist_m", energyJ = "energy_j"
    }
}

struct DriveEvent: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var kind: EventKind
    var tOffsetS: Double
    var tEndS: Double
    var tPeakS: Double
    var severity: Double
    var lat: Double?
    var lon: Double?
    var detail: EventDetail = EventDetail()
    var clipPath: String? = nil

    var duration: Double { max(tEndS - tOffsetS, 0) }

    enum CodingKeys: String, CodingKey {
        case id, kind, tOffsetS = "t_offset_s", tEndS = "t_end_s", tPeakS = "t_peak_s"
        case severity, lat, lon, detail, clipPath = "clip_path"
    }
}

enum EventDetector {

    struct Input: Sendable {
        var series: DriveSeries
        var limits: [SpeedLimits.Match]
        var massKg: Double
    }

    static func detect(_ input: Input) -> [DriveEvent] {
        let s = input.series
        guard s.count > 1 else { return [] }
        let hasLimits = input.limits.count == s.count
        var raw: [DriveEvent] = []
        raw += thresholdEvents(s, kind: .hardBrake)
        raw += thresholdEvents(s, kind: .hardAccel)
        raw += thresholdEvents(s, kind: .harshCorner)
        if hasLimits { raw += speedingEvents(s, limits: input.limits) }
        raw += idleEvents(s)
        raw += tailgatingEvents(s)
        return debounce(raw)
            .map { enrich($0, s, limits: hasLimits ? input.limits : nil, mass: input.massKg) }
            .sorted { $0.tOffsetS < $1.tOffsetS }
    }

    private static func runEvents(_ s: DriveSeries, kind: EventKind, mask: [Bool], sustain: Double,
                                  peakScore: (Int) -> Double, severity: (Int, Double) -> Double) -> [DriveEvent] {
        var out: [DriveEvent] = []
        for (a, b) in Numerics.runs(mask) {
            let duration = Double(b - a + 1) * s.dt
            guard duration >= sustain - 1e-9 else { continue }
            var peak = a
            for i in a...b where peakScore(i) > peakScore(peak) { peak = i }
            out.append(DriveEvent(kind: kind, tOffsetS: s.t[a], tEndS: s.t[b] + s.dt, tPeakS: s.t[peak],
                                  severity: severity(peak, duration), lat: s.lat[peak], lon: s.lon[peak]))
        }
        return out
    }

    private static func thresholdEvents(_ s: DriveSeries, kind: EventKind) -> [DriveEvent] {
        switch kind {
        case .hardBrake:
            let mask = (0..<s.count).map { s.aLong[$0] < Thresholds.hardBrakeA && !s.gpsGap[$0] }
            return runEvents(s, kind: kind, mask: mask, sustain: Thresholds.accelSustain,
                             peakScore: { -s.aLong[$0] },
                             severity: { i, _ in Numerics.ramp(s.aLong[i], from: Thresholds.hardBrakeA, to: Thresholds.hardBrakeFull) })
        case .hardAccel:
            let mask = (0..<s.count).map { s.aLong[$0] > Thresholds.hardAccelA && !s.gpsGap[$0] }
            return runEvents(s, kind: kind, mask: mask, sustain: Thresholds.accelSustain,
                             peakScore: { s.aLong[$0] },
                             severity: { i, _ in Numerics.ramp(s.aLong[i], from: Thresholds.hardAccelA, to: Thresholds.hardAccelFull) })
        default:
            let mask = (0..<s.count).map { abs(s.aLat[$0]) > Thresholds.harshCornerA && !s.gpsGap[$0] }
            return runEvents(s, kind: .harshCorner, mask: mask, sustain: Thresholds.accelSustain,
                             peakScore: { abs(s.aLat[$0]) },
                             severity: { i, _ in Numerics.ramp(abs(s.aLat[i]), from: Thresholds.harshCornerA, to: Thresholds.harshCornerFull) })
        }
    }

    private static func speedingEvents(_ s: DriveSeries, limits: [SpeedLimits.Match]) -> [DriveEvent] {
        let over = (0..<s.count).map { i in limits[i].limitMps.map { s.v[i] - $0 } ?? -Double.infinity }
        return runEvents(s, kind: .speeding, mask: over.map { $0 > Thresholds.speedingMargin },
                         sustain: Thresholds.speedingSustain,
                         peakScore: { over[$0] },
                         severity: { i, duration in
                             0.6 * Numerics.ramp(over[i], from: Thresholds.speedingMargin, to: Thresholds.speedingFullExcess)
                             + 0.4 * Numerics.clip(duration / 60, 0, 1) })
    }

    private static func idleEvents(_ s: DriveSeries) -> [DriveEvent] {
        var out: [DriveEvent] = []
        for (a, b) in Numerics.runs(s.v.map { $0 < Thresholds.idleSpeed }) {
            let duration = Double(b - a + 1) * s.dt
            guard duration > Thresholds.idleMin else { continue }
            let mid = (a + b) / 2
            out.append(DriveEvent(kind: .idle, tOffsetS: s.t[a], tEndS: s.t[b] + s.dt, tPeakS: s.t[mid],
                                  severity: Numerics.ramp(duration, from: Thresholds.idleMin, to: Thresholds.idleFull),
                                  lat: s.lat[mid], lon: s.lon[mid]))
        }
        return out
    }

    static func headway(_ s: DriveSeries) -> [Double?] {
        var h = [Double?](repeating: nil, count: s.count)
        guard s.leadDist.count == s.count else { return h }
        let bridge = Int((0.5 / s.dt).rounded())
        var lastIdx: Int? = nil
        for i in 0..<s.count {
            guard let d = s.leadDist[i], s.v[i] >= Thresholds.tailgateMinSpeed else { continue }
            h[i] = d / s.v[i]
            if let li = lastIdx, i - li > 1, i - li <= bridge + 1, let prev = h[li] {
                for k in (li + 1)..<i where s.v[k] >= Thresholds.tailgateMinSpeed { h[k] = prev }
            }
            lastIdx = i
        }
        return h
    }

    private static func tailgatingEvents(_ s: DriveSeries) -> [DriveEvent] {
        let h = headway(s).map { $0 ?? Double.infinity }
        return runEvents(s, kind: .tailgating, mask: h.map { $0 < Thresholds.tailgateHeadway },
                         sustain: Thresholds.tailgateSustain,
                         peakScore: { -h[$0] },
                         severity: { i, _ in Numerics.ramp(h[i], from: Thresholds.tailgateHeadway, to: Thresholds.tailgateFullHeadway) })
    }

    static func debounce(_ events: [DriveEvent]) -> [DriveEvent] {
        var result: [DriveEvent] = []
        let byKind = Dictionary(grouping: events, by: \.kind)
        for kind in EventKind.allCases {
            guard let list = byKind[kind]?.sorted(by: { $0.tOffsetS < $1.tOffsetS }), !list.isEmpty else { continue }
            var merged: [DriveEvent] = []
            for ev in list {
                if var last = merged.last,
                   ev.tOffsetS - last.tEndS <= Thresholds.debounceMerge + 1e-9
                    || ev.tOffsetS - last.tOffsetS < Thresholds.debounceMinGap - 1e-9 {
                    last.tEndS = max(last.tEndS, ev.tEndS)
                    if ev.severity > last.severity {
                        last.severity = ev.severity; last.tPeakS = ev.tPeakS; last.lat = ev.lat; last.lon = ev.lon
                    }
                    merged[merged.count - 1] = last
                } else {
                    merged.append(ev)
                }
            }
            result += merged
        }
        return result
    }

    static func enrich(_ e: DriveEvent, _ s: DriveSeries, limits: [SpeedLimits.Match]?, mass: Double) -> DriveEvent {
        var ev = e
        let a = s.index(at: e.tOffsetS)
        let b = max(s.index(at: e.tEndS - s.dt), a)
        let p = s.index(at: e.tPeakS)
        var d = EventDetail()
        d.durationS = Double(b - a + 1) * s.dt
        switch e.kind {
        case .hardBrake, .hardAccel:
            let braking = e.kind == .hardBrake
            var lo = a, hi = b
            func inManoeuvre(_ i: Int) -> Bool { braking ? s.aLong[i] < Thresholds.brakingIntervalA : s.aLong[i] > -Thresholds.brakingIntervalA }
            while lo > 0 && inManoeuvre(lo - 1) { lo -= 1 }
            while hi < s.count - 1 && inManoeuvre(hi + 1) { hi += 1 }
            d.vStartMps = s.v[lo]
            d.vEndMps = s.v[hi]
            d.durationS = Double(hi - lo) * s.dt
            d.peak = s.aLong[p]
            if braking { d.energyJ = max(0.5 * mass * (s.v[lo] * s.v[lo] - s.v[hi] * s.v[hi]), 0) }
        case .harshCorner:
            d.vStartMps = s.v[p]
            d.peak = abs(s.aLat[p])
        case .speeding:
            d.vStartMps = s.v[p]
            d.limitMps = limits?[p].limitMps
            if let l = d.limitMps { d.peak = s.v[p] - l }
        case .idle, .laneDrift:
            break
        case .tailgating:
            let h = headway(s)
            d.headwayS = h[p]
            d.peak = h[p]
            d.leadDistM = s.leadDist[p]
            d.vStartMps = s.v[p]
        }
        d.road = limits?[p].road
        ev.detail = d
        return ev
    }
}
