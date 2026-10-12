//  CameraRecorder.swift — Driveby
//  Decision 1: the phone IS the dashcam. Camera frames and motion samples share one
//  system clock, so the frame at t = 12.400 s and the accelerometer sample at t = 12.400 s
//  are the same moment — no cross-device clock drift to solve.
//
//  720p @ 30 fps (we analyse at ≤15 Hz anyway; bigger files slow everything downstream),
//  stabilisation OFF (it crops and changes the focal length the distance estimate relies on),
//  no audio (in-car conversations are nobody's business).

import AVFoundation
import Foundation
import simd
import UIKit

final class CameraRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum CameraError: LocalizedError {
        case unavailable, notAuthorized, configurationFailed
        var errorDescription: String? {
            switch self {
            case .unavailable: return "No back camera is available on this device."
            case .notAuthorized: return "Camera access is off. Enable it in Settings → Driveby, or record sensors only."
            case .configurationFailed: return "The camera couldn't be configured."
            }
        }
    }

    struct Summary {
        var videoStartT: Double?
        var videoEndT: Double?
        var framesWritten: Int
        var framesDropped: Int
        var focalPx: Double?
        var width: Int?
        var height: Int?
        var interrupted: Bool
        var interruptionReason: String?
    }

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "driveby.camera.session")
    private let videoQueue = DispatchQueue(label: "driveby.camera.video", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var configured = false
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?

    // videoQueue-confined recording state
    private var writer: RedactingVideoWriter?
    private var sensorWriter: SampleFileWriter?
    private var t0: TimeInterval = 0
    private var focalPx: Double?
    private var focalOverride: Double = 0
    private var interrupted = false
    private var interruptionReason: String?
    private var lastLeadUIUpdate: TimeInterval = 0
    let redactor = Redactor()

    /// Main-thread callbacks for the HUD.
    var onInterrupted: ((String) -> Void)?
    var onLiveStats: ((_ faces: Int, _ vehicles: Int, _ plates: Int, _ leadDistance: Double?) -> Void)?
    /// First redacted frame is on disk: video_start_t, focal length and size are now known.
    var onVideoStarted: ((_ videoStartT: Double, _ focalPx: Double?, _ width: Int, _ height: Int) -> Void)?

    static var authorization: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }

    static func requestAccess() async -> Bool { await AVCaptureDevice.requestAccess(for: .video) }

    override init() {
        super.init()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(sessionInterrupted(_:)), name: AVCaptureSession.wasInterruptedNotification, object: session)
        nc.addObserver(self, selector: #selector(sessionError(_:)), name: AVCaptureSession.runtimeErrorNotification, object: session)
        nc.addObserver(self, selector: #selector(thermalChanged), name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: Session

    /// Configure (once) and start the capture session — preview runs, nothing is written.
    func startSession(completion: @escaping (Error?) -> Void) {
        sessionQueue.async {
            do {
                try self.configureIfNeeded()
                if !self.session.isRunning { self.session.startRunning() }
                DispatchQueue.main.async { completion(nil) }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    func stopSession() {
        sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    private func configureIfNeeded() throws {
        guard !configured else { return }
        redactor.prepare()
        do {
            try configureSession()
        } catch {
            // Leave the session clean so a later attempt (e.g. after granting permission) can succeed.
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
            session.commitConfiguration()
            throw error
        }
    }

    private func configureSession() throws {
        guard CameraRecorder.authorization == .authorized else { throw CameraError.notAuthorized }
        guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { throw CameraError.unavailable }
        device = cam
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
        let input = try AVCaptureDeviceInput(device: cam)
        guard session.canAddInput(input) else { throw CameraError.configurationFailed }
        session.addInput(input)

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else { throw CameraError.configurationFailed }
        session.addOutput(output)

        if let conn = output.connection(with: .video) {
            if conn.isVideoStabilizationSupported { conn.preferredVideoStabilizationMode = .off }
            if conn.isCameraIntrinsicMatrixDeliverySupported { conn.isCameraIntrinsicMatrixDeliveryEnabled = true }
        }

        try cam.lockForConfiguration()
        let thirty = CMTime(value: 1, timescale: 30)
        if cam.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameDuration <= thirty && $0.maxFrameDuration >= thirty }) {
            cam.activeVideoMinFrameDuration = thirty
            cam.activeVideoMaxFrameDuration = thirty
        }
        if cam.isFocusModeSupported(.continuousAutoFocus) { cam.focusMode = .continuousAutoFocus }
        if cam.isExposureModeSupported(.continuousAutoExposure) { cam.exposureMode = .continuousAutoExposure }
        cam.unlockForConfiguration()

        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: cam, previewLayer: nil)
        configured = true
    }

    /// Horizon-level rotation for the current physical orientation, locked for the whole drive.
    private func applyCaptureRotation() {
        guard let conn = output.connection(with: .video), let rc = rotationCoordinator else { return }
        let angle = rc.videoRotationAngleForHorizonLevelCapture
        if conn.isVideoRotationAngleSupported(angle) { conn.videoRotationAngle = angle }
    }

    /// Fallback focal length from the format's horizontal field of view (only if intrinsics are unavailable).
    private func fovFocal(width: Int) -> Double? {
        guard let fov = device?.activeFormat.videoFieldOfView, fov > 1 else { return nil }
        return Double(width) / 2 / tan(Double(fov) * .pi / 360)
    }

    // MARK: Recording

    func beginRecording(url: URL, t0: TimeInterval, sensorWriter: SampleFileWriter, detectionHz: Double, focalOverride: Double) {
        sessionQueue.async {
            self.applyCaptureRotation()
            self.videoQueue.async {
                self.redactor.reset()
                self.redactor.minInterval = 1.0 / max(detectionHz, 1)
                self.writer = RedactingVideoWriter(url: url, redactor: self.redactor)
                self.sensorWriter = sensorWriter
                self.t0 = t0
                self.focalPx = nil
                self.focalOverride = focalOverride
                self.interrupted = false
                self.interruptionReason = nil
            }
        }
    }

    /// Stop writing and finalise the file. Completion on the main queue.
    func endRecording(completion: @escaping (Summary) -> Void) {
        sessionQueue.async {
            self.videoQueue.async {
                guard let w = self.writer else {
                    DispatchQueue.main.async { completion(Summary(framesWritten: 0, framesDropped: 0, interrupted: self.interrupted, interruptionReason: self.interruptionReason)) }
                    return
                }
                self.writer = nil
                self.sensorWriter = nil
                let summary = Summary(videoStartT: w.firstT, videoEndT: w.lastT, framesWritten: w.framesWritten,
                                      framesDropped: w.framesDropped, focalPx: self.focalPx,
                                      width: w.dimensions?.width, height: w.dimensions?.height,
                                      interrupted: self.interrupted, interruptionReason: self.interruptionReason)
                w.finish { _ in DispatchQueue.main.async { completion(summary) } }
            }
        }
    }

    /// Camera stopped mid-drive (phone locked, call, overheating). Sensors keep recording.
    private func interrupt(reason: String) {
        videoQueue.async {
            guard let w = self.writer, !self.interrupted else { return }
            self.interrupted = true
            self.interruptionReason = reason
            w.finish { _ in }
            DispatchQueue.main.async { self.onInterrupted?(reason) }
        }
    }

    @objc private func sessionInterrupted(_ n: Notification) { interrupt(reason: "Camera interrupted (phone locked or another app used the camera)") }
    @objc private func sessionError(_ n: Notification) { interrupt(reason: "Camera error") }
    @objc private func thermalChanged() {
        let state = ProcessInfo.processInfo.thermalState
        videoQueue.async {
            switch state {
            case .critical: self.interrupt(reason: "Phone too hot — video stopped, sensors still recording")
            case .serious: self.redactor.minInterval = 1.0 / 6.0
            default: break
            }
        }
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate (videoQueue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let w = writer, !interrupted else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let t = CMTimeGetSeconds(pts) - t0        // capture PTS is on the host (mach) clock = our sensor clock
        guard t >= 0 else { return }

        if focalPx == nil, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let width = CVPixelBufferGetWidth(pb)
            if focalOverride > 0 {
                focalPx = focalOverride * Double(width) / 1280.0
            } else if let data = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil) as? Data,
                      data.count >= MemoryLayout<matrix_float3x3>.size {
                let m = data.withUnsafeBytes { $0.loadUnaligned(as: matrix_float3x3.self) }
                focalPx = Double(m.columns.0.x)
            } else {
                focalPx = fovFocal(width: width)
            }
        }

        let wasEmpty = w.framesWritten == 0
        guard let result = w.append(sampleBuffer, t: t) else { return }
        if wasEmpty, w.framesWritten > 0, let start = w.firstT, let dims = w.dimensions {
            let f = focalPx
            DispatchQueue.main.async { self.onVideoStarted?(start, f, dims.width, dims.height) }
        }

        var leadDist: Double? = nil
        if result.analyzed, let lead = result.lead, let f = focalPx, lead.widthPx > 1 {
            let dist = Thresholds.vehicleRealWidth * f / lead.widthPx
            leadDist = dist
            let r = lead.rectTopLeft
            sensorWriter?.append(SampleLine.lead(LeadSample(t: t, bx: Double(r.minX), by: Double(r.minY),
                                                            bw: Double(r.width), bh: Double(r.height), dist: dist)))
        }
        let now = MonotonicClock.now()
        if now - lastLeadUIUpdate > 0.5 {
            lastLeadUIUpdate = now
            let faces = result.faceCount, vehicles = result.vehicleCount, plates = result.plateCount
            DispatchQueue.main.async { self.onLiveStats?(faces, vehicles, plates, leadDist) }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {}
}
