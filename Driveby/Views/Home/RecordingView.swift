import AVFoundation
import Combine
import SwiftUI

struct RecordingView: View {
    @Environment(RecordingController.self) private var recorder
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private static let cueVisibleFor: TimeInterval = 5

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let clip = recorder.demoClip {
                DemoClipLayer(player: clip.player, leadRect: recorder.leadRect, leadDistance: recorder.leadDistance)
                    .ignoresSafeArea()
            } else if recorder.mode == .camera && (recorder.phase == .recording || recorder.phase == .armed) {
                CameraPreview(session: recorder.camera.session)
                    .ignoresSafeArea()
                    .opacity(recorder.moving ? 0.25 : 0.85)
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
                    Text("Armed, waiting for the car to move").font(.headline)
                case .finishing:
                    Text("Saving drive…").font(.headline)
                default:
                    RecBadge(elapsed: recorder.startedAt.map { now.timeIntervalSince($0) } ?? 0)
                }
                gpsStatus
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                if settings.voiceCoach && recorder.phase == .recording { voiceToggle }
                if recorder.mode == .camera && recorder.phase == .recording { privacyBadge }
                if recorder.demoClip != nil { demoBadge }
            }
        }
        .foregroundStyle(.white)
    }

    private var voiceToggle: some View {
        Button { recorder.toggleVoice() } label: {
            Text(recorder.voiceMuted ? "Voice off" : "Voice on")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(.black.opacity(0.5), in: Capsule())
        }
        .accessibilityLabel(recorder.voiceMuted ? "Turn voice coach on" : "Mute voice coach")
    }

    private var gpsStatus: some View {
        let s = recorder.live
        return HStack(spacing: 6) {
            Text(s.hasGPS ? String(format: "GPS ±%.0f m", s.gpsAccuracy) : "Searching for GPS…")
            if settings.obdEnabled {
                Text(model.obd.isReady ? "OBD" : "OBD off")
            }
        }
        .font(.caption)
        .foregroundStyle(s.hasGPS ? .green : .orange)
    }

    private var privacyBadge: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("Blurring on device").font(.caption.weight(.semibold))
            Text("\(recorder.faces) faces · \(recorder.vehicles) vehicles · \(recorder.plates) plates")
                .font(.caption2).monospacedDigit().opacity(0.8)
        }
        .padding(8)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var demoBadge: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("Demo clip").font(.caption.weight(.semibold))
            Text("Real video · scripted speed").font(.caption2).opacity(0.8)
        }
        .padding(8)
        .background(Color.orange.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
    }

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
                Text(settings.voiceCoach ? "Eyes on the road. Driveby will speak up." : "Eyes on the road.")
                    .font(.subheadline).opacity(0.8)
            }
            .foregroundStyle(.white)
            .animation(.spring(duration: 0.4), value: visibleCue)
        case .recording:
            VStack(spacing: 6) {
                Text(Fmt.miles(recorder.live.distanceM)).font(.roadSign(fixed: 48)).monospacedDigit()
                Text(recorder.mode == .camera ? "Camera + sensors" : "Sensors only").font(.subheadline).opacity(0.8)
                if let reason = recorder.videoInterruptedReason {
                    Text(reason).font(.footnote).foregroundStyle(.orange)
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
                Text("Starts once you're moving.")
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
                Text("\(mph)").font(.roadSign(fixed: 96)).monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(over ? Color.orange : Color.white)
                Text("mph").font(.roadSign(.headline)).opacity(0.7)
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
                HoldButton(title: recorder.moving ? "Passenger: hold to stop" : "Hold to stop") {
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

private struct DemoClipLayer: View {
    let player: AVPlayer
    var leadRect: CGRect?
    var leadDistance: Double?
    private static let aspect: CGFloat = 16 / 9
    private static let feetPerMetre = 3.28084

    var body: some View {
        GeometryReader { geo in
            let frame = Self.fitted(in: geo.size)
            ZStack(alignment: .topLeading) {
                PlayerLayerView(player: player)
                if let r = leadRect {
                    let box = CGRect(x: frame.minX + r.minX * frame.width, y: frame.minY + r.minY * frame.height,
                                     width: r.width * frame.width, height: r.height * frame.height)
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.yellow, lineWidth: 3)
                        .frame(width: box.width, height: box.height)
                        .offset(x: box.minX, y: box.minY)
                    if let d = leadDistance {
                        Text(String(format: "%.0f ft", d * Self.feetPerMetre))
                            .font(.caption.weight(.bold)).monospacedDigit()
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.yellow, in: Capsule())
                            .foregroundStyle(.black)
                            .offset(x: box.minX, y: max(box.minY - 24, frame.minY))
                    }
                }
            }
            .animation(.easeOut(duration: 0.15), value: leadRect)
        }
        .allowsHitTesting(false)
    }

    private static func fitted(in size: CGSize) -> CGRect {
        let width = min(size.width, size.height * aspect)
        let height = width / aspect
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }
}

private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ v: LayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }
}

private struct CueBanner: View {
    var event: LiveCueEvent
    var body: some View {
        Text(event.cue.shortText(limitMph: event.limitMph))
            .font(.roadSign(fixed: 30))
            .padding(.horizontal, 22).padding(.vertical, 14)
            .background(event.cue.color.opacity(0.9), in: Capsule())
            .accessibilityLabel(event.cue.shortText(limitMph: event.limitMph))
    }
}

private struct SpeedLimitSign: View {
    var mph: Int
    var body: some View {
        VStack(spacing: 0) {
            Text("SPEED").font(.roadSign(fixed: 12))
            Text("LIMIT").font(.roadSign(fixed: 12))
            Text("\(mph)").font(.roadSign(fixed: 44)).monospacedDigit()
        }
        .foregroundStyle(.black)
        .frame(width: 78, height: 96)
        .background(.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(.black, lineWidth: 2.5).padding(4))
        .accessibilityLabel("Speed limit \(mph)")
    }
}
