//  CoreTests.swift — unit tests for numerics, hazard k-anonymity, validation, OBD parsing, trips.

import XCTest
@testable import DrivebyCore

final class NumericsTests: XCTestCase {
    private var ref: [String: Any] = [:]

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil)).appendingPathComponent("numerics.json")
        ref = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func arr(_ k: String) -> [Double] { (ref[k] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.doubleValue ?? ($0 as? Double) } }
    private func val(_ k: String) -> Double { (ref[k] as? NSNumber)?.doubleValue ?? (ref[k] as? Double) ?? .nan }

    func testSavgolMatchesScipy() {
        let out = Numerics.savgol(arr("y"), window: 21, order: 3)
        for (a, b) in zip(out, arr("savgol_21_3")) { XCTAssertEqual(a, b, accuracy: 1e-9) }
        let short = Numerics.savgol(arr("short"), window: 21, order: 3)   // shrinks to 9 like the Python wrapper
        for (a, b) in zip(short, arr("savgol_short")) { XCTAssertEqual(a, b, accuracy: 1e-9) }
    }

    func testGradientMatchesNumpy() {
        for (a, b) in zip(Numerics.gradient(arr("y"), dt: 0.1), arr("gradient")) { XCTAssertEqual(a, b, accuracy: 1e-9) }
    }

    func testPercentileMatchesNumpy() {
        XCTAssertEqual(Numerics.percentile(arr("percentile_in"), 5), val("p5"), accuracy: 1e-12)
        XCTAssertEqual(Numerics.percentile(arr("percentile_in"), 95), val("p95"), accuracy: 1e-12)
        XCTAssertEqual(Numerics.percentile(arr("percentile_in"), 50), val("p50"), accuracy: 1e-12)
    }

    func testLinregressMatchesScipy() throws {
        let fit = try XCTUnwrap(Numerics.linearFit(x: arr("lr_x"), y: arr("lr_y")))
        XCTAssertEqual(fit.slope, val("lr_slope"), accuracy: 1e-9)
        XCTAssertEqual(fit.intercept, val("lr_intercept"), accuracy: 1e-9)
        XCTAssertEqual(fit.r, val("lr_r"), accuracy: 1e-9)
    }

    func testCellKeysMatchPythonRounding() {
        for item in ref["cell_keys"] as? [[String: Any]] ?? [] {
            let lat = (item["lat"] as? NSNumber)?.doubleValue ?? 0, lon = (item["lon"] as? NSNumber)?.doubleValue ?? 0
            XCTAssertEqual(HazardGrid.cellKey(lat: lat, lon: lon), item["key"] as? String)
        }
    }

    func testMaxspeedParsingMatchesPython() {
        for (raw, expected) in ref["maxspeed"] as? [String: Any] ?? [:] {
            let mine = SpeedLimits.parseMaxspeed(raw)
            if let e = (expected as? NSNumber)?.doubleValue { XCTAssertEqual(mine ?? .nan, e, accuracy: 1e-12, raw) }
            else { XCTAssertNil(mine, raw) }
        }
    }

    func testRidgeRecoversKnownCoefficients() throws {
        let X: [[Double]] = (0..<40).map { i in [Double(i % 7) / 7, Double((i * 3) % 11) / 11] }
        let y = X.map { 1.0 - 0.5 * $0[0] - 0.25 * $0[1] }
        let fit = try XCTUnwrap(Numerics.ridge(X: X, y: y, lambda: 0))
        XCTAssertEqual(fit.coef[0], -0.5, accuracy: 1e-9)
        XCTAssertEqual(fit.coef[1], -0.25, accuracy: 1e-9)
        XCTAssertEqual(fit.intercept, 1.0, accuracy: 1e-9)
    }
}

