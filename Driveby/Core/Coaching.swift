import Foundation

enum DriverMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case regular = "advanced"
    case newDriver = "beginner"

    var id: String { rawValue }
    var title: String { self == .newDriver ? "New driver" : "Regular driver" }
    var summary: String {
        switch self {
        case .regular: return "Short spoken tips while you drive and a clear score after. Only significant issues are flagged."
        case .newDriver: return "Learner's-permit mode: supervised-hours log, a pre-drive checklist, encouraging voice tips and every moment explained."
        }
    }
}

enum Skill: String, Codable, CaseIterable, Identifiable, Sendable {
    case smoothBraking = "smooth_braking"
    case smoothAcceleration = "smooth_acceleration"
    case turns
    case speedControl = "speed_control"
    case followingDistance = "following_distance"
    case stopSigns = "stop_signs"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smoothBraking: return "Smooth Braking"
        case .smoothAcceleration: return "Smooth Acceleration"
        case .turns: return "Turns"
        case .speedControl: return "Speed Control"
        case .followingDistance: return "Following Distance"
        case .stopSigns: return "Stop Signs"
        }
    }

    var definition: String {
        switch self {
        case .smoothBraking: return "Share of your slow-downs that were gentle (under 0.22 g)."
        case .smoothAcceleration: return "Share of your speed-ups that were gentle (under 0.2 g)."
        case .turns: return "Share of your turns taken without heavy sideways force (under 0.25 g)."
        case .speedControl: return "Share of driving time within 5 mph of the speed limit."
        case .followingDistance: return "Share of time behind another car with at least a 2-second gap."
        case .stopSigns: return "Share of stop signs where you came to a full stop."
        }
    }

    var unit: String {
        switch self {
        case .smoothBraking: return "slow-downs"
        case .smoothAcceleration: return "speed-ups"
        case .turns: return "turns"
        case .speedControl, .followingDistance: return "minutes"
        case .stopSigns: return "stop signs"
        }
    }

    var minimumTotal: Double {
        switch self {
        case .speedControl, .followingDistance: return 60
        default: return 3
        }
    }
}

struct SkillStat: Codable, Hashable, Sendable {
    var good: Double
    var total: Double
    var percent: Double? { total > 0 ? 100 * good / total : nil }

    static func + (a: SkillStat, b: SkillStat) -> SkillStat { SkillStat(good: a.good + b.good, total: a.total + b.total) }
}

struct SkillReport: Codable, Hashable, Sendable {
    var stats: [String: SkillStat] = [:]

    subscript(skill: Skill) -> SkillStat { stats[skill.rawValue] ?? SkillStat(good: 0, total: 0) }

    func percent(_ skill: Skill) -> Double? {
        let s = self[skill]
        return s.total >= skill.minimumTotal ? s.percent : nil
    }

    static func combine(_ reports: [SkillReport]) -> SkillReport {
        var out = SkillReport()
        for r in reports {
            for (k, v) in r.stats { out.stats[k] = (out.stats[k] ?? SkillStat(good: 0, total: 0)) + v }
        }
        return out
    }
}

enum SkillThresholds {
    static let smoothBrakeA = -2.2
    static let smoothAccelA = 2.0
    static let smoothTurnLat = 2.5
    static let episodeMinDeltaV = 2.5
    static let turnYaw = 0.08
    static let turnMinAngle = 0.6
    static let speedTolerance = 2.24
    static let goodHeadway = 2.0
    static let stopFull = 0.7
    static let stopRolling = 4.5
    static let stopRadius = 30.0
}

struct BrakeEpisode: Sendable { var start: Int; var end: Int; var vStart: Double; var vEnd: Double; var peak: Double }
struct TurnEpisode: Sendable { var start: Int; var end: Int; var angle: Double; var peakLat: Double; var peakV: Double }

enum SkillAnalyzer {
    static func brakeEpisodes(_ s: DriveSeries) -> [BrakeEpisode] {
        Numerics.runs(s.aLong.map { $0 < Thresholds.brakingIntervalA }).compactMap { a, b in
            let dv = s.v[a] - s.v[b]
            guard dv >= SkillThresholds.episodeMinDeltaV, !s.gpsGap[a...b].contains(true) else { return nil }
            return BrakeEpisode(start: a, end: b, vStart: s.v[a], vEnd: s.v[b], peak: s.aLong[a...b].min() ?? 0)
        }
    }

