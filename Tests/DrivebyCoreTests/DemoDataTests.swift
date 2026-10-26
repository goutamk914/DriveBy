import XCTest
@testable import DrivebyCore

final class DemoDataTests: XCTestCase {

    private let road = DemoRoad(name: "Ashburn Road", highway: "secondary", mph: 40)
    private let side = DemoRoad(name: "Sweetgrass Way", highway: "residential", mph: 25)
    private let origin = DemoPoint(lat: 39.0294, lon: -77.4943)
    private let metresPerDegree = 111_195.0
    private let now = Date(timeIntervalSince1970: 1_792_800_000)

    private func point(east: Double, north: Double) -> DemoPoint {
        DemoPoint(lat: origin.lat + north / metresPerDegree,
                  lon: origin.lon + east / (metresPerDegree * cos(origin.lat * .pi / 180)))
    }

    private func straight(_ metres: Double, road: DemoRoad, light: Double? = nil) -> DemoRoute {
        let half = metres / 2
        return DemoRoute(points: [point(east: 0, north: 0), point(east: 0, north: half), point(east: 0, north: metres)],
                         segments: [DemoSegment(at: 0, road: road, control: .none),
                                    DemoSegment(at: half, road: road, control: light == nil ? .none : .light)])
    }

    private func corner(first: Double, then: Double, control: DemoControl) -> DemoRoute {
        DemoRoute(points: [point(east: 0, north: 0), point(east: first, north: 0), point(east: first, north: then)],
                  segments: [DemoSegment(at: 0, road: side, control: .none), DemoSegment(at: first, road: road, control: control)])
    }

    private func script(_ route: DemoRoute, style: DemoStyle = DemoStyle(), stops: [StopSignPass.Outcome] = [],
                        lightWaits: [Double] = [], incidents: [DemoIncidentAt] = []) -> DemoDriveScript {
        DemoDriveScript(startedAt: Date(timeIntervalSince1970: 1_790_000_000), route: route, style: style, stopOutcomes: stops,
                        lightWaits: lightWaits, incidents: incidents, seed: 42)
    }

    private func analyse(_ s: DemoDriveScript) throws -> DriveAnalysis {
        let drive = DemoSynth.synthesize(s)
        let plan = try DriveAnalyzer.plan(log: drive.log)
        return DriveAnalyzer.analyze(plan: plan, log: drive.log, vehicle: VehicleParams(), ways: drive.ways, controls: drive.controls)
    }

    private func distance(from p: GPSSample, to route: DemoRoute) -> Double {
        let proj = Geo.LocalProjection(lat0: origin.lat, lon0: origin.lon)
        let (px, py) = proj.xy(p.lat, p.lon)
        return zip(route.points, route.points.dropFirst()).map { a, b in
            let (ax, ay) = proj.xy(a.lat, a.lon), (bx, by) = proj.xy(b.lat, b.lon)
            return Geo.pointSegment(px: px, py: py, ax: ax, ay: ay, bx: bx, by: by).dist
        }.min() ?? .infinity
    }

    func testCleanDriveHasNoEventsAndKnownLimits() throws {
        let a = try analyse(script(straight(2400, road: road)))
        XCTAssertGreaterThan(a.distanceM, 2200)
        XCTAssertTrue(a.events.filter { $0.kind != .idle }.isEmpty, "\(a.events.map(\.kind))")
        XCTAssertTrue(a.speedLimitsAvailable)
        XCTAssertGreaterThan(a.speedLimitCoverage, 0.8)
    }

    func testIncidentsBecomeEvents() throws {
        let route = straight(2000, road: road)
        let speeding = try analyse(script(route, incidents: [DemoIncidentAt(incident: .speeding(mphOver: 13, seconds: 14), at: 0.3)]))
        XCTAssertTrue(speeding.events.contains { $0.kind == .speeding })

        let brake = try analyse(script(route, incidents: [DemoIncidentAt(incident: .suddenBrake, at: 0.5)]))
        XCTAssertTrue(brake.events.contains { $0.kind == .hardBrake })

        let close = try analyse(script(route, incidents: [DemoIncidentAt(incident: .tailgating(gap: 0.7, seconds: 9), at: 0.3)]))
        XCTAssertTrue(close.events.contains { $0.kind == .tailgating })
        XCTAssertTrue(close.tailgatingAvailable)
    }

    func testFastTurnIsHarshAndSlowTurnIsNot() throws {
        let route = corner(first: 600, then: 1800, control: .none)
        let fast = try analyse(script(route, style: DemoStyle(cornering: 3.6)))
        XCTAssertTrue(fast.events.contains { $0.kind == .harshCorner })
        let rushed = try analyse(script(route, incidents: [DemoIncidentAt(incident: .fastTurn, at: 0.05)]))
        XCTAssertEqual(rushed.events.filter { $0.kind == .harshCorner }.count, 1)
        let slow = try analyse(script(route))
        XCTAssertFalse(slow.events.contains { $0.kind == .harshCorner })
    }

    func testStopSignOutcomesAreRecognised() throws {
        for outcome in [StopSignPass.Outcome.fullStop, .rolling, .missed] {
            let a = try analyse(script(corner(first: 800, then: 1600, control: .stopSign), stops: [outcome]))
            XCTAssertEqual(a.stopSigns?.map(\.outcome), [outcome], "\(outcome)")
        }
    }

