//  DriveAnalysis.swift — Driveby
//  One function from (sensor log, vehicle, speed-limit ways) → everything the UI shows.
//  Two-step because speed limits need the network:
//    1. `plan(log:)` → resampled series + trip + the Overpass tiles to fetch
//    2. `analyze(...)` with whatever ways were obtained (possibly none → speeding marked unavailable)

import Foundation

struct VehicleParams: Sendable {
    var massKg: Double = 1500
    var regenFactor: Double = 0
    var epaCombined: Double? = nil
}

struct TracePoint: Codable, Hashable, Sendable {
    var t: Double          // sensor time
    var v: Double          // m/s
    var a: Double          // a_long m/s²
    var lat: Double
    var lon: Double
    var aLat: Double
    var headway: Double?
    var limit: Double?

    enum CodingKeys: String, CodingKey { case t, v, a, lat, lon, aLat = "a_lat", headway, limit }
}

struct DriveAnalysis: Codable, Sendable {
    var version: Int = 2
    var tripStartT: Double
    var tripEndT: Double
    var distanceM: Double
    var durationS: Double
    var movingS: Double
    var maxSpeedMps: Double
    var components: EfficiencyComponents
    var safety: SafetyBreakdown
    var events: [DriveEvent]
    /// 2 Hz trace for charts, the route map, and the clip overlay.
    var trace: [TracePoint]
    var speedLimitsAvailable: Bool
    var speedLimitCoverage: Double       // fraction of samples with a matched limit
    var tailgatingAvailable: Bool        // lead-vehicle detections were present
    var gpsFixes: Int
    var imuSamples: Int
    var malformedLines: Int
    var imuJerkRMS: Double?
    var obdFuelGal: Double?              // integrated from OBD fuel rate / MAF, nil if unavailable
    var obdMethod: String?               // "fuel_rate" | "maf"
    var processedAt: Date
    // Coaching layer (v3) — optional so older analysis.json files and the Python processor's output still decode.
    var skills: SkillReport? = nil
    var stopSigns: [StopSignPass]? = nil
    var highlights: [DriveMoment]? = nil   // positive moments + stop-sign moments (events are merged at display time)

    enum CodingKeys: String, CodingKey {
        case version, tripStartT = "trip_start_t", tripEndT = "trip_end_t", distanceM = "distance_m"
        case durationS = "duration_s", movingS = "moving_s", maxSpeedMps = "max_speed_mps", components, safety, events, trace
        case speedLimitsAvailable = "speed_limits_available", speedLimitCoverage = "speed_limit_coverage"
        case tailgatingAvailable = "tailgating_available", gpsFixes = "gps_fixes", imuSamples = "imu_samples"
        case malformedLines = "malformed_lines", imuJerkRMS = "imu_jerk_rms", obdFuelGal = "obd_fuel_gal"
        case obdMethod = "obd_method", processedAt = "processed_at"
        case skills, stopSigns = "stop_signs", highlights
    }

    /// The post-drive reflection timeline (good and bad moments, chronological).
    func moments(pricePerGallon: Double) -> [DriveMoment] {
        MomentBuilder.merge(events: events, highlights: highlights ?? [], tripStartT: tripStartT, pricePerGallon: pricePerGallon)
    }

    var miles: Double { Units.miles(distanceM) }
    var obdMPG: Double? { obdFuelGal.flatMap { $0 > 0.005 ? miles / $0 : nil } }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; e.dateEncodingStrategy = .iso8601
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return d
    }()
}

enum DriveAnalyzer {
    enum Failure: Error, Equatable {
        case noGPS(fixes: Int)
        case neverMoved
        case tooShort(distanceM: Double, durationS: Double)
    }

    struct Plan: Sendable {
        var series: DriveSeries      // full recording
        var trip: TripSegmenter.Trip
        var tripSeries: DriveSeries
        var tiles: [SpeedLimits.Tile]
    }

