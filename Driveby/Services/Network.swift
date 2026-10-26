import Foundation

enum HTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 90
        c.waitsForConnectivity = false
        c.httpAdditionalHeaders = ["User-Agent": "Driveby/1.0 (iOS; Congressional App Challenge VA-10)"]
        return URLSession(configuration: c)
    }()
}

actor OverpassClient {
    static let shared = OverpassClient()
    private let endpoints = [URL(string: "https://overpass-api.de/api/interpreter")!,
                             URL(string: "https://overpass.kumi.systems/api/interpreter")!]
    private let cacheDir: URL = {
        let u = Storage.caches.appendingPathComponent("overpass", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    private let maxAge: TimeInterval = 60 * 86_400

    struct MapData: Sendable { var ways: [OSMWay]; var controls: [OSMControl] }

    func mapData(for tiles: [SpeedLimits.Tile]) async -> MapData? {
        var byId: [Int64: OSMWay] = [:]
        var tileData: [Data] = []
        for tile in tiles {
            guard let data = await self.tileData(tile) else { return nil }
            tileData.append(data)
            for w in SpeedLimits.parseOverpass(data) { byId[w.id] = w }
        }
        let ways = Array(byId.values)
        var controls: [Int64: OSMControl] = [:]
        for data in tileData { for c in SpeedLimits.parseControls(data, ways: ways) { controls[c.id] = c } }
        return MapData(ways: ways, controls: Array(controls.values))
    }

    private func tileData(_ tile: SpeedLimits.Tile) async -> Data? {
        let file = cacheDir.appendingPathComponent("\(SpeedLimits.overpassCacheVersion)_\(tile.key).json")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let mod = attrs[.modificationDate] as? Date, Date().timeIntervalSince(mod) < maxAge,
           let data = try? Data(contentsOf: file) {
            return data
        }
        let query = SpeedLimits.overpassQuery(for: tile)
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = "data=" + (query.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        for attempt in 0..<4 {
            let endpoint = endpoints[attempt % endpoints.count]
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(body.utf8)
            do {
                let (data, resp) = try await HTTP.session.data(for: req)
                if (resp as? HTTPURLResponse)?.statusCode == 200,
                   (try? JSONSerialization.jsonObject(with: data)) != nil {
                    try? data.write(to: file, options: .atomic)
                    return data
                }
            } catch {}
            try? await Task.sleep(nanoseconds: UInt64(1_500_000_000) * UInt64(attempt + 1))
        }
        return try? Data(contentsOf: file)
    }
}

struct EPAMenuItem: Hashable, Identifiable {
    var text: String
    var value: String
    var id: String { value }
}

struct EPAVehicle {
    var id: Int
    var year: Int
    var make: String
    var model: String
    var city: Double?
    var highway: Double?
    var combined: Double?
    var fuelType: String?
    var atvType: String?
    var vClass: String?
}

enum FuelEconomyAPI {
    static let base = "https://www.fueleconomy.gov/ws/rest/vehicle"

    enum Failure: LocalizedError {
        case offline, badResponse
        var errorDescription: String? {
            switch self {
            case .offline: return "Couldn't reach fueleconomy.gov. Enter the car manually."
            case .badResponse: return "fueleconomy.gov returned something unexpected."
            }
        }
    }

    private static func get(_ path: String, query: [URLQueryItem] = []) async throws -> Any {
        var comps = URLComponents(string: base + path)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await HTTP.session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.badResponse }
            return try JSONSerialization.jsonObject(with: data)
        } catch let e as Failure { throw e } catch { throw Failure.offline }
    }

    private static func menu(_ obj: Any) -> [EPAMenuItem] {
        guard let root = obj as? [String: Any] else { return [] }
        let raw: [[String: Any]]
        if let arr = root["menuItem"] as? [[String: Any]] { raw = arr }
        else if let one = root["menuItem"] as? [String: Any] { raw = [one] }
        else { raw = [] }
        return raw.compactMap { m in
            guard let t = string(m["text"]), let v = string(m["value"]) else { return nil }
            return EPAMenuItem(text: t, value: v)
        }
    }

    private static func string(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    private static func double(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    static func years() async throws -> [EPAMenuItem] { menu(try await get("/menu/year")) }

    static func makes(year: String) async throws -> [EPAMenuItem] {
        menu(try await get("/menu/make", query: [URLQueryItem(name: "year", value: year)]))
    }

    static func models(year: String, make: String) async throws -> [EPAMenuItem] {
        menu(try await get("/menu/model", query: [URLQueryItem(name: "year", value: year), URLQueryItem(name: "make", value: make)]))
    }

    static func options(year: String, make: String, model: String) async throws -> [EPAMenuItem] {
        menu(try await get("/menu/options", query: [URLQueryItem(name: "year", value: year), URLQueryItem(name: "make", value: make),
                                                    URLQueryItem(name: "model", value: model)]))
    }

    static func vehicle(id: String) async throws -> EPAVehicle {
        guard let o = try await get("/\(id)") as? [String: Any] else { throw Failure.badResponse }
        return EPAVehicle(id: Int(string(o["id"]) ?? id) ?? 0,
                          year: Int(string(o["year"]) ?? "") ?? 0,
                          make: string(o["make"]) ?? "", model: string(o["model"]) ?? "",
                          city: double(o["city08"]), highway: double(o["highway08"]), combined: double(o["comb08"]),
                          fuelType: string(o["fuelType"]), atvType: string(o["atvType"]), vClass: string(o["VClass"]))
    }
}
