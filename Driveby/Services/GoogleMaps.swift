import Foundation
import UIKit

enum GoogleMaps {
    static let configKey = "GOOGLE_MAPS_API_KEY"
    private static let configFiles = ["Config.local", "Config"]

    @MainActor
    static func apiKey(settings: AppSettings) -> String? {
        let override = settings.googleMapsKeyOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty { return override }
        return configFiles.lazy.compactMap(bundledKey(in:)).first
    }

    private static func bundledKey(in file: String) -> String? {
        guard let path = Bundle.main.path(forResource: file, ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: Any],
              let key = (dict[configKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    @MainActor
    static var googleMapsInstalled: Bool {
        guard let url = URL(string: "comgooglemaps://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    @MainActor
    static func mapsURL(lat: Double, lon: Double) -> URL {
        let q = String(format: "%.6f,%.6f", lat, lon)
        if googleMapsInstalled, let app = URL(string: "comgooglemaps://?q=\(q)&center=\(q)&zoom=18&views=satellite") { return app }
        return URL(string: "https://www.google.com/maps/search/?api=1&query=\(q)")!
    }

    @MainActor
    static func streetViewURL(lat: Double, lon: Double) -> URL {
        let q = String(format: "%.6f,%.6f", lat, lon)
        if googleMapsInstalled, let app = URL(string: "comgooglemaps://?center=\(q)&mapmode=streetview") { return app }
        return URL(string: "https://www.google.com/maps/@?api=1&map_action=pano&viewpoint=\(q)")!
    }

    private static func get(_ url: URL) async -> [String: Any]? {
        var req = URLRequest(url: url)
        if let bundle = Bundle.main.bundleIdentifier { req.setValue(bundle, forHTTPHeaderField: "X-Ios-Bundle-Identifier") }
        guard let (data, resp) = try? await HTTP.session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func snapToRoads(_ points: [[Double]], key: String) async -> [[Double]]? {
        guard points.count >= 2 else { return nil }
        let stride = max(points.count / 400, 1)
        let sampled = Swift.stride(from: 0, to: points.count, by: stride).map { points[$0] }
        var snapped: [[Double]] = []
        var i = 0
        while i < sampled.count {
            let chunk = Array(sampled[i..<min(i + 100, sampled.count)])
            let path = chunk.map { String(format: "%.6f,%.6f", $0[0], $0[1]) }.joined(separator: "|")
            var c = URLComponents(string: "https://roads.googleapis.com/v1/snapToRoads")!
            c.queryItems = [URLQueryItem(name: "path", value: path), URLQueryItem(name: "interpolate", value: "true"),
                            URLQueryItem(name: "key", value: key)]
            guard let url = c.url, let json = await get(url),
                  let pts = json["snappedPoints"] as? [[String: Any]] else { return nil }
            for p in pts {
                if let loc = p["location"] as? [String: Any],
                   let la = (loc["latitude"] as? NSNumber)?.doubleValue, let lo = (loc["longitude"] as? NSNumber)?.doubleValue {
                    snapped.append([la, lo])
                }
            }
            i += 99
            if i >= sampled.count - 1 { break }
        }
        return snapped.count >= 2 ? snapped : nil
    }

    static func placeName(lat: Double, lon: Double, key: String) async -> String? {
        for type in ["intersection", "route"] {
            var c = URLComponents(string: "https://maps.googleapis.com/maps/api/geocode/json")!
            c.queryItems = [URLQueryItem(name: "latlng", value: String(format: "%.6f,%.6f", lat, lon)),
                            URLQueryItem(name: "result_type", value: type), URLQueryItem(name: "key", value: key)]
            guard let url = c.url, let json = await get(url) else { return nil }
            if let first = (json["results"] as? [[String: Any]])?.first,
               let address = first["formatted_address"] as? String,
               let name = address.split(separator: ",").first {
                return String(name)
            }
        }
        return nil
    }
}

@MainActor
final class GoogleMapsCache {
    static let shared = GoogleMapsCache()
    var routes: [UUID: [[Double]]] = [:]
    var places: [String: String] = [:]

    func placeKey(_ lat: Double, _ lon: Double) -> String { String(format: "%.5f,%.5f", lat, lon) }
}
