import SwiftUI

struct ClosetView: View {
    @Environment(Store.self) private var store
    @State private var filter = Filter.all
    @State private var opened: Item?

    enum Filter: String, CaseIterable {
        case all = "All", tops = "Tops", sweaters = "Sweaters", layers = "Jackets", bottoms = "Bottoms", shoes = "Shoes", accessories = "Accessories", wash = "In the wash"

        var part: String? {
            [.tops: "upperbody", .sweaters: "midlayer", .layers: "wholebody_up", .bottoms: "lowerbody", .shoes: "shoes", .accessories: "accessories_up"][self]
        }
    }

    private var laundry: [Item] { store.items.filter { !$0.isAvailable } }

    private var shown: [Item] {
        switch filter {
        case .all: store.items
        case .wash: laundry
        default: store.items.filter { $0.part == filter.part }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(store.items.count) pieces").eyebrow()
                    if !laundry.isEmpty {
                        Text("· \(laundry.count) in the wash").eyebrow()
                    }
                    Spacer()
                    if filter == .wash && !laundry.isEmpty {
                        Button("All clean") { Task { await store.setUnavailable(laundry.map(\.id), false) } }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                    }
                }
                .contentTransition(.numericText())
                .padding(.horizontal, 20)

                FilterBar(selection: $filter, showsWash: !laundry.isEmpty)

                if store.items.isEmpty {
                    VStack(spacing: 16) {
                        Text("Your closet is empty").font(.display(26))
                        Button("Add clothes") { store.sheet = .clothes }.buttonStyle(QuietButtonStyle())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                } else if shown.isEmpty {
                    Text(filter == .wash ? "Nothing in the wash." : "No \(filter.rawValue.lowercased()) yet.")
                        .font(.subheadline).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity).padding(.top, 60)
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(shown) { item in ClosetCell(item: item) { opened = item } }
                }
                .padding(.horizontal, 14)
                .animation(Theme.spring, value: shown.map(\.id))
            }
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Theme.canvas.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await store.refresh() }
        .onChange(of: laundry.isEmpty) { _, empty in if empty && filter == .wash { filter = .all } }
        .sheet(item: $opened) { ItemSheet(item: $0) }
    }
}

/// Bordered uppercase tabs, joined like a segmented control.
private struct FilterBar: View {
    @Binding var selection: ClosetView.Filter
    let showsWash: Bool

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: -1) {
                ForEach(ClosetView.Filter.allCases.filter { $0 != .wash || showsWash }, id: \.self) { filter in
                    let selected = filter == selection
                    Button {
                        withAnimation(Theme.spring) { selection = filter }
                    } label: {
                        Text(filter.rawValue)
                            .font(.caption.weight(.medium))
                            .tracking(1.2)
                            .textCase(.uppercase)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 40)
                            .foregroundStyle(selected ? Theme.canvas : Theme.ink)
                            .background(selected ? Theme.ink : Color.clear)
                            .overlay(Rectangle().strokeBorder(Theme.ink.opacity(selected ? 1 : 0.18), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, filter == .wash ? 10 : 0)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

private struct ClosetCell: View {
    @Environment(Store.self) private var store
    let item: Item
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            GarmentImage(item: item)
                .garmentLift()
                .padding(8)
                .aspectRatio(1, contentMode: .fit)
                .saturation(item.isAvailable ? 1 : 0)
                .opacity(item.isAvailable ? 1 : 0.35)
                .overlay(alignment: .bottomTrailing) {
                    if !item.isAvailable {
                        Image(systemName: "washer")
                            .font(.caption2.weight(.semibold))
                            .padding(6)
                            .background(Theme.card, in: Circle())
                            .padding(6)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .animation(Theme.spring, value: item.isAvailable)
        .sensoryFeedback(.selection, trigger: item.isAvailable)
        .accessibilityLabel(item.name)
        .accessibilityValue(item.isAvailable ? "Available" : "In the wash")
        .accessibilityHint("Opens details")
        .contextMenu {
            Button(item.isAvailable ? "In the wash" : "Back from the wash", systemImage: "washer") {
                Task { await store.setUnavailable([item.id], item.isAvailable) }
            }
            Button("Remove piece", systemImage: "trash", role: .destructive) { Task { await store.delete(item) } }
        }
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(Theme.spring, value: configuration.isPressed)
    }
}
