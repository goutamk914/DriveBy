//  HoursLogView.swift — Driveby
//  The "Hours" tab: supervised practice time toward the learner's-permit requirement
//  (Virginia, under 18: 45 hours, 15 of them after sunset). Recorded drives are logged automatically;
//  drives done without the app can be added by hand. Export as CSV or a printable PDF.

import SwiftUI

struct HoursLogView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(PracticeLogStore.self) private var log
    @State private var editing: PracticeLogEntry?
    @State private var editingIsNew = false
    @State private var showTargets = false
    @State private var importPaperLog = false
    @State private var csvURL: URL?
    @State private var pdfURL: URL?

    var body: some View {
        NavigationStack {
            List {
                Section { progressCard.listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }

                Section {
                    if log.entries.isEmpty {
                        Text("Your supervised drives show up here automatically after each recording. Drove without the app, or logging on paper? Tap + to add it.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(log.entries) { e in
                        Button { editingIsNew = false; editing = e } label: { row(e) }
                            .buttonStyle(.plain)
                    }
                    .onDelete { idx in
                        let ids = idx.map { log.entries[$0].id }
                        ids.forEach { log.delete($0) }
                    }
                } header: {
                    Text("Sessions")
                } footer: {
                    Text("Night time is worked out from sunset and sunrise where the drive started. Tap a session to fix the supervisor, time or notes.")
                }

                Section {
                    if let pdfURL {
                        ShareLink(item: pdfURL) { Label("Printable log (PDF)", systemImage: "doc.richtext") }
                    }
                    if let csvURL {
                        ShareLink(item: csvURL) { Label("Spreadsheet (CSV)", systemImage: "tablecells") }
                    }
                    TextField("Learner's name (printed on the PDF)", text: Bindable(settings).learnerName)
                        .textContentType(.name)
                } header: { Text("Export") } footer: {
                    Text("Use this record to fill in your state's official driving log — in Virginia, the form your parent or guardian signs. Driveby's log is not the official form.")
                }

                Section { DisclaimerBanner().listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
            }
            .navigationTitle("Practice Hours")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            editingIsNew = true
                            editing = PracticeLogEntry(startedAt: Date().addingTimeInterval(-3600), durationS: 1800, nightS: 0,
                                                       supervisor: settings.defaultSupervisor, manual: true)
                        } label: { Label("Add a drive by hand", systemImage: "square.and.pencil") }
                        Button { importPaperLog = true } label: {
                            Label("Import from a paper log photo", systemImage: "doc.text.viewfinder")
                        }
                    } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add hours")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { showTargets = true } label: { Image(systemName: "target") }
                        .accessibilityLabel("Change hour requirement")
                }
            }
            .sheet(item: $editing) { e in
                PracticeEntryForm(entry: e, isNew: editingIsNew)
            }
            .sheet(isPresented: $showTargets) { NavigationStack { HoursTargetForm(showDone: true) } }
            .sheet(isPresented: $importPaperLog) { PaperLogImportView() }
            .task(id: exportKey) { writeExports() }
        }
    }

    // MARK: Progress

    private var progressCard: some View {
        let h = model.hoursSummary
        return Card {
            HStack(spacing: 20) {
                HoursRing(title: "Total", done: h.totalHours, target: h.requirement.totalHours, tint: Theme.safety)
                HoursRing(title: "After sunset", done: h.nightHours, target: h.requirement.nightHours, tint: .indigo)
            }
            .frame(maxWidth: .infinity)
            if h.complete {
                Label("Requirement met — ask your parent or guardian to sign your official log.", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.efficiency)
            } else {
                Text(remainingText(h)).font(.subheadline)
            }
            Text("Requirement: \(h.requirement.label) — \(Int(h.requirement.totalHours)) h supervised, \(Int(h.requirement.nightHours)) h after sunset.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func remainingText(_ h: HoursSummary) -> String {
        var parts: [String] = []
        if h.totalRemaining > 0 { parts.append(String(format: "%.1f more hours in total", h.totalRemaining)) }
        if h.nightRemaining > 0 { parts.append(String(format: "%.1f more after sunset", h.nightRemaining)) }
        return parts.joined(separator: " · ")
    }

    private func row(_ e: PracticeLogEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: e.nightS >= 60 ? "moon.stars.fill" : "sun.max.fill")
                .foregroundStyle(e.nightS >= 60 ? Color.indigo : Color.orange)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(Fmt.dayTime.string(from: e.startedAt)).font(.subheadline.weight(.semibold))
                Text("Supervisor: \(e.supervisor.isEmpty ? "not set" : e.supervisor)")
                    .font(.caption).foregroundStyle(e.supervisor.isEmpty ? Color.orange : Color.secondary)
                if !e.notes.isEmpty { Text(e.notes).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(HoursSummary.hoursString(e.durationS)).font(.subheadline.monospacedDigit().weight(.semibold))
                if e.nightS >= 60 {
                    Text("\(HoursSummary.hoursString(e.nightS)) night").font(.caption.monospacedDigit()).foregroundStyle(.indigo)
                }
                Text(e.manual ? "Added by hand" : "Recorded").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: Export

    private struct ExportKey: Hashable {
        var entries: [PracticeLogEntry]; var learner: String; var total: Double; var night: Double
    }

    private var exportKey: ExportKey {
        ExportKey(entries: log.entries, learner: settings.learnerName, total: settings.hoursTotalTarget, night: settings.hoursNightTarget)
    }

    private func writeExports() {
        let root = Storage.exportsRoot
        let csv = root.appendingPathComponent("driveby_practice_hours.csv")
        let pdf = root.appendingPathComponent("driveby_practice_hours.pdf")
        try? PracticeLogCSV.csv(log.entries).data(using: .utf8)?.write(to: csv, options: .atomic)
        try? PracticeLogPDF.render(entries: log.entries, summary: model.hoursSummary, learner: settings.learnerName)
            .write(to: pdf, options: .atomic)
        csvURL = csv
        pdfURL = pdf
    }
}

/// Ring showing hours done / target.
struct HoursRing: View {
    var title: String
    var done: Double
    var target: Double
    var tint: Color
    var size: CGFloat = 110

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(tint.opacity(0.15), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: CGFloat(target > 0 ? min(done / target, 1) : 0))
                    .stroke(tint, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text(String(format: "%.1f", done)).font(.system(size: size * 0.26, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("of \(Int(target)) h").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: size, height: size)
            Text(title).font(.subheadline.weight(.semibold))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: "%@: %.1f of %.0f hours", title, done, target))
    }
}

/// Add or edit a logged session.
struct PracticeEntryForm: View {
    @State var entry: PracticeLogEntry
    var isNew: Bool
    @Environment(PracticeLogStore.self) private var log
    @Environment(\.dismiss) private var dismiss
    @State private var minutes: Int = 30
    @State private var nightMinutes: Int = 0
    @State private var autoNight = true

    /// Longest single session that can be entered by hand (10 h). An imported paper log can be longer —
    /// its own length stays reachable when it's edited.
    private static let maxSessionMinutes = 600
    private var maxMinutes: Int { max(Self.maxSessionMinutes, Int((entry.durationS / 60).rounded())) }

    var body: some View {
        NavigationStack {
            Form {
                Section("When") {
                    DatePicker("Started", selection: $entry.startedAt, in: ...Date())
                    Stepper(value: $minutes, in: 5...maxMinutes, step: 5) {
                        LabeledContent("Duration", value: HoursSummary.hoursString(Double(minutes) * 60))
                    }
                    if entry.manual {
                        Toggle("Work out night time from sunset (Virginia)", isOn: $autoNight)
                    }
                    if !entry.manual || !autoNight {
                        Stepper(value: $nightMinutes, in: 0...minutes, step: 5) {
                            LabeledContent("After sunset", value: HoursSummary.hoursString(Double(nightMinutes) * 60))
                        }
                    } else {
                        LabeledContent("After sunset", value: HoursSummary.hoursString(estimatedNight))
                    }
                }
                Section {
                    TextField("Supervisor's name", text: $entry.supervisor).textContentType(.name)
                } header: { Text("Supervising driver") } footer: {
                    Text("Licensed driver 21+, parent or legal guardian, or licensed sibling 18+, in the front passenger seat.")
                }
                Section("Notes") {
                    TextField("Roads, weather, what you practised…", text: $entry.notes, axis: .vertical).lineLimit(2...5)
                }
                if !entry.manual {
                    Section {
                        Text("Recorded by Driveby. You can correct the supervisor, notes or times if something's off.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !isNew {
                    Section {
                        Button("Delete session", role: .destructive) { log.delete(entry.id); dismiss() }
                    }
                }
            }
            .navigationTitle(isNew ? "Add a drive" : "Edit session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(entry.supervisor.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                minutes = max(Int((entry.durationS / 60).rounded()), 5)
                nightMinutes = Int((entry.nightS / 60).rounded())
                autoNight = entry.manual && isNew
            }
            .onChange(of: minutes) { _, m in nightMinutes = min(nightMinutes, m) }
        }
    }

    /// Manual entries have no GPS — use central Virginia for the sunset estimate.
    private var estimatedNight: Double {
        Solar.nightSeconds(from: entry.startedAt, to: entry.startedAt.addingTimeInterval(Double(minutes) * 60),
                           lat: 37.54, lon: -77.43)
    }

    private func save() {
        entry.durationS = Double(minutes) * 60
        entry.nightS = (entry.manual && autoNight) ? estimatedNight : Double(nightMinutes) * 60
        entry.supervisor = entry.supervisor.trimmingCharacters(in: .whitespacesAndNewlines)
        log.upsert(entry)
        dismiss()
    }
}

/// Change the hours requirement (other states / age groups).
struct HoursTargetForm: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    /// True when presented as a sheet (pushed from Settings it uses the back button instead).
    var showDone = false

    var body: some View {
        @Bindable var s = settings
        Form {
                Section {
                    Stepper(value: $s.hoursTotalTarget, in: 0...200, step: 5) {
                        LabeledContent("Total hours", value: "\(Int(s.hoursTotalTarget))")
                    }
                    Stepper(value: $s.hoursNightTarget, in: 0...100, step: 1) {
                        LabeledContent("After sunset", value: "\(Int(s.hoursNightTarget))")
                    }
                    Button("Use Virginia (under 18): 45 h, 15 at night") {
                        s.hoursTotalTarget = 45; s.hoursNightTarget = 15
                    }
                } footer: {
                    Text("Virginia requires drivers under 18 to log 45 hours of supervised driving, 15 after sunset, before the road test. Check your state's DMV for its rules.")
                }
        }
        .navigationTitle("Hour requirement")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if showDone { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } } }
    }
}
