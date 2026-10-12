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
                Section {
                    Text("Only scores, numeric events and (if you choose) blurred clips are synced. Your raw sensor log and full videos stay on this phone.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
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
                Text("We record other cars incidentally. We thought hard about whether to use that. We decided we had no right to — so faces and plates are blurred on the phone before anything is written to disk.")
                    .font(.headline)
            }
            Section("Never leaves your phone") {
                row("Full drive video", "Already blurred when written. You can delete it any time; it auto-deletes after the period you choose.")
                row("Raw sensor log", "Every GPS fix and motion sample stays local. Export it yourself if you want to.")
                row("Unblurred frames", "Don't exist. The camera's frames go through the blur step in memory; only the blurred version is encoded.")
            }
            Section("Synced to your private account (if you sign in)") {
                row("Drive summaries & scores", "Readable only by you (row-level security).")
                row("Event locations and numbers", "Used for your history, and — pooled with k-anonymity — for the public hazard map.")
                row("Blurred event clips (opt-in)", "Off by default.")
            }
            Section("Public") {
                row("Hazard cells", "Only cells with ≥\(Thresholds.kEvents) events from ≥\(Thresholds.kUsers) drivers, and only counts. No user IDs, no trip times. You can opt out.")
            }
            Section("What Driveby will never do") {
                Text("Read, store or look up licence plates. Track other drivers. Rank you publicly. Sell data. Record audio in your car.")
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
        Rule(text: "The driver does not touch the phone while the car is moving."),
        Rule(text: "New drivers practise only with a licensed adult; a passenger operates the device."),
        Rule(text: "Start recording before shifting into drive; stop after parking."),
        Rule(text: "Mount the phone where it doesn't block your view — centred, lens above the dash line."),
        Rule(text: "While you drive, Driveby only speaks short tips — never look at the screen. Full coaching comes after you park."),
    ]

    var body: some View {
        List {
            Section {
                ForEach(Self.rules) { rule in
                    Text(rule.text)
                }
            } footer: {
                Text("These rules are part of the app's design, not fine print.")
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
                Text("Driveby coaches drivers on safety and fuel efficiency using their own phone as a dashcam — with short spoken tips while they drive, and a full breakdown after. New drivers can also log their permit hours. It proves its efficiency score against real fuel data, and never records a single thing about anyone else.")
            }
            Section("A coach, not an instructor") {
                Text(Disclaimer.fullRegular).font(.subheadline)
                Text(Disclaimer.full).font(.subheadline)
            }
            Section("Why it's different") {
                Text("Telematics apps exist — but they're built for insurers, they don't tell you why you scored what you scored, and they don't show your data to the one person who actually needs it: the parent of a new driver. Driveby is free, runs on a phone you already own, blurs every face and plate on-device before anything is stored, and the data belongs to you.")
                    .font(.subheadline)
            }
            Section("Honest limits") {
                Text("• The efficiency score is validated against real fuel consumption (see Skills → \"Is the efficiency score real?\" for n and r²).\n• The safety score is not validated — it's built from established telematics thresholds; validating it would need crash data we don't have.\n• Speed limits come from OpenStreetMap and can be missing or out of date.\n• Blur detection isn't 100% — we err toward over-blurring.\n• Harsh-cornering uses the gyroscope and GPS speed; a phone that moves in its mount adds noise.\n• Stop-sign checks depend on OpenStreetMap marking the sign; a \"missed stop\" is flagged for review, not a verdict.\n• Driveby can't see mirrors, signals, head checks or your hands — your supervisor and instructor can.")
                    .font(.subheadline)
            }
            Section("Data sources") {
                Text("OpenStreetMap contributors (ODbL) via the Overpass API — speed limits, stop signs and road names.\nU.S. EPA / DOE fueleconomy.gov web services — vehicle MPG ratings.\nApple MapKit — maps.\nGoogle Maps Platform (optional) — Roads API snap-to-road, intersection names, and Google Maps / Street View links.\nNOAA solar-position equations — sunset times for the night-hours log.")
                    .font(.subheadline)
            }
            Section("Open-source & models") {
                Text("Ultralytics YOLOv8n (AGPL-3.0) — vehicle & pedestrian detection, converted to Core ML with coremltools (BSD-3).\nOnboarding symbol morph and walkthrough layout adapted from SwiftUI-Intro \"Walkthrough+Morphing\" by Balaji Venkatesh (MIT).\nFonts: DIN Alternate (ships with iOS) and SF Pro Rounded.\nPython processor: NumPy, pandas, SciPy, OpenCV, Ultralytics, Matplotlib, Requests, supabase-py.\nApple frameworks: AVFoundation, Vision, Core ML, Core Motion, Core Location, Core Bluetooth, MapKit, Swift Charts.")
                    .font(.subheadline)
            }
            Section("AI usage disclosure") {
                Text("Parts of this app's code, documentation and test fixtures were drafted with the help of an AI assistant (Claude by Anthropic), then reviewed, tested and modified by the team. The detection models are standard pretrained open-source models; no generative AI runs inside the app.")
                    .font(.subheadline)
            }
            Section("Driveby 2.0") {
                Text("• Lane-departure detection (classical CV → segmentation)\n• Traffic-light state at intersections\n• Opt-in parent/teen shared view\n• Import footage from a standalone dashcam SD card\n• Multi-city hazard map partnerships with county traffic engineering")
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
                Text("Normally set in Config.plist. The anon key is public by design; row-level security protects the data.")
            }
            Section {
                SecureField("Google Maps API key (optional)", text: $settings.googleMapsKeyOverride)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                LabeledContent("Status", value: GoogleMaps.apiKey(settings: settings) == nil ? "Not set — Google links still work" : "Key set")
            } header: { Text("Google Maps override") } footer: {
                Text("Normally GOOGLE_MAPS_API_KEY in Resources/Config.local.plist (git-ignored). Enables Roads API snap-to-road and intersection names. Restrict the key to this app's bundle ID and to the Roads and Geocoding APIs.")
            }
            Section("Detectors") {
                let caps = model.recorder.camera.redactor.capabilities
                LabeledContent("Faces", value: "Apple Vision")
                LabeledContent("Vehicles & people", value: caps.objects ? "YOLOv8n (Core ML)" : "Vision humans only")
                LabeledContent("Plates", value: caps.plates ? "Plate model (Core ML)" : "Vehicle plate-zone + text heuristic")
            }
            Section("Thresholds (Build Guide Step 2.2)") {
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
