import SwiftUI

struct OutfitsView: View {
    @Environment(Store.self) private var store
    @State private var selected: String?

    /// Planned days from today on, plus days still being styled.
    private var days: [String] {
        Set(store.plans.map(\.date).filter { $0 >= Day.today }).union(store.planningDates).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            if days.isEmpty {
                EmptyPlan { store.sheet = .plan }
            } else {
                DayStrip(days: days, selected: $selected)
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(days, id: \.self) { date in
                            DayPage(date: date)
                                .containerRelativeFrame(.horizontal)
                                .scrollTransition(axis: .horizontal) { content, phase in
                                    content
                                        .scaleEffect(phase.isIdentity ? 1 : 0.9)
                                        .opacity(phase.isIdentity ? 1 : 0.3)
                                }
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollIndicators(.hidden)
                .scrollPosition(id: $selected)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: days) { _, days in
            if selected == nil || !days.contains(selected!) { selected = days.first }
        }
        .onAppear { selected = selected ?? days.first }
        .sensoryFeedback(.selection, trigger: selected)
        .task(id: store.plans.contains { $0.tryOn?.status == "processing" }) {
            // Try-ons take about a minute on the Mac; refresh until they land.
            while store.plans.contains(where: { $0.tryOn?.status == "processing" }) && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                await store.loadPlans()
            }
        }
    }
}

private struct EmptyPlan: View {
    let plan: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "hanger")
                .font(.system(size: 54, weight: .thin))
                .foregroundStyle(Theme.muted)
            Text("Nothing planned").font(.display(34))
            Text("Choose a style and get a fresh outfit\nfor each day.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.muted)
            Spacer()
            Button("Plan my week", action: plan).buttonStyle(QuietButtonStyle())
        }
        .padding(24)
    }
}

/// Compact row of planned dates; tap to jump.
private struct DayStrip: View {
    let days: [String]
    @Binding var selected: String?
    @Namespace private var marker

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(days, id: \.self) { date in
                    let isSelected = date == selected
                    Button {
                        withAnimation(Theme.spring) { selected = date }
                    } label: {
                        VStack(spacing: 2) {
                            Text(Day.date(date), format: .dateTime.weekday(.narrow)).font(.caption2.weight(.semibold))
                            Text(Day.date(date), format: .dateTime.day()).font(.callout.monospacedDigit())
                        }
                        .frame(width: 40, height: 50)
                        .foregroundStyle(isSelected ? Theme.canvas : Theme.ink)
                        .background {
                            if isSelected { Capsule().fill(Theme.ink).matchedGeometryEffect(id: "marker", in: marker) }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(Day.date(date), format: .dateTime.weekday(.wide).day().month()))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
        .padding(.vertical, 8)
    }
}

private struct DayPage: View {
    @Environment(Store.self) private var store
    let date: String

    private var plan: Plan? { store.plans.first { $0.date == date } }
    private var isStyling: Bool { store.planningDates.contains(date) }

    /// Parts the outfit being styled will have, and ones it may or may not get, from its weather and what the closet holds.
    private var expectedOutfit: (parts: Set<String>, maybe: Set<String>) {
        let day = store.planning[date]
        let owned = Set(store.items.filter(\.isAvailable).map(\.part))
        // A swap keeps the outfit's shape.
        if day?.replace != nil, let plan {
            return (Set(plan.garmentIds.compactMap { store.item($0)?.part }), [])
        }
        var parts: Set<String> = ["upperbody", "lowerbody", "shoes"]
        var maybe: Set<String> = []
        switch day?.weather ?? plan?.weather ?? "auto" {
        case "warm": break
        case "cold": parts.formUnion(["midlayer", "wholebody_up"])
        case "rain": parts.insert("wholebody_up"); maybe.insert("midlayer")
        default: maybe.insert("midlayer")
        }
        return (parts.intersection(owned).union(["upperbody", "lowerbody"]), maybe.intersection(owned))
    }

