import Foundation

struct EfficiencyComponents: Codable, Hashable, Sendable {
    var brakeWaste: Double
    var idleFrac: Double
    var jerkRMS: Double
    var highSpeed: Double
    var accelWaste: Double

    enum CodingKeys: String, CodingKey {
        case brakeWaste = "brake_waste", idleFrac = "idle_frac", jerkRMS = "jerk_rms"
        case highSpeed = "high_speed", accelWaste = "accel_waste"
    }

    static let keys = ["brake_waste", "idle_frac", "jerk_rms", "high_speed", "accel_waste"]

    subscript(key: String) -> Double {
        switch key {
        case "brake_waste": return brakeWaste
        case "idle_frac": return idleFrac
        case "jerk_rms": return jerkRMS
        case "high_speed": return highSpeed
        case "accel_waste": return accelWaste
        default: return .nan
        }
    }

    var vector: [Double] { Self.keys.map { self[$0] } }

    static func label(_ key: String) -> String {
        switch key {
        case "brake_waste": return "Braking waste"
        case "idle_frac": return "Idling"
        case "jerk_rms": return "Jerkiness"
        case "high_speed": return "High-speed time"
        case "accel_waste": return "Hard acceleration"
        default: return key
        }
    }

    static func explanation(_ key: String) -> String {
        switch key {
        case "brake_waste": return "Fuel energy lost as brake heat."
        case "idle_frac": return "Time stopped with the engine on."
        case "jerk_rms": return "How abrupt your pedal inputs are."
        case "high_speed": return "Time above 65 mph."
        case "accel_waste": return "Starts harder than 0.15 g."
        default: return ""
        }
    }
}

enum Efficiency {
    static func brakingEnergyPerKm(_ s: DriveSeries, massKg: Double, regenFactor: Double = 0) -> Double {
        let km = s.totalDistance / 1000
        guard km > 0.01 else { return 0 }
        var total = 0.0
        for (a, b) in Numerics.runs(s.aLong.map { $0 < Thresholds.brakingIntervalA }) {
            let v0 = s.v[a], v1 = s.v[b]
            total += max(0.5 * massKg * (v0 * v0 - v1 * v1), 0)
        }
        return total * (1 - Numerics.clip(regenFactor, 0, 1)) / km
    }

    static func components(_ s: DriveSeries, massKg: Double, regenFactor: Double = 0) -> EfficiencyComponents {
        let n = Double(max(s.count, 1))
        let idle = Double(s.v.filter { $0 < Thresholds.idleSpeed }.count) / n
        let jerk = Numerics.gradient(s.aLong, dt: s.dt)
        let jerkRMS = s.count > 1 ? (jerk.map { $0 * $0 }.reduce(0, +) / n).squareRoot() : 0
        let high = Double(s.v.filter { $0 > Thresholds.highSpeed }.count) / n
        let accel = s.aLong.map { max($0 - Thresholds.accelWasteA, 0) }.reduce(0, +) / n
        return EfficiencyComponents(brakeWaste: brakingEnergyPerKm(s, massKg: massKg, regenFactor: regenFactor),
                                    idleFrac: idle, jerkRMS: jerkRMS, highSpeed: high, accelWaste: accel)
    }
}

struct ScoringModel: Codable, Equatable, Sendable {
    struct Range: Codable, Equatable, Sendable { var p5: Double; var p95: Double }

    var version: Int = 1
    var source: String = "default"
    var weights: [String: Double] = ScoringModel.defaultWeights
    var normalization: [String: Range] = ScoringModel.defaultNormalization
    var safety: SafetyCoefficients = SafetyCoefficients()
    var fitN: Int? = nil
    var fitR2: Double? = nil

    static let defaultWeights: [String: Double] = [
        "brake_waste": 0.35, "idle_frac": 0.15, "jerk_rms": 0.15, "high_speed": 0.20, "accel_waste": 0.15,
    ]

    static let defaultNormalization: [String: Range] = [
        "brake_waste": Range(p5: 20_000, p95: 450_000),
        "idle_frac": Range(p5: 0.0, p95: 0.30),
        "jerk_rms": Range(p5: 0.15, p95: 1.2),
        "high_speed": Range(p5: 0.0, p95: 0.60),
        "accel_waste": Range(p5: 0.0, p95: 0.08),
    ]

