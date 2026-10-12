//  LiveCoachTests.swift — the real-time voice coach: thresholds, rate limiting, mode differences,
//  and the single-point speed-limit lookup it relies on.

import XCTest
@testable import DrivebyCore

final class LiveCoachTests: XCTestCase {

    // MARK: Braking / acceleration (GPS speed, 1 Hz)

    func testHardBrakeIsCalledOut() {
        var coach = LiveCoach(mode: .regular)
        XCTAssertNil(coach.speed(t: 0, v: 20, limitMps: nil))
        let cue = coach.speed(t: 1, v: 16, limitMps: nil)          // −4 m/s² < −3.0
        XCTAssertEqual(cue?.cue, .hardBrake)
    }

    func testGentleSlowDownIsQuiet() {
        var coach = LiveCoach(mode: .regular)
        var cues: [LiveCueEvent] = []
        for (i, v) in [20.0, 18.5, 17.0, 15.5, 14.0].enumerated() {
            if let c = coach.speed(t: Double(i), v: v, limitMps: nil) { cues.append(c) }
        }
        XCTAssertTrue(cues.isEmpty)
    }

    func testHardAccelerationIsCalledOut() {
        var coach = LiveCoach(mode: .regular)
        _ = coach.speed(t: 0, v: 2, limitMps: nil)
        XCTAssertEqual(coach.speed(t: 1, v: 5, limitMps: nil)?.cue, .hardAccel)   // +3 m/s² > 2.5
    }

    func testStaleGPSGapIsNotTreatedAsAcceleration() {
        var coach = LiveCoach(mode: .regular)
        _ = coach.speed(t: 0, v: 20, limitMps: nil)
        XCTAssertNil(coach.speed(t: 10, v: 0, limitMps: nil), "a 10 s gap (tunnel) must not look like a hard brake")
    }

    // MARK: Rate limiting

    func testSameCueDoesNotRepeatWithinRepeatGap() {
        var coach = LiveCoach(mode: .regular)
        _ = coach.speed(t: 0, v: 20, limitMps: nil)
        XCTAssertEqual(coach.speed(t: 1, v: 16, limitMps: nil)?.cue, .hardBrake)
        _ = coach.speed(t: 20, v: 20, limitMps: nil)
        XCTAssertNil(coach.speed(t: 21, v: 16, limitMps: nil), "20 s later is inside the repeat gap")
        _ = coach.speed(t: 60, v: 20, limitMps: nil)
        XCTAssertEqual(coach.speed(t: 61, v: 16, limitMps: nil)?.cue, .hardBrake)
    }

    func testAnyTwoCuesAreSpacedOut() {
        var coach = LiveCoach(mode: .regular)
        _ = coach.speed(t: 0, v: 20, limitMps: nil)
        XCTAssertNotNil(coach.speed(t: 1, v: 16, limitMps: nil))
        // A sharp turn right after: suppressed by the global gap.
        XCTAssertNil(coach.yaw(t: 2, yawRate: 0.5, v: 10))
        XCTAssertNil(coach.yaw(t: 2.6, yawRate: 0.5, v: 10))
    }

    // MARK: Speeding

    func testSpeedingNeedsToBeSustained() {
        var coach = LiveCoach(mode: .regular)
        let limit = 35 / Units.mpsToMph
        let over = limit + Thresholds.speedingMargin + 1
        XCTAssertNil(coach.speed(t: 0, v: over, limitMps: limit))
        XCTAssertNil(coach.speed(t: 3, v: over, limitMps: limit))
        let cue = coach.speed(t: 5, v: over, limitMps: limit)
        XCTAssertEqual(cue?.cue, .speeding)
        XCTAssertEqual(cue?.limitMph, 35)
    }

    func testDroppingBelowTheLimitResetsSpeeding() {
        var coach = LiveCoach(mode: .regular)
        let limit = 25 / Units.mpsToMph
        let over = limit + Thresholds.speedingMargin + 1
        // Fixes 4 s apart (beyond maxFixGap) so the speed changes aren't read as acceleration.
        _ = coach.speed(t: 0, v: over, limitMps: limit)
        _ = coach.speed(t: 4, v: limit, limitMps: limit)
        XCTAssertNil(coach.speed(t: 8, v: over, limitMps: limit))
        XCTAssertNil(coach.speed(t: 12, v: over, limitMps: limit))
        XCTAssertEqual(coach.speed(t: 13, v: over, limitMps: limit)?.cue, .speeding)
    }

