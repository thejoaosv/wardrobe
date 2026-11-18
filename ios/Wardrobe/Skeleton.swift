import CoreImage
import SwiftUI
import Vision

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

    /// A silhouette in a unit box: corner points, each with its rounding radius, and detail lines cut out of it.
    struct Outline {
        var aspect: CGFloat
        var points: [SIMD3<Double>]
        var details: [[SIMD3<Double>]]
    }

    var outline: Outline {
        switch self {
        case .tee:
            Outline(aspect: 1.05,
                    points: [q(0.36, 0.06, 0.02), q(0.42, 0.12, 0.05), q(0.5, 0.15, 0.08), q(0.58, 0.12, 0.05), q(0.64, 0.06, 0.02), q(0.8, 0.12, 0.05), q(0.99, 0.33, 0.03), q(0.87, 0.45, 0.02), q(0.79, 0.38, 0.03), q(0.79, 0.97, 0.03), q(0.21, 0.97, 0.03), q(0.21, 0.38, 0.03), q(0.13, 0.45, 0.02), q(0.01, 0.33, 0.03), q(0.2, 0.12, 0.05)],
                    details: [[q(0.38, 0.08), q(0.5, 0.19, 0.1), q(0.62, 0.08)]])
        case .sweater:
            Outline(aspect: 1,
                    points: [q(0.37, 0.07, 0.02), q(0.43, 0.12, 0.05), q(0.5, 0.145, 0.08), q(0.57, 0.12, 0.05), q(0.63, 0.07, 0.02), q(0.78, 0.12, 0.06), q(0.92, 0.48, 0.08), q(0.96, 0.9, 0.02), q(0.84, 0.92, 0.02), q(0.8, 0.5, 0.06), q(0.79, 0.4, 0.03), q(0.79, 0.96, 0.03), q(0.21, 0.96, 0.03), q(0.21, 0.4, 0.03), q(0.2, 0.5, 0.06), q(0.16, 0.92, 0.02), q(0.04, 0.9, 0.02), q(0.08, 0.48, 0.08), q(0.22, 0.12, 0.06)],
                    details: [[q(0.39, 0.09), q(0.5, 0.18, 0.1), q(0.61, 0.09)], [q(0.22, 0.89), q(0.78, 0.89)], [q(0.05, 0.84), q(0.16, 0.85)], [q(0.84, 0.85), q(0.95, 0.84)]])
        case .hoodie:
            Outline(aspect: 1,
                    points: [q(0.33, 0.2, 0.03), q(0.32, 0.07, 0.1), q(0.5, 0, 0.14), q(0.68, 0.07, 0.1), q(0.67, 0.2, 0.03), q(0.79, 0.14, 0.06), q(0.92, 0.48, 0.08), q(0.96, 0.9, 0.02), q(0.84, 0.92, 0.02), q(0.8, 0.5, 0.06), q(0.79, 0.4, 0.03), q(0.79, 0.96, 0.03), q(0.21, 0.96, 0.03), q(0.21, 0.4, 0.03), q(0.2, 0.5, 0.06), q(0.16, 0.92, 0.02), q(0.04, 0.9, 0.02), q(0.08, 0.48, 0.08), q(0.21, 0.14, 0.06)],
                    details: [[q(0.4, 0.14), q(0.5, 0.27, 0.12), q(0.6, 0.14)], [q(0.46, 0.25), q(0.46, 0.38)], [q(0.54, 0.25), q(0.54, 0.38)], [q(0.32, 0.82), q(0.35, 0.6, 0.03), q(0.65, 0.6, 0.03), q(0.68, 0.82)], [q(0.22, 0.89), q(0.78, 0.89)]])
        case .jacket:
            Outline(aspect: 1,
                    points: [q(0.36, 0.03, 0.02), q(0.64, 0.03, 0.02), q(0.66, 0.1, 0.02), q(0.79, 0.13, 0.06), q(0.93, 0.48, 0.08), q(0.96, 0.9, 0.02), q(0.84, 0.92, 0.02), q(0.8, 0.5, 0.06), q(0.79, 0.4, 0.03), q(0.8, 0.97, 0.03), q(0.2, 0.97, 0.03), q(0.21, 0.4, 0.03), q(0.2, 0.5, 0.06), q(0.16, 0.92, 0.02), q(0.04, 0.9, 0.02), q(0.07, 0.48, 0.08), q(0.21, 0.13, 0.06), q(0.34, 0.1, 0.02)],
                    details: [[q(0.5, 0.04), q(0.5, 0.96)], [q(0.28, 0.62), q(0.36, 0.76)], [q(0.72, 0.62), q(0.64, 0.76)], [q(0.36, 0.1), q(0.64, 0.1)]])
        case .pants:
            Outline(aspect: 0.62,
                    points: [q(0.1, 0.02, 0.03), q(0.9, 0.02, 0.03), q(0.97, 0.97, 0.03), q(0.58, 0.97, 0.03), q(0.5, 0.32, 0.05), q(0.42, 0.97, 0.03), q(0.03, 0.97, 0.03)],
                    details: [[q(0.11, 0.09), q(0.89, 0.09)], [q(0.5, 0.1), q(0.5, 0.24)]])
        case .shoes:
            Outline(aspect: 2.1,
                    points: [q(0.03, 0.94, 0.04), q(0.02, 0.5, 0.1), q(0.09, 0.28, 0.08), q(0.27, 0.36, 0.08), q(0.38, 0.12, 0.06), q(0.47, 0.14, 0.05), q(0.6, 0.38, 0.12), q(0.86, 0.54, 0.16), q(0.99, 0.76, 0.1), q(0.96, 0.95, 0.04)],
                    details: [[q(0.03, 0.8), q(0.97, 0.8)], [q(0.42, 0.26), q(0.48, 0.3)], [q(0.46, 0.33), q(0.52, 0.37)], [q(0.5, 0.4), q(0.56, 0.44)]])
        case .cap:
            Outline(aspect: 1.4,
                    points: [q(0.1, 0.74, 0.03), q(0.12, 0.44, 0.12), q(0.32, 0.14, 0.16), q(0.52, 0.1, 0.12), q(0.7, 0.26, 0.12), q(0.75, 0.58, 0.04), q(0.98, 0.65, 0.05), q(0.95, 0.77, 0.03), q(0.1, 0.8, 0.03)],
                    details: [[q(0.42, 0.12), q(0.46, 0.6)], [q(0.74, 0.6), q(0.76, 0.62)]])
        }
    }
}

