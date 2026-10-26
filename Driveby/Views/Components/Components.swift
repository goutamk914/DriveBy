import AVFoundation
import AVKit
import Charts
import SwiftUI

struct ScoreRing: View {
    var title: String
    var score: Double?
    var tint: Color
    var caption: String? = nil
    var size: CGFloat = 112

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(tint.opacity(0.15), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: CGFloat((score ?? 0) / 100))
                    .stroke(tint, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.8), value: score)
                VStack(spacing: 0) {
                    Text(Fmt.score(score)).font(.roadSign(fixed: size * 0.34)).monospacedDigit()
                    Text("/ 100").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: size, height: size)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title) score \(Fmt.score(score)) out of 100")
            Text(title).font(.subheadline.weight(.semibold))
            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: size + 40)
            }
        }
    }
}

struct ScoreChip: View {
    var label: String
    var score: Double?
    var tint: Color
    var body: some View {
        Text(Fmt.score(score)).font(.roadSign(.subheadline)).monospacedDigit()
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: Capsule())
            .accessibilityLabel("\(label) \(Fmt.score(score))")
    }
}

struct EfficiencyChip: View {
    var score: Double?
    var body: some View { ScoreChip(label: "Efficiency", score: score, tint: Theme.efficiency) }
}

struct SafetyChip: View {
    var score: Double?
    var body: some View { ScoreChip(label: "Safety", score: score, tint: Theme.safety) }
}

struct Sparkline: View {
    var values: [(Date, Double)]
    var tint: Color
    var body: some View {
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("Day", p.0), y: .value("Score", p.1))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(tint)
                AreaMark(x: .value("Day", p.0), y: .value("Score", p.1))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.25), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...100)
    }
}

struct EventBadge: View {
    var kind: EventKind
    var size: CGFloat = 30
    var body: some View {
        Circle()
            .fill(kind.color)
            .frame(width: size * 0.5, height: size * 0.5)
            .frame(width: size, height: size)
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var coordinator: AVCaptureDevice.RotationCoordinator?
        var observation: NSKeyValueObservation?
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
            let rc = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: v.previewLayer)
            v.coordinator = rc
            let apply: (CGFloat) -> Void = { [weak v] angle in
                guard let conn = v?.previewLayer.connection, conn.isVideoRotationAngleSupported(angle) else { return }
                conn.videoRotationAngle = angle
            }
            apply(rc.videoRotationAngleForHorizonLevelPreview)
            v.observation = rc.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                DispatchQueue.main.async { apply(angle) }
            }
        }
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    @Binding var videoRect: CGRect

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var onRect: ((CGRect) -> Void)?
        override func layoutSubviews() {
            super.layoutSubviews()
            onRect?(playerLayer.videoRect)
        }
    }

    func makeUIView(context: Context) -> PlayerView {
        let v = PlayerView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
        v.onRect = { r in DispatchQueue.main.async { if videoRect != r { videoRect = r } } }
        return v
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
        uiView.setNeedsLayout()
    }
}

struct HoldButton: View {
    var title: String
    var tint: Color = .red
    var duration: Double = 1.2
    var action: () -> Void

    @State private var progress: CGFloat = 0
    @State private var holding = false

    var body: some View {
        ZStack {
            Capsule().fill(tint.opacity(0.2))
            GeometryReader { geo in
                Capsule().fill(tint).frame(width: geo.size.width * progress)
            }
            .clipShape(Capsule())
            Text(holding ? "Keep holding…" : title)
                .font(.headline)
                .foregroundStyle(.white)
        }
        .frame(height: 64)
        .contentShape(Capsule())
        .onLongPressGesture(minimumDuration: duration, maximumDistance: 40) {
            progress = 0
            holding = false
            action()
        } onPressingChanged: { pressing in
            holding = pressing
            withAnimation(pressing ? .linear(duration: duration) : .easeOut(duration: 0.2)) { progress = pressing ? 1 : 0 }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(title)
        .accessibilityAction { action() }
    }
}

struct InfoRow: View {
    var label: String
    var value: String
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.subheadline)
    }
}

struct Toast: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(radius: 8, y: 4)
            .padding(.horizontal, 24)
    }
}

struct MomentBadge: View {
    var kind: MomentKind
    var size: CGFloat = 30
    var body: some View {
        Circle()
            .fill(kind.color)
            .frame(width: size * 0.5, height: size * 0.5)
            .frame(width: size, height: size)
    }
}

struct SkillBar: View {
    var skill: Skill
    var percent: Double?
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(skill.title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(percent.map { String(format: "%.0f%%", $0) } ?? "-")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(Theme.scoreColor(percent))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(Theme.scoreColor(percent)).frame(width: geo.size.width * CGFloat((percent ?? 0) / 100))
                }
            }
            .frame(height: 10)
            Text(detail ?? skill.definition).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct DisclaimerBanner: View {
    var compact = false
    @Environment(AppSettings.self) private var settings
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Disclaimer.short(settings.driverMode)).font(.subheadline.weight(.bold))
                if !compact {
                    Text(Disclaimer.detail(settings.driverMode))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.orange.opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

struct RecBadge: View {
    var elapsed: TimeInterval
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(.white).frame(width: 16, height: 16)
                .opacity(pulse ? 0.35 : 1)
            Text("REC").font(.roadSign(fixed: 26))
            Text(Fmt.clock(elapsed)).font(.roadSign(fixed: 22)).monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(Color.red, in: Capsule())
        .shadow(color: .red.opacity(0.6), radius: pulse ? 16 : 6)
        .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true } }
        .accessibilityLabel("Recording, \(Fmt.clock(elapsed))")
    }
}
