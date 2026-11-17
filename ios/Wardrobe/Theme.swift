import SwiftUI

enum Theme {
    static let canvas = Color(light: 0xF4F1EB, dark: 0x0E0D0C)
    static let card = Color(light: 0xFFFFFF, dark: 0x1A1917)
    static let ink = Color(light: 0x161513, dark: 0xF4F1EB)
    static let muted = Color(light: 0x8A847A, dark: 0x8F8980)
    static let spring = Animation.spring(duration: 0.55, bounce: 0.22)
}

// SwiftUI resolves dynamic colors on its render thread during animations, so this must not be main-actor isolated.
nonisolated extension Color {
    init(light: UInt32, dark: UInt32) {
        let light = Self.rgb(light)
        let dark = Self.rgb(dark)
        self.init(uiColor: UIColor { @Sendable traits in traits.userInterfaceStyle == .dark ? dark : light })
    }

    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Font {
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .regular, design: .serif) }
}

extension View {
    /// Small tracked uppercase label used for dates and section names.
    func eyebrow() -> some View {
        font(.caption.weight(.semibold)).tracking(1.6).textCase(.uppercase).foregroundStyle(Theme.muted)
    }
}

/// Solid ink capsule for the one primary action on a screen.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Theme.canvas)
            .padding(.horizontal, 28)
            .frame(minHeight: 54)
            .frame(maxWidth: .infinity)
            .background(Theme.ink, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.spring, value: configuration.isPressed)
    }
}

/// Quiet text action that still gives press feedback.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(Theme.ink.opacity(configuration.isPressed ? 0.12 : 0.06), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Theme.spring, value: configuration.isPressed)
    }
}

/// Garment cutout that fades in once loaded; transparent PNGs sit directly on the canvas.
struct GarmentImage: View {
    @Environment(Store.self) private var store
    let item: Item?

    var body: some View {
        AsyncImage(url: store.url(item?.image), transaction: Transaction(animation: .easeOut(duration: 0.35))) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFit().transition(.opacity)
            } else {
                Color.clear
            }
        }
        .accessibilityLabel(item?.name ?? "Missing item")
    }
}

/// Wraps chips onto as many lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews, width: proposal.width ?? .infinity)
        let height = rows.map { $0.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0 }.reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            let height = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            for view in row {
                let size = view.sizeThatFits(.unspecified)
                view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += height + spacing
        }
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[LayoutSubview]] {
        var rows: [[LayoutSubview]] = [[]]
        var x: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, !rows[rows.count - 1].isEmpty {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append(view)
            x += size.width + spacing
        }
        return rows
    }
}

nonisolated extension Color {
    /// "#rrggbb" as stored by the server.
    init?(hex: String?) {
        guard let hex, hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    var hex: String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let byte = { (value: CGFloat) in Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(red), byte(green), byte(blue))
    }
}

/// Photos are downscaled before upload; the server never needs more than 2048px.
func uploadJPEG(_ data: Data) -> Data? {
    guard let image = UIImage(data: data) else { return nil }
    let scale = min(1, 2048 / max(image.size.width, image.size.height))
    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    return UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }.jpegData(compressionQuality: 0.85)
}
