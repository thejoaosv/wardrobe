import SwiftUI

let presetStyles = ["Casual", "Smart casual", "Office", "Date night", "Streetwear", "Sporty", "Minimal", "Cozy"]

let weathers: [(id: String, label: String, symbol: String)] = [
    ("auto", "Auto", "wand.and.stars"), ("warm", "Warm", "sun.max"), ("mild", "Mild", "cloud.sun"), ("cold", "Cold", "snowflake"), ("rain", "Rain", "cloud.rain"),
]

/// Three choices, top to bottom: which days, what weather, what style. All remembered, so planning again is one tap.
struct PlanForm: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("plan.days") private var dayCount = 5
    @AppStorage("plan.weather") private var weather = "auto"
    @AppStorage("plan.style") private var style = "Casual"
    @State private var selected: Set<String> = []
    @State private var perDay = false
    @State private var styles: [String: String] = [:]

    /// The next two weeks, from today.
    private var upcoming: [String] {
        (0..<14).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: Calendar.current.startOfDay(for: .now)) }.map(Day.string)
    }
    private var days: [String] { upcoming.filter(selected.contains) }
    private var replacing: Int { days.filter { date in store.plans.contains { $0.date == date } }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Text("Plan outfits").font(.display(34))

                section("Days", hint: "Tap the days you need outfits for.") {
                    DayStrip(days: upcoming, selected: $selected, planned: Set(store.plans.map(\.date)))
                        .padding(.horizontal, -24)
                }

                section("Weather", hint: weatherHint) {
                    HStack(spacing: 8) {
                        ForEach(weathers, id: \.id) { option in
                            Tile(label: option.label, symbol: option.symbol, selected: weather == option.id) { weather = option.id }
                        }
                    }
                    .sensoryFeedback(.selection, trigger: weather)
                }

                section("Style") {
                    StyleChips(style: $style)
                    if days.count > 1 {
                        Toggle("Different style each day", isOn: $perDay.animation(Theme.spring))
                            .font(.subheadline.weight(.medium))
                            .tint(Theme.ink)
                            .padding(.top, 6)
                        if perDay {
                            VStack(spacing: 0) {
                                ForEach(days, id: \.self) { date in
                                    HStack {
                                        Text(Day.date(date), format: .dateTime.weekday(.wide).day())
                                        Spacer()
                                        StyleMenu(style: Binding(get: { styles[date] ?? style }, set: { styles[date] = $0 }))
                                    }
                                    .frame(minHeight: 48)
                                }
                            }
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                }
            }
            .padding(24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if replacing > 0 {
                    Text(replacing == 1 ? "Replaces 1 planned outfit" : "Replaces \(replacing) planned outfits")
                        .font(.footnote).foregroundStyle(Theme.muted)
                }
                Button(buttonTitle, action: start)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(days.isEmpty)
                    .opacity(days.isEmpty ? 0.4 : 1)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
        .background(Theme.canvas.ignoresSafeArea())
        .onAppear {
            if selected.isEmpty { selected = Set(upcoming.prefix(max(1, min(dayCount, 14)))) }
        }
    }

    private var buttonTitle: String {
        switch days.count {
        case 0: "Pick a day"
        case 1: "Style \(Day.date(days[0]).formatted(.dateTime.weekday(.wide)))"
        default: "Style \(days.count) days"
        }
    }

    private var weatherHint: String {
        ["warm": "Just a top, no layers.", "mild": "A light layer when the style suits it.", "cold": "A hoodie or sweater over the top, and a jacket if you have one.", "rain": "A jacket on top."][weather]
            ?? "Layers picked for the time of year."
    }

    private func start() {
        let plan = days.map { PlanDay(date: Day.date($0), style: perDay ? styles[$0] ?? style : style, weather: weather) }
        dayCount = plan.count
        Task { await store.generate(plan) }
        dismiss()
    }

    private func section<Content: View>(_ title: String, hint: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).eyebrow()
            content()
            if let hint {
                Text(hint).font(.footnote).foregroundStyle(Theme.muted).contentTransition(.opacity)
            }
        }
    }
}

/// Two weeks of dates to tap on and off; a dot marks days that already have an outfit.
private struct DayStrip: View {
    let days: [String]
    @Binding var selected: Set<String>
    let planned: Set<String>

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(days, id: \.self) { date in
                    let isOn = selected.contains(date)
                    Button {
                        withAnimation(Theme.spring) { if isOn { selected.remove(date) } else { selected.insert(date) } }
                    } label: {
                        VStack(spacing: 3) {
                            Text(date == days.first ? "Today" : Day.date(date).formatted(.dateTime.weekday(.abbreviated)))
                                .font(.caption2.weight(.semibold))
                            Text(Day.date(date), format: .dateTime.day()).font(.title3.monospacedDigit())
                            Circle().frame(width: 4, height: 4).opacity(planned.contains(date) ? 1 : 0)
                        }
                        .frame(width: 52, height: 70)
                        .foregroundStyle(isOn ? Theme.canvas : Theme.ink)
                        .background(isOn ? Theme.ink : Theme.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel(Text(Day.date(date), format: .dateTime.weekday(.wide).day().month()))
                    .accessibilityValue(planned.contains(date) ? "Has an outfit" : "")
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
            .padding(.horizontal, 24)
        }
        .scrollIndicators(.hidden)
        .sensoryFeedback(.selection, trigger: selected)
    }
}

private struct Tile: View {
    let label: String
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: { withAnimation(Theme.spring) { action() } }) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 20))
                Text(label).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .foregroundStyle(selected ? Theme.canvas : Theme.ink)
            .background(selected ? Theme.ink : Theme.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct StyleChips: View {
    @Binding var style: String
    @State private var custom = ""
    @State private var askingCustom = false

    var body: some View {
        FlowLayout {
            ForEach(presetStyles + (presetStyles.contains(style) ? [] : [style]), id: \.self) { preset in
                Chip(title: preset, selected: style == preset) { style = preset }
            }
            Chip(title: "Other…", selected: false) { askingCustom = true }
        }
        .sensoryFeedback(.selection, trigger: style)
        .alert("Describe a style", isPresented: $askingCustom) {
            TextField("e.g. rainy day office", text: $custom)
            Button("Use") { if !custom.trimmingCharacters(in: .whitespaces).isEmpty { style = custom } }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct StyleMenu: View {
    @Binding var style: String

    var body: some View {
        Menu {
            Picker("Style", selection: $style) {
                ForEach(presetStyles + (presetStyles.contains(style) ? [] : [style]), id: \.self) { Text($0) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(style)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(Theme.ink.opacity(0.06), in: Capsule())
        }
    }
}

private struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: { withAnimation(Theme.spring) { action() } }) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16)
                .frame(minHeight: 40)
                .foregroundStyle(selected ? Theme.canvas : Theme.ink)
                .background(selected ? Theme.ink : Theme.ink.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