final class HazardTests: XCTestCase {
    func testKAnonymityRequiresBothThresholds() {
        let base = (lat: 39.04512, lon: -77.48731)
        func c(_ user: String, _ n: Int) -> [HazardAggregator.Contribution] {
            (0..<n).map { _ in .init(lat: base.lat + 0.00001, lon: base.lon, kind: .hardBrake, driveId: UUID(), userKey: user) }
        }
        // 9 events from 2 drivers → NOT published (k_users = 3)
        XCTAssertTrue(HazardAggregator.publish(c("a", 5) + c("b", 4)).isEmpty)
        // 4 events from 4 drivers → NOT published (k_events = 5)
        XCTAssertTrue(HazardAggregator.publish(c("a", 1) + c("b", 1) + c("c", 1) + c("d", 1)).isEmpty)
        // 7 events from 3 drivers → published, counts only
        let cells = HazardAggregator.publish(c("a", 3) + c("b", 2) + c("c", 2))
        XCTAssertEqual(cells.count, 1)
        XCTAssertEqual(cells[0].eventCount, 7)
        XCTAssertEqual(cells[0].distinctUsers, 3)
        XCTAssertEqual(cells[0].summary, "This intersection: 7 hard-braking events from 3 drivers")
        // speeding / idle never enter the public map
        let other = (0..<10).map { i in HazardAggregator.Contribution(lat: base.lat, lon: base.lon, kind: .speeding, driveId: UUID(), userKey: "u\(i)") }
        XCTAssertTrue(HazardAggregator.publish(other).isEmpty)
    }

    func testGeoJSONHasNoIdentifiers() throws {
        let cells = [HazardCell(cellKey: "39.0450_-77.4875", lat: 39.045, lon: -77.4875, eventCount: 7, distinctUsers: 3,
                                dominantKind: "hard_brake", updatedAt: Date(timeIntervalSince1970: 1_790_000_000))]
        let data = GeoJSON.hazardFeatureCollection(cells)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["type"] as? String, "FeatureCollection")
        let f = try XCTUnwrap((root["features"] as? [[String: Any]])?.first)
        let props = try XCTUnwrap(f["properties"] as? [String: Any])
        XCTAssertEqual(Set(props.keys), ["cell_key", "center_lat", "center_lon", "event_count", "distinct_users", "dominant_kind", "updated_at"])
        let ring = try XCTUnwrap(((f["geometry"] as? [String: Any])?["coordinates"] as? [[[Double]]])?.first)
        XCTAssertEqual(ring.count, 5)
        XCTAssertEqual(ring.first, ring.last)
    }
}

final class ValidationTests: XCTestCase {
    private func date(_ d: Int) -> Date { Date(timeIntervalSince1970: 1_788_000_000 + Double(d) * 86_400) }

    func testTankToTankWithPartialFill() {
        let v = UUID()
        let logs = [
            FuelLog(vehicleId: v, loggedAt: date(0), odometerMi: 1000, gallons: 10),
            FuelLog(vehicleId: v, loggedAt: date(5), odometerMi: 1150, gallons: 4, filledToFull: false),
            FuelLog(vehicleId: v, loggedAt: date(9), odometerMi: 1300, gallons: 6),
            FuelLog(vehicleId: v, loggedAt: date(14), odometerMi: 1600, gallons: 10),
        ]
        let comps = EfficiencyComponents(brakeWaste: 100_000, idleFrac: 0.1, jerkRMS: 0.4, highSpeed: 0.1, accelWaste: 0.01)
        let drives = [DriveForValidation(id: UUID(), vehicleId: v, startedAt: date(2), miles: 200, components: comps, obdFuelGal: nil)]
        let iv = Validation.tankIntervals(logs: logs, drives: drives, vehicleId: v)
        XCTAssertEqual(iv.count, 2)
        XCTAssertEqual(iv[0].mpg, 300.0 / 10.0, accuracy: 1e-9)   // partial 4 gal + full 6 gal
        XCTAssertEqual(iv[0].coverage, 200.0 / 300.0, accuracy: 1e-9)
        XCTAssertEqual(iv[1].mpg, 30, accuracy: 1e-9)
        XCTAssertNil(iv[1].meanComponents)
    }

