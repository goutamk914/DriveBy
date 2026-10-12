//  MorphingSymbolView.swift — Driveby
//  An SF Symbol that melts into the next one (blur + alpha-threshold) — the onboarding hero.
//  Adapted from SwiftUI-Intro "Walkthrough+Morphing" by Balaji Venkatesh (MIT licence).

import SwiftUI

struct MorphingSymbolView: View {
    var symbol: String
    var config: Config

    @State private var trigger = false
    @State private var displayingSymbol = ""
    @State private var nextSymbol = ""

    var body: some View {
        Canvas { ctx, size in
            ctx.addFilter(.alphaThreshold(min: 0.4, color: config.foregroundColor))
            if let rendered = ctx.resolveSymbol(id: 0) {
                ctx.draw(rendered, at: CGPoint(x: size.width / 2, y: size.height / 2))
            }
        } symbols: {
            imageView().tag(0)
        }
        .frame(width: config.frame.width, height: config.frame.height)
        .onChange(of: symbol) { _, newValue in
            trigger.toggle()
            nextSymbol = newValue
        }
        .task {
            guard displayingSymbol.isEmpty else { return }
            displayingSymbol = symbol
        }
        .accessibilityHidden(true)
    }

    private func imageView() -> some View {
        KeyframeAnimator(initialValue: CGFloat.zero, trigger: trigger) { radius in
            Image(systemName: displayingSymbol.isEmpty ? symbol : displayingSymbol)
                .font(config.font)
                .blur(radius: radius)
                .frame(width: config.frame.width, height: config.frame.height)
                .onChange(of: radius) { _, newValue in
                    // Swap the symbol at peak blur, so the change happens while it's a blob.
                    if newValue.rounded() == config.radius {
                        withAnimation(config.symbolAnimation) { displayingSymbol = nextSymbol }
                    }
                }
        } keyframes: { _ in
            CubicKeyframe(config.radius, duration: config.keyFrameDuration)
            CubicKeyframe(0, duration: config.keyFrameDuration)
        }
    }

    struct Config {
        var font: Font
        var frame: CGSize
        var radius: CGFloat
        var foregroundColor: Color
        var keyFrameDuration: CGFloat = 0.4
        var symbolAnimation: Animation = .smooth(duration: 0.5, extraBounce: 0)
    }
}
