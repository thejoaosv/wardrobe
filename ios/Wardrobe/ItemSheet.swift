import PhotosUI
import SwiftUI

/// Bottom sheet for one piece: its photos up top, then the essentials, the stylist's details, and photo tools.
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
    private let original: Item

    enum Side: String, Identifiable { case front, back; var id: String { rawValue } }

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
            Form {
                Section {
                    photos.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }

                Section {
                    TextField("Name", text: $draft.name, axis: .vertical)
                        .font(.display(26))
                        .submitLabel(.done)
                    Picker("Category", selection: $draft.part) {
                        ForEach(Parts.order, id: \.self) { Text(Parts.label($0)).tag($0) }
                    }
                    Toggle(isOn: Binding(get: { !live.isAvailable }, set: { washing in Task { await store.setUnavailable([live.id], washing) } })) {
                        Label("In the wash", systemImage: "washer")
                    }
                    .sensoryFeedback(.selection, trigger: live.isAvailable)
                }

                Section {
                    labeled("Description") {
                        TextField("Fabric, fit, warmth, how dressy it is", text: optional(\.description), axis: .vertical)
                            .lineLimit(2...6)
                    }
                    labeled("Text on it") {
                        TextField("None", text: optional(\.text), axis: .vertical)
                            .lineLimit(1...3)
                    }
                } header: {
                    Text("For the stylist")
                } footer: {
                    Text("Outfits and cutouts use these. Write text exactly as printed, e.g. front: large \"ROTATION\", small \"LX\" below.")
                }

                Section("Look") {
                    ColorPicker("Main color", selection: colorBinding(\.color), supportsOpacity: false)
                    if draft.secondaryColor != nil {
                        ColorPicker(selection: colorBinding(\.secondaryColor), supportsOpacity: false) {
                            HStack {
                                Text("Second color")
                                Button("Remove second color", systemImage: "minus.circle.fill") { draft.secondaryColor = nil }
                                    .labelStyle(.iconOnly).foregroundStyle(Theme.muted).buttonStyle(.plain)
                            }
                        }
                    } else {
                        Button("Add a second color", systemImage: "plus") { draft.secondaryColor = "#8a847a" }
                    }
                    labeled("Details") { tags }
                }

                Section {
                    Stepper(value: Binding(get: { draft.wearLimit }, set: { draft.wears = $0 }), in: 1...10) {
                        LabeledContent("Wears before washing") {
                            Text(draft.wearLimit == 1 ? "Once" : "\(draft.wearLimit)×").monospacedDigit().contentTransition(.numericText())
                        }
                    }
                } footer: {
                    Text("Outfits can repeat it on nearby days up to this many times.")
                }

                Section {
                    Menu {
                        Button("From its photo", systemImage: "arrow.clockwise") { Task { await use(nil, for: .front) } }
                        photoSources(.front)
                    } label: {
                        Label("Redo cutout", systemImage: "wand.and.sparkles")
                    }
                    .disabled(frontStatus == "processing")
                    Menu {
                        photoSources(.back)
                        if live.backImage != nil {
                            Button("Remove back", systemImage: "trash", role: .destructive) { Task { await store.removeBack(live) } }
                        }
                    } label: {
                        Label(live.backImage == nil ? "Add a back photo" : "Replace back photo", systemImage: "arrow.uturn.backward.square")
                    }
                    .disabled(backStatus == "processing")
                } header: {
                    Text("Photos")
                } footer: {
                    photoFooter
                }

                Section {
                    Button("Remove piece", role: .destructive) { confirmingRemove = true }
                        .frame(maxWidth: .infinity)
                }
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.canvas.ignoresSafeArea())
            .navigationTitle(Parts.label(draft.part))
            .navigationBarTitleDisplayMode(.inline)
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

    /// Errors and the reviewer's leftover notes for the cutouts, or a hint when all is well.
    @ViewBuilder private var photoFooter: some View {
        if frontStatus == "failed" {
            Text("Cutout: \(live.front?.error ?? "That didn't work.")").foregroundStyle(.red)
        } else if backStatus == "failed" {
            Text("Back: \(live.back?.error ?? "That didn't work.")").foregroundStyle(.red)
        } else if !warnings.isEmpty {
            ReviewerNote(warnings: warnings)
        } else {
            Text("Redo the cutout if its text or details came out wrong. A back photo lets try-ons show the back.")
        }
    }

    /// Saves edited details, only if they differ from what the server has; a cutout redo reads them from there.
    private func save() async {
        addTag()
        guard let saved = store.item(original.id) else { return }
        if draft.name != saved.name || draft.part != saved.part || draft.color != saved.color
            || draft.secondaryColor != saved.secondaryColor || draft.tags != saved.tags || draft.wears != saved.wears
            || draft.description != saved.description || draft.text != saved.text {
            await store.update(draft)
        }
    }

    /// Front and back in a pager; a side being made shows its skeleton and the AI's status.
    private var photos: some View {
        TabView {
            if frontStatus == "processing" {
                working("Redoing the cutout…")
            } else {
                GarmentImage(item: live).padding(24)
            }
            if backStatus == "processing" {
                working("Cutting out the back…")
            } else if let back = live.backImage {
                AsyncImage(url: store.url(back), transaction: Transaction(animation: .easeOut(duration: 0.35))) { phase in
                    if case .success(let image) = phase { image.resizable().scaledToFit().transition(.opacity) } else { Color.clear }
                }
                .padding(24)
                .accessibilityLabel("Back of \(live.name)")
            }
        }
        .tabViewStyle(.page(indexDisplayMode: live.backImage != nil || backStatus == "processing" ? .automatic : .never))
        .indexViewStyle(.page(backgroundDisplayMode: .interactive))
        .frame(height: 300)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .saturation(live.isAvailable ? 1 : 0)
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
        .padding(.vertical, 2)
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

    /// nil redoes the front from the photo kept at import.
    private func use(_ jpeg: Data?, for side: Side) async {
        switch side {
        case .front:
            await save()
            await store.redoCutout(live, jpeg: jpeg)
        case .back:
            guard let jpeg else { return }
            await store.addBack(live, jpeg: jpeg)
        }
    }

    private func working(_ title: String) -> some View {
        VStack(spacing: 12) {
            GarmentSkeleton(kind: GarmentKind(part: live.part, name: live.name, tags: live.tags ?? []))
                .frame(height: 170)
            Text(title).eyebrow()
            if let status {
                Text(status).font(.footnote).foregroundStyle(Theme.muted).multilineTextAlignment(.center).lineLimit(3).padding(.horizontal, 24)
            }
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote).foregroundStyle(Theme.muted)
            content()
        }
        .padding(.vertical, 2)
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
