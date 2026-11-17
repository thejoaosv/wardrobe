import PhotosUI
import SwiftUI

/// Connection first, then what the AI does, the photo try-ons use, and about. The changelog hides behind the server version.
struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var versionTaps = 0
    @State private var showsChangelog = false
    @State private var choosingPhoto = false
    @State private var takingPhoto = false
    @State private var photoPick: PhotosPickerItem?

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

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
                    connection
                } header: {
                    Text("Your Mac")
                } footer: {
                    Text("Run `npm run dev` in the wardrobe folder on your Mac, then enter its address.")
                }

                if store.serverIsOutdated {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Update Wardrobe on your Mac").font(.body.weight(.semibold))
                                Text("This app needs a newer server. In the wardrobe folder, run `git pull`, then restart `npm run dev`.")
                                    .font(.footnote).foregroundStyle(Theme.muted)
                            }
                        } icon: {
                            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
                        }
                    }
                }

                if let config = store.config {
                    Section {
                        LabeledContent("Runs on", value: ["codex": "Your ChatGPT plan", "api": "OpenAI API key"][config.provider ?? ""] ?? "Not set up")
                        if let settings = store.settings {
                            Picker("Quality checks", selection: Binding(get: { settings.checks }, set: { value in Task { await store.setChecks(value) } })) {
                                Text("Thorough").tag("thorough")
                                Text("Fast").tag("fast")
                            }
                        }
                    } header: {
                        Text("AI")
                    } footer: {
                        Text(store.settings?.checks == "fast"
                             ? "Fast: results come back sooner, without a second look. Check cutouts yourself."
                             : "Thorough: every cutout, try-on and photo scan gets a second look and is redone up to 3 times if it's wrong. Slower, but more accurate.")
                    }

                    Section {
                        HStack(spacing: 14) {
                            reference
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Photo of you")
                                Text(config.hasModelReference ? "Ready for try-ons" : "Not added yet").font(.footnote).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Menu(config.hasModelReference ? "Change" : "Add") {
                                if CameraPicker.isAvailable {
                                    Button("Take photo", systemImage: "camera") { takingPhoto = true }
                                }
                                Button("Choose photo", systemImage: "photo.on.rectangle") { choosingPhoto = true }
                            }
                        }
                    } header: {
                        Text("Try-ons")
                    } footer: {
                        Text("Outfits are shown on this person. A full-body photo in good light, facing the camera, works best.")
                    }
                }

                Section("Notifications") {
                    Button("Notification settings") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                    }
                }

                Section {
                    LabeledContent("Valet", value: appVersion)
                    // Looks like a plain row; five taps open the changelog.
                    Button {
                        versionTaps += 1
                        if versionTaps >= 5, store.version != nil { showsChangelog = true; versionTaps = 0 }
                    } label: {
                        LabeledContent("Server", value: store.version?.version ?? (store.config == nil ? "Not connected" : "Before 1.2"))
                    }
                    .foregroundStyle(Theme.ink)
                } header: {
                    Text("About")
                }
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.canvas.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationDestination(isPresented: $showsChangelog) { ChangelogView(releases: store.version?.changelog ?? []) }
            .refreshable { await store.refresh() }
        }
        .photosPicker(isPresented: $choosingPhoto, selection: $photoPick, matching: .images)
        .onChange(of: photoPick) { _, pick in
            guard let pick else { return }
            photoPick = nil
            Task {
                guard let data = try? await pick.loadTransferable(type: Data.self), let jpeg = uploadJPEG(data) else { return }
                await store.uploadModelReference(jpeg)
            }
        }
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { photo in
                guard let jpeg = uploadJPEG(photo) else { return }
                Task { await store.uploadModelReference(jpeg) }
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder private var connection: some View {
        if store.config != nil {
            Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Label("Not connected", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                if let reason = store.connectionError {
                    Text(reason).font(.footnote).foregroundStyle(Theme.muted)
                }
            }
            Button("Try again") { Task { await store.refresh() } }
        }
    }

    private var reference: some View {
        AsyncImage(url: store.config?.hasModelReference == true ? store.url("/api/import/model-reference?v=\(store.referenceStamp.timeIntervalSince1970)") : nil) { phase in
            if case .success(let image) = phase { image.resizable().scaledToFill() } else {
                Image(systemName: "person.crop.rectangle").font(.title2).foregroundStyle(Theme.muted)
            }
        }
        .frame(width: 48, height: 64)
        .background(Theme.ink.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// What changed in each server version, newest first.
private struct ChangelogView: View {
    let releases: [ServerVersion.Release]

    var body: some View {
        List(releases, id: \.version) { release in
            Section {
                ForEach(release.notes, id: \.self) { Text($0).font(.subheadline) }
            } header: {
                HStack {
                    Text(release.version)
                    Spacer()
                    if let date = release.date { Text(date) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.canvas.ignoresSafeArea())
        .navigationTitle("Changelog")
    }
}