    static func accelEpisodes(_ s: DriveSeries) -> [BrakeEpisode] {
        Numerics.runs(s.aLong.map { $0 > -Thresholds.brakingIntervalA }).compactMap { a, b in
            let dv = s.v[b] - s.v[a]
            guard dv >= SkillThresholds.episodeMinDeltaV, !s.gpsGap[a...b].contains(true) else { return nil }
            return BrakeEpisode(start: a, end: b, vStart: s.v[a], vEnd: s.v[b], peak: s.aLong[a...b].max() ?? 0)
        }
    }

    static func turnEpisodes(_ s: DriveSeries) -> [TurnEpisode] {
        let mask = (0..<s.count).map { abs(s.yawRate[$0]) > SkillThresholds.turnYaw && s.v[$0] > 3 }
        return Numerics.runs(mask).compactMap { a, b in
            let angle = abs(s.yawRate[a...b].reduce(0, +) * s.dt)
            guard angle >= SkillThresholds.turnMinAngle else { return nil }
            return TurnEpisode(start: a, end: b, angle: angle,
                               peakLat: s.aLat[a...b].map { abs($0) }.max() ?? 0, peakV: s.v[a...b].max() ?? 0)
        }
    }

    static func analyze(series s: DriveSeries, limits: [SpeedLimits.Match], stops: [StopSignPass]) -> SkillReport {
        var r = SkillReport()
        let brakes = brakeEpisodes(s)
        r.stats[Skill.smoothBraking.rawValue] = SkillStat(good: Double(brakes.filter { $0.peak > SkillThresholds.smoothBrakeA }.count),
                                                          total: Double(brakes.count))
        let accels = accelEpisodes(s)
        r.stats[Skill.smoothAcceleration.rawValue] = SkillStat(good: Double(accels.filter { $0.peak < SkillThresholds.smoothAccelA }.count),
                                                               total: Double(accels.count))
        let turns = turnEpisodes(s)
        r.stats[Skill.turns.rawValue] = SkillStat(good: Double(turns.filter { $0.peakLat < SkillThresholds.smoothTurnLat }.count),
                                                  total: Double(turns.count))
        if limits.count == s.count {
            var good = 0.0, total = 0.0
            for i in 0..<s.count where s.v[i] > 2 {
                guard let l = limits[i].limitMps else { continue }
                total += s.dt
                if s.v[i] <= l + SkillThresholds.speedTolerance { good += s.dt }
            }
            r.stats[Skill.speedControl.rawValue] = SkillStat(good: good, total: total)
        }
        var hGood = 0.0, hTotal = 0.0
        for h in EventDetector.headway(s) { if let h { hTotal += s.dt; if h >= SkillThresholds.goodHeadway { hGood += s.dt } } }
        r.stats[Skill.followingDistance.rawValue] = SkillStat(good: hGood, total: hTotal)
        r.stats[Skill.stopSigns.rawValue] = SkillStat(good: Double(stops.filter { $0.outcome == .fullStop }.count),
                                                      total: Double(stops.count))
        return r
    }
}

struct StopSignPass: Codable, Hashable, Sendable {
    enum Outcome: String, Codable, Sendable { case fullStop = "full_stop", rolling, missed }
    var nodeId: Int64
    var t: Double
    var lat: Double
    var lon: Double
    var minSpeedMps: Double
    var approachSpeedMps: Double
    var approachPeakDecel: Double
    var outcome: Outcome
    var road: String?
}

