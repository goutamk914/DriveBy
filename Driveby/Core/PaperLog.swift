import Foundation

struct OCRFragment: Equatable, Sendable {
    var text: String
    var minX: Double
    var midY: Double
    var height: Double
}

enum PaperLog {
    struct Session: Equatable, Sendable {
        var minutes: Double
        var night: Bool
        var line: String
    }

    struct Estimate: Equatable, Sendable {
        var totalMinutes: Double
        var nightMinutes: Double
        var sessions: [Session]
        var fromWrittenTotal: Bool
        var isEmpty: Bool { totalMinutes <= 0 }
    }

    static let minSessionMinutes = 5.0
    static let maxSessionMinutes = 12.0 * 60
    static let maxTotalMinutes = 500.0 * 60
    static let rowTolerance = 0.5
    static let bareHoursCeiling = 10.0
    static let bareMinutesFloor = 15.0
    static let bareMinutesCeiling = 240.0
    static let maxBareClockMinutes = 4.0 * 60
    static let maxStartEndSpanMinutes = 4.0 * 60

    static func rows(_ fragments: [OCRFragment]) -> [String] {
        var rows: [[OCRFragment]] = []
        for f in fragments.sorted(by: { $0.midY < $1.midY }) {
            if let row = rows.last, let first = row.first {
                let centre = row.map(\.midY).reduce(0, +) / Double(row.count)
                if abs(f.midY - centre) <= rowTolerance * max(f.height, first.height) {
                    rows[rows.count - 1].append(f)
                    continue
                }
            }
            rows.append([f])
        }
        return rows.map { $0.sorted { $0.minX < $1.minX }.map(\.text).joined(separator: "  ") }
    }

    static func estimate(lines: [String]) -> Estimate {
        var writtenTotal: Double?
        var writtenNight: Double?
        var sessions: [Session] = []
        for raw in lines {
            let line = raw.lowercased()
            if isRequirementText(line) { continue }
            if line.contains("total") {
                let (all, night) = splitAtNight(replace(Pattern.target, in: line, with: " "))
                if let m = durationMinutes(in: all, isTotal: true) { writtenTotal = max(writtenTotal ?? 0, m) }
                if let night, let m = durationMinutes(in: night, isTotal: true) { writtenNight = max(writtenNight ?? 0, m) }
                continue
            }
            guard let m = durationMinutes(in: line) else { continue }
            sessions.append(Session(minutes: m, night: isNight(line), line: raw.trimmingCharacters(in: .whitespaces)))
        }
        let sessionTotal = sessions.map(\.minutes).reduce(0, +)
        let sessionNight = sessions.filter(\.night).map(\.minutes).reduce(0, +)
        let total = min(writtenTotal ?? sessionTotal, maxTotalMinutes)
        return Estimate(totalMinutes: total, nightMinutes: min(writtenNight ?? sessionNight, total),
                        sessions: sessions, fromWrittenTotal: writtenTotal != nil)
    }

    static func durationMinutes(in raw: String, isTotal: Bool = false) -> Double? {
        let line = raw.lowercased()
        let range = isTotal ? (minSessionMinutes...maxTotalMinutes) : (minSessionMinutes...maxSessionMinutes)
        func plausible(_ m: Double?) -> Double? { m.flatMap { range.contains($0) ? $0 : nil } }

        if let m = timeRangeMinutes(line) { return plausible(m) }
        if let m = unitMinutes(line) { return plausible(m) }
        let clocks = matches(Pattern.clock, in: line).compactMap { g -> Double? in
            guard let h = g[1].flatMap(Double.init), let m = g[2].flatMap(Double.init) else { return nil }
            return h * 60 + m
        }
        if !clocks.isEmpty { return plausible(isTotal ? clocks.max() : sessionMinutes(fromClocks: clocks)) }
        return plausible(bareNumberMinutes(line, isTotal: isTotal))
    }

    private static func sessionMinutes(fromClocks clocks: [Double]) -> Double? {
        if clocks.count == 2, clocks[1] > clocks[0], clocks[1] - clocks[0] <= maxStartEndSpanMinutes {
            return clocks[1] - clocks[0]
        }
        return clocks.filter { $0 < maxBareClockMinutes }.min()
    }

    private static func isRequirementText(_ line: String) -> Bool {
        ["must", "required", "requirement", "requires", "minimum", "at least", "including", "needed"].contains { line.contains($0) }
    }

    private static func splitAtNight(_ line: String) -> (String, String?) {
        guard let r = line.range(of: "night") ?? line.range(of: "nite") else { return (line, nil) }
        return (String(line[..<r.lowerBound]), String(line[r.lowerBound...]))
    }

