import SwiftUI

struct ContentView: View {
    @Environment(CullSession.self) private var session
    @Environment(ThumbnailCache.self) private var cache
    @State private var showExportSheet = false
    @FocusState private var isViewerFocused: Bool

    var body: some View {
        Group {
            if session.sourceFolder == nil {
                ImportView()
            } else if session.isImporting {
                VStack(spacing: 16) {
                    Text("Analyzing photos...")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    ProgressView(value: session.importProgress)
                        .frame(width: 300)
                    Text("\(Int(session.importProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.groups.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No supported photos found")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Button("Choose Another Folder") { session.sourceFolder = nil }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                cullingView
            }
        }
        .frame(minWidth: 1000, minHeight: 600)
        .onReceive(NotificationCenter.default.publisher(for: .openFolder)) { notification in
            guard let url = notification.object as? URL else { return }
            startImport(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showExport)) { _ in
            showExportSheet = true
        }
    }

    @MainActor
    private func startImport(_ url: URL) {
        session.sourceFolder = url
        session.isImporting = true
        session.importProgress = 0.02
        cache.clearCache()

        let s = session
        let c = cache

        Task {
            do {
                let result = try await PhotoImporter.importFolder(url)

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

    private var cullingView: some View {
        HStack(spacing: 0) {
            // Left: Groups column
            GroupListView()
                .frame(width: 120)

            Divider()

            // Middle: Photos in selected group
            GroupDetailView()
                .frame(width: 160)

            Divider()

            // Right: Large preview
            PhotoViewer()
        }
        .focusable()
        .focused($isViewerFocused)
        .focusEffectDisabled()
        // Narrative-style: ↑/↓ = photos, ←/→ = scenes/groups
        .onKeyPress(.upArrow) { session.moveToPreviousPhoto(); return .handled }
        .onKeyPress(.downArrow) { session.moveToNextPhoto(); return .handled }
        .onKeyPress(.leftArrow) { session.moveToPreviousGroup(); return .handled }
        .onKeyPress(.rightArrow) { session.moveToNextGroup(); return .handled }
        .onKeyPress(keys: ["p"]) { _ in session.togglePick(); return .handled }
        .onKeyPress(keys: ["x"]) { _ in session.toggleReject(); return .handled }
        .onKeyPress(keys: ["0"]) { _ in session.clearRatingAndFlag(); return .handled }
        .onKeyPress(characters: .decimalDigits) { press in
            if let digit = Int(press.characters), (1...5).contains(digit) {
                session.setRating(digit)
                return .handled
            }
            return .ignored
        }
        .onKeyPress(keys: ["e"]) { _ in showExportSheet = true; return .handled }
        .onAppear { isViewerFocused = true }
        .onChange(of: session.selectedGroupIndex) { isViewerFocused = true }
        .onChange(of: session.selectedPhotoIndex) { isViewerFocused = true }
        .sheet(isPresented: $showExportSheet) {
            ExportSheet()
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 4) {
                    Button { session.togglePick() } label: {
                        Image(systemName: "checkmark.circle")
                    }
                    .help("Pick (P)")

                    Button { session.toggleReject() } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .help("Reject (X)")
                }
            }

            ToolbarItem(placement: .automatic) {
                HStack(spacing: 2) {
                    ForEach(1...5, id: \.self) { star in
                        Button { session.setRating(star) } label: {
                            Image(systemName: star <= (session.selectedPhoto?.rating ?? 0) ? "star.fill" : "star")
                                .foregroundStyle(star <= (session.selectedPhoto?.rating ?? 0) ? .yellow : .secondary)
                        }
                        .help("Rate \(star)")
                    }
                }
            }

            ToolbarItem(placement: .automatic) {
                Spacer()
            }

            ToolbarItem(placement: .automatic) {
                Button { showExportSheet = true } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("Export (E)")
            }

            ToolbarItem(placement: .automatic) {
                Button { session.sourceFolder = nil } label: {
                    Image(systemName: "folder")
                }
                .help("Open Folder")
            }
        }
    }
}
