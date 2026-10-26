import SwiftUI

struct SafetyPoints: View {
    var mode: DriverMode

    private struct Point: Identifiable { var text: String; var id: String { text } }

    private var points: [Point] {
        let shared = [
            Point(text: "Eyes on the road, hands off the phone."),
            Point(text: "It can be wrong. Signs and laws come first."),
        ]
        guard mode == .newDriver else {
            return [Point(text: "A coach, not a safety system.")] + shared
        }
        return [
            Point(text: "It doesn't replace your instructor or driver's ed."),
            Point(text: "Practise only with a licensed adult beside you."),
        ] + shared
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(points) { p in
                Text(p.text).font(.subheadline)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct AgreeCheckbox: View {
    @Binding var agreed: Bool
    var body: some View {
        Button { agreed.toggle() } label: {
            HStack(spacing: 10) {
                Image(systemName: agreed ? "checkmark.square.fill" : "square")
                    .font(.title2).foregroundStyle(agreed ? Color.accentColor : Color.secondary)
                Text("I understand and agree").font(.body.weight(.medium)).foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(agreed ? .isSelected : [])
    }
}

struct DisclaimerAcceptView: View {
    var accepting: Bool
    var onAccept: () -> Void = {}
    @Environment(AppSettings.self) private var settings
    @State private var agreed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Before you drive").font(.roadSign(.largeTitle)).padding(.top, 24)
                SafetyPoints(mode: settings.driverMode)
                if accepting {
                    AgreeCheckbox(agreed: $agreed)
                    Button(action: onAccept) {
                        Text("Continue").font(.headline).frame(maxWidth: .infinity).frame(height: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!agreed)
                } else {
                    Text(settings.isNewDriver ? Disclaimer.full : Disclaimer.fullRegular)
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .navigationTitle(accepting ? "" : "Safety")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct HowItWorksView: View {
    var onContinue: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("How Driveby watches your drive").font(.roadSign(.largeTitle)).padding(.top, 12)
                Text("Mount the phone, tap Start, and drive normally.").font(.title3)

                Card {
                    step(1, .blue, "GPS → your speed", "Speed and route.")
                    step(2, .purple, "Motion sensors → braking & turning", "Hard brakes and sharp turns.")
                    step(3, .green, "Map → speed limits & stop signs", "From OpenStreetMap.")
                    step(4, .red, "Camera → replay clips", "Clips and following distance, blurred first.")
                }

                Card {
                    SectionHeader(title: "While you drive")
                    Text("Short spoken tips. No need to look.")
                        .font(.subheadline)
                }

                Card {
                    SectionHeader(title: "After you park")
                    Text("A timeline of moments, clips and drills.")
                        .font(.subheadline)
                }

                Card {
                    SectionHeader(title: "What it can't see")
                    Text("Mirrors, signals or head checks.")
                        .font(.subheadline)
                }

                if let onContinue {
                    Button(action: onContinue) {
                        Text("Got it").font(.headline).frame(maxWidth: .infinity).frame(height: 52)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
        }
        .background(Theme.background)
        .navigationTitle(onContinue == nil ? "How it works" : "")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ n: Int, _ color: Color, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(color.opacity(0.15)).frame(width: 40, height: 40)
                Text("\(n)").font(.roadSign(.headline)).foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
