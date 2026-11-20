import PhotosUI
import SwiftUI

enum SettingsPage: Hashable { case connection, quality, photo, laundry, about, changelog }

/// A short overview of every setting; each opens its own page, so nothing is piled on top of anything else.
struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var path: [SettingsPage] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    Text("Settings").font(.display(34))

                    link(.connection) {
                        HStack(spacing: 10) {
                            Circle().fill(!store.isConnected ? Color.red : store.serverIsOutdated ? Color.orange : Color.green).frame(width: 8, height: 8)
                            Text(!store.isConnected ? "Not connected to the server" : store.serverIsOutdated ? "The server needs an update" : "Connected to the server")
                                .font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink)
                            Spacer()
                            RowValue()
                        }
                        .padding(.horizontal, 18)
                        .frame(minHeight: 52)
                        .background(Theme.card, in: Capsule())
                    }

                    Panel(title: "Outfits") {
                        link(.laundry) { PanelRow(title: "Washing", symbol: "washer") { RowValue() } }
                        link(.photo) { PanelRow(title: "Photo of you", symbol: "person.crop.rectangle") { RowValue() } }
                    }

                    Panel(title: "App") {
                        link(.quality) { PanelRow(title: "AI quality", symbol: "checkmark.seal") { RowValue() } }
                        Button {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                        } label: {
                            PanelRow(title: "Notifications", symbol: "bell") { RowValue(symbol: "arrow.up.right") }
                        }
                        .buttonStyle(.plain)
                        link(.about) { PanelRow(title: "About", symbol: "info.circle") { RowValue() } }
                    }
                }
                .padding(24)
            }
            .background(Theme.canvas.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await store.refresh() }
            .navigationDestination(for: SettingsPage.self) { page in
                Group {
                    switch page {
                    case .connection: ConnectionPage()
                    case .quality: QualityPage()
                    case .photo: PhotoPage()
                    case .laundry: LaundryPage()
                    case .about: AboutPage(path: $path)
                    case .changelog: ChangelogPage(releases: store.version?.changelog ?? [])
                    }
                }
                .background(Theme.canvas.ignoresSafeArea())
            }
        }
    }

    private func link<Label: View>(_ page: SettingsPage, @ViewBuilder label: () -> Label) -> some View {
        NavigationLink(value: page, label: label).buttonStyle(.plain)
    }
}

/// A settings sub-page: a serif title and its panels.
private struct Page<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text(title).font(.display(30))
                content
            }
            .padding(24)
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ConnectionPage: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        Page(title: "Server") {
            Panel(title: "Server address", footer: "Enter the address of the computer running the wardrobe server, e.g. http://my-server.local:5173.") {
                TextField("http://my-server.local:5173", text: $store.serverURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { Task { await store.refresh() } }
                    .padding(.horizontal, 18)
                    .frame(minHeight: 58)
            }

            Panel(title: "Status") {
                if store.isConnected {
                    PanelRow(title: "Connected", symbol: "checkmark.circle.fill", detail: store.version.map { "Server \($0.version)" })
                } else {
                    PanelRow(title: "Not connected", symbol: "xmark.circle", detail: store.connectionError)
                }
                Button { Task { await store.refresh() } } label: {
                    PanelRow(title: "Check again", symbol: "arrow.clockwise")
                }
                .buttonStyle(.plain)
            }

            if store.serverIsOutdated {
                Panel(title: "Update needed", footer: "This app needs a newer server. On the server, run `git pull` in the wardrobe folder, then restart the wardrobe service.") {
                    PanelRow(title: "Server is out of date", symbol: "arrow.triangle.2.circlepath")
                }
            }
        }
    }
}

private struct QualityPage: View {
    @Environment(Store.self) private var store

    var body: some View {
        Page(title: "AI quality") {
            Text("After the AI finds clothes, cuts them out or dresses you, a second look can check its work against your photo.")
                .font(.subheadline).foregroundStyle(Theme.muted)
            VStack(spacing: 12) {
                option("thorough", "Thorough", "Every result gets a second look and is redone up to 3 times if the text, colors or shape are wrong. Slower, more accurate.")
                option("fast", "Fast", "Results come back sooner without the second look. Check cutouts yourself.")
            }
        }
    }

