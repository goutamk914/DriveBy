import SwiftUI

enum Theme {
    static let efficiency = Color(red: 0.09, green: 0.64, blue: 0.29)
    static let safety = Color(red: 0.15, green: 0.39, blue: 0.92)
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
}

enum Fmt {
    static func miles(_ metres: Double?) -> String {
        guard let m = metres else { return "-" }
        let mi = Units.miles(m)
        return mi < 10 ? String(format: "%.1f mi", mi) : String(format: "%.0f mi", mi)
    }

    static func duration(_ s: Double?) -> String {
        guard let s, s.isFinite else { return "-" }
        let total = Int(s.rounded())
        if total >= 3600 { return "\(total / 3600) h \((total % 3600) / 60) min" }
        if total >= 60 { return "\(total / 60) min" }
        return "\(total) s"
    }

    static func clock(_ s: Double) -> String {
        let t = max(Int(s), 0)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    static func score(_ s: Double?) -> String { s.map { String(format: "%.0f", $0) } ?? "-" }

    static func mph(_ mps: Double?) -> String { mps.map { String(format: "%.0f mph", Units.mph($0)) } ?? "-" }

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

enum Typography {
    static let roadSignFace = "DINAlternate-Bold"
    private static let largeTitleSize: CGFloat = 34
    private static let inlineTitleSize: CGFloat = 17

    static func pointSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 34
        case .title: return 28
        case .title2: return 22
        case .title3: return 20
        case .headline, .body: return 17
        case .callout: return 16
        case .subheadline: return 15
        case .footnote: return 13
        case .caption: return 12
        case .caption2: return 11
        @unknown default: return 17
        }
    }

    @MainActor
    static func styleNavigationBars() {
        guard let large = UIFont(name: roadSignFace, size: largeTitleSize),
              let inline = UIFont(name: roadSignFace, size: inlineTitleSize) else { return }
        let bar = UINavigationBar.appearance()
        bar.largeTitleTextAttributes = [.font: UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: large)]
        bar.titleTextAttributes = [.font: UIFontMetrics(forTextStyle: .headline).scaledFont(for: inline)]
    }
}

extension Font {
    static func roadSign(_ style: Font.TextStyle) -> Font {
        .custom(Typography.roadSignFace, size: Typography.pointSize(style), relativeTo: style)
    }

    static func roadSign(fixed size: CGFloat) -> Font {
        .custom(Typography.roadSignFace, fixedSize: size)
    }
}

struct SectionHeader: View {
    var title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.roadSign(.headline))
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
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

extension LiveCue {
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

enum Disclaimer {
    static func short(_ mode: DriverMode) -> String {
        mode == .newDriver ? "Practice tool, not a driving instructor." : "A coach, not a safety system."
    }

    static func detail(_ mode: DriverMode) -> String {
        mode == .newDriver
            ? "Practise only with a licensed adult beside you."
            : "Eyes on the road, hands off the phone."
    }

    static let full = "Driveby is a practice tool, not a driving instructor. Always practise with a licensed adult."
    static let fullRegular = "Driveby is a coach, not a safety system. Eyes on the road, hands off the phone."
}
