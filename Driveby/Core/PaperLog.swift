//  PaperLog.swift — Driveby
//  Reads supervised-driving hours off a photo of a PAPER log, so a new driver who has been logging
//  by hand doesn't start from zero. The OCR itself is Apple Vision (Services/LogScanner.swift);
//  this file is the pure part:
//    1. group recognised text fragments into table rows (cells come back out of order),
//    2. use a written total if there is one ("Total hours: 23.5", "Night total 6:30"),
//    3. otherwise add up every session row ("10/1  4:15–5:30 pm  Night", "10/3  45 min").
//  The result is always shown to the driver to confirm or correct before it touches their log.
//  Pure Foundation — unit-tested in Tests/DrivebyCoreTests/PaperLogTests.swift.

import Foundation

/// One piece of recognised text. Normalised image coordinates with y growing DOWNWARD (top = 0).
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

    /// A single practice session outside this range is a misread (or the state's requirement text).
    static let minSessionMinutes = 5.0
    static let maxSessionMinutes = 12.0 * 60
    /// A whole log can't plausibly exceed this.
    static let maxTotalMinutes = 500.0 * 60
    /// Fragments belong to the same row when their centres are within this fraction of a line height.
    static let rowTolerance = 0.5
    /// Bare integers on a dated row: up to this many are hours, from `bareMinutesFloor` up they're minutes.
    static let bareHoursCeiling = 10.0
    static let bareMinutesFloor = 15.0
    static let bareMinutesCeiling = 240.0
    /// A lone h:mm on a session row counts as a duration only below this (longer is a time of day).
    static let maxBareClockMinutes = 4.0 * 60
    /// Two h:mm columns this close together (and rising) are a start and an end time.
    static let maxStartEndSpanMinutes = 4.0 * 60

    // MARK: Rows

    /// Joins fragments on the same line (left to right), top to bottom.
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

    // MARK: Estimate

    static func estimate(lines: [String]) -> Estimate {
        var writtenTotal: Double?
        var writtenNight: Double?
        var sessions: [Session] = []
        for raw in lines {
            let line = raw.lowercased()
            if isRequirementText(line) { continue }
            if line.contains("total") {
                // "Total hours: 45  Night hours: 15" holds both; a printed target ("/ 45", "of 45") is neither.
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

    /// Minutes of driving written on one line, or nil. Tries, in order: a time range, explicit units,
    /// h:mm, then (only on a dated line or a total) a bare number. The first kind found decides —
    /// if it's implausible the line is skipped rather than guessed from something else on it.
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

    /// h:mm values on a session row with no am/pm. Two rising values close together are Start/End
    /// columns ("4:15  5:30" → 75); otherwise the duration is the smallest value short enough to be one —
    /// a lone "4:15" is a start time, not a four-hour drive.
    private static func sessionMinutes(fromClocks clocks: [Double]) -> Double? {
        if clocks.count == 2, clocks[1] > clocks[0], clocks[1] - clocks[0] <= maxStartEndSpanMinutes {
            return clocks[1] - clocks[0]
        }
        return clocks.filter { $0 < maxBareClockMinutes }.min()
    }

    // MARK: Line parts

    private static func isRequirementText(_ line: String) -> Bool {
        ["must", "required", "requirement", "requires", "minimum", "at least", "including", "needed"].contains { line.contains($0) }
    }

    /// Splits a totals line at its "night" label: (everything before, the night part if any).
    private static func splitAtNight(_ line: String) -> (String, String?) {
        guard let r = line.range(of: "night") ?? line.range(of: "nite") else { return (line, nil) }
        return (String(line[..<r.lowerBound]), String(line[r.lowerBound...]))
    }

    private static func isNight(_ line: String) -> Bool {
        line.contains("night") || line.contains("nite") || !matches(Pattern.nightMark, in: line).isEmpty
    }

    /// "4:15 - 5:30 pm", "11:30am to 1:00pm", "7:45-8:15" → end − start. A bare "10-12" (a date) isn't a range.
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
        // A suffix written on only one end applies to both, unless that makes the session negative
        // ("11:30 to 1:00 pm" started in the morning).
        let startSuffix = start.suffix ?? end.suffix
        let endSuffix = end.suffix ?? start.suffix
        let b = minuteOfDay(end, endSuffix)
        var a = minuteOfDay(start, startSuffix)
        if b <= a, start.suffix == nil, let s = startSuffix { a = minuteOfDay(start, opposite(s)) }
        if b <= a, startSuffix == nil { return b + halfDay - a }    // no am/pm anywhere: "11:30-1:00"
        return b > a ? b - a : b + day - a                          // past midnight
    }

    /// "1 hr 15 min", "45 minutes", "2h", "1.5 hrs" → summed minutes.
    private static func unitMinutes(_ line: String) -> Double? {
        let hours = matches(Pattern.hours, in: line).compactMap { $0[1].flatMap(Double.init) }
        let minutes = matches(Pattern.minutes, in: line).compactMap { $0[1].flatMap(Double.init) }
        guard !hours.isEmpty || !minutes.isEmpty else { return nil }
        return hours.reduce(0, +) * 60 + minutes.reduce(0, +)
    }

    /// "10/12/2025  1.5  D" → 90. Only trusted on a dated row (a session) or a total line; times of day
    /// ("3:45 pm" — a start time, not a duration) are removed first.
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

    // MARK: Regex helpers

    private enum Pattern {
        static let suffix = "(am|pm|a\\.m\\.|p\\.m\\.|a|p)?"
        // ":" or "." between hours and minutes — OCR often reads a handwritten colon as a dot.
        static let range = regex("\\b(\\d{1,2})(?:[:.](\\d{2}))?\\s*\(suffix)\\s*(?:-|–|—|to)\\s*(\\d{1,2})(?:[:.](\\d{2}))?\\s*\(suffix)\\b")
        /// A printed target after the written total: "___ / 45", "out of 45", "12.5 of 45" (but not "total of 23 hours").
        static let target = regex("(?:/|\\bout of\\b)\\s*\\d+(?:\\.\\d+)?|(?<=\\d)\\s+of\\s+\\d+(?:\\.\\d+)?")
        static let clock = regex("\\b(\\d{1,3}):([0-5]\\d)\\b(?!\\s*(?:am|pm|a\\.m|p\\.m))")
        static let timeOfDay = regex("\\b\\d{1,2}(?::\\d{2})?\\s*(?:am|pm|a\\.m\\.|p\\.m\\.)")
        static let hours = regex("\\b(\\d+(?:\\.\\d+)?)\\s*(?:hours|hour|hrs|hr|h)\\b")
        static let minutes = regex("\\b(\\d+)\\s*(?:minutes|minute|mins|min|m)\\b")
        static let date = regex("\\b\\d{1,2}/\\d{1,2}(?:/\\d{2,4})?\\b|\\b\\d{1,2}-\\d{1,2}-\\d{2,4}\\b")
        static let number = regex("(?<![\\d.])(\\d+(?:\\.\\d+)?)(?![\\d.])")
        static let nightMark = regex("(?:^|\\s)\\(?n\\)?(?:\\s|$)")

        /// The patterns are compile-time constants, so a failure here is a programming error caught by the tests.
        private static func regex(_ p: String) -> NSRegularExpression {
            try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
        }
    }

    /// Capture groups (index 0 = whole match) for every match.
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