enum StopSignAnalyzer {
    static func analyze(series s: DriveSeries, limits: [SpeedLimits.Match], controls: [OSMControl]) -> [StopSignPass] {
        guard s.count > 1, limits.count == s.count else { return [] }
        let proj = Geo.LocalProjection(lat0: s.lat[s.count / 2], lon0: s.lon[s.count / 2])
        let pts = (0..<s.count).map { proj.xy(s.lat[$0], s.lon[$0]) }
        var out: [StopSignPass] = []
        for c in controls where c.kind == .stop && !c.wayIds.isEmpty && (c.allWay || c.wayIds.count == 1) {
            let (cx, cy) = proj.xy(c.lat, c.lon)
            let d = pts.map { (($0.0 - cx) * ($0.0 - cx) + ($0.1 - cy) * ($0.1 - cy)).squareRoot() }
            let near = d.map { $0 < SkillThresholds.stopRadius }
            for (a, b) in Numerics.runs(near) {
                var k = a
                for i in a...b where d[i] < d[k] { k = i }
                let approached = d[a] - d[k] >= 8 || a == 0
                let ways = (a...k).compactMap { limits[$0].wayId }
                let onSignedRoad = ways.contains { c.wayIds.contains($0) }
                guard approached, onSignedRoad else { continue }
                let lo = max(a - Int((8 / s.dt).rounded()), 0)
                let hi = min(k + Int((1 / s.dt).rounded()), s.count - 1)
                var m = lo
                for i in lo...hi where s.v[i] < s.v[m] { m = i }
                let minV = s.v[m]
                let outcome: StopSignPass.Outcome = minV < SkillThresholds.stopFull ? .fullStop
                    : minV < SkillThresholds.stopRolling ? .rolling : .missed
                let pre = max(m - Int((8 / s.dt).rounded()), 0)
                out.append(StopSignPass(nodeId: c.id, t: s.t[m], lat: c.lat, lon: c.lon, minSpeedMps: minV,
                                        approachSpeedMps: s.v[pre], approachPeakDecel: s.aLong[pre...m].min() ?? 0,
                                        outcome: outcome, road: limits[k].road))
            }
        }
        return out.sorted { $0.t < $1.t }
    }
}

enum MomentKind: String, Codable, Sendable {
    case hardBrake = "hard_brake", hardAccel = "hard_accel", harshCorner = "harsh_corner"
    case speeding, idle, tailgating, laneDrift = "lane_drift"
    case rollingStop = "rolling_stop", missedStop = "missed_stop"
    case goodStop = "good_stop", smoothStop = "smooth_stop", smoothTurn = "smooth_turn"

    var isPositive: Bool { [.goodStop, .smoothStop, .smoothTurn].contains(self) }

    var title: String {
        switch self {
        case .goodStop: return "Good stop sign approach"
        case .smoothStop: return "Smooth stop"
        case .smoothTurn: return "Smooth turn"
        case .rollingStop: return "Rolling stop"
        case .missedStop: return "Stop sign — flagged for review"
        default: return EventKind(rawValue: rawValue)?.title ?? rawValue
        }
    }

    var skill: Skill? {
        switch self {
        case .hardBrake, .smoothStop: return .smoothBraking
        case .hardAccel: return .smoothAcceleration
        case .harshCorner, .smoothTurn: return .turns
        case .speeding: return .speedControl
        case .tailgating: return .followingDistance
        case .rollingStop, .missedStop, .goodStop: return .stopSigns
        case .idle, .laneDrift: return nil
        }
    }
}

struct DriveMoment: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var kind: MomentKind
    var t: Double
    var tEnd: Double
    var severity: Double
    var lat: Double?
    var lon: Double?
    var eventId: UUID?
    var headline: String = ""
    var body: String = ""
    var tip: String = ""
    var clipPath: String? = nil
    var place: String? = nil

    var isPositive: Bool { kind.isPositive }

    var isSignificant: Bool {
        if isPositive { return false }
        switch kind {
        case .speeding, .tailgating, .missedStop: return true
        case .idle: return severity >= 0.6
        default: return severity >= 0.35
        }
    }
}

enum MomentBuilder {
    static func merge(events: [DriveEvent], highlights: [DriveMoment], tripStartT: Double, pricePerGallon: Double) -> [DriveMoment] {
        var moments = highlights
        for e in events {
            let c = EventCopywriter.copy(for: e, tripStartT: tripStartT, pricePerGallon: pricePerGallon)
            moments.append(DriveMoment(id: e.id, kind: MomentKind(rawValue: e.kind.rawValue) ?? .hardBrake, t: e.tOffsetS, tEnd: e.tEndS,
                                       severity: e.severity, lat: e.lat, lon: e.lon, eventId: e.id,
                                       headline: c.headline, body: c.body, tip: c.tip, clipPath: e.clipPath,
                                       place: e.detail.road))
        }
        return moments.sorted { $0.t < $1.t }
    }

