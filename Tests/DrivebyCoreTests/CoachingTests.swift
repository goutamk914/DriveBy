//  CoachingTests.swift — skills, stop signs, moments, practice plan, sunset maths, hours log.

import XCTest
@testable import DrivebyCore

final class CoachingTests: XCTestCase {

    private func fixture(_ path: String) throws -> Data {
        let base = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return try Data(contentsOf: base.appendingPathComponent(path))
    }

    /// The synthetic drive + its ways, with node ids added so stop signs can be tied to roads.
    private func scenario() throws -> (DriveAnalyzer.Plan, SensorLog, [OSMWay]) {
        let log = SensorLogParser.parse(try fixture("synth_drive/sensors.jsonl"))
        var ways = SpeedLimits.parseOverpass(try fixture("synth_drive/overpass.json"))
        for i in ways.indices { ways[i].nodeIds = [Int64(ways[i].id * 10), Int64(ways[i].id * 10 + 1)] }
        return (try DriveAnalyzer.plan(log: log), log, ways)
    }

    func testStopSignOutcomes() throws {
        let (plan, log, ways) = try scenario()
        let s = plan.tripSeries
        // Where the car came to rest at the first stop (on Route 7, way 101), and a point it blew through on way 102.
        let stopIdx = s.v.firstIndex { $0 < 0.3 }!
        let fastIdx = s.v.indices.first { s.v[$0] > 30 && s.t[$0] > 230 }!
        let stopSign = OSMControl(id: 1010, lat: s.lat[stopIdx], lon: s.lon[stopIdx], kind: .stop, allWay: false, wayIds: [101])
        let missed = OSMControl(id: 1020, lat: s.lat[fastIdx], lon: s.lon[fastIdx], kind: .stop, allWay: false, wayIds: [102])
        // A stop node shared by two roads (junction) is ambiguous → ignored.
        let ambiguous = OSMControl(id: 1021, lat: s.lat[fastIdx], lon: s.lon[fastIdx], kind: .stop, allWay: false, wayIds: [101, 102])
        // A stop sign on a road we are NOT on (cross street) → ignored even though we pass right by it.
        let crossStreet = OSMControl(id: 1030, lat: s.lat[fastIdx], lon: s.lon[fastIdx], kind: .stop, allWay: false, wayIds: [103])

        let a = DriveAnalyzer.analyze(plan: plan, log: log, vehicle: VehicleParams(), ways: ways,
                                      controls: [stopSign, missed, ambiguous, crossStreet])
        let passes = try XCTUnwrap(a.stopSigns)
        XCTAssertEqual(passes.map(\.nodeId), [1010, 1020])
        XCTAssertEqual(passes[0].outcome, .fullStop)
        XCTAssertEqual(passes[0].road, "Route 7")
        XCTAssertEqual(passes[1].outcome, .missed)

        let skills = try XCTUnwrap(a.skills)
        XCTAssertEqual(skills[.stopSigns].good, 1)
        XCTAssertEqual(skills[.stopSigns].total, 2)
        XCTAssertNil(skills.percent(.stopSigns), "2 stop signs is not enough evidence to show a percentage")

        let moments = a.moments(pricePerGallon: 3.4)
        XCTAssertTrue(moments.contains { $0.kind == .goodStop && $0.headline.contains("stop sign") })
        let flagged = try XCTUnwrap(moments.first { $0.kind == .missedStop })
        XCTAssertTrue(flagged.body.contains("map data can be wrong"), "a missed stop is flagged for review, not a verdict")
        XCTAssertTrue(flagged.isSignificant)
        XCTAssertEqual(moments.map(\.t), moments.map(\.t).sorted())
        // every scored event appears exactly once in the timeline
        XCTAssertEqual(moments.filter { $0.eventId != nil }.count, a.events.count)
    }