    func testLimitIsRoundedToAPostedValue() {
        var coach = LiveCoach(mode: .regular)
        let limit = 56 / 3.6     // OSM "56" (km/h) ≈ 34.8 mph → posted 35
        let over = limit + Thresholds.speedingMargin + 1
        _ = coach.speed(t: 0, v: over, limitMps: limit)
        XCTAssertEqual(coach.speed(t: 5, v: over, limitMps: limit)?.limitMph, 35)
    }

    // MARK: Cornering (yaw × speed)

    func testSharpTurnNeedsHalfASecond() {
        var coach = LiveCoach(mode: .regular)
        XCTAssertNil(coach.yaw(t: 0, yawRate: 0.4, v: 10))          // 4 m/s² lateral
        XCTAssertNil(coach.yaw(t: 0.3, yawRate: 0.4, v: 10))
        XCTAssertEqual(coach.yaw(t: 0.5, yawRate: -0.4, v: 10)?.cue, .sharpTurn)
    }

    func testSlowTightTurnIsFine() {
        var coach = LiveCoach(mode: .regular)
        for i in 0..<10 { XCTAssertNil(coach.yaw(t: Double(i) * 0.1, yawRate: 0.5, v: 4)) }   // 2 m/s²
    }

    // MARK: Following distance (camera)

    func testTailgatingNeedsThreeSeconds() {
        var coach = LiveCoach(mode: .regular)
        XCTAssertNil(coach.headway(t: 0, leadDistance: 10, v: 20))   // 0.5 s headway
        XCTAssertNil(coach.headway(t: 2, leadDistance: 10, v: 20))
        XCTAssertEqual(coach.headway(t: 3, leadDistance: 10, v: 20)?.cue, .tailgating)
    }

    func testLosingTheLeadCarResetsTailgating() {
        var coach = LiveCoach(mode: .regular)
        _ = coach.headway(t: 0, leadDistance: 10, v: 20)
        _ = coach.headway(t: 2, leadDistance: nil, v: 20)
        XCTAssertNil(coach.headway(t: 3, leadDistance: 10, v: 20))
    }

    func testCrawlingTrafficIsNotTailgating() {
        var coach = LiveCoach(mode: .regular)
        for i in 0...5 { XCTAssertNil(coach.headway(t: Double(i), leadDistance: 2, v: 3)) }
    }

    // MARK: Positive feedback — new drivers only

    private func smoothStop(_ coach: inout LiveCoach, from t0: Double = 0) -> [LiveCueEvent] {
        var out: [LiveCueEvent] = []
        for (i, v) in [12.0, 10.5, 9.0, 7.5, 6.0, 4.5, 3.0, 1.5, 0.3].enumerated() {
            if let c = coach.speed(t: t0 + Double(i), v: v, limitMps: nil) { out.append(c) }
        }
        return out
    }

    func testNewDriverHearsSmoothStop() {
        var coach = LiveCoach(mode: .newDriver)
        XCTAssertEqual(smoothStop(&coach).map(\.cue), [.smoothStop])
    }

    func testRegularDriverIsNotPraised() {
        var coach = LiveCoach(mode: .regular)
        XCTAssertTrue(smoothStop(&coach).isEmpty)
    }

    func testHardStopIsNotPraised() {
        var coach = LiveCoach(mode: .newDriver)
        let cues = [14.0, 10.0, 6.0, 3.0, 0.3].enumerated().compactMap { i, v in coach.speed(t: Double(i), v: v, limitMps: nil) }
        XCTAssertEqual(cues.map(\.cue), [.hardBrake])
    }

    func testHardFinalStepIsNotPraised() {
        // Gentle until the last second, then −2.5 m/s² (harder than "smooth") into the stop.
        var coach = LiveCoach(mode: .newDriver)
        let cues = [10.0, 8.5, 7.0, 5.5, 4.0, 2.9, 0.4].enumerated().compactMap { i, v in coach.speed(t: Double(i), v: v, limitMps: nil) }
        XCTAssertTrue(cues.isEmpty)
    }

