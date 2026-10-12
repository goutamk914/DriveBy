//  Supabase.swift — Driveby
//  Minimal, dependency-free Supabase client (GoTrue auth, PostgREST, Storage) over URLSession.
//  Only derived data leaves the phone: drive summaries, numeric events, and — if the user opts
//  in — blurred event clips. Raw video and the raw sensor log never upload.
//
//  Configure in Driveby/Resources/Config.plist (SUPABASE_URL, SUPABASE_ANON_KEY) or in
//  Settings → Developer. Without it, Driveby runs fully local ("Continue without an account").

import Foundation
import Security

// MARK: - Config

struct SupabaseConfig: Equatable {
    var url: URL
    var anonKey: String

    @MainActor
    static func current(settings: AppSettings) -> SupabaseConfig? {
        var urlString = settings.supabaseURLOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        var key = settings.supabaseKeyOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if urlString.isEmpty || key.isEmpty,
           let path = Bundle.main.path(forResource: "Config", ofType: "plist"),
           let dict = NSDictionary(contentsOfFile: path) as? [String: Any] {
            urlString = (dict["SUPABASE_URL"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            key = (dict["SUPABASE_ANON_KEY"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !urlString.isEmpty, !key.isEmpty, let url = URL(string: urlString), url.scheme == "https" else { return nil }
        return SupabaseConfig(url: url, anonKey: key)
    }
}

// MARK: - Keychain

enum Keychain {
    private static let service = "org.driveby.auth"

    static func set(_ data: Data?, for account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let data else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }
}

// MARK: - Session

struct AuthSession: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var userId: String
    var email: String?

    var needsRefresh: Bool { expiresAt.timeIntervalSinceNow < 120 }

    static func load() -> AuthSession? {
        Keychain.get("session").flatMap { try? JSONDecoder().decode(AuthSession.self, from: $0) }
    }

    func save() { Keychain.set(try? JSONEncoder().encode(self), for: "session") }
    static func clear() { Keychain.set(nil, for: "session") }
}

enum SupabaseError: LocalizedError {
    case notConfigured, notSignedIn, http(Int, String), confirmEmail, decoding

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Cloud sync isn't configured for this build."
        case .notSignedIn: return "Sign in to sync."
        case .http(let code, let msg): return msg.isEmpty ? "Server error \(code)." : msg
        case .confirmEmail: return "Check your email to confirm your account, then sign in."
        case .decoding: return "Unexpected response from the server."
        }
    }
}

// MARK: - Client

final class SupabaseClient: @unchecked Sendable {
    let config: SupabaseConfig
    private let lock = NSLock()
    private var _session: AuthSession?

    var session: AuthSession? {
        get { lock.lock(); defer { lock.unlock() }; return _session }
        set { lock.lock(); _session = newValue; lock.unlock(); if let s = newValue { s.save() } else { AuthSession.clear() } }
    }

    init(config: SupabaseConfig) {
        self.config = config
        _session = AuthSession.load()
    }

    private func endpoint(_ path: String) -> URL { config.url.appendingPathComponent(path) }

    private func request(_ url: URL, method: String = "GET", json: Any? = nil, body: Data? = nil,
                         contentType: String? = nil, auth: Bool = true, headers: [String: String] = [:]) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        if auth {
            let token = try await validAccessToken()
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            req.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        }
        if let json {
            // JSONSerialization raises (crashes) on NaN/Infinity — scrub them to null first.
            req.httpBody = try JSONSerialization.data(withJSONObject: Self.sanitize(json))
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let body {
            req.httpBody = body
            if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await HTTP.session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            var msg = ""
            if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                msg = (o["msg"] as? String) ?? (o["message"] as? String) ?? (o["error_description"] as? String) ?? (o["error"] as? String) ?? ""
            }
            throw SupabaseError.http(code, msg)
        }
        return data
    }

    static func sanitize(_ v: Any) -> Any {
        switch v {
        case let d as Double: return d.isFinite ? d : NSNull()
        case let f as Float: return f.isFinite ? Double(f) : NSNull()
        case let a as [Any]: return a.map(sanitize)
        case let o as [String: Any]: return o.mapValues(sanitize)
        default: return v
        }
    }

    // MARK: Auth (GoTrue)

    private func storeSession(from data: Data) throws -> AuthSession {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SupabaseError.decoding }
        guard let access = o["access_token"] as? String, let refresh = o["refresh_token"] as? String,
              let user = o["user"] as? [String: Any], let uid = user["id"] as? String else {
            if o["id"] != nil || o["user"] != nil { throw SupabaseError.confirmEmail }
            throw SupabaseError.decoding
        }
        let expiresIn = (o["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        let s = AuthSession(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(expiresIn),
                            userId: uid, email: user["email"] as? String)
        session = s
        return s
    }

    func signUp(email: String, password: String) async throws -> AuthSession {
        let data = try await request(endpoint("auth/v1/signup"), method: "POST", json: ["email": email, "password": password], auth: false)
        return try storeSession(from: data)
    }

    func signIn(email: String, password: String) async throws -> AuthSession {
        var comps = URLComponents(url: endpoint("auth/v1/token"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "grant_type", value: "password")]
        let data = try await request(comps.url!, method: "POST", json: ["email": email, "password": password], auth: false)
        return try storeSession(from: data)
    }

    func refresh() async throws -> AuthSession {
        guard let s = session else { throw SupabaseError.notSignedIn }
        var comps = URLComponents(url: endpoint("auth/v1/token"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
        do {
            let data = try await request(comps.url!, method: "POST", json: ["refresh_token": s.refreshToken], auth: false)
            return try storeSession(from: data)
        } catch SupabaseError.http(let code, _) where code == 400 || code == 401 {
            session = nil
            throw SupabaseError.notSignedIn
        }
    }

    func validAccessToken() async throws -> String {
        guard let s = session else { throw SupabaseError.notSignedIn }
        if s.needsRefresh { return try await refresh().accessToken }
        return s.accessToken
    }

    func signOut() async {
        if session != nil { _ = try? await request(endpoint("auth/v1/logout"), method: "POST") }
        session = nil
    }

    // MARK: PostgREST

    func upsert(_ table: String, rows: [[String: Any]]) async throws {
        guard !rows.isEmpty else { return }
        var comps = URLComponents(url: endpoint("rest/v1/\(table)"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "on_conflict", value: "id")]
        _ = try await request(comps.url!, method: "POST", json: rows,
                              headers: ["Prefer": "resolution=merge-duplicates,return=minimal"])
    }

    func insert(_ table: String, rows: [[String: Any]]) async throws {
        guard !rows.isEmpty else { return }
        _ = try await request(endpoint("rest/v1/\(table)"), method: "POST", json: rows, headers: ["Prefer": "return=minimal"])
    }

    func delete(_ table: String, column: String = "id", equals value: String) async throws {
        var comps = URLComponents(url: endpoint("rest/v1/\(table)"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: column, value: "eq.\(value)")]
        _ = try await request(comps.url!, method: "DELETE", headers: ["Prefer": "return=minimal"])
    }

    func rpc(_ fn: String, params: [String: Any] = [:], auth: Bool = true) async throws -> Data {
        try await request(endpoint("rest/v1/rpc/\(fn)"), method: "POST", json: params, auth: auth)
    }

    /// Public, world-readable aggregate — no sign-in required.
    func hazardCells() async throws -> [HazardCell] {
        var comps = URLComponents(url: endpoint("rest/v1/hazard_cells"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "select", value: "*"), URLQueryItem(name: "order", value: "event_count.desc"),
                            URLQueryItem(name: "limit", value: "5000")]
        let data = try await request(comps.url!, auth: false)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let f2 = ISO8601DateFormatter()
            return f1.date(from: s) ?? f2.date(from: s) ?? Date()
        }
        return try dec.decode([HazardCell].self, from: data)
    }

    // MARK: Storage (blurred clips only)

    func upload(bucket: String, path: String, file: URL, contentType: String) async throws {
        let data = try Data(contentsOf: file)
        _ = try await request(endpoint("storage/v1/object/\(bucket)/\(path)"), method: "POST", body: data,
                              contentType: contentType, headers: ["x-upsert": "true"])
    }

    func removeObjects(bucket: String, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await request(endpoint("storage/v1/object/\(bucket)"), method: "DELETE", json: ["prefixes": paths])
    }

    func listObjects(bucket: String, prefix: String) async throws -> [String] {
        let data = try await request(endpoint("storage/v1/object/list/\(bucket)"), method: "POST",
                                     json: ["prefix": prefix, "limit": 1000, "offset": 0])
        let arr = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        return arr.compactMap { $0["name"] as? String }.map { prefix.isEmpty ? $0 : "\(prefix)/\($0)" }
    }
}