// Unrounded points round by 3% of the shape's size.
private nonisolated func q(_ x: Double, _ y: Double, _ radius: Double = 0.03) -> SIMD3<Double> { SIMD3(x, y, radius) }

/// The silhouette drawn aspect-fit into its frame, or with details on, just its detail lines as stroked outlines.
nonisolated struct GarmentShape: Shape {
    var kind: GarmentKind
    var details = false

    func path(in rect: CGRect) -> Path {
        let outline = kind.outline
        let width = min(rect.width, rect.height * outline.aspect)
        let height = width / outline.aspect
        let box = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        let unit = min(width, height)
        guard details else { return rounded(outline.points, in: box, unit: unit, closed: true) }
        var lines = Path()
        for line in outline.details { lines.addPath(rounded(line, in: box, unit: unit, closed: false)) }
        return lines.strokedPath(StrokeStyle(lineWidth: unit * 0.022, lineCap: .round, lineJoin: .round))
    }

    /// Joins the points with straight edges and turns each corner into a curve of that point's radius.
    private func rounded(_ points: [SIMD3<Double>], in box: CGRect, unit: CGFloat, closed: Bool) -> Path {
        let corners = points.map { (point: CGPoint(x: box.minX + $0.x * box.width, y: box.minY + $0.y * box.height), radius: $0.z * unit) }
        let count = corners.count
        func toward(_ from: CGPoint, _ to: CGPoint, _ distance: CGFloat) -> CGPoint {
            let length = hypot(to.x - from.x, to.y - from.y)
            return length == 0 ? from : CGPoint(x: from.x + (to.x - from.x) * distance / length, y: from.y + (to.y - from.y) * distance / length)
        }
        func corner(_ path: inout Path, _ index: Int) {
            let previous = corners[(index - 1 + count) % count].point, next = corners[(index + 1) % count].point
            let (vertex, radius) = corners[index]
            let limit = min(radius, hypot(previous.x - vertex.x, previous.y - vertex.y) / 2, hypot(next.x - vertex.x, next.y - vertex.y) / 2)
            path.addLine(to: toward(vertex, previous, limit))
            path.addQuadCurve(to: toward(vertex, next, limit), control: vertex)
        }
        var path = Path()
        if closed {
            let first = corners[0].point, second = corners[1].point
            path.move(to: CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2))
            for index in 1...count { corner(&path, index % count) }
            path.closeSubpath()
        } else {
            path.move(to: corners[0].point)
            for index in corners.indices.dropFirst().dropLast() { corner(&path, index) }
            path.addLine(to: corners[count - 1].point)
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
            // Composited first so the detail lines cut through to the background.
            ZStack {
                shape.fill()
                GarmentShape(kind: kind, details: true).fill().blendMode(.destinationOut)
            }
            .foregroundStyle(Theme.ink)
            .compositingGroup()
            .opacity(0.08)
            GeometryReader { geometry in
                LinearGradient(colors: [.clear, Theme.ink.opacity(0.09), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: geometry.size.width * 0.5)
                    .offset(x: sweep ? geometry.size.width : -geometry.size.width * 0.5)
            }
            .mask(shape)
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

/// The user's own outline, cut from their try-on photo on the phone, with the same sweeping light as the garments.
struct BodySkeleton: View {
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var silhouette: CGImage?
    @State private var sweep = false

    var body: some View {
        Group {
            if let silhouette {
                let mask = Image(decorative: silhouette, scale: 1).resizable().scaledToFit().luminanceToAlpha()
                ZStack {
                    Theme.ink.opacity(0.08)
                    GeometryReader { geometry in
                        LinearGradient(colors: [.clear, Theme.ink.opacity(0.09), .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: geometry.size.height * 0.35)
                            .offset(y: sweep ? geometry.size.height : -geometry.size.height * 0.35)
                    }
                    .opacity(reduceMotion ? 0 : 1)
                }
                .mask(mask)
                .transition(.opacity)
            } else {
                Image(systemName: "figure.stand").resizable().scaledToFit().fontWeight(.ultraLight)
                    .foregroundStyle(Theme.ink.opacity(0.08)).padding(.vertical, 24)
            }
        }
        .animation(.easeOut(duration: 0.4), value: silhouette != nil)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: false)) { sweep = true }
        }
        .task(id: store.referenceStamp) {
            guard let url = store.url("/api/import/model-reference", width: 900),
                  let (data, _) = try? await URLSession.shared.data(from: url) else { return }
            silhouette = await Task.detached(priority: .userInitiated) { Self.person(in: data) }.value
        }
        .accessibilityHidden(true)
    }

    /// White where the person is, black elsewhere, at the photo's proportions; nil when no person is found.
    nonisolated static func person(in data: Data) -> CGImage? {
        guard let photo = UIImage(data: data)?.cgImage else { return nil }
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        guard (try? VNImageRequestHandler(cgImage: photo).perform([request])) != nil,
              let buffer = request.results?.first?.pixelBuffer else { return nil }
        let full = CIImage(cvPixelBuffer: buffer)
        guard let body = bounds(of: buffer) else { return nil }
        // Softened a touch so the edge reads as a skeleton, not a cutout; cropped to the body so it fills the space.
        let mask = full.clampedToExtent().applyingGaussianBlur(sigma: 2).cropped(to: body)
        return CIContext().createCGImage(mask, from: body)
    }

    /// The person's box in Core Image coordinates (origin bottom left), with a little room around it.
    nonisolated private static func bounds(of buffer: CVPixelBuffer) -> CGRect? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            let row = base + y * stride
            for x in 0..<width where row[x] > 127 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let pad = Double(max(maxX - minX, maxY - minY)) * 0.03
        let box = CGRect(x: Double(minX), y: Double(height - 1 - maxY), width: Double(maxX - minX + 1), height: Double(maxY - minY + 1))
        return box.insetBy(dx: -pad, dy: -pad).intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
    }
}
