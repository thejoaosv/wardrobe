import PhotosUI
import SwiftUI

struct ImportForm: View {
    @Environment(Store.self) private var store
    @State private var selection: [PhotosPickerItem] = []
    private var busy: Bool { !store.detecting.isEmpty || store.jobs.contains { ["queued", "processing", "pending"].contains($0.current.stage.status) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Add clothes").font(.display(34))
                Group {
                    if let config = store.config, !config.ready {
                        Text("On your Mac, run `codex login` to use your ChatGPT plan, or add an OpenAI API key.")
                    } else {
                        Text("Each piece is cut out from your photo. Keep the ones you like.")
                    }
                }
                .font(.subheadline).foregroundStyle(Theme.muted)
                ForEach(store.detecting, id: \.self) { id in
                    ReviewCard(title: "New photo", subtitle: "Finding clothes", status: store.progress["detect:\(id)"], imageURL: nil) { EmptyView() }
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
                ForEach(store.jobs) { JobCard(job: $0).transition(.scale(scale: 0.96).combined(with: .opacity)) }
            }
            .padding(24)
            .animation(Theme.spring, value: store.jobs.map(\.current.stage.status))
            .animation(Theme.spring, value: store.detecting)
        }
        .safeAreaInset(edge: .bottom) {
            PhotosPicker(selection: $selection, maxSelectionCount: 5, matching: .images) {
                Text("Choose photos")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(store.config?.ready != true)
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
        .background(Theme.canvas.ignoresSafeArea())
        .task(id: busy) {
            await store.loadJobs()
            // Poll while generations run on the server.
            while busy && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                await store.loadJobs()
            }
        }
        .onChange(of: selection) { _, picked in
            guard !picked.isEmpty else { return }
            selection = []
            for item in picked {
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self), let jpeg = uploadJPEG(data) else { return }
                    await store.importPhoto(jpeg)
                }
            }
        }
    }
}

private struct JobCard: View {
    @Environment(Store.self) private var store
    let job: Job

    var body: some View {
        let (name, stage) = job.current
        let step = name == "crop" ? "Is this the right piece?" : "Cutout"
        let waiting = ["queued", "processing", "pending"].contains(stage.status)
        ReviewCard(title: job.metadata.name, subtitle: waiting ? "Cutting out" : step, status: waiting ? store.progress["job:\(job.id)"] : nil, skeleton: GarmentKind(part: job.metadata.part, name: job.metadata.name), imageURL: waiting ? nil : store.url(stage.assetUrl)) {
            switch stage.status {
            case "review":
                if let warnings = stage.warnings, !warnings.isEmpty {
                    ReviewerNote(warnings: warnings)
                }
                HStack(spacing: 10) {
                    Button("Keep") { Task { await store.review(job, "approve") } }.buttonStyle(PrimaryButtonStyle())
                    if name != "crop" {
                        Button("Try again", systemImage: "arrow.clockwise") { Task { await store.review(job, "regenerate") } }
                            .labelStyle(.iconOnly).buttonStyle(QuietButtonStyle())
                    }
                    Button("Discard", systemImage: "xmark") { Task { await store.review(job, "reject") } }
                        .labelStyle(.iconOnly).buttonStyle(QuietButtonStyle())
                }
            case "failed":
                VStack(alignment: .leading, spacing: 10) {
                    Text(stage.error ?? "That didn't work.").font(.footnote).foregroundStyle(Theme.muted).lineLimit(3)
                    Button("Try again") { Task { await store.review(job, "regenerate") } }.buttonStyle(QuietButtonStyle())
                }
            default:
                EmptyView()
            }
        }
    }
}

/// What the AI reviewer still saw wrong after its retries, so the user knows what to check before keeping it.
struct ReviewerNote: View {
    let warnings: [String]

    var body: some View {
        Label {
            Text("Still not quite right: \(warnings.joined(separator: " · "))")
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .font(.footnote)
        .foregroundStyle(Theme.muted)
        .lineLimit(4)
    }
}

private struct ReviewCard<Actions: View>: View {
    let title: String
    let subtitle: String
    /// The AI's live status, e.g. "Retrying (2/3): …".
    var status: String? = nil
    /// Silhouette shown while waiting; nil cycles through kinds of clothing.
    var skeleton: GarmentKind? = nil
    let imageURL: URL?
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                if let imageURL {
                    AsyncImage(url: imageURL, transaction: Transaction(animation: .easeOut(duration: 0.35))) { phase in
                        if case .success(let image) = phase { image.resizable().scaledToFit().transition(.opacity) }
                    }
                } else if let skeleton {
                    GarmentSkeleton(kind: skeleton).padding(.vertical, 16).transition(.opacity)
                } else {
                    CyclingGarmentSkeleton().padding(.vertical, 16).transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 240)
            .shadow(color: .black.opacity(0.1), radius: 12, y: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(subtitle).eyebrow()
                Text(title).font(.display(22))
                if let status {
                    Text(status).font(.footnote).foregroundStyle(Theme.muted).lineLimit(3)
                        .contentTransition(.opacity)
                        .padding(.top, 4)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: status)
            actions
        }
        .padding(18)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}
