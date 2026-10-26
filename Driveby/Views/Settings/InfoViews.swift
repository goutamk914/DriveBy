import SwiftUI

struct AccountView: View {
    @Environment(SyncService.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var creating = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password (8+ characters)", text: $password)
                        .textContentType(creating ? .newPassword : .password)
                }
                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack { Text(creating ? "Create account" : "Sign in"); if busy { Spacer(); ProgressView() } }
                    }
                    .disabled(busy || !email.contains("@") || password.count < 8)
                    Button(creating ? "I already have an account" : "Create a new account") { creating.toggle() }
                }
                if let error { Section { Text(error).foregroundStyle(.orange) } }
            }
            .navigationTitle(creating ? "Create account" : "Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func submit() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            try await sync.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password, create: creating)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct PrivacyView: View {
    var body: some View {
        List {
            Section {
                Text("Faces and plates are blurred before anything is saved.")
                    .font(.headline)
            }
            Section("Never leaves your phone") {
                row("Full drive video", "Blurred. Auto-deletes on your schedule.")
                row("Raw sensor log", "Stays on this phone.")
                row("Unblurred frames", "Never saved.")
            }
            Section("Synced to your private account (if you sign in)") {
                row("Drive summaries & scores", "Only you can read them.")
                row("Event locations and numbers", "Pooled anonymously for the hazard map.")
                row("Blurred event clips (opt-in)", "Off by default.")
            }
            Section("Public") {
                row("Hazard cells", "Counts only, ≥\(Thresholds.kEvents) events from ≥\(Thresholds.kUsers) drivers.")
            }
            Section("What Driveby will never do") {
                Text("Read plates, track drivers, rank you, sell data or record audio.")
            }
        }
        .navigationTitle("What leaves my phone")
    }

    private func row(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct SafetyRulesView: View {
    var accepting: Bool
    var onAccept: (() -> Void)? = nil
    @State private var agreed = false

    struct Rule: Identifiable { var text: String; var id: String { text } }

    static let rules: [Rule] = [
        Rule(text: "Never touch the phone while the car is moving."),
        Rule(text: "New drivers practise only with a licensed adult."),
        Rule(text: "Start recording before you drive; stop after parking."),
        Rule(text: "Mount the phone so it doesn't block your view."),
        Rule(text: "Don't look at the screen. Driveby speaks its tips."),
    ]

    var body: some View {
        List {
            Section {
                ForEach(Self.rules) { rule in
                    Text(rule.text)
                }
            }
            if accepting {
                Section {
                    Toggle("I'll follow these rules", isOn: $agreed)
                    Button("Continue") { onAccept?() }.disabled(!agreed)
                }
            }
        }
        .navigationTitle("Safety rules")
    }
}

struct AboutView: View {
    var body: some View {
        List {
            Section {
                Text("A driving coach that uses your phone as a dashcam.")
            }
            Section("A coach, not an instructor") {
                Text(Disclaimer.fullRegular).font(.subheadline)
                Text(Disclaimer.full).font(.subheadline)
            }
            Section("Honest limits") {
                Text("• Efficiency score: validated with fuel data.\n• Safety score: not validated.\n• Map speed limits and stop signs can be wrong.\n• Blurring isn't perfect.\n• Can't see mirrors, signals or head checks.")
                    .font(.subheadline)
            }
            Section("Data sources") {
                Text("OpenStreetMap contributors (ODbL): speed limits, stop signs\nEPA fueleconomy.gov: MPG ratings\nApple MapKit: maps\nGoogle Maps Platform: roads, places (optional)\nNOAA: sunset times\nOSRM: demo routes\n\(DemoClip.credit)")
                    .font(.subheadline)
            }
            Section("Open-source & models") {
                Text("Ultralytics YOLOv8n (AGPL-3.0) via coremltools (BSD-3)\nSwiftUI-Intro by Balaji Venkatesh (MIT)\nFonts: DIN Alternate, SF Pro Rounded\nPython: NumPy, pandas, SciPy, OpenCV, Ultralytics, Matplotlib, Requests, supabase-py\nApple: AVFoundation, Vision, Core ML, Core Motion, Core Location, Core Bluetooth, MapKit, Swift Charts")
                    .font(.subheadline)
            }
            Section("AI usage disclosure") {
                Text("Parts of the code were drafted with Claude by Anthropic. No generative AI runs in the app.")
                    .font(.subheadline)
            }
            Section("Driveby 2.0") {
                Text("• Lane-departure detection\n• Traffic-light state\n• Parent/teen shared view\n• Dashcam SD card import\n• Hazard map partnerships")
                    .font(.subheadline)
            }
            Section {
                LabeledContent("Version", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"))")
            }
        }
        .navigationTitle("About")
    }
}

struct DeveloperView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SyncService.self) private var sync
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                TextField("https://xxxx.supabase.co", text: $settings.supabaseURLOverride)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("anon public key", text: $settings.supabaseKeyOverride)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Apply") { sync.reconfigure() }
                LabeledContent("Status", value: sync.isConfigured ? "Configured" : "Local only")
            } header: { Text("Supabase override") } footer: {
                Text("Normally set in Config.plist.")
            }
            Section {
                SecureField("Google Maps API key (optional)", text: $settings.googleMapsKeyOverride)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                LabeledContent("Status", value: GoogleMaps.apiKey(settings: settings) == nil ? "Not set" : "Key set")
            } header: { Text("Google Maps override") } footer: {
                Text("Normally set in Config.local.plist.")
            }
            Section("Detectors") {
                let caps = model.recorder.camera.redactor.capabilities
                LabeledContent("Faces", value: "Apple Vision")
                LabeledContent("Vehicles & people", value: caps.objects ? "YOLOv8n (Core ML)" : "Vision humans only")
                LabeledContent("Plates", value: caps.plates ? "Plate model (Core ML)" : "Vehicle plate-zone + text heuristic")
            }
            Section("Thresholds") {
                LabeledContent("Hard brake", value: "< −3.0 m/s² for 0.5 s")
                LabeledContent("Hard accel", value: "> 2.5 m/s² for 0.5 s")
                LabeledContent("Sharp turn", value: "|v·yaw| > 3.0 m/s² for 0.5 s")
                LabeledContent("Speeding", value: "> limit + 10 mph for 5 s")
                LabeledContent("Idle", value: "< 0.5 m/s for > 60 s")
                LabeledContent("Tailgating", value: "headway < 1.0 s for 3 s")
            }
        }
        .navigationTitle("Developer")
    }
}
