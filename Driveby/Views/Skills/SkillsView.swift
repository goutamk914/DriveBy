import SwiftUI

struct SkillsView: View {
    @Environment(AppModel.self) private var model
    @Environment(DriveStore.self) private var drives
    @Environment(AppSettings.self) private var settings
    @State private var expanded: Skill?

    private let window = 10

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    safetyCard
                    skillsCard
                    practiceCard
                    NavigationLink { TrendsView() } label: {
                        linkCard(title: "Score trends", detail: "Daily safety and efficiency, streaks and totals")
                    }
                    .buttonStyle(.plain)
                    NavigationLink { ValidationView() } label: {
                        linkCard(title: "Is the efficiency score real?", detail: "Your score vs. actual fuel economy")
                    }
                    .buttonStyle(.plain)
                    DisclaimerBanner(compact: true)
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Driver Skills")
        }
    }

    private var recent: [DriveRecord] { Array(drives.processed.prefix(window)) }

    private var current: SkillReport { model.combinedSkills(lastDrives: window) }

    private var previous: SkillReport {
        SkillReport.combine(drives.processed.dropFirst(window).prefix(window).compactMap { drives.analysis($0)?.skills })
    }

    private var averageSafety: Double? {
        let scored = recent.filter { $0.safetyScore != nil }
        let weight = scored.map { max($0.distanceM ?? 0, 1) }
        let total = weight.reduce(0, +)
        guard total > 0 else { return nil }
        return zip(scored, weight).map { ($0.safetyScore ?? 0) * $1 }.reduce(0, +) / total
    }

    private var safetyCard: some View {
        Card {
            HStack(alignment: .center, spacing: 16) {
                ScoreRing(title: "Safety score", score: averageSafety, tint: Theme.safety, size: 104)
                VStack(alignment: .leading, spacing: 6) {
                    Text(safetyHeadline).font(.headline)
                    Text(recent.isEmpty ? "Record a supervised drive to get your first score."
                                        : "Average of your last \(recent.count) drive\(recent.count == 1 ? "" : "s"), weighted by distance. 100 = no coaching events.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var safetyHeadline: String {
        guard let s = averageSafety else { return "No score yet" }
        switch s {
        case 90...: return "Excellent — keep it up"
        case 80..<90: return "Solid, a few things to polish"
        case 70..<80: return "Getting there"
        default: return "Lots to practise — that's what permits are for"
        }
    }

    private var skillsCard: some View {
        let now = current, before = previous
        return Card {
            SectionHeader(title: "Skills", subtitle: "Last \(min(recent.count, window)) drives · tap a skill for what it means")
            ForEach(Skill.allCases) { skill in
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        withAnimation(.snappy) { expanded = expanded == skill ? nil : skill }
                    } label: {
                        SkillBar(skill: skill, percent: now.percent(skill), detail: detail(skill, now))
                    }
                    .buttonStyle(.plain)
                    if let delta = change(skill, now, before) {
                        Text(String(format: "%@%.0f points vs. the 10 drives before", delta >= 0 ? "+" : "", delta))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(delta >= 0 ? Theme.efficiency : .orange)
                    }
                    if expanded == skill {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(skill.definition).font(.caption)
                            let drill = PracticePlanner.drill(for: skill)
                            Text("Drill: \(drill.title)").font(.caption.weight(.semibold)).padding(.top, 2)
                            ForEach(Array(drill.steps.enumerated()), id: \.offset) { n, s in
                                Text("\(n + 1). \(s)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(skill.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                if skill != Skill.allCases.last { Divider() }
            }
        }
    }

    private func detail(_ skill: Skill, _ r: SkillReport) -> String {
        let s = r[skill]
        let timeBased = skill == .speedControl || skill == .followingDistance
        if s.total < skill.minimumTotal {
            let need = timeBased ? "\(Int(skill.minimumTotal / 60)) minute of data" : "\(Int(skill.minimumTotal)) \(skill.unit)"
            if skill == .followingDistance { return "Not enough time behind other cars yet (needs \(need) with the camera on)." }
            if skill == .stopSigns { return "Not enough mapped stop signs yet (needs \(need))." }
            return "Not enough data yet (needs \(need))."
        }
        if timeBased {
            return "\(Int((s.good / 60).rounded())) of \(Int((s.total / 60).rounded())) \(skill.unit)"
        }
        return "\(Int(s.good)) of \(Int(s.total)) \(skill.unit)"
    }

    private func change(_ skill: Skill, _ now: SkillReport, _ before: SkillReport) -> Double? {
        guard let a = now.percent(skill), let b = before.percent(skill), abs(a - b) >= 1 else { return nil }
        return a - b
    }

    private var practiceCard: some View {
        Card {
            SectionHeader(title: "What to practise next", subtitle: settings.driverMode == .newDriver ? "Step-by-step drills" : nil)
            let plan = model.practicePlan()
            if plan.isEmpty {
                Text("Record a few drives and Driveby will suggest what to work on.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(plan) { f in
                VStack(alignment: .leading, spacing: 6) {
                    Text(f.title)
                        .font(.headline).foregroundStyle(f.skill?.color ?? .indigo)
                    Text(f.why).font(.footnote).foregroundStyle(.secondary)
                    if settings.driverMode == .newDriver {
                        ForEach(Array(f.steps.enumerated()), id: \.offset) { n, s in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(n + 1).").font(.footnote.monospacedDigit().weight(.semibold))
                                Text(s).font(.footnote)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            Text("Practise drills only with your supervising driver, and check them with your instructor.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func linkCard(title: String, detail: String) -> some View {
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
    }
}
