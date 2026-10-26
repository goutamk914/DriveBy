import Foundation

struct EventCopy: Equatable, Sendable {
    var headline: String
    var body: String
    var tip: String
}

enum EventCopywriter {
    static func timeInto(_ seconds: Double) -> String {
        let s = max(Int(seconds.rounded()), 0)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func mph(_ mps: Double?) -> String { String(format: "%.0f", Units.mph(mps ?? 0)) }

    static func money(_ dollars: Double) -> String {
        if dollars < 0.995 { return "\(max(Int((dollars * 100).rounded()), 1))¢" }
        return String(format: "$%.2f", dollars)
    }

    static func gallons(_ g: Double) -> String {
        g < 0.01 ? String(format: "%.3f", g) : String(format: "%.2f", g)
    }

    static func copy(for e: DriveEvent, tripStartT: Double, pricePerGallon: Double) -> EventCopy {
        let when = "\(e.kind.title), \(timeInto(e.tOffsetS - tripStartT)) into your drive"
        let road = e.detail.road.map { " on \($0)" } ?? ""
        let d = e.detail
        switch e.kind {
        case .hardBrake:
            let secs = String(format: "%.1f", d.durationS ?? e.duration)
            var body = "You slowed from \(mph(d.vStartMps)) to \(mph(d.vEndMps)) mph in \(secs) seconds\(road)."
            if let energy = d.energyJ, energy > 0 {
                let gal = energy / (Units.joulesPerGallonGasoline * Units.typicalEngineEfficiency)
                body += " Easing off earlier would have saved about \(money(gal * pricePerGallon))."
            }
            return EventCopy(headline: when, body: body,
                             tip: "Lift off the gas earlier and let the car coast.")
        case .hardAccel:
            let secs = String(format: "%.1f", d.durationS ?? e.duration)
            let g = String(format: "%.2f", abs(d.peak ?? 0) / 9.81)
            return EventCopy(headline: when,
                             body: "You went from \(mph(d.vStartMps)) to \(mph(d.vEndMps)) mph in \(secs) seconds\(road) (peak \(g) g).",
                             tip: "Take about twice as long to reach speed.")
        case .harshCorner:
            let g = String(format: "%.2f", (d.peak ?? 0) / 9.81)
            return EventCopy(headline: when,
                             body: "You took this turn at \(mph(d.vStartMps)) mph with \(g) g of sideways force\(road).",
                             tip: "Brake before the turn, not in it.")
        case .speeding:
            let secs = String(format: "%.0f", d.durationS ?? e.duration)
            let limit = d.limitMps.map { "\(mph($0)) zone" } ?? "zone"
            return EventCopy(headline: when,
                             body: "You held about \(mph(d.vStartMps)) mph in a \(limit)\(road) for \(secs) seconds.",
                             tip: "Map limits can be outdated. The posted sign wins.")
        case .idle:
            let dur = d.durationS ?? e.duration
            let gal = dur / 3600 * Units.idleGallonsPerHour
            let mins = Int(dur) / 60, secs = Int(dur) % 60
            return EventCopy(headline: when,
                             body: "The car idled for \(mins) min \(secs) s\(road), using about \(money(gal * pricePerGallon)) of fuel.",
                             tip: "Waiting over a minute somewhere safe? Turn the engine off.")
        case .tailgating:
            let h = String(format: "%.1f", d.headwayS ?? d.peak ?? 0)
            let secs = String(format: "%.0f", d.durationS ?? e.duration)
            return EventCopy(headline: when,
                             body: "You were \(h) seconds behind the car ahead at \(mph(d.vStartMps)) mph for \(secs) seconds\(road).",
                             tip: "Leave at least 2 seconds, 3 in rain or at night.")
        case .laneDrift:
            return EventCopy(headline: when, body: "Lane drift detection is planned for Driveby 2.0.", tip: "")
        }
    }
}
