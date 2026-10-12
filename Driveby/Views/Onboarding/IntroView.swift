import SwiftUI

enum IntroPage: Int, CaseIterable, Identifiable {
    case welcome, voice, scores, privacy

    var id: Int { rawValue }

    var symbol: String {
        switch self {
        case .welcome: return "steeringwheel"
        case .voice: return "waveform"
        case .scores: return "gauge.with.dots.needle.67percent"
        case .privacy: return "eye.slash.fill"
        }
    }

    var title: String {
        switch self {
        case .welcome: return "Welcome to Driveby"
        case .voice: return "Hear it live"
        case .scores: return "See your progress"
        case .privacy: return "Private by design"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome: return "Your coach for every drive."
        case .voice: return "Short spoken tips while you drive."
        case .scores: return "A safety and efficiency score after each drive."
        case .privacy: return "Faces and plates are blurred on your phone."
        }
    }

    private static var count: CGFloat { CGFloat(allCases.count) }
    var carStop: CGFloat { CGFloat(rawValue) / Self.count }
    var paved: CGFloat { CGFloat(rawValue + 1) / Self.count }
    var next: IntroPage? { IntroPage(rawValue: rawValue + 1) }
    var previous: IntroPage? { IntroPage(rawValue: rawValue - 1) }
    static var last: IntroPage { allCases[allCases.count - 1] }
}

struct IntroView: View {
    static let version = 1

    var onFinish: () -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var scheme
    @State private var page: IntroPage = .welcome
    @State private var carProgress: CGFloat = IntroPage.welcome.carStop
    @State private var paved: CGFloat = IntroPage.welcome.paved
    @State private var driving = false
    @State private var autoplay = true

    private static let secondsPerStop = 0.8
    private static let paveDuration = 0.6
    private static let readingPause = 2.6
    private static let swipeDistance: CGFloat = 40

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                MorphingSymbolView(
                    symbol: page.symbol,
                    config: .init(font: .system(size: 130, weight: .bold), frame: CGSize(width: 250, height: 180),
                                  radius: 30, foregroundColor: scheme == .dark ? .white : .black)
                )
                textContents(width: geo.size.width)
                Spacer(minLength: 0)
                RoadTripView(carProgress: carProgress, paved: paved,
                             stops: IntroPage.allCases.dropFirst().map(\.carStop))
                    .frame(height: 150)
                    .padding(.horizontal, 8)
                indicator
                continueButton
            }
            .frame(maxWidth: .infinity)
        }
        .background {
            LinearGradient(colors: [Color.accentColor.opacity(0.22), Color(.systemBackground)], startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 20).onEnded { value in
            if value.translation.width < -Self.swipeDistance, let next = page.next { go(to: next) }
            if value.translation.width > Self.swipeDistance, let previous = page.previous { goBack(to: previous) }
        })
        .sensoryFeedback(.impact(weight: .light), trigger: page)
        .task(id: page) { await autoAdvance() }
    }

    private func autoAdvance() async {
        guard autoplay, let next = page.next else { return }
        try? await Task.sleep(for: .seconds(Self.secondsPerStop + Self.paveDuration + Self.readingPause))
        guard !Task.isCancelled, autoplay, page.next == next else { return }
        go(to: next)
    }

    private func goBack(to previous: IntroPage) {
        autoplay = false
        go(to: previous)
    }

    private var header: some View {
        HStack {
            Button { if let previous = page.previous { goBack(to: previous) } } label: {
                Image(systemName: "chevron.left").font(.title3.weight(.semibold)).contentShape(Rectangle())
            }
            .opacity(page.previous == nil ? 0 : 1)
            .accessibilityLabel("Back")
            Spacer(minLength: 0)
            Button(action: toggleAppearance) {
                Image(systemName: scheme == .dark ? "sun.max.fill" : "moon.fill")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.thinMaterial, in: Circle())
            }
            .accessibilityLabel(scheme == .dark ? "Switch to light mode" : "Switch to dark mode")
            Spacer(minLength: 0)
            Button("Skip") { go(to: .last) }
                .fontWeight(.semibold)
                .opacity(page == .last ? 0 : 1)
        }
        .foregroundStyle(.primary)
        .animation(.snappy(duration: 0.35), value: page)
        .padding(15)
    }

    private func textContents(width: CGFloat) -> some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(IntroPage.allCases) { p in
                    Text(p.title).font(.roadSign(.title)).lineLimit(1).minimumScaleFactor(0.8)
                        .frame(width: width)
                }
            }
            .offset(x: -CGFloat(page.rawValue) * width)
            .animation(.bouncy(duration: 0.7), value: page)
            HStack(alignment: .top, spacing: 0) {
                ForEach(IntroPage.allCases) { p in
                    Text(p.subtitle).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .frame(width: width)
                }
            }
            .offset(x: -CGFloat(page.rawValue) * width)
            .animation(.bouncy(duration: 0.9), value: page)
        }
        .padding(.top, 12)
        .frame(width: width, alignment: .leading)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(page.title). \(page.subtitle)")
    }

    private var indicator: some View {
        HStack(spacing: 6) {
            ForEach(IntroPage.allCases) { p in
                Capsule()
                    .fill(Color.primary.opacity(page == p ? 1 : 0.3))
                    .frame(width: page == p ? 25 : 8, height: 8)
            }
        }
        .animation(.smooth(duration: 0.5), value: page)
        .padding(.vertical, 12)
        .accessibilityHidden(true)
    }

    private var continueButton: some View {
        Button {
            if let next = page.next { go(to: next) } else { finish() }
        } label: {
            Text(page == .last ? "Let's drive" : "Next")
                .font(.roadSign(.title3))
                .contentTransition(.identity)
                .foregroundStyle(Color(.systemBackground))
                .padding(.vertical, 15)
                .frame(maxWidth: page == .last ? 220 : 180)
                .background(Color.primary, in: Capsule())
        }
        .padding(.bottom, 15)
        .animation(.smooth(duration: 0.5), value: page)
    }

    private func go(to target: IntroPage) {
        guard !driving, target != page else { return }
        driving = true
        let stops = abs(target.rawValue - page.rawValue)
        page = target
        withAnimation(.easeInOut(duration: Self.secondsPerStop * Double(stops))) {
            carProgress = target.carStop
        } completion: {
            withAnimation(.easeOut(duration: Self.paveDuration)) { paved = max(paved, target.paved) }
            driving = false
        }
    }

    private func finish() {
        guard !driving else { return }
        driving = true
        withAnimation(.easeIn(duration: Self.secondsPerStop)) { carProgress = 1 } completion: { onFinish() }
    }

    private func toggleAppearance() {
        withAnimation(.easeInOut) { settings.appearance = scheme == .dark ? .light : .dark }
    }
}
