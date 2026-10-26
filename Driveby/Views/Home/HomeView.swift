import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(DriveStore.self) private var drives
    @Environment(AppSettings.self) private var settings
    @Environment(RecordingController.self) private var recorder
    @State private var showChecklist = false
    @State private var showNewDriverSetup = false
    @State private var pendingStart: (supervisor: String, auto: Bool)?

    private static let recentCount = 3

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let demo = settings.demoProfile { demoBadge(demo) }
                    startCard
                    if settings.isNewDriver {
                        hoursCard
                        practiceCard
                    }
                    latestCard
                    recentDrives
                    if !settings.isNewDriver { newDriverRow }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Theme.background)
            .navigationTitle("Driveby")
            .navigationDestination(for: UUID.self) { id in DriveDetailView(driveId: id) }
            .sheet(isPresented: $showChecklist, onDismiss: startPending) {
                PreDriveChecklistView { supervisor, auto in pendingStart = (supervisor, auto) }
            }
            .sheet(isPresented: $showNewDriverSetup) {
                NavigationStack {
                    NewDriverSetupView(doneTitle: "Turn on new-driver mode") {
                        settings.driverMode = .newDriver
                        showNewDriverSetup = false
                    }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showNewDriverSetup = false } } }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { DriveListView() } label: { Text("All drives") }
                        .accessibilityLabel("All drives")
                }
            }
        }
    }

    private func begin(supervisor: String?, auto: Bool) {
        let vehicle = model.activeVehicle?.id
        if auto { recorder.arm(vehicleId: vehicle, supervisor: supervisor) }
        else { recorder.start(vehicleId: vehicle, supervisor: supervisor) }
    }

    private func startPending() {
        guard let p = pendingStart else { return }
        pendingStart = nil
        begin(supervisor: p.supervisor, auto: p.auto)
    }

    private func demoBadge(_ demo: DemoProfile) -> some View {
        Text("Demo data · \(demo.person), \(demo.title.lowercased())")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.orange.opacity(0.14), in: Capsule())
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var startCard: some View {
        VStack(spacing: 14) {
            Button {
                if settings.isNewDriver { showChecklist = true } else { begin(supervisor: nil, auto: false) }
            } label: {
                ZStack {
                    Circle().fill(Color.red.gradient).frame(width: 150, height: 150)
                        .shadow(color: .red.opacity(0.35), radius: 16, y: 8)
                    VStack(spacing: 4) {
                        Text("Start drive").font(.roadSign(.title2))
                    }
                    .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start recording a drive")

            if !settings.isNewDriver {
                Button("Start automatically when I drive") { begin(supervisor: nil, auto: true) }
                    .font(.subheadline.weight(.medium))
            }

            Text(model.activeVehicle?.displayName ?? "No car set")
                .font(.footnote).foregroundStyle(.secondary)

            if let msg = recorder.message, recorder.phase == .idle {
                Text(msg).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.top, 4)
    }

    @ViewBuilder private var latestCard: some View {
        if let last = drives.processed.first {
            NavigationLink(value: last.id) {
                Card {
                    HStack {
                        SectionHeader(title: "Last drive", subtitle: "\(Fmt.day.string(from: last.startedAt)) · \(Fmt.miles(last.distanceM))")
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 28) {
                        ScoreRing(title: "Safety", score: last.safetyScore, tint: Theme.safety, size: 84)
                        ScoreRing(title: "Efficiency", score: last.efficiencyScore, tint: Theme.efficiency, size: 84)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var hoursCard: some View {
        let h = model.hoursSummary
        return Card {
            HStack {
                SectionHeader(title: "Permit hours")
                Spacer()
                if h.complete { Text("Done").foregroundStyle(.green).font(.subheadline.weight(.semibold)) }
            }
            ProgressView(value: min(h.totalHours, h.requirement.totalHours), total: max(h.requirement.totalHours, 1)) {
                Text(String(format: "%.1f of %.0f hours", h.totalHours, h.requirement.totalHours)).font(.caption)
            }
            .tint(Theme.safety)
            ProgressView(value: min(h.nightHours, h.requirement.nightHours), total: max(h.requirement.nightHours, 1)) {
                Text(String(format: "%.1f of %.0f after sunset", h.nightHours, h.requirement.nightHours)).font(.caption)
            }
            .tint(.indigo)
        }
    }

    @ViewBuilder private var practiceCard: some View {
        if let f = model.practicePlan().first {
            Card {
                SectionHeader(title: "Practise next")
                Text(f.title).font(.headline)
                if let first = f.steps.first {
                    Text(first).font(.footnote)
                }
            }
        }
    }

    private var recentDrives: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "Recent drives")
                Spacer()
                if drives.records.count > Self.recentCount {
                    NavigationLink("See all") { DriveListView() }.font(.subheadline)
                }
            }
            if drives.records.isEmpty {
                Card {
                    Text("No drives yet.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                ForEach(drives.records.prefix(Self.recentCount)) { r in
                    NavigationLink(value: r.id) { DriveRow(record: r) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private var newDriverRow: some View {
        Button { showNewDriverSetup = true } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("New driver?").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text("Log permit hours and import your paper log.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct DriveRow: View {
    @Environment(AppModel.self) private var model
    var record: DriveRecord

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(Fmt.day.string(from: record.startedAt)).font(.subheadline.weight(.semibold))
                HStack(spacing: 6) {
                    Text(Fmt.time.string(from: record.startedAt))
                    Text("·")
                    Text(Fmt.miles(record.distanceM))
                    if record.hasVideo { Text("· video") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.processing.contains(record.id) {
                ProgressView().controlSize(.small)
                Text("Scoring…").font(.caption).foregroundStyle(.secondary)
            } else if record.processed {
                EfficiencyChip(score: record.efficiencyScore)
                SafetyChip(score: record.safetyScore)
            } else if record.processingError != nil {
                Text("Not scored").font(.caption).foregroundStyle(.orange)
            } else {
                Text("Pending").font(.caption).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }
}

struct DriveListView: View {
    @Environment(AppModel.self) private var model
    @Environment(DriveStore.self) private var drives

    private struct MonthGroup: Identifiable {
        var id: String
        var rows: [DriveRecord]
    }

    private var grouped: [MonthGroup] {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"
        var groups: [MonthGroup] = []
        for r in drives.records {
            let k = f.string(from: r.startedAt)
            if let i = groups.firstIndex(where: { $0.id == k }) { groups[i].rows.append(r) } else { groups.append(MonthGroup(id: k, rows: [r])) }
        }
        return groups
    }

    var body: some View {
        List {
            ForEach(grouped) { group in
                Section(group.id) {
                    ForEach(group.rows) { r in
                        NavigationLink { DriveDetailView(driveId: r.id) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(Fmt.dayTime.string(from: r.startedAt)).font(.subheadline)
                                    Text("\(Fmt.miles(r.distanceM)) · \(Fmt.duration(r.durationS)) · \(r.eventCount) events")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if r.processed {
                                    EfficiencyChip(score: r.efficiencyScore)
                                    SafetyChip(score: r.safetyScore)
                                }
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { model.deleteDrive(r) } label: { Text("Delete") }
                        }
                    }
                }
            }
        }
        .overlay {
            if drives.records.isEmpty {
                ContentUnavailableView { Text("No drives yet") } description: { Text("Recorded drives appear here.") }
            }
        }
        .navigationTitle("All drives")
    }
}