    func testSkillsOnScriptedDrive() throws {
        let (plan, log, ways) = try scenario()
        let a = DriveAnalyzer.analyze(plan: plan, log: log, vehicle: VehicleParams(), ways: ways)
        let skills = try XCTUnwrap(a.skills)
        // Slow-downs: the hard stop (not smooth) + two gentle −1.0 m/s² decelerations (smooth).
        XCTAssertEqual(skills[.smoothBraking].total, 3)
        XCTAssertEqual(skills[.smoothBraking].good, 2)
        XCTAssertEqual(skills.percent(.smoothBraking) ?? 0, 66.67, accuracy: 0.01)
        // Speed-ups: gentle start, hard launch, gentle highway build-up.
        XCTAssertEqual(skills[.smoothAcceleration].good, 2)
        XCTAssertEqual(skills[.smoothAcceleration].total, 3)
        // One sharp 90° turn — counted, not smooth, not enough turns for a percentage yet.
        XCTAssertEqual(skills[.turns].total, 1)
        XCTAssertEqual(skills[.turns].good, 0)
        XCTAssertNil(skills.percent(.turns))
        // Speed control: the 73 mph stretch on a 40 mph road pulls this well below 100%.
        let speed = try XCTUnwrap(skills.percent(.speedControl))
        XCTAssertLessThan(speed, 75)
        XCTAssertGreaterThan(speed, 30)
        // Following distance: the only lead-vehicle stretch is a ~0.6 s tailgate.
        XCTAssertEqual(skills[.followingDistance].good, 0)
        // Positive highlights exist (a gentle stop to park).
        XCTAssertTrue((a.highlights ?? []).contains { $0.isPositive })
    }

    func testSkillReportsCombineAcrossDrives() {
        var a = SkillReport(); a.stats[Skill.turns.rawValue] = SkillStat(good: 2, total: 2)
        var b = SkillReport(); b.stats[Skill.turns.rawValue] = SkillStat(good: 1, total: 2)
        let c = SkillReport.combine([a, b])
        XCTAssertEqual(c.percent(.turns) ?? 0, 75, accuracy: 1e-9)
    }

    func testPracticePlanPicksWeakestSkill() {
        var r = SkillReport()
        r.stats[Skill.smoothBraking.rawValue] = SkillStat(good: 6, total: 10)   // 60 %
        r.stats[Skill.turns.rawValue] = SkillStat(good: 9, total: 10)           // 90 % — fine
        r.stats[Skill.stopSigns.rawValue] = SkillStat(good: 3, total: 4)        // 75 %
        let plan = PracticePlanner.plan(skills: r, nightHoursRemaining: nil)
        XCTAssertEqual(plan.map(\.skill), [.smoothBraking, .stopSigns])
        XCTAssertFalse(plan[0].steps.isEmpty)
        let withNight = PracticePlanner.plan(skills: SkillReport(), nightHoursRemaining: 9)
        XCTAssertEqual(withNight.first?.title, "Practise after sunset")
    }

    func testSunsetMatchesReferenceAlgorithm() throws {
        // Reference values from the `astral` Python package.
        let utc = ISO8601DateFormatter()
        let leesburg = try XCTUnwrap(Solar.sunriseSunset(on: utc.date(from: "2026-10-04T12:00:00Z")!, lat: 39.115, lon: -77.564))
        XCTAssertEqual(leesburg.sunrise.timeIntervalSince(utc.date(from: "2026-10-04T11:09:25Z")!), 0, accuracy: 45)
        XCTAssertEqual(leesburg.sunset.timeIntervalSince(utc.date(from: "2026-10-04T22:47:48Z")!), 0, accuracy: 45)
        let dcWinter = try XCTUnwrap(Solar.sunriseSunset(on: utc.date(from: "2026-12-21T12:00:00Z")!, lat: 38.9072, lon: -77.0369))
        XCTAssertEqual(dcWinter.sunset.timeIntervalSince(utc.date(from: "2026-12-21T21:49:12Z")!), 0, accuracy: 45)
    }

