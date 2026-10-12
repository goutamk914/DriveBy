//  DriveDetailView.swift — Driveby
//  Route map with coloured event pins · two score rings + component breakdown ·
//  scrollable, tappable event timeline. Tapping an event is the whole app.

import MapKit
import SwiftUI

struct DriveDetailView: View {
    let driveId: UUID
    @Environment(AppModel.self) private var model
    @Environment(DriveStore.self) private var drives
    @Environment(GarageStore.self) private var garage
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var exportURL: URL?
    @State private var exporting = false
    @State private var selectedMoment: DriveMoment?
    @State private var showReflection = false
    @State private var snappedRoute: [[Double]]?

    var body: some View {
        Group {
            if let r = drives.record(driveId) {
                content(r)
            } else {
                ContentUnavailableView("Drive deleted", systemImage: "trash")
            }
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func content(_ r: DriveRecord) -> some View {
        let analysis = drives.analysis(r)
        ScrollView {
            VStack(spacing: 16) {
                header(r, analysis)
                if model.processing.contains(r.id) {
                    Card { HStack { ProgressView(); Text("Scoring this drive…").foregroundStyle(.secondary) } }
                } else if let err = r.processingError {
                    Card {
                        Label(err, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Button("Try again") { model.reprocess(r) }.buttonStyle(.bordered)
                    }
                }
                if let a = analysis {
                    routeMap(a)
                    scores(r, a)
                    timeline(r, a)
                    breakdown(a)
                    notes(r, a)
                }
                actions(r)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle(Fmt.day.string(from: r.startedAt))
        .navigationDestination(item: $selectedMoment) { m in
            MomentDetailView(record: r, moment: m)
        }
        .sheet(isPresented: $showReflection) { ReflectionView(driveId: r.id) }
        .task(id: r.id) { await loadSnappedRoute(r, analysis) }
        .confirmationDialog("Delete this drive?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete drive", role: .destructive) { model.deleteDrive(r); dismiss() }
        } message: {
            Text("Removes the video, clips, sensor log and scores from this phone (and from your cloud account if synced).")
        }
    }

    // MARK: Sections

    private func header(_ r: DriveRecord, _ a: DriveAnalysis?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(Fmt.dayTime.string(from: r.startedAt)).font(.headline)
                Text(subtitle(r, a))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.top, 8)
    }

    private func subtitle(_ r: DriveRecord, _ a: DriveAnalysis?) -> String {
        var parts = [Fmt.miles(r.distanceM), Fmt.duration(r.durationS)]
        if let a { parts.append("max \(Fmt.mph(a.maxSpeedMps))") }
        if let n = garage.vehicle(r.vehicleId)?.displayName { parts.append(n) }
        return parts.joined(separator: " · ")
    }

    private func routeMap(_ a: DriveAnalysis) -> some View {
        let coords = (snappedRoute ?? a.trace.map { [$0.lat, $0.lon] }).map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
        let pinned = visibleMoments(a).filter { $0.lat != nil && $0.lon != nil }
        return Map(initialPosition: .automatic) {
            MapPolyline(coordinates: coords).stroke(.blue, lineWidth: 4)
            if let first = coords.first {
                Annotation("Start", coordinate: first) { Circle().fill(.green).frame(width: 12, height: 12).overlay(Circle().stroke(.white, lineWidth: 2)) }
                    .annotationTitles(.hidden)
            }
            if let last = coords.last {
                Annotation("End", coordinate: last) { Circle().fill(.black).frame(width: 12, height: 12).overlay(Circle().stroke(.white, lineWidth: 2)) }
                    .annotationTitles(.hidden)
            }
            ForEach(pinned) { m in
                Annotation(m.kind.title, coordinate: CLLocationCoordinate2D(latitude: m.lat ?? 0, longitude: m.lon ?? 0)) {
                    Button { selectedMoment = m } label: { MomentBadge(kind: m.kind, size: 26) }
                        .buttonStyle(.plain)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .frame(height: 260)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func scores(_ r: DriveRecord, _ a: DriveAnalysis) -> some View {
        Card {
            HStack(alignment: .top) {
                ScoreRing(title: "Efficiency", score: r.efficiencyScore, tint: Theme.efficiency,
                          caption: "Validated against real fuel data — see Trends")
                    .frame(maxWidth: .infinity)
                ScoreRing(title: "Safety", score: a.safety.score, tint: Theme.safety,
                          caption: "Built from telematics thresholds — not validated (no crash data)")
                    .frame(maxWidth: .infinity)
            }
            if let mpg = a.obdMPG {
                Label(String(format: "OBD-II measured %.1f mpg this drive (%.2f gal)", mpg, a.obdFuelGal ?? 0), systemImage: "fuelpump.fill")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func visibleMoments(_ a: DriveAnalysis) -> [DriveMoment] {
        let all = a.moments(pricePerGallon: model.pricePerGallon)
        return settings.driverMode == .newDriver ? all : all.filter(\.isSignificant)
    }

    private func timeline(_ r: DriveRecord, _ a: DriveAnalysis) -> some View {
        Card {
            HStack {
                SectionHeader(title: "Timeline",
                              subtitle: settings.driverMode == .newDriver ? "Good moments and things to work on — tap any to replay it"
                                                                         : "Significant issues only (Advanced mode)")
                Spacer()
            }
            MomentTimeline(moments: visibleMoments(a), tripStartT: a.tripStartT) { selectedMoment = $0 }
            Button { showReflection = true } label: {
                Label("Post-drive reflection", systemImage: "text.bubble.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func loadSnappedRoute(_ r: DriveRecord, _ a: DriveAnalysis?) async {
        guard let a, let key = GoogleMaps.apiKey(settings: settings) else { return }
        if let cached = GoogleMapsCache.shared.routes[r.id] { snappedRoute = cached; return }
        if let snapped = await GoogleMaps.snapToRoads(a.trace.map { [$0.lat, $0.lon] }, key: key) {
            GoogleMapsCache.shared.routes[r.id] = snapped
            snappedRoute = snapped
        }
    }

    private func breakdown(_ a: DriveAnalysis) -> some View {
        let points = model.model.penaltyPoints(a.components)
        let norm = model.model.normalized(a.components)
        return Card {
            SectionHeader(title: "Efficiency breakdown", subtitle: "Points lost per component (weights: \(model.model.source))")
            ForEach(EfficiencyComponents.keys, id: \.self) { k in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(EfficiencyComponents.label(k)).font(.subheadline)
                        Spacer()
                        Text(String(format: "−%.1f", points[k] ?? 0)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    ProgressView(value: norm[k] ?? 0).tint(Theme.efficiency)
                    Text(EfficiencyComponents.explanation(k)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Divider()
            SectionHeader(title: "Safety breakdown", subtitle: "Event points are per 10 miles so long drives aren't penalised for length")
            InfoRow(label: "Hard braking", value: String(format: "−%.1f", a.safety.hardBrakePoints))
            InfoRow(label: "Sharp turns", value: String(format: "−%.1f", a.safety.harshCornerPoints))
            InfoRow(label: "Speeding (\(Int((a.safety.speedingFraction * 100).rounded()))% of moving time)", value: String(format: "−%.1f", a.safety.speedingPoints))
            InfoRow(label: "Tailgating (\(Int((a.safety.tailgatingFraction * 100).rounded()))% of moving time)", value: String(format: "−%.1f", a.safety.tailgatingPoints))
        }
    }

    private struct Note: Identifiable {
        var symbol: String
        var text: String
        var id: String { text }
    }

    private func noteItems(_ r: DriveRecord, _ a: DriveAnalysis) -> [Note] {
        var items: [Note] = []
        if !a.speedLimitsAvailable {
            items.append(Note(symbol: "wifi.slash", text: "Speed limits weren't available when this drive was scored, so speeding wasn't checked."))
        }
        if drives.sidecar(r)?.videoInterrupted == true {
            items.append(Note(symbol: "video.slash", text: "The camera stopped part-way (phone locked, call or heat). Sensors kept recording; later events have no clip."))
        }
        if !a.tailgatingAvailable && r.hasVideo {
            items.append(Note(symbol: "car.2", text: "No vehicles were detected ahead, so following distance couldn't be measured."))
        }
        if a.malformedLines > 0 {
            items.append(Note(symbol: "doc.badge.ellipsis", text: "\(a.malformedLines) damaged sensor line(s) were skipped (e.g. the phone shut down mid-write)."))
        }
        return items
    }

    @ViewBuilder
    private func notes(_ r: DriveRecord, _ a: DriveAnalysis) -> some View {
        let items = noteItems(r, a)
        if !items.isEmpty {
            Card {
                ForEach(items) { item in
                    Label(item.text, systemImage: item.symbol).font(.footnote).foregroundStyle(.secondary)
                }
                if !a.speedLimitsAvailable {
                    Button("Retry speed limits") { model.reprocess(r) }.buttonStyle(.bordered)
                }
            }
        }
    }

    private func actions(_ r: DriveRecord) -> some View {
        Card {
            if r.hasVideo, drives.videoURL(r) != nil {
                NavigationLink { PrivacyAuditView(record: r) } label: {
                    Label("Privacy spot-check (20 random frames)", systemImage: "eye.slash")
                }
            }
            if let url = exportURL {
                ShareLink(item: url) { Label("Share \(url.lastPathComponent)", systemImage: "square.and.arrow.up") }
            } else {
                Button {
                    exporting = true
                    Task {
                        exportURL = await DriveExport.zip(folder: drives.folderURL(r), name: r.folder)
                        exporting = false
                    }
                } label: {
                    HStack {
                        Label("Export raw data for the Python processor", systemImage: "shippingbox")
                        if exporting { Spacer(); ProgressView() }
                    }
                }
                .disabled(exporting)
            }
            Button("Re-score this drive") { model.reprocess(r) }
            Button("Delete drive", role: .destructive) { confirmDelete = true }
        }
        .buttonStyle(.borderless)
    }
}

struct SeverityBar: View {
    var value: Double
    var tint: Color
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                Capsule().fill(Double(i) < max(value * 5, 0.6) ? tint : tint.opacity(0.18)).frame(width: 14, height: 5)
            }
        }
        .accessibilityLabel("Severity \(Int((value * 100).rounded())) percent")
    }
}

enum DriveExport {
    /// Zips a drive folder (drive.json, sensors JSONL, blurred video, analysis.json) for AirDrop / Files.
    static func zip(folder: URL, name: String) async -> URL? {
        await Task.detached(priority: .userInitiated) {
            var result: URL?
            var coordError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading], error: &coordError) { zipURL in
                let dst = Storage.exportsRoot.appendingPathComponent("\(name).zip")
                try? FileManager.default.removeItem(at: dst)
                if (try? FileManager.default.copyItem(at: zipURL, to: dst)) != nil { result = dst }
            }
            return result
        }.value
    }
}
