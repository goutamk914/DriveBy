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
        center: CLLocationCoordinate2D(latitude: 39.03, longitude: -77.52),
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
                    Button { showHow = true } label: { Text("About") }
                        .accessibilityLabel("How the hazard map works")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Published cells", isOn: $showPublic)
                        Toggle("My contributions", isOn: $showMine)
                    } label: { Text("Layers") }
                    exportMenu
                    Button { Task { await sync.refreshHazardCells() } } label: { Text("Refresh") }
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
                        Circle().fill(Color.blue).frame(width: 14, height: 14).overlay(Circle().stroke(.white, lineWidth: 2))
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
                Text("\(publishedCount) published").foregroundStyle(.red)
                Text("\(mineCount) yours (private)").foregroundStyle(.blue)
            }
            .font(.caption.weight(.semibold))
            Text(sync.isConfigured
                 ? "Published at ≥\(Thresholds.kEvents) events from ≥\(Thresholds.kUsers) drivers."
                 : "Cloud is off. Only your cells show.")
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
                ShareLink(item: g) { Text("GeoJSON (for VDOT / county GIS)") }
            }
            if let c = exportCSV {
                ShareLink(item: c) { Text("CSV") }
            }
            if exportGeoJSON == nil { Text("No published cells to export yet") }
        } label: { Text("Export") }
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
                Text("Published hazard cell").foregroundStyle(.red).font(.headline)
                Text(c.summary).font(.title3.weight(.semibold))
                Text("Anonymous, pooled data. ≈55 m cell.")
                    .font(.footnote).foregroundStyle(.secondary)
            case .mine(let c):
                Text("Your contribution (private)").foregroundStyle(.blue).font(.headline)
                let hb = c.kindCounts[.hardBrake] ?? 0, hc = c.kindCounts[.harshCorner] ?? 0
                Text("\(c.eventCount) event\(c.eventCount == 1 ? "" : "s") here across \(c.driveCount) of your drives (\(hb) hard braking, \(hc) sharp turns).")
                    .font(.title3.weight(.semibold))
                Text("Publishes at \(Thresholds.kEvents) events from \(Thresholds.kUsers) drivers.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            HStack {
                Button { openURL(GoogleMaps.mapsURL(lat: coordinate.lat, lon: coordinate.lon)) } label: {
                    Text("Google Maps").frame(maxWidth: .infinity)
                }
                Button { openURL(GoogleMaps.streetViewURL(lat: coordinate.lat, lon: coordinate.lon)) } label: {
                    Text("Street View").frame(maxWidth: .infinity)
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
                    Text("Where drivers brake hardest, pooled anonymously.")
                        .font(.title3.weight(.semibold))
                    explainer("1. Private by default", "Drives stay on your phone. Synced numbers are private.")
                    explainer("2. Pooled into ≈55 m cells", "Hard brakes and sharp turns are rounded to a grid.")
                    explainer("3. k-anonymity", "Published at ≥\(Thresholds.kEvents) events from ≥\(Thresholds.kUsers) drivers. Counts only.")
                    explainer("4. Shareable", "Export as GeoJSON for county and VDOT tools.")
                    explainer("Opt out any time", "Settings → Privacy.")
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
