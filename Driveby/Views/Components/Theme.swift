//  Theme.swift — Driveby
//  Colours, event styling and formatting helpers shared by every screen.

import SwiftUI

enum Theme {
    static let efficiency = Color(red: 0.09, green: 0.64, blue: 0.29)    // leaf green
    static let safety = Color(red: 0.15, green: 0.39, blue: 0.92)        // road-sign blue
    static let card = Color(.secondarySystemGroupedBackground)
    static let background = Color(.systemGroupedBackground)

    static func scoreColor(_ s: Double?) -> Color {
        guard let s else { return .secondary }
        switch s {
        case 85...: return Color(red: 0.09, green: 0.64, blue: 0.29)
        case 70..<85: return Color(red: 0.85, green: 0.62, blue: 0.05)
        default: return Color(red: 0.86, green: 0.27, blue: 0.20)
        }
    }
}

extension EventKind {
    var color: Color {
        switch self {
        case .hardBrake: return Color(red: 0.86, green: 0.15, blue: 0.15)
        case .hardAccel: return Color(red: 0.92, green: 0.45, blue: 0.05)
        case .harshCorner: return Color(red: 0.55, green: 0.27, blue: 0.85)
        case .speeding: return Color(red: 0.85, green: 0.62, blue: 0.05)
        case .idle: return Color(red: 0.45, green: 0.50, blue: 0.56)
        case .tailgating: return Color(red: 0.86, green: 0.16, blue: 0.47)
        case .laneDrift: return Color(red: 0.05, green: 0.58, blue: 0.53)
        }
    }

    var symbol: String {
        switch self {
        case .hardBrake: return "exclamationmark.octagon.fill"
        case .hardAccel: return "hare.fill"
        case .harshCorner: return "arrow.turn.up.right"
        case .speeding: return "gauge.with.dots.needle.67percent"
        case .idle: return "hourglass"
        case .tailgating: return "car.2.fill"
        case .laneDrift: return "road.lanes"
        }
    }
}

enum Fmt {
    static func miles(_ metres: Double?) -> String {
        guard let m = metres else { return "—" }
        let mi = Units.miles(m)
        return mi < 10 ? String(format: "%.1f mi", mi) : String(format: "%.0f mi", mi)
    }

    static func duration(_ s: Double?) -> String {
        guard let s, s.isFinite else { return "—" }
        let total = Int(s.rounded())
        if total >= 3600 { return "\(total / 3600) h \((total % 3600) / 60) min" }
        if total >= 60 { return "\(total / 60) min" }
        return "\(total) s"
    }

    static func clock(_ s: Double) -> String {
        let t = max(Int(s), 0)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    static func score(_ s: Double?) -> String { s.map { String(format: "%.0f", $0) } ?? "—" }

    static func mph(_ mps: Double?) -> String { mps.map { String(format: "%.0f mph", Units.mph($0)) } ?? "—" }

    static let dayTime: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()
    static let day: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f
    }()
    static let time: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f
    }()
}

/// Rounded card container.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct SectionHeader: View {
    var title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(.secondary) }
        }
    }
}

extension MomentKind {
    var color: Color {
        if isPositive { return Color(red: 0.09, green: 0.64, blue: 0.29) }
        switch self {
        case .rollingStop: return Color(red: 0.92, green: 0.45, blue: 0.05)
        case .missedStop: return Color(red: 0.86, green: 0.15, blue: 0.15)
        default: return EventKind(rawValue: rawValue)?.color ?? .gray
        }
    }

    var symbol: String {
        switch self {
        case .goodStop: return "checkmark.octagon.fill"
        case .smoothStop: return "checkmark.circle.fill"
        case .smoothTurn: return "arrow.turn.up.right"
        case .rollingStop, .missedStop: return "octagon.fill"
        default: return EventKind(rawValue: rawValue)?.symbol ?? "circle.fill"
        }
    }
}

extension Skill {
    var color: Color {
        switch self {
        case .smoothBraking: return Color(red: 0.86, green: 0.15, blue: 0.15)
        case .smoothAcceleration: return Color(red: 0.92, green: 0.45, blue: 0.05)
        case .turns: return Color(red: 0.55, green: 0.27, blue: 0.85)
        case .speedControl: return Color(red: 0.85, green: 0.62, blue: 0.05)
        case .followingDistance: return Color(red: 0.86, green: 0.16, blue: 0.47)
        case .stopSigns: return Color(red: 0.75, green: 0.10, blue: 0.10)
        }
    }
}

extension AppAppearance {
    /// nil follows the phone's setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
}

extension LiveCue {
    var symbol: String {
        switch self {
        case .hardBrake: return EventKind.hardBrake.symbol
        case .hardAccel: return EventKind.hardAccel.symbol
        case .sharpTurn: return EventKind.harshCorner.symbol
        case .speeding: return EventKind.speeding.symbol
        case .tailgating: return EventKind.tailgating.symbol
        case .smoothStop: return "hand.thumbsup.fill"
        }
    }

    var color: Color {
        switch self {
        case .hardBrake: return EventKind.hardBrake.color
        case .hardAccel: return EventKind.hardAccel.color
        case .sharpTurn: return EventKind.harshCorner.color
        case .speeding: return EventKind.speeding.color
        case .tailgating: return EventKind.tailgating.color
        case .smoothStop: return Theme.efficiency
        }
    }
}

/// The one sentence this app must never let anyone miss — worded for the driver's mode.
enum Disclaimer {
    static func short(_ mode: DriverMode) -> String {
        mode == .newDriver ? "Practice tool only — not a driving instructor." : "A coach, not a safety system."
    }

    static func detail(_ mode: DriverMode) -> String {
        mode == .newDriver
            ? "Practise with a licensed adult in the passenger seat. Driveby never replaces your driving instructor."
            : "Eyes on the road, hands off the phone. Driveby speaks its tips so you never need to look."
    }

    static let full = "Driveby is a practice tool. It does not replace a licensed driving instructor or a state-approved driver education course. Always practise with a licensed adult in the front passenger seat, as your learner's permit requires, and follow everything your instructor teaches you."
    static let fullRegular = "Driveby is a coaching tool, not a safety system. Keep your eyes on the road and your hands off the phone — it speaks short tips so you never need to look. Traffic laws, signs and road conditions always come before anything the app says."
}
