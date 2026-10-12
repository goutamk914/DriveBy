import Foundation

struct Vehicle: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var make: String
    var model: String
    var year: Int
    var epaId: Int? = nil
    var epaCity: Double? = nil
    var epaHwy: Double? = nil
    var epaCombined: Double? = nil
    var massKg: Double = 1500
    var fuelType: String? = nil
    var atvType: String? = nil
    var regenFactor: Double = 0
    var trim: String? = nil

    var displayName: String { "\(year) \(make) \(model)" }

    var params: VehicleParams { VehicleParams(massKg: massKg, regenFactor: regenFactor, epaCombined: epaCombined) }

    static func defaultRegen(atvType: String?) -> Double {
        let s = atvType?.lowercased() ?? ""
        if s.contains("plug") { return 0.6 }
        if s.contains("hybrid") { return 0.5 }
        if s == "ev" || s.contains("electric") { return 0.65 }
        return 0
    }

    enum CodingKeys: String, CodingKey {
        case id, make, model, year, trim
        case epaId = "epa_id", epaCity = "epa_city", epaHwy = "epa_hwy", epaCombined = "epa_combined"
        case massKg = "mass_kg", fuelType = "fuel_type", atvType = "atv_type", regenFactor = "regen_factor"
    }
}

struct FuelLog: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var vehicleId: UUID?
    var loggedAt: Date
    var odometerMi: Double
    var gallons: Double
    var priceTotal: Double?
    var filledToFull: Bool = true

    var pricePerGallon: Double? {
        guard let p = priceTotal, gallons > 0 else { return nil }
        return p / gallons
    }

    enum CodingKeys: String, CodingKey {
        case id, vehicleId = "vehicle_id", loggedAt = "logged_at", odometerMi = "odometer_mi"
        case gallons, priceTotal = "price_total", filledToFull = "filled_to_full"
    }
}

struct DriveRecord: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var folder: String
    var vehicleId: UUID?
    var startedAt: Date
    var endedAt: Date?
    var distanceM: Double?
    var durationS: Double?
    var efficiencyScore: Double?
    var safetyScore: Double?
    var fuelGal: Double?
    var processed: Bool = false
    var processingError: String? = nil
    var hasVideo: Bool = false
    var eventCount: Int = 0
    var syncedAt: Date? = nil
    var components: EfficiencyComponents? = nil

    var miles: Double? { distanceM.map(Units.miles) }

    enum CodingKeys: String, CodingKey {
        case id, folder, vehicleId = "vehicle_id", startedAt = "started_at", endedAt = "ended_at"
        case distanceM = "distance_m", durationS = "duration_s", efficiencyScore = "efficiency_score"
        case safetyScore = "safety_score", fuelGal = "fuel_gal", processed, processingError = "processing_error"
        case hasVideo = "has_video", eventCount = "event_count", syncedAt = "synced_at", components
    }
}

enum JSONCoding {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return d
    }()
}
