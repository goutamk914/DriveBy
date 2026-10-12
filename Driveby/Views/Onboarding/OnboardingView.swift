//  OnboardingView.swift — Driveby
//  "Someone else can install it and complete a drive without you touching it."
//  Animated intro (the car drives a road that grows with each page) → how do you drive? →
//  new drivers only: permit hours + paper log → your car → permissions → ready (one safety agreement).
//  The setup steps keep the road theme: a small car in the navigation bar moves along as you go.

import SwiftUI

struct OnboardingView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(GarageStore.self) private var garage

    private enum Step: Hashable { case intro, driverType, newDriver, vehicle, permissions, ready }

    @State private var step: Step = .intro
    @State private var vehicle: Vehicle?

    /// Setup steps after the intro; new drivers get one more.
    private var steps: [Step] {
        settings.isNewDriver ? [.driverType, .newDriver, .vehicle, .permissions, .ready]
                             : [.driverType, .vehicle, .permissions, .ready]
    }

    private var progress: CGFloat {
        guard let i = steps.firstIndex(of: step), steps.count > 1 else { return 0 }
        return CGFloat(i) / CGFloat(steps.count - 1)
    }

    var body: some View {
        ZStack {
            if step == .intro {
                IntroView { move(to: .driverType) }
                    .transition(.opacity)
            } else {
                NavigationStack {
                    content
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) { Button("Back", action: back) }
                            ToolbarItem(placement: .principal) { SetupRoadProgress(fraction: progress) }
                            if step == .vehicle {
                                ToolbarItem(placement: .topBarTrailing) { Button("Skip", action: advance) }
                            }
                        }
                        .navigationBarTitleDisplayMode(.inline)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .intro, .driverType:
            DriverTypeStep(mode: Bindable(settings).driverMode, onContinue: advance)
        case .newDriver:
            NewDriverSetupView(onDone: advance)
        case .vehicle:
            VehiclePickerView { picked in
                // Going back and picking again replaces the car chosen earlier instead of adding a second one.
                var v = picked
                if let previous = vehicle { v.id = previous.id }
                vehicle = v
                garage.upsert(v)
                settings.activeVehicleId = v.id
                advance()
            }
        case .permissions:
            PermissionsStep(next: advance)
        case .ready:
            ReadyStep {
                let now = Date()
                settings.disclaimerAcceptedAt = now
                settings.safetyRulesAcceptedAt = now
                settings.onboardingComplete = true
            }
        }
    }

    // MARK: Navigation

    private func move(to target: Step) {
        withAnimation(.easeInOut(duration: 0.4)) { step = target }
    }

    private func advance() {
        guard let i = steps.firstIndex(of: step), i + 1 < steps.count else { return }
        move(to: steps[i + 1])
    }

    private func back() {
        guard let i = steps.firstIndex(of: step) else { return }
        move(to: i == 0 ? .intro : steps[i - 1])
    }
}
