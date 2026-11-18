import SwiftUI

/// A titled card of rows in the app's own style, used instead of system forms.
struct Panel<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title { Text(title).eyebrow().padding(.leading, 4) }
            Group(subviews: content) { rows in
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        row
                        if row.id != rows.last?.id {
                            Rectangle().fill(Theme.ink.opacity(0.07)).frame(height: 1).padding(.leading, 18)
                        }
                    }
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            if let footer {
                Text(footer).font(.footnote).foregroundStyle(Theme.muted).padding(.horizontal, 4)
            }
        }
    }
}

/// One panel row: an optional icon, a title with an optional detail line, and a value or control on the right.
struct PanelRow<Trailing: View>: View {
    let title: String
    var symbol: String? = nil
    var detail: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            if let symbol {
                Image(systemName: symbol).font(.body).frame(width: 24).foregroundStyle(Theme.ink)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(Theme.ink)
                if let detail { Text(detail).font(.footnote).foregroundStyle(Theme.muted) }
            }
            // Menus center their labels otherwise.
            .multilineTextAlignment(.leading)
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(minHeight: 58)
        .contentShape(Rectangle())
    }
}

extension PanelRow where Trailing == EmptyView {
    init(title: String, symbol: String? = nil, detail: String? = nil) {
        self.init(title: title, symbol: symbol, detail: detail) { EmptyView() }
    }
}

/// A muted value with a chevron, for rows that open a page or a menu.
struct RowValue: View {
    var text: String? = nil
    var symbol = "chevron.right"

    var body: some View {
        HStack(spacing: 6) {
            if let text { Text(text).foregroundStyle(Theme.muted) }
            Image(systemName: symbol).font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted.opacity(0.7))
        }
    }
}

/// Minus, the count, plus: compact enough for a panel row.
struct CountStepper: View {
    @Binding var value: Int
    var range: ClosedRange<Int> = 1...10

    var body: some View {
        HStack(spacing: 4) {
            step("minus", by: -1).disabled(value <= range.lowerBound)
            Text("\(value)×").font(.body.weight(.medium).monospacedDigit()).frame(minWidth: 34).contentTransition(.numericText())
            step("plus", by: 1).disabled(value >= range.upperBound)
        }
        .sensoryFeedback(.selection, trigger: value)
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(value) times")
        .accessibilityAdjustableAction { direction in
            value = min(max(value + (direction == .increment ? 1 : -1), range.lowerBound), range.upperBound)
        }
    }

    private func step(_ symbol: String, by change: Int) -> some View {
        Button {
            withAnimation(Theme.spring) { value += change }
        } label: {
            Image(systemName: symbol).font(.footnote.weight(.bold)).frame(width: 36, height: 36)
                .background(Theme.ink.opacity(0.06), in: Circle())
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(Theme.ink)
    }
}

/// A capsule for a choice: filled when selected, quiet otherwise.
struct ChoiceChip: View {
    let title: String
    var symbol: String? = nil
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: { withAnimation(Theme.spring) { action() } }) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 15)
            .frame(minHeight: 42)
            .foregroundStyle(selected ? Theme.canvas : Theme.ink)
            .background(selected ? Theme.ink : Theme.ink.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The look of a capsule that opens a menu.
struct MenuChipLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
            Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 14)
        .frame(minHeight: 38)
        .background(Theme.ink.opacity(0.06), in: Capsule())
    }
}

extension View {
    /// Lifts a cutout off the canvas: a soft shadow in light mode and a faint glow in dark mode, just enough to keep
    /// black pieces visible without pulling the eye away from the clothes.
    func garmentLift() -> some View {
        shadow(color: Theme.lift, radius: 10, y: 4)
    }
}

/// An on/off switch drawn in the app's style; a plain button underneath, so it behaves like every other control here.
struct SwitchButton: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(Theme.spring) { isOn.toggle() }
        } label: {
            Capsule()
                .fill(isOn ? Theme.ink : Theme.ink.opacity(0.12))
                .frame(width: 50, height: 30)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(isOn ? Theme.canvas : Theme.card).padding(3).shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isOn)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}
