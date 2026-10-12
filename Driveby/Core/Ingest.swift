import Foundation

struct DriveSeries: Sendable {
    var dt: Double = 0.1
    var t: [Double] = []
    var lat: [Double] = []
    var lon: [Double] = []
    var heading: [Double] = []
    var vRaw: [Double] = []
    var v: [Double] = []
    var aLong: [Double] = []
    var yawRate: [Double] = []
    var aLat: [Double] = []
    var distance: [Double] = []
    var gpsGap: [Bool] = []
    var leadDist: [Double?] = []
    var imuJerkRMS: Double = .nan

    var count: Int { t.count }
    var isEmpty: Bool { t.isEmpty }
    var totalDistance: Double { distance.last ?? 0 }
    var duration: Double { count > 1 ? t[count - 1] - t[0] + dt : 0 }

    func index(at time: Double) -> Int {
        guard let first = t.first else { return 0 }
        return Int(Numerics.clip(((time - first) / dt).rounded(), 0, Double(count - 1)))
    }

    func slice(_ lo: Int, _ hi: Int) -> DriveSeries {
        guard !isEmpty, lo <= hi, lo >= 0, hi < count else { return DriveSeries(dt: dt) }
        var s = DriveSeries(dt: dt)
        let r = lo...hi
        s.t = Array(t[r]); s.lat = Array(lat[r]); s.lon = Array(lon[r]); s.heading = Array(heading[r])
        s.vRaw = Array(vRaw[r]); s.v = Array(v[r]); s.aLong = Array(aLong[r]); s.yawRate = Array(yawRate[r])
        s.aLat = Array(aLat[r]); s.gpsGap = Array(gpsGap[r]); s.leadDist = Array(leadDist[r])
        let base = distance[lo]
        s.distance = distance[r].map { $0 - base }
        s.imuJerkRMS = imuJerkRMS
        return s
    }
}

enum Ingest {
    enum Failure: Error, Equatable { case noUsableGPS(fixes: Int) }

    static func resample(_ log: SensorLog, hz: Double = Thresholds.resampleHz) throws -> DriveSeries {
        let dt = 1.0 / hz
        let fixes = log.gps.filter { $0.acc <= Thresholds.maxGPSAccuracy && $0.acc >= 0 }
        guard fixes.count >= 3 else { throw Failure.noUsableGPS(fixes: fixes.count) }

        let t0 = fixes.first!.t, t1 = fixes.last!.t
        let n = max(Int(((t1 - t0) / dt).rounded(.down)) + 1, 1)
        let grid = (0..<n).map { t0 + Double($0) * dt }

        let ft = fixes.map(\.t)
        var spd = [Double](repeating: 0, count: fixes.count)
        for i in fixes.indices {
            if let s = fixes[i].spd { spd[i] = s; continue }
            let j = i > 0 ? i - 1 : min(i + 1, fixes.count - 1)
            let a = fixes[min(i, j)], b = fixes[max(i, j)]
            let dtf = b.t - a.t
            spd[i] = dtf > 0 ? Geo.haversine(a.lat, a.lon, b.lat, b.lon) / dtf : 0
        }

        var s = DriveSeries(dt: dt)
        s.t = grid
        s.lat = Numerics.interp(grid, xs: ft, ys: fixes.map(\.lat))
        s.lon = Numerics.interp(grid, xs: ft, ys: fixes.map(\.lon))
        s.vRaw = Numerics.interp(grid, xs: ft, ys: spd)

        var heading = [Double](repeating: .nan, count: n)
        var gap = [Bool](repeating: false, count: n)
        var j = 0
        for (i, q) in grid.enumerated() {
            while j + 1 < fixes.count && abs(fixes[j + 1].t - q) <= abs(fixes[j].t - q) { j += 1 }
            heading[i] = fixes[j].hdg ?? .nan
            gap[i] = abs(fixes[j].t - q) > 3.0
        }
        for i in 0..<n where heading[i].isNaN {
            let a = max(i - 10, 0), b = min(i + 10, n - 1)
            if b > a, Geo.haversine(s.lat[a], s.lon[a], s.lat[b], s.lon[b]) > 5 {
                heading[i] = Geo.bearing(s.lat[a], s.lon[a], s.lat[b], s.lon[b])
            }
        }
        s.heading = heading
        s.gpsGap = gap

        let smooth = Numerics.savgol(s.vRaw, window: Thresholds.savgolWindow, order: Thresholds.savgolOrder)
        s.v = smooth.map { max($0, 0) }
        s.aLong = Numerics.gradient(smooth, dt: dt)

        var dist = [Double](repeating: 0, count: n)
        for i in 1..<max(n, 1) where i < n { dist[i] = dist[i - 1] + 0.5 * (s.v[i] + s.v[i - 1]) * dt }
        s.distance = dist

        s.yawRate = yawSeries(log.imu, grid: grid, dt: dt)
        s.aLat = zip(s.v, s.yawRate).map { $0 * $1 }
        s.imuJerkRMS = imuJerk(log.imu)

        s.leadDist = leadSeries(log.lead, grid: grid)
        return s
    }

