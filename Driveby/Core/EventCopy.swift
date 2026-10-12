//  EventCopy.swift — Driveby
//  "Do not show `hard_brake severity 0.72`." Every event becomes a plain-English
//  coaching line, tied to a dollar figure from the user's own fuel log where
//  the physics supports one.
//
//    Hard braking — 4:32 into your drive
//    You slowed from 41 to 12 mph in 2.1 seconds on Route 7. Easing off earlier
//    here would have saved roughly 0.008 gallons — about 3¢.

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

    /// - Parameters:
    ///   - tripStartT: sensor time when the trip started (for "4:32 into your drive")
    ///   - pricePerGallon: from the user's latest fuel-log entry (fallback: settings default)
    static func copy(for e: DriveEvent, tripStartT: Double, pricePerGallon: Double) -> EventCopy {
        let when = "\(e.kind.title) — \(timeInto(e.tOffsetS - tripStartT)) into your drive"
        let road = e.detail.road.map { " on \($0)" } ?? ""
        let d = e.detail
        switch e.kind {
        case .hardBrake:
            let secs = String(format: "%.1f", d.durationS ?? e.duration)
            var body = "You slowed from \(mph(d.vStartMps)) to \(mph(d.vEndMps)) mph in \(secs) seconds\(road)."
            if let energy = d.energyJ, energy > 0 {
                let gal = energy / (Units.joulesPerGallonGasoline * Units.typicalEngineEfficiency)
                body += " Easing off earlier here would have saved roughly \(gallons(gal)) gallons — about \(money(gal * pricePerGallon))."
            }
            let g = String(format: "%.2f", abs(d.peak ?? 0) / 9.81)
            return EventCopy(headline: when, body: body,
                             tip: "Peak deceleration \(g) g. Lift off the gas as soon as you see the light change or traffic slow, and let the car coast.")
        case .hardAccel:
            let secs = String(format: "%.1f", d.durationS ?? e.duration)
            let g = String(format: "%.2f", abs(d.peak ?? 0) / 9.81)
            return EventCopy(headline: when,
                             body: "You went from \(mph(d.vStartMps)) to \(mph(d.vEndMps)) mph in \(secs) seconds\(road) (peak \(g) g).",
                             tip: "Hard launches burn extra fuel for very little time saved. Try taking about twice as long to reach speed.")
        case .harshCorner:
            let g = String(format: "%.2f", (d.peak ?? 0) / 9.81)
            return EventCopy(headline: when,
                             body: "You took this turn at \(mph(d.vStartMps)) mph with \(g) g of sideways force\(road).",
                             tip: "Brake before the turn, not in it — enter slower and accelerate gently on the way out.")
        case .speeding:
            let secs = String(format: "%.0f", d.durationS ?? e.duration)
            let limit = d.limitMps.map { "\(mph($0)) zone" } ?? "zone"
            return EventCopy(headline: when,
                             body: "You held about \(mph(d.vStartMps)) mph in a \(limit)\(road) for \(secs) seconds.",
                             tip: "Limits come from OpenStreetMap and can be out of date — the posted sign always wins. Drag rises with the square of speed, so this costs fuel too.")
        case .idle:
            let dur = d.durationS ?? e.duration
            let gal = dur / 3600 * Units.idleGallonsPerHour
            let mins = Int(dur) / 60, secs = Int(dur) % 60
            return EventCopy(headline: when,
                             body: "The car sat still for \(mins) min \(secs) s\(road). Idling burns roughly \(gallons(gal)) gallons over that time — about \(money(gal * pricePerGallon)).",
                             tip: "Waiting more than a minute somewhere safe (pickup line, drive-through)? Turning the engine off saves fuel.")
        case .tailgating:
            let h = String(format: "%.1f", d.headwayS ?? d.peak ?? 0)
            let secs = String(format: "%.0f", d.durationS ?? e.duration)
            return EventCopy(headline: when,
                             body: "You were \(h) seconds behind the car ahead at \(mph(d.vStartMps)) mph for \(secs) seconds\(road).",
                             tip: "Leave at least 2 seconds — 3 or more in rain or at night. Pick a sign; count when the car ahead passes it.")
        case .laneDrift:
            return EventCopy(headline: when, body: "Lane drift detection is planned for Driveby 2.0.", tip: "")
        }
    }
}
