//  ReflectionView.swift — Driveby
//  Post-drive reflection: opens by itself when a drive has been scored.
//    Beginner — walks through each moment one at a time, then asks one reflection question.
//    Advanced — a compact timeline of the significant moments.
//  Both end with the safety score, what to practise next, and the hours added to the permit log.

import SwiftUI

struct ReflectionView: View {
    let driveId: UUID
    @Environment(AppModel.self) private var model
    @Environment(DriveStore.self) private var drives
    @Environment(AppSettings.self) private var settings
    @Environment(PracticeLogStore.self) private var practiceLog
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var selected: DriveMoment?
    @State private var note = ""
    @State private var noteSaved = false

    var body: some View {
        NavigationStack {
            Group {
                if let r = drives.record(driveId), let a = drives.analysis(r) {
                    content(r, a)
                } else {
                    ContentUnavailableView("Drive not scored yet", systemImage: "hourglass")
                }
            }
            .navigationTitle("Post-drive reflection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { saveNote(); dismiss() } } }
            .navigationDestination(item: $selected) { m in
                if let r = drives.record(driveId) { MomentDetailView(record: r, moment: m) }
            }
        }
    }

    private func moments(_ a: DriveAnalysis) -> [DriveMoment] {
        let all = a.moments(pricePerGallon: model.pricePerGallon)
        return settings.driverMode == .newDriver ? all : all.filter(\.isSignificant)
    }

    @ViewBuilder
    private func content(_ r: DriveRecord, _ a: DriveAnalysis) -> some View {
        let list = moments(a)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summary(r, a, list)
                if settings.driverMode == .newDriver && !list.isEmpty {
                    guided(list, a)
                } else {
                    Card {
                        SectionHeader(title: "Timeline", subtitle: settings.driverMode == .regular ? "Significant issues only" : nil)
                        MomentTimeline(moments: list, tripStartT: a.tripStartT) { selected = $0 }
                    }
                }
                practiceNext
                hoursCard(r)
                if settings.driverMode == .newDriver { reflectionQuestion(r) }
                DisclaimerBanner(compact: true)
            }
            .padding(16)
        }
        .background(Theme.background)
    }

    private func summary(_ r: DriveRecord, _ a: DriveAnalysis, _ list: [DriveMoment]) -> some View {
        let good = list.filter(\.isPositive).count
        let work = list.count - good
        return Card {
            HStack(alignment: .top) {
                ScoreRing(title: "Safety", score: a.safety.score, tint: Theme.safety, size: 96).frame(maxWidth: .infinity)
                ScoreRing(title: "Efficiency", score: r.efficiencyScore, tint: Theme.efficiency, size: 96).frame(maxWidth: .infinity)
            }
            Text("\(Fmt.miles(a.distanceM)) in \(Fmt.duration(a.durationS)) · \(good) good moment\(good == 1 ? "" : "s") · \(work) to work on")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    // MARK: Beginner walk-through

    private func guided(_ list: [DriveMoment], _ a: DriveAnalysis) -> some View {
        let i = min(step, list.count - 1)
        let m = list[i]
        return Card {
            HStack {
                Text("Moment \(i + 1) of \(list.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(EventCopywriter.timeInto(m.t - a.tripStartT)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                MomentBadge(kind: m.kind, size: 36)
                Text(m.kind.title).font(.title3.weight(.bold)).foregroundStyle(m.isPositive ? Theme.efficiency : .primary)
            }
            Text(m.body)
            if !m.tip.isEmpty {
                Label(m.tip, systemImage: m.isPositive ? "hand.thumbsup.fill" : "lightbulb.fill")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Button { selected = m } label: {
                Label(m.clipPath != nil ? "Watch the clip" : "See the details", systemImage: "play.rectangle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            HStack {
                Button("Back") { withAnimation { step = max(i - 1, 0) } }.disabled(i == 0)
                Spacer()
                ProgressView(value: Double(i + 1), total: Double(list.count)).frame(width: 100)
                Spacer()
                Button(i == list.count - 1 ? "Finish" : "Next") {
                    if i == list.count - 1 { saveNote(); dismiss() } else { withAnimation { step = i + 1 } }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: Practice next + hours

    private var practiceNext: some View {
        Card {
            SectionHeader(title: "What to practise next", subtitle: "Based on your last 10 drives")
            ForEach(model.practicePlan()) { f in
                VStack(alignment: .leading, spacing: 6) {
                    Label(f.title, systemImage: f.skill?.symbol ?? "star.fill").font(.headline)
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
            }
        }
    }

    @ViewBuilder
    private func hoursCard(_ r: DriveRecord) -> some View {
        if let e = practiceLog.entry(forDrive: r.id) {
            let h = model.hoursSummary
            Card {
                Label("Added \(HoursSummary.hoursString(e.durationS)) to your permit log" + (e.nightS >= 60 ? " (\(HoursSummary.hoursString(e.nightS)) at night)" : ""),
                      systemImage: "clock.badge.checkmark.fill")
                    .font(.subheadline.weight(.semibold))
                Text("Supervisor: \(e.supervisor.isEmpty ? "not set — edit in the Hours tab" : e.supervisor)").font(.caption).foregroundStyle(.secondary)
                ProgressView(value: min(h.totalHours, max(h.requirement.totalHours, 1)), total: max(h.requirement.totalHours, 1)) {
                    Text(String(format: "%.1f of %.0f hours · %.1f of %.0f night hours", h.totalHours, h.requirement.totalHours,
                                h.nightHours, h.requirement.nightHours)).font(.caption)
                }
            }
        }
    }

    private func reflectionQuestion(_ r: DriveRecord) -> some View {
        Card {
            SectionHeader(title: "Your turn", subtitle: "One thing you'll do differently next drive (saved in your log)")
            TextField("e.g. Start braking earlier for stop signs", text: $note, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            Button(noteSaved ? "Saved" : "Save note") { saveNote() }
                .buttonStyle(.bordered)
                .disabled(note.trimmingCharacters(in: .whitespaces).isEmpty || noteSaved)
        }
        .onChange(of: note) { _, _ in noteSaved = false }
    }

    private func saveNote() {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, var e = practiceLog.entry(forDrive: driveId) else { return }
        e.notes = text
        practiceLog.upsert(e)
        noteSaved = true
    }
}