    /// "Casual · Rain", leaving out what wasn't chosen.
    private var subtitle: String {
        let weather = ["warm": "Warm", "mild": "Mild", "cold": "Cold", "rain": "Rain"][plan?.weather ?? store.planning[date]?.weather ?? ""]
        return [plan?.style ?? store.planning[date]?.style, weather].compactMap(\.self).joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(subtitle.isEmpty ? " " : subtitle).eyebrow()
                    Text(Day.date(date), format: .dateTime.weekday(.wide)).font(.display(38))
                }
                Spacer(minLength: 0)
                if let plan, !isStyling { DayMenu(plan: plan).transition(.opacity) }
            }
            .padding(.horizontal, 24)

            Group {
                if isStyling || plan == nil {
                    StylingPlaceholder(expected: expectedOutfit)
                } else if let plan {
                    DressedOutfit(items: plan.garmentIds.compactMap(store.item), plan: plan)
                        .id(plan.garmentIds.joined())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 32)

            Group {
                if let plan, !isStyling {
                    DayDetails(plan: plan).transition(.opacity)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Styling…").font(.display(24))
                        Text(store.progress["plan:\(date)"] ?? "Picking pieces that go together.")
                            .font(.subheadline).foregroundStyle(Theme.muted).lineLimit(2)
                            .contentTransition(.opacity)
                    }
                    .animation(.easeInOut(duration: 0.25), value: store.progress["plan:\(date)"])
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 24)
        }
        .padding(.bottom, 16)
        .animation(Theme.spring, value: isStyling)
    }
}

/// Restyle and remove, tucked into one round button by the day's title.
private struct DayMenu: View {
    @Environment(Store.self) private var store
    let plan: Plan

    var body: some View {
        Menu {
            Button("Restyle", systemImage: "sparkles") { Task { await store.generate([PlanDay(plan)]) } }
            Button("Remove", systemImage: "trash", role: .destructive) { Task { await store.deletePlan(plan) } }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .foregroundStyle(Theme.ink)
                .background(Theme.ink.opacity(0.06), in: Circle())
        }
        .accessibilityLabel("Outfit options")
    }
}

/// The outfit's name, why it works (in full), what's in the wash, and the try-on.
private struct DayDetails: View {
    @Environment(Store.self) private var store
    let plan: Plan

    private var inLaundry: [Item] { plan.garmentIds.compactMap(store.item).filter { !$0.isAvailable } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(plan.name).font(.display(26)).lineLimit(2).minimumScaleFactor(0.85)
                Text(plan.reason).font(.subheadline).foregroundStyle(Theme.muted)
                    .lineLimit(5).fixedSize(horizontal: false, vertical: true)
            }
            if !inLaundry.isEmpty {
                Label("\(inLaundry.map(\.name).formatted()) in the wash", systemImage: "washer")
                    .font(.footnote.weight(.medium)).foregroundStyle(Theme.ink)
            }
            HStack(spacing: 10) {
                if !inLaundry.isEmpty {
                    // Something is in the wash, so restyling becomes the obvious next step.
                    Button("Restyle", systemImage: "sparkles") { Task { await store.generate([PlanDay(plan)]) } }
                        .buttonStyle(QuietButtonStyle())
                }
                if store.config?.hasModelReference == true { TryOnControl(plan: plan) }
            }
        }
    }
}

/// Where each top sits when one, two or three are layered: outermost at the back right, base top in front.
let topFan: [[(x: CGFloat, width: CGFloat)]] = [[(0.5, 0.82)], [(0.62, 0.7), (0.4, 0.66)], [(0.68, 0.6), (0.5, 0.6), (0.32, 0.58)]]

/// The outfit laid out as it is worn: layers and top above bottoms, shoes at the feet.
struct DressedOutfit: View {
    let items: [Item]
    var plan: Plan?

    private func first(_ part: String) -> Item? { items.first { $0.part == part } }