    static func highlights(series s: DriveSeries, stops: [StopSignPass], tripStartT: Double) -> [DriveMoment] {
        var moments: [DriveMoment] = []
        let into = { (t: Double) in EventCopywriter.timeInto(t - tripStartT) }
        func at(_ road: String?) -> String { road.map { " on \($0)" } ?? "" }
        for p in stops {
            var m = DriveMoment(kind: .goodStop, t: p.t - 2, tEnd: p.t + 1, severity: 0, lat: p.lat, lon: p.lon, place: p.road)
            let from = EventCopywriter.mph(p.approachSpeedMps)
            switch p.outcome {
            case .fullStop:
                if p.approachPeakDecel > SkillThresholds.smoothBrakeA {
                    m.headline = "Good stop sign approach — \(into(p.t)) into your drive"
                    m.body = "You eased from \(from) mph to a full stop at the stop sign\(at(p.road))."
                    m.tip = "This is exactly it: slow early, stop completely, then look left-right-left."
                } else {
                    m.headline = "Full stop at the stop sign — \(into(p.t)) into your drive"
                    m.body = "You stopped completely at the stop sign\(at(p.road)) — but the braking at the end was firm."
                    m.tip = "Start slowing about 5 car-lengths earlier so the stop is gentle too."
                }
            case .rolling:
                m.kind = .rollingStop; m.severity = 0.5
                m.headline = "Rolling stop — \(into(p.t)) into your drive"
                m.body = "You slowed to \(EventCopywriter.mph(p.minSpeedMps)) mph but didn't stop completely at the stop sign\(at(p.road))."
                m.tip = "A full stop means the car stops moving. Count \"one-thousand-one\" before going."
            case .missed:
                m.kind = .missedStop; m.severity = 0.8
                m.headline = "Stop sign flagged for review — \(into(p.t)) into your drive"
                m.body = "Map data shows a stop sign here\(at(p.road)), and you passed at \(EventCopywriter.mph(p.minSpeedMps)) mph. Watch the clip: map data can be wrong."
                m.tip = "If there was a stop sign, practise stopping at the white line, then creeping forward to see."
            }
            moments.append(m)
        }
        let stopTimes = stops.map(\.t)
        let smoothStops = SkillAnalyzer.brakeEpisodes(s)
            .filter { $0.vStart >= 11 && $0.vEnd < 1 && $0.peak > SkillThresholds.smoothBrakeA }
            .filter { e in !stopTimes.contains { abs($0 - s.t[e.end]) < 10 } }
            .sorted { $0.vStart > $1.vStart }
            .prefix(3)
        for e in smoothStops {
            let secs = Double(e.end - e.start) * s.dt
            moments.append(DriveMoment(kind: .smoothStop, t: s.t[e.start], tEnd: s.t[e.end], severity: 0,
                                       lat: s.lat[e.end], lon: s.lon[e.end],
                                       headline: "Smooth stop — \(into(s.t[e.start])) into your drive",
                                       body: String(format: "You came down from %@ mph to a stop over %.0f seconds without a jolt.",
                                                    EventCopywriter.mph(e.vStart), secs),
                                       tip: "Gentle stops like this save fuel and give the driver behind you time to react."))
        }
        let smoothTurns = SkillAnalyzer.turnEpisodes(s)
            .filter { $0.angle >= 1.05 && $0.peakV >= 6 && $0.peakLat < 2.0 }
            .sorted { $0.peakV > $1.peakV }
            .prefix(2)
        for t in smoothTurns {
            let mid = (t.start + t.end) / 2
            moments.append(DriveMoment(kind: .smoothTurn, t: s.t[t.start], tEnd: s.t[t.end], severity: 0,
                                       lat: s.lat[mid], lon: s.lon[mid],
                                       headline: "Smooth turn — \(into(s.t[t.start])) into your drive",
                                       body: String(format: "A %.0f° turn at %@ mph with steady, gentle sideways force.",
                                                    t.angle * 180 / .pi, EventCopywriter.mph(t.peakV)),
                                       tip: "Slow before the turn, then a light, steady throttle through it — like this."))
        }
        return moments.sorted { $0.t < $1.t }
    }
}

struct PracticeFocus: Codable, Hashable, Sendable, Identifiable {
    var skill: Skill?
    var title: String
    var why: String
    var steps: [String]
    var id: String { skill?.rawValue ?? title }
}