    private func option(_ id: String, _ title: String, _ detail: String) -> some View {
        let selected = (store.settings?.checks ?? "thorough") == id
        return Button { Task { await store.setChecks(id) } } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.body.weight(.semibold))
                    Text(detail).font(.subheadline).foregroundStyle(Theme.muted).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.ink)
            .padding(18)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.ink.opacity(selected ? 0.6 : 0), lineWidth: 1.5))
        }
        .buttonStyle(PressableStyle())
        .disabled(store.settings == nil)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PhotoPage: View {
    @Environment(Store.self) private var store
    @State private var choosing = false
    @State private var taking = false
    @State private var pick: PhotosPickerItem?

    var body: some View {
        Page(title: "Photo of you") {
            RetryingAsyncImage(url: store.config?.hasModelReference == true ? store.url("/api/import/model-reference?v=\(store.referenceStamp.timeIntervalSince1970)", width: 900) : nil) { phase in
                if case .success(let image) = phase { image.resizable().scaledToFill() } else {
                    Image(systemName: "person.crop.rectangle").font(.system(size: 44, weight: .light)).foregroundStyle(Theme.muted)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 380)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .accessibilityLabel("Your photo for try-ons")

            Text("Try-ons dress this person in your planned outfits. A full-body photo facing the camera, in good light, works best.")
                .font(.subheadline).foregroundStyle(Theme.muted)

            HStack(spacing: 10) {
                if CameraPicker.isAvailable {
                    Button("Take photo") { taking = true }.buttonStyle(PrimaryButtonStyle())
                }
                Button("Choose photo") { choosing = true }.buttonStyle(QuietButtonStyle())
            }
        }
        .photosPicker(isPresented: $choosing, selection: $pick, matching: .images)
        .onChange(of: pick) { _, item in
            guard let item else { return }
            pick = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self), let jpeg = await uploadJPEG(data) else { return }
                await store.uploadModelReference(jpeg)
            }
        }
        .fullScreenCover(isPresented: $taking) {
            CameraPicker { photo in
                Task {
                    guard let jpeg = await uploadJPEG(photo) else { return }
                    await store.uploadModelReference(jpeg)
                }
            }
            .ignoresSafeArea()
        }
    }
}

private struct LaundryPage: View {
    @Environment(Store.self) private var store

    var body: some View {
        Page(title: "Washing") {
            Text("How many times each type is worn before it goes in the wash. Outfits can repeat a piece on nearby days up to this many times. A piece can still set its own.")
                .font(.subheadline).foregroundStyle(Theme.muted)
            Panel {
                ForEach(Parts.order, id: \.self) { part in
                    PanelRow(title: Parts.label(part)) {
                        CountStepper(value: Binding(get: { store.defaultWears(part) }, set: { value in Task { await store.setDefaultWears(part, value) } }))
                    }
                }
            }
            .disabled(store.settings?.wears == nil)
            if store.settings?.wears == nil {
                Text("Update the server to change these.").font(.footnote).foregroundStyle(Theme.muted)
            }
        }
    }
}

private struct AboutPage: View {
    @Environment(Store.self) private var store
    @Binding var path: [SettingsPage]
    @State private var versionTaps = 0

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        Page(title: "About") {
            Panel {
                PanelRow(title: "Valet") { Text(appVersion).foregroundStyle(Theme.muted) }
                // Looks like a plain row; five quick taps open the changelog.
                Button {
                    versionTaps += 1
                    if versionTaps >= 5, store.version != nil { path.append(.changelog); versionTaps = 0 }
                } label: {
                    PanelRow(title: "Server") {
                        Text(store.version?.version ?? (store.config == nil ? "Not connected" : "Before 1.2")).foregroundStyle(Theme.muted)
                    }
                }
                .buttonStyle(.plain)
                PanelRow(title: "AI runs on") {
                    Text(["codex": "ChatGPT plan", "api": "API key"][store.config?.provider ?? ""] ?? "Not set up").foregroundStyle(Theme.muted)
                }
            }
        }
    }
}

/// What changed in each server version, newest first.
private struct ChangelogPage: View {
    let releases: [ServerVersion.Release]

    var body: some View {
        Page(title: "Changelog") {
            ForEach(releases, id: \.version) { release in
                Panel(title: [release.version, release.date].compactMap(\.self).joined(separator: " · ")) {
                    ForEach(release.notes, id: \.self) { note in
                        Text(note).font(.subheadline).foregroundStyle(Theme.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 18).padding(.vertical, 14)
                    }
                }
            }
        }
    }
}
