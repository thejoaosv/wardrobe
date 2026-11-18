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
                .task(id: store.isWorking) {
                    // Status lines change every few seconds while the AI checks and retries its work.
                    while store.isWorking && !Task.isCancelled {
                        await store.poll()
                        try? await Task.sleep(for: .seconds(2))
                    }
                    store.progress = [:]
                }
                .task(id: scenePhase) {
                    // Notices a lost Mac within seconds, so taps fail at once instead of after a long timeout.
                    while scenePhase == .active && !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(store.isOnline ? 5 : 3))
                        await store.checkConnection()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background, store.hasPendingWork, let base = store.baseURL {
                        // A second back so a result that lands as the app leaves isn't missed by the Mac's whole-second clock reading.
                        let since = Date.now.addingTimeInterval(store.serverClockOffset - 1)
                        let reviews = store.reviewCount
                        Task { await withBackgroundTime("arm-wait") { await Notifier.shared.arm(base: base, since: since, reviews: reviews) } }
                    } else if phase == .active {
                        Task { await store.refresh() }
                    }
                }
                .modifier(ErrorAlert(store: store, active: store.sheetDepth == 0))
        }
    }
}

/// Shows the store's error as an alert. The root shows it only while no sheet is open: presenting an alert from
/// under a sheet makes SwiftUI close the sheet, which is how a failed tap used to throw the user out of a sheet.
struct ErrorAlert: ViewModifier {
    // Passed in: at the root this sits outside .environment(store).
    let store: Store
    var active = true

    func body(content: Content) -> some View {
        content.alert("Something went wrong", isPresented: Binding(get: { active && store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.error ?? "")
        }
    }
}

/// Put on a sheet's content: it takes over showing errors while it is open.
struct SheetErrors: ViewModifier {
    @Environment(Store.self) private var store

    func body(content: Content) -> some View {
        content
            .modifier(ErrorAlert(store: store))
            .onAppear { store.sheetDepth += 1 }
            .onDisappear { store.sheetDepth -= 1 }
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
        .overlay(alignment: .top) {
            if !store.isOnline {
                Label("Not connected to your Mac", systemImage: "wifi.slash")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Theme.spring, value: store.isOnline)
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
            // The plan form stays alive so switching back keeps picked styles; imports live in the store, and the
            // import form's looping skeletons shouldn't keep animating out of sight.
            ZStack {
                PlanForm().opacity(mode == .plan ? 1 : 0).allowsHitTesting(mode == .plan).accessibilityHidden(mode != .plan)
                if mode == .clothes { ImportForm().transition(.opacity) }
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
        .modifier(SheetErrors())
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.canvas)
    }
}
