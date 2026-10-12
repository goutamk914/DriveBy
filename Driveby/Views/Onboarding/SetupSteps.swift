import AVFoundation
import CoreLocation
import SwiftUI

struct DriverTypeStep: View {
    @Binding var mode: DriverMode
    var onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How do you drive?").font(.roadSign(.largeTitle)).padding(.top, 8)
            Text("You can change this any time in Settings.").foregroundStyle(.secondary)
            choice(.regular, title: "I drive regularly",
                   detail: "Voice tips while you drive and a score after.")
            choice(.newDriver, title: "I'm a new driver",
                   detail: "Log permit hours and get step-by-step coaching.")
            Spacer()
            Button(action: onContinue) {
                Text("Continue").font(.roadSign(.title3)).frame(maxWidth: .infinity).frame(height: 52)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
    }

    private func choice(_ m: DriverMode, title: String, detail: String) -> some View {
        let selected = mode == m
        return Button { withAnimation(.snappy) { mode = m } } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2).foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            .padding(16)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct NewDriverSetupView: View {
    var doneTitle = "Continue"
    var onDone: () -> Void
    @Environment(AppSettings.self) private var settings
    @Environment(AppModel.self) private var model
    @State private var importing = false
    @State private var imported: PracticeLogEntry?

    var body: some View {
        @Bindable var s = settings
        Form {
            Section {
                Text("Driveby logs your supervised hours for you, day and night, and coaches you one step at a time.")
                    .font(.subheadline)
            }
            Section("Your permit") {
                NavigationLink { HoursTargetForm() } label: {
                    LabeledContent("Hours to log", value: "\(Int(s.hoursTotalTarget)) h · \(Int(s.hoursNightTarget)) at night")
                }
            }
            Section {
                TextField("Supervising driver's name", text: $s.defaultSupervisor).textContentType(.name)
            } header: { Text("Who rides with you") } footer: {
                Text("A licensed adult in the front passenger seat. You can change it before each drive.")
            }
            Section {
                Button { importing = true } label: { Text("Scan or upload your paper log") }
                if let imported {
                    Text("Added \(HoursSummary.hoursString(imported.durationS)) from your paper log")
                        .foregroundStyle(Theme.efficiency)
                } else if model.hoursSummary.totalS > 0 {
                    LabeledContent("Already logged", value: HoursSummary.hoursString(model.hoursSummary.totalS))
                }
            } header: { Text("Already have hours?") } footer: {
                Text("Driveby reads the hours from a photo of your log. The photo stays on your phone.")
            }
            Section {
                Button(action: onDone) { Text(doneTitle).font(.headline).frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
        }
        .navigationTitle("New driver")
        .sheet(isPresented: $importing) { PaperLogImportView { imported = $0 } }
    }
}

struct PermissionsStep: View {
    var next: () -> Void
    @Environment(RecordingController.self) private var recorder
    @State private var location: CLAuthorizationStatus = .notDetermined
    @State private var camera: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

    private var locationGranted: Bool { location == .authorizedWhenInUse || location == .authorizedAlways }

    var body: some View {
        Form {
            Section {
                permissionRow(title: "Location", detail: "Your speed and route — needed to score a drive.",
                              granted: locationGranted, denied: location == .denied || location == .restricted) {
                    recorder.sensors.requestLocationPermission()
                }
                permissionRow(title: "Camera (optional)", detail: "Dashcam clips and following distance. Faces and plates are blurred first.",
                              granted: camera == .authorized, denied: camera == .denied || camera == .restricted) {
                    Task { _ = await CameraRecorder.requestAccess(); camera = AVCaptureDevice.authorizationStatus(for: .video) }
                }
            }
            Section {
                Button("Continue") { next() }.disabled(!locationGranted)
                if location == .denied {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            }
        }
        .navigationTitle("Permissions")
        .onAppear {
            location = recorder.sensors.authorization
            recorder.sensors.onAuthorizationChange = { status in location = status }
        }
    }

    private func permissionRow(title: String, detail: String, granted: Bool, denied: Bool,
                               request: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
                if granted {
                    Text("Allowed").foregroundStyle(.green).font(.subheadline)
                } else if denied {
                    Text("Turned off — enable in Settings → Driveby.").font(.subheadline).foregroundStyle(.orange)
                } else {
                    Button("Allow") { request() }.buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct ReadyStep: View {
    @Binding var agreed: Bool
    var onStart: () -> Void
    @Environment(AppSettings.self) private var settings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("You're set").font(.roadSign(.largeTitle)).padding(.top, 8)
                VStack(alignment: .leading, spacing: 10) {
                    tip("Mount the phone in landscape")
                    tip("Tap Start before you drive")
                    tip("Listen — Driveby speaks up")
                }
                SafetyPoints(mode: settings.driverMode)
                AgreeCheckbox(agreed: $agreed)
                NavigationLink { MountCheckView() } label: { Text("Check my mount") }
                    .disabled(CameraRecorder.authorization != .authorized)
                Button(action: onStart) {
                    Text("Start driving").font(.roadSign(.title3)).frame(maxWidth: .infinity).frame(height: 52)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!agreed)
            }
            .padding(24)
        }
    }

    private func tip(_ text: String) -> some View {
        Text(text).font(.headline)
    }
}
