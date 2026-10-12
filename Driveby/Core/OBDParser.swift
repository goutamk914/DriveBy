import Foundation

enum OBDPID: String, CaseIterable, Sendable {
    case rpm = "0C", speed = "0D", maf = "10", fuelRate = "5E"

    var command: String { "01" + rawValue }
    var label: String {
        switch self {
        case .rpm: return "Engine RPM (010C)"
        case .speed: return "Vehicle speed (010D)"
        case .maf: return "Mass air flow (0110)"
        case .fuelRate: return "Engine fuel rate (015E)"
        }
    }
}

enum OBDParser {
    static let initCommands = ["ATZ", "ATE0", "ATL0", "ATS0", "ATH0", "ATSP0"]

    static func cleanLines(_ raw: String) -> [String] {
        raw.replacingOccurrences(of: ">", with: "")
            .components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            .map { $0.replacingOccurrences(of: " ", with: "").uppercased() }
            .filter { !$0.isEmpty && !$0.hasPrefix("SEARCHING") && !$0.hasPrefix("BUSINIT") }
    }

    static func isNoData(_ raw: String) -> Bool {
        let u = raw.uppercased()
        return u.contains("NODATA") || u.contains("NO DATA") || u.contains("UNABLETOCONNECT") || u.contains("UNABLE TO CONNECT")
            || u.contains("ERROR") || u.contains("?") || u.contains("STOPPED")
    }

    static func dataBytes(_ raw: String, pid: String) -> [UInt8]? {
        let header = "41" + pid.uppercased()
        for line in cleanLines(raw) {
            guard let r = line.range(of: header) else { continue }
            let hex = String(line[r.upperBound...])
            var bytes: [UInt8] = []
            var idx = hex.startIndex
            while hex.distance(from: idx, to: hex.endIndex) >= 2 {
                let next = hex.index(idx, offsetBy: 2)
                guard let b = UInt8(hex[idx..<next], radix: 16) else { break }
                bytes.append(b)
                idx = next
            }
            if !bytes.isEmpty { return bytes }
        }
        return nil
    }

    static func decode(_ pid: OBDPID, raw: String) -> Double? {
        guard let b = dataBytes(raw, pid: pid.rawValue) else { return nil }
        switch pid {
        case .rpm: return b.count >= 2 ? (Double(b[0]) * 256 + Double(b[1])) / 4 : nil
        case .speed: return b.count >= 1 ? Double(b[0]) : nil
        case .maf: return b.count >= 2 ? (Double(b[0]) * 256 + Double(b[1])) / 100 : nil
        case .fuelRate: return b.count >= 2 ? (Double(b[0]) * 256 + Double(b[1])) / 20 : nil
        }
    }

    static func supportedPIDs(_ raw: String, base: Int) -> Set<String> {
        let pid = String(format: "%02X", base)
        guard let b = dataBytes(raw, pid: pid), b.count >= 4 else { return [] }
        var out = Set<String>()
        for byteIndex in 0..<4 {
            for bit in 0..<8 where b[byteIndex] & (0x80 >> UInt8(bit)) != 0 {
                out.insert(String(format: "%02X", base + byteIndex * 8 + bit + 1))
            }
        }
        return out
    }
}
