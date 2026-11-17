import SwiftUI

let presetStyles = ["Casual", "Smart casual", "Office", "Date night", "Streetwear", "Sporty", "Minimal", "Cozy"]

/// When outfits start (days from today) and how many days they cover.
private let spans: [(id: String, label: String, start: Int, count: Int)] = [
    ("today", "Today", 0, 1), ("tomorrow", "Tomorrow", 1, 1), ("three", "3 days", 0, 3), ("week", "Week", 0, 7),
]

private let weathers: [(id: String, label: String, symbol: String)] = [
    ("auto", "Auto", "wand.and.stars"), ("warm", "Warm", "sun.max"), ("mild", "Mild", "cloud.sun"), ("cold", "Cold", "snowflake"), ("rain", "Rain", "cloud.rain"),
]

/// Three rows of choices, each one tap: when, the weather and a style. All remembered for next time.
struct PlanForm: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("plan.span") private var span = "three"
    @AppStorage("plan.weather") private var weather = "auto"
    @AppStorage("plan.style") private var style = "Casual"

    private var dates: [Date] {
        let chosen = spans.first { $0.id == span } ?? spans[2]
        let today = Calendar.current.startOfDay(for: .now)
        return (chosen.start..<chosen.start + chosen.count).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: today) }
    }

    /// The days in plain words, and whether planning them replaces outfits already there.
    private var whenHint: String {
        let format = Date.FormatStyle().weekday(.abbreviated).day()
        let range = dates.count == 1 ? dates[0].formatted(format) : "\(dates[0].formatted(format)) to \(dates[dates.count - 1].formatted(format))"
        let replacing = dates.filter { date in store.plans.contains { $0.date == Day.string(date) } }.count
        return replacing == 0 ? range : "\(range) · replaces \(replacing == 1 ? "1 outfit" : "\(replacing) outfits")"
    }

    private var weatherHint: String {
        ["warm": "Just a top, no layers.", "mild": "A light layer if the style suits it.", "cold": "A hoodie or sweater over the top, and a jacket.", "rain": "A jacket on top."][weather]
            ?? "Layers for the time of year."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                Text("Plan outfits").font(.display(34))

                choices("When", hint: whenHint) {
                    FlowLayout {
                        ForEach(spans, id: \.id) { option in
                            ChoiceChip(title: option.label, selected: span == option.id) { span = option.id }
                        }
                    }
                }
                .sensoryFeedback(.selection, trigger: span)

                choices("Weather", hint: weatherHint) {
                    FlowLayout {
                        ForEach(weathers, id: \.id) { option in
                            ChoiceChip(title: option.label, symbol: option.symbol, selected: weather == option.id) { weather = option.id }
                        }
                    }
                }
                .sensoryFeedback(.selection, trigger: weather)

                choices("Style") {
                    StyleChips(style: $style)
                }
            }
            .padding(24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            Button(dates.count == 1 ? "Style \(dates[0].formatted(.dateTime.weekday(.wide)))" : "Style \(dates.count) days") {
                let days = dates.map { PlanDay(date: $0, style: style, weather: weather) }
                Task { await store.generate(days) }
                dismiss()
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
        .background(Theme.canvas.ignoresSafeArea())
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