enum PracticePlanner {
    static func drill(for skill: Skill) -> (title: String, steps: [String]) {
        switch skill {
        case .smoothBraking:
            return ("Smooth stops", ["In an empty parking lot, drive toward a cone at 15 mph.",
                                     "Lift off the gas early and let the car coast first.",
                                     "Squeeze the brake gradually — aim for passengers not to lean forward.",
                                     "Ease off the brake slightly just before stopping to avoid the final jolt.",
                                     "Repeat 10 times, then try at 25 mph on a quiet street."])
        case .smoothAcceleration:
            return ("Gentle starts", ["From a full stop, press the gas as if there's an egg under your foot.",
                                      "Take about 6–8 seconds to reach 25 mph.",
                                      "Repeat at 5 stop signs on a quiet loop."])
        case .turns:
            return ("Slow in, smooth out", ["Finish braking BEFORE the turn begins.",
                                            "Look through the turn to where you want to go.",
                                            "Hold a light, steady throttle through the turn; unwind the wheel smoothly.",
                                            "Practise 10 right and 10 left turns in a quiet neighbourhood."])
        case .speedControl:
            return ("Hold the limit", ["Before each drive, note the speed limits on your route.",
                                       "Glance at the speedometer every 5–8 seconds.",
                                       "On downhills, ease off early instead of braking late.",
                                       "Practise on one familiar 35 mph road until it's automatic."])
        case .followingDistance:
            return ("The 3-second rule", ["Pick a fixed object the car ahead passes.",
                                          "Count \"one-thousand-one, two, three\" — you shouldn't reach it before 3.",
                                          "If you do, ease off and let the gap grow.",
                                          "Add a second in rain or at night."])
        case .stopSigns:
            return ("Complete stops", ["Start slowing 5 car-lengths before the sign.",
                                       "Stop at the white line (or before the crosswalk).",
                                       "Count \"one-thousand-one\" with the car fully still.",
                                       "Creep forward to see if needed, then go when clear."])
        }
    }

    static func plan(skills: SkillReport, nightHoursRemaining: Double?, maxItems: Int = 2) -> [PracticeFocus] {
        var ranked: [(Skill, Double)] = Skill.allCases.compactMap { sk in skills.percent(sk).map { (sk, $0) } }
        ranked.sort { $0.1 < $1.1 }
        var out: [PracticeFocus] = []
        for (skill, pct) in ranked where pct < 85 && out.count < maxItems {
            let d = drill(for: skill)
            out.append(PracticeFocus(skill: skill, title: d.title,
                                     why: String(format: "%@ is your lowest skill right now (%.0f%%). %@", skill.title, pct, skill.definition),
                                     steps: d.steps))
        }
        if let night = nightHoursRemaining, night > 0, out.count < maxItems {
            out.append(PracticeFocus(skill: nil, title: "Practise after sunset",
                                     why: String(format: "You still need %.1f night hours for your permit log.", night),
                                     steps: ["Plan a familiar route and drive it after sunset with your supervisor.",
                                             "Use low beams; switch to high beams only on empty dark roads.",
                                             "Leave a 4-second gap — it's harder to judge distance at night."]))
        }
        if out.isEmpty {
            if ranked.isEmpty {
                out.append(PracticeFocus(skill: nil, title: "Keep driving",
                                         why: "A few more recorded drives and Driveby can tell you which skill to work on.",
                                         steps: ["Record your next practice drive start to finish."]))
            } else {
                out.append(PracticeFocus(skill: nil, title: "Level up",
                                         why: "Every skill is at 85% or better. Time for new situations — with your supervisor.",
                                         steps: ["Merge onto a highway during light traffic.",
                                                 "Drive a new route you've never taken.",
                                                 "Practise in light rain with extra following distance."]))
            }
        }
        return out
    }
}

