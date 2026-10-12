//  DeviceViews.swift — Driveby
//  Mount check (Day 3: same geometry every drive or distance estimation breaks),
//  camera calibration, and the OBD-II adapter screen.

import CoreMotion
import SwiftUI

@MainActor
@Observable
final class LevelMeter {
    private(set) var roll: Double = 0      // degrees, 0 = horizon level in landscape
    private(set) var pitch: Double = 0     // degrees, 0 = lens pointing at the horizon
    private(set) var landscape = false
    @ObservationIgnored private let mm = CMMotionManager()

    func start() {
        guard mm.isDeviceMotionAvailable, !mm.isDeviceMotionActive else { return }
        mm.deviceMotionUpdateInterval = 0.1
        mm.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let g = m?.gravity else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.landscape = abs(g.x) > abs(g.y)
                if self.landscape {
                    self.roll = atan2(g.y, abs(g.x)) * 180 / .pi * (g.x < 0 ? 1 : -1)
                } else {
                    self.roll = atan2(g.x, abs(g.y)) * 180 / .pi
                }
                self.pitch = asin(max(-1, min(1, -g.z))) * 180 / .pi * -1
            }
        }
    }

    func stop() { mm.stopDeviceMotionUpdates() }
}

struct MountCheckView: View {
    @Environment(RecordingController.self) private var recorder
    @State private var level = LevelMeter()

    private var levelOK: Bool { abs(level.roll) < 3 }
    private var pitchOK: Bool { abs(level.pitch) < 12 }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                if CameraRecorder.authorization == .authorized {
                    CameraPreview(session: recorder.camera.session)
                } else {
                    Color.black.overlay(Text("Camera access is off").foregroundStyle(.white))
                }
                GeometryReader { geo in
                    Path { p in
                        p.move(to: CGPoint(x: geo.size.width / 2, y: 0)); p.addLine(to: CGPoint(x: geo.size.width / 2, y: geo.size.height))
                        p.move(to: CGPoint(x: 0, y: geo.size.height / 2)); p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2))
                    }
                    .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    Rectangle()
                        .stroke(Color.yellow, lineWidth: 2)
                        .frame(width: geo.size.width * 0.3, height: geo.size.height)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        .opacity(0.6)
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            HStack(spacing: 16) {
                gauge("Horizon", String(format: "%+.1f°", level.roll), ok: levelOK)
                gauge("Tilt", String(format: "%+.0f°", level.pitch), ok: pitchOK)
                gauge("Orientation", level.landscape ? "Landscape" : "Portrait", ok: level.landscape)
            }
            List {
                Label("Landscape, lens centred behind the mirror, above the dash line.", systemImage: "iphone.landscape")
                Label("The dashed lines should cross on the road ahead; the yellow band is \"our lane\" for following distance.", systemImage: "scope")
                Label("Level the horizon, then mark the mount position with tape — every drive must use the same geometry.", systemImage: "ruler")
                Label("Clean the windshield. Glare and grime hurt detection and blur.", systemImage: "sparkles")
            }
            .listStyle(.plain)
            .font(.footnote)
        }
        .padding()
        .navigationTitle("Mount check")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { recorder.startPreview(); level.start() }
        .onDisappear { recorder.stopPreview(); level.stop() }
    }

    private func gauge(_ title: String, _ value: String, ok: Bool) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.monospacedDigit()).foregroundStyle(ok ? .green : .orange)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct CalibrationView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Text("Following distance uses the pinhole model: distance = car width (1.8 m) × focal length (px) ÷ box width (px). Driveby reads the factory-calibrated focal length from the camera automatically (AVFoundation intrinsic matrix) and stores it with every drive.")
                    .font(.subheadline)
            }
            Section {
                LabeledContent("Focal length override (px @ 1280 wide)") {
                    TextField("auto", value: $settings.focalOverride, format: .number.precision(.fractionLength(1)))
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
                }
                Button("Use automatic") { settings.focalOverride = 0 }
            } header: { Text("Verify with a checkerboard") } footer: {
                Text("Print a checkerboard, take ~20 photos with the phone in its mount, and run tools/calibrate_camera.py. Enter its fx here to override. Don't guess from the spec-sheet field of view — you'd be off by ~20%.")
            }
        }
        .navigationTitle("Camera calibration")
    }
}

struct OBDView: View {
    @Environment(OBDManager.self) private var obd
    @Environment(AppSettings.self) private var settings

    var body: some View {
        List {
            Section {
                LabeledContent("Status", value: statusText)
                if obd.isReady {
                    Button("Test which PIDs respond") { obd.testPIDs() }
                    Button("Disconnect", role: .destructive) { obd.disconnect() }
                } else if obd.phase == .scanning {
                    HStack { ProgressView(); Text("Scanning for adapters…") }
                    Button("Stop scanning") { obd.stopScan() }
                } else {
                    Button("Scan for adapters") { obd.scan() }
                }
            } footer: {
                Text("Plug the adapter into the port under the dashboard, turn the ignition on, then scan. iPhones can only use Bluetooth LE (or Wi-Fi) adapters — \"Bluetooth Classic\" ELM327s won't appear.")
            }
            if !obd.found.isEmpty && !obd.isReady {
                Section("Nearby devices") {
                    ForEach(obd.found) { d in
                        Button {
                            settings.obdPeripheralId = d.id.uuidString
                            obd.connect(d.id)
                        } label: {
                            HStack { Text(d.name); Spacer(); Text("\(d.rssi) dBm").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            if obd.isReady {
                Section("PIDs (Week 0: which ones respond?)") {
                    ForEach(obd.report) { r in
                        HStack {
                            Text(r.pid.label)
                            Spacer()
                            if let v = r.lastValue { Text(String(format: "%.1f", v)).monospacedDigit().foregroundStyle(.secondary) }
                            Image(systemName: r.supported == true ? "checkmark.circle.fill" : r.supported == false ? "xmark.circle" : "questionmark.circle")
                                .foregroundStyle(r.supported == true ? Color.green : Color.secondary)
                        }
                    }
                    Text("Fuel per trip uses 015E (fuel rate) when supported, otherwise MAF (0110): fuel g/s = MAF ÷ 14.7, gallons = g ÷ 2830.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !obd.log.isEmpty {
                Section("Adapter log") {
                    ForEach(Array(obd.log.suffix(30).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                }
            }
        }
        .navigationTitle("OBD-II adapter")
    }

    private var statusText: String {
        switch obd.phase {
        case .off: return "Not connected"
        case .unsupported: return "Bluetooth LE unavailable"
        case .scanning: return "Scanning"
        case .connecting: return "Connecting…"
        case .initializing: return "Initialising \(obd.connectedName ?? "")…"
        case .ready: return "Connected — \(obd.connectedName ?? "adapter")"
        case .error(let m): return m
        }
    }
}
