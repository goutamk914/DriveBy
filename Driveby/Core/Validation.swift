import Foundation

struct DriveForValidation: Sendable {
    var id: UUID
    var vehicleId: UUID?
    var startedAt: Date
    var miles: Double
    var components: EfficiencyComponents
    var obdFuelGal: Double?
}

struct TankInterval: Identifiable, Sendable {
    var id: UUID { end.id }
    var start: FuelLog
    var end: FuelLog
    var odometerMiles: Double
    var gallons: Double
    var mpg: Double
    var recordedMiles: Double
    var driveIds: [UUID]
    var meanComponents: EfficiencyComponents?
    var coverage: Double { odometerMiles > 0 ? min(recordedMiles / odometerMiles, 1) : 0 }
}

struct ValidationPoint: Identifiable, Hashable, Sendable {
    var id: String
    var score: Double
    var target: Double
    var label: String
    var lowCoverage: Bool
}

struct ValidationResult: Sendable {
    enum Source: String, Sendable { case tank = "Tank-to-tank (fuel log)", obd = "Per-trip (OBD-II)" }
    var source: Source
    var normalizedByEPA: Bool
    var points: [ValidationPoint]
    var fit: Numerics.LinearFit?
    var n: Int { points.count }

    var honestSummary: String {
        guard let fit else {
            return n < 3 ? "n=\(n): not enough data yet." : "n=\(n): no fit yet."
        }
        let r2 = String(format: "%.2f", fit.r2)
        let direction = fit.slope > 0 ? "higher scores, better mpg" : "wrong direction, investigate"
        let strength: String
        switch (n, fit.r2) {
        case (..<8, _): strength = "too few points"
        case (_, ..<0.25): strength = "weak"
        case (_, ..<0.5): strength = "moderate"
        default: strength = n < 20 ? "suggestive, needs more data" : "strong"
        }
        return "n=\(n), r²=\(r2): \(strength); \(direction)."
    }
}

enum Validation {

    static func tankIntervals(logs: [FuelLog], drives: [DriveForValidation], vehicleId: UUID?) -> [TankInterval] {
        let mine = logs.filter { vehicleId == nil || $0.vehicleId == vehicleId }.sorted { $0.odometerMi < $1.odometerMi }
        var result: [TankInterval] = []
        var lastFull: FuelLog? = nil
        var pendingGallons = 0.0
        for log in mine {
            guard let prev = lastFull else {
                if log.filledToFull { lastFull = log }
                continue
            }
            pendingGallons += log.gallons
            guard log.filledToFull else { continue }
            let miles = log.odometerMi - prev.odometerMi
            if miles > 0 && pendingGallons > 0 {
                let inRange = drives.filter {
                    (vehicleId == nil || $0.vehicleId == vehicleId) && $0.startedAt >= prev.loggedAt && $0.startedAt < log.loggedAt
                }
                result.append(TankInterval(start: prev, end: log, odometerMiles: miles, gallons: pendingGallons,
                                           mpg: miles / pendingGallons, recordedMiles: inRange.map(\.miles).reduce(0, +),
                                           driveIds: inRange.map(\.id), meanComponents: weightedMean(inRange)))
            }
            lastFull = log
            pendingGallons = 0
        }
        return result
    }

    static func weightedMean(_ drives: [DriveForValidation]) -> EfficiencyComponents? {
        let total = drives.map(\.miles).reduce(0, +)
        guard total > 0 else { return nil }
        func wm(_ f: (EfficiencyComponents) -> Double) -> Double {
            drives.map { f($0.components) * $0.miles }.reduce(0, +) / total
        }
        return EfficiencyComponents(brakeWaste: wm(\.brakeWaste), idleFrac: wm(\.idleFrac), jerkRMS: wm(\.jerkRMS),
                                    highSpeed: wm(\.highSpeed), accelWaste: wm(\.accelWaste))
    }

    static func tankValidation(intervals: [TankInterval], model: ScoringModel, epaCombined: Double?,
                               minCoverage: Double = 0.5) -> ValidationResult {
        let df = DateFormatter(); df.dateFormat = "MMM d"
        var points: [ValidationPoint] = []
        for iv in intervals {
            guard let c = iv.meanComponents else { continue }
            let target = epaCombined.map { iv.mpg / $0 } ?? iv.mpg
            points.append(ValidationPoint(id: iv.end.id.uuidString, score: model.efficiencyScore(c), target: target,
                                          label: "\(df.string(from: iv.start.loggedAt)) - \(df.string(from: iv.end.loggedAt))",
                                          lowCoverage: iv.coverage < minCoverage))
        }
        let used = points.filter { !$0.lowCoverage }
        return ValidationResult(source: .tank, normalizedByEPA: epaCombined != nil, points: points,
                                fit: Numerics.linearFit(x: used.map(\.score), y: used.map(\.target)))
    }

    static func obdValidation(drives: [DriveForValidation], model: ScoringModel, epaCombined: Double?) -> ValidationResult {
        var points: [ValidationPoint] = []
        for d in drives {
            guard let gal = d.obdFuelGal, gal > 0.01, d.miles > 0.5 else { continue }
            let mpg = d.miles / gal
            guard mpg > 3 && mpg < 150 else { continue }
            points.append(ValidationPoint(id: d.id.uuidString, score: model.efficiencyScore(d.components),
                                          target: epaCombined.map { mpg / $0 } ?? mpg,
                                          label: String(format: "%.1f mi", d.miles), lowCoverage: false))
        }
        return ValidationResult(source: .obd, normalizedByEPA: epaCombined != nil, points: points,
                                fit: Numerics.linearFit(x: points.map(\.score), y: points.map(\.target)))
    }

    static func fitWeights(rows: [(components: EfficiencyComponents, target: Double)], base: ScoringModel,
                           lambda: Double = 0.5) -> ScoringModel? {
        guard rows.count >= 6 else { return nil }
        let X = rows.map { r in EfficiencyComponents.keys.map { base.normalized(r.components)[$0] ?? 0 } }
        guard let fit = Numerics.ridge(X: X, y: rows.map(\.target), lambda: lambda) else { return nil }
        let raw = fit.coef.map { max(-$0, 0) }
        let total = raw.reduce(0, +)
        guard total > 0 else { return nil }
        var m = base
        for (k, w) in zip(EfficiencyComponents.keys, raw) { m.weights[k] = w / total }
        let iso = ISO8601DateFormatter().string(from: Date())
        m.source = "fitted:\(iso.prefix(10))"
        let scores = rows.map { m.efficiencyScore($0.components) }
        let lf = Numerics.linearFit(x: scores, y: rows.map(\.target))
        m.fitN = rows.count
        m.fitR2 = lf?.r2
        return m
    }
}
