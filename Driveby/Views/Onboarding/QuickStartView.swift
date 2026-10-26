import SwiftUI

enum QuickStartAction {
    case armAutoStart(supervisor: String?)
    case startNow(supervisor: String?)
    case notNow
}

struct QuickStartView: View {
    var onFinish: (QuickStartAction) -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(AppModel.self) private var model

    private enum Step: Hashable { case hello, phone, rider, go }

    @State private var step: Step = .hello
    @State private var checked: Set<String> = []
    @State private var supervisor = ""
    @State private var supervisorPresent = false

    private struct PhoneTip: Identifiable {
        var symbol: String
        var title: String
        var detail: String
        var id: String { title }
    }

    private static let phoneTips = [
        PhoneTip(symbol: "iphone.landscape", title: "Mount it in landscape", detail: "Centred behind the mirror, not blocking your view."),
        PhoneTip(symbol: "camera.viewfinder", title: "Lens clear, above the dash", detail: "So the camera sees the road ahead."),
        PhoneTip(symbol: "bolt.fill", title: "Plug it in", detail: "Recording uses a lot of battery."),
        PhoneTip(symbol: "moon.fill", title: "Turn on Driving Focus", detail: "No notifications while you drive."),
    ]

    private var steps: [Step] { settings.isNewDriver ? [.hello, .phone, .rider, .go] : [.hello, .phone, .go] }

    @State private var leaving = false
    private static let checkShare: CGFloat = 0.85
    private static let driveOffDelay: Duration = .milliseconds(750)

    private var stepProgress: CGFloat {
        switch step {
        case .phone:
            return Self.checkShare * CGFloat(checked.count) / CGFloat(Self.phoneTips.count)
        case .rider:
            return Self.checkShare * ((supervisorName != nil ? 0.5 : 0) + (supervisorPresent ? 0.5 : 0))
        case .hello, .go:
            return 0
        }
    }

    private var progress: CGFloat {
        if leaving { return 1 }
        guard let i = steps.firstIndex(of: step), !steps.isEmpty else { return 0 }
        return (CGFloat(i) + stepProgress) / CGFloat(steps.count)
    }

    private var supervisorName: String? {
        guard settings.isNewDriver else { return nil }
        let name = supervisor.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    var body: some View {
        RoadStepContainer(fraction: progress, showsBack: step != .hello, onBack: back,
                          trailingTitle: "Not now", onTrailing: { onFinish(.notNow) }) {
            page
                .id(step)
                .transition(.driveForward)
        }
        .onAppear { if supervisor.isEmpty { supervisor = settings.defaultSupervisor } }
    }

    @ViewBuilder private var page: some View {
        switch step {
        case .hello: hello
        case .phone: phone
        case .rider: rider
        case .go: go
        }
    }

    private var hello: some View {
        QuickStartPage(title: "Hey, ready to drive?",
                       subtitle: model.activeVehicle.map { "Let's get your \($0.displayName) on the road." } ?? "Let's get you on the road.",
                       buttonTitle: "Let's go", action: advance) {
            TopDownCar(scale: 3)
                .frame(maxWidth: .infinity)
                .frame(height: 120)
        }
    }

    private var phone: some View {
        QuickStartPage(title: "Set your phone up", subtitle: "Tap each one as you do it.",
                       buttonTitle: checked.count == Self.phoneTips.count ? "Done" : "Next", action: advance) {
            VStack(spacing: 10) {
                ForEach(Self.phoneTips) { tip in tipRow(tip) }
                if CameraRecorder.authorization == .authorized {
                    NavigationLink { MountCheckView() } label: {
                        Text("Check my mount with the camera")
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private func tipRow(_ tip: PhoneTip) -> some View {
        let done = checked.contains(tip.id)
        return Button {
            withAnimation(.snappy) { if done { checked.remove(tip.id) } else { checked.insert(tip.id) } }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: tip.symbol).font(.title3).foregroundStyle(.tint).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tip.title).font(.headline).foregroundStyle(.primary)
                    Text(tip.detail).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.title2).foregroundStyle(done ? Color.green : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(done ? .isSelected : [])
    }

    private var rider: some View {
        QuickStartPage(title: "Who's riding with you?", subtitle: "Your permit needs a licensed adult beside you.",
                       buttonTitle: "Next", isEnabled: supervisorName != nil && supervisorPresent, action: advance) {
            VStack(spacing: 12) {
                TextField("Supervisor's name", text: $supervisor)
                    .textContentType(.name)
                    .padding(14)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Toggle("They're in the passenger seat", isOn: $supervisorPresent)
                    .padding(14)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private var go: some View {
        QuickStartPage(title: "You're ready",
                       subtitle: "Recording starts once you're moving.",
                       buttonTitle: "Start when I drive", buttonSymbol: "wand.and.stars", action: { finish(auto: true) }) {
            VStack(spacing: 14) {
                Image(systemName: "steeringwheel")
                    .font(.system(size: 84, weight: .bold))
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                Button { finish(auto: false) } label: {
                    Label("Start recording now", systemImage: "record.circle").font(.subheadline.weight(.semibold))
                }
            }
        }
    }

    private func finish(auto: Bool) {
        guard !leaving else { return }
        if let name = supervisorName { settings.defaultSupervisor = name }
        let action: QuickStartAction = auto ? .armAutoStart(supervisor: supervisorName) : .startNow(supervisor: supervisorName)
        leaving = true
        Task {
            try? await Task.sleep(for: Self.driveOffDelay)
            onFinish(action)
        }
    }

    private func advance() {
        guard let i = steps.firstIndex(of: step), i + 1 < steps.count else { return }
        withAnimation(.easeInOut(duration: 0.45)) { step = steps[i + 1] }
    }

    private func back() {
        guard let i = steps.firstIndex(of: step), i > 0 else { return }
        withAnimation(.easeInOut(duration: 0.45)) { step = steps[i - 1] }
    }
}

private struct QuickStartPage<Content: View>: View {
    var title: String
    var subtitle: String
    var buttonTitle: String
    var buttonSymbol: String? = nil
    var isEnabled = true
    var action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.roadSign(.largeTitle))
                Text(subtitle).font(.body).foregroundStyle(.secondary)
            }
            .padding(.top, 12)
            ScrollView { content.padding(.vertical, 4) }
                .scrollBounceBehavior(.basedOnSize)
            Button(action: action) {
                Group {
                    if let buttonSymbol { Label(buttonTitle, systemImage: buttonSymbol) } else { Text(buttonTitle) }
                }
                .font(.roadSign(.title3))
                .frame(maxWidth: .infinity)
                .frame(height: 54)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .disabled(!isEnabled)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }
}
