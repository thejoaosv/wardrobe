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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(plan?.style ?? " ").eyebrow()
                Text(Day.date(date), format: .dateTime.weekday(.wide)).font(.display(38))
            }
            .padding(.horizontal, 24)

            Group {
                if isStyling || plan == nil {
                    StylingPlaceholder()
                } else if let plan {
                    DressedOutfit(items: plan.garmentIds.compactMap(store.item), plan: plan)
                        .id(plan.garmentIds.joined())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 32)
            .overlay(alignment: .topTrailing) {
                if let plan, !isStyling, store.config?.hasModelReference == true {
                    TryOnBadge(plan: plan).padding(.trailing, 20).transition(.opacity)
                }
            }

            if let plan, !isStyling {
                PlanFooter(plan: plan).padding(.horizontal, 24).transition(.opacity)
            } else {
                Text("Styling…").eyebrow().padding(.horizontal, 24).frame(minHeight: 96, alignment: .top)
            }
        }
        .padding(.bottom, 12)
        .animation(Theme.spring, value: isStyling)
    }
}

private struct PlanFooter: View {
    @Environment(Store.self) private var store
    let plan: Plan

    private var inLaundry: [Item] { plan.garmentIds.compactMap(store.item).filter { !$0.isAvailable } }

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(plan.name).font(.display(24)).lineLimit(1).minimumScaleFactor(0.8)
                if inLaundry.isEmpty {
                    Text(plan.reason).font(.subheadline).foregroundStyle(Theme.muted).lineLimit(2)
                } else {
                    Label("\(inLaundry.map(\.name).formatted()) in the wash", systemImage: "washer")
                        .font(.subheadline).foregroundStyle(Theme.muted).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if inLaundry.isEmpty {
                Menu {
                    Button("Restyle", systemImage: "sparkles") { restyle() }
                    Button("Remove", systemImage: "trash", role: .destructive) { Task { await store.deletePlan(plan) } }
                } label: {
                    circle("ellipsis", filled: false)
                }
                .accessibilityLabel("Outfit options")
            } else {
                // Something is in the wash, so restyling becomes the one obvious action.
                Button(action: restyle) { circle("sparkles", filled: true) }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Restyle")
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(minHeight: 96, alignment: .top)
    }

    private func circle(_ symbol: String, filled: Bool) -> some View {
        Image(systemName: symbol)
            .font(.body.weight(.semibold))
            .frame(width: 44, height: 44)
            .foregroundStyle(filled ? Theme.canvas : Theme.ink)
            .background(filled ? Theme.ink : Theme.ink.opacity(0.06), in: Circle())
    }

    private func restyle() {
        Task { await store.generate([PlanDay(date: Day.date(plan.date), style: plan.style, weather: plan.weather ?? "auto")]) }
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
            .shadow(color: .black.opacity(0.12), radius: 14, y: 10)
            .saturation(item.isAvailable ? 1 : 0)
            .opacity(shown ? (item.isAvailable ? 1 : 0.45) : 0)
            .offset(y: shown || reduceMotion ? 0 : 28)
            .scaleEffect(shown || reduceMotion ? 1 : 0.94)
            .contextMenu {
                if let plan {
                    Button("Swap this piece", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await store.generate([PlanDay(date: Day.date(plan.date), style: plan.style, weather: plan.weather ?? "auto", replace: item.id)]) }
                    }
                }
                Button(item.isAvailable ? "In the wash" : "Back from the wash", systemImage: "washer") {
                    Task { await store.setUnavailable([item.id], item.isAvailable) }
                }
                Button("Remove piece", systemImage: "trash", role: .destructive) { Task { await store.delete(item) } }
            }
            .onTapGesture { editing = true }
            .sheet(isPresented: $editing) { ItemSheet(item: item) }
            .onAppear {
                withAnimation(Theme.spring.delay(Double(order) * 0.08)) { shown = true }
            }
            .animation(Theme.spring, value: item.isAvailable)
    }
}

/// Soft silhouettes that breathe while the stylist works.
private struct StylingPlaceholder: View {
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            PhaseAnimator([0.35, 0.8]) { opacity in
                ZStack {
                    RoundedRectangle(cornerRadius: 28).frame(width: width * 0.7, height: height * 0.34).position(x: width / 2, y: height * 0.2)
                    RoundedRectangle(cornerRadius: 28).frame(width: width * 0.5, height: height * 0.4).position(x: width / 2, y: height * 0.6)
                    Capsule().frame(width: width * 0.4, height: height * 0.08).position(x: width / 2, y: height * 0.9)
                }
                .foregroundStyle(Theme.ink.opacity(0.06))
                .opacity(opacity)
            } animation: { _ in .easeInOut(duration: 1.1) }
        }
        .accessibilityLabel("Styling outfit")
    }
}

/// Small corner control: ask for a try-on, watch it work, then open the result.
private struct TryOnBadge: View {
    @Environment(Store.self) private var store
    @Namespace private var zoom
    @State private var showing = false
    let plan: Plan

    var body: some View {
        Group {
            switch plan.tryOn?.status {
            case "ready":
                Button { showing = true } label: {
                    AsyncImage(url: store.url(plan.tryOn?.image), transaction: Transaction(animation: .easeOut(duration: 0.35))) { phase in
                        if case .success(let image) = phase { image.resizable().scaledToFill().transition(.opacity) } else { Theme.ink.opacity(0.06) }
                    }
                    .frame(width: 64, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
                }
                .buttonStyle(PressableStyle())
                .matchedTransitionSource(id: plan.date, in: zoom)
                .accessibilityLabel("See \(plan.name) on you")
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            case "processing":
                Label("Dressing you…", systemImage: "sparkles")
                    .font(.footnote.weight(.medium))
                    .symbolEffect(.pulse)
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .background(Theme.ink.opacity(0.06), in: Capsule())
            default:
                Button(plan.tryOn?.status == "failed" ? "Try again" : "Try on", systemImage: "person.crop.rectangle") {
                    Task { await store.tryOn(plan) }
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(QuietButtonStyle())
                .accessibilityHint("Makes a photo of you wearing this outfit")
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
            AsyncImage(url: store.url(plan.tryOn?.image)) { phase in
                if case .success(let image) = phase { image.resizable().scaledToFit() } else { Color.clear }
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("You wearing \(plan.name)")

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(plan.style).eyebrow()
                    Text(plan.name).font(.display(28))
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
