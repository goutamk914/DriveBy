//  Contract.swift — Driveby
//
//  THE DATA CONTRACT (frozen Week 1 — see docs/DATA_CONTRACT.md).
//  The phone app writes these exact shapes; the Python processor reads them.
//
//  sensors.jsonl — one sample per line, `t` = seconds since recording start
//  on the MONOTONIC system clock (never wall-clock):
//    {"t":12.400,"type":"gps","lat":39.045,"lon":-77.487,"spd":18.2,"acc":4.0,"hdg":271.4}
//    {"t":12.420,"type":"imu","ax":0.11,"ay":-0.03,"az":9.79,"gx":0.001,"gy":0.002,"gz":-0.014,"yaw":-0.013}
//  Driveby extensions (optional, additive — old readers ignore them):
//    {"t":13.000,"type":"obd","rpm":1850,"kph":64,"maf":7.21,"fuel_lph":4.10}
//    {"t":13.033,"type":"lead","bx":0.41,"by":0.48,"bw":0.12,"bh":0.10,"dist":21.4}
//
//  drive.json sidecar:
//    { "drive_id": "...", "video_file": "drive_0007.mov", "sensor_file": "drive_0007.jsonl",
//      "video_start_t": 0.83, "vehicle_id": "...", "device": "iPhone 13" }
//
//  This file is pure Foundation so it compiles both in the iOS app and in the
//  DrivebyCore Swift package (tests run on macOS or Linux with `swift test`).

import Foundation

// MARK: - Event kinds (matches db/schema.sql `events.kind`)

enum EventKind: String, Codable, CaseIterable, Hashable, Sendable {
    case hardBrake = "hard_brake"
    case hardAccel = "hard_accel"
    case harshCorner = "harsh_corner"
    case speeding = "speeding"
    case idle = "idle"
    case laneDrift = "lane_drift"     // reserved in schema; lane detection is CUT for 2026 (2.0 roadmap)
    case tailgating = "tailgating"

    var title: String {
        switch self {
        case .hardBrake: return "Hard braking"
        case .hardAccel: return "Hard acceleration"
        case .harshCorner: return "Sharp turn"
        case .speeding: return "Over the limit"
        case .idle: return "Long idle"
        case .laneDrift: return "Lane drift"
        case .tailgating: return "Following too closely"
        }
    }

    /// Which score the event feeds.
    var affectsSafety: Bool { [.hardBrake, .harshCorner, .speeding, .tailgating].contains(self) }
    var affectsEfficiency: Bool { [.hardBrake, .hardAccel, .idle, .speeding].contains(self) }

    /// Kinds pooled into the public hazard map ("hard-brake / swerve events").
    static let hazardKinds: Set<EventKind> = [.hardBrake, .harshCorner]
}

// MARK: - Raw sensor samples

struct GPSSample: Equatable, Sendable {
    var t: Double          // s, monotonic since recording start
    var lat: Double
    var lon: Double
    var spd: Double?       // m/s (Doppler); nil when invalid
    var acc: Double        // horizontal accuracy, metres
    var hdg: Double?       // course over ground, degrees true; nil when invalid
}

struct IMUSample: Equatable, Sendable {
    var t: Double
    var ax: Double, ay: Double, az: Double   // m/s², device frame, INCLUDING gravity
    var gx: Double, gy: Double, gz: Double   // rad/s, device frame
    var yaw: Double?                         // rad/s about the gravity axis (orientation-free yaw rate)
}

struct OBDSample: Equatable, Sendable {
    var t: Double
    var rpm: Double?
    var kph: Double?
    var maf: Double?       // g/s
    var fuelLph: Double?   // L/h (PID 015E)
}

/// Lead vehicle detected in our lane by the on-device vision pass.
/// Box is normalised to the video frame, origin TOP-LEFT.
struct LeadSample: Equatable, Sendable {
    var t: Double
    var bx: Double, by: Double, bw: Double, bh: Double
    var dist: Double       // metres (pinhole model: real_width * focal_px / box_width_px)
}

struct SensorLog: Sendable {
    var gps: [GPSSample] = []
    var imu: [IMUSample] = []
    var obd: [OBDSample] = []
    var lead: [LeadSample] = []
    var malformedLines = 0

    var isEmpty: Bool { gps.isEmpty && imu.isEmpty }
    var lastT: Double {
        max(gps.last?.t ?? 0, imu.last?.t ?? 0, obd.last?.t ?? 0, lead.last?.t ?? 0)
    }
}

// MARK: - JSONL line formatting (writer side)

enum SampleLine {
    @inline(__always) private static func f(_ v: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", v)
    }

