import PhotosUI
import SwiftUI

/// Bottom sheet for one piece: the cutout on the canvas, its name and quick toggles, then grouped panels.
struct ItemSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Item
    @State private var newTag = ""
    @State private var frontPick: PhotosPickerItem?
    @State private var backPick: PhotosPickerItem?
    @State private var picking: Side?
    @State private var shooting: Side?
    @State private var confirmingRemove = false
    /// The side shown in the pager; held here so it stays put when a cutout finishes.
    @State private var page = Side.front
    /// The side whose photo is on its way to the Mac, before the server reports it as processing.
    @State private var sending: Side?
    @State private var scroll = ScrollPosition(edge: .top)
    private let original: Item

    enum Side: String, Identifiable { case front, back; var id: String { rawValue } }

    private func isBusy(_ side: Side) -> Bool { sending == side || (side == .front ? frontStatus : backStatus) == "processing" }

    init(item: Item) {
        original = item
        _draft = State(initialValue: item)
    }

    /// Live copy for state the server changes (wash, cutouts).
    private var live: Item { store.item(original.id) ?? original }
    private var backStatus: String? { live.back?.status }
    private var frontStatus: String? { live.front?.status }
    private var status: String? { store.progress["cutout:\(original.id)"] }
    private var warnings: [String] { (live.front?.warnings ?? []) + (live.back?.warnings ?? []) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    photos

                    VStack(alignment: .leading, spacing: 14) {
                        TextField("Name", text: $draft.name, axis: .vertical)
                            .font(.display(30))
                            .submitLabel(.done)
                        HStack(spacing: 8) {
                            Menu {
                                Picker("Category", selection: $draft.part) {
                                    ForEach(Parts.order, id: \.self) { Text(Parts.label($0)).tag($0) }
                                }
                            } label: {
                                MenuChipLabel(title: Parts.label(draft.part))
                            }
                            ChoiceChip(title: "In the wash", symbol: "washer", selected: !live.isAvailable) {
                                Task { await store.setUnavailable([live.id], live.isAvailable) }
                            }
                            .sensoryFeedback(.selection, trigger: live.isAvailable)
                            .accessibilityHint("Toggles whether it's in the wash")
                        }
                    }

                    Panel(title: "For the stylist", footer: "Outfits and cutouts use these. Write text exactly as printed, e.g. front: large \"ROTATION\", small \"LX\" below.") {
                        field("Description") {
                            TextField("Fabric, fit, warmth, how dressy it is", text: optional(\.description), axis: .vertical)
                                .lineLimit(2...6)
                        }
                        field(live.backImage == nil ? "Text on it" : "Text on the front") {
                            TextField("None", text: optional(\.text), axis: .vertical)
                                .lineLimit(1...3)
                        }
                        if live.backImage != nil {
                            field("Text on the back") {
                                TextField("None", text: optional(\.backText), axis: .vertical)
                                    .lineLimit(1...3)
                            }
                        }
                    }

                    Panel(title: "Look") {
                        PanelRow(title: "Main color") {
                            ColorPicker("Main color", selection: colorBinding(\.color), supportsOpacity: false).labelsHidden()
                        }
                        PanelRow(title: "Second color") {
                            if draft.secondaryColor != nil {
                                HStack(spacing: 12) {
                                    Button("Remove second color", systemImage: "xmark.circle.fill") { withAnimation(Theme.spring) { draft.secondaryColor = nil } }
                                        .labelStyle(.iconOnly).foregroundStyle(Theme.muted).buttonStyle(.plain)
                                    ColorPicker("Second color", selection: colorBinding(\.secondaryColor), supportsOpacity: false).labelsHidden()
                                }
                            } else {
                                Button("Add") { withAnimation(Theme.spring) { draft.secondaryColor = "#8a847a" } }
                                    .font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink)
                            }
                        }
                        field("Details") { tags }
                    }

                    Panel(title: "Laundry", footer: draft.wears == nil
                          ? "Uses the default for \(Parts.label(draft.part).lowercased()), set in Settings. Outfits can repeat it on nearby days up to this many times."
                          : "Outfits can repeat it on nearby days up to this many times.") {
                        PanelRow(title: "Wears before washing", detail: draft.wears == nil ? "Default" : nil) {
                            CountStepper(value: Binding(get: { draft.wears ?? store.defaultWears(draft.part) }, set: { draft.wears = $0 }))
                        }
                        if draft.wears != nil {
                            Button { withAnimation(Theme.spring) { draft.wears = nil } } label: {
                                PanelRow(title: "Use the default (\(store.defaultWears(draft.part))×)", symbol: "arrow.uturn.backward")
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Panel(title: "Photos") {
                            Menu {
                                Button("From its photo", systemImage: "arrow.clockwise") { Task { await use(nil, for: .front) } }
                                photoSources(.front)
                            } label: {
                                photoRow(.front, title: "Redo cutout", symbol: "wand.and.sparkles", detail: "Pressed and checked again")
                            }
                            .disabled(isBusy(.front))
                            Menu {
                                if live.backImage != nil {
                                    Button("From its photo", systemImage: "arrow.clockwise") { Task { await use(nil, for: .back) } }
                                }
                                photoSources(.back)
                                if live.backImage != nil {
                                    Button("Remove back", systemImage: "trash", role: .destructive) { Task { await store.removeBack(live) } }
                                }
                            } label: {
                                photoRow(.back, title: live.backImage == nil ? "Add the back" : "Back", symbol: "arrow.uturn.backward.square",
                                         detail: live.backImage == nil ? "Try-ons can then show it" : "Redo, replace or remove")
                            }
                            .disabled(isBusy(.back))
                        }
                        photoNote.font(.footnote).padding(.horizontal, 4)
                    }

                    Button("Remove piece", role: .destructive) { confirmingRemove = true }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .padding(24)
            }
            .scrollPosition($scroll)
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.canvas.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
            .confirmationDialog("Remove \(live.name)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
                Button("Remove piece", role: .destructive) {
                    Task { await store.delete(live) }
                    dismiss()
                }
            } message: {
                Text("It disappears from your closet and future outfits.")
            }
        }
        .modifier(SheetErrors())
        .presentationDetents([.large])
        .presentationBackground(Theme.canvas)
        .presentationDragIndicator(.visible)
        // Saves on any dismissal (Done or swipe), only if something changed.
        .onDisappear { Task { await save() } }
        .photosPicker(isPresented: Binding(get: { picking == .front }, set: { if !$0 { picking = nil } }), selection: $frontPick, matching: .images)
        .photosPicker(isPresented: Binding(get: { picking == .back }, set: { if !$0 { picking = nil } }), selection: $backPick, matching: .images)
        .fullScreenCover(item: $shooting) { side in
            CameraPicker { photo in
                guard let jpeg = uploadJPEG(photo) else { return }
                Task { await use(jpeg, for: side) }
            }
            .ignoresSafeArea()
        }
        // The Mac can rewrite details while the sheet is open (a back photo updates them); take its values for fields
        // the user hasn't touched, so closing the sheet doesn't overwrite them with the old ones.
        .onChange(of: live) { old, new in
            func merge<T: Equatable>(_ key: WritableKeyPath<Item, T>) { if draft[keyPath: key] == old[keyPath: key] { draft[keyPath: key] = new[keyPath: key] } }
            merge(\.name); merge(\.part); merge(\.color); merge(\.secondaryColor); merge(\.description)
            merge(\.text); merge(\.backText); merge(\.tags); merge(\.wears)
        }
        .onChange(of: frontPick) { _, pick in load(pick, for: .front) }
        .onChange(of: backPick) { _, pick in load(pick, for: .back) }
        .task(id: "\(backStatus ?? "")\(frontStatus ?? "")") {
            // Cutouts take about a minute on the Mac.
            while (backStatus == "processing" || frontStatus == "processing") && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                await store.loadItems()
            }
        }
    }

    /// Errors and the reviewer's leftover notes for the cutouts.
    @ViewBuilder private var photoNote: some View {
        if frontStatus == "failed" {
            Text("Cutout: \(live.front?.error ?? "That didn't work.")").foregroundStyle(.red)
        } else if backStatus == "failed" {
            Text("Back: \(live.back?.error ?? "That didn't work.")").foregroundStyle(.red)
        } else if !warnings.isEmpty {
            ReviewerNote(warnings: warnings)
        }
    }

    /// Saves edited details, only if they differ from what the server has; a cutout redo reads them from there.
    private func save() async {
        addTag()
        guard let saved = store.item(original.id) else { return }
        if draft.name != saved.name || draft.part != saved.part || draft.color != saved.color
            || draft.secondaryColor != saved.secondaryColor || draft.tags != saved.tags || draft.wears != saved.wears
            || draft.description != saved.description || draft.text != saved.text || draft.backText != saved.backText {
            await store.update(draft)
        }
    }

    /// Front and back in a pager, straight on the canvas; a side being made shows its skeleton and the AI's status.
    private var photos: some View {
        TabView(selection: $page) {
            Group {
                if isBusy(.front) {
                    working("Redoing the cutout…")
                } else {
                    GarmentImage(item: live).garmentLift()
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 36)
            .tag(Side.front)
            if isBusy(.back) || live.backImage != nil {
                Group {
                    if isBusy(.back) {
                        working(live.backImage == nil ? "Cutting out the back…" : "Redoing the back…")
                    } else {
                        AsyncImage(url: store.url(live.backImage, width: 800), transaction: Transaction(animation: .easeOut(duration: 0.35))) { phase in
                            if case .success(let image) = phase { image.resizable().scaledToFit().transition(.opacity) } else { Color.clear }
                        }
                        .garmentLift()
                        .accessibilityLabel("Back of \(live.name)")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 36)
                .tag(Side.back)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: live.backImage != nil || isBusy(.back) ? .automatic : .never))
        .indexViewStyle(.page(backgroundDisplayMode: .never))
        .frame(height: 340)
        .padding(.horizontal, -24)
        .saturation(live.isAvailable ? 1 : 0)
        .opacity(live.isAvailable ? 1 : 0.6)
        .animation(Theme.spring, value: live.isAvailable)
    }

    private var tags: some View {
        FlowLayout {
            ForEach(draft.tags ?? [], id: \.self) { tag in
                Button {
                    withAnimation(Theme.spring) { draft.tags?.removeAll { $0 == tag } }
                } label: {
                    HStack(spacing: 6) {
                        Text(tag)
                        Image(systemName: "xmark").font(.caption2.weight(.semibold)).foregroundStyle(Theme.muted)
                    }
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 32)
                    .background(Theme.ink.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(tag)")
            }
            TextField("Add detail", text: $newTag)
                .font(.subheadline)
                .frame(width: 110, height: 32)
                .submitLabel(.done)
                .onSubmit(addTag)
        }
    }

    @ViewBuilder private func photoSources(_ side: Side) -> some View {
        if CameraPicker.isAvailable {
            Button("Take photo", systemImage: "camera") { shooting = side }
        }
        Button("Choose photo", systemImage: "photo.on.rectangle") { picking = side }
    }

    private func load(_ pick: PhotosPickerItem?, for side: Side) {
        guard let pick else { return }
        if side == .front { frontPick = nil } else { backPick = nil }
        Task {
            guard let data = try? await pick.loadTransferable(type: Data.self), let jpeg = uploadJPEG(data) else { return }
            await use(jpeg, for: side)
        }
    }

    /// nil redoes that side from the photo it already has.
    private func use(_ jpeg: Data?, for side: Side) async {
        // Show that side being made, at the top where its skeleton and status are.
        sending = side
        defer { sending = nil }
        withAnimation(Theme.spring) {
            page = side
            scroll.scrollTo(edge: .top)
        }
        switch side {
        case .front:
            await save()
            await store.redoCutout(live, jpeg: jpeg)
        case .back:
            await store.addBack(live, jpeg: jpeg)
        }
    }

    /// A photo action's row; while that side is being made it says so, with a spinner instead of the chevron.
    private func photoRow(_ side: Side, title: String, symbol: String, detail: String) -> some View {
        let busy = isBusy(side)
        let doing = side == .front ? "Redoing the cutout" : live.backImage == nil ? "Cutting out the back" : "Redoing the back"
        return PanelRow(title: busy ? doing : title, symbol: symbol, detail: busy ? (sending == side ? "Sending the photo…" : status ?? "About a minute") : detail) {
            if busy { ProgressView() } else { RowValue() }
        }
        .animation(.easeInOut(duration: 0.2), value: busy)
    }

    private func working(_ title: String) -> some View {
        VStack(spacing: 14) {
            GarmentSkeleton(kind: GarmentKind(part: live.part, name: live.name, tags: live.tags ?? []))
                .frame(height: 190)
            Text(title).eyebrow()
            if let status {
                Text(status).font(.footnote).foregroundStyle(Theme.muted).multilineTextAlignment(.center).lineLimit(3)
            }
        }
    }

    /// A panel row with its label above the control, for text that needs the full width.
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote).foregroundStyle(Theme.muted)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func optional(_ key: WritableKeyPath<Item, String?>) -> Binding<String> {
        Binding(get: { draft[keyPath: key] ?? "" }, set: { draft[keyPath: key] = $0 })
    }

    private func colorBinding(_ key: WritableKeyPath<Item, String?>) -> Binding<Color> {
        Binding(get: { Color(hex: draft[keyPath: key]) ?? Theme.muted }, set: { draft[keyPath: key] = $0.hex })
    }

    private func addTag() {
        let tag = newTag.trimmingCharacters(in: .whitespaces).lowercased()
        newTag = ""
        guard !tag.isEmpty, !(draft.tags ?? []).contains(tag) else { return }
        withAnimation(Theme.spring) { draft.tags = (draft.tags ?? []) + [tag] }
    }
}