enum Solar {
    static func sunriseSunset(on date: Date, lat: Double, lon: Double) -> (sunrise: Date, sunset: Date)? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let dayStart = cal.startOfDay(for: date)
        func event(rising: Bool) -> Date? {
            var minutes = 720 - 4 * lon
            for _ in 0..<3 {
                guard let (eqTime, decl) = sunParameters(at: dayStart.addingTimeInterval(minutes * 60)) else { return nil }
                let rad = Double.pi / 180
                let cosH = cos(90.833 * rad) / (cos(lat * rad) * cos(decl)) - tan(lat * rad) * tan(decl)
                guard cosH >= -1, cosH <= 1 else { return nil }
                let ha = acos(cosH) / rad
                let noon = 720 - 4 * lon - eqTime
                minutes = rising ? noon - 4 * ha : noon + 4 * ha
            }
            return dayStart.addingTimeInterval(minutes * 60)
        }
        guard let rise = event(rising: true), let set = event(rising: false) else { return nil }
        return (rise, set)
    }

    private static func sunParameters(at t: Date) -> (Double, Double)? {
        let rad = Double.pi / 180
        let jd = t.timeIntervalSince1970 / 86_400 + 2_440_587.5
        let T = (jd - 2_451_545) / 36_525
        let L0 = (280.46646 + T * (36000.76983 + T * 0.0003032)).truncatingRemainder(dividingBy: 360)
        let M = 357.52911 + T * (35999.05029 - 0.0001537 * T)
        let e = 0.016708634 - T * (0.000042037 + 0.0000001267 * T)
        let C = sin(M * rad) * (1.914602 - T * (0.004817 + 0.000014 * T)) + sin(2 * M * rad) * (0.019993 - 0.000101 * T)
            + sin(3 * M * rad) * 0.000289
        let omega = 125.04 - 1934.136 * T
        let appLong = L0 + C - 0.00569 - 0.00478 * sin(omega * rad)
        let meanObliq = 23 + (26 + (21.448 - T * (46.815 + T * (0.00059 - T * 0.001813))) / 60) / 60
        let obliq = meanObliq + 0.00256 * cos(omega * rad)
        let decl = asin(sin(obliq * rad) * sin(appLong * rad))
        let y = pow(tan(obliq * rad / 2), 2)
        let eq = y * sin(2 * L0 * rad) - 2 * e * sin(M * rad) + 4 * e * y * sin(M * rad) * cos(2 * L0 * rad)
            - 0.5 * y * y * sin(4 * L0 * rad) - 1.25 * e * e * sin(2 * M * rad)
        return (4 * eq / rad, decl)
    }

    static func isNight(_ t: Date, lat: Double, lon: Double) -> Bool {
        let solarNoonShift = -lon / 15 * 3600
        let probe = t.addingTimeInterval(-solarNoonShift)
        guard let s = sunriseSunset(on: probe, lat: lat, lon: lon) else { return false }
        return t < s.sunrise || t > s.sunset
    }

    static func nightSeconds(from start: Date, to end: Date, lat: Double, lon: Double) -> Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        var night = 0.0
        var t = 0.0
        while t < total {
            let step = min(60, total - t)
            if isNight(start.addingTimeInterval(t + step / 2), lat: lat, lon: lon) { night += step }
            t += step
        }
        return night
    }
}

struct PracticeLogEntry: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var driveId: UUID? = nil
    var startedAt: Date
    var durationS: Double
    var nightS: Double
    var supervisor: String
    var notes: String = ""
    var manual: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, driveId = "drive_id", startedAt = "started_at", durationS = "duration_s", nightS = "night_s"
        case supervisor, notes, manual
    }
}

struct HoursRequirement: Codable, Equatable, Sendable {
    var totalHours: Double = 45
    var nightHours: Double = 15
    var label: String = "Virginia (under 18)"
}

struct HoursSummary: Equatable, Sendable {
    var totalS: Double
    var nightS: Double
    var requirement: HoursRequirement

    var totalHours: Double { totalS / 3600 }
    var nightHours: Double { nightS / 3600 }
    var totalRemaining: Double { max(requirement.totalHours - totalHours, 0) }
    var nightRemaining: Double { max(requirement.nightHours - nightHours, 0) }
    var complete: Bool { totalRemaining == 0 && nightRemaining == 0 }

    init(entries: [PracticeLogEntry], requirement: HoursRequirement) {
        totalS = entries.map(\.durationS).reduce(0, +)
        nightS = entries.map(\.nightS).reduce(0, +)
        self.requirement = requirement
    }

    static func hoursString(_ seconds: Double) -> String {
        let m = Int((seconds / 60).rounded())
        return "\(m / 60)h \(String(format: "%02d", m % 60))m"
    }
}

enum PracticeLogCSV {
    static func csv(_ entries: [PracticeLogEntry]) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"; df.locale = Locale(identifier: "en_US_POSIX")
        var s = "date,duration_min,night_min,supervisor,source,notes\n"
        func q(_ v: String) -> String { "\"" + v.replacingOccurrences(of: "\"", with: "\"\"").replacingOccurrences(of: "\n", with: " ") + "\"" }
        for e in entries.sorted(by: { $0.startedAt < $1.startedAt }) {
            s += "\(df.string(from: e.startedAt)),\(Int((e.durationS / 60).rounded())),\(Int((e.nightS / 60).rounded())),\(q(e.supervisor)),\(e.manual ? "manual" : "recorded"),\(q(e.notes))\n"
        }
        return s
    }
}
