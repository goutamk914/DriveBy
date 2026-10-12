import Foundation

enum LiveCue: String, CaseIterable, Sendable {
    case hardBrake, hardAccel, sharpTurn, speeding, tailgating, smoothStop

    var isPositive: Bool { self == .smoothStop }

    func phrase(mode: DriverMode, limitMph: Int?) -> String {
        let learner = mode == .newDriver
        switch self {
        case .hardBrake:
            return learner ? "That was a hard stop. Next time, brake earlier and more gently." : "Hard brake."
        case .hardAccel:
            return learner ? "Easy on the gas. Press the pedal slowly." : "Easy on the gas."
        case .sharpTurn:
            return learner ? "That turn was sharp. Slow down before you start turning." : "Slow down for turns."
        case .speeding:
            guard let limitMph else { return learner ? "You're going too fast. Ease off." : "Watch your speed." }
            return learner ? "You're over the limit. It's \(limitMph) here." : "Speed limit is \(limitMph)."
        case .tailgating:
            return learner ? "You're following too closely. Drop back to a three second gap." : "Too close. Leave more space."
        case .smoothStop:
            return "Nice, smooth stop."
        }
    }

    func shortText(limitMph: Int?) -> String {
        switch self {
        case .hardBrake: return "Hard brake"
        case .hardAccel: return "Easy on the gas"
        case .sharpTurn: return "Sharp turn"
        case .speeding: return limitMph.map { "Limit \($0) mph" } ?? "Watch your speed"
        case .tailgating: return "Too close"
        case .smoothStop: return "Smooth stop"
        }
    }
}

struct LiveCueEvent: Equatable, Sendable {
    var cue: LiveCue
    var t: Double
    var limitMph: Int? = nil
}

struct LiveCoach: Sendable {
    static let minGap = 8.0
    static let repeatGap = 45.0
    static let praiseRepeatGap = 180.0
    static let maxFixGap = 2.5
    static let minFixGap = 0.2
    static let smoothStopFrom = 6.0
    static let brakingOnset = -0.3
    static let stopCancelAccel = 0.5
    static let maxCoastSteps = 5
    static let maxHeadwayGap = 2.5

    let mode: DriverMode

    private var lastFix: (t: Double, v: Double)?
    private var overLimitSince: Double?
    private var cornerSince: Double?
    private var closeSince: Double?
    private var lastHeadwayT: Double?
    private var stopMinAccel: Double?
    private var coastSteps = 0
    private var lastSpoken = -Double.infinity
    private var lastByCue: [LiveCue: Double] = [:]

    init(mode: DriverMode) { self.mode = mode }

    mutating func speed(t: Double, v: Double, limitMps: Double?, posted: Bool = true) -> LiveCueEvent? {
        defer { lastFix = (t, v) }
        var event: LiveCueEvent?
        if let a = longitudinalAccel(t: t, v: v), let previous = lastFix {
            if a <= Thresholds.hardBrakeA, previous.v > Thresholds.tripStartSpeed {
                event = emit(.hardBrake, t: t)
            } else if a >= Thresholds.hardAccelA {
                event = emit(.hardAccel, t: t)
            }
            if let praise = trackStop(a: a, v: v, previousV: previous.v, t: t), event == nil { event = praise }
        }
        if let speeding = trackSpeeding(t: t, v: v, limitMps: limitMps, posted: posted), event == nil { event = speeding }
        return event
    }

    mutating func yaw(t: Double, yawRate: Double, v: Double) -> LiveCueEvent? {
        let lateral = abs(v * yawRate)
        guard v > Thresholds.tripStartSpeed, lateral >= Thresholds.harshCornerA else {
            cornerSince = nil
            return nil
        }
        let since = cornerSince ?? t
        cornerSince = since
        return t - since >= Thresholds.accelSustain ? emit(.sharpTurn, t: t) : nil
    }

    mutating func headway(t: Double, leadDistance: Double?, v: Double) -> LiveCueEvent? {
        defer { lastHeadwayT = t }
        if let last = lastHeadwayT, t - last > Self.maxHeadwayGap { closeSince = nil }
        guard let d = leadDistance, v >= Thresholds.tailgateMinSpeed, d / v < Thresholds.tailgateHeadway else {
            closeSince = nil
            return nil
        }
        let since = closeSince ?? t
        closeSince = since
        return t - since >= Thresholds.tailgateSustain ? emit(.tailgating, t: t) : nil
    }

    private func longitudinalAccel(t: Double, v: Double) -> Double? {
        guard let p = lastFix else { return nil }
        let dt = t - p.t
        guard dt >= Self.minFixGap, dt <= Self.maxFixGap else { return nil }
        return (v - p.v) / dt
    }

    private mutating func trackSpeeding(t: Double, v: Double, limitMps: Double?, posted: Bool) -> LiveCueEvent? {
        guard let limit = limitMps, v > limit + Thresholds.speedingMargin else {
            overLimitSince = nil
            return nil
        }
        let since = overLimitSince ?? t
        overLimitSince = since
        guard t - since >= Thresholds.speedingSustain else { return nil }
        return emit(.speeding, t: t, limitMph: posted ? Self.postedMph(limit) : nil)
    }

    private mutating func trackStop(a: Double, v: Double, previousV: Double, t: Double) -> LiveCueEvent? {
        if a < Self.brakingOnset {
            coastSteps = 0
            if let hardest = stopMinAccel {
                stopMinAccel = min(hardest, a)
            } else if previousV >= Self.smoothStopFrom {
                stopMinAccel = a
            }
        } else if a > Self.stopCancelAccel {
            stopMinAccel = nil
        } else {
            coastSteps += 1
            if coastSteps > Self.maxCoastSteps { stopMinAccel = nil }
        }
        guard v <= SkillThresholds.stopFull, let hardest = stopMinAccel else { return nil }
        stopMinAccel = nil
        return hardest > SkillThresholds.smoothBrakeA ? emit(.smoothStop, t: t) : nil
    }

    private mutating func emit(_ cue: LiveCue, t: Double, limitMph: Int? = nil) -> LiveCueEvent? {
        if cue.isPositive && mode != .newDriver { return nil }
        let repeatGap = cue.isPositive ? Self.praiseRepeatGap : Self.repeatGap
        guard t - lastSpoken >= Self.minGap, t - (lastByCue[cue] ?? -.infinity) >= repeatGap else { return nil }
        lastSpoken = t
        lastByCue[cue] = t
        return LiveCueEvent(cue: cue, t: t, limitMph: limitMph)
    }

    static func postedMph(_ limitMps: Double) -> Int {
        Int(((limitMps * Units.mpsToMph) / 5).rounded()) * 5
    }
}
