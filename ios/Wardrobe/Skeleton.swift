import SwiftUI

/// Silhouette families used as loading skeletons.
nonisolated enum GarmentKind: String, CaseIterable {
    case tee, hoodie, sweater, jacket, pants, shoes, cap

    init(part: String, name: String = "", tags: [String] = []) {
        let words = ([name] + tags).joined(separator: " ").lowercased()
        switch part {
        case "midlayer": self = words.contains("hood") ? .hoodie : .sweater
        case "wholebody_up": self = .jacket
        case "lowerbody": self = .pants
        case "shoes": self = .shoes
        case "accessories_up": self = .cap
        default: self = .tee
        }
    }

    /// Width over height of the silhouette.
    var aspect: CGFloat {
        switch self {
        case .pants: 0.62
        case .shoes: 2.2
        case .cap: 1.4
        default: 1
        }
    }

    /// Outlines in a unit square, as closed polygons.
    var outlines: [[CGPoint]] {
        let p = { (x: CGFloat, y: CGFloat) in CGPoint(x: x, y: y) }
        let longSleeves = [p(0.24, 0.12), p(0.06, 0.5), p(0.03, 0.88), p(0.15, 0.9), p(0.21, 0.52), p(0.23, 0.38), p(0.23, 0.97),
                           p(0.77, 0.97), p(0.77, 0.38), p(0.79, 0.52), p(0.85, 0.9), p(0.97, 0.88), p(0.94, 0.5), p(0.76, 0.12)]
        switch self {
        case .tee:
            return [[p(0.38, 0.06), p(0.5, 0.14), p(0.62, 0.06), p(0.78, 0.1), p(0.99, 0.3), p(0.88, 0.43), p(0.78, 0.35), p(0.78, 0.97),
                     p(0.22, 0.97), p(0.22, 0.35), p(0.12, 0.43), p(0.01, 0.3), p(0.22, 0.1)]]
        case .sweater:
            return [[p(0.38, 0.08), p(0.5, 0.14), p(0.62, 0.08)] + longSleeves.reversed()]
        case .hoodie:
            return [[p(0.34, 0.16), p(0.33, 0.07), p(0.39, 0.015), p(0.5, 0), p(0.61, 0.015), p(0.67, 0.07), p(0.66, 0.16)] + longSleeves.reversed()]
        case .jacket:
            // A deep open V collar tells it apart from a sweater.
            return [[p(0.34, 0.04), p(0.42, 0.16), p(0.5, 0.36), p(0.58, 0.16), p(0.66, 0.04)] + longSleeves.reversed()]
        case .pants:
            return [[p(0.1, 0.02), p(0.9, 0.02), p(0.98, 0.98), p(0.58, 0.98), p(0.5, 0.34), p(0.42, 0.98), p(0.02, 0.98)]]
        case .shoes:
            return [[p(0.02, 0.95), p(0.02, 0.55), p(0.08, 0.36), p(0.3, 0.44), p(0.42, 0.18), p(0.52, 0.22), p(0.72, 0.52), p(0.9, 0.6),
                     p(1, 0.78), p(0.98, 0.95)]]
        case .cap:
            return [[p(0.12, 0.68), p(0.14, 0.44), p(0.24, 0.22), p(0.42, 0.1), p(0.58, 0.14), p(0.7, 0.3), p(0.74, 0.54), p(1, 0.64),
                     p(0.96, 0.76), p(0.12, 0.74)]]
        }
    }
}

/// The silhouette drawn aspect-fit into its frame.
nonisolated struct GarmentShape: Shape {
    var kind: GarmentKind

    func path(in rect: CGRect) -> Path {
        let width = min(rect.width, rect.height * kind.aspect)
        let height = width / kind.aspect
        let origin = CGPoint(x: rect.midX - width / 2, y: rect.midY - height / 2)
        var path = Path()
        for outline in kind.outlines {
            path.addLines(outline.map { CGPoint(x: origin.x + $0.x * width, y: origin.y + $0.y * height) })
            path.closeSubpath()
        }
        return path
    }
}

/// A soft garment silhouette with a light sweeping across it while the AI works.
struct GarmentSkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let kind: GarmentKind
    @State private var sweep = false

    var body: some View {
        let shape = GarmentShape(kind: kind)
        ZStack {
            // A round stroke softens the polygon corners; composited first so the overlap doesn't show as an outline.
            ZStack {
                shape.fill()
                shape.stroke(style: StrokeStyle(lineWidth: 8, lineJoin: .round))
            }
            .foregroundStyle(Theme.ink)
            .compositingGroup()
            .opacity(0.07)
            GeometryReader { geometry in
                LinearGradient(colors: [.clear, Theme.ink.opacity(0.09), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: geometry.size.width * 0.5)
                    .offset(x: sweep ? geometry.size.width : -geometry.size.width * 0.5)
            }
            .mask(shape.stroke(style: StrokeStyle(lineWidth: 8, lineJoin: .round)).overlay(shape.fill()))
            .opacity(reduceMotion ? 0 : 1)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) { sweep = true }
        }
        .accessibilityHidden(true)
    }
}

/// Cycles through kinds of clothing while the AI looks for pieces in a photo.
struct CyclingGarmentSkeleton: View {
    private static let kinds: [GarmentKind] = [.tee, .hoodie, .pants, .jacket, .shoes, .sweater, .cap]
    @State private var index = 0

    var body: some View {
        ZStack {
            GarmentSkeleton(kind: Self.kinds[index])
                .id(index)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.8))
                withAnimation(.easeInOut(duration: 0.45)) { index = (index + 1) % Self.kinds.count }
            }
        }
        .accessibilityLabel("Finding clothes")
    }
}
