import AVFoundation
import CoreLocation
import Foundation

final class DemoClipPlayer {
    struct Detection: Equatable {
        var faces = 0
        var vehicles = 0
        var plates = 0
        var leadDistance: Double?
        var leadRect: CGRect?
        var t = 0.0
    }

    static let tickHz = 15.0

    static var videoURL: URL? { Bundle.main.url(forResource: DemoClip.resource, withExtension: DemoClip.fileExtension) }

    let player: AVPlayer
    private let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
    ])
    private let log: SensorLog
    private let redactor = Redactor()
    private let queue = DispatchQueue(label: "driveby.democlip", qos: .userInitiated)

    private var writer: RedactingVideoWriter?
    private var sensorWriter: SampleFileWriter?
    private var videoFile: URL?
    private var timer: Timer?
    private var t0: TimeInterval = 0
    private var videoStarted = false
    private var frameInFlight = false
    private var ended = false
    private var gpsIndex = 0
    private var imuIndex = 0
    private var lastFix: CLLocation?
    private var focalPx: Double?
    private var state = LiveSensorState()

    var onState: ((LiveSensorState) -> Void)?
    var onSpeed: ((_ t: Double, _ speed: Double) -> Void)?
    var onFix: ((_ t: Double, _ fix: CLLocation) -> Void)?
    var onYawRate: ((_ t: Double, _ yawRate: Double) -> Void)?
    var onDetection: ((Detection) -> Void)?
    var onVideoStarted: ((_ start: Double, _ focal: Double?, _ width: Int, _ height: Int) -> Void)?
    var onEnded: (() -> Void)?

    init?(log: SensorLog) {
        guard let url = Self.videoURL else { return nil }
        let item = AVPlayerItem(url: url)
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .pause
        self.log = log
    }

    func start(videoFile: URL, sensorWriter: SampleFileWriter, t0: TimeInterval) {
        self.videoFile = videoFile
        self.sensorWriter = sensorWriter
        self.t0 = t0
        queue.async { self.redactor.prepare() }
        let timer = Timer(timeInterval: 1 / Self.tickHz, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop(completion: @escaping (CameraRecorder.Summary?) -> Void) {
        timer?.invalidate()
        timer = nil
        player.pause()
        sensorWriter = nil
        queue.async {
            guard let w = self.writer else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self.writer = nil
            let summary = CameraRecorder.Summary(videoStartT: w.firstT, videoEndT: w.lastT, framesWritten: w.framesWritten,
                                                 framesDropped: w.framesDropped, focalPx: self.focalPx,
                                                 width: w.dimensions?.width, height: w.dimensions?.height,
                                                 interrupted: false, interruptionReason: nil)
            w.finish { _ in DispatchQueue.main.async { completion(summary) } }
        }
    }

    private var sensorTime: Double {
        guard videoStarted else { return min(MonotonicClock.now() - t0, DemoClip.videoDelay) }
        return DemoClip.videoDelay + max(CMTimeGetSeconds(player.currentTime()), 0)
    }

    private func tick() {
        if !videoStarted && MonotonicClock.now() - t0 >= DemoClip.videoDelay {
            videoStarted = true
            player.play()
        }
        replaySensors(upTo: sensorTime)
        if videoStarted { pullFrame() }
        let finished = videoStarted && player.timeControlStatus == .paused && gpsIndex >= log.gps.count
        if finished && !ended {
            ended = true
            onEnded?()
        }
    }

    private func replaySensors(upTo t: Double) {
        while imuIndex < log.imu.count, log.imu[imuIndex].t <= t {
            let s = log.imu[imuIndex]
            sensorWriter?.append(SampleLine.imu(t: s.t, ax: s.ax, ay: s.ay, az: s.az, gx: s.gx, gy: s.gy, gz: s.gz, yaw: s.yaw))
            if let yaw = s.yaw { onYawRate?(s.t, yaw) }
            imuIndex += 1
            state.imuSamples = imuIndex
        }
        while gpsIndex < log.gps.count, log.gps[gpsIndex].t <= t {
            let g = log.gps[gpsIndex]
            sensorWriter?.append(SampleLine.gps(t: g.t, lat: g.lat, lon: g.lon, spd: g.spd, acc: g.acc, hdg: g.hdg))
            let fix = CLLocation(coordinate: CLLocationCoordinate2D(latitude: g.lat, longitude: g.lon), altitude: 0,
                                 horizontalAccuracy: g.acc, verticalAccuracy: -1, course: g.hdg ?? -1, speed: g.spd ?? -1,
                                 timestamp: Date())
            if let last = lastFix { state.distanceM += fix.distance(from: last) }
            lastFix = fix
            state.speedMps = g.spd ?? state.speedMps
            state.gpsAccuracy = g.acc
            state.gpsFixes += 1
            gpsIndex += 1
            onFix?(g.t, fix)
            onSpeed?(g.t, g.spd ?? 0)
            onState?(state)
        }
    }

    private func pullFrame() {
        guard !frameInFlight else { return }
        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        guard itemTime.isValid, output.hasNewPixelBuffer(forItemTime: itemTime),
              let pb = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else { return }
        frameInFlight = true
        queue.async { self.process(pb, itemTime: itemTime) }
    }

    private func process(_ pb: CVPixelBuffer, itemTime: CMTime) {
        let t = DemoClip.videoDelay + CMTimeGetSeconds(itemTime)
        var detection: Detection?
        if let sample = Self.sampleBuffer(pb, pts: itemTime) {
            if writer == nil, let url = videoFile { writer = RedactingVideoWriter(url: url, redactor: redactor) }
            let wasEmpty = (writer?.framesWritten ?? 0) == 0
            let result = writer?.append(sample, t: t)
            let width = CVPixelBufferGetWidth(pb), height = CVPixelBufferGetHeight(pb)
            let focal = DemoClip.focalPx(width: width)
            focalPx = focal
            if wasEmpty, let w = writer, w.framesWritten > 0, let start = w.firstT {
                DispatchQueue.main.async { self.onVideoStarted?(start, focal, width, height) }
            }
            if let result, result.analyzed {
                var d = Detection(faces: result.faceCount, vehicles: result.vehicleCount, plates: result.plateCount, t: t)
                if let lead = result.lead, lead.widthPx > 1 {
                    let dist = Thresholds.vehicleRealWidth * focal / lead.widthPx
                    let r = lead.rectTopLeft
                    d.leadDistance = dist
                    d.leadRect = r
                    sensorWriter?.append(SampleLine.lead(LeadSample(t: t, bx: Double(r.minX), by: Double(r.minY),
                                                                    bw: Double(r.width), bh: Double(r.height), dist: dist)))
                }
                detection = d
            }
        }
        DispatchQueue.main.async {
            self.frameInFlight = false
            if let detection { self.onDetection?(detection) }
        }
    }

    private static func sampleBuffer(_ pb: CVPixelBuffer, pts: CMTime) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: format,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}
