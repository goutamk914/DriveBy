import SwiftUI

struct MomentTimeline: View {
    var moments: [DriveMoment]
    var tripStartT: Double
    var onSelect: (DriveMoment) -> Void

    var body: some View {
        if moments.isEmpty {
            Text("Nothing significant to review — nice, steady drive.")
                .foregroundStyle(Theme.efficiency)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(moments.enumerated()), id: \.element.id) { index, m in
                    Button { onSelect(m) } label: { row(m, last: index == moments.count - 1) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func row(_ m: DriveMoment, last: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(EventCopywriter.timeInto(m.t - tripStartT))
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .frame(width: 52, alignment: .trailing)
                .padding(.top, 5)
            VStack(spacing: 0) {
                MomentBadge(kind: m.kind, size: 28)
                if !last { Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 2).frame(maxHeight: .infinity) }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(m.kind.title).font(.subheadline.weight(.semibold)).foregroundStyle(m.isPositive ? Theme.efficiency : .primary)
                    Spacer()
                    if m.clipPath != nil { Text("Clip").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                }
                Text(m.body).font(.footnote).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                if !m.isPositive { SeverityBar(value: m.severity, tint: m.kind.color) }
            }
            .padding(.bottom, last ? 0 : 14)
        }
        .contentShape(Rectangle())
    }
}
