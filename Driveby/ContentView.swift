//
//  ContentView.swift
//  Driveby
//
//  Root: onboarding until a vehicle is set up and the disclaimer + safety rules are accepted, then the tabs:
//    Drive · Skills · Hours · Hazard Map · Settings.
//  The post-drive reflection opens by itself as soon as a just-finished drive has been scored.
//  Screen map (Build Guide, Phase 6):
//    Onboarding → pick vehicle (year/make/model → EPA lookup)
//    Home ── Record button (large, thumb-reachable, one tap)
//         ├─ Recent drives list (date, distance, two score chips)
//         ├─ Trends (7/30-day sparklines for both scores)
//         └─ Hazard map tab
//    Drive Detail ── route map with coloured event pins, two score rings + breakdown bars,
//                    event timeline → tap → blurred clip + sensor trace overlay + plain-English cause
//

import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(RecordingController.self) private var recorder

    var body: some View {
        Group {
            if settings.onboardingComplete {
                MainTabView()
            } else {
                OnboardingView()
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { recorder.phase != .idle },
            set: { _ in })) {
            RecordingView()
        }
        // Installs from before the disclaimer existed must accept it once too.
        .fullScreenCover(isPresented: Binding(
            get: { settings.onboardingComplete && settings.disclaimerAcceptedAt == nil && recorder.phase == .idle },
            set: { _ in })) {
            NavigationStack {
                DisclaimerAcceptView(accepting: true) { settings.disclaimerAcceptedAt = Date() }
            }
            .interactiveDismissDisabled()
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
}

/// Regular drivers get four tabs; the permit-hours tab appears only in new-driver mode.
struct MainTabView: View {
    @Environment(AppSettings.self) private var settings
    /// Explicit tags so switching new-driver mode on/off (which adds/removes a tab) keeps you where you are.
    private enum Tab: Hashable { case drive, skills, hours, map, settings }
    @State private var tab: Tab = .drive

    var body: some View {
        TabView(selection: $tab) {
            HomeView()
                .tabItem { Label("Drive", systemImage: "car.fill") }
                .tag(Tab.drive)
            SkillsView()
                .tabItem { Label("Skills", systemImage: "gauge.with.dots.needle.67percent") }
                .tag(Tab.skills)
            if settings.isNewDriver {
                HoursLogView()
                    .tabItem { Label("Hours", systemImage: "clock.badge.checkmark.fill") }
                    .tag(Tab.hours)
            }
            HazardMapView()
                .tabItem { Label("Map", systemImage: "map.fill") }
                .tag(Tab.map)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        .onChange(of: settings.isNewDriver) { _, isNew in
            if !isNew && tab == .hours { tab = .drive }
        }
    }
}

/// Identifiable wrapper so `.sheet(item:)` can present the reflection for a drive id.
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
