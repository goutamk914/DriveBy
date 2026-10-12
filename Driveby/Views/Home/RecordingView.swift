//  RecordingView.swift — Driveby
//  Glanceable while the car moves: speed, the speed limit, and the latest spoken tip in big type —
//  the voice does the coaching so nobody needs to read anything. Full coaching happens after the
//  drive. Stopping requires press-and-hold. Always dark (it's a dashcam), whatever the app theme.

import Combine
import SwiftUI

struct RecordingView: View {
    @Environment(RecordingController.self) private var recorder
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    /// How long a cue stays on screen after it's spoken.
    private static let cueVisibleFor: TimeInterval = 5

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if recorder.mode == .camera && (recorder.phase == .recording || recorder.phase == .armed) {
                CameraPreview(session: recorder.camera.session)
                    .ignoresSafeArea()
                    .opacity(recorder.moving ? 0.25 : 0.85)   // dim while moving — nothing to look at
                    .animation(.easeInOut, value: recorder.moving)
            }
            VStack(spacing: 16) {
                header
                Spacer()
                centre
                Spacer()
                footer
            }
            .padding(20)
            if recorder.phase == .recording {
                // Red frame around the whole screen: nobody can miss that this phone is recording.
                RoundedRectangle(cornerRadius: 38, style: .continuous)
                    .strokeBorder(Color.red, lineWidth: 8)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onReceive(tick) { now = $0 }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                switch recorder.phase {
                case .armed:
                    Label("Armed — waiting for the car to move", systemImage: "wand.and.stars").font(.headline)
                case .finishing:
                    Label("Saving drive…", systemImage: "square.and.arrow.down").font(.headline)
                default:
                    RecBadge(elapsed: recorder.startedAt.map { now.timeIntervalSince($0) } ?? 0)   // `now` ticks every second
                }
                gpsStatus
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                if settings.voiceCoach && recorder.phase == .recording { voiceToggle }
                if recorder.mode == .camera && recorder.phase == .recording { privacyBadge }
            }
        }
        .foregroundStyle(.white)
    }

    private var voiceToggle: some View {
        Button { recorder.toggleVoice() } label: {
            Image(systemName: recorder.voiceMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.title3)
                .frame(width: 48, height: 48)
                .background(.black.opacity(0.5), in: Circle())
        }
        .accessibilityLabel(recorder.voiceMuted ? "Turn voice coach on" : "Mute voice coach")
    }

    private var gpsStatus: some View {
        let s = recorder.live
        return HStack(spacing: 6) {
            Image(systemName: s.hasGPS ? "location.fill" : "location.slash.fill")
            Text(s.hasGPS ? String(format: "GPS ±%.0f m", s.gpsAccuracy) : "Searching for GPS…")
            if settings.obdEnabled {
                Image(systemName: "engine.combustion.fill")
                Text(model.obd.isReady ? "OBD" : "OBD off")
            }
        }
        .font(.caption)
        .foregroundStyle(s.hasGPS ? .green : .orange)
    }

    private var privacyBadge: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Label("Blurring on device", systemImage: "eye.slash.fill").font(.caption.weight(.semibold))
            Text("\(recorder.faces) faces · \(recorder.vehicles) vehicles · \(recorder.plates) plates")
                .font(.caption2).monospacedDigit().opacity(0.8)
        }
        .padding(8)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Centre

    /// The latest cue while it's fresh. Compared on the sensor clock (the cue's own time base); `now`
    /// only makes the view re-check every second.
    private var visibleCue: LiveCueEvent? {
        _ = now
        guard let cue = recorder.lastCue else { return nil }
        return recorder.sensorTime - cue.t < Self.cueVisibleFor ? cue : nil
    }

    @ViewBuilder private var centre: some View {
        switch recorder.phase {
        case .recording where recorder.moving:
            VStack(spacing: 22) {
                if let cue = visibleCue {
                    CueBanner(event: cue).transition(.scale.combined(with: .opacity))
                }
                speedometer
                Text(settings.voiceCoach ? "Eyes on the road — Driveby will speak up." : "Eyes on the road.")
                    .font(.subheadline).opacity(0.8)
            }
            .foregroundStyle(.white)
            .animation(.spring(duration: 0.4), value: visibleCue)
        case .recording:
            VStack(spacing: 6) {
                Text(Fmt.miles(recorder.live.distanceM)).font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                Text(recorder.mode == .camera ? "Camera + sensors" : "Sensors only").font(.subheadline).opacity(0.8)
                if let reason = recorder.videoInterruptedReason {
                    Label(reason, systemImage: "video.slash.fill").font(.footnote).foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
                if let err = recorder.cameraError {
                    Text(err).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
            }
            .foregroundStyle(.white)
        case .armed:
            VStack(spacing: 8) {
                ProgressView().tint(.white)
                Text("Recording starts on its own once you've been moving for 10 seconds.")
                    .font(.subheadline).multilineTextAlignment(.center).foregroundStyle(Color.white.opacity(0.8))
            }
        default:
            ProgressView().tint(.white)
        }
    }

    private var speedometer: some View {
        let mph = Int(Units.mph(recorder.live.speedMps).rounded())
        let limit = recorder.speedLimitMps
        let over = limit.map { recorder.live.speedMps > $0 + Thresholds.speedingMargin } ?? false
        return HStack(alignment: .center, spacing: 28) {
            VStack(spacing: 0) {
                Text("\(mph)").font(.system(size: 88, weight: .bold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(over ? Color.orange : Color.white)
                Text("mph").font(.headline).opacity(0.7)
            }
            if let limit { SpeedLimitSign(mph: LiveCoach.postedMph(limit)) }
        }
        .animation(.snappy, value: mph)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var footer: some View {
        switch recorder.phase {
        case .armed:
            Button { recorder.disarm() } label: {
                Text("Cancel").font(.headline).frame(maxWidth: .infinity).frame(height: 56)
            }
            .buttonStyle(.borderedProminent).tint(.gray)
        case .recording:
            VStack(spacing: 8) {
                HoldButton(title: recorder.moving ? "Passenger: hold to stop" : "Hold to stop", systemImage: "stop.fill") {
                    recorder.stop()
                }
                if settings.autoStop {
                    Text("Stops by itself after 3 minutes parked.").font(.caption).foregroundStyle(Color.white.opacity(0.7))
                }
            }
        default:
            EmptyView()
        }
    }
}

/// The spoken cue, big enough to read in a glance.
private struct CueBanner: View {
    var event: LiveCueEvent
    var body: some View {
        Label(event.cue.shortText(limitMph: event.limitMph), systemImage: event.cue.symbol)
            .font(.system(size: 30, weight: .bold, design: .rounded))
            .padding(.horizontal, 22).padding(.vertical, 14)
            .background(event.cue.color.opacity(0.9), in: Capsule())
            .accessibilityLabel(event.cue.shortText(limitMph: event.limitMph))
    }
}

/// US-style regulatory speed-limit sign.
private struct SpeedLimitSign: View {
    var mph: Int
    var body: some View {
        VStack(spacing: 0) {
            Text("SPEED").font(.system(size: 11, weight: .heavy))
            Text("LIMIT").font(.system(size: 11, weight: .heavy))
            Text("\(mph)").font(.system(size: 40, weight: .heavy, design: .rounded)).monospacedDigit()
        }
        .foregroundStyle(.black)
        .frame(width: 78, height: 96)
        .background(.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(.black, lineWidth: 2.5).padding(4))
        .accessibilityLabel("Speed limit \(mph)")
    }
}