    var body: some View {
        let tops = ["wholebody_up", "midlayer", "upperbody"].compactMap(first)
        let bottom = first("lowerbody")
        let shoes = first("shoes")
        let accessory = first("accessories_up")
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            // Cutouts carry ~6% padding, so zones overlap slightly to read as one figure.
            ZStack {
                ForEach(Array(tops.enumerated()), id: \.element.id) { index, top in
                    let slot = topFan[tops.count - 1][index]
                    GarmentPiece(item: top, order: index, plan: plan)
                        .frame(width: width * slot.width, height: height * 0.4)
                        .position(x: width * slot.x, y: height * (0.2 + 0.005 * CGFloat(index)))
                        .zIndex(Double(index) + 1)
                }
                if let bottom {
                    GarmentPiece(item: bottom, order: tops.count, plan: plan)
                        .frame(width: width * 0.8, height: height * 0.46)
                        .position(x: width * 0.5, y: height * 0.6)
                        .zIndex(0.5)
                }
                if let shoes {
                    GarmentPiece(item: shoes, order: tops.count + 1, plan: plan)
                        .frame(width: width * 0.48, height: height * 0.16)
                        .position(x: width * 0.5, y: height * 0.91)
                }
                if let accessory {
                    GarmentPiece(item: accessory, order: tops.count + 2, plan: plan)
                        .frame(width: width * 0.26, height: height * 0.14)
                        .position(x: width * 0.88, y: height * 0.08)
                        .zIndex(5)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct GarmentPiece: View {
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: Item
    let order: Int
    let plan: Plan?
    @State private var shown = false
    @State private var editing = false

    var body: some View {
        GarmentImage(item: item)
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 24, style: .continuous))
            .contextMenu {
                if let plan {
                    Button("Swap this piece", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await store.generate([PlanDay(plan, replace: item.id)]) }
                    }
                }
                Button(item.isAvailable ? "In the wash" : "Back from the wash", systemImage: "washer") {
                    Task { await store.setUnavailable([item.id], item.isAvailable) }
                }
                Button("Remove piece", systemImage: "trash", role: .destructive) { Task { await store.delete(item) } }
            }
            // After the menu, so the long-press preview shows the piece without its glow cut off at the edges.
            .garmentLift()
            .saturation(item.isAvailable ? 1 : 0)
            .opacity(shown ? (item.isAvailable ? 1 : 0.45) : 0)
            .offset(y: shown || reduceMotion ? 0 : 28)
            .scaleEffect(shown || reduceMotion ? 1 : 0.94)
            .onTapGesture { editing = true }
            .sheet(isPresented: $editing) { ItemSheet(item: item) }
            .onAppear {
                withAnimation(Theme.spring.delay(Double(order) * 0.08)) { shown = true }
            }
            .animation(Theme.spring, value: item.isAvailable)
    }
}

/// A garment skeleton laid out like DressedOutfit; a layer the stylist may or may not add fades in and out.
private struct StylingPlaceholder: View {
    let expected: (parts: Set<String>, maybe: Set<String>)
    @State private var showsMaybe = false

    var body: some View {
        let parts = expected.parts.union(showsMaybe ? expected.maybe : [])
        let tops = ["wholebody_up", "midlayer", "upperbody"].filter(parts.contains)
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            ZStack {
                ForEach(Array(tops.enumerated()), id: \.element) { index, part in
                    let slot = topFan[tops.count - 1][index]
                    GarmentSkeleton(kind: GarmentKind(part: part, name: "hood"))
                        .frame(width: width * slot.width * 0.86, height: height * 0.34)
                        .position(x: width * slot.x, y: height * 0.2)
                        .zIndex(Double(index) + 1)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
                GarmentSkeleton(kind: .pants)
                    .frame(width: width * 0.8, height: height * 0.4)
                    .position(x: width * 0.5, y: height * 0.6)
                if parts.contains("shoes") {
                    GarmentSkeleton(kind: .shoes)
                        .frame(width: width * 0.36, height: height * 0.12)
                        .position(x: width * 0.5, y: height * 0.91)
                }
            }
        }
        .task(id: expected.maybe) {
            guard !expected.maybe.isEmpty else { return showsMaybe = false }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                withAnimation(Theme.spring) { showsMaybe.toggle() }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Styling outfit")
    }
}

/// Try-on in the details row: ask for one, watch it work with the AI's status, then open the result.
private struct TryOnControl: View {
    @Environment(Store.self) private var store
    @Namespace private var zoom
    @State private var showing = false
    let plan: Plan

