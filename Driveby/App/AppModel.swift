import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    let drives: DriveStore
    let garage: GarageStore
    let practiceLog: PracticeLogStore
    let obd: OBDManager
    let sync: SyncService
    let recorder: RecordingController

    private(set) var baseModel: ScoringModel
    private(set) var model: ScoringModel
    private(set) var processing: Set<UUID> = []
    var toast: String?
    var quickStartPending: Bool
    var reflectionDriveId: UUID?
    @ObservationIgnored private var awaitingReflection: Set<UUID> = []

    @ObservationIgnored private var queue: [UUID] = []
    @ObservationIgnored private var queueRunning = false

    private static var modelURL: URL { Storage.appSupport.appendingPathComponent("scoring_model.json") }

    init() {
        let settings = AppSettings()
        let drives = DriveStore()
        let garage = GarageStore()
        let practiceLog = PracticeLogStore()
        let obd = OBDManager()
        self.settings = settings
        self.drives = drives
        self.garage = garage
        self.practiceLog = practiceLog
        self.obd = obd
        self.quickStartPending = settings.onboardingComplete && settings.quickStartOnLaunch
        self.sync = SyncService(drives: drives, garage: garage, practiceLog: practiceLog, settings: settings)
        self.recorder = RecordingController(settings: settings, drives: drives, obd: obd)
        let base = Storage.readJSON(ScoringModel.self, from: Self.modelURL, decoder: JSONDecoder()) ?? ScoringModel()
        self.baseModel = base
        self.model = base
        obd.preferredPeripheral = settings.obdPeripheralId
        recorder.onFinished = { [weak self] record in
            self?.awaitingReflection.insert(record.id)
            self?.enqueue(record.id)
        }
        recomputeScores()
    }

    func bootstrap() async {
        for r in recorder.recoverInterruptedDrives() { enqueue(r.id) }
        for r in drives.records where !r.processed && r.processingError == nil && r.endedAt != nil { enqueue(r.id) }
        drives.pruneOldVideos(olderThanDays: settings.keepFullVideoDays)
        if settings.obdEnabled, let id = settings.obdPeripheralId, let uuid = UUID(uuidString: id) { obd.connect(uuid) }
        if sync.isSignedIn { await sync.syncNow() } else { await sync.refreshHazardCells() }
    }

    var activeVehicle: Vehicle? { garage.vehicle(settings.activeVehicleId) ?? garage.vehicles.first }

    var pricePerGallon: Double { garage.latestPricePerGallon(vehicleId: activeVehicle?.id) ?? settings.defaultFuelPrice }

    func enqueue(_ id: UUID) {
        guard !queue.contains(id), !processing.contains(id) else { return }
        queue.append(id)
        runQueue()
    }

    func reprocess(_ r: DriveRecord) {
        var rec = r
        rec.processingError = nil
        drives.update(rec)
        enqueue(r.id)
    }

    private func runQueue() {
        guard !queueRunning else { return }
        queueRunning = true
        Task {
            while !queue.isEmpty {
                let id = queue.removeFirst()
                await processOne(id)
            }
            queueRunning = false
        }
    }

    private func processOne(_ id: UUID) async {
        guard let r = drives.record(id), let side = drives.sidecar(r) else { return }
        processing.insert(id)
        defer { processing.remove(id) }
        let folder = drives.folderURL(r)
        let vehicle = garage.vehicle(r.vehicleId)?.params ?? VehicleParams()
        let outcome = await DriveProcessor.process(folder: folder, sidecar: side, vehicle: vehicle)
        switch outcome {
        case .processed(let analysis):
            do {
                try drives.store(analysis: analysis, for: r)
                var rec = r
                rec.processed = true
                rec.processingError = nil
                rec.distanceM = analysis.distanceM
                rec.durationS = analysis.durationS
                rec.safetyScore = analysis.safety.score
                rec.components = analysis.components
                rec.eventCount = analysis.events.count
                rec.fuelGal = analysis.obdFuelGal
                rec.hasVideo = drives.videoURL(r) != nil
                rec.syncedAt = nil
                drives.update(rec)
                recomputeScores()
                logPracticeHours(record: rec, analysis: analysis, supervisor: side.supervisor)
                if awaitingReflection.remove(id) != nil { reflectionDriveId = id }
                if !analysis.speedLimitsAvailable {
                    toast = "Drive scored. Speed limits weren't available (offline?) — retry from the drive's page."
                }
            } catch {
                markFailed(r, "Couldn't save results: \(error.localizedDescription)")
            }
        case .discarded(let reason):
            awaitingReflection.remove(id)
            drives.delete(r, keepCloudCopy: true)
            toast = reason
        case .failed(let reason):
            markFailed(r, reason)
        }
        if sync.isSignedIn { await sync.syncNow() }
    }

    private func logPracticeHours(record r: DriveRecord, analysis a: DriveAnalysis, supervisor: String?) {
        guard practiceLog.entry(forDrive: r.id) == nil, !practiceLog.removedDrives.contains(r.id), a.durationS >= 60 else { return }
        let start = r.startedAt.addingTimeInterval(a.tripStartT)
        let end = start.addingTimeInterval(a.durationS)
        let p = a.trace.first
        let night = p.map { Solar.nightSeconds(from: start, to: end, lat: $0.lat, lon: $0.lon) } ?? 0
        let who = (supervisor?.isEmpty == false ? supervisor : nil) ?? settings.defaultSupervisor
        practiceLog.upsert(PracticeLogEntry(driveId: r.id, startedAt: start, durationS: a.durationS, nightS: night,
                                            supervisor: who))
    }

    var hoursSummary: HoursSummary { practiceLog.summary(settings.hoursRequirement) }

    func combinedSkills(lastDrives: Int = 10) -> SkillReport {
        SkillReport.combine(drives.processed.prefix(lastDrives).compactMap { drives.analysis($0)?.skills })
    }

    func practicePlan() -> [PracticeFocus] {
        let h = hoursSummary
        return PracticePlanner.plan(skills: combinedSkills(), nightHoursRemaining: h.nightRemaining > 0 ? h.nightRemaining : nil,
                                    maxItems: settings.driverMode == .newDriver ? 2 : 1)
    }

    private func markFailed(_ r: DriveRecord, _ reason: String) {
        var rec = r
        rec.processingError = reason
        drives.update(rec)
    }

    func recomputeScores() {
        let corpus = drives.processed.compactMap(\.components)
        model = baseModel.withCorpus(corpus)
        for var r in drives.processed {
            guard let c = r.components else { continue }
            let s = model.efficiencyScore(c)
            if r.efficiencyScore == nil || abs((r.efficiencyScore ?? 0) - s) > 0.05 {
                if let old = r.efficiencyScore, abs(old - s) > 2 { r.syncedAt = nil }
                r.efficiencyScore = s
                drives.update(r)
            }
        }
    }

    func setBaseModel(_ m: ScoringModel) {
        baseModel = m
        try? Storage.writeJSON(m, to: Self.modelURL, encoder: ScoringModel.encoder)
        recomputeScores()
    }

    func importScoringModel(from url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        var m = try JSONDecoder().decode(ScoringModel.self, from: data)
        if !m.source.hasPrefix("fitted") { m.source = "imported" }
        setBaseModel(m)
    }

    func resetScoringModel() {
        try? FileManager.default.removeItem(at: Self.modelURL)
        baseModel = ScoringModel()
        recomputeScores()
    }

    func validationDrives(vehicleId: UUID?) -> [DriveForValidation] {
        drives.processed.compactMap { r in
            guard let c = r.components, let miles = r.miles, vehicleId == nil || r.vehicleId == vehicleId else { return nil }
            return DriveForValidation(id: r.id, vehicleId: r.vehicleId, startedAt: r.startedAt, miles: miles,
                                      components: c, obdFuelGal: r.fuelGal)
        }
    }

    func localHazardCells() -> [LocalHazardCell] {
        var contributions: [HazardAggregator.Contribution] = []
        for r in drives.processed {
            guard let a = drives.analysis(r) else { continue }
            for e in a.events {
                guard let lat = e.lat, let lon = e.lon else { continue }
                contributions.append(.init(lat: lat, lon: lon, kind: e.kind, driveId: r.id, userKey: "me"))
            }
        }
        return HazardAggregator.localCells(contributions)
    }

    func deleteDrive(_ r: DriveRecord) {
        drives.delete(r)
        recomputeScores()
        if sync.isSignedIn { Task { await sync.syncNow() } }
    }

    func wipeLocalData() {
        drives.wipe()
        garage.wipe()
        practiceLog.wipe()
        resetScoringModel()
        settings.resetAll()
        settings.onboardingComplete = false
        settings.activeVehicleId = nil
        settings.safetyRulesAcceptedAt = nil
        settings.disclaimerAcceptedAt = nil
    }
}