    private static func isNight(_ line: String) -> Bool {
        line.contains("night") || line.contains("nite") || !matches(Pattern.nightMark, in: line).isEmpty
    }

    private static func timeRangeMinutes(_ line: String) -> Double? {
        for g in matches(Pattern.range, in: line) {
            let h1 = g[1].flatMap(Double.init), m1 = g[2].flatMap(Double.init), s1 = g[3]
            let h2 = g[4].flatMap(Double.init), m2 = g[5].flatMap(Double.init), s2 = g[6]
            guard let h1, let h2, m1 != nil || m2 != nil || s1 != nil || s2 != nil else { continue }
            return rangeMinutes(start: (h1, m1 ?? 0, s1), end: (h2, m2 ?? 0, s2))
        }
        return nil
    }

    private typealias ClockTime = (h: Double, m: Double, suffix: String?)

    private static func rangeMinutes(start: ClockTime, end: ClockTime) -> Double {
        let day = 24 * 60.0, halfDay = 12 * 60.0
        func minuteOfDay(_ c: ClockTime, _ suffix: String?) -> Double {
            guard let suffix else { return c.h * 60 + c.m }
            let pm = suffix.hasPrefix("p")
            return (c.h.truncatingRemainder(dividingBy: 12) + (pm ? 12 : 0)) * 60 + c.m
        }
        func opposite(_ s: String) -> String { s.hasPrefix("p") ? "am" : "pm" }
        let startSuffix = start.suffix ?? end.suffix
        let endSuffix = end.suffix ?? start.suffix
        let b = minuteOfDay(end, endSuffix)
        var a = minuteOfDay(start, startSuffix)
        if b <= a, start.suffix == nil, let s = startSuffix { a = minuteOfDay(start, opposite(s)) }
        if b <= a, startSuffix == nil { return b + halfDay - a }
        return b > a ? b - a : b + day - a
    }

    private static func unitMinutes(_ line: String) -> Double? {
        let hours = matches(Pattern.hours, in: line).compactMap { $0[1].flatMap(Double.init) }
        let minutes = matches(Pattern.minutes, in: line).compactMap { $0[1].flatMap(Double.init) }
        guard !hours.isEmpty || !minutes.isEmpty else { return nil }
        return hours.reduce(0, +) * 60 + minutes.reduce(0, +)
    }

    private static func bareNumberMinutes(_ line: String, isTotal: Bool) -> Double? {
        let undated = replace(Pattern.date, in: line, with: " ")
        guard isTotal || undated != line else { return nil }
        let rest = replace(Pattern.timeOfDay, in: undated, with: " ")
        for g in matches(Pattern.number, in: rest) {
            guard let token = g[1], let v = Double(token), v > 0 else { continue }
            if isTotal || token.contains(".") || v <= bareHoursCeiling { return v * 60 }
            if (bareMinutesFloor...bareMinutesCeiling).contains(v) { return v }
        }
        return nil
    }

    private enum Pattern {
        static let suffix = "(am|pm|a\\.m\\.|p\\.m\\.|a|p)?"
        static let range = regex("\\b(\\d{1,2})(?:[:.](\\d{2}))?\\s*\(suffix)\\s*(?:-|\u{2013}|\u{2014}|to)\\s*(\\d{1,2})(?:[:.](\\d{2}))?\\s*\(suffix)\\b")
        static let target = regex("(?:/|\\bout of\\b)\\s*\\d+(?:\\.\\d+)?|(?<=\\d)\\s+of\\s+\\d+(?:\\.\\d+)?")
        static let clock = regex("\\b(\\d{1,3}):([0-5]\\d)\\b(?!\\s*(?:am|pm|a\\.m|p\\.m))")
        static let timeOfDay = regex("\\b\\d{1,2}(?::\\d{2})?\\s*(?:am|pm|a\\.m\\.|p\\.m\\.)")
        static let hours = regex("\\b(\\d+(?:\\.\\d+)?)\\s*(?:hours|hour|hrs|hr|h)\\b")
        static let minutes = regex("\\b(\\d+)\\s*(?:minutes|minute|mins|min|m)\\b")
        static let date = regex("\\b\\d{1,2}/\\d{1,2}(?:/\\d{2,4})?\\b|\\b\\d{1,2}-\\d{1,2}-\\d{2,4}\\b")
        static let number = regex("(?<![\\d.])(\\d+(?:\\.\\d+)?)(?![\\d.])")
        static let nightMark = regex("(?:^|\\s)\\(?n\\)?(?:\\s|$)")

        private static func regex(_ p: String) -> NSRegularExpression {
            try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
        }
    }

    private static func matches(_ re: NSRegularExpression, in s: String) -> [[String?]] {
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
        }
    }

    private static func replace(_ re: NSRegularExpression, in s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }
}
