import AVFoundation
import Charts
import Observation
import SwiftUI

@MainActor
@Observable
final class ClipPlayback {
    let player: AVPlayer
    private(set) var time: Double = 0
    @ObservationIgnored private var token: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    init(url: URL) {
        player = AVPlayer(url: url)
        player.isMuted = true
        player.actionAtItemEnd = .pause
    }

    func start() {
        guard token == nil else { return }
        token = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.time = CMTimeGetSeconds(t) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.player.seek(to: .zero)
                self?.player.play()
            }
        }
        player.play()
    }

    func stop() {
        player.pause()
        if let token { player.removeTimeObserver(token) }
        token = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    func togglePlay() { player.timeControlStatus == .playing ? player.pause() : player.play() }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: max(seconds, 0), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

struct MomentDetailView: View {
    let record: DriveRecord
    let moment: DriveMoment
    @Environment(AppModel.self) private var model
    @Environment(DriveStore.self) private var drives
    @Environment(AppSettings.self) private var settings
    @Environment(\.openURL) private var openURL
    @State private var playback: ClipPlayback?
    @State private var videoRect: CGRect = .zero
    @State private var leads: [LeadSample] = []
    @State private var showTechnical = false
    @State private var sidecar: DriveSidecar?
    @State private var googlePlace: String?
    @State private var windowPts: [TracePoint] = []

    private var analysis: DriveAnalysis? { drives.analysis(record) }
    private var event: DriveEvent? { moment.eventId.flatMap { id in analysis?.events.first { $0.id == id } } }
    private var isTurn: Bool { moment.kind == .harshCorner || moment.kind == .smoothTurn }
    private var center: Double { event.map { ClipExporter.clipCenter($0) } ?? ClipExporter.clipCenter(moment) }

    private var clipStartSensorT: Double? {
        guard let vStart = sidecar?.videoStartT else { return nil }
        return vStart + ClipExporter.clipStartAsset(center: center, videoStartT: vStart)
    }

    private var playheadT: Double {
        if let start = clipStartSensorT, let p = playback { return start + p.time }
        return moment.t
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                clip
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        MomentBadge(kind: moment.kind, size: 34)
                        Text(moment.headline).font(.headline)
                    }
                    if let place = googlePlace ?? moment.place {
                        Text(place).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text(moment.body).font(.body)
                    if !moment.tip.isEmpty {
                        Text(moment.tip).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if let lat = moment.lat, let lon = moment.lon {
                    HStack {
                        Button { openURL(GoogleMaps.mapsURL(lat: lat, lon: lon)) } label: {
                            Text("Google Maps")
                        }
                        Button { openURL(GoogleMaps.streetViewURL(lat: lat, lon: lon)) } label: {
                            Text("Street View")
                        }
                    }
                    .buttonStyle(.bordered)
                }
                traces
                technical
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle(moment.kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if sidecar == nil { sidecar = drives.sidecar(record) }
            if windowPts.isEmpty { windowPts = traceWindow }
            if playback == nil, let url = drives.clipURL(record, path: moment.clipPath) { playback = ClipPlayback(url: url) }
            playback?.start()
        }
        .onDisappear { playback?.stop() }
        .task { await loadLeads() }
        .task { await loadPlace() }
    }

    @ViewBuilder private var clip: some View {
        if let p = playback {
            ZStack(alignment: .topLeading) {
                PlayerSurface(player: p.player, videoRect: $videoRect)
                overlay
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onTapGesture { p.togglePlay() }
            .accessibilityLabel("Blurred clip of this moment. Tap to pause or play.")
        } else {
            Card {
                Text(record.hasVideo ? "No clip for this moment." : "Sensors only, no video.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var overlay: some View {
        let t = playheadT
        let v = speedAt(t)
        let inMoment = t >= moment.t && t <= moment.tEnd
        return ZStack(alignment: .topLeading) {
            if let lead = nearestLead(t), videoRect.width > 0 {
                let vr = videoRect
                let rect = CGRect(x: vr.minX + CGFloat(lead.bx) * vr.width,
                                  y: vr.minY + CGFloat(lead.by) * vr.height,
                                  width: CGFloat(lead.bw) * vr.width,
                                  height: CGFloat(lead.bh) * vr.height)
                let headway = v > 1 ? lead.dist / v : nil
                let color: Color = (headway ?? 9) < 1 ? .red : (headway ?? 9) < 2 ? .yellow : .green
                Rectangle().stroke(color, lineWidth: 3)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                Text(headway.map { String(format: "%.1f s behind", $0) } ?? String(format: "%.0f m", lead.dist))
                    .font(.caption.weight(.bold)).padding(4)
                    .background(color, in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.black)
                    .position(x: rect.midX, y: max(rect.minY - 14, videoRect.minY + 12))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: "%.0f mph", Units.mph(v))).font(.title2.weight(.bold).monospacedDigit())
                Text(String(format: "%+.2f g", accelAt(t) / 9.81)).font(.caption.monospacedDigit())
            }
            .foregroundStyle(.white)
            .padding(8)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            .padding(10)
            if inMoment {
                RoundedRectangle(cornerRadius: 16).stroke(moment.kind.color, lineWidth: 5)
                Text(moment.kind.title.uppercased())
                    .font(.caption.weight(.heavy)).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(moment.kind.color, in: Capsule()).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(10)
            }
        }
    }

    private var window: (Double, Double) { (center - 10, center + 10) }

    private var traceWindow: [TracePoint] {
        let (lo, hi) = window
        return analysis?.trace.filter { $0.t >= lo && $0.t <= hi } ?? []
    }

    private var traces: some View {
        let pts = windowPts
        let start = analysis?.tripStartT ?? 0
        let tint = moment.kind.color
        return Card {
            SectionHeader(title: "Sensor trace")
            Chart {
                RectangleMark(xStart: .value("Start", moment.t - start), xEnd: .value("End", moment.tEnd - start))
                    .foregroundStyle(tint.opacity(0.15))
                ForEach(pts, id: \.t) { p in
                    LineMark(x: .value("Time", p.t - start), y: .value("Speed (mph)", Units.mph(p.v)))
                        .foregroundStyle(Theme.safety)
                        .interpolationMethod(.monotone)
                }
                if let limit = event?.detail.limitMps {
                    RuleMark(y: .value("Limit", Units.mph(limit))).foregroundStyle(.orange).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .leading) { Text("limit").font(.caption2).foregroundStyle(.orange) }
                }
                RuleMark(x: .value("Now", playheadT - start)).foregroundStyle(Color.primary.opacity(0.6))
            }
            .chartXAxisLabel("seconds into drive")
            .chartYAxisLabel("mph")
            .frame(height: 150)

            Chart {
                RectangleMark(xStart: .value("Start", moment.t - start), xEnd: .value("End", moment.tEnd - start))
                    .foregroundStyle(tint.opacity(0.15))
                ForEach(pts, id: \.t) { p in
                    LineMark(x: .value("Time", p.t - start), y: .value(isTurn ? "Lateral g" : "Accel g", (isTurn ? p.aLat : p.a) / 9.81))
                        .foregroundStyle(tint)
                        .interpolationMethod(.monotone)
                }
                RuleMark(y: .value("Zero", 0.0)).foregroundStyle(Color.secondary.opacity(0.4))
                RuleMark(x: .value("Now", playheadT - start)).foregroundStyle(Color.primary.opacity(0.6))
            }
            .chartYAxisLabel(isTurn ? "sideways g" : "g (− = braking)")
            .frame(height: 120)
            if let p = playback, let clipStart = clipStartSensorT {
                Button {
                    p.seek(to: moment.t - clipStart - 1)
                    p.player.play()
                } label: { Text("Replay the moment") }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var technical: some View {
        Card {
            DisclosureGroup("Technical details", isExpanded: $showTechnical) {
                VStack(alignment: .leading, spacing: 6) {
                    InfoRow(label: "Kind", value: moment.kind.rawValue)
                    if !moment.isPositive { InfoRow(label: "Severity (0-1)", value: String(format: "%.2f", moment.severity)) }
                    InfoRow(label: "Sensor time", value: String(format: "%.1f - %.1f s", moment.t, moment.tEnd))
                    if let e = event {
                        if let p = e.detail.peak { InfoRow(label: "Peak", value: String(format: "%.2f", p)) }
                        if let en = e.detail.energyJ { InfoRow(label: "Energy dissipated", value: String(format: "%.0f kJ", en / 1000)) }
                        if let l = e.detail.limitMps { InfoRow(label: "OSM speed limit", value: Fmt.mph(l)) }
                        if let h = e.detail.headwayS { InfoRow(label: "Min headway", value: String(format: "%.2f s", h)) }
                    }
                    if let lat = moment.lat, let lon = moment.lon {
                        InfoRow(label: "Location", value: String(format: "%.5f, %.5f", lat, lon))
                        InfoRow(label: "Hazard cell", value: HazardGrid.cellKey(lat: lat, lon: lon))
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    private func speedAt(_ t: Double) -> Double { interp(t, \.v) }
    private func accelAt(_ t: Double) -> Double { isTurn ? abs(interp(t, \.aLat)) : interp(t, \.a) }

    private func interp(_ t: Double, _ key: KeyPath<TracePoint, Double>) -> Double {
        let pts = analysis?.trace ?? []
        guard let i = pts.firstIndex(where: { $0.t >= t }) else { return pts.last?[keyPath: key] ?? 0 }
        if i == 0 { return pts[0][keyPath: key] }
        let a = pts[i - 1], b = pts[i]
        let w = b.t > a.t ? (t - a.t) / (b.t - a.t) : 0
        return a[keyPath: key] + (b[keyPath: key] - a[keyPath: key]) * w
    }

    private func nearestLead(_ t: Double) -> LeadSample? {
        guard !leads.isEmpty else { return nil }
        let best = leads.min { abs($0.t - t) < abs($1.t - t) }
        return best.flatMap { abs($0.t - t) <= 0.25 ? $0 : nil }
    }

    private func loadLeads() async {
        guard record.hasVideo, let side = sidecar ?? drives.sidecar(record) else { return }
        let url = drives.folderURL(record).appendingPathComponent(side.sensorFile)
        let (lo, hi) = window
        let result: [LeadSample] = await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url) else { return [] }
            return SensorLogParser.parse(data).lead.filter { $0.t >= lo - 1 && $0.t <= hi + 1 }
        }.value
        leads = result
    }

    private func loadPlace() async {
        guard let lat = moment.lat, let lon = moment.lon, let key = GoogleMaps.apiKey(settings: settings) else { return }
        let cacheKey = GoogleMapsCache.shared.placeKey(lat, lon)
        if let cached = GoogleMapsCache.shared.places[cacheKey] { googlePlace = cached; return }
        if let name = await GoogleMaps.placeName(lat: lat, lon: lon, key: key) {
            GoogleMapsCache.shared.places[cacheKey] = name
            googlePlace = name
        }
    }
}
