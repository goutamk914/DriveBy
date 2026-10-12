import SwiftUI

struct OnboardingView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(GarageStore.self) private var garage

    private enum Step: Hashable { case intro, driverType, newDriver, vehicle, permissions, ready }

    @State private var step: Step = .intro
    @State private var vehicle: Vehicle?
    @State private var agreed = false
    @State private var leaving = false

    private static let agreeShare: CGFloat = 0.5
    private static let driveOffDelay: Duration = .milliseconds(750)

    private var steps: [Step] {
        settings.isNewDriver ? [.driverType, .newDriver, .vehicle, .permissions, .ready]
                             : [.driverType, .vehicle, .permissions, .ready]
    }

    private var progress: CGFloat {
        if leaving { return 1 }
        guard let i = steps.firstIndex(of: step), !steps.isEmpty else { return 0 }
        let stepProgress = step == .ready && agreed ? Self.agreeShare : 0
        return (CGFloat(i) + stepProgress) / CGFloat(steps.count)
    }

    var body: some View {
        ZStack {
            if step == .intro {
                IntroView {
                    settings.introSeenVersion = IntroView.version
                    move(to: .driverType)
                }
                .transition(.opacity)
            } else {
                RoadStepContainer(fraction: progress, showsBack: true, onBack: back,
                                  trailingTitle: step == .vehicle ? "Skip" : nil, onTrailing: advance) {
                    content
                        .id(step)
                        .transition(.driveForward)
                }
                .transition(.opacity)
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
            ReadyStep(agreed: $agreed, onStart: finish)
        }
    }

    private func finish() {
        guard !leaving else { return }
        leaving = true
        Task {
            try? await Task.sleep(for: Self.driveOffDelay)
            let now = Date()
            settings.disclaimerAcceptedAt = now
            settings.safetyRulesAcceptedAt = now
            settings.onboardingComplete = true
        }
    }

    private func move(to target: Step) {
        withAnimation(.easeInOut(duration: 0.45)) { step = target }
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
