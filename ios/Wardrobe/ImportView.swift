import PhotosUI
import SwiftUI

/// Add clothes: one button to start, pieces that need a decision as big cards, and work in progress as compact rows.
struct ImportForm: View {
    @Environment(Store.self) private var store
    @State private var selection: [PhotosPickerItem] = []
    @State private var choosing = false
    @State private var takingPhoto = false

    private static let waiting: Set<String> = ["queued", "processing", "pending"]
    private var needsYou: [Job] { store.jobs.filter { !Self.waiting.contains($0.current.stage.status) } }
    private var working: [Job] { store.jobs.filter { Self.waiting.contains($0.current.stage.status) } }
    private var searching: [Detection] { store.detections.filter(\.isWorking) }
    /// Photos that failed or held no clothes, shown until dismissed.
    private var notices: [Detection] { store.detections.filter { $0.status == "failed" || ($0.status == "done" && $0.found == 0) } }
    private var busy: Bool { !store.uploading.isEmpty || !searching.isEmpty || !working.isEmpty }
    private var ready: Bool { store.config?.ready == true }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Add clothes").font(.display(34))
                    Text(ready ? "Snap or pick photos. Each piece is found, cut out, pressed and checked for you."
                         : "On the server, run `codex login` to use your ChatGPT plan, or add an OpenAI API key.")
                        .font(.subheadline).foregroundStyle(Theme.muted)
                }

                if store.jobs.isEmpty && !busy && notices.isEmpty {
                    Tips().transition(.opacity)
                }

                ForEach(notices) { notice in
                    NoticeRow(detection: notice).transition(.opacity)
                }

                if !needsYou.isEmpty {
                    group(needsYou.count == 1 ? "1 needs you" : "\(needsYou.count) need you") {
                        ForEach(needsYou) { JobCard(job: $0).transition(.scale(scale: 0.96).combined(with: .opacity)) }
                    }
                }

                if busy {
                    group("Working on it") {
                        ForEach(store.uploading, id: \.self) { _ in
                            WorkingRow(kind: nil, title: "New photo", status: "Sending to the server…")
                        }
                        ForEach(searching) { detection in
                            WorkingRow(kind: nil, title: "New photo", status: detection.message ?? "Finding clothes…")
                        }
                        ForEach(working) { job in
                            WorkingRow(kind: GarmentKind(part: job.metadata.part, name: job.metadata.name), title: job.metadata.name,
                                       status: store.progress["job:\(job.id)"] ?? "Cutting out…")
                        }
                    }
                    .transition(.opacity)
                }
            }
            .padding(24)
            .animation(Theme.spring, value: store.jobs.map(\.current.stage.status))
            .animation(Theme.spring, value: store.uploading)
            .animation(Theme.spring, value: store.detections)
        }
        .safeAreaInset(edge: .bottom) {
            start
                .disabled(!ready)
                .opacity(ready ? 1 : 0.4)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
        }
        .background(Theme.canvas.ignoresSafeArea())
        .photosPicker(isPresented: $choosing, selection: $selection, maxSelectionCount: 5, matching: .images)
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { photo in
                Task {
                    guard let jpeg = await uploadJPEG(photo) else { return }
                    await store.importPhoto(jpeg)
                }
            }
            .ignoresSafeArea()
        }
        // The store keeps these fresh while generations run on the Mac.
        .task { await store.loadJobs() }
        .onChange(of: selection) { _, picked in
            guard !picked.isEmpty else { return }
            selection = []
            for item in picked {
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self), let jpeg = await uploadJPEG(data) else { return }
                    await store.importPhoto(jpeg)
                }
            }
        }
    }

    /// The one primary action: asks camera or library, or goes straight to the library without a camera.
    @ViewBuilder private var start: some View {
        let label = Text(store.jobs.isEmpty ? "Start importing" : "Import more")
            .font(.body.weight(.semibold))
            .foregroundStyle(Theme.canvas)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(Theme.ink, in: Capsule())
        if CameraPicker.isAvailable {
            Menu {
                Button("Take photo", systemImage: "camera") { takingPhoto = true }
                Button("Choose from library", systemImage: "photo.on.rectangle") { choosing = true }
            } label: { label }
        } else {
            Button { choosing = true } label: { label }.buttonStyle(PressableStyle())
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).eyebrow()
            content()
        }
    }
}