    func testFitWeightsRecoversTheComponentThatMatters() throws {
        // Fuel economy driven only by braking waste → fitted weights should concentrate on brake_waste.
        var rows: [(components: EfficiencyComponents, target: Double)] = []
        for i in 0..<12 {
            let bw = 30_000 + Double(i) * 35_000
            let c = EfficiencyComponents(brakeWaste: bw, idleFrac: Double((i * 5) % 7) / 30, jerkRMS: 0.3 + Double((i * 3) % 5) / 10,
                                         highSpeed: 0.1, accelWaste: 0.01)
            rows.append((c, 1.1 - bw / 1_000_000))
        }
        let m = try XCTUnwrap(Validation.fitWeights(rows: rows, base: ScoringModel(), lambda: 0.01))
        XCTAssertGreaterThan(m.weights["brake_waste"] ?? 0, 0.9)
        XCTAssertEqual(m.weights.values.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertGreaterThan(m.fitR2 ?? 0, 0.95)
        XCTAssertTrue(m.source.hasPrefix("fitted:"))
    }

    func testHonestSummaryAlwaysStatesN() {
        var points: [ValidationPoint] = []
        var xs: [Double] = [], ys: [Double] = []
        for i in 0..<9 {
            let x = Double(60 + i)
            let y: Double = 0.9 + Double(i) / 100 + (i % 2 == 0 ? 0.01 : -0.01)
            xs.append(x); ys.append(y)
            points.append(ValidationPoint(id: "\(i)", score: x, target: y, label: "", lowCoverage: false))
        }
        let r = ValidationResult(source: .tank, normalizedByEPA: true, points: points, fit: Numerics.linearFit(x: xs, y: ys))
        XCTAssertTrue(r.honestSummary.hasPrefix("n=9, r²="), r.honestSummary)
    }
}

final class OBDTests: XCTestCase {
    func testDecodesStandardPIDs() {
        XCTAssertEqual(OBDParser.decode(.rpm, raw: "41 0C 1A F8\r\r>"), 1726)
        XCTAssertEqual(OBDParser.decode(.speed, raw: "410D3C\r>"), 60)
        XCTAssertEqual(OBDParser.decode(.maf, raw: "SEARCHING...\r41 10 02 D1\r>") ?? .nan, 7.21, accuracy: 1e-9)
        XCTAssertEqual(OBDParser.decode(.fuelRate, raw: "41 5E 00 52") ?? .nan, 4.1, accuracy: 1e-9)
        XCTAssertNil(OBDParser.decode(.fuelRate, raw: "NO DATA\r>"))
        XCTAssertTrue(OBDParser.isNoData("NO DATA"))
    }

    func testSupportedPIDBitmask() {
        // BE 1F A8 13 → standard example: 01,03,04,05,06,07,0C,0D,0E,0F,10,11,13,15,1C,1F,20
        let s = OBDParser.supportedPIDs("41 00 BE 1F A8 13", base: 0x00)
        XCTAssertTrue(s.isSuperset(of: ["0C", "0D", "10"]))
        XCTAssertFalse(s.contains("5E"))
        XCTAssertTrue(s.contains("20"))
    }
}

final class TripAndContractTests: XCTestCase {
    func testLiveTripDetector() {
        var d = LiveTripDetector()
        var signals: [LiveTripDetector.Signal] = []
        var t = 0.0
        for _ in 0..<15 { signals.append(d.feed(t: t, speed: 5)); t += 1 }
        XCTAssertEqual(signals.filter { $0 == .started }.count, 1)
        for _ in 0..<180 { XCTAssertEqual(d.feed(t: t, speed: 0), .none); t += 1 }  // t = 15…194
        XCTAssertEqual(d.feed(t: t, speed: 0), .parked)
    }

