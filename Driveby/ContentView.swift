import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(RecordingController.self) private var recorder
    @State private var pendingQuickStart: QuickStartAction?

    private var introPending: Bool { settings.introSeenVersion < IntroView.version }

    var body: some View {
        Group {
            if !settings.onboardingComplete {
                OnboardingView()
            } else if introPending {
                IntroView {
                    model.quickStartPending = false
                    withAnimation(.easeInOut(duration: 0.4)) { settings.introSeenVersion = IntroView.version }
                }
                .transition(.opacity)
            } else {
                MainTabView()
                    .transition(.opacity)
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { recorder.phase != .idle },
            set: { _ in })) {
            RecordingView()
        }
        .fullScreenCover(isPresented: Binding(
            get: { settings.onboardingComplete && settings.disclaimerAcceptedAt == nil && recorder.phase == .idle },
            set: { _ in })) {
            NavigationStack {
                DisclaimerAcceptView(accepting: true) { settings.disclaimerAcceptedAt = Date() }
            }
            .interactiveDismissDisabled()
        }
        .fullScreenCover(isPresented: quickStartShown, onDismiss: runPendingQuickStart) {
            QuickStartView { action in
                pendingQuickStart = action
                model.quickStartPending = false
            }
        }
        .sheet(item: Binding(
            get: { recorder.phase == .idle ? model.reflectionDriveId.map(ReflectionTarget.init) : nil },
            set: { if $0 == nil { model.reflectionDriveId = nil } })) { t in
            ReflectionView(driveId: t.id)
        }
        .overlay(alignment: .top) {
            if let toast = model.toast {
                Toast(text: toast)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { withAnimation { model.toast = nil } }
                    .task(id: toast) {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        withAnimation { model.toast = nil }
                    }
            }
        }
        .animation(.spring(duration: 0.35), value: model.toast)
    }

    private var quickStartShown: Binding<Bool> {
        Binding(
            get: {
                model.quickStartPending && settings.onboardingComplete && !introPending
                    && settings.disclaimerAcceptedAt != nil && recorder.phase == .idle
            },
            set: { if !$0 { model.quickStartPending = false } })
    }

    private func runPendingQuickStart() {
        guard let action = pendingQuickStart else { return }
        pendingQuickStart = nil
        let vehicle = model.activeVehicle?.id
        switch action {
        case .armAutoStart(let supervisor): recorder.arm(vehicleId: vehicle, supervisor: supervisor)
        case .startNow(let supervisor): recorder.start(vehicleId: vehicle, supervisor: supervisor)
        case .notNow: break
        }
    }
}

struct MainTabView: View {
    @Environment(AppSettings.self) private var settings
    private enum Tab: Hashable { case drive, skills, hours, map, settings }
    @State private var tab: Tab = .drive

    private var items: [DriveTabBar<Tab>.Item] {
        var list: [DriveTabBar<Tab>.Item] = [
            .init(tab: .drive, title: "Drive"),
            .init(tab: .skills, title: "Skills"),
        ]
        if settings.isNewDriver { list.append(.init(tab: .hours, title: "Hours")) }
        list.append(.init(tab: .map, title: "Map"))
        list.append(.init(tab: .settings, title: "Settings"))
        return list
    }

    var body: some View {
        TabView(selection: $tab) {
            HomeView()
                .tag(Tab.drive)
                .toolbar(.hidden, for: .tabBar)
            SkillsView()
                .tag(Tab.skills)
                .toolbar(.hidden, for: .tabBar)
            if settings.isNewDriver {
                HoursLogView()
                    .tag(Tab.hours)
                    .toolbar(.hidden, for: .tabBar)
            }
            HazardMapView()
                .tag(Tab.map)
                .toolbar(.hidden, for: .tabBar)
            SettingsView()
                .tag(Tab.settings)
                .toolbar(.hidden, for: .tabBar)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            DriveTabBar(items: items, selection: $tab)
        }
        .onChange(of: settings.isNewDriver) { _, isNew in
            if !isNew && tab == .hours { tab = .drive }
        }    }
}

private struct ReflectionTarget: Identifiable { let id: UUID }

#Preview {
    let model = AppModel()
    return ContentView()
        .environment(model)
        .environment(model.settings)
        .environment(model.drives)
        .environment(model.garage)
        .environment(model.practiceLog)
        .environment(model.sync)
        .environment(model.recorder)
        .environment(model.obd)
}
