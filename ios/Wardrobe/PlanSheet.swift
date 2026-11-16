import SwiftUI

let presetStyles = ["Casual", "Smart casual", "Office", "Date night", "Streetwear", "Sporty", "Minimal", "Cozy"]

struct PlanForm: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var startsTomorrow = false
    @State private var count = 5
    @State private var mixStyles = false
    @State private var style = "Casual"
    @State private var styles = Array(repeating: "Casual", count: 7)

    private var dates: [Date] {
        let start = Calendar.current.date(byAdding: .day, value: startsTomorrow ? 1 : 0, to: Calendar.current.startOfDay(for: .now))!
        return (0..<count).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: start) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Plan outfits").font(.display(34))

                VStack(alignment: .leading, spacing: 10) {
                    Text("When").eyebrow()
                    Picker("Start", selection: $startsTomorrow) {
                        Text("From today").tag(false)
                        Text("From tomorrow").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Picker("Days", selection: $count) {
                        ForEach([1, 3, 5, 7], id: \.self) { Text($0 == 1 ? "1 day" : "\($0) days").tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Style").eyebrow()
                        Spacer()
                        Toggle("Mix per day", isOn: $mixStyles.animation(Theme.spring))
                            .toggleStyle(.button).buttonStyle(.plain)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(mixStyles ? Theme.ink : Theme.muted)
                    }
                    if mixStyles {
                        ForEach(Array(dates.enumerated()), id: \.offset) { index, date in
                            HStack {
                                Text(date, format: .dateTime.weekday(.wide)).font(.body)
                                Spacer()
                                StyleMenu(style: $styles[index])
                            }
                            .frame(minHeight: 44)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    } else {
                        StyleChips(style: $style).transition(.opacity)
                    }
                }
            }
            .padding(24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            Button(count == 1 ? "Style my day" : "Style \(count) days") {
                let days = dates.enumerated().map { PlanDay(date: $1, style: mixStyles ? styles[$0] : style) }
                Task { await store.generate(days) }
                dismiss()
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
        .background(Theme.canvas.ignoresSafeArea())
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
                ForEach(presetStyles, id: \.self) { Text($0) }
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