/// What makes a good photo, shown before the first import.
private struct Tips: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            CyclingGarmentSkeleton()
                .frame(width: 200, height: 160)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            tip("tshirt", "One piece or a whole outfit", "Lay it flat, hang it, or wear it. Every piece in the photo is found.")
            tip("sun.max", "Good light", "Daylight and a plain background give the truest colors and text.")
            tip("wand.and.sparkles", "Cleaned up for you", "Wrinkles are pressed out and each cutout is checked against your photo.")
        }
    }

    private func tip(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title3).frame(width: 28).foregroundStyle(Theme.ink)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(Theme.muted)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A photo that failed or had no clothes in it, until the user dismisses it.
private struct NoticeRow: View {
    @Environment(Store.self) private var store
    let detection: Detection

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: detection.status == "failed" ? "exclamationmark.triangle" : "eye.slash").font(.title3).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(detection.status == "failed" ? "Couldn't read a photo" : "No clothes found in a photo").font(.body.weight(.medium))
                Text(detection.status == "failed" ? detection.error ?? "Try importing it again." : "Try one where the clothes fill more of the frame.")
                    .font(.footnote).foregroundStyle(Theme.muted).lineLimit(3)
            }
            Spacer(minLength: 0)
            Button("Dismiss", systemImage: "xmark") { Task { await store.dismissDetection(detection) } }
                .labelStyle(.iconOnly).font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .foregroundStyle(Theme.ink)
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// A compact line for a photo or piece the AI is still working on.
private struct WorkingRow: View {
    let kind: GarmentKind?
    let title: String
    let status: String

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let kind { GarmentSkeleton(kind: kind) } else { CyclingGarmentSkeleton() }
            }
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium)).lineLimit(1)
                Text(status).font(.footnote).foregroundStyle(Theme.muted).lineLimit(2).contentTransition(.opacity)
            }
            .animation(.easeInOut(duration: 0.25), value: status)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A piece waiting for a decision: confirm the crop, then keep, redo or discard the cutout.
private struct JobCard: View {
    @Environment(Store.self) private var store
    let job: Job

    var body: some View {
        let (name, stage) = job.current
        let isCrop = name == "crop"
        VStack(alignment: .leading, spacing: 14) {
            RetryingAsyncImage(url: store.url(stage.assetUrl, width: 1000), transaction: Transaction(animation: .easeOut(duration: 0.35))) { phase in
                if case .success(let image) = phase { image.resizable().scaledToFit().transition(.opacity) }
                else { GarmentSkeleton(kind: GarmentKind(part: job.metadata.part, name: job.metadata.name)).padding(.vertical, 16) }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 240)
            .shadow(color: .black.opacity(0.1), radius: 12, y: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(stage.status == "failed" ? "Couldn't cut it out" : isCrop ? "Is this a piece to add?" : "Cutout ready").eyebrow()
                Text(job.metadata.name).font(.display(22))
            }

            let busy = store.reviewing.contains(job.id)
            if stage.status == "failed" {
                Text(stage.error ?? "That didn't work.").font(.footnote).foregroundStyle(Theme.muted).lineLimit(3)
                HStack(spacing: 10) {
                    Button("Try again") { Task { await store.review(job, "regenerate") } }.buttonStyle(PrimaryButtonStyle())
                    Button("Discard") { Task { await store.review(job, "reject") } }.buttonStyle(QuietButtonStyle())
                }
                .disabled(busy)
            } else {
                if let warnings = stage.warnings, !warnings.isEmpty {
                    ReviewerNote(warnings: warnings)
                }
                HStack(spacing: 10) {
                    Button(isCrop ? "Add it" : "Keep") { Task { await store.review(job, "approve") } }.buttonStyle(PrimaryButtonStyle())
                    if !isCrop {
                        Button("Redo", systemImage: "arrow.clockwise") { Task { await store.review(job, "regenerate") } }
                            .labelStyle(.iconOnly).buttonStyle(QuietButtonStyle())
                    }
                    Button(isCrop ? "Skip" : "Discard", systemImage: "xmark") { Task { await store.review(job, "reject") } }
                        .labelStyle(.iconOnly).buttonStyle(QuietButtonStyle())
                }
                // One decision at a time per piece; the next tap waits for the Mac's answer.
                .disabled(busy)
                .opacity(busy ? 0.5 : 1)
            }
        }
        .padding(18)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
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
