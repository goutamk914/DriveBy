//  HazardMapView.swift — Driveby
//  The civic payload — individual input → shared public resource.
//  "Your data stays yours. But stripped of everything identifying and pooled together, it becomes
//   a map of the intersections where drivers brake hardest — something a county traffic engineer
//   could actually act on."

import MapKit
import SwiftUI

struct HazardMapView: View {
    @Environment(AppModel.self) private var model
    @Environment(SyncService.self) private var sync
    @Environment(DriveStore.self) private var drives
    @State private var showPublic = true
    @State private var showMine = true
    @State private var selection: Selection?
    @State private var exportGeoJSON: URL?
    @State private var exportCSV: URL?
    @State private var showHow = false
    @State private var position: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 39.03, longitude: -77.52),       // Loudoun County, VA-10
        span: MKCoordinateSpan(latitudeDelta: 0.35, longitudeDelta: 0.35)))

    enum Selection: Identifiable {
        case published(HazardCell)
        case mine(LocalHazardCell)
        var id: String {
            switch self {
            case .published(let c): return "p" + c.cellKey
            case .mine(let c): return "m" + c.cellKey
            }
        }
    }

    var body: some View {
        let mine = showMine ? model.localHazardCells() : []
        let published = showPublic ? sync.hazardCells : []
        NavigationStack {
            ZStack(alignment: .bottom) {
                map(published: published, mine: mine)
                legend(publishedCount: sync.hazardCells.count, mineCount: mine.count)
            }
            .navigationTitle("Hazard Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showHow = true } label: { Image(systemName: "questionmark.circle") }
                        .accessibilityLabel("How the hazard map works")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Published cells", isOn: $showPublic)
                        Toggle("My contributions", isOn: $showMine)
                    } label: { Image(systemName: "square.3.layers.3d") }
                    exportMenu
                    Button { Task { await sync.refreshHazardCells() } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Refresh")
                }
            }
            .sheet(item: $selection) { sel in
                CellDetail(selection: sel).presentationDetents([.fraction(0.32), .medium])
            }
            .sheet(isPresented: $showHow) { HazardExplainer().presentationDetents([.large]) }
            .task(id: sync.hazardCells.count) { writeExports() }
            .task { if sync.hazardCells.isEmpty { await sync.refreshHazardCells() } }
        }
    }

    private func map(published: [HazardCell], mine: [LocalHazardCell]) -> some View {
        let maxCount = Double(max(published.map(\.eventCount).max() ?? 1, 1))
        return Map(position: $position) {
            ForEach(published) { c in
                MapPolygon(coordinates: square(c.lat, c.lon))
                    .stroke(Color.red, lineWidth: 1)
                    .foregroundStyle(Color.red.opacity(0.25 + 0.55 * Double(c.eventCount) / maxCount))
                Annotation(c.cellKey, coordinate: CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon)) {
                    Button { selection = .published(c) } label: {
                        Text("\(c.eventCount)").font(.caption2.weight(.bold)).foregroundStyle(.white)
                            .frame(width: 22, height: 22).background(Color.red, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .annotationTitles(.hidden)
            }
            ForEach(mine) { c in
                MapPolygon(coordinates: square(c.lat, c.lon))
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .foregroundStyle(Color.blue.opacity(0.18))
                Annotation(c.cellKey, coordinate: CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon), anchor: .bottom) {
                    Button { selection = .mine(c) } label: {
                        Image(systemName: "person.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 18, height: 18).background(Color.blue, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControls { MapUserLocationButton(); MapCompass(); MapScaleView() }
    }

    private func square(_ lat: Double, _ lon: Double) -> [CLLocationCoordinate2D] {
        let h = Thresholds.hazardCell / 2
        return [CLLocationCoordinate2D(latitude: lat - h, longitude: lon - h), CLLocationCoordinate2D(latitude: lat - h, longitude: lon + h),
                CLLocationCoordinate2D(latitude: lat + h, longitude: lon + h), CLLocationCoordinate2D(latitude: lat + h, longitude: lon - h)]
    }

    private func legend(publishedCount: Int, mineCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Label("\(publishedCount) published", systemImage: "square.fill").foregroundStyle(.red)
                Label("\(mineCount) yours (private)", systemImage: "square.dashed").foregroundStyle(.blue)
            }
            .font(.caption.weight(.semibold))
            Text(sync.isConfigured
                 ? "A cell is published only with ≥\(Thresholds.kEvents) hard-braking/sharp-turn events from ≥\(Thresholds.kUsers) different drivers (k-anonymity). Counts only — no names, no trip times."
                 : "Cloud isn't configured in this build, so only your own (private) cells show. Published cells need ≥\(Thresholds.kEvents) events from ≥\(Thresholds.kUsers) drivers.")
                .font(.caption2).foregroundStyle(.secondary)
            if let err = sync.hazardError { Text(err).font(.caption2).foregroundStyle(.orange) }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(12)
    }

    @ViewBuilder private var exportMenu: some View {
        Menu {
            if let g = exportGeoJSON {
                ShareLink(item: g) { Label("GeoJSON (for VDOT / county GIS)", systemImage: "map") }
            }
            if let c = exportCSV {
                ShareLink(item: c) { Label("CSV", systemImage: "tablecells") }
            }
            if exportGeoJSON == nil { Text("No published cells to export yet") }
        } label: { Image(systemName: "square.and.arrow.up") }
        .accessibilityLabel("Export hazard data")
    }

    private func writeExports() {
        let cells = sync.hazardCells
        guard !cells.isEmpty else { exportGeoJSON = nil; exportCSV = nil; return }
        let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let g = Storage.exportsRoot.appendingPathComponent("driveby_hazard_cells_\(stamp).geojson")
        let c = Storage.exportsRoot.appendingPathComponent("driveby_hazard_cells_\(stamp).csv")
        try? GeoJSON.hazardFeatureCollection(cells).write(to: g, options: .atomic)
        try? GeoJSON.hazardCSV(cells).data(using: .utf8)?.write(to: c, options: .atomic)
        exportGeoJSON = g
        exportCSV = c
    }
}

private struct CellDetail: View {
    let selection: HazardMapView.Selection
    @Environment(\.openURL) private var openURL

    private var coordinate: (lat: Double, lon: Double) {
        switch selection {
        case .published(let c): return (c.lat, c.lon)
        case .mine(let c): return (c.lat, c.lon)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch selection {
            case .published(let c):
                Label("Published hazard cell", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.headline)
                Text(c.summary).font(.title3.weight(.semibold))
                Text("Pooled, anonymised data from everyone who opted in. Cell \(c.cellKey) (≈55 m square).")
                    .font(.footnote).foregroundStyle(.secondary)
            case .mine(let c):
                Label("Your contribution (private)", systemImage: "person.fill").foregroundStyle(.blue).font(.headline)
                let hb = c.kindCounts[.hardBrake] ?? 0, hc = c.kindCounts[.harshCorner] ?? 0
                Text("\(c.eventCount) event\(c.eventCount == 1 ? "" : "s") here across \(c.driveCount) of your drives (\(hb) hard braking, \(hc) sharp turns).")
                    .font(.title3.weight(.semibold))
                Text("This cell can be published only when at least \(Thresholds.kEvents) events from at least \(Thresholds.kUsers) different drivers land in it. Your data alone can never publish a cell — that's the point.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            // Look at the intersection before you drive it again.
            HStack {
                Button { openURL(GoogleMaps.mapsURL(lat: coordinate.lat, lon: coordinate.lon)) } label: {
                    Label("Google Maps", systemImage: "map").frame(maxWidth: .infinity)
                }
                Button { openURL(GoogleMaps.streetViewURL(lat: coordinate.lat, lon: coordinate.lon)) } label: {
                    Label("Street View", systemImage: "binoculars.fill").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HazardExplainer: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Your data stays yours. But stripped of everything identifying and pooled together, it becomes a map of the intersections where drivers brake hardest — something a county traffic engineer could actually act on.")
                        .font(.title3.weight(.semibold))
                    explainer("1. Private by default", "Every drive is stored on your phone. If you sign in, only numbers (scores and event locations) sync to your private account — protected so only you can read them.")
                    explainer("2. Pooled into ≈55 m cells", "Hard-braking and sharp-turn events are rounded into grid cells about 55 metres across.")
                    explainer("3. k-anonymity", "A cell is published only when it has at least \(Thresholds.kEvents) events from at least \(Thresholds.kUsers) different drivers. The public table stores counts — never a user ID, never a trip time.")
                    explainer("4. Shareable with the people who can fix it", "Export the published cells as GeoJSON — the format county traffic engineering and VDOT GIS tools already use.")
                    explainer("Honest about scale", "Right now most of this is our own driving. The point is the architecture: at scale, it's a map no individual driver could produce, built from data no individual driver had to surrender.")
                    explainer("Opt out any time", "Settings → Privacy → Contribute to the hazard map.")
                }
                .padding(20)
            }
            .navigationTitle("How the hazard map works")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func explainer(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(body).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}
