import Foundation

enum Numerics {

    static func mean(_ x: [Double]) -> Double {
        x.isEmpty ? .nan : x.reduce(0, +) / Double(x.count)
    }

    static func clip(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        v.isNaN ? lo : min(max(v, lo), hi)
    }

    static func ramp(_ v: Double, from a: Double, to b: Double) -> Double {
        guard a != b else { return v >= b ? 1 : 0 }
        return clip((v - a) / (b - a), 0, 1)
    }

    static func percentile(_ values: [Double], _ q: Double) -> Double {
        let x = values.filter { $0.isFinite }.sorted()
        guard !x.isEmpty else { return .nan }
        if x.count == 1 { return x[0] }
        let pos = clip(q, 0, 100) / 100 * Double(x.count - 1)
        let lo = Int(pos.rounded(.down))
        let hi = min(lo + 1, x.count - 1)
        let frac = pos - Double(lo)
        return x[lo] + (x[hi] - x[lo]) * frac
    }

    static func gradient(_ y: [Double], dt: Double) -> [Double] {
        let n = y.count
        guard n >= 2 else { return Array(repeating: 0, count: n) }
        var g = [Double](repeating: 0, count: n)
        g[0] = (y[1] - y[0]) / dt
        g[n - 1] = (y[n - 1] - y[n - 2]) / dt
        if n > 2 {
            for i in 1..<(n - 1) { g[i] = (y[i + 1] - y[i - 1]) / (2 * dt) }
        }
        return g
    }

    static func polyfit(_ xs: [Double], _ ys: [Double], order: Int) -> [Double] {
        let k = order + 1
        var ata = [[Double]](repeating: [Double](repeating: 0, count: k), count: k)
        var aty = [Double](repeating: 0, count: k)
        for (x, y) in zip(xs, ys) {
            var powers = [Double](repeating: 1, count: 2 * k)
            for p in 1..<(2 * k) { powers[p] = powers[p - 1] * x }
            for r in 0..<k {
                aty[r] += powers[r] * y
                for c in 0..<k { ata[r][c] += powers[r + c] }
            }
        }
        return solve(ata, aty) ?? [Double](repeating: 0, count: k)
    }

    static func polyval(_ c: [Double], _ x: Double) -> Double {
        var acc = 0.0
        for coef in c.reversed() { acc = acc * x + coef }
        return acc
    }

    static func savgolCoefficients(window: Int, order: Int) -> [Double] {
        let half = window / 2
        var coeffs = [Double](repeating: 0, count: window)
        let xs = (0..<window).map { Double($0 - half) }
        for j in 0..<window {
            var ys = [Double](repeating: 0, count: window)
            ys[j] = 1
            coeffs[j] = polyval(polyfit(xs, ys, order: order), 0)
        }
        return coeffs
    }

    static func savgol(_ y: [Double], window requested: Int, order: Int) -> [Double] {
        let n = y.count
        var window = requested
        if window > n { window = n % 2 == 1 ? n : n - 1 }
        guard window > order, window >= 3 else { return y }
        let half = window / 2
        let c = savgolCoefficients(window: window, order: order)
        var out = [Double](repeating: 0, count: n)
        for i in half..<(n - half) {
            var acc = 0.0
            for j in 0..<window { acc += c[j] * y[i - half + j] }
            out[i] = acc
        }
        let xs = (0..<window).map(Double.init)
        let headFit = polyfit(xs, Array(y[0..<window]), order: order)
        for i in 0..<half { out[i] = polyval(headFit, Double(i)) }
        let tailFit = polyfit(xs, Array(y[(n - window)..<n]), order: order)
        for i in (n - half)..<n { out[i] = polyval(tailFit, Double(i - (n - window))) }
        return out
    }

