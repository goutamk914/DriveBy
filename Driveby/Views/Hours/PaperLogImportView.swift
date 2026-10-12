//  PaperLogImportView.swift — Driveby
//  "Already logging on paper?" Snap or pick a photo of the log; Driveby reads the hours on the phone
//  (LogScanner + PaperLog), shows what it found, and the driver confirms or corrects the numbers
//  before they're added to the hours log as one entry. The photo itself is never stored.

import PhotosUI
import SwiftUI

struct PaperLogImportView: View {
    var onImported: ((PracticeLogEntry) -> Void)? = nil

    @Environment(PracticeLogStore.self) private var log
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showScanner = false
    @State private var pages: [UIImage] = []
    @State private var reading = false
    @State private var estimate: PaperLog.Estimate?
    @State private var error: String?
    @State private var totalMinutes = 0
    @State private var nightMinutes = 0
    @State private var supervisor = ""
    @State private var loggedThrough = Date()
    @State private var readToken: UUID?

    private static let maxPages = 5
    private static let minuteStep = 15
    private static let maxMinutes = Int(PaperLog.maxTotalMinutes)

    var body: some View {
        NavigationStack {
            Form {
                sourceSection
                if reading {
                    Section { HStack(spacing: 12) { ProgressView(); Text("Reading your log…").foregroundStyle(.secondary) } }
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                }
                if let estimate { resultSections(estimate) }
            }
            .navigationTitle("Import paper log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { save() }.disabled(estimate == nil || totalMinutes <= 0)
                }
            }
            .onChange(of: pickerItems) { _, items in Task { await loadPhotos(items) } }
            .fullScreenCover(isPresented: $showScanner) {
                DocumentScanner(
                    onScan: { images in showScanner = false; error = nil; Task { await read(images) } },
                    onCancel: { showScanner = false },
                    onError: { e in showScanner = false; error = "The scanner stopped: \(e.localizedDescription)" }
                )
                .ignoresSafeArea()
            }
            .onAppear { if supervisor.isEmpty { supervisor = settings.defaultSupervisor } }
        }
    }

    // MARK: Sections

    private var sourceSection: some View {
        Section {
            if pages.isEmpty {
                Label("Take a photo of your driving log and Driveby will count the hours. The photo stays on your phone and isn't saved.",
                      systemImage: "doc.text.viewfinder")
                    .font(.subheadline)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pages.indices, id: \.self) { i in
                            Image(uiImage: pages[i]).resizable().scaledToFill()
                                .frame(width: 70, height: 92)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .accessibilityLabel("Page \(i + 1)")
                        }
                    }
                }
            }
            if DocumentScanner.isSupported {
                Button { showScanner = true } label: { Label("Scan with camera", systemImage: "camera.viewfinder") }
            }
            PhotosPicker(selection: $pickerItems, maxSelectionCount: Self.maxPages, matching: .images) {
                Label(pages.isEmpty ? "Choose from Photos" : "Choose different photos", systemImage: "photo.on.rectangle")
            }
        } footer: {
            Text("Up to \(Self.maxPages) pages. Works best flat, in good light, with the hours column in view.")
        }
    }

    @ViewBuilder
    private func resultSections(_ e: PaperLog.Estimate) -> some View {
        Section {
            Text(summary(e)).font(.subheadline)
            Stepper(value: $totalMinutes, in: 0...Self.maxMinutes, step: Self.minuteStep) {
                LabeledContent("Total", value: HoursSummary.hoursString(Double(totalMinutes) * 60))
            }
            Stepper(value: $nightMinutes, in: 0...max(totalMinutes, 0), step: Self.minuteStep) {
                LabeledContent("After sunset", value: HoursSummary.hoursString(Double(nightMinutes) * 60))
            }
            DatePicker("Logged up to", selection: $loggedThrough, in: ...Date(), displayedComponents: .date)
            TextField("Supervisor (optional)", text: $supervisor).textContentType(.name)
        } header: {
            Text("Hours found")
        } footer: {
            Text("Check these against your log and adjust if needed — you know it better than the camera does.")
        }
        .onChange(of: totalMinutes) { _, t in nightMinutes = min(nightMinutes, t) }

        if !e.sessions.isEmpty {
            Section {
                DisclosureGroup("What Driveby read (\(e.sessions.count) session\(e.sessions.count == 1 ? "" : "s"))") {
                    ForEach(Array(e.sessions.enumerated()), id: \.offset) { _, s in
                        HStack {
                            Text(s.line).font(.caption).lineLimit(1)
                            Spacer()
                            if s.night { Image(systemName: "moon.stars.fill").foregroundStyle(.indigo).font(.caption) }
                            Text(HoursSummary.hoursString(s.minutes * 60)).font(.caption.monospacedDigit())
                        }
                    }
                }
            }
        }
    }

    private func summary(_ e: PaperLog.Estimate) -> String {
        if e.isEmpty { return "Couldn't find any hours in this photo. Enter them below, or try a clearer photo." }
        if e.fromWrittenTotal { return "Found the total written on your log." }
        return "Added up \(e.sessions.count) session\(e.sessions.count == 1 ? "" : "s") from your log."
    }

    // MARK: Reading

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        error = nil
        var images: [UIImage] = []
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                    error = "One of those photos couldn't be opened."
                    continue
                }
                images.append(image)
            } catch {
                self.error = "Couldn't load a photo: \(error.localizedDescription)"
            }
        }
        await read(images)
    }

    /// Reads the pages; if newer photos are picked meanwhile, this (older) result is dropped.
    private func read(_ images: [UIImage]) async {
        guard !images.isEmpty else { return }
        let token = UUID()
        readToken = token
        pages = images
        reading = true
        do {
            let lines = try await LogScanner.lines(from: images)
            guard readToken == token else { return }
            let e = PaperLog.estimate(lines: lines)
            estimate = e
            totalMinutes = Self.rounded(e.totalMinutes)
            nightMinutes = min(Self.rounded(e.nightMinutes), totalMinutes)
        } catch {
            guard readToken == token else { return }
            self.error = "Couldn't read that log: \(error.localizedDescription)"
        }
        reading = false
    }

    /// Steppers move in 15-minute steps; start them on one.
    private static func rounded(_ minutes: Double) -> Int {
        Int((minutes / Double(minuteStep)).rounded()) * minuteStep
    }

    private func save() {
        let name = supervisor.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessions = estimate?.sessions.count ?? 0
        let entry = PracticeLogEntry(startedAt: loggedThrough, durationS: Double(totalMinutes) * 60, nightS: Double(nightMinutes) * 60,
                                     supervisor: name.isEmpty ? "Paper log" : name,
                                     notes: sessions > 0 ? "Imported from paper log (\(sessions) sessions)" : "Imported from paper log",
                                     manual: true)
        log.upsert(entry)
        onImported?(entry)
        dismiss()
    }
}