    func testNightSplitAroundSunset() {
        let utc = ISO8601DateFormatter()
        // 6:30–7:30 pm EDT in Leesburg on Oct 4: sunset 6:47:48 pm → ~42 min of night.
        let start = utc.date(from: "2026-10-04T22:30:00Z")!, end = utc.date(from: "2026-10-04T23:30:00Z")!
        let night = Solar.nightSeconds(from: start, to: end, lat: 39.115, lon: -77.564)
        XCTAssertEqual(night / 60, 42, accuracy: 2)
        // A noon drive has no night time; a 2 am drive is all night.
        XCTAssertEqual(Solar.nightSeconds(from: utc.date(from: "2026-10-04T16:00:00Z")!, to: utc.date(from: "2026-10-04T17:00:00Z")!,
                                          lat: 39.115, lon: -77.564), 0)
        XCTAssertEqual(Solar.nightSeconds(from: utc.date(from: "2026-10-05T06:00:00Z")!, to: utc.date(from: "2026-10-05T06:30:00Z")!,
                                          lat: 39.115, lon: -77.564), 1800)
    }

    func testHoursSummary() {
        let e = [PracticeLogEntry(startedAt: Date(), durationS: 3600 * 10, nightS: 3600 * 4, supervisor: "Mom"),
                 PracticeLogEntry(startedAt: Date(), durationS: 1800, nightS: 0, supervisor: "Dad", manual: true)]
        let h = HoursSummary(entries: e, requirement: HoursRequirement())
        XCTAssertEqual(h.totalHours, 10.5, accuracy: 1e-9)
        XCTAssertEqual(h.totalRemaining, 34.5, accuracy: 1e-9)
        XCTAssertEqual(h.nightRemaining, 11, accuracy: 1e-9)
        XCTAssertFalse(h.complete)
        XCTAssertEqual(HoursSummary.hoursString(5400), "1h 30m")
        let csv = PracticeLogCSV.csv(e)
        XCTAssertTrue(csv.hasPrefix("date,duration_min,night_min,supervisor,source,notes\n"))
        XCTAssertTrue(csv.contains("\"Dad\",manual"))
        let quoted = PracticeLogCSV.csv([PracticeLogEntry(startedAt: Date(timeIntervalSince1970: 0), durationS: 600, nightS: 0,
                                                          supervisor: "Sam \"Coach\" Lee", notes: "line1\nline2")])
        XCTAssertTrue(quoted.contains("\"Sam \"\"Coach\"\" Lee\""))
        XCTAssertTrue(quoted.contains("\"line1 line2\""))
    }

    func testOverpassControlsParsing() {
        let json = """
        {"elements":[
          {"type":"way","id":5,"nodes":[1,2,3],"tags":{"highway":"residential"},"geometry":[{"lat":39.0,"lon":-77.0},{"lat":39.001,"lon":-77.0},{"lat":39.002,"lon":-77.0}]},
          {"type":"node","id":2,"lat":39.001,"lon":-77.0,"tags":{"highway":"stop","stop":"all"}},
          {"type":"node","id":9,"lat":39.003,"lon":-77.0,"tags":{"highway":"traffic_signals"}}
        ]}
        """
        let data = Data(json.utf8)
        let ways = SpeedLimits.parseOverpass(data)
        XCTAssertEqual(ways.first?.nodeIds, [1, 2, 3])
        let c = SpeedLimits.parseControls(data, ways: ways)
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c[0].kind, .stop)
        XCTAssertTrue(c[0].allWay)
        XCTAssertEqual(c[0].wayIds, [5])
        XCTAssertEqual(c[1].kind, .trafficSignals)
        XCTAssertTrue(SpeedLimits.overpassQuery(for: .init(x: 1, y: 1)).contains("node[\"highway\"~\"^(stop|traffic_signals)$\"]"))
    }

    func testAnalysisV2StillDecodes() throws {
        // analysis.json written by the Python processor (no coaching fields) must still load in the app.
        let (plan, log, ways) = try scenario()
        var a = DriveAnalyzer.analyze(plan: plan, log: log, vehicle: VehicleParams(), ways: ways)
        a.skills = nil; a.highlights = nil; a.stopSigns = nil
        let back = try DriveAnalysis.decoder.decode(DriveAnalysis.self, from: DriveAnalysis.encoder.encode(a))
        XCTAssertNil(back.skills)
        XCTAssertEqual(back.moments(pricePerGallon: 3).count, a.events.count)
    }
}