    var body: some View {
        Group {
            switch plan.tryOn?.status {
            case "ready":
                Button { showing = true } label: {
                    HStack(spacing: 10) {
                        AsyncImage(url: store.url(plan.tryOn?.image, width: 300), transaction: Transaction(animation: .easeOut(duration: 0.35))) { phase in
                            if case .success(let image) = phase { image.resizable().scaledToFill().transition(.opacity) } else { Theme.ink.opacity(0.06) }
                        }
                        .frame(width: 30, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Text("See it on you").font(.subheadline.weight(.medium))
                    }
                    .foregroundStyle(Theme.ink)
                    .padding(.leading, 7).padding(.trailing, 16)
                    .frame(minHeight: 52)
                    .background(Theme.ink.opacity(0.06), in: Capsule())
                }
                .buttonStyle(PressableStyle())
                .matchedTransitionSource(id: plan.date, in: zoom)
                .accessibilityLabel("See \(plan.name) on you")
            case "processing":
                HStack(spacing: 10) {
                    Image(systemName: "sparkles").symbolEffect(.pulse)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Dressing you…").font(.subheadline.weight(.medium))
                        if let status = store.progress["tryon:\(plan.date)"] {
                            Text(status).font(.caption).foregroundStyle(Theme.muted).lineLimit(1).contentTransition(.opacity)
                        }
                    }
                }
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .background(Theme.ink.opacity(0.06), in: Capsule())
                .animation(.easeInOut(duration: 0.25), value: store.progress["tryon:\(plan.date)"])
            default:
                VStack(alignment: .leading, spacing: 6) {
                    Button(plan.tryOn?.status == "failed" ? "Try on again" : "Try it on", systemImage: "person.crop.rectangle") {
                        Task { await store.tryOn(plan) }
                    }
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityHint("Makes a photo of you wearing this outfit")
                    if plan.tryOn?.status == "failed", let error = plan.tryOn?.error {
                        Text(error).font(.caption).foregroundStyle(Theme.muted).lineLimit(2)
                    }
                }
            }
        }
        .animation(Theme.spring, value: plan.tryOn?.status)
        .sensoryFeedback(.success, trigger: plan.tryOn?.status == "ready")
        .fullScreenCover(isPresented: $showing) {
            TryOnViewer(plan: plan).navigationTransition(.zoom(sourceID: plan.date, in: zoom))
        }
    }
}

private struct TryOnViewer: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let plan: Plan

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AsyncImage(url: store.url(plan.tryOn?.image, width: 1600)) { phase in
                if case .success(let image) = phase { image.resizable().scaledToFit() } else { Color.clear }
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("You wearing \(plan.name)")

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(plan.style).eyebrow()
                    Text(plan.name).font(.display(28))
                    if let warnings = plan.tryOn?.warnings, !warnings.isEmpty {
                        ReviewerNote(warnings: warnings).padding(.top, 4)
                    }
                }
                Spacer()
                Button("Try again", systemImage: "arrow.clockwise") {
                    Task { await store.tryOn(plan) }
                    dismiss()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(QuietButtonStyle())
            }
        }
        .padding(20)
        .background(Theme.canvas.ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            Button("Close", systemImage: "xmark") { dismiss() }
                .labelStyle(.iconOnly)
                .buttonStyle(QuietButtonStyle())
                .padding(28)
        }
    }
}
