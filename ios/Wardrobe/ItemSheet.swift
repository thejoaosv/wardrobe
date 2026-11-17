import PhotosUI
import SwiftUI

/// Bottom sheet for one piece: its photos, editable details, and the wash and remove actions.
struct ItemSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Item
    @State private var newTag = ""
    @State private var backPick: PhotosPickerItem?
    @State private var confirmingRemove = false
    private let original: Item

    init(item: Item) {
        original = item
        _draft = State(initialValue: item)
    }

    /// Live copy for state the server changes (wash, back cutout).
    private var live: Item { store.item(original.id) ?? original }
    private var backStatus: String? { live.back?.status }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    photos

                    TextField("Name", text: $draft.name, axis: .vertical)
                        .font(.display(30))
                        .submitLabel(.done)

                    field("Category") {
                        Menu {
                            Picker("Category", selection: $draft.part) {
                                ForEach(Parts.order, id: \.self) { Text(Parts.label($0)).tag($0) }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(Parts.label(draft.part))
                                Image(systemName: "chevron.up.chevron.down").font(.caption)
                            }
                            .font(.body.weight(.medium))
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 40)
                            .background(Theme.ink.opacity(0.06), in: Capsule())
                        }
                    }

                    field("Description") {
                        TextField("Fabric, fit, warmth, how dressy it is", text: optional(\.description), axis: .vertical)
                            .font(.body)
                            .lineLimit(2...6)
                    }

                    field("Text on it") {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("None", text: optional(\.text), axis: .vertical)
                                .font(.body)
                                .lineLimit(1...3)
                            Text("Exactly as printed, e.g. front: large \"ROTATION\", small \"LX\" below. Cutouts copy it letter for letter.")
                                .font(.footnote).foregroundStyle(Theme.muted)
                        }
                    }

                    field("Colors") {
                        HStack(spacing: 20) {
                            ColorPicker("Main", selection: colorBinding(\.color), supportsOpacity: false)
                                .fixedSize()
                            if draft.secondaryColor != nil {
                                ColorPicker("Second", selection: colorBinding(\.secondaryColor), supportsOpacity: false)
                                    .fixedSize()
                                Button("Remove second color", systemImage: "xmark.circle.fill") { draft.secondaryColor = nil }
                                    .labelStyle(.iconOnly)
                                    .foregroundStyle(Theme.muted)
                            } else {
                                Button("Add second color", systemImage: "plus") { draft.secondaryColor = "#8a847a" }
                                    .font(.subheadline.weight(.medium))
                            }
                        }
                        .font(.subheadline)
                    }

                    field("Details") {
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
                                    .padding(.horizontal, 14)
                                    .frame(minHeight: 36)
                                    .background(Theme.ink.opacity(0.06), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(tag)")
                            }
                            TextField("Add detail", text: $newTag)
                                .font(.subheadline)
                                .frame(width: 120, height: 36)
                                .submitLabel(.done)
                                .onSubmit(addTag)
                        }
                    }

                    field("Wears before washing") {
                        VStack(alignment: .leading, spacing: 6) {
                            Stepper(value: Binding(get: { draft.wearLimit }, set: { draft.wears = $0 }), in: 1...10) {
                                Text(draft.wearLimit == 1 ? "Once" : "\(draft.wearLimit) times").font(.body.weight(.medium))
                                    .contentTransition(.numericText())
                            }
                            Text("Outfits can repeat it on nearby days up to this many times.")
                                .font(.footnote).foregroundStyle(Theme.muted)
                        }
                    }

                    field("Back") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Add a photo of the back if it has a print or detail worth seeing. Try-ons will then turn to show it.")
                                .font(.footnote).foregroundStyle(Theme.muted)
                            if backStatus == "failed" {
                                Text(live.back?.error ?? "That didn't work.").font(.footnote).foregroundStyle(.red).lineLimit(3)
                            }
                            HStack(spacing: 10) {
                                PhotosPicker(selection: $backPick, matching: .images) {
                                    Label(live.backImage == nil ? "Add back photo" : "Replace back photo", systemImage: "camera")
                                }
                                .buttonStyle(QuietButtonStyle())
                                .disabled(backStatus == "processing")
                                if live.backImage != nil {
                                    Button("Remove back", systemImage: "trash") { Task { await store.removeBack(live) } }
                                        .labelStyle(.iconOnly)
                                        .buttonStyle(QuietButtonStyle())
                                }
                            }
                        }
                    }

                    VStack(spacing: 10) {
                        Button {
                            Task { await store.setUnavailable([live.id], live.isAvailable) }
                        } label: {
                            Label(live.isAvailable ? "Put in the wash" : "Back from the wash", systemImage: "washer")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(QuietButtonStyle())
                        .sensoryFeedback(.selection, trigger: live.isAvailable)

                        Button("Remove piece", role: .destructive) { confirmingRemove = true }
                            .font(.subheadline.weight(.medium))
                            .frame(minHeight: 44)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(24)
            }
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
        .presentationDetents([.large])
        .presentationBackground(Theme.canvas)
        .presentationDragIndicator(.visible)
        // Saves on any dismissal (Done or swipe), only if something changed.
        .onDisappear {
            addTag()
            if draft.name != original.name || draft.part != original.part || draft.color != original.color
                || draft.secondaryColor != original.secondaryColor || draft.tags != original.tags || draft.wears != original.wears
                || draft.description != original.description || draft.text != original.text,
               store.item(original.id) != nil {
                let edited = draft
                Task { await store.update(edited) }
            }
        }
        .onChange(of: backPick) { _, pick in
            guard let pick else { return }
            backPick = nil
            Task {
                guard let data = try? await pick.loadTransferable(type: Data.self), let jpeg = uploadJPEG(data) else { return }
                await store.addBack(live, jpeg: jpeg)
            }
        }
        .task(id: backStatus) {
            // Back cutouts take about a minute on the Mac.
            while backStatus == "processing" && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                await store.loadItems()
            }
        }
    }

    /// Front and back side by side in a pager; the back pulses while it's being cut out.
    private var photos: some View {
        TabView {
            GarmentImage(item: live).padding(20)
            if backStatus == "processing" {
                VStack(spacing: 12) {
                    PhaseAnimator([0.4, 1]) { opacity in
                        Image(systemName: "sparkles").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.muted).opacity(opacity)
                    } animation: { _ in .easeInOut(duration: 0.9) }
                    Text("Cutting out the back…").eyebrow()
                }
            } else if let back = live.backImage {
                AsyncImage(url: store.url(back), transaction: Transaction(animation: .easeOut(duration: 0.35))) { phase in
                    if case .success(let image) = phase { image.resizable().scaledToFit().transition(.opacity) } else { Color.clear }
                }
                .padding(20)
                .accessibilityLabel("Back of \(live.name)")
            }
        }
        .tabViewStyle(.page(indexDisplayMode: live.backImage != nil || backStatus == "processing" ? .automatic : .never))
        .indexViewStyle(.page(backgroundDisplayMode: .interactive))
        .frame(height: 320)
        .frame(maxWidth: .infinity)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .saturation(live.isAvailable ? 1 : 0)
        .animation(Theme.spring, value: live.isAvailable)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).eyebrow()
            content()
        }
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