    static func gps(t: Double, lat: Double, lon: Double, spd: Double?, acc: Double, hdg: Double?) -> String {
        var s = "{\"t\":\(f(t, 3)),\"type\":\"gps\",\"lat\":\(f(lat, 7)),\"lon\":\(f(lon, 7))"
        s += ",\"spd\":" + (spd.map { f($0, 2) } ?? "null")
        s += ",\"acc\":\(f(acc, 1))"
        s += ",\"hdg\":" + (hdg.map { f($0, 1) } ?? "null")
        return s + "}"
    }

    static func imu(t: Double, ax: Double, ay: Double, az: Double,
                    gx: Double, gy: Double, gz: Double, yaw: Double?) -> String {
        var s = "{\"t\":\(f(t, 3)),\"type\":\"imu\",\"ax\":\(f(ax, 3)),\"ay\":\(f(ay, 3)),\"az\":\(f(az, 3))"
        s += ",\"gx\":\(f(gx, 4)),\"gy\":\(f(gy, 4)),\"gz\":\(f(gz, 4))"
        if let yaw { s += ",\"yaw\":\(f(yaw, 4))" }
        return s + "}"
    }

    static func obd(_ o: OBDSample) -> String {
        var s = "{\"t\":\(f(o.t, 3)),\"type\":\"obd\""
        if let v = o.rpm { s += ",\"rpm\":\(f(v, 0))" }
        if let v = o.kph { s += ",\"kph\":\(f(v, 0))" }
        if let v = o.maf { s += ",\"maf\":\(f(v, 2))" }
        if let v = o.fuelLph { s += ",\"fuel_lph\":\(f(v, 2))" }
        return s + "}"
    }

    static func lead(_ l: LeadSample) -> String {
        "{\"t\":\(f(l.t, 3)),\"type\":\"lead\",\"bx\":\(f(l.bx, 4)),\"by\":\(f(l.by, 4)),\"bw\":\(f(l.bw, 4)),\"bh\":\(f(l.bh, 4)),\"dist\":\(f(l.dist, 2))}"
    }
}

// MARK: - JSONL parsing (reader side)

enum SensorLogParser {
    /// Parses a sensors.jsonl blob. Malformed lines (e.g. a half-written final
    /// line after a crash or dead battery) are counted and skipped, never fatal.
    static func parse(_ data: Data) -> SensorLog {
        var log = SensorLog()
        guard !data.isEmpty else { return log }
        let newline = UInt8(ascii: "\n")
        var start = data.startIndex
        let end = data.endIndex
        while start < end {
            let lineEnd = data[start..<end].firstIndex(of: newline) ?? end
            if lineEnd > start {
                let slice = data[start..<lineEnd]
                if let obj = (try? JSONSerialization.jsonObject(with: slice, options: [])) as? [String: Any] {
                    if !ingest(obj, into: &log) { log.malformedLines += 1 }
                } else {
                    // tolerate trailing \r or whitespace-only lines
                    let trimmed = String(decoding: slice, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { log.malformedLines += 1 }
                }
            }
            start = lineEnd < end ? data.index(after: lineEnd) : end
        }
        // Samples are written in arrival order; GPS fixes can arrive slightly
        // out of order relative to IMU, so sort each stream by t.
        log.gps.sort { $0.t < $1.t }
        log.imu.sort { $0.t < $1.t }
        log.obd.sort { $0.t < $1.t }
        log.lead.sort { $0.t < $1.t }
        return log
    }

    private static func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d.isFinite ? d : nil }
        if let n = v as? NSNumber { let d = n.doubleValue; return d.isFinite ? d : nil }
        if let i = v as? Int { return Double(i) }
        return nil
    }

    private static func ingest(_ o: [String: Any], into log: inout SensorLog) -> Bool {
        guard let t = num(o["t"]), let type = o["type"] as? String else { return false }
        switch type {
        case "gps":
            guard let lat = num(o["lat"]), let lon = num(o["lon"]) else { return false }
            var spd = num(o["spd"]); if let s = spd, s < 0 { spd = nil }
            var hdg = num(o["hdg"]); if let h = hdg, h < 0 { hdg = nil }
            let acc = num(o["acc"]) ?? 999
            log.gps.append(GPSSample(t: t, lat: lat, lon: lon, spd: spd, acc: acc, hdg: hdg))
        case "imu":
            guard let ax = num(o["ax"]), let ay = num(o["ay"]), let az = num(o["az"]) else { return false }
            log.imu.append(IMUSample(t: t, ax: ax, ay: ay, az: az,
                                     gx: num(o["gx"]) ?? 0, gy: num(o["gy"]) ?? 0, gz: num(o["gz"]) ?? 0,
                                     yaw: num(o["yaw"])))
        case "obd":
            log.obd.append(OBDSample(t: t, rpm: num(o["rpm"]), kph: num(o["kph"]),
                                     maf: num(o["maf"]), fuelLph: num(o["fuel_lph"])))
        case "lead":
            guard let bx = num(o["bx"]), let by = num(o["by"]), let bw = num(o["bw"]),
                  let bh = num(o["bh"]), let dist = num(o["dist"]) else { return false }
            log.lead.append(LeadSample(t: t, bx: bx, by: by, bw: bw, bh: bh, dist: dist))
        default:
            return true // unknown future sample types are ignored, not errors
        }
        return true
    }
}