    static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        let n = b.count
        guard n > 0, a.count == n else { return nil }
        var m = a
        var v = b
        for col in 0..<n {
            var pivot = col
            var best = abs(m[col][col])
            for r in (col + 1)..<n {
                if abs(m[r][col]) > best { best = abs(m[r][col]); pivot = r }
            }
            if best < 1e-12 { return nil }
            if pivot != col { m.swapAt(pivot, col); v.swapAt(pivot, col) }
            for r in 0..<n where r != col {
                let f = m[r][col] / m[col][col]
                if f == 0 { continue }
                for c in col..<n { m[r][c] -= f * m[col][c] }
                v[r] -= f * v[col]
            }
        }
        return (0..<n).map { v[$0] / m[$0][$0] }
    }

    struct LinearFit: Equatable, Sendable {
        var slope: Double
        var intercept: Double
        var r: Double
        var r2: Double { r * r }
        var n: Int
        func predict(_ x: Double) -> Double { intercept + slope * x }
    }

    static func linearFit(x: [Double], y: [Double]) -> LinearFit? {
        let pairs = zip(x, y).filter { $0.0.isFinite && $0.1.isFinite }
        let n = pairs.count
        guard n >= 2 else { return nil }
        let mx = pairs.map(\.0).reduce(0, +) / Double(n)
        let my = pairs.map(\.1).reduce(0, +) / Double(n)
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for (a, b) in pairs { sxx += (a - mx) * (a - mx); syy += (b - my) * (b - my); sxy += (a - mx) * (b - my) }
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx
        let r = syy > 0 ? sxy / (sxx * syy).squareRoot() : 0
        return LinearFit(slope: slope, intercept: my - slope * mx, r: r, n: n)
    }

    static func ridge(X: [[Double]], y: [Double], lambda: Double) -> (intercept: Double, coef: [Double])? {
        let n = y.count
        guard n >= 2, let p = X.first?.count, p > 0, X.count == n else { return nil }
        let mx = (0..<p).map { j in X.map { $0[j] }.reduce(0, +) / Double(n) }
        let my = y.reduce(0, +) / Double(n)
        var ata = [[Double]](repeating: [Double](repeating: 0, count: p), count: p)
        var aty = [Double](repeating: 0, count: p)
        for i in 0..<n {
            let xc = (0..<p).map { X[i][$0] - mx[$0] }
            let yc = y[i] - my
            for r in 0..<p {
                aty[r] += xc[r] * yc
                for c in 0..<p { ata[r][c] += xc[r] * xc[c] }
            }
        }
        for d in 0..<p { ata[d][d] += lambda }
        guard let beta = solve(ata, aty) else { return nil }
        let intercept = my - zip(beta, mx).map { $0 * $1 }.reduce(0, +)
        return (intercept, beta)
    }

    static func interp(_ query: [Double], xs: [Double], ys: [Double]) -> [Double] {
        guard !xs.isEmpty else { return query.map { _ in .nan } }
        var out = [Double](repeating: 0, count: query.count)
        var j = 0
        for (i, q) in query.enumerated() {
            if q <= xs[0] { out[i] = ys[0]; continue }
            if q >= xs[xs.count - 1] { out[i] = ys[ys.count - 1]; continue }
            while j + 1 < xs.count && xs[j + 1] < q { j += 1 }
            let x0 = xs[j], x1 = xs[j + 1]
            let w = x1 > x0 ? (q - x0) / (x1 - x0) : 0
            out[i] = ys[j] + (ys[j + 1] - ys[j]) * w
        }
        return out
    }

    static func runs(_ mask: [Bool]) -> [(Int, Int)] {
        var result: [(Int, Int)] = []
        var start: Int? = nil
        for (i, m) in mask.enumerated() {
            if m, start == nil { start = i }
            if !m, let s = start { result.append((s, i - 1)); start = nil }
        }
        if let s = start { result.append((s, mask.count - 1)) }
        return result
    }
}

enum Geo {
    static let earthRadius = 6_371_008.8

    static func haversine(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180, dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * earthRadius * atan2(a.squareRoot(), (1 - a).squareRoot())
    }

    static func bearing(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180, dl = (lon2 - lon1) * .pi / 180
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        let b = atan2(y, x) * 180 / .pi
        return (b + 360).truncatingRemainder(dividingBy: 360)
    }

    static func headingDelta(_ a: Double, _ b: Double) -> Double {
        let d = abs((a - b).truncatingRemainder(dividingBy: 360))
        return d > 180 ? 360 - d : d
    }

    struct LocalProjection: Sendable {
        let lat0: Double, lon0: Double, kx: Double, ky: Double
        init(lat0: Double, lon0: Double) {
            self.lat0 = lat0; self.lon0 = lon0
            ky = .pi / 180 * Geo.earthRadius
            kx = ky * cos(lat0 * .pi / 180)
        }
        func xy(_ lat: Double, _ lon: Double) -> (Double, Double) { ((lon - lon0) * kx, (lat - lat0) * ky) }
    }

    static func pointSegment(px: Double, py: Double, ax: Double, ay: Double, bx: Double, by: Double) -> (dist: Double, bearing: Double) {
        let dx = bx - ax, dy = by - ay
        let len2 = dx * dx + dy * dy
        var t = len2 > 0 ? ((px - ax) * dx + (py - ay) * dy) / len2 : 0
        t = min(max(t, 0), 1)
        let cx = ax + t * dx, cy = ay + t * dy
        let dist = ((px - cx) * (px - cx) + (py - cy) * (py - cy)).squareRoot()
        var b = atan2(dx, dy) * 180 / .pi
        if b < 0 { b += 360 }
        return (dist, b)
    }
}

enum Units {
    static let mpsToMph = 2.236936
    static let metresPerMile = 1609.344
    static let litresPerGallon = 3.785411784
    static let gramsGasolinePerGallon = 2830.0
    static let stoichiometricAFR = 14.7
    static let joulesPerGallonGasoline = 121.32e6
    static let typicalEngineEfficiency = 0.25
    static let idleGallonsPerHour = 0.3

    static func mph(_ mps: Double) -> Double { mps * mpsToMph }
    static func miles(_ metres: Double) -> Double { metres / metresPerMile }
}
