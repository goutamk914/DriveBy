import AVFoundation
import CoreLocation
import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class RecordingController {
    enum Phase: Equatable { case idle, armed, recording, finishing }
    enum Mode: String { case camera, sensors }

    private(set) var phase: Phase = .idle
    private(set) var mode: Mode = .camera
    private(set) var startedAt: Date?
    private(set) var live = LiveSensorState()
    private(set) var faces = 0
    private(set) var vehicles = 0
    private(set) var plates = 0
    private(set) var leadDistance: Double?
    private(set) var videoInterruptedReason: String?
    private(set) var cameraError: String?
    private(set) var moving = false
    var message: String?
    private(set) var lastCue: LiveCueEvent?
    private(set) var speedLimitMps: Double?
    private(set) var voiceMuted = false

    @ObservationIgnored let camera = CameraRecorder()
    @ObservationIgnored let sensors = SensorRecorder()
    @ObservationIgnored private var coach = LiveCoach(mode: .regular)
    @ObservationIgnored private let voice = VoiceCoach()
    @ObservationIgnored private let liveLimits = LiveSpeedLimits()
    @ObservationIgnored private var writer: SampleFileWriter?
    @ObservationIgnored private var folderName: String?
    @ObservationIgnored private var driveId = UUID()
    @ObservationIgnored private var t0: TimeInterval = 0
    @ObservationIgnored private var detector = LiveTripDetector()
    @ObservationIgnored private var sidecar: DriveSidecar?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let drives: DriveStore
    @ObservationIgnored private let obd: OBDManager
    @ObservationIgnored var onFinished: ((DriveRecord) -> Void)?

    init(settings: AppSettings, drives: DriveStore, obd: OBDManager) {
        self.settings = settings
        self.drives = drives
        self.obd = obd
        sensors.onState = { [weak self] s in self?.live = s }
        sensors.onSpeed = { [weak self] t, v in self?.handleSpeed(t: t, speed: v) }
        sensors.onFix = { [weak self] t, fix in self?.coachFix(t: t, fix: fix) }
        sensors.onYawRate = { [weak self] t, yaw in self?.coachYaw(t: t, yawRate: yaw) }
        camera.onInterrupted = { [weak self] reason in self?.videoInterruptedReason = reason }
        camera.onVideoStarted = { [weak self] start, focal, w, h in
            guard let self, var side = self.sidecar else { return }
            side.videoStartT = start; side.focalPx = focal; side.videoWidth = w; side.videoHeight = h
            self.sidecar = side
            try? self.writeSidecar(side)
        }
        camera.onLiveStats = { [weak self] f, v, p, d in
            self?.faces = f; self?.vehicles = v; self?.plates = p; self?.leadDistance = d
            self?.coachHeadway(leadDistance: d)
        }
    }

    var isActive: Bool { phase == .recording || phase == .finishing }
    var elapsed: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }
    var currentDriveId: UUID? { phase == .recording ? driveId : nil }

    func startPreview() {
        guard CameraRecorder.authorization == .authorized else { return }
        camera.startSession { [weak self] err in self?.cameraError = err?.localizedDescription }
    }

    func stopPreview() {
        if phase == .idle { camera.stopSession() }
    }

    func arm(vehicleId: UUID?, supervisor: String? = nil) {
        guard phase == .idle else { return }
        armedSupervisor = supervisor
        detector = LiveTripDetector()
        armedVehicleId = vehicleId
        phase = .armed
        sensors.startMonitoring()
        if settings.recordVideo { startPreview() }
    }

    func disarm() {
        guard phase == .armed else { return }
        sensors.stopMonitoring()
        phase = .idle
        camera.stopSession()
    }

    @ObservationIgnored private var armedVehicleId: UUID?
    @ObservationIgnored private var armedSupervisor: String?

    private func handleSpeed(t: Double, speed: Double) {
        let signal = detector.feed(t: t, speed: speed)
        moving = detector.moving
        switch (phase, signal) {
        case (.armed, .started):
            sensors.stopMonitoring()
            start(vehicleId: armedVehicleId)
        case (.recording, .parked):
            if settings.autoStop { stop(reason: "Parked for 3 minutes — recording stopped automatically.") }
        default:
            break
        }
    }

    func start(vehicleId: UUID?, supervisor: String? = nil) {
        guard phase == .idle || phase == .armed else { return }
        message = nil
        videoInterruptedReason = nil
        cameraError = nil

        let auth = sensors.authorization
        guard auth == .authorizedWhenInUse || auth == .authorizedAlways else {
            message = "Location access is needed to record a drive. Enable it in Settings → Driveby → Location."
            phase = .idle
            return
        }

        var useCamera = settings.recordVideo && CameraRecorder.authorization == .authorized
        if useCamera && Storage.freeBytes() < 1_000_000_000 {
            useCamera = false
            message = "Less than 1 GB free — recording sensors only (no video)."
        }
        mode = useCamera ? .camera : .sensors

        let folder = drives.nextFolderName()
        let url = Storage.folder(folder)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            driveId = UUID()
            folderName = folder
            let sensorName = "\(folder).jsonl"
            let w = try SampleFileWriter(url: url.appendingPathComponent(sensorName))
            writer = w
            t0 = MonotonicClock.now()
            let now = Date()
            startedAt = now
            let info = Bundle.main.infoDictionary
            let side = DriveSidecar(driveId: driveId.uuidString.lowercased(), videoFile: useCamera ? "\(folder).mov" : nil,
                                    sensorFile: sensorName, videoStartT: nil,
                                    vehicleId: vehicleId?.uuidString.lowercased(), device: Self.deviceModel(), startedAt: now,
                                    appVersion: info?["CFBundleShortVersionString"] as? String,
                                    recordingMode: mode.rawValue, supervisor: supervisor ?? armedSupervisor)
            sidecar = side
            try writeSidecar(side)
            drives.add(DriveRecord(id: driveId, folder: folder, vehicleId: vehicleId, startedAt: now, hasVideo: useCamera))

            detector = LiveTripDetector()
            sensors.start(writer: w, t0: t0, background: true)
            if settings.obdEnabled && obd.isReady { obd.startLogging(writer: w, t0: t0) }
            if useCamera {
                camera.startSession { [weak self] err in
                    guard let self, self.phase == .recording, self.folderName == folder else { return }
                    if let err { self.cameraError = err.localizedDescription; self.mode = .sensors; return }
                    self.camera.beginRecording(url: url.appendingPathComponent("\(folder).mov"), t0: self.t0, sensorWriter: w,
                                               detectionHz: self.settings.detectionHz, focalOverride: self.settings.focalOverride)
                }
            }
            UIApplication.shared.isIdleTimerDisabled = true
            phase = .recording
            startLiveCoaching()
        } catch {
            message = "Couldn't start recording: \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: url)
            phase = .idle
        }
    }

    func stop(reason: String? = nil) {
        guard phase == .recording else { return }
        phase = .finishing
        if let reason { message = reason }
        liveLimits.reset()
        if settings.voiceCoach && !voiceMuted {
            voice.say("Recording stopped. Your coaching is ready.", interrupting: true)
        } else {
            voice.stop()
        }
        sensors.stop()
        obd.stopLogging()
        if mode == .camera {
            camera.endRecording { [weak self] summary in self?.finalize(summary) }
        } else {
            finalize(nil)
        }
    }

    private func finalize(_ summary: CameraRecorder.Summary?) {
        writer?.close()
        writer = nil
        UIApplication.shared.isIdleTimerDisabled = false
        camera.stopSession()

        guard var side = sidecar, let folder = folderName else { phase = .idle; return }
        side.endedAt = Date()
        if summary == nil, let v = side.videoFile {
            try? FileManager.default.removeItem(at: Storage.folder(folder).appendingPathComponent(v))
            side.videoFile = nil
            side.videoStartT = nil
        }
        if let s = summary {
            side.videoStartT = s.videoStartT
            side.videoEndT = s.videoEndT
            side.videoInterrupted = s.interrupted
            side.focalPx = s.focalPx
            side.videoWidth = s.width
            side.videoHeight = s.height
            if s.framesWritten == 0 {
                try? FileManager.default.removeItem(at: Storage.folder(folder).appendingPathComponent(side.videoFile ?? "none"))
                side.videoFile = nil
                side.videoStartT = nil
            }
        }
        try? writeSidecar(side)

        var record = drives.record(driveId) ?? DriveRecord(id: driveId, folder: folder, startedAt: side.startedAt)
        record.endedAt = side.endedAt
        record.hasVideo = side.videoFile != nil
        drives.update(record)
        sidecar = nil
        folderName = nil
        startedAt = nil
        phase = .idle
        onFinished?(record)
    }

    private func writeSidecar(_ s: DriveSidecar) throws {
        guard let folder = folderName else { return }
        let data = try DriveSidecar.encoder.encode(s)
        try data.write(to: Storage.folder(folder).appendingPathComponent("drive.json"), options: .atomic)
    }

    static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return machine.isEmpty ? UIDevice.current.model : machine
    }

    func toggleVoice() {
        voiceMuted.toggle()
        if voiceMuted { voice.stop() }
    }

    private func startLiveCoaching() {
        coach = LiveCoach(mode: settings.driverMode)
        liveLimits.reset()
        lastCue = nil
        speedLimitMps = nil
        voiceMuted = false
        guard settings.voiceCoach else { return }
        voice.say(settings.isNewDriver ? "Recording. Drive safely, I'll speak up if something needs attention." : "Driveby is recording.")
    }

    var sensorTime: Double { phase == .recording ? MonotonicClock.now() - t0 : 0 }

    private func coachFix(t: Double, fix: CLLocation) {
        guard phase == .recording, fix.speed >= 0 else { return }
        let match = liveLimits.match(lat: fix.coordinate.latitude, lon: fix.coordinate.longitude,
                                     heading: fix.course >= 0 ? fix.course : .nan, speed: fix.speed)
        speedLimitMps = match.tagged ? match.limitMps : nil
        deliver(coach.speed(t: t, v: fix.speed, limitMps: match.limitMps, posted: match.tagged))
    }

    private func coachYaw(t: Double, yawRate: Double) {
        guard phase == .recording else { return }
        deliver(coach.yaw(t: t, yawRate: yawRate, v: live.speedMps))
    }

    private func coachHeadway(leadDistance: Double?) {
        guard phase == .recording, mode == .camera else { return }
        deliver(coach.headway(t: sensorTime, leadDistance: leadDistance, v: live.speedMps))
    }

    private func deliver(_ event: LiveCueEvent?) {
        guard let event, settings.voiceCoach else { return }
        lastCue = event
        if !voiceMuted { voice.say(event.cue.phrase(mode: settings.driverMode, limitMph: event.limitMph)) }
    }

    func recoverInterruptedDrives() -> [DriveRecord] {
        var recovered: [DriveRecord] = []
        for r in drives.records where !r.processed && r.processingError == nil && r.id != currentDriveId {
            guard var side = drives.sidecar(r), side.endedAt == nil else { continue }
            let folder = drives.folderURL(r)
            let log = (try? Data(contentsOf: folder.appendingPathComponent(side.sensorFile))).map(SensorLogParser.parse)
            let lastT = log?.lastT ?? 0
            side.endedAt = side.startedAt.addingTimeInterval(lastT)
            side.videoInterrupted = side.videoFile != nil ? true : nil
            if let v = side.videoFile {
                let vURL = folder.appendingPathComponent(v)
                if !FileManager.default.fileExists(atPath: vURL.path) || side.videoStartT == nil {
                    try? FileManager.default.removeItem(at: vURL)
                    side.videoFile = nil
                }
            }
            if let data = try? DriveSidecar.encoder.encode(side) {
                try? data.write(to: folder.appendingPathComponent("drive.json"), options: .atomic)
            }
            var rec = r
            rec.endedAt = side.endedAt
            rec.hasVideo = side.videoFile != nil
            drives.update(rec)
            recovered.append(rec)
        }
        return recovered
    }
}
