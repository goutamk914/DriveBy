import Foundation

struct DemoRoad: Sendable, Equatable {
    var name: String
    var highway: String
    var mph: Int
}

enum DemoControl: Sendable, Equatable {
    case none, stopSign, light, pause
}

struct DemoSegment: Sendable, Equatable {
    var at: Double
    var road: DemoRoad
    var control: DemoControl
}

struct DemoPoint: Sendable, Equatable {
    var lat: Double
    var lon: Double
}

struct DemoRoute: Sendable {
    var points: [DemoPoint]
    var segments: [DemoSegment]

    init(points: [DemoPoint], segments: [DemoSegment]) {
        self.points = points
        self.segments = segments
    }

    init(polyline: String, segments: [DemoSegment]) {
        self.init(points: DemoPolyline.decode(polyline), segments: segments)
    }

    var length: Double {
        zip(points, points.dropFirst()).map { Geo.haversine($0.lat, $0.lon, $1.lat, $1.lon) }.reduce(0, +)
    }

    func dropping(first metres: Double) -> DemoRoute {
        var walked = 0.0
        var k = 0
        while k + 1 < points.count {
            let step = Geo.haversine(points[k].lat, points[k].lon, points[k + 1].lat, points[k + 1].lon)
            guard walked + step <= metres else { break }
            walked += step
            k += 1
        }
        let current = segments.last { $0.at <= walked } ?? segments.first
        let later = segments.filter { $0.at > walked }.map { DemoSegment(at: $0.at - walked, road: $0.road, control: $0.control) }
        let first = current.map { [DemoSegment(at: 0, road: $0.road, control: .none)] } ?? []
        return DemoRoute(points: Array(points[k...]), segments: first + later)
    }

    static func laps(_ lap: DemoRoute, count: Int) -> DemoRoute {
        let lapLength = lap.length
        var points: [DemoPoint] = []
        var segments: [DemoSegment] = []
        for i in 0..<max(count, 1) {
            points += i == 0 ? lap.points : Array(lap.points.dropFirst())
            segments += lap.segments.enumerated().map { k, seg in
                DemoSegment(at: seg.at + Double(i) * lapLength, road: seg.road, control: i > 0 && k == 0 ? .pause : seg.control)
            }
        }
        return DemoRoute(points: points, segments: segments)
    }
}

enum DemoPolyline {
    static func decode(_ encoded: String, precision: Double = 1e6) -> [DemoPoint] {
        let bytes = Array(encoded.utf8)
        var index = 0, lat = 0, lon = 0
        var out: [DemoPoint] = []
        func next() -> Int? {
            var result = 0, shift = 0
            while index < bytes.count {
                let b = Int(bytes[index]) - 63
                index += 1
                result |= (b & 0x1F) << shift
                shift += 5
                if b < 0x20 { return (result & 1) != 0 ? ~(result >> 1) : result >> 1 }
            }
            return nil
        }
        while index < bytes.count, let dLat = next(), let dLon = next() {
            lat += dLat
            lon += dLon
            out.append(DemoPoint(lat: Double(lat) / precision, lon: Double(lon) / precision))
        }
        return out
    }
}

enum DemoIncident: Sendable, Equatable {
    case speeding(mphOver: Double, seconds: Double)
    case tailgating(gap: Double, seconds: Double)
    case suddenBrake
    case fastTurn
}

struct DemoIncidentAt: Sendable, Equatable {
    var incident: DemoIncident
    var at: Double
}

struct DemoStyle: Sendable, Equatable {
    var launch: Double = 1.7
    var brake: Double = 1.8
    var cornering: Double = 2.0
    var mphUnderLimit: Double = 2
}

struct DemoDriveScript: Sendable {
    var startedAt: Date
    var route: DemoRoute
    var style: DemoStyle
    var stopOutcomes: [StopSignPass.Outcome] = []
    var lightWaits: [Double] = []
    var incidents: [DemoIncidentAt] = []
    var seed: UInt64
    var supervisor: String? = nil
    var speedProfile: [DemoSpeedPoint] = []
}

struct DemoSpeedPoint: Sendable, Equatable {
    var t: Double
    var mph: Double
}

struct DemoDrive: Sendable {
    var log: SensorLog
    var ways: [OSMWay]
    var controls: [OSMControl]
}

