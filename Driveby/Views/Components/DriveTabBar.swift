import SwiftUI

struct DriveTabBar<Tab: Hashable>: View {
    struct Item: Identifiable {
        let tab: Tab
        let title: String
        var id: Tab { tab }
    }

    let items: [Item]
    @Binding var selection: Tab
    @State private var facing: CGFloat = 1

    private static var roadHeight: CGFloat { 12 }
    private static var carScale: CGFloat { 0.62 }
    private static var cornerRadius: CGFloat { 28 }

    var body: some View {
        VStack(spacing: 6) {
            road
            HStack(spacing: 0) {
                ForEach(items) { item in button(item) }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous).stroke(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 2)
        .sensoryFeedback(.selection, trigger: selection)
        .onChange(of: selection) { old, new in
            guard let from = items.firstIndex(where: { $0.tab == old }),
                  let to = items.firstIndex(where: { $0.tab == new }), from != to else { return }
            withAnimation(.easeInOut(duration: 0.25)) { facing = to > from ? 1 : -1 }
        }
    }

    private var selectedIndex: Int { items.firstIndex { $0.tab == selection } ?? 0 }

    private var road: some View {
        GeometryReader { geo in
            let slot = geo.size.width / CGFloat(max(items.count, 1))
            let x = slot * (CGFloat(selectedIndex) + 0.5)
            ZStack(alignment: .leading) {
                StraightRoad(height: Self.roadHeight)
                TopDownCar(scale: Self.carScale)
                    .scaleEffect(x: facing, y: 1)
                    .position(x: x, y: geo.size.height / 2)
            }
        }
        .frame(height: Self.roadHeight)
        .animation(.spring(duration: 0.7, bounce: 0.15), value: selection)
        .accessibilityHidden(true)
    }

    private func button(_ item: Item) -> some View {
        let selected = item.tab == selection
        return Button { select(item.tab) } label: {
            VStack(spacing: 3) {
                Text(item.title).font(.roadSign(.subheadline)).frame(height: 26)
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func select(_ tab: Tab) {
        guard tab != selection else { return }
        selection = tab
    }
}
