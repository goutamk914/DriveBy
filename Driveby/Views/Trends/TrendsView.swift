import Charts
import SwiftUI

struct TrendsView: View {
    @Environment(AppModel.self) private var model
    @Environment(DriveStore.self) private var drives
    @State private var days = 30

    var body: some View {
        ScrollView {
                VStack(spacing: 16) {
                    Picker("Range", selection: $days) {
                        Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90)
                    }
                    .pickerStyle(.segmented)
                    scoresChart
                    streaks
                    NavigationLink { ValidationView() } label: { validationTeaser }
                        .buttonStyle(.plain)
                    totals
                }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("Trends")
    }

    private var daily: [DailyScore] { Trends.daily(drives.records, days: days) }

    private var scoresChart: some View {
        let d = daily
        return Card {
            SectionHeader(title: "Your scores", subtitle: "Daily average, weighted by distance")
            if d.isEmpty {
                Text("Drive a few times to see your trend.").foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(d) { p in
                        if let e = p.efficiency {
                            LineMark(x: .value("Day", p.day, unit: .day), y: .value("Score", e), series: .value("Score", "Efficiency"))
                                .foregroundStyle(Theme.efficiency)
                            PointMark(x: .value("Day", p.day, unit: .day), y: .value("Score", e)).foregroundStyle(Theme.efficiency)
                        }
                        if let s = p.safety {
                            LineMark(x: .value("Day", p.day, unit: .day), y: .value("Score", s), series: .value("Score", "Safety"))
                                .foregroundStyle(Theme.safety)
                            PointMark(x: .value("Day", p.day, unit: .day), y: .value("Score", s)).foregroundStyle(Theme.safety)
                        }
                    }
                }
                .chartYScale(domain: 0...100)
                .frame(height: 200)
                HStack(spacing: 16) {
                    Text("Efficiency").foregroundStyle(Theme.efficiency)
                    Text("Safety").foregroundStyle(Theme.safety)
                }
                .font(.caption)
            }
        }
    }

    private var streaks: some View {
        let weekly = Trends.weeklyStreak(drives.records)
        let smooth = Trends.smoothStreak(drives.records, hardBrakeCounts: drives.hardBrakeCounts())
        return HStack(spacing: 12) {
            Card {
                Text("\(weekly)").font(.title.weight(.bold))
                Text("week safety streak (avg ≥ 80)").font(.caption).foregroundStyle(.secondary)
            }
            Card {
                Text("\(smooth)").font(.title.weight(.bold))
                Text("drives in a row without a hard brake").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var validationTeaser: some View {
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Is the efficiency score real?").font(.headline)
                    Text("Your score vs. actual fuel economy, with r² and n.").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private var totals: some View {
        let recent = drives.processed.filter { $0.startedAt > Date().addingTimeInterval(-Double(days) * 86_400) }
        let miles = recent.compactMap(\.miles).reduce(0, +)
        let hours = recent.compactMap(\.durationS).reduce(0, +) / 3600
        let events = recent.map(\.eventCount).reduce(0, +)
        return Card {
            SectionHeader(title: "Last \(days) days")
            InfoRow(label: "Drives", value: "\(recent.count)")
            InfoRow(label: "Distance", value: String(format: "%.0f mi", miles))
            InfoRow(label: "Time behind the wheel", value: String(format: "%.1f h", hours))
            InfoRow(label: "Coaching events", value: "\(events)")
        }
    }
}