    static func yawSeries(_ imu: [IMUSample], grid: [Double], dt: Double) -> [Double] {
        guard !imu.isEmpty, !grid.isEmpty else { return [Double](repeating: 0, count: grid.count) }
        var yaw = [Double](repeating: 0, count: imu.count)
        var g = (imu[0].ax, imu[0].ay, imu[0].az)
        for (i, s) in imu.enumerated() {
            if let y = s.yaw { yaw[i] = y; continue }
            let alpha = 0.02
            g = (g.0 + alpha * (s.ax - g.0), g.1 + alpha * (s.ay - g.1), g.2 + alpha * (s.az - g.2))
            let norm = (g.0 * g.0 + g.1 * g.1 + g.2 * g.2).squareRoot()
            yaw[i] = norm > 1e-6 ? (s.gx * g.0 + s.gy * g.1 + s.gz * g.2) / norm : 0
        }
        var sums = [Double](repeating: 0, count: grid.count)
        var counts = [Int](repeating: 0, count: grid.count)
        let t0 = grid[0]
        for (i, s) in imu.enumerated() {
            let k = Int(((s.t - t0) / dt).rounded())
            if k >= 0 && k < grid.count { sums[k] += yaw[i]; counts[k] += 1 }
        }
        var xs: [Double] = [], ys: [Double] = []
        for k in grid.indices where counts[k] > 0 { xs.append(grid[k]); ys.append(sums[k] / Double(counts[k])) }
        guard !xs.isEmpty else { return [Double](repeating: 0, count: grid.count) }
        return Numerics.interp(grid, xs: xs, ys: ys)
    }

    static func imuJerk(_ imu: [IMUSample]) -> Double {
        guard imu.count > 2 else { return .nan }
        var acc = 0.0
        var n = 0
        for i in 1..<imu.count {
            let dt = imu[i].t - imu[i - 1].t
            guard dt > 0.001 && dt < 0.2 else { continue }
            let m1 = (imu[i].ax * imu[i].ax + imu[i].ay * imu[i].ay + imu[i].az * imu[i].az).squareRoot()
            let m0 = (imu[i - 1].ax * imu[i - 1].ax + imu[i - 1].ay * imu[i - 1].ay + imu[i - 1].az * imu[i - 1].az).squareRoot()
            let j = (m1 - m0) / dt
            acc += j * j; n += 1
        }
        return n > 0 ? (acc / Double(n)).squareRoot() : .nan
    }

    static func leadSeries(_ lead: [LeadSample], grid: [Double]) -> [Double?] {
        var out = [Double?](repeating: nil, count: grid.count)
        guard !lead.isEmpty else { return out }
        var j = 0
        for (i, q) in grid.enumerated() {
            while j + 1 < lead.count && abs(lead[j + 1].t - q) <= abs(lead[j].t - q) { j += 1 }
            if abs(lead[j].t - q) <= 0.3 { out[i] = lead[j].dist }
        }
        return out
    }
}

enum TripSegmenter {
    struct Trip: Equatable, Sendable { var startIndex: Int; var endIndex: Int }

    static func segment(_ s: DriveSeries) -> Trip? {
        guard s.count > 0 else { return nil }
        let needStart = Int((Thresholds.tripStartSustain / s.dt).rounded())
        let needEnd = Int((Thresholds.tripEndSustain / s.dt).rounded())
        var startIdx: Int? = nil
        var run = 0
        for i in 0..<s.count {
            run = s.vRaw[i] > Thresholds.tripStartSpeed ? run + 1 : 0
            if run >= needStart { startIdx = i - run + 1; break }
        }
        guard let start = startIdx else { return nil }
        var end = s.count - 1
        run = 0
        for i in start..<s.count {
            run = s.vRaw[i] < Thresholds.tripEndSpeed ? run + 1 : 0
            if run >= needEnd { end = i - run + 1; break }
        }
        return Trip(startIndex: start, endIndex: max(end, start))
    }

    static func isTooShort(distance: Double, duration: Double) -> Bool {
        distance < Thresholds.minTripDistance || duration < Thresholds.minTripDuration
    }
}

struct LiveTripDetector: Sendable {
    enum Signal: Equatable, Sendable { case none, started, parked }
    private(set) var moving = false
    private var aboveSince: Double? = nil
    private var belowSince: Double? = nil

    mutating func feed(t: Double, speed: Double) -> Signal {
        if !moving {
            if speed > Thresholds.tripStartSpeed {
                if aboveSince == nil { aboveSince = t }
                if t - aboveSince! >= Thresholds.tripStartSustain { moving = true; belowSince = nil; return .started }
            } else { aboveSince = nil }
        } else {
            if speed < Thresholds.tripEndSpeed {
                if belowSince == nil { belowSince = t }
                if t - belowSince! >= Thresholds.tripEndSustain { moving = false; aboveSince = nil; return .parked }
            } else { belowSince = nil }
        }
        return .none
    }
}
