import Foundation

extension AppModel {
    static let demoLaunchKey = "DrivebyDemo"
    private static let demoHoursTotal = 45.0
    private static let demoHoursNight = 15.0

    func loadDemoFromLaunchArgument() async {
        guard let raw = UserDefaults.standard.string(forKey: Self.demoLaunchKey),
              let profile = DemoProfile(rawValue: raw), settings.demoProfile != profile else { return }
        await loadDemo(profile)
    }

    func loadDemo(_ profile: DemoProfile) async {
        guard !demoLoading, recorder.phase == .idle else { return }
        demoLoading = true
        defer { demoLoading = false }

        let content = DemoCatalog.content(for: profile, now: Date())
        drives.wipe()
        garage.wipe()
        practiceLog.wipe()
        applyDemoSettings(profile, content: content)
        garage.upsert(content.vehicle)
        for log in content.fuelLogs { garage.upsert(log) }

        let params = content.vehicle.params
        let scripts = content.drives
        let scored = await Task.detached(priority: .userInitiated) {
            scripts.compactMap { script -> (DemoDriveScript, DriveAnalysis)? in
                let drive = DemoSynth.synthesize(script)
                guard let plan = try? DriveAnalyzer.plan(log: drive.log) else { return nil }
                let analysis = DriveAnalyzer.analyze(plan: plan, log: drive.log, vehicle: params,
                                                     ways: drive.ways, controls: drive.controls)
                return (script, analysis)
            }
        }.value

        var saved = 0
        var failure: String?
        for (script, analysis) in scored {
            do {
                try saveDemoDrive(script, analysis: analysis, vehicleId: content.vehicle.id)
                saved += 1
            } catch {
                failure = error.localizedDescription
            }
        }
        for entry in content.extraHours { practiceLog.upsert(entry) }
        recomputeScores()
        toast = failure.map { "Loaded \(saved) demo drives; one couldn't be saved: \($0)" }
            ?? "Loaded \(profile.person)'s demo: \(saved) drives."
    }

    func exitDemo() {
        wipeLocalData()
    }

    private func applyDemoSettings(_ profile: DemoProfile, content: DemoContent) {
        let now = Date()
        settings.demoProfile = profile
        settings.driverMode = content.driverMode
        settings.learnerName = content.learnerName
        settings.defaultSupervisor = content.supervisor
        settings.hoursTotalTarget = Self.demoHoursTotal
        settings.hoursNightTarget = Self.demoHoursNight
        settings.activeVehicleId = content.vehicle.id
        settings.disclaimerAcceptedAt = settings.disclaimerAcceptedAt ?? now
        settings.safetyRulesAcceptedAt = settings.safetyRulesAcceptedAt ?? now
        settings.introSeenVersion = IntroView.version
        settings.onboardingComplete = true
        quickStartPending = false
    }

    private func saveDemoDrive(_ script: DemoDriveScript, analysis a: DriveAnalysis, vehicleId: UUID) throws {
        let folder = drives.nextFolderName()
        let url = Storage.folder(folder)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let id = UUID()
        let ended = script.startedAt.addingTimeInterval(a.tripEndT + DemoSynth.parkAfter)
        let sidecar = DriveSidecar(driveId: id.uuidString.lowercased(), videoFile: nil, sensorFile: "sensors.jsonl", videoStartT: nil,
                                   vehicleId: vehicleId.uuidString.lowercased(), device: "demo", startedAt: script.startedAt,
                                   endedAt: ended, recordingMode: "sensors", supervisor: script.supervisor)
        try DriveSidecar.encoder.encode(sidecar).write(to: url.appendingPathComponent("drive.json"), options: .atomic)
        let record = DriveRecord(id: id, folder: folder, vehicleId: vehicleId, startedAt: script.startedAt, endedAt: ended,
                                 distanceM: a.distanceM, durationS: a.durationS, safetyScore: a.safety.score, processed: true,
                                 eventCount: a.events.count, components: a.components)
        drives.add(record)
        try drives.store(analysis: a, for: record)
        if script.supervisor != nil { logPracticeHours(record: record, analysis: a, supervisor: script.supervisor) }
    }
}
