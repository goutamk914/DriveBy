import Foundation

struct DailyScore: Identifiable, Hashable, Sendable {
    var day: Date
    var efficiency: Double?
    var safety: Double?
    var miles: Double
    var id: Date { day }
}

enum Trends {
    static func daily(_ drives: [DriveRecord], days: Int, now: Date = Date(), calendar: Calendar = .current) -> [DailyScore] {
        guard let from = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now)) else { return [] }
        let recent = drives.filter { $0.processed && $0.startedAt >= from }
        let groups = Dictionary(grouping: recent) { calendar.startOfDay(for: $0.startedAt) }
        return groups.keys.sorted().map { day in
            let ds = groups[day]!
            func wmean(_ f: (DriveRecord) -> Double?) -> Double? {
                let pairs = ds.compactMap { d -> (Double, Double)? in
                    guard let v = f(d) else { return nil }
                    return (v, max(d.miles ?? 0, 0.1))
                }
                let w = pairs.map(\.1).reduce(0, +)
                return w > 0 ? pairs.map { $0.0 * $0.1 }.reduce(0, +) / w : nil
            }
            return DailyScore(day: day, efficiency: wmean(\.efficiencyScore), safety: wmean(\.safetyScore),
                              miles: ds.compactMap(\.miles).reduce(0, +))
        }
    }

    static func weeklyStreak(_ drives: [DriveRecord], threshold: Double = 80, now: Date = Date(),
                             calendar: Calendar = .current) -> Int {
        var cal = calendar
        cal.firstWeekday = 1
        func weekStart(_ d: Date) -> Date { cal.dateInterval(of: .weekOfYear, for: d)?.start ?? cal.startOfDay(for: d) }
        let groups = Dictionary(grouping: drives.filter { $0.processed && $0.safetyScore != nil }) { weekStart($0.startedAt) }
        func qualifies(_ w: Date) -> Bool? {
            guard let ds = groups[w], !ds.isEmpty else { return nil }
            let wsum = ds.map { max($0.miles ?? 0, 0.1) }.reduce(0, +)
            let avg = ds.map { ($0.safetyScore ?? 0) * max($0.miles ?? 0, 0.1) }.reduce(0, +) / wsum
            return avg >= threshold
        }
        var week = weekStart(now)
        var streak = 0
        if qualifies(week) == true { streak += 1 }
        guard let prev = cal.date(byAdding: .weekOfYear, value: -1, to: week) else { return streak }
        week = prev
        while qualifies(week) == true {
            streak += 1
            guard let p = cal.date(byAdding: .weekOfYear, value: -1, to: week) else { break }
            week = p
        }
        return streak
    }

    static func smoothStreak(_ drives: [DriveRecord], hardBrakeCounts: [UUID: Int]) -> Int {
        var n = 0
        for d in drives.filter(\.processed).sorted(by: { $0.startedAt > $1.startedAt }) {
            if (hardBrakeCounts[d.id] ?? 0) == 0 { n += 1 } else { break }
        }
        return n
    }
}
