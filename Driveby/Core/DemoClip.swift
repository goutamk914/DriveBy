import Foundation

enum DemoClip {
    static let resource = "DemoDrive"
    static let fileExtension = "mp4"
    static let device = "demo-clip"
    static let videoDelay = 3.0
    static let focalPxAt1280 = 533.0
    static let routeOffset = 900.0
    static let seed: UInt64 = 900
    static let credit = "Demo video: Jabriel on Pexels (Pexels License)"

    static let speedProfile: [DemoSpeedPoint] = [
        (0, 20), (7, 17), (10, 11), (11.3, 5), (11.9, 1.5), (12.4, 0), (13.2, 5), (14.6, 0), (52.3, 0),
        (54.3, 10), (57.3, 15), (59.8, 11), (61.8, 15), (64.3, 24), (67.3, 31), (75.3, 32), (77.8, 25), (80, 13),
        (81.3, 5), (82.2, 0), (83.1, 4), (84.6, 0), (92.6, 0), (94.3, 9), (96.3, 18), (98.5, 28), (100.7, 38),
        (102.6, 47), (104, 53), (111, 53), (117.3, 17), (119.8, 14), (122.3, 22), (125.3, 26), (138.3, 26),
    ].map { DemoSpeedPoint(t: $0.0, mph: $0.1) }

    static var duration: Double { speedProfile.last?.t ?? 0 }

    static var route: DemoRoute { DemoRoutes.toWork.dropping(first: routeOffset) }

    static func script(startedAt: Date, supervisor: String?) -> DemoDriveScript {
        DemoDriveScript(startedAt: startedAt, route: route, style: DemoStyle(), seed: seed, supervisor: supervisor,
                        speedProfile: speedProfile)
    }

    static func drive() -> DemoDrive {
        DemoSynth.synthesize(script(startedAt: Date(timeIntervalSince1970: 0), supervisor: nil))
    }

    static func focalPx(width: Int) -> Double { focalPxAt1280 * Double(width) / 1280 }
}
