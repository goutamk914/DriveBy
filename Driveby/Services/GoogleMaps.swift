//  GoogleMaps.swift — Driveby
//  Google Maps Platform integration (optional — everything works without a key):
//
//   • Deep links (no key needed): open any moment or hazard cell in Google Maps or Street View,
//     so a learner can look at the intersection before driving it again.
//   • Roads API — Snap to Roads: draws the drive's route exactly on the road instead of the
//     slightly wobbly GPS trace.
//   • Geocoding API: names the intersection for each moment ("Main St & Oak Ave").
//
//  Results are fetched when a screen opens and kept in memory only (Google's terms limit caching).
//  Speed limits still come from OpenStreetMap: Google's speed-limit data is only sold with an Asset
//  Tracking licence, and Apple's MapKit draws the maps for free.
//
//  Setup: Google Cloud console → enable "Roads API" and "Geocoding API" → create an API key →
//  restrict it to iOS apps with this app's bundle id → paste into Resources/Config.local.plist
//  (GOOGLE_MAPS_API_KEY; that file is git-ignored so the key never lands in the repo), or
//  Settings → About → Developer.

import Foundation
import UIKit

enum GoogleMaps {
    static let configKey = "GOOGLE_MAPS_API_KEY"
    /// Checked in order: the git-ignored local file first, then the shared Config.plist.
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

    // MARK: Deep links (free, no key)

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

    // MARK: Web services (need a key)

    private static func get(_ url: URL) async -> [String: Any]? {
        var req = URLRequest(url: url)
        // Required when the key is restricted to iOS apps (recommended).
        if let bundle = Bundle.main.bundleIdentifier { req.setValue(bundle, forHTTPHeaderField: "X-Ios-Bundle-Identifier") }
        guard let (data, resp) = try? await HTTP.session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Roads API "Snap to Roads" (≤100 points per request, interpolated). Returns [lat, lon] pairs or nil.
    static func snapToRoads(_ points: [[Double]], key: String) async -> [[Double]]? {
        guard points.count >= 2 else { return nil }
        // ~1 point every 25–50 m is plenty; keep requests small.
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
            i += 99   // overlap one point so chunks join
            if i >= sampled.count - 1 { break }   // only the shared point left — already sent
        }
        return snapped.count >= 2 ? snapped : nil
    }

    /// Geocoding API reverse lookup: "Main St & Oak Ave" for intersections, else the street name.
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

/// In-memory, per-session cache for Google results (not persisted, per Google's caching terms).
@MainActor
final class GoogleMapsCache {
    static let shared = GoogleMapsCache()
    var routes: [UUID: [[Double]]] = [:]
    var places: [String: String] = [:]

    func placeKey(_ lat: Double, _ lon: Double) -> String { String(format: "%.5f,%.5f", lat, lon) }
}
