import SwiftUI

let presetStyles = ["Casual", "Smart casual", "Office", "Date night", "Streetwear", "Sporty", "Minimal", "Cozy"]

/// When outfits start (days from today) and how many days they cover; "pick" lets the user tap the days.
private let spans: [(id: String, label: String, start: Int, count: Int)] = [
    ("today", "Today", 0, 1), ("tomorrow", "Tomorrow", 1, 1), ("three", "3 days", 0, 3), ("week", "Week", 0, 7), ("pick", "Pick days", 0, 0),
]

private let weathers: [(id: String, label: String, symbol: String)] = [
    ("auto", "Auto", "wand.and.stars"), ("warm", "Warm", "sun.max"), ("mild", "Mild", "cloud.sun"), ("cold", "Cold", "snowflake"), ("rain", "Rain", "cloud.rain"),
]

private let palettes: [(id: String, label: String)] = [
    ("any", "Any"), ("neutral", "Neutrals"), ("muted", "Muted"), ("bold", "Bold"), ("monochrome", "One color"),
]

/// The three choices most plans need as chip rows, then a small panel for fine-tuning. The main choices are remembered.
struct PlanForm: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("plan.span") private var span = "three"
    @AppStorage("plan.weather") private var weather = "auto"
    @AppStorage("plan.style") private var style = "Casual"
    @AppStorage("plan.palette") private var palette = "any"
    @State private var picked: Set<String> = []
    @State private var perDay = false
    @State private var dayStyles: [String: String] = [:]
    @State private var dayWeathers: [String: String] = [:]
    @State private var include: String?
    @State private var note = ""

    private var upcoming: [Date] {
        let today = Calendar.current.startOfDay(for: .now)
        return (0..<14).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: today) }
    }

    private var dates: [Date] {
        if span == "pick" { return upcoming.filter { picked.contains(Day.string($0)) } }
        let chosen = spans.first { $0.id == span } ?? spans[2]
        return Array(upcoming[chosen.start..<chosen.start + chosen.count])
    }

    /// The days in plain words, and whether planning them replaces outfits already there.
    private var whenHint: String {
        guard let first = dates.first, let last = dates.last else { return "Tap the days you need outfits for." }
        let format = Date.FormatStyle().weekday(.abbreviated).day()
        let range = dates.count == 1 ? first.formatted(format) : span == "pick" ? "\(dates.count) days" : "\(first.formatted(format)) to \(last.formatted(format))"
        let replacing = dates.filter { date in store.plans.contains { $0.date == Day.string(date) } }.count
        return replacing == 0 ? range : "\(range) · replaces \(replacing == 1 ? "1 outfit" : "\(replacing) outfits")"
    }

    private var weatherHint: String {
        ["warm": "Just a top, no layers.", "mild": "A light layer if the style suits it.", "cold": "A hoodie or sweater over the top, and a jacket.", "rain": "A jacket on top."][weather]
            ?? "Layers for the time of year."
    }

    private var includeName: String? { include.flatMap(store.item)?.name }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                Text("Plan outfits").font(.display(34))

                choices("When", hint: whenHint) {
                    FlowLayout {
                        ForEach(spans, id: \.id) { option in
                            ChoiceChip(title: option.label, symbol: option.id == "pick" ? "calendar" : nil, selected: span == option.id) { span = option.id }
                        }
                    }
                    if span == "pick" {
                        PickDays(days: upcoming, picked: $picked, planned: Set(store.plans.map(\.date)))
                            .padding(.horizontal, -24)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .sensoryFeedback(.selection, trigger: span)

                choices(perDay && dates.count > 1 ? "Weather, unless set per day" : "Weather", hint: weatherHint) {
                    FlowLayout {
                        ForEach(weathers, id: \.id) { option in
                            ChoiceChip(title: option.label, symbol: option.symbol, selected: weather == option.id) { weather = option.id }
                        }
                    }
                }
                .sensoryFeedback(.selection, trigger: weather)

                choices(perDay && dates.count > 1 ? "Style, unless set per day" : "Style") {
                    StyleChips(style: $style)
                }

                Panel(title: "Fine-tune", footer: include != nil && dates.count > 1 ? "The piece you build around goes in the first day's outfit." : nil) {
                    PanelRow(title: "Colors", symbol: "paintpalette") {
                        Menu {
                            Picker("Colors", selection: $palette) {
                                ForEach(palettes, id: \.id) { Text($0.label).tag($0.id) }
                            }
                        } label: {
                            MenuChipLabel(title: palettes.first { $0.id == palette }?.label ?? "Any")
                        }
                    }
                    PanelRow(title: "Build around", symbol: "pin") {
                        Menu {
                            Button("Nothing") { include = nil }
                            ForEach(Parts.order, id: \.self) { part in
                                let pieces = store.items.filter { $0.part == part && $0.isAvailable }
                                if !pieces.isEmpty {
                                    Section(Parts.label(part)) {
                                        ForEach(pieces) { piece in Button(piece.name) { include = piece.id } }
                                    }
                                }
                            }
                        } label: {
                            MenuChipLabel(title: includeName ?? "Nothing")
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Note for the stylist").font(.footnote).foregroundStyle(Theme.muted)
                        TextField("e.g. dinner out, lots of walking", text: $note, axis: .vertical)
                            .lineLimit(1...3)
                            .submitLabel(.done)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    if dates.count > 1 {
                        PanelRow(title: "Different style each day", symbol: "calendar.day.timeline.left") {
                            SwitchButton(title: "Different style each day", isOn: $perDay)
                        }
                    }
                }

                if perDay && dates.count > 1 {
                    Panel(title: "Each day") {
                        ForEach(dates, id: \.self) { date in
                            let key = Day.string(date)
                            PanelRow(title: date.formatted(.dateTime.weekday(.wide).day())) {
                                HStack(spacing: 8) {
                                    Menu {
                                        Picker("Weather", selection: Binding(get: { dayWeathers[key] ?? weather }, set: { dayWeathers[key] = $0 })) {
                                            ForEach(weathers, id: \.id) { Label($0.label, systemImage: $0.symbol).tag($0.id) }
                                        }
                                    } label: {
                                        Image(systemName: weathers.first { $0.id == (dayWeathers[key] ?? weather) }?.symbol ?? "wand.and.stars")
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(Theme.ink)
                                            .frame(width: 38, height: 38)
                                            .background(Theme.ink.opacity(0.06), in: Circle())
                                    }
                                    .accessibilityLabel("Weather")
                                    Menu {
                                        Picker("Style", selection: Binding(get: { dayStyles[key] ?? style }, set: { dayStyles[key] = $0 })) {
                                            ForEach(presetStyles + (presetStyles.contains(style) ? [] : [style]), id: \.self) { Text($0) }
                                        }
                                    } label: {
                                        MenuChipLabel(title: dayStyles[key] ?? style)
                                    }
                                }
                            }
                        }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(24)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            Button(buttonTitle, action: start)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(dates.isEmpty)
                .opacity(dates.isEmpty ? 0.4 : 1)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
        }
        .background(Theme.canvas.ignoresSafeArea())
        .animation(Theme.spring, value: span)
    }

    private var buttonTitle: String {
        switch dates.count {
        case 0: "Pick a day"
        case 1: "Style \(dates[0].formatted(.dateTime.weekday(.wide)))"
        default: "Style \(dates.count) days"
        }
    }

    private func start() {
        let separate = perDay && dates.count > 1
        let days = dates.enumerated().map { index, date in
            let key = Day.string(date)
            return PlanDay(date: date, style: separate ? dayStyles[key] ?? style : style, weather: separate ? dayWeathers[key] ?? weather : weather,
                           palette: palette, include: index == 0 ? include : nil, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        Task { await store.generate(days) }
        dismiss()
    }

    private func choices<Content: View>(_ title: String, hint: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).eyebrow()
            content()
            if let hint {
                Text(hint).font(.footnote).foregroundStyle(Theme.muted).contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: hint)
            }
        }
    }
}

/// Two weeks of dates to tap on and off; a dot marks days that already have an outfit.
private struct PickDays: View {
    let days: [Date]
    @Binding var picked: Set<String>
    let planned: Set<String>

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(days, id: \.self) { date in
                    let key = Day.string(date)
                    let isOn = picked.contains(key)
                    Button {
                        withAnimation(Theme.spring) { if isOn { picked.remove(key) } else { picked.insert(key) } }
                    } label: {
                        VStack(spacing: 3) {
                            Text(date == days.first ? "Today" : date.formatted(.dateTime.weekday(.abbreviated))).font(.caption2.weight(.semibold))
                            Text(date, format: .dateTime.day()).font(.title3.monospacedDigit())
                            Circle().frame(width: 4, height: 4).opacity(planned.contains(key) ? 1 : 0)
                        }
                        .frame(width: 52, height: 70)
                        .foregroundStyle(isOn ? Theme.canvas : Theme.ink)
                        .background(isOn ? Theme.ink : Theme.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel(Text(date, format: .dateTime.weekday(.wide).day().month()))
                    .accessibilityValue(planned.contains(key) ? "Has an outfit" : "")
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
            .padding(.horizontal, 24)
        }
        .scrollIndicators(.hidden)
        .sensoryFeedback(.selection, trigger: picked)
    }
}

private struct StyleChips: View {
    @Binding var style: String
    @State private var custom = ""
    @State private var askingCustom = false

    var body: some View {
        FlowLayout {
            ForEach(presetStyles + (presetStyles.contains(style) ? [] : [style]), id: \.self) { preset in
                ChoiceChip(title: preset, selected: style == preset) { style = preset }
            }
            ChoiceChip(title: "Other…", selected: false) { askingCustom = true }
        }
        .sensoryFeedback(.selection, trigger: style)
        .alert("Describe a style", isPresented: $askingCustom) {
            TextField("e.g. rainy day office", text: $custom)
            Button("Use") { if !custom.trimmingCharacters(in: .whitespaces).isEmpty { style = custom } }
            Button("Cancel", role: .cancel) {}
        }
    }
}
