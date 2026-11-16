import SwiftUI

@main
struct WardrobeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = Store()

    init() {
        // Garment PNGs are immutable on the server, so keep plenty of them around for paging.
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
        let serif = { (style: UIFont.TextStyle, weight: UIFont.Weight) in
            UIFont(descriptor: UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: style).pointSize, weight: weight).fontDescriptor.withDesign(.serif)!, size: 0)
        }
        UINavigationBar.appearance().largeTitleTextAttributes = [.font: serif(.largeTitle, .regular)]
        UINavigationBar.appearance().titleTextAttributes = [.font: serif(.headline, .medium)]
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(Theme.ink)
                .environment(store)
                .task { await store.refresh() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background, store.hasPendingWork, let base = store.baseURL {
                        Notifier.shared.arm(base: base)
                    } else if phase == .active {
                        Task { await store.refresh() }
                    }
                }
                .alert("Something went wrong", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(store.error ?? "")
                }
        }
    }
}

enum AppTab: Hashable { case outfits, closet, settings, add }

enum AppSheet: String, Identifiable {
    case plan, clothes
    var id: String { rawValue }
}

struct RootView: View {
    @Environment(Store.self) private var store
    @State private var tab = AppTab.outfits

    /// iOS 27 shows a prominent tab as its own glass circle beside the bar; iOS 26 does the same for the search role.
    private var addRole: TabRole? {
        if #available(iOS 27.0, *) { return .prominent }
        return .search
    }

    var body: some View {
        @Bindable var store = store
        TabView(selection: $tab) {
            Tab("Outfits", systemImage: "calendar", value: AppTab.outfits) { NavigationStack { OutfitsView() } }
            Tab("Closet", systemImage: "hanger", value: AppTab.closet) { NavigationStack { ClosetView() } }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) { SettingsView() }
            Tab("Add", systemImage: "plus", value: AppTab.add, role: addRole) { Theme.canvas.ignoresSafeArea() }
        }
        // + is an action, not a screen: stay on the current tab and add what fits it.
        .onChange(of: tab) { previous, next in
            guard next == .add else { return }
            tab = previous
            store.sheet = previous == .closet ? .clothes : .plan
        }
        .sheet(item: $store.sheet) { AddSheet(initial: $0) }
    }
}

/// One sheet for adding things, opened on whatever fits the current tab, with a slim switch to the other.
private struct AddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var mode: AppSheet

    init(initial: AppSheet) { _mode = State(initialValue: initial) }

    var body: some View {
        NavigationStack {
            // Both stay alive so switching back keeps picked styles and running imports.
            ZStack {
                PlanForm().opacity(mode == .plan ? 1 : 0).allowsHitTesting(mode == .plan).accessibilityHidden(mode != .plan)
                ImportForm().opacity(mode == .clothes ? 1 : 0).allowsHitTesting(mode == .clothes).accessibilityHidden(mode != .clothes)
            }
            .animation(.easeInOut(duration: 0.2), value: mode)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Add", selection: $mode) {
                        Text("Outfits").tag(AppSheet.plan)
                        Text("Clothes").tag(AppSheet.clothes)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: mode)
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.canvas)
    }
}

struct SettingsView: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                Section {
                    TextField("http://my-mac.local:5173", text: $store.serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { Task { await store.refresh() } }
                } header: {
                    Text("Server")
                } footer: {
                    Text("Run `npm run dev` in the wardrobe folder on your Mac, then enter its address.")
                }
                Section("Status") {
                    if let config = store.config {
                        LabeledContent("AI", value: ["codex": "ChatGPT plan", "api": "OpenAI API key"][config.provider ?? ""] ?? "Not set up")
                        LabeledContent("Photo of you", value: config.hasModelReference ? "Ready" : "Optional, not added")
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Not connected")
                            if let reason = store.connectionError {
                                Text(reason).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Reconnect") { Task { await store.refresh() } }
                }
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.canvas.ignoresSafeArea())
            .navigationTitle("Settings")
        }
    }
}
