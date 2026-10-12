//  OBDParser.swift — Driveby
//  ELM327 (BLE) response parsing for Decision 4: real fuel data per trip.
//  Pure logic, unit tested; the CoreBluetooth transport is Services/OBDManager.swift.
//
//  PIDs used (SAE J1979 mode 01):
//    0C  engine RPM            ((A·256)+B)/4
//    0D  vehicle speed (km/h)  A
//    10  MAF air flow (g/s)    ((A·256)+B)/100
//    5E  engine fuel rate L/h  ((A·256)+B)/20
//    00/20/40  supported-PID bitmasks

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
    /// ELM327 init sequence: reset, echo off, linefeeds off, spaces off, headers off, auto protocol.
    static let initCommands = ["ATZ", "ATE0", "ATL0", "ATS0", "ATH0", "ATSP0"]

    /// Strip prompt, echoes, "SEARCHING...", whitespace; return hex payload lines.
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

    /// Data bytes following "41 <pid>" in a mode-01 response.
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

    /// Parse a supported-PIDs response (0100 / 0120 / 0140) into the set of supported PID hex codes.
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