    func testSampleLinesParseBack() {
        let text = [
            SampleLine.gps(t: 12.4, lat: 39.045, lon: -77.487, spd: 18.2, acc: 4, hdg: 271.4),
            SampleLine.imu(t: 12.42, ax: 0.11, ay: -0.03, az: 9.79, gx: 0.001, gy: 0.002, gz: -0.014, yaw: nil),
            SampleLine.gps(t: 13.4, lat: 39.045, lon: -77.487, spd: nil, acc: 4, hdg: nil),
            SampleLine.obd(OBDSample(t: 13, rpm: 1850, kph: 64, maf: 7.21, fuelLph: 4.1)),
            SampleLine.lead(LeadSample(t: 13.033, bx: 0.41, by: 0.48, bw: 0.12, bh: 0.1, dist: 21.4)),
        ].joined(separator: "\n")
        XCTAssertTrue(text.hasPrefix("{\"t\":12.400,\"type\":\"gps\",\"lat\":39.0450000,\"lon\":-77.4870000,\"spd\":18.20"))
        let log = SensorLogParser.parse(Data(text.utf8))
        XCTAssertEqual(log.gps.count, 2)
        XCTAssertNil(log.gps[1].spd)
        XCTAssertEqual(log.imu.first?.az, 9.79)
        XCTAssertEqual(log.obd.first?.fuelLph, 4.1)
        XCTAssertEqual(log.lead.first?.dist, 21.4)
        XCTAssertEqual(log.malformedLines, 0)
    }

    func testSidecarUsesContractKeys() throws {
        let s = DriveSidecar(driveId: "d", videoFile: "drive_0007.mov", sensorFile: "drive_0007.jsonl", videoStartT: 0.83,
                             vehicleId: "v", device: "iPhone 13", startedAt: Date(timeIntervalSince1970: 0))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: DriveSidecar.encoder.encode(s)) as? [String: Any])
        for k in ["drive_id", "video_file", "sensor_file", "video_start_t", "vehicle_id", "device"] { XCTAssertNotNil(obj[k], k) }
    }

    func testShortTripsAreRejected() {
        XCTAssertTrue(TripSegmenter.isTooShort(distance: 400, duration: 300))
        XCTAssertTrue(TripSegmenter.isTooShort(distance: 900, duration: 30))
        XCTAssertFalse(TripSegmenter.isTooShort(distance: 900, duration: 300))
    }

    func testSafetyNormalisesPer10Miles() {
        var s = DriveSeries()
        s.dt = 0.1
        let n = 6000
        s.t = (0..<n).map { Double($0) * 0.1 }
        s.v = [Double](repeating: 26.8, count: n)  // 60 mph for 10 min = 10 miles
        s.distance = (0..<n).map { Double($0) * 2.68 }
        let ev = DriveEvent(kind: .hardBrake, tOffsetS: 10, tEndS: 11, tPeakS: 10.5, severity: 0.5)
        let b = Safety.score(events: [ev], series: s)
        XCTAssertEqual(b.per10MilesFactor, 10 / Units.miles(s.totalDistance), accuracy: 1e-9)
        XCTAssertEqual(b.score, 100 - 12 * 0.5 * b.per10MilesFactor, accuracy: 1e-9)
    }
}

final class ScoringModelInteropTests: XCTestCase {
    /// notebooks/validation.ipynb writes scoring_model.json with processor.scoring.ScoringModel.to_json();
    /// the app must import it unchanged (Settings → Scoring model → Import).
    func testDecodesModelWrittenByPython() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil)).appendingPathComponent("scoring_model_python.json")
        let m = try JSONDecoder().decode(ScoringModel.self, from: Data(contentsOf: url))
        XCTAssertEqual(m.weights["brake_waste"], 0.5)
        XCTAssertEqual(m.source, "fitted:2026-10-01")
        XCTAssertEqual(m.fitN, 9)
        XCTAssertEqual(m.fitR2 ?? 0, 0.71, accuracy: 1e-12)
        XCTAssertEqual(m.normalization["brake_waste"], ScoringModel.Range(p5: 20_000, p95: 450_000))
        XCTAssertEqual(m.safety, SafetyCoefficients())
        // Fitted models are not re-normalised by the corpus.
        XCTAssertEqual(m.withCorpus(Array(repeating: EfficiencyComponents(brakeWaste: 1, idleFrac: 0, jerkRMS: 0, highSpeed: 0, accelWaste: 0), count: 10)), m)
    }
}
