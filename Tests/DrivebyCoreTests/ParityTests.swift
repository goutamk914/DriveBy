import XCTest
@testable import DrivebyCore

final class ParityTests: XCTestCase {

    private func fixtureURL(_ path: String) throws -> URL {
        let base = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return base.appendingPathComponent(path)
    }

    private func json(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: fixtureURL(path))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? Double) }

    private func runSwift(_ name: String, withLimits: Bool = true) throws -> DriveAnalysis {
        let log = SensorLogParser.parse(try Data(contentsOf: fixtureURL("\(name)/sensors.jsonl")))
        let ways = SpeedLimits.parseOverpass(try Data(contentsOf: fixtureURL("\(name)/overpass.json")))
        XCTAssertEqual(ways.count, 3)
        let plan = try DriveAnalyzer.plan(log: log)
        return DriveAnalyzer.analyze(plan: plan, log: log, vehicle: VehicleParams(), ways: withLimits ? ways : nil)
    }

    func testSynthDriveMatchesPython() throws { try compare("synth_drive") }
    func testSynthDriveWithoutYawFieldMatchesPython() throws { try compare("synth_drive_noyaw") }

    private func compare(_ name: String) throws {
        let expected = try json("\(name)/expected.json")
        let a = try runSwift(name)

        XCTAssertEqual(a.malformedLines, 1, "half-written last line must be skipped, not fatal")
        XCTAssertEqual(a.tripStartT, try XCTUnwrap(num(expected["trip_start_t"])), accuracy: 1e-6)
        XCTAssertEqual(a.tripEndT, try XCTUnwrap(num(expected["trip_end_t"])), accuracy: 1e-6)
        XCTAssertEqual(a.distanceM, try XCTUnwrap(num(expected["distance_m"])), accuracy: 0.5)
        XCTAssertEqual(a.durationS, try XCTUnwrap(num(expected["duration_s"])), accuracy: 1e-6)

        let comps = try XCTUnwrap(expected["components"] as? [String: Any])
        for key in EfficiencyComponents.keys {
            let e = try XCTUnwrap(num(comps[key]), key)
            XCTAssertEqual(a.components[key], e, accuracy: max(abs(e) * 1e-4, 1e-6), key)
        }
        let eff = ScoringModel().efficiencyScore(a.components)
        XCTAssertEqual(eff, try XCTUnwrap(num(expected["efficiency_score_default_model"])), accuracy: 0.01)

        let safety = try XCTUnwrap(expected["safety"] as? [String: Any])
        XCTAssertEqual(a.safety.score, try XCTUnwrap(num(safety["score"])), accuracy: 0.01)
        XCTAssertEqual(a.safety.speedingFraction, try XCTUnwrap(num(safety["speeding_fraction"])), accuracy: 1e-6)

        let evs = try XCTUnwrap(expected["events"] as? [[String: Any]])
        XCTAssertEqual(a.events.count, evs.count, "event count")
        for (mine, theirs) in zip(a.events, evs) {
            XCTAssertEqual(mine.kind.rawValue, theirs["kind"] as? String)
            XCTAssertEqual(mine.tOffsetS, try XCTUnwrap(num(theirs["t_offset_s"])), accuracy: 1e-6)
            XCTAssertEqual(mine.tEndS, try XCTUnwrap(num(theirs["t_end_s"])), accuracy: 1e-6)
            XCTAssertEqual(mine.tPeakS, try XCTUnwrap(num(theirs["t_peak_s"])), accuracy: 1e-6)
            XCTAssertEqual(mine.severity, try XCTUnwrap(num(theirs["severity"])), accuracy: 1e-6)
            let d = try XCTUnwrap(theirs["detail"] as? [String: Any])
            XCTAssertEqual(mine.detail.road, d["road"] as? String, "road for \(mine.kind)")
            if let v = num(d["v_start_mps"]) { XCTAssertEqual(mine.detail.vStartMps ?? .nan, v, accuracy: 1e-6) }
            if let v = num(d["energy_j"]) { XCTAssertEqual(mine.detail.energyJ ?? .nan, v, accuracy: 0.5) }
            if let v = num(d["headway_s"]) { XCTAssertEqual(mine.detail.headwayS ?? .nan, v, accuracy: 1e-6) }
        }

        let noLimits = try runSwift(name, withLimits: false)
        let expectedNoLimits = try XCTUnwrap(expected["no_limits"] as? [[String: Any]])
        XCTAssertEqual(noLimits.events.map(\.kind.rawValue), expectedNoLimits.compactMap { $0["kind"] as? String })
        XCTAssertFalse(noLimits.speedLimitsAvailable)

        XCTAssertEqual(a.obdFuelGal ?? .nan, try XCTUnwrap(num(expected["obd_fuel_gal"])), accuracy: 1e-9)
        XCTAssertEqual(a.obdMethod, expected["obd_method"] as? String)
    }

    func testScriptedManoeuvresAreDetected() throws {
        let a = try runSwift("synth_drive")
        let kinds = a.events.map(\.kind)
        XCTAssertEqual(kinds, [.hardBrake, .idle, .hardAccel, .harshCorner, .speeding, .tailgating])
        let brake = try XCTUnwrap(a.events.first { $0.kind == .hardBrake })
        XCTAssertEqual(brake.detail.road, "Route 7")
        XCTAssertEqual(Units.mph(brake.detail.vStartMps ?? 0), 33.5, accuracy: 1.0)
        let speeding = try XCTUnwrap(a.events.first { $0.kind == .speeding })
        XCTAssertEqual(Units.mph(speeding.detail.limitMps ?? 0), 40, accuracy: 0.01, "untagged secondary → 40 mph default")
        let tail = try XCTUnwrap(a.events.first { $0.kind == .tailgating })
        XCTAssertLessThan(tail.detail.headwayS ?? 9, 1.0)
        XCTAssertTrue(a.tailgatingAvailable)
        XCTAssertEqual(a.speedLimitCoverage, 1.0, accuracy: 0.001)
    }

    func testAnalysisRoundTripsThroughJSON() throws {
        let a = try runSwift("synth_drive")
        let data = try DriveAnalysis.encoder.encode(a)
        let back = try DriveAnalysis.decoder.decode(DriveAnalysis.self, from: data)
        XCTAssertEqual(back.events, a.events)
        XCTAssertEqual(back.components, a.components)
        XCTAssertEqual(back.trace.count, a.trace.count)
    }

    func testCopyForEveryEventIsPlainEnglish() throws {
        let a = try runSwift("synth_drive")
        for e in a.events {
            let c = EventCopywriter.copy(for: e, tripStartT: a.tripStartT, pricePerGallon: 3.40)
            XCTAssertTrue(c.headline.contains("into your drive"), c.headline)
            XCTAssertFalse(c.body.contains("severity"))
            XCTAssertFalse(c.body.isEmpty)
        }
        let brake = try XCTUnwrap(a.events.first { $0.kind == .hardBrake })
        let c = EventCopywriter.copy(for: brake, tripStartT: a.tripStartT, pricePerGallon: 3.40)
        XCTAssertTrue(c.headline.hasPrefix("Hard braking — 0:59 into your drive"), c.headline)
        XCTAssertTrue(c.body.hasPrefix("You slowed from 33 to 0 mph"), c.body)
        XCTAssertTrue(c.body.contains("on Route 7"), c.body)
        XCTAssertTrue(c.body.contains("¢"), c.body)
    }
}
