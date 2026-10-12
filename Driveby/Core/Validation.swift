//  Validation.swift — Driveby
//  Phase 3.3 / 3.4: prove the efficiency score is real by regressing it against
//  ground-truth fuel economy, and REPORT IT HONESTLY (always show n and r²).
//
//  Two ground truths:
//   • Tank-to-tank MPG from the fuel log (n ≈ number of fill-ups)
//   • Per-trip MPG from the OBD-II dongle (n ≈ number of drives)
//  Target is MPG ÷ EPA combined when the EPA rating is known (controls for the car).
//  Mirrors processor/validate.py and notebooks/validation.ipynb.

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
    var meanComponents: EfficiencyComponents?   // distance-weighted
    var coverage: Double { odometerMiles > 0 ? min(recordedMiles / odometerMiles, 1) : 0 }
}

struct ValidationPoint: Identifiable, Hashable, Sendable {
    var id: String
    var score: Double          // x: efficiency score under the model
    var target: Double         // y: MPG or MPG / EPA combined
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

    /// The honest sentence (Step 3.4) — n first, then r², then what it means.
    var honestSummary: String {
        guard let fit else {
            return n < 3 ? "n=\(n) — not enough data yet. Keep logging every fill-up." : "n=\(n) — no linear relationship could be fitted."
        }
        let r2 = String(format: "%.2f", fit.r2)
        let direction = fit.slope > 0 ? "higher scores go with better fuel economy" : "the relationship runs the wrong way — investigate"
        let strength: String
        switch (n, fit.r2) {
        case (..<8, _): strength = "too few points to conclude anything"
        case (_, ..<0.25): strength = "weak"
        case (_, ..<0.5): strength = "moderate"
        default: strength = n < 20 ? "suggestive — the obvious next step is more data" : "strong"
        }
        return "n=\(n), r²=\(r2) — \(strength); \(direction)."
    }
}

enum Validation {

    /// Tank-to-tank intervals between consecutive FULL fills (partial fills roll forward).
    /// A drive belongs to the interval if it started after the previous full fill and before this one.
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

    /// Distance-weighted mean of each component across drives (Step 3.3, "without OBD").
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
                                          label: "\(df.string(from: iv.start.loggedAt))–\(df.string(from: iv.end.loggedAt))",
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
            guard mpg > 3 && mpg < 150 else { continue } // reject sensor nonsense
            points.append(ValidationPoint(id: d.id.uuidString, score: model.efficiencyScore(d.components),
                                          target: epaCombined.map { mpg / $0 } ?? mpg,
                                          label: String(format: "%.1f mi", d.miles), lowCoverage: false))
        }
        return ValidationResult(source: .obd, normalizedByEPA: epaCombined != nil, points: points,
                                fit: Numerics.linearFit(x: points.map(\.score), y: points.map(\.target)))
    }

    /// Step 3.3 — regress target on normalised components, negate and rescale the coefficients into
    /// weights that sum to 1. Ridge (λ) keeps n≈9 from producing wild weights. Returns nil if the data
    /// doesn't support any component (all coefficients ≥ 0) or there are too few rows.
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