    static func plan(log: SensorLog) throws -> Plan {
        let series: DriveSeries
        do { series = try Ingest.resample(log) } catch Ingest.Failure.noUsableGPS(let n) { throw Failure.noGPS(fixes: n) }
        guard let trip = TripSegmenter.segment(series) else { throw Failure.neverMoved }
        let tripSeries = series.slice(trip.startIndex, trip.endIndex)
        if TripSegmenter.isTooShort(distance: tripSeries.totalDistance, duration: tripSeries.duration) {
            throw Failure.tooShort(distanceM: tripSeries.totalDistance, durationS: tripSeries.duration)
        }
        return Plan(series: series, trip: trip, tripSeries: tripSeries,
                    tiles: SpeedLimits.tiles(lat: tripSeries.lat, lon: tripSeries.lon))
    }

    static func analyze(plan: Plan, log: SensorLog, vehicle: VehicleParams, ways: [OSMWay]?, controls: [OSMControl] = []) -> DriveAnalysis {
        let s = plan.tripSeries
        let limits = ways.map { SpeedLimits.match(series: s, ways: $0) } ?? []
        let coverage = limits.isEmpty ? 0 : Double(limits.filter { $0.limitMps != nil }.count) / Double(max(s.count, 1))
        let events = EventDetector.detect(.init(series: s, limits: limits, massKg: vehicle.massKg))
        let components = Efficiency.components(s, massKg: vehicle.massKg, regenFactor: vehicle.regenFactor)
        let safety = Safety.score(events: events, series: s)
        let headway = EventDetector.headway(s)

        var trace: [TracePoint] = []
        let step = max(Int((0.5 / s.dt).rounded()), 1)
        var i = 0
        while i < s.count {
            trace.append(TracePoint(t: s.t[i], v: s.v[i], a: s.aLong[i], lat: s.lat[i], lon: s.lon[i], aLat: s.aLat[i],
                                    headway: headway[i], limit: limits.isEmpty ? nil : limits[i].limitMps))
            i += step
        }

        let tStart = s.t.first ?? 0, tEnd = (s.t.last ?? 0) + s.dt
        let fuel = obdFuel(log.obd, from: tStart, to: tEnd)
        let stops = StopSignAnalyzer.analyze(series: s, limits: limits, controls: controls)
        var result = DriveAnalysis(
            tripStartT: tStart, tripEndT: tEnd, distanceM: s.totalDistance, durationS: s.duration,
            movingS: Double(s.v.filter { $0 >= Thresholds.idleSpeed }.count) * s.dt,
            maxSpeedMps: s.v.max() ?? 0, components: components, safety: safety, events: events, trace: trace,
            speedLimitsAvailable: !limits.isEmpty && coverage > 0, speedLimitCoverage: coverage,
            tailgatingAvailable: s.leadDist.contains { $0 != nil },
            gpsFixes: log.gps.count, imuSamples: log.imu.count, malformedLines: log.malformedLines,
            imuJerkRMS: s.imuJerkRMS.isFinite ? s.imuJerkRMS : nil,
            obdFuelGal: fuel?.gallons, obdMethod: fuel?.method, processedAt: Date())
        result.version = 3
        result.stopSigns = stops
        result.skills = SkillAnalyzer.analyze(series: s, limits: limits, stops: stops)
        result.highlights = MomentBuilder.highlights(series: s, stops: stops, tripStartT: tStart)
        return result
    }

    /// Decision 4: integrate fuel from OBD — PID 015E fuel rate (L/h) preferred,
    /// else MAF (PID 0110): fuel_g/s = MAF / 14.7; gal/s = fuel_g/s / 2830.
    static func obdFuel(_ obd: [OBDSample], from t0: Double, to t1: Double) -> (gallons: Double, method: String)? {
        let window = obd.filter { $0.t >= t0 && $0.t <= t1 }
        guard window.count >= 10 else { return nil }
        let rateSamples = window.compactMap { o in o.fuelLph.map { (o.t, $0 / Units.litresPerGallon / 3600) } }
        let mafSamples = window.compactMap { o in o.maf.map { (o.t, $0 / Units.stoichiometricAFR / Units.gramsGasolinePerGallon) } }
        let (samples, method) = rateSamples.count >= window.count / 2 ? (rateSamples, "fuel_rate") : (mafSamples, "maf")
        guard samples.count >= 10 else { return nil }
        var gal = 0.0
        for k in 1..<samples.count {
            let dt = samples[k].0 - samples[k - 1].0
            guard dt > 0 && dt < 10 else { continue }  // don't integrate across dropouts
            gal += 0.5 * (samples[k].1 + samples[k - 1].1) * dt
        }
        return (gal, method)
    }
}
