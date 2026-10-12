import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(SyncService.self) private var sync
    @Environment(GarageStore.self) private var garage
    @Environment(DriveStore.self) private var drives
    @State private var showAccount = false
    @State private var addVehicle = false
    @State private var importModel = false
    @State private var modelExportURL: URL?
    @State private var confirmWipe = false
    @State private var confirmDeleteAccount = false
    @State private var storageBytes: Int64 = 0
    @State private var error: String?
    @State private var showNewDriverSetup = false
    @State private var importPaperLog = false

    private var newDriverToggle: Binding<Bool> {
        Binding(get: { settings.isNewDriver },
                set: { on in if on { showNewDriverSetup = true } else { settings.driverMode = .regular } })
    }

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Appearance", selection: $settings.appearance) {
                        ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Toggle("Voice coach while driving", isOn: $settings.voiceCoach)
                    Toggle("Quick start when Driveby opens", isOn: $settings.quickStartOnLaunch)
                    Toggle("I'm a new driver", isOn: newDriverToggle)
                    if settings.isNewDriver {
                        TextField("Usual supervising driver", text: $settings.defaultSupervisor)
                            .textContentType(.name)
                        NavigationLink { HoursTargetForm() } label: {
                            LabeledContent("Hours requirement", value: "\(Int(settings.hoursTotalTarget)) h · \(Int(settings.hoursNightTarget)) at night")
                        }
                        Button { importPaperLog = true } label: { Text("Import paper log photo") }
                    }
                } header: { Text("Driving") } footer: {
                    Text(settings.driverMode.summary)
                }
                accountSection
                Section("Vehicles") {
                    ForEach(garage.vehicles) { v in
                        NavigationLink { VehicleEditView(vehicle: v) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(v.displayName)
                                    Text(v.epaCombined.map { "EPA \(Int($0)) mpg combined" } ?? "No EPA rating")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.activeVehicle?.id == v.id { Text("Active").font(.caption.weight(.semibold)).foregroundStyle(.tint) }
                            }
                        }
                    }
                    Button { addVehicle = true } label: { Text("Add vehicle") }
                    NavigationLink { FuelLogView() } label: { Text("Fuel log") }
                }
                Section {
                    Toggle("Record video (blurred on device)", isOn: $settings.recordVideo)
                    Toggle("Stop automatically after 3 min parked", isOn: $settings.autoStop)
                    Picker("Detection rate", selection: $settings.detectionHz) {
                        Text("6 Hz (coolest)").tag(6.0); Text("10 Hz").tag(10.0); Text("15 Hz (default)").tag(15.0); Text("30 Hz (every frame)").tag(30.0)
                    }
                    NavigationLink { MountCheckView() } label: { Text("Mount check") }
                    NavigationLink { CalibrationView() } label: { Text("Camera calibration") }
                } header: { Text("Recording") } footer: {
                    Text("Higher detection rates blur and measure following distance more often but make the phone warmer.")
                }
                Section {
                    Toggle("Use OBD-II adapter", isOn: $settings.obdEnabled)
                    if settings.obdEnabled {
                        NavigationLink { OBDView() } label: {
                            LabeledContent("Adapter", value: model.obd.connectedName ?? "Not connected")
                        }
                    }
                } header: { Text("OBD-II (optional)") } footer: {
                    Text("A $15 ELM327 Bluetooth LE adapter reads real fuel use per drive — hundreds of validation points instead of one per tank.")
                }
                Section {
                    Toggle("Contribute to the hazard map", isOn: $settings.contributeToHazardMap)
                    Toggle("Back up blurred event clips", isOn: $settings.uploadClips)
                        .disabled(!sync.isSignedIn)
                    NavigationLink { PrivacyView() } label: { Text("What leaves my phone") }
                } header: { Text("Privacy") } footer: {
                    Text("Raw video never exists — faces and plates are blurred before anything is written. Hazard contributions are pooled with k-anonymity (≥\(Thresholds.kEvents) events from ≥\(Thresholds.kUsers) drivers).")
                }
                Section {
                    LabeledContent("Weights", value: model.baseModel.source)
                    if let n = model.baseModel.fitN, let r2 = model.baseModel.fitR2 {
                        LabeledContent("Fit", value: String(format: "n=%d, r²=%.2f", n, r2))
                    }
                    Button("Import scoring_model.json…") { importModel = true }
                    if let url = modelExportURL { ShareLink("Export current model", item: url) }
                    if model.baseModel.source != "default" {
                        Button("Reset to default weights", role: .destructive) { model.resetScoringModel() }
                    }
                } header: { Text("Scoring model") } footer: {
                    Text("Fit weights in notebooks/validation.ipynb, then import the scoring_model.json it writes.")
                }
                Section {
                    LabeledContent("Fuel price fallback") {
                        TextField("$/gal", value: $settings.defaultFuelPrice, format: .number.precision(.fractionLength(2)))
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 80)
                    }
                } footer: { Text("Used for the \"about 4¢\" figures until your fuel log has a price.") }
                Section {
                    LabeledContent("Drives on this phone", value: "\(drives.records.count) · \(Storage.byteString(storageBytes))")
                    Stepper(value: $settings.keepFullVideoDays, in: 0...90, step: 7) {
                        Text(settings.keepFullVideoDays == 0 ? "Keep full videos forever" : "Delete full videos after \(settings.keepFullVideoDays) days")
                    }
                    Button("Free space now") {
                        let freed = drives.pruneOldVideos(olderThanDays: max(settings.keepFullVideoDays, 1))
                        model.toast = "Freed \(Storage.byteString(freed)). Event clips were kept."
                        storageBytes = drives.totalBytes()
                    }
                    Button("Delete all data on this phone", role: .destructive) { confirmWipe = true }
                } header: { Text("Storage") } footer: { Text("Event clips are always kept; only full-length drive videos are pruned.") }
                Section("About") {
                    NavigationLink { DisclaimerAcceptView(accepting: false) } label: {
                        Text("Not a driving instructor")
                    }
                    NavigationLink { HowItWorksView() } label: { Text("How Driveby watches your drive") }
                    Button { settings.introSeenVersion = 0 } label: { Text("Replay the intro") }
                    NavigationLink { SafetyRulesView(accepting: false) } label: { Text("Safety rules") }
                    NavigationLink { AboutView() } label: { Text("About Driveby") }
                    NavigationLink { DeveloperView() } label: { Text("Developer") }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showAccount) { AccountView() }
            .sheet(isPresented: $showNewDriverSetup) {
                NavigationStack {
                    NewDriverSetupView(doneTitle: "Turn on new-driver mode") {
                        settings.driverMode = .newDriver
                        showNewDriverSetup = false
                    }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showNewDriverSetup = false } } }
                }
            }
            .sheet(isPresented: $importPaperLog) { PaperLogImportView() }
            .sheet(isPresented: $addVehicle) {
                NavigationStack {
                    VehiclePickerView { v in
                        garage.upsert(v)
                        settings.activeVehicleId = v.id
                        addVehicle = false
                    }
                }
            }
            .fileImporter(isPresented: $importModel, allowedContentTypes: [.json]) { result in
                do { try model.importScoringModel(from: result.get()); model.toast = "Scoring model imported." }
                catch { self.error = error.localizedDescription }
            }
            .alert("Something went wrong", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
            .confirmationDialog("Delete everything on this phone?", isPresented: $confirmWipe, titleVisibility: .visible) {
                Button("Delete all local data", role: .destructive) { model.wipeLocalData() }
            } message: { Text("Drives, videos, clips, practice hours, fuel log and vehicles are removed from this phone. Your cloud account (if any) is not affected.") }
            .confirmationDialog("Delete your Driveby account?", isPresented: $confirmDeleteAccount, titleVisibility: .visible) {
                Button("Delete account and cloud data", role: .destructive) {
                    Task {
                        do { try await sync.deleteAccount(); model.toast = "Account deleted." }
                        catch { self.error = error.localizedDescription }
                    }
                }
            } message: { Text("Removes your account, synced drives, events, fuel log and clips from the server. Drives on this phone stay.") }
            .task {
                storageBytes = drives.totalBytes()
                let url = Storage.exportsRoot.appendingPathComponent("scoring_model.json")
                if (try? ScoringModel.encoder.encode(model.model).write(to: url)) != nil { modelExportURL = url }
            }
        }
    }

    @ViewBuilder private var accountSection: some View {
        Section {
            if !sync.isConfigured {
                Text("Local-only mode")
                Text("Cloud sync isn't configured in this build (Config.plist). Everything works on this phone.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if let email = sync.signedInEmail {
                LabeledContent("Signed in", value: email)
                Button {
                    Task { await sync.syncNow() }
                } label: {
                    HStack {
                        Text("Sync now")
                        Spacer()
                        switch sync.status {
                        case .syncing: ProgressView()
                        case .done(let d): Text("Synced \(Fmt.time.string(from: d))").foregroundStyle(.secondary).font(.caption)
                        case .failed(let m): Text(m).foregroundStyle(.orange).font(.caption).lineLimit(2)
                        case .idle: EmptyView()
                        }
                    }
                }
                Button("Sign out") { Task { await sync.signOut() } }
                Button("Delete account…", role: .destructive) { confirmDeleteAccount = true }
            } else {
                Button { showAccount = true } label: { Text("Sign in or create an account") }
                Text("Back up your history and contribute to the district hazard map.").font(.footnote).foregroundStyle(.secondary)
            }
        } header: { Text("Account") }
    }
}

