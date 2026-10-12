//  CoachingOnboarding.swift — Driveby
//  The safety agreement and the how-it-works explainer (both also reachable from Settings):
//    • SafetyPoints          — the few things every driver agrees to, worded for their mode.
//    • DisclaimerAcceptView  — those points + one "I understand" (shown once to older installs).
//    • HowItWorksView        — how a phone "watches" a drive, in plain words.

import SwiftUI

// MARK: - Safety agreement

struct SafetyPoints: View {
    var mode: DriverMode

    private struct Point: Identifiable { var symbol: String; var color: Color; var text: String; var id: String { text } }

    private var points: [Point] {
        let shared = [
            Point(symbol: "hand.raised.fill", color: .orange, text: "Eyes on the road, hands off the phone. Driveby speaks, so you never need to look."),
            Point(symbol: "exclamationmark.triangle.fill", color: .yellow, text: "It can be wrong. Signs, traffic laws and the road always come first."),
        ]
        guard mode == .newDriver else {
            return [Point(symbol: "shield.lefthalf.filled", color: Theme.safety, text: "A coach, not a safety system. You're always the driver.")] + shared
        }
        return [
            Point(symbol: "xmark.octagon.fill", color: .red, text: "It doesn't replace your instructor, driver's ed or road test."),
            Point(symbol: "person.2.fill", color: .blue, text: "Practise only with a licensed adult beside you, as your permit requires."),
        ] + shared
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(points) { p in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: p.symbol).foregroundStyle(p.color).font(.title3).frame(width: 26)
                    Text(p.text).font(.subheadline)
                }
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
                Image(systemName: "person.badge.shield.checkmark.fill")
                    .font(.system(size: 52)).foregroundStyle(.orange).padding(.top, 24)
                Text("Before you drive").font(.largeTitle.weight(.bold))
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

// MARK: - How it works

struct HowItWorksView: View {
    var onContinue: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("How Driveby watches your drive").font(.largeTitle.weight(.bold)).padding(.top, 12)
                Text("Mount the phone, tap Start, and drive normally.").font(.title3)

                Card {
                    step(1, "location.fill", .blue, "GPS → your speed",
                         "The same GPS your maps app uses tells Driveby how fast you're going and where.")
                    step(2, "gyroscope", .purple, "Motion sensors → braking & turning",
                         "Feels what a passenger feels: pushed forward when you brake hard, sideways in a sharp turn.")
                    step(3, "map.fill", .green, "Map → speed limits & stop signs",
                         "OpenStreetMap says what the limit is and where the stop signs are.")
                    step(4, "video.fill", .red, "Camera → replay clips",
                         "Records the road so you can rewatch a moment, and measures the gap to the car ahead. Faces and plates are blurred first.")
                }

                Card {
                    SectionHeader(title: "While you drive")
                    Text("Driveby speaks short tips — “Easy on the gas”, “Speed limit is 35” — and shows them in big type, so you never need to read the screen. You can turn the voice off in Settings.")
                        .font(.subheadline)
                }

                Card {
                    SectionHeader(title: "After you park")
                    Text("Every moment that mattered is on one timeline — “2:15 Smooth stop”, “5:30 Hard brake” — with its clip, a score and what to practise next.")
                        .font(.subheadline)
                }

                Card {
                    SectionHeader(title: "What it can't see")
                    Text("Your mirrors, signals, head checks or the pedestrian you waited for. Your own judgement — and your instructor — matter more than any app.")
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

    private func step(_ n: Int, _ icon: String, _ color: Color, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(color.opacity(0.15)).frame(width: 40, height: 40)
                Image(systemName: icon).foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("\(n). \(title)").font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