// MARK: - Sidecar

struct DriveSidecar: Codable, Equatable, Sendable {
    var driveId: String
    var videoFile: String?          // nil for sensors-only drives
    var sensorFile: String
    var videoStartT: Double?        // sensor-clock time of the first video frame
    var videoEndT: Double?          // sensor-clock time of the last written frame
    var videoInterrupted: Bool?     // camera stopped early (phone locked / app backgrounded)
    var vehicleId: String?
    var device: String
    var startedAt: Date             // wall clock at t = 0 (display only — never used for sync)
    var endedAt: Date?
    var focalPx: Double?            // camera focal length in pixels at video resolution
    var videoWidth: Int?
    var videoHeight: Int?
    var appVersion: String?
    var recordingMode: String?      // "camera" | "sensors"
    var supervisor: String? = nil   // licensed adult in the passenger seat (for the permit-hours log)

    enum CodingKeys: String, CodingKey {
        case driveId = "drive_id"
        case videoFile = "video_file"
        case sensorFile = "sensor_file"
        case videoStartT = "video_start_t"
        case videoEndT = "video_end_t"
        case videoInterrupted = "video_interrupted"
        case vehicleId = "vehicle_id"
        case device
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case focalPx = "focal_px"
        case videoWidth = "video_width"
        case videoHeight = "video_height"
        case appVersion = "app_version"
        case recordingMode = "recording_mode"
        case supervisor
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

// MARK: - Thresholds (single source of truth; mirrored in processor/contract.py)

enum Thresholds {
    // Step 1.3 — trip segmentation
    static let tripStartSpeed = 2.0          // m/s
    static let tripStartSustain = 10.0       // s
    static let tripEndSpeed = 0.5            // m/s
    static let tripEndSustain = 180.0        // s
    static let minTripDistance = 500.0       // m
    static let minTripDuration = 120.0       // s

    // Step 2.1 — ingest
    static let maxGPSAccuracy = 20.0         // m — drop worse fixes before resampling
    static let resampleHz = 10.0
    static let savgolWindow = 21             // samples ≈ 2.1 s at 10 Hz
    static let savgolOrder = 3

    // Step 2.2 — events
    static let hardBrakeA = -3.0, hardBrakeFull = -6.0
    static let hardAccelA = 2.5, hardAccelFull = 5.0
    static let harshCornerA = 3.0, harshCornerFull = 6.0
    static let accelSustain = 0.5            // s
    static let speedingMargin = 4.5          // m/s over the limit (~10 mph)
    static let speedingSustain = 5.0         // s
    static let speedingFullExcess = 13.4     // m/s over (~30 mph) → severity excess term 1
    static let idleSpeed = 0.5               // m/s
    static let idleMin = 60.0                // s
    static let idleFull = 300.0              // s → severity 1
    static let debounceMerge = 2.0           // s — merge same-kind events this close
    static let debounceMinGap = 5.0          // s — minimum gap between same-kind event starts

    // Step 5.2 — following distance
    static let tailgateHeadway = 1.0         // s
    static let closeHeadway = 2.0            // s
    static let tailgateSustain = 3.0         // s
    static let tailgateMinSpeed = 5.0        // m/s — headway is meaningless in crawling traffic
    static let tailgateFullHeadway = 0.4     // s → severity 1
    static let vehicleRealWidth = 1.8        // m

    // Step 3 — efficiency
    static let brakingIntervalA = -0.5       // m/s² — drag + engine braking below this isn't waste
    static let highSpeed = 29.0              // m/s ≈ 65 mph
    static let accelWasteA = 1.5             // m/s²

    // Step 2.3 — speed-limit matching
    static let wayMatchRadius = 25.0         // m
    static let wayHeadingTolerance = 45.0    // degrees

    // Step 7.1 — hazard map k-anonymity
    static let hazardCell = 0.0005           // degrees ≈ 55 m at this latitude
    static let kEvents = 5
    static let kUsers = 3
}