    static let minCorpusForPercentiles = 5

    func normalized(_ c: EfficiencyComponents) -> [String: Double] {
        var out: [String: Double] = [:]
        for k in EfficiencyComponents.keys {
            let r = normalization[k] ?? ScoringModel.defaultNormalization[k]!
            out[k] = r.p95 > r.p5 ? Numerics.clip((c[k] - r.p5) / (r.p95 - r.p5), 0, 1) : 0
        }
        return out
    }

    func efficiencyScore(_ c: EfficiencyComponents) -> Double {
        let n = normalized(c)
        let penalty = EfficiencyComponents.keys.map { (weights[$0] ?? 0) * (n[$0] ?? 0) }.reduce(0, +)
        return 100 * (1 - Numerics.clip(penalty, 0, 1))
    }

    func penaltyPoints(_ c: EfficiencyComponents) -> [String: Double] {
        let n = normalized(c)
        var out: [String: Double] = [:]
        for k in EfficiencyComponents.keys { out[k] = 100 * (weights[k] ?? 0) * (n[k] ?? 0) }
        return out
    }

    func withCorpus(_ corpus: [EfficiencyComponents]) -> ScoringModel {
        guard corpus.count >= ScoringModel.minCorpusForPercentiles, !source.hasPrefix("fitted") else { return self }
        var m = self
        for k in EfficiencyComponents.keys {
            let values = corpus.map { $0[k] }
            let p5 = Numerics.percentile(values, 5), p95 = Numerics.percentile(values, 95)
            if p95 > p5 { m.normalization[k] = Range(p5: p5, p95: p95) }
        }
        m.source = "corpus"
        return m
    }

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }()
}

struct SafetyCoefficients: Codable, Equatable, Sendable {
    var hardBrake: Double = 12
    var tailgatingFraction: Double = 14
    var harshCorner: Double = 6
    var speedingFraction: Double = 15

    enum CodingKeys: String, CodingKey {
        case hardBrake = "hard_brake", tailgatingFraction = "tailgating_fraction"
        case harshCorner = "harsh_corner", speedingFraction = "speeding_fraction"
    }
}

struct SafetyBreakdown: Codable, Hashable, Sendable {
    var hardBrakePoints: Double
    var tailgatingPoints: Double
    var harshCornerPoints: Double
    var speedingPoints: Double
    var tailgatingFraction: Double
    var speedingFraction: Double
    var per10MilesFactor: Double
    var score: Double

    enum CodingKeys: String, CodingKey {
        case hardBrakePoints = "hard_brake_points", tailgatingPoints = "tailgating_points"
        case harshCornerPoints = "harsh_corner_points", speedingPoints = "speeding_points"
        case tailgatingFraction = "tailgating_fraction", speedingFraction = "speeding_fraction"
        case per10MilesFactor = "per_10_miles_factor", score
    }
}

enum Safety {
    static func score(events: [DriveEvent], series s: DriveSeries, coefficients c: SafetyCoefficients = SafetyCoefficients()) -> SafetyBreakdown {
        let miles = max(Units.miles(s.totalDistance), 1.0)
        let factor = 10.0 / miles
        let moving = Double(s.v.filter { $0 >= Thresholds.idleSpeed }.count) * s.dt
        func sev(_ k: EventKind) -> Double { events.filter { $0.kind == k }.map(\.severity).reduce(0, +) }
        func time(_ k: EventKind) -> Double { events.filter { $0.kind == k }.map(\.duration).reduce(0, +) }
        let tailFrac = moving > 0 ? Numerics.clip(time(.tailgating) / moving, 0, 1) : 0
        let speedFrac = moving > 0 ? Numerics.clip(time(.speeding) / moving, 0, 1) : 0
        let hb = c.hardBrake * sev(.hardBrake) * factor
        let hc = c.harshCorner * sev(.harshCorner) * factor
        let tg = c.tailgatingFraction * tailFrac
        let sp = c.speedingFraction * speedFrac
        let score = Numerics.clip(100 - hb - tg - hc - sp, 0, 100)
        return SafetyBreakdown(hardBrakePoints: hb, tailgatingPoints: tg, harshCornerPoints: hc, speedingPoints: sp,
                               tailgatingFraction: tailFrac, speedingFraction: speedFrac, per10MilesFactor: factor, score: score)
    }
}