enum DemoSynth {
    static let dt = 0.1
    static let sampleSpacing = 2.0
    static let headingWindow = 2
    static let curvatureWindow = 5
    static let stopLineSetback = 6.0
    static let parkBefore = 15.0
    static let parkAfter = 200.0
    static let fullStopPause = 2.5
    static let lapPause = 4.0
    static let rollingSpeed = 2.6
    static let missedSpeed = 6.5
    static let suddenBrakeRate = 4.6
    static let suddenBrakeSpeed = 3.0
    static let sharpTurnCurvature = 0.04
    static let fastTurnLateral = 3.8
    static let fastTurnClearOfStop = 40.0
    static let defaultLightWaits: [Double] = [25, 35, 20, 30, 40]
    static let wayPointEvery = 5
    static let gpsInterval = 1.0
    static let firstFix = 0.4
    static let mountTiltDegrees = 20.0
    static let gravity = 9.80665
    static let minCurvature = 1e-4
    static let sameSpot = 8.0
    static let stopTolerance = 0.05
    static let signPastStopLine = 3.0

    static func mps(_ mph: Double) -> Double { mph / Units.mpsToMph }

    static func synthesize(_ script: DemoDriveScript) -> DemoDrive {
        var sim = DemoSimulator(script: script)
        sim.run()
        return sim.result()
    }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func normal(_ sd: Double) -> Double {
        let u1 = max(Double.random(in: 0..<1, using: &self), 1e-12)
        let u2 = Double.random(in: 0..<1, using: &self)
        return sd * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

private struct DemoTrack {
    let proj: Geo.LocalProjection
    var x: [Double] = []
    var y: [Double] = []
    var heading: [Double] = []
    var curvature: [Double] = []
    var length = 0.0

    init(_ route: DemoRoute) {
        let first = route.points.first ?? DemoPoint(lat: 0, lon: 0)
        proj = Geo.LocalProjection(lat0: first.lat, lon0: first.lon)
        let xy = route.points.map { proj.xy($0.lat, $0.lon) }
        var cumulative = [0.0]
        for k in 1..<max(xy.count, 1) where k < xy.count {
            cumulative.append(cumulative[k - 1] + hypot(xy[k].0 - xy[k - 1].0, xy[k].1 - xy[k - 1].1))
        }
        length = cumulative.last ?? 0
        var j = 0
        var s = 0.0
        while s <= length, xy.count >= 2 {
            while j < xy.count - 2 && cumulative[j + 1] < s { j += 1 }
            let span = max(cumulative[j + 1] - cumulative[j], 1e-9)
            let f = min(max((s - cumulative[j]) / span, 0), 1)
            x.append(xy[j].0 + f * (xy[j + 1].0 - xy[j].0))
            y.append(xy[j].1 + f * (xy[j + 1].1 - xy[j].1))
            s += DemoSynth.sampleSpacing
        }
        let n = x.count
        let w = DemoSynth.headingWindow
        let headings = (0..<n).map { i -> Double in
            let a = max(i - w, 0), b = min(i + w, n - 1)
            return (atan2(x[b] - x[a], y[b] - y[a]) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        }
        heading = headings
        let c = DemoSynth.curvatureWindow
        curvature = (0..<n).map { i -> Double in
            let a = max(i - c, 0), b = min(i + c, n - 1)
            guard b > a else { return 0 }
            var d = (headings[b] - headings[a]).truncatingRemainder(dividingBy: 360)
            if d > 180 { d -= 360 }
            if d < -180 { d += 360 }
            return d * .pi / 180 / (Double(b - a) * DemoSynth.sampleSpacing)
        }
    }

    var count: Int { x.count }

    func index(_ s: Double) -> Int { min(max(Int((s / DemoSynth.sampleSpacing).rounded()), 0), max(count - 1, 0)) }

    func latLon(_ px: Double, _ py: Double) -> (lat: Double, lon: Double) {
        (proj.lat0 + py / proj.ky, proj.lon0 + px / proj.kx)
    }
}

private struct DemoStop {
    var s: Double
    var endSpeed: Double
    var hold: Double
    var isSign: Bool
}

private struct DemoSimulator {
    let script: DemoDriveScript
    let track: DemoTrack
    let up: (x: Double, y: Double, z: Double)
    var rng: SeededGenerator
    var caps: [Double] = []
    var stops: [DemoStop] = []
    var t = 0.0
    var s = 0.0
    var v = 0.0
    var nextFix = DemoSynth.firstFix
    var tailgateUntil = -1.0
    var tailgateGap = 1.0
    var gps: [GPSSample] = []
    var imu: [IMUSample] = []
    var lead: [LeadSample] = []
    var controls: [OSMControl] = []
    var wayIds: [Int64] = []

    init(script: DemoDriveScript) {
        self.script = script
        track = DemoTrack(script.route)
        rng = SeededGenerator(seed: script.seed)
        let tilt = DemoSynth.mountTiltDegrees * .pi / 180
        up = (0, cos(tilt), sin(tilt))
        wayIds = sharedWayIds()
        stops = planStops()
        caps = planCaps()
    }

    private func segmentIndex(at distance: Double) -> Int {
        script.route.segments.lastIndex { $0.at <= distance } ?? 0
    }

    private func segmentEnd(_ i: Int) -> Double {
        i + 1 < script.route.segments.count ? script.route.segments[i + 1].at : track.length
    }

    private func sharedWayIds() -> [Int64] {
        let segments = script.route.segments
        return segments.map { seg in Int64((segments.firstIndex { $0.road == seg.road } ?? 0) + 1) }
    }

    private func planStops() -> [DemoStop] {
        var signs = script.stopOutcomes.makeIterator()
        let waits = script.lightWaits.isEmpty ? DemoSynth.defaultLightWaits : script.lightWaits
        var lightCount = 0
        var out: [DemoStop] = []
        for seg in script.route.segments where seg.control != .none {
            let at = max(min(seg.at, track.length) - DemoSynth.stopLineSetback, 0)
            switch seg.control {
            case .stopSign:
                let outcome = signs.next() ?? .fullStop
                let end = outcome == .fullStop ? 0 : outcome == .rolling ? DemoSynth.rollingSpeed : DemoSynth.missedSpeed
                out.append(DemoStop(s: at, endSpeed: end, hold: outcome == .fullStop ? DemoSynth.fullStopPause : 0, isSign: true))
            case .light:
                out.append(DemoStop(s: at, endSpeed: 0, hold: waits[lightCount % waits.count], isSign: false))
                lightCount += 1
            case .pause:
                out.append(DemoStop(s: at, endSpeed: 0, hold: DemoSynth.lapPause, isSign: false))
            case .none:
                break
            }
        }
        out.append(DemoStop(s: track.length, endSpeed: 0, hold: DemoSynth.parkAfter, isSign: false))
        return out.sorted { $0.s < $1.s }
    }

    private func cornerCap(_ k: Int) -> Double {
        (script.style.cornering / max(abs(track.curvature[k]), DemoSynth.minCurvature)).squareRoot()
    }

    private func sharpTurn(after distance: Double) -> [Int] {
        let ds = DemoSynth.sampleSpacing
        let sharp = DemoSynth.sharpTurnCurvature
        let clearOfStops = { (k: Int) in
            !stops.contains { (0...DemoSynth.fastTurnClearOfStop).contains(Double(k) * ds - $0.s) }
        }
        guard let apex = (track.index(distance)..<track.count).first(where: { abs(track.curvature[$0]) > sharp && clearOfStops($0) })
        else { return [] }
        var lo = apex, hi = apex
        while lo > 0 && abs(track.curvature[lo - 1]) > sharp / 2 { lo -= 1 }
        while hi < track.count - 1 && abs(track.curvature[hi + 1]) > sharp / 2 { hi += 1 }
        return Array(lo...hi)
    }

    private func planCaps() -> [Double] {
        let style = script.style
        let n = track.count
        let ds = DemoSynth.sampleSpacing
        guard n > 0 else { return [] }
        let limits = (0..<n).map { Double(script.route.segments[segmentIndex(at: Double($0) * ds)].road.mph) }
        var cap = (0..<n).map { min(DemoSynth.mps(limits[$0] - style.mphUnderLimit), cornerCap($0)) }
        for item in script.incidents {
            guard case .speeding(let over, let seconds) = item.incident else { continue }
            let start = item.at * track.length
            let fast = DemoSynth.mps(limits[track.index(start)] + over)
            for k in track.index(start)...track.index(start + fast * (seconds + 4)) {
                cap[k] = min(DemoSynth.mps(limits[k] + over), cornerCap(k))
            }
        }
        for item in script.incidents where item.incident == .fastTurn {
            for k in sharpTurn(after: item.at * track.length) {
                let fast = min(DemoSynth.mps(limits[k]), (DemoSynth.fastTurnLateral / abs(track.curvature[k])).squareRoot())
                cap[k] = max(cap[k], fast)
            }
        }
        if n >= 2 {
            for k in stride(from: n - 2, through: 0, by: -1) {
                cap[k] = min(cap[k], (cap[k + 1] * cap[k + 1] + 2 * style.brake * ds).squareRoot())
            }
        }
        for item in script.incidents where item.incident == .suddenBrake {
            let at = item.at * track.length
            let slow = DemoSynth.suddenBrakeSpeed
            for k in 0...track.index(at) {
                let d = max(at - Double(k) * ds, 0)
                cap[k] = min(cap[k], (slow * slow + 2 * DemoSynth.suddenBrakeRate * d).squareRoot())
            }
        }
        return cap
    }

    private func cap(at distance: Double) -> Double {
        guard !caps.isEmpty else { return 0 }
        let f = distance / DemoSynth.sampleSpacing
        let a = min(max(Int(f), 0), caps.count - 1), b = min(a + 1, caps.count - 1)
        let w = min(max(f - Double(a), 0), 1)
        return caps[a] + (caps[b] - caps[a]) * w
    }

    mutating func run() {
        guard script.speedProfile.isEmpty else { return runProfile() }
        hold(DemoSynth.parkBefore)
        for stop in stops {
            let target = min(stop.endSpeed, cap(at: stop.s))
            while stop.s - s > DemoSynth.stopTolerance {
                let braking = (target * target + 2 * script.style.brake * (stop.s - s)).squareRoot()
                v = max(min(v + script.style.launch * DemoSynth.dt, cap(at: s), braking), 0.05)
                tick()
                s += v * DemoSynth.dt
            }
            s = max(s, stop.s)
            v = target
            if stop.isSign { placeSign(at: stop.s + DemoSynth.signPastStopLine) }
            if stop.hold > 0 { hold(stop.hold) }
        }
    }

    private mutating func runProfile() {
        let end = script.speedProfile.last?.t ?? 0
        while t < end {
            v = DemoSynth.mps(profileMph(at: t))
            tick()
            s = min(s + v * DemoSynth.dt, track.length)
        }
    }

    private func profileMph(at time: Double) -> Double {
        let points = script.speedProfile
        guard let after = points.firstIndex(where: { $0.t >= time }) else { return points.last?.mph ?? 0 }
        guard after > 0 else { return points[0].mph }
        let a = points[after - 1], b = points[after]
        let w = b.t > a.t ? (time - a.t) / (b.t - a.t) : 1
        return a.mph + (b.mph - a.mph) * w
    }

    private mutating func placeSign(at distance: Double) {
        let k = track.index(distance)
        let c = track.latLon(track.x[k], track.y[k])
        let way = wayIds[segmentIndex(at: max(distance - 5, 0))]
        let known = controls.contains { $0.wayIds == [way] && Geo.haversine($0.lat, $0.lon, c.lat, c.lon) < DemoSynth.sameSpot }
        guard !known else { return }
        controls.append(OSMControl(id: 1000 + Int64(controls.count), lat: c.lat, lon: c.lon, kind: .stop, allWay: false,
                                   wayIds: [way]))
    }

    private mutating func hold(_ seconds: Double) {
        v = 0
        for _ in 0..<Int((seconds / DemoSynth.dt).rounded()) { tick() }
    }

    private mutating func tick() {
        for item in script.incidents {
            guard case .tailgating(let gap, let seconds) = item.incident else { continue }
            let start = item.at * track.length
            if s >= start && s < start + v * DemoSynth.dt + 0.01 && t > tailgateUntil { tailgateUntil = t + seconds; tailgateGap = gap }
        }
        guard track.count > 0 else { t += DemoSynth.dt; return }
        let k = track.index(s)
        let yaw = v * track.curvature[k] + rng.normal(0.003)
        let g = DemoSynth.gravity
        imu.append(IMUSample(t: t,
                             ax: g * up.x + rng.normal(0.05), ay: g * up.y + rng.normal(0.05), az: g * up.z + rng.normal(0.05),
                             gx: yaw * up.x + rng.normal(0.003), gy: yaw * up.y + rng.normal(0.003), gz: yaw * up.z + rng.normal(0.003),
                             yaw: yaw))
        if t + 1e-9 >= nextFix {
            let c = track.latLon(track.x[k] + rng.normal(1.0), track.y[k] + rng.normal(1.0))
            gps.append(GPSSample(t: t, lat: c.lat, lon: c.lon, spd: max(v + rng.normal(0.1), 0),
                                 acc: 4 + Double.random(in: 0..<2, using: &rng), hdg: v >= 1 ? track.heading[k] : nil))
            nextFix += DemoSynth.gpsInterval
        }
        if t < tailgateUntil, v > 0.5 {
            lead.append(LeadSample(t: t, bx: 0.45, by: 0.5, bw: 0.09, bh: 0.08, dist: max(tailgateGap * v + rng.normal(0.4), 2)))
        }
        t += DemoSynth.dt
    }

    func result() -> DemoDrive {
        let segments = script.route.segments
        let ways = segments.enumerated().compactMap { i, seg -> OSMWay? in
            let a = track.index(seg.at), b = track.index(segmentEnd(i))
            guard b > a else { return nil }
            let indices = Array(stride(from: a, to: b, by: DemoSynth.wayPointEvery)) + [b]
            let geometry = indices.map { k -> [Double] in
                let c = track.latLon(track.x[k], track.y[k])
                return [c.lat, c.lon]
            }
            return OSMWay(id: wayIds[i], highway: seg.road.highway, maxspeed: "\(seg.road.mph) mph", name: seg.road.name,
                          ref: nil, oneway: nil, geometry: geometry)
        }
        return DemoDrive(log: SensorLog(gps: gps, imu: imu, obd: [], lead: lead, malformedLines: 0), ways: ways, controls: controls)
    }
}
