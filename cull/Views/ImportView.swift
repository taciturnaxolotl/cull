import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @Environment(CullSession.self) private var session
    @Environment(ThumbnailCache.self) private var cache
    @State private var isDragging = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text("Open a folder of photos to start culling")
                .font(.title2)
                .foregroundStyle(.secondary)

            Button("Choose Folder") {
                openFolder()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("or drag a folder here")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isDragging ? Color.accentColor : Color.clear, lineWidth: 3)
                .padding(20)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.hasDirectoryPath else { return }
                Task { @MainActor in
                    startImport(url)
                }
            }
            return true
        }
    }

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder containing photos"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        startImport(url)
    }

    @MainActor
    private func startImport(_ url: URL) {
        session.sourceFolder = url
        session.isImporting = true
        session.importProgress = 0.02 // small initial bump so bar is visible

        let s = session
        let c = cache

        Task {
            do {
                let result = try await PhotoImporter.importFolder(url)

                // Feature print grouping — run off main actor
                var lastReported = 0.0
                let groups = await ShotGrouper.group(photos: result.photos) { p in
                    let mapped = p * 0.95
                    guard mapped - lastReported > 0.02 else { return }
                    lastReported = mapped
                    await MainActor.run {
                        withAnimation(.linear(duration: 0.3)) {
                            s.importProgress = mapped
                        }
                    }
                }

                // Phase 2: Load thumbnails into memory (95-98%)
                let allPhotos = groups.flatMap(\.photos)
                var lastCacheReported = 0.95
                await c.preloadAllThumbnails(photos: allPhotos) { p in
                    let mapped = 0.95 + p * 0.03
                    guard mapped - lastCacheReported > 0.005 else { return }
                    lastCacheReported = mapped
                    await MainActor.run {
                        withAnimation(.linear(duration: 0.2)) {
                            s.importProgress = mapped
                        }
                    }
                }

                // Phase 3: Preload initial full-res previews (98-100%)
                let ahead = Array(allPhotos.prefix(30))
                let behind = Array(allPhotos.suffix(30))
                let initialPreviews = ahead + behind.reversed()
                var lastPreviewReported = 0.98
                await c.preloadAllPreviews(photos: initialPreviews) { p in
                    let mapped = 0.98 + p * 0.02
                    guard mapped - lastPreviewReported > 0.005 else { return }
                    lastPreviewReported = mapped
                    await MainActor.run {
                        withAnimation(.linear(duration: 0.2)) {
                            s.importProgress = mapped
                        }
                    }
                }

                await MainActor.run {
                    s.importProgress = 1.0
                    s.groups = groups
                    s.selectedGroupIndex = 0
                    s.selectedPhotoIndex = 0
                    s.isImporting = false
                }

                // Quality analysis in background — batched to avoid overwhelming GPU
                let analysisWork: [(UUID, URL)] = allPhotos.map { ($0.id, $0.pairedURL ?? $0.url) }
                let photosByID: [UUID: Photo] = Dictionary(uniqueKeysWithValues: allPhotos.map { ($0.id, $0) })
                Task.detached(priority: .background) {
                    for batchStart in stride(from: 0, to: analysisWork.count, by: 4) {
                        let batch = Array(analysisWork[batchStart..<min(batchStart + 4, analysisWork.count)])
                        await withTaskGroup(of: (UUID, Double?, Double?).self) { group in
                            for (id, url) in batch {
                                group.addTask {
                                    let blur = await QualityAnalyzer.analyzeBlur(imageURL: url)
                                    let face = await QualityAnalyzer.analyzeFaceQuality(imageURL: url)
                                    return (id, blur, face)
                                }
                            }
                            for await (id, blur, face) in group {
                                await MainActor.run {
                                    if let photo = photosByID[id] {
                                        photo.blurScore = blur
                                        photo.faceQualityScore = face
                                    }
                                }
                            }
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    s.sourceFolder = nil
                    s.isImporting = false
                }
            }
        }
    }
}
