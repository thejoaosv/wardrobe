import PhotosUI
import SwiftUI

struct ImportForm: View {
    @Environment(Store.self) private var store
    @State private var selection: [PhotosPickerItem] = []
    @State private var analyzing = 0

    private var busy: Bool { analyzing > 0 || store.jobs.contains { ["queued", "processing", "pending"].contains($0.current.stage.status) } }

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
                if analyzing > 0 {
                    ReviewCard(title: "Finding clothes", subtitle: "Looking at \(analyzing) photo\(analyzing == 1 ? "" : "s")", imageURL: nil) { EmptyView() }
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
                ForEach(store.jobs) { JobCard(job: $0).transition(.scale(scale: 0.96).combined(with: .opacity)) }
            }
            .padding(24)
            .animation(Theme.spring, value: store.jobs.map(\.current.stage.status))
            .animation(Theme.spring, value: analyzing)
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
                analyzing += 1
                Task {
                    defer { analyzing -= 1 }
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
        ReviewCard(title: job.metadata.name, subtitle: waiting ? "Cutting out…" : step, imageURL: waiting ? nil : store.url(stage.assetUrl)) {
            switch stage.status {
            case "review":
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

private struct ReviewCard<Actions: View>: View {
    let title: String
    let subtitle: String
    let imageURL: URL?
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                if let imageURL {
                    AsyncImage(url: imageURL, transaction: Transaction(animation: .easeOut(duration: 0.35))) { phase in
                        if case .success(let image) = phase { image.resizable().scaledToFit().transition(.opacity) }
                    }
                } else {
                    PhaseAnimator([0.4, 1]) { opacity in
                        Image(systemName: "sparkles").font(.system(size: 36, weight: .light)).foregroundStyle(Theme.muted).opacity(opacity)
                    } animation: { _ in .easeInOut(duration: 0.9) }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 240)
            .shadow(color: .black.opacity(0.1), radius: 12, y: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(subtitle).eyebrow()
                Text(title).font(.display(22))
            }
            actions
        }
        .padding(18)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}