struct VehicleEditView: View {
    @State var vehicle: Vehicle
    @Environment(GarageStore.self) private var garage
    @Environment(AppSettings.self) private var settings
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Vehicle") {
                LabeledContent("Model", value: vehicle.displayName)
                if let t = vehicle.trim { LabeledContent("Trim", value: t) }
                LabeledContent("EPA city / hwy / combined",
                               value: [vehicle.epaCity, vehicle.epaHwy, vehicle.epaCombined].map { $0.map { String(Int($0)) } ?? "—" }.joined(separator: " / "))
            }
            Section {
                LabeledContent("Mass (kg)") {
                    TextField("1500", value: $vehicle.massKg, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
                VStack(alignment: .leading) {
                    Text("Regenerative braking recovery: \(Int(vehicle.regenFactor * 100))%")
                    Slider(value: $vehicle.regenFactor, in: 0...0.8, step: 0.05)
                }
            } header: { Text("Physics") } footer: {
                Text("Mass sets the kinetic energy thrown away by braking. Hybrids and EVs recover some of it — the recovery factor credits that.")
            }
            Section {
                Button("Make this the active vehicle") { settings.activeVehicleId = vehicle.id }
                    .disabled(model.activeVehicle?.id == vehicle.id)
                Button("Delete vehicle", role: .destructive) {
                    garage.deleteVehicle(vehicle.id)
                    if settings.activeVehicleId == vehicle.id { settings.activeVehicleId = garage.vehicles.first?.id }
                    dismiss()
                }
            }
        }
        .navigationTitle(vehicle.model)
        .onDisappear {
            if garage.vehicles.contains(where: { $0.id == vehicle.id }) { garage.upsert(vehicle) }
        }
    }
}
