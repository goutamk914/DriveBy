//  AppSettings.swift — Driveby
//  User preferences, persisted in UserDefaults.

import Foundation
import Observation

/// Light / dark appearance. `system` follows the phone's setting.
enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "Automatic"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    private let d = UserDefaults.standard

    var onboardingComplete: Bool { didSet { d.set(onboardingComplete, forKey: "onboardingComplete") } }
    var appearance: AppAppearance { didSet { d.set(appearance.rawValue, forKey: "appearance") } }
    /// Speak short coaching cues while recording (hard brake, speeding, too close…).
    var voiceCoach: Bool { didSet { d.set(voiceCoach, forKey: "voiceCoach") } }
    var safetyRulesAcceptedAt: Date? { didSet { d.set(safetyRulesAcceptedAt, forKey: "safetyRulesAcceptedAt") } }
    var activeVehicleId: UUID? { didSet { d.set(activeVehicleId?.uuidString, forKey: "activeVehicleId") } }

    // Recording
    var recordVideo: Bool { didSet { d.set(recordVideo, forKey: "recordVideo") } }
    var autoStart: Bool { didSet { d.set(autoStart, forKey: "autoStart") } }
    var autoStop: Bool { didSet { d.set(autoStop, forKey: "autoStop") } }
    var detectionHz: Double { didSet { d.set(detectionHz, forKey: "detectionHz") } }
    /// Focal length (px at 1280-wide video) from tools/calibrate_camera.py; 0 = use AVFoundation intrinsics.
    var focalOverride: Double { didSet { d.set(focalOverride, forKey: "focalOverride") } }

    // Storage
    /// Delete full drive videos after N days (event clips are always kept). 0 = keep forever.
    var keepFullVideoDays: Int { didSet { d.set(keepFullVideoDays, forKey: "keepFullVideoDays") } }

    // Money
    var defaultFuelPrice: Double { didSet { d.set(defaultFuelPrice, forKey: "defaultFuelPrice") } }

    // Cloud
    var uploadClips: Bool { didSet { d.set(uploadClips, forKey: "uploadClips") } }
    var contributeToHazardMap: Bool { didSet { d.set(contributeToHazardMap, forKey: "contributeToHazardMap") } }
    var supabaseURLOverride: String { didSet { d.set(supabaseURLOverride, forKey: "supabaseURLOverride") } }
    var supabaseKeyOverride: String { didSet { d.set(supabaseKeyOverride, forKey: "supabaseKeyOverride") } }

    // Coaching
    var driverMode: DriverMode { didSet { d.set(driverMode.rawValue, forKey: "driverMode") } }
    var disclaimerAcceptedAt: Date? { didSet { d.set(disclaimerAcceptedAt, forKey: "disclaimerAcceptedAt") } }
    /// Default licensed adult who supervises practice drives (pre-filled in the checklist).
    var defaultSupervisor: String { didSet { d.set(defaultSupervisor, forKey: "defaultSupervisor") } }
    /// Printed on the hours-log PDF only (never uploaded).
    var learnerName: String { didSet { d.set(learnerName, forKey: "learnerName") } }
    var hoursTotalTarget: Double { didSet { d.set(hoursTotalTarget, forKey: "hoursTotalTarget") } }
    var hoursNightTarget: Double { didSet { d.set(hoursNightTarget, forKey: "hoursNightTarget") } }
    var googleMapsKeyOverride: String { didSet { d.set(googleMapsKeyOverride, forKey: "googleMapsKeyOverride") } }

    var isNewDriver: Bool { driverMode == .newDriver }

    var hoursRequirement: HoursRequirement {
        HoursRequirement(totalHours: hoursTotalTarget, nightHours: hoursNightTarget,
                         label: hoursTotalTarget == 45 && hoursNightTarget == 15 ? "Virginia (under 18)" : "Custom")
    }

    // OBD-II
    var obdPeripheralId: String? { didSet { d.set(obdPeripheralId, forKey: "obdPeripheralId") } }
    var obdEnabled: Bool { didSet { d.set(obdEnabled, forKey: "obdEnabled") } }

    init() {
        d.register(defaults: [
            "recordVideo": true, "autoStart": false, "autoStop": true, "detectionHz": 15.0,
            "focalOverride": 0.0, "keepFullVideoDays": 14, "defaultFuelPrice": 3.40,
            "uploadClips": false, "contributeToHazardMap": true, "obdEnabled": false, "voiceCoach": true,
            "appearance": AppAppearance.system.rawValue,
            "driverMode": DriverMode.regular.rawValue, "hoursTotalTarget": 45.0, "hoursNightTarget": 15.0,
        ])
        onboardingComplete = d.bool(forKey: "onboardingComplete")
        appearance = AppAppearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        voiceCoach = d.bool(forKey: "voiceCoach")
        safetyRulesAcceptedAt = d.object(forKey: "safetyRulesAcceptedAt") as? Date
        activeVehicleId = d.string(forKey: "activeVehicleId").flatMap(UUID.init(uuidString:))
        recordVideo = d.bool(forKey: "recordVideo")
        autoStart = d.bool(forKey: "autoStart")
        autoStop = d.bool(forKey: "autoStop")
        detectionHz = d.double(forKey: "detectionHz")
        focalOverride = d.double(forKey: "focalOverride")
        keepFullVideoDays = d.integer(forKey: "keepFullVideoDays")
        defaultFuelPrice = d.double(forKey: "defaultFuelPrice")
        uploadClips = d.bool(forKey: "uploadClips")
        contributeToHazardMap = d.bool(forKey: "contributeToHazardMap")
        supabaseURLOverride = d.string(forKey: "supabaseURLOverride") ?? ""
        supabaseKeyOverride = d.string(forKey: "supabaseKeyOverride") ?? ""
        obdPeripheralId = d.string(forKey: "obdPeripheralId")
        obdEnabled = d.bool(forKey: "obdEnabled")
        driverMode = DriverMode(rawValue: d.string(forKey: "driverMode") ?? "") ?? .regular
        disclaimerAcceptedAt = d.object(forKey: "disclaimerAcceptedAt") as? Date
        defaultSupervisor = d.string(forKey: "defaultSupervisor") ?? ""
        learnerName = d.string(forKey: "learnerName") ?? ""
        hoursTotalTarget = d.double(forKey: "hoursTotalTarget")
        hoursNightTarget = d.double(forKey: "hoursNightTarget")
        googleMapsKeyOverride = d.string(forKey: "googleMapsKeyOverride") ?? ""
    }

    func resetAll() {
        for key in d.dictionaryRepresentation().keys { d.removeObject(forKey: key) }
        // Reload so the screens show the defaults straight away (not only after a relaunch).
        onboardingComplete = d.bool(forKey: "onboardingComplete")
        appearance = AppAppearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        voiceCoach = d.bool(forKey: "voiceCoach")
        safetyRulesAcceptedAt = d.object(forKey: "safetyRulesAcceptedAt") as? Date
        activeVehicleId = d.string(forKey: "activeVehicleId").flatMap(UUID.init(uuidString:))
        recordVideo = d.bool(forKey: "recordVideo")
        autoStart = d.bool(forKey: "autoStart")
        autoStop = d.bool(forKey: "autoStop")
        detectionHz = d.double(forKey: "detectionHz")
        focalOverride = d.double(forKey: "focalOverride")
        keepFullVideoDays = d.integer(forKey: "keepFullVideoDays")
        defaultFuelPrice = d.double(forKey: "defaultFuelPrice")
        uploadClips = d.bool(forKey: "uploadClips")
        contributeToHazardMap = d.bool(forKey: "contributeToHazardMap")
        supabaseURLOverride = d.string(forKey: "supabaseURLOverride") ?? ""
        supabaseKeyOverride = d.string(forKey: "supabaseKeyOverride") ?? ""
        obdPeripheralId = d.string(forKey: "obdPeripheralId")
        obdEnabled = d.bool(forKey: "obdEnabled")
        driverMode = DriverMode(rawValue: d.string(forKey: "driverMode") ?? "") ?? .regular
        disclaimerAcceptedAt = d.object(forKey: "disclaimerAcceptedAt") as? Date
        defaultSupervisor = d.string(forKey: "defaultSupervisor") ?? ""
        learnerName = d.string(forKey: "learnerName") ?? ""
        hoursTotalTarget = d.double(forKey: "hoursTotalTarget")
        hoursNightTarget = d.double(forKey: "hoursNightTarget")
        googleMapsKeyOverride = d.string(forKey: "googleMapsKeyOverride") ?? ""
    }
}
