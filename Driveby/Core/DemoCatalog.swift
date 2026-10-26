import Foundation

enum DemoProfile: String, CaseIterable, Identifiable, Codable, Sendable {
    case regular, newDriver

    var id: String { rawValue }
    var person: String { self == .regular ? "Jordan" : "Sam" }
    var title: String { self == .regular ? "Regular driver" : "New driver" }
    var summary: String {
        switch self {
        case .regular: return "Three weeks of commutes and errands."
        case .newDriver: return "Permit practice, night hours, paper log."
        }
    }
}

struct DemoContent: Sendable {
    var vehicle: Vehicle
    var fuelLogs: [FuelLog]
    var drives: [DemoDriveScript]
    var extraHours: [PracticeLogEntry]
    var driverMode: DriverMode
    var learnerName: String
    var supervisor: String
}

enum DemoCatalog {
    static let timeZone = TimeZone(identifier: "America/New_York") ?? .current
    static let supervisor = "Dana Rivera"

    static func content(for profile: DemoProfile, now: Date) -> DemoContent {
        profile == .regular ? regular(now: now) : newDriver(now: now)
    }

    private enum Style {
        static let eager = DemoStyle(launch: 2.8, brake: 2.4, cornering: 2.7, mphUnderLimit: 0)
        static let settling = DemoStyle(launch: 2.0, brake: 2.0, cornering: 2.3, mphUnderLimit: 1)
        static let calm = DemoStyle(launch: 1.6, brake: 1.7, cornering: 2.0, mphUnderLimit: 2)
        static let learner = DemoStyle(launch: 2.2, brake: 2.7, cornering: 2.7, mphUnderLimit: 4)
        static let improving = DemoStyle(launch: 1.9, brake: 2.4, cornering: 2.6, mphUnderLimit: 3)
        static let confident = DemoStyle(launch: 1.6, brake: 1.8, cornering: 2.0, mphUnderLimit: 3)
    }

    private struct Trip {
        var daysAgo: Int
        var hour: Int
        var minute: Int
        var route: DemoRoute
        var style: DemoStyle
        var incidents: [DemoIncidentAt] = []
        var lightWaits: [Double] = []
    }

    private struct Practice {
        var daysAgo: Int
        var hour: Int
        var minute: Int
        var laps: Int
        var stops: [StopSignPass.Outcome]
        var style: DemoStyle
        var mistakes: [DemoIncidentAt] = []
    }

    private static func mistakes(turns: [Double], brakes: [Double]) -> [DemoIncidentAt] {
        turns.map { DemoIncidentAt(incident: .fastTurn, at: $0) } + brakes.map { DemoIncidentAt(incident: .suddenBrake, at: $0) }
    }

    private static func regular(now: Date) -> DemoContent {
        let civic = Vehicle(make: "Honda", model: "Civic", year: 2021, epaCity: 30, epaHwy: 37, epaCombined: 33,
                            massKg: 1290, fuelType: "Regular Gasoline", trim: "Sport, 2.0 L, 4 cyl, CVT")
        let work = DemoRoutes.toWork, home = DemoRoutes.toHome
        let store = DemoRoutes.toStore, back = DemoRoutes.fromStore
        let trips: [Trip] = [
            Trip(daysAgo: 19, hour: 7, minute: 52, route: work, style: Style.eager,
                 incidents: [DemoIncidentAt(incident: .speeding(mphOver: 13, seconds: 14), at: 0.35)]),
            Trip(daysAgo: 19, hour: 17, minute: 41, route: home, style: Style.eager,
                 incidents: [DemoIncidentAt(incident: .tailgating(gap: 0.7, seconds: 9), at: 0.4)]),
            Trip(daysAgo: 18, hour: 7, minute: 49, route: work, style: Style.eager,
                 incidents: [DemoIncidentAt(incident: .suddenBrake, at: 0.5)]),
            Trip(daysAgo: 18, hour: 17, minute: 35, route: home, style: Style.eager),
            Trip(daysAgo: 17, hour: 8, minute: 3, route: work, style: Style.eager,
                 incidents: [DemoIncidentAt(incident: .speeding(mphOver: 12, seconds: 12), at: 0.6)]),
            Trip(daysAgo: 15, hour: 11, minute: 20, route: store, style: Style.settling, lightWaits: [70, 30, 25, 35]),
            Trip(daysAgo: 15, hour: 12, minute: 5, route: back, style: Style.settling,
                 incidents: [DemoIncidentAt(incident: .tailgating(gap: 0.8, seconds: 8), at: 0.55)]),
            Trip(daysAgo: 12, hour: 7, minute: 55, route: work, style: Style.settling),
            Trip(daysAgo: 12, hour: 17, minute: 44, route: home, style: Style.settling,
                 incidents: [DemoIncidentAt(incident: .speeding(mphOver: 11, seconds: 10), at: 0.3)]),
            Trip(daysAgo: 11, hour: 7, minute: 51, route: work, style: Style.settling),
            Trip(daysAgo: 10, hour: 17, minute: 39, route: home, style: Style.settling),
            Trip(daysAgo: 8, hour: 10, minute: 30, route: store, style: Style.calm),
            Trip(daysAgo: 8, hour: 11, minute: 10, route: back, style: Style.calm),
            Trip(daysAgo: 5, hour: 7, minute: 50, route: work, style: Style.calm),
            Trip(daysAgo: 5, hour: 17, minute: 42, route: home, style: Style.calm),
            Trip(daysAgo: 4, hour: 7, minute: 53, route: work, style: Style.calm),
            Trip(daysAgo: 3, hour: 17, minute: 37, route: home, style: Style.calm),
            Trip(daysAgo: 2, hour: 7, minute: 48, route: work, style: Style.calm),
            Trip(daysAgo: 2, hour: 17, minute: 40, route: home, style: Style.calm),
        ]
        let fuel = [
            FuelLog(vehicleId: civic.id, loggedAt: date(daysAgo: 20, 18, 10, now: now), odometerMi: 41_212, gallons: 0),
            FuelLog(vehicleId: civic.id, loggedAt: date(daysAgo: 9, 18, 5, now: now), odometerMi: 41_538, gallons: 10.4, priceTotal: 38.17),
        ]
        let drives = trips.enumerated().map { i, trip in script(trip, seed: UInt64(100 + i), supervisor: nil, now: now) }
        return DemoContent(vehicle: civic, fuelLogs: fuel, drives: drives, extraHours: [], driverMode: .regular,
                           learnerName: "", supervisor: "")
    }

