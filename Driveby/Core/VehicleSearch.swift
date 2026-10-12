//  VehicleSearch.swift — Driveby
//  Free-text car search ("2019 honda civic", "chevy silverado", "cr-v") over the EPA make/model menus.
//  Pure Foundation — unit-tested on Linux (Tests/DrivebyCoreTests/VehicleSearchTests.swift).

import Foundation

enum VehicleSearch {
    /// Common nicknames → normalised EPA make names.
    static let aliases: [String: String] = [
        "chevy": "chevrolet", "vw": "volkswagen", "volks": "volkswagen", "mercedes": "mercedesbenz",
        "benz": "mercedesbenz", "merc": "mercedesbenz", "rangerover": "landrover",
        "alfa": "alfaromeo", "caddy": "cadillac", "gm": "gmc", "rolls": "rollsroyce",
    ]

    struct Parsed: Equatable {
        var year: String?
        var make: String?        // as spelled in `makes`
        var rest: [String]       // remaining words (model filter)
    }

    /// Lowercase letters and digits only ("Mercedes-Benz" → "mercedesbenz", "CR-V" → "crv").
    static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    static func words(_ q: String) -> [String] {
        q.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" }).map(String.init).filter { !$0.isEmpty }
    }

    /// Pulls a leading/trailing model year and the longest leading make out of the query.
    static func parse(_ query: String, years: [String], makes: [String]) -> Parsed {
        var w = words(query)
        var year: String?
        if let i = w.firstIndex(where: { $0.count == 4 && Int($0) != nil && years.contains($0) }) {
            year = w[i]
            w.remove(at: i)
        }
        let byNorm = Dictionary(makes.map { (normalize($0), $0) }, uniquingKeysWith: { a, _ in a })
        if !w.isEmpty {
            for k in stride(from: w.count, through: 1, by: -1) {
                let joined = normalize(w[0..<k].joined())
                let key = aliases[joined] ?? joined
                if let make = byNorm[key] { return Parsed(year: year, make: make, rest: Array(w[k...])) }
            }
        }
        return Parsed(year: year, make: nil, rest: w)
    }

    /// Makes matching a partial query (prefix matches first, then substring and nickname matches).
    static func matchMakes(_ query: String, makes: [String]) -> [String] {
        let q = normalize(query)
        guard !q.isEmpty else { return makes.sorted() }
        let aliasTargets = Set(aliases.filter { $0.key.hasPrefix(q) }.map(\.value))
        let scored: [(String, Int)] = makes.compactMap { m in
            let n = normalize(m)
            if n.hasPrefix(q) { return (m, 0) }
            if aliasTargets.contains(n) { return (m, 1) }
            if n.contains(q) { return (m, 2) }
            return nil
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }.map(\.0)
    }

    /// Models containing every remaining word (ignoring case, spaces and dashes); prefix matches first.
    static func matchModels(_ rest: [String], models: [String]) -> [String] {
        let toks = rest.map(normalize).filter { !$0.isEmpty }
        guard !toks.isEmpty else { return models.sorted() }
        let hits = models.filter { m in
            let n = normalize(m)
            return toks.allSatisfy { n.contains($0) }
        }
        return hits.sorted { a, b in
            let pa = normalize(a).hasPrefix(toks[0]), pb = normalize(b).hasPrefix(toks[0])
            return pa != pb ? pa : a < b
        }
    }
}