    func testLongRedLightIsIdling() throws {
        let a = try analyse(script(straight(2400, road: road, light: 75), lightWaits: [75]))
        XCTAssertTrue(a.events.contains { $0.kind == .idle })
    }

    func testRoutesFollowLoudounRoads() {
        let routes = [DemoRoutes.toWork, DemoRoutes.toHome, DemoRoutes.toSchool, DemoRoutes.fromSchool,
                      DemoRoutes.toStore, DemoRoutes.fromStore, DemoRoutes.lap]
        for route in routes {
            XCTAssertTrue(route.points.allSatisfy { (38.9...39.3).contains($0.lat) && (-77.9 ... -77.3).contains($0.lon) })
            XCTAssertGreaterThan(route.length, 2000)
            let gps = DemoSynth.synthesize(script(route)).log.gps
            let worst = gps.map { distance(from: $0, to: route) }.max() ?? .infinity
            XCTAssertLessThan(worst, 20, "\(route.segments.map(\.road.name))")
            guard let end = gps.last, let last = route.points.last else { return XCTFail("empty route") }
            XCTAssertLessThan(Geo.haversine(end.lat, end.lon, last.lat, last.lon), 20)
        }
    }

    func testLapsRepeatTheLoopWithAPauseBetween() {
        let lap = DemoRoutes.lap
        let three = DemoRoute.laps(lap, count: 3)
        XCTAssertEqual(three.length, lap.length * 3, accuracy: 1)
        XCTAssertEqual(three.segments.count, lap.segments.count * 3)
        XCTAssertEqual(three.segments.filter { $0.control == .pause }.count, 2)
        XCTAssertEqual(three.segments.filter { $0.control == .stopSign }.count, 6)
    }

    func testPracticeLapsRecogniseEveryStopSign() throws {
        let practice = DemoCatalog.content(for: .newDriver, now: now).drives.filter { !$0.stopOutcomes.isEmpty }
        XCTAssertFalse(practice.isEmpty)
        for drive in practice {
            XCTAssertEqual(try analyse(drive).stopSigns?.map(\.outcome), drive.stopOutcomes, "\(drive.startedAt)")
        }
    }

    func testRealRoutesHaveSpeedLimits() throws {
        let a = try analyse(script(DemoRoutes.toWork))
        XCTAssertTrue(a.speedLimitsAvailable)
        XCTAssertGreaterThan(a.speedLimitCoverage, 0.8)
        XCTAssertTrue(a.events.filter { $0.kind != .idle }.isEmpty, "\(a.events.map(\.kind))")
    }

    func testDemoClipDriveScoresAsAFullTrip() throws {
        let drive = DemoClip.drive()
        let plan = try DriveAnalyzer.plan(log: drive.log)
        let a = DriveAnalyzer.analyze(plan: plan, log: drive.log, vehicle: VehicleParams(), ways: drive.ways, controls: drive.controls)
        XCTAssertLessThan(a.tripStartT, 2)
        XCTAssertGreaterThan(a.durationS, 120)
        XCTAssertGreaterThan(a.distanceM, 500)
        XCTAssertGreaterThan(a.speedLimitCoverage, 0.9)
        XCTAssertEqual(a.events.filter { $0.kind != .idle }.map(\.kind), [.speeding], "\(a.events.map(\.kind))")
        XCTAssertEqual(drive.log.gps.last?.t ?? 0, DemoClip.duration, accuracy: 1.5)
        XCTAssertEqual(drive.ways.first?.name, "Ashburn Road")
    }

    func testSynthesisIsDeterministic() {
        let s = script(straight(800, road: road))
        XCTAssertEqual(DemoSynth.synthesize(s).log.gps, DemoSynth.synthesize(s).log.gps)
    }

    func testEveryCatalogDriveScores() throws {
        for profile in DemoProfile.allCases {
            let content = DemoCatalog.content(for: profile, now: now)
            XCTAssertGreaterThanOrEqual(content.drives.count, 10, "\(profile)")
            for s in content.drives {
                XCTAssertLessThan(s.startedAt, now)
                let a = try analyse(s)
                XCTAssertEqual(a.stopSigns?.count ?? 0, s.route.segments.filter { $0.control == .stopSign }.count, "\(profile) \(s.startedAt)")
                XCTAssertGreaterThan(a.speedLimitCoverage, 0.9)
            }
        }
    }

    func testRegularDriverImproves() throws {
        let drives = DemoCatalog.content(for: .regular, now: now).drives
        let sorted = drives.sorted { $0.startedAt < $1.startedAt }
        let early = try sorted.prefix(5).map { try analyse($0).events.filter { $0.kind != .idle }.count }.reduce(0, +)
        let late = try sorted.suffix(5).map { try analyse($0).events.filter { $0.kind != .idle }.count }.reduce(0, +)
        XCTAssertGreaterThan(early, late)
    }

    func testNewDriverHasNightPractice() throws {
        let content = DemoCatalog.content(for: .newDriver, now: now)
        let nightDrives = try content.drives.filter { s in
            let a = try analyse(s)
            let start = s.startedAt.addingTimeInterval(a.tripStartT)
            let p = try XCTUnwrap(a.trace.first)
            return Solar.nightSeconds(from: start, to: start.addingTimeInterval(a.durationS), lat: p.lat, lon: p.lon) > 600
        }
        XCTAssertGreaterThanOrEqual(nightDrives.count, 2)
        XCTAssertTrue(content.drives.allSatisfy { $0.supervisor != nil })
        XCTAssertFalse(content.extraHours.isEmpty)
    }
}