    private static func newDriver(now: Date) -> DemoContent {
        let corolla = Vehicle(make: "Toyota", model: "Corolla", year: 2016, epaCity: 28, epaHwy: 36, epaCombined: 31,
                              massKg: 1300, fuelType: "Regular Gasoline", trim: "LE, 1.8 L, 4 cyl, CVT")
        let allFull = { (count: Int) in [StopSignPass.Outcome](repeating: .fullStop, count: count) }
        let practice: [Practice] = [
            Practice(daysAgo: 27, hour: 16, minute: 30, laps: 3, stops: [.rolling, .missed, .rolling, .rolling, .fullStop, .rolling],
                     style: Style.learner, mistakes: mistakes(turns: [0.1, 0.42, 0.75], brakes: [0.25, 0.6])),
            Practice(daysAgo: 24, hour: 17, minute: 0, laps: 3, stops: [.rolling, .fullStop, .fullStop, .rolling, .rolling, .fullStop],
                     style: Style.learner, mistakes: mistakes(turns: [0.2, 0.7], brakes: [0.45])),
            Practice(daysAgo: 21, hour: 21, minute: 5, laps: 4,
                     stops: [.fullStop, .rolling, .fullStop, .fullStop, .fullStop, .rolling, .fullStop, .fullStop], style: Style.improving,
                     mistakes: mistakes(turns: [0.55], brakes: [])),
            Practice(daysAgo: 19, hour: 16, minute: 15, laps: 3, stops: [.fullStop, .fullStop, .rolling, .fullStop, .fullStop, .fullStop],
                     style: Style.improving),
            Practice(daysAgo: 13, hour: 21, minute: 0, laps: 4, stops: allFull(8), style: Style.confident),
            Practice(daysAgo: 6, hour: 21, minute: 10, laps: 4, stops: allFull(8), style: Style.confident),
            Practice(daysAgo: 3, hour: 16, minute: 20, laps: 3, stops: allFull(6), style: Style.confident),
        ]
        let trips: [Trip] = [
            Trip(daysAgo: 16, hour: 7, minute: 10, route: DemoRoutes.toSchool, style: Style.improving),
            Trip(daysAgo: 16, hour: 14, minute: 35, route: DemoRoutes.fromSchool, style: Style.improving),
            Trip(daysAgo: 10, hour: 16, minute: 0, route: DemoRoutes.toStore, style: Style.confident),
            Trip(daysAgo: 10, hour: 16, minute: 40, route: DemoRoutes.fromStore, style: Style.confident,
                 incidents: [DemoIncidentAt(incident: .speeding(mphOver: 11, seconds: 9), at: 0.6)]),
            Trip(daysAgo: 2, hour: 7, minute: 12, route: DemoRoutes.toSchool, style: Style.confident),
        ]
        let laps = practice.enumerated().map { i, p in
            DemoDriveScript(startedAt: date(daysAgo: p.daysAgo, p.hour, p.minute, now: now),
                            route: DemoRoute.laps(DemoRoutes.lap, count: p.laps), style: p.style, stopOutcomes: p.stops,
                            incidents: p.mistakes, seed: UInt64(200 + i), supervisor: supervisor)
        }
        let outings = trips.enumerated().map { i, trip in script(trip, seed: UInt64(300 + i), supervisor: supervisor, now: now) }
        let extra = [
            PracticeLogEntry(startedAt: date(daysAgo: 30, 12, 0, now: now), durationS: 14.5 * 3600, nightS: 3 * 3600,
                             supervisor: supervisor, notes: "Imported from paper log (16 sessions)", manual: true),
            PracticeLogEntry(startedAt: date(daysAgo: 26, 13, 0, now: now), durationS: 75 * 60, nightS: 0,
                             supervisor: supervisor, notes: "Merging practice on the Greenway", manual: true),
            PracticeLogEntry(startedAt: date(daysAgo: 9, 20, 30, now: now), durationS: 50 * 60, nightS: 50 * 60,
                             supervisor: supervisor, notes: "Parking lot practice after dark", manual: true),
        ]
        return DemoContent(vehicle: corolla, fuelLogs: [], drives: laps + outings, extraHours: extra, driverMode: .newDriver,
                           learnerName: "Sam Rivera", supervisor: supervisor)
    }

    private static func script(_ trip: Trip, seed: UInt64, supervisor: String?, now: Date) -> DemoDriveScript {
        DemoDriveScript(startedAt: date(daysAgo: trip.daysAgo, trip.hour, trip.minute, now: now), route: trip.route,
                        style: trip.style, lightWaits: trip.lightWaits, incidents: trip.incidents, seed: seed,
                        supervisor: supervisor)
    }

    static func date(daysAgo: Int, _ hour: Int, _ minute: Int, now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now)) ?? now
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }
}