    func testOldHardBrakeDoesNotSpoilALaterSmoothStop() {
        var coach = LiveCoach(mode: .newDriver)
        _ = coach.speed(t: 0, v: 16, limitMps: nil)
        _ = coach.speed(t: 1, v: 12, limitMps: nil)                  // hard brake, then cruise at 12 m/s
        for t in 2...61 { _ = coach.speed(t: Double(t), v: 12, limitMps: nil) }
        XCTAssertEqual(smoothStop(&coach, from: 62).map(\.cue), [.smoothStop])
    }

    // MARK: Estimated (untagged) limits

    func testEstimatedLimitIsNotAnnouncedAsPosted() {
        var coach = LiveCoach(mode: .regular)
        let limit = 25 / Units.mpsToMph
        let over = limit + Thresholds.speedingMargin + 1
        _ = coach.speed(t: 0, v: over, limitMps: limit, posted: false)
        let cue = coach.speed(t: 5, v: over, limitMps: limit, posted: false)
        XCTAssertEqual(cue?.cue, .speeding)
        XCTAssertNil(cue?.limitMph, "a highway-type default isn't a posted limit — say \"Watch your speed\" instead")
        XCTAssertEqual(LiveCue.speeding.phrase(mode: .regular, limitMph: cue?.limitMph), "Watch your speed.")
    }

    // MARK: Camera interruptions

    func testCameraGapResetsTailgating() {
        var coach = LiveCoach(mode: .regular)
        _ = coach.headway(t: 0, leadDistance: 10, v: 20)
        // Camera interrupted for 10 s, then a close car again: the 3 s must start over.
        XCTAssertNil(coach.headway(t: 10, leadDistance: 10, v: 20))
        XCTAssertNil(coach.headway(t: 12, leadDistance: 10, v: 20))
        XCTAssertEqual(coach.headway(t: 13, leadDistance: 10, v: 20)?.cue, .tailgating)
    }

    // MARK: Phrases

    func testPhrasesDifferByMode() {
        XCTAssertNotEqual(LiveCue.hardBrake.phrase(mode: .regular, limitMph: nil),
                          LiveCue.hardBrake.phrase(mode: .newDriver, limitMph: nil))
        XCTAssertTrue(LiveCue.speeding.phrase(mode: .regular, limitMph: 45).contains("45"))
        XCTAssertFalse(LiveCue.speeding.phrase(mode: .regular, limitMph: nil).isEmpty)
        for cue in LiveCue.allCases {
            XCTAssertFalse(cue.shortText(limitMph: 30).isEmpty)
        }
    }

    // MARK: Single-point speed-limit lookup (live)

    private func northSouthRoad() -> OSMWay {
        OSMWay(id: 7, highway: "residential", maxspeed: "25 mph", name: "Oak Ave", ref: nil, oneway: nil,
               geometry: [[38.9000, -77.3000], [38.9100, -77.3000]])
    }

    func testRoadIndexMatchesNearbyRoad() {
        let index = SpeedLimits.RoadIndex(ways: [northSouthRoad()], lat0: 38.905, lon0: -77.3)
        let m = index.match(lat: 38.905, lon: -77.30005, heading: 0, speed: 10)
        XCTAssertEqual(m.wayId, 7)
        XCTAssertEqual(m.road, "Oak Ave")
        XCTAssertEqual(try XCTUnwrap(m.limitMps) * Units.mpsToMph, 25, accuracy: 0.01)
    }

    func testRoadIndexRejectsCrossingTraffic() {
        let index = SpeedLimits.RoadIndex(ways: [northSouthRoad()], lat0: 38.905, lon0: -77.3)
        XCTAssertNil(index.match(lat: 38.905, lon: -77.30005, heading: 90, speed: 10).wayId)
        XCTAssertEqual(index.match(lat: 38.905, lon: -77.30005, heading: 90, speed: 0.5).wayId, 7,
                       "heading is ignored when nearly stopped")
    }

    func testRoadIndexIgnoresFarRoads() {
        let index = SpeedLimits.RoadIndex(ways: [northSouthRoad()], lat0: 38.905, lon0: -77.3)
        XCTAssertNil(index.match(lat: 38.905, lon: -77.301, heading: 0, speed: 10).wayId)   // ≈ 87 m away
    }
}
