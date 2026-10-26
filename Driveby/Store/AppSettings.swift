import Foundation
import Observation

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
    var voiceCoach: Bool { didSet { d.set(voiceCoach, forKey: "voiceCoach") } }
    var quickStartOnLaunch: Bool { didSet { d.set(quickStartOnLaunch, forKey: "quickStartOnLaunch") } }
    var introSeenVersion: Int { didSet { d.set(introSeenVersion, forKey: "introSeenVersion") } }
    var demoProfile: DemoProfile? { didSet { d.set(demoProfile?.rawValue, forKey: "demoProfile") } }
    var safetyRulesAcceptedAt: Date? { didSet { d.set(safetyRulesAcceptedAt, forKey: "safetyRulesAcceptedAt") } }
    var activeVehicleId: UUID? { didSet { d.set(activeVehicleId?.uuidString, forKey: "activeVehicleId") } }

    var recordVideo: Bool { didSet { d.set(recordVideo, forKey: "recordVideo") } }
    var autoStart: Bool { didSet { d.set(autoStart, forKey: "autoStart") } }
    var autoStop: Bool { didSet { d.set(autoStop, forKey: "autoStop") } }
    var detectionHz: Double { didSet { d.set(detectionHz, forKey: "detectionHz") } }
    var focalOverride: Double { didSet { d.set(focalOverride, forKey: "focalOverride") } }

    var keepFullVideoDays: Int { didSet { d.set(keepFullVideoDays, forKey: "keepFullVideoDays") } }

    var defaultFuelPrice: Double { didSet { d.set(defaultFuelPrice, forKey: "defaultFuelPrice") } }

    var uploadClips: Bool { didSet { d.set(uploadClips, forKey: "uploadClips") } }
    var contributeToHazardMap: Bool { didSet { d.set(contributeToHazardMap, forKey: "contributeToHazardMap") } }
    var supabaseURLOverride: String { didSet { d.set(supabaseURLOverride, forKey: "supabaseURLOverride") } }
    var supabaseKeyOverride: String { didSet { d.set(supabaseKeyOverride, forKey: "supabaseKeyOverride") } }

    var driverMode: DriverMode { didSet { d.set(driverMode.rawValue, forKey: "driverMode") } }
    var disclaimerAcceptedAt: Date? { didSet { d.set(disclaimerAcceptedAt, forKey: "disclaimerAcceptedAt") } }
    var defaultSupervisor: String { didSet { d.set(defaultSupervisor, forKey: "defaultSupervisor") } }
    var learnerName: String { didSet { d.set(learnerName, forKey: "learnerName") } }
    var hoursTotalTarget: Double { didSet { d.set(hoursTotalTarget, forKey: "hoursTotalTarget") } }
    var hoursNightTarget: Double { didSet { d.set(hoursNightTarget, forKey: "hoursNightTarget") } }
    var googleMapsKeyOverride: String { didSet { d.set(googleMapsKeyOverride, forKey: "googleMapsKeyOverride") } }

    var isNewDriver: Bool { driverMode == .newDriver }
    var isDemo: Bool { demoProfile != nil }

    var hoursRequirement: HoursRequirement {
        HoursRequirement(totalHours: hoursTotalTarget, nightHours: hoursNightTarget,
                         label: hoursTotalTarget == 45 && hoursNightTarget == 15 ? "Virginia (under 18)" : "Custom")
    }

    var obdPeripheralId: String? { didSet { d.set(obdPeripheralId, forKey: "obdPeripheralId") } }
    var obdEnabled: Bool { didSet { d.set(obdEnabled, forKey: "obdEnabled") } }

    init() {
        d.register(defaults: [
            "recordVideo": true, "autoStart": false, "autoStop": true, "detectionHz": 15.0,
            "focalOverride": 0.0, "keepFullVideoDays": 14, "defaultFuelPrice": 3.40,
            "uploadClips": false, "contributeToHazardMap": true, "obdEnabled": false, "voiceCoach": true, "quickStartOnLaunch": true, "introSeenVersion": 0,
            "appearance": AppAppearance.system.rawValue,
            "driverMode": DriverMode.regular.rawValue, "hoursTotalTarget": 45.0, "hoursNightTarget": 15.0,
        ])
        onboardingComplete = d.bool(forKey: "onboardingComplete")
        appearance = AppAppearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        voiceCoach = d.bool(forKey: "voiceCoach")
        quickStartOnLaunch = d.bool(forKey: "quickStartOnLaunch")
        introSeenVersion = d.integer(forKey: "introSeenVersion")
        demoProfile = d.string(forKey: "demoProfile").flatMap(DemoProfile.init(rawValue:))
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
        onboardingComplete = d.bool(forKey: "onboardingComplete")
        appearance = AppAppearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        voiceCoach = d.bool(forKey: "voiceCoach")
        quickStartOnLaunch = d.bool(forKey: "quickStartOnLaunch")
        introSeenVersion = d.integer(forKey: "introSeenVersion")
        demoProfile = d.string(forKey: "demoProfile").flatMap(DemoProfile.init(rawValue:))
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
