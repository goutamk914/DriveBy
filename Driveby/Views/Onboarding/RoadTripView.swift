//  RoadTripView.swift — Driveby
//  The onboarding road: a winding road that is paved one stretch at a time while a little car drives
//  it. `carProgress` and `paved` are fractions of the road's length (0…1); the caller animates them,
//  and both the trim and the car's position interpolate along the curve.

import SwiftUI

struct RoadTripView: View {
    /// Where the car is along the road (0…1).
    var carProgress: CGFloat
    /// How much of the road has been built so far (0…1).
    var paved: CGFloat
    /// Waypoints along the road (fractions), one per onboarding page after the first.
    var stops: [CGFloat]

    static let roadWidth: CGFloat = 22
    /// Keeps the car and stop markers inside the frame at both ends.
    static let inset: CGFloat = 26

    var body: some View {
        GeometryReader { geo in
            let path = WindingRoad().path(in: CGRect(origin: .zero, size: geo.size))
            ZStack {
                // Where the road is heading: a faint dotted guide.
                path.stroke(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [1, 9]))
                WindingRoad().trim(from: 0, to: paved)
                    .stroke(Color(.systemGray4), style: StrokeStyle(lineWidth: Self.roadWidth, lineCap: .round, lineJoin: .round))
                WindingRoad().trim(from: 0, to: paved)
                    .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .butt, dash: [9, 9]))
                ForEach(stops.indices, id: \.self) { i in
                    StopMarker(reached: carProgress >= stops[i] - 0.001)
                        .opacity(paved >= stops[i] - 0.001 ? 1 : 0)
                        .scaleEffect(paved >= stops[i] - 0.001 ? 1 : 0.3)
                        .position(WindingRoad.point(on: path, at: stops[i]))
                }
                FinishFlag()
                    .opacity(paved >= 0.999 ? 1 : 0)
                    .scaleEffect(paved >= 0.999 ? 1 : 0.3)
                    .position(WindingRoad.point(on: path, at: 1).applying(.init(translationX: 0, y: -22)))
                TopDownCar()
                    .modifier(FollowRoad(progress: carProgress, path: path))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Road progress")
        .accessibilityValue("\(Int((carProgress * 100).rounded())) percent")
    }
}

/// A smooth S-curve (Catmull-Rom through fixed points) across the frame.
struct WindingRoad: Shape {
    /// Unit-square waypoints the road passes through, left to right.
    private static let points: [CGPoint] = [
        CGPoint(x: 0.00, y: 0.62), CGPoint(x: 0.20, y: 0.28), CGPoint(x: 0.42, y: 0.72),
        CGPoint(x: 0.64, y: 0.30), CGPoint(x: 0.84, y: 0.70), CGPoint(x: 1.00, y: 0.42),
    ]

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: RoadTripView.inset, dy: RoadTripView.inset)
        let pts = Self.points.map { CGPoint(x: r.minX + $0.x * r.width, y: r.minY + $0.y * r.height) }
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: first)
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }

    /// Point at a fraction of the road's LENGTH (not its x).
    static func point(on path: Path, at fraction: CGFloat) -> CGPoint {
        let f = min(max(fraction, 0.0001), 1)
        return path.trimmedPath(from: 0, to: f).currentPoint ?? .zero
    }

    /// Direction of travel at a fraction of the road's length.
    static func heading(on path: Path, at fraction: CGFloat) -> Angle {
        let step: CGFloat = 0.01
        let a = point(on: path, at: max(fraction - step, 0))
        let b = point(on: path, at: min(fraction + step, 1))
        return .radians(atan2(b.y - a.y, b.x - a.x))
    }
}

/// Moves (and turns) a view along the road; animatable, so the car drives the curve.
private struct FollowRoad: ViewModifier, Animatable {
    var progress: CGFloat
    let path: Path

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .rotationEffect(WindingRoad.heading(on: path, at: progress))
            .position(WindingRoad.point(on: path, at: progress))
    }
}

/// A little car seen from above, pointing right (+x). Headlight beams come on in dark mode.
struct TopDownCar: View {
    var scale: CGFloat = 1
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            if scheme == .dark {
                Beam()
                    .fill(LinearGradient(colors: [Color.yellow.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 46, height: 30)
                    .offset(x: 39)
            }
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.accentColor).frame(width: 34, height: 18)
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Color.black.opacity(0.35)).frame(width: 7, height: 13).offset(x: 6)
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Color.black.opacity(0.22)).frame(width: 5, height: 12).offset(x: -10)
            Circle().fill(Color.yellow).frame(width: 4, height: 4).offset(x: 16, y: -6)
            Circle().fill(Color.yellow).frame(width: 4, height: 4).offset(x: 16, y: 6)
        }
        .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
        .scaleEffect(scale)
        .accessibilityHidden(true)
    }

    private struct Beam: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.midY - 5))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.midY + 5))
            p.closeSubpath()
            return p
        }
    }
}

private struct StopMarker: View {
    var reached: Bool
    var body: some View {
        Image(systemName: reached ? "checkmark.circle.fill" : "mappin.circle.fill")
            .font(.system(size: 20, weight: .bold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, reached ? Color.accentColor : Color.orange)
            .background(Circle().fill(Color(.systemBackground)).padding(2))
            .contentTransition(.symbolEffect(.replace))
            .animation(.snappy, value: reached)
    }
}

private struct FinishFlag: View {
    var body: some View {
        Image(systemName: "flag.checkered")
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(.primary)
    }
}

/// Compact version for the setup steps' navigation bar: a short road with the car at the current step.
struct SetupRoadProgress: View {
    var fraction: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.systemGray5)).frame(height: 6)
                Capsule().fill(Color.accentColor).frame(width: max(geo.size.width * fraction, 6), height: 6)
                TopDownCar(scale: 0.55).position(x: geo.size.width * fraction, y: geo.size.height / 2)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 150, height: 22)
        .animation(.easeInOut(duration: 0.6), value: fraction)
        .accessibilityElement()
        .accessibilityLabel("Setup progress")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}
