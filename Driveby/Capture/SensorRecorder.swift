//  SensorRecorder.swift — Driveby
//  Phase 1.1 — GPS 1 Hz (BestForNavigation) + accelerometer/gyro 50 Hz → sensors.jsonl.
//  Every `t` is seconds since recording start on the MONOTONIC clock: CoreMotion
//  timestamps and AVFoundation frame times share it, wall clock never enters the log.

import CoreLocation
import CoreMotion
import Foundation

/// Live numbers for the recording HUD (main thread).
struct LiveSensorState: Equatable {
    var speedMps: Double = 0
    var distanceM: Double = 0
    var gpsAccuracy: Double = -1
    var gpsFixes = 0
    var imuSamples = 0
    var hasGPS: Bool { gpsAccuracy >= 0 && gpsAccuracy <= Thresholds.maxGPSAccuracy }
}

final class SensorRecorder: NSObject, CLLocationManagerDelegate {
    static let imuHz = 50.0
    private let G = 9.80665

    private let location = CLLocationManager()
    private let motion = CMMotionManager()
    private let motionQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "driveby.motion"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()

    private let writerLock = NSLock()
    private var _writer: SampleFileWriter?
    private var writer: SampleFileWriter? {
        get { writerLock.lock(); defer { writerLock.unlock() }; return _writer }
        set { writerLock.lock(); _writer = newValue; writerLock.unlock() }
    }
    private var t0: TimeInterval = 0
    private var lastFix: CLLocation?
    private var imuCount = 0          // touched only on motionQueue
    private var lastUIUpdate: TimeInterval = 0

    /// Main-thread callbacks.
    var onState: ((LiveSensorState) -> Void)?
    var onSpeed: ((_ t: Double, _ speed: Double) -> Void)?
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?
    /// Each good GPS fix while recording (for the live coach's braking/speeding cues).
    var onFix: ((_ t: Double, _ fix: CLLocation) -> Void)?
    /// Yaw rate (rad/s) averaged to ~10 Hz while recording (for live cornering cues).
    var onYawRate: ((_ t: Double, _ yawRate: Double) -> Void)?

    /// IMU samples averaged per `onYawRate` call: 50 Hz / 5 = 10 Hz.
    private static let yawAverageSamples = 5
    private var yawSum = 0.0          // touched only on motionQueue
    private var yawCount = 0

    private(set) var state = LiveSensorState()
    private(set) var isRunning = false
    private var monitoringOnly = false

    override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        location.distanceFilter = kCLDistanceFilterNone
        location.activityType = .automotiveNavigation
        location.pausesLocationUpdatesAutomatically = false
    }

    var authorization: CLAuthorizationStatus { location.authorizationStatus }
    func requestLocationPermission() { location.requestWhenInUseAuthorization() }

    var motionAvailable: Bool { motion.isDeviceMotionAvailable }

    /// Location only, no file — used while "armed" for auto-start.
    func startMonitoring() {
        monitoringOnly = true
        location.startUpdatingLocation()
    }

    func stopMonitoring() {
        guard monitoringOnly else { return }
        monitoringOnly = false
        if !isRunning { location.stopUpdatingLocation() }
    }

    /// Start logging. `t0` = MonotonicClock time that defines t = 0. `background` keeps GPS + IMU
    /// alive with the screen off (sensors-only mode).
    func start(writer: SampleFileWriter, t0: TimeInterval, background: Bool) {
        self.writer = writer
        self.t0 = t0
        state = LiveSensorState()
        lastFix = nil
        isRunning = true
        monitoringOnly = false
        if background {
            location.allowsBackgroundLocationUpdates = true
            location.showsBackgroundLocationIndicator = true
        }
        location.startUpdatingLocation()

        guard motion.isDeviceMotionAvailable else { return }
        imuCount = 0
        yawSum = 0
        yawCount = 0
        motion.deviceMotionUpdateInterval = 1.0 / Self.imuHz
        motion.startDeviceMotionUpdates(to: motionQueue) { [weak self] m, _ in
            guard let self, let m, let w = self.writer else { return }
            // CMDeviceMotion.timestamp: seconds since boot on the same mach clock as systemUptime.
            let t = m.timestamp - self.t0
            guard t >= 0 else { return }
            let g = m.gravity, ua = m.userAcceleration, rr = m.rotationRate
            // Specific force in m/s² (+9.81 on the axis pointing UP — the convention of the data-contract sample).
            let ax = -(g.x + ua.x) * self.G, ay = -(g.y + ua.y) * self.G, az = -(g.z + ua.z) * self.G
            // Yaw rate = rotation about the vertical (orientation-free, no quaternion math needed).
            let gn = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
            let yaw = gn > 1e-6 ? -(rr.x * g.x + rr.y * g.y + rr.z * g.z) / gn : 0
            w.append(SampleLine.imu(t: t, ax: ax, ay: ay, az: az, gx: rr.x, gy: rr.y, gz: rr.z, yaw: yaw))
            self.imuCount += 1
            self.yawSum += yaw
            self.yawCount += 1
            if self.yawCount == Self.yawAverageSamples {
                let mean = self.yawSum / Double(self.yawCount)
                self.yawSum = 0
                self.yawCount = 0
                DispatchQueue.main.async { self.onYawRate?(t, mean) }
            }
            if self.imuCount % 50 == 0 {
                let c = self.imuCount
                DispatchQueue.main.async { self.state.imuSamples = c; self.onState?(self.state) }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        motion.stopDeviceMotionUpdates()
        location.stopUpdatingLocation()
        location.allowsBackgroundLocationUpdates = false
        writer = nil
    }

    // MARK: CLLocationManagerDelegate (main thread)

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let nowMono = MonotonicClock.now()
        let nowWall = Date()
        for loc in locations {
            // Convert the fix's wall-clock timestamp onto the monotonic clock.
            let fixMono = nowMono - nowWall.timeIntervalSince(loc.timestamp)
            let t = fixMono - t0
            let spd: Double? = loc.speed >= 0 ? loc.speed : nil
            let hdg: Double? = loc.course >= 0 ? loc.course : nil
            let acc = loc.horizontalAccuracy

            if isRunning, let w = writer, t >= 0, acc >= 0 {
                w.append(SampleLine.gps(t: t, lat: loc.coordinate.latitude, lon: loc.coordinate.longitude,
                                        spd: spd, acc: acc, hdg: hdg))
                if acc <= Thresholds.maxGPSAccuracy {
                    if let last = lastFix, last.horizontalAccuracy <= Thresholds.maxGPSAccuracy {
                        state.distanceM += loc.distance(from: last)
                    }
                    lastFix = loc
                    onFix?(t, loc)
                }
                state.gpsFixes += 1
            }
            state.speedMps = spd ?? state.speedMps
            state.gpsAccuracy = acc
            onSpeed?(isRunning ? t : fixMono, spd ?? 0)
        }
        onState?(state)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        state.gpsAccuracy = -1
        onState?(state)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChange?(manager.authorizationStatus)
    }
}
