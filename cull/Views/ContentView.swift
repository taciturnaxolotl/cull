import SwiftUI

struct ContentView: View {
    @Environment(CullSession.self) private var session
    @Environment(ThumbnailCache.self) private var cache
    @Environment(\.undoManager) private var windowUndoManager
    @State private var showExportSheet = false
    @FocusState private var isViewerFocused: Bool

    var body: some View {
        Group {
            if session.sourceFolder == nil {
                ImportView()
            } else if session.isImporting {
                ImportProgressView(status: session.importStatus, progress: session.importProgress)
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
        .onReceive(NotificationCenter.default.publisher(for: .reimport)) { _ in
            guard let folder = session.sourceFolder else { return }
            startReanalyze(folder)
        }
        .onAppear {
            session.undoManager = windowUndoManager
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
                // Try loading from workspace first
                if let wsResult = s.openWorkspace(folder: url) {
                    let allPhotos = s.allPhotos
                    let newPhotos = wsResult.newPhotos

                    if !newPhotos.isEmpty {
                        await MainActor.run { s.importStatus = "Analyzing \(newPhotos.count) new photos..." }
                        // Read metadata for new photos
                        let formatter = DateFormatter()
                        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
                        formatter.locale = Locale(identifier: "en_US_POSIX")
                        let metaInputs: [(Int, URL, URL?)] = newPhotos.enumerated().map { (i, p) in
                            (i, p.url, p.pairedURL)
                        }
                        let results = await withTaskGroup(of: (Int, PhotoImporter.PhotoMetadata).self, returning: [(Int, PhotoImporter.PhotoMetadata)].self) { group in
                            for (index, photoURL, pairedURL) in metaInputs {
                                group.addTask {
                                    let meta = PhotoImporter.readAllMetadata(url: photoURL, pairedURL: pairedURL, formatter: formatter)
                                    return (index, meta)
                                }
                            }
                            var collected: [(Int, PhotoImporter.PhotoMetadata)] = []
                            for await result in group { collected.append(result) }
                            return collected
                        }
                        for (index, meta) in results {
                            let photo = newPhotos[index]
                            photo.captureDate = meta.captureDate
                            photo.pixelWidth = meta.pixelWidth
                            photo.pixelHeight = meta.pixelHeight
                            photo.fileSize = meta.fileSize
                            photo.pairedPixelWidth = meta.pairedPixelWidth
                            photo.pairedPixelHeight = meta.pairedPixelHeight
                            photo.pairedFileSize = meta.pairedFileSize
                        }

                        // Analyze new photos
                        for photo in newPhotos {
                            await QualityAnalyzer.analyze(photo: photo)
                        }
                    }

                    // Load thumbnails and previews
                    await MainActor.run { s.importStatus = "Loading thumbnails..." }
                    await c.preloadAllThumbnails(photos: allPhotos) { p in
                        await MainActor.run {
                            withAnimation(.linear(duration: 0.2)) {
                                s.importProgress = p * 0.7
                            }
                        }
                    }

                    await MainActor.run { s.importStatus = "Loading previews..." }
                    let ahead = Array(allPhotos.prefix(30))
                    let behind = Array(allPhotos.suffix(30))
                    let initialPreviews = ahead + behind.reversed()
                    await c.preloadAllPreviews(photos: initialPreviews) { p in
                        await MainActor.run {
                            withAnimation(.linear(duration: 0.2)) {
                                s.importProgress = 0.7 + p * 0.3
                            }
                        }
                    }

                    await MainActor.run {
                        s.importProgress = 1.0
                        s.isImporting = false
                        if !newPhotos.isEmpty {
                            s.saveWorkspace()
                        }
                    }
                    return
                }

                // No workspace — full import
                _ = WorkspaceDB(folder: url).map { s.workspace = $0 }

                await MainActor.run { s.importStatus = "Scanning photos..." }
                let result = try await PhotoImporter.importFolder(url, recursive: s.importRecursive)

                // Phase 1: Feature print grouping (0-20%)
                await MainActor.run { s.importStatus = "Grouping similar shots..." }
                var lastReported = 0.0
                let groups = await ShotGrouper.group(photos: result.photos) { p in
                    let mapped = p * 0.20
                    guard mapped - lastReported > 0.01 else { return }
                    lastReported = mapped
                    await MainActor.run {
                        withAnimation(.linear(duration: 0.3)) {
                            s.importProgress = mapped
                        }
                    }
                }

                // Phase 2: Analysis + Thumbnails + Previews in parallel (20-100%)
                let allPhotos = groups.flatMap(\.photos)
                await MainActor.run { s.importStatus = "Analyzing & loading..." }

                // Track progress from three parallel streams
                let totalPhotos = Double(allPhotos.count)
                // Each stream contributes a fraction: analysis 40%, thumbnails 35%, previews 25%
                nonisolated(unsafe) var analysisProgress = 0.0
                nonisolated(unsafe) var thumbProgress = 0.0
                nonisolated(unsafe) var previewProgress = 0.0

                @Sendable func reportProgress() async {
                    let combined = 0.20 + (analysisProgress * 0.40 + thumbProgress * 0.35 + previewProgress * 0.25) * 0.80
                    await MainActor.run {
                        withAnimation(.linear(duration: 0.2)) {
                            s.importProgress = combined
                        }
                    }
                }

                await withTaskGroup(of: Void.self) { parallelGroup in
                    // Stream 1: Quality analysis (blur + faces) — low priority to not starve preview/thumbnail loading
                    parallelGroup.addTask {
                        var completed = 0.0
                        for batchStart in stride(from: 0, to: allPhotos.count, by: 8) {
                            let batch = Array(allPhotos[batchStart..<min(batchStart + 8, allPhotos.count)])
                            await withTaskGroup(of: Void.self) { group in
                                for photo in batch {
                                    group.addTask(priority: .background) {
                                        await QualityAnalyzer.analyze(photo: photo)
                                    }
                                }
                            }
                            completed += Double(batch.count)
                            analysisProgress = completed / totalPhotos
                            await reportProgress()
                        }
                    }

                    // Stream 2: Thumbnails — high priority
                    parallelGroup.addTask {
                        await c.preloadAllThumbnails(photos: allPhotos) { p in
                            thumbProgress = p
                            await reportProgress()
                        }
                    }

                    // Stream 3: Initial full-res previews — high priority
                    parallelGroup.addTask {
                        let ahead = Array(allPhotos.prefix(30))
                        let behind = Array(allPhotos.suffix(30))
                        let initialPreviews = ahead + behind.reversed()
                        await c.preloadAllPreviews(photos: initialPreviews) { p in
                            previewProgress = p
                            await reportProgress()
                        }
                    }
                }

                // Rank photos within each group — best first (after analysis completes)
                for group in groups {
                    let scored = group.photos.map { (photo: $0, score: Self.qualityScore($0, in: group)) }
                    group.photos = scored.sorted { $0.score > $1.score }.map(\.photo)
                }

                await MainActor.run {
                    s.importProgress = 1.0
                    s.groups = groups
                    s.selectedGroupIndex = 0
                    s.selectedPhotoIndex = 0
                    s.isImporting = false
                    s.saveWorkspace()
                }
            } catch {
                await MainActor.run {
                    s.sourceFolder = nil
                    s.isImporting = false
                }
            }
        }
    }

    @MainActor
    private func startReanalyze(_ url: URL) {
        session.isImporting = true
        session.importProgress = 0.02
        cache.clearCache()

        // Snapshot existing ratings/flags keyed by relative path
        let existingState: [String: (rating: Int, flag: PhotoFlag)] = {
            var map: [String: (Int, PhotoFlag)] = [:]
            for photo in session.allPhotos {
                let rel = photo.url.relativePath(from: url)
                map[rel] = (photo.rating, photo.flag)
            }
            return map
        }()

        let s = session
        let c = cache

        Task {
            do {
                // Phase 1: Full re-scan and metadata read
                await MainActor.run { s.importStatus = "Scanning photos..." }
                let result = try await PhotoImporter.importFolder(url, recursive: s.importRecursive)

                // Restore ratings/flags from previous state
                for photo in result.photos {
                    let rel = photo.url.relativePath(from: url)
                    if let saved = existingState[rel] {
                        photo.rating = saved.rating
                        photo.flag = saved.flag
                    }
                }

                // Phase 2: Re-group (0-20%)
                await MainActor.run { s.importStatus = "Grouping similar shots..." }
                var lastReported = 0.0
                let groups = await ShotGrouper.group(photos: result.photos) { p in
                    let mapped = p * 0.20
                    guard mapped - lastReported > 0.01 else { return }
                    lastReported = mapped
                    await MainActor.run {
                        withAnimation(.linear(duration: 0.3)) {
                            s.importProgress = mapped
                        }
                    }
                }

                // Phase 3: Analysis + Thumbnails + Previews in parallel (20-100%)
                let allPhotos = groups.flatMap(\.photos)
                await MainActor.run { s.importStatus = "Analyzing & loading..." }

                let totalPhotos = Double(allPhotos.count)
                nonisolated(unsafe) var analysisProgress = 0.0
                nonisolated(unsafe) var thumbProgress = 0.0
                nonisolated(unsafe) var previewProgress = 0.0

                @Sendable func reportProgress() async {
                    let combined = 0.20 + (analysisProgress * 0.40 + thumbProgress * 0.35 + previewProgress * 0.25) * 0.80
                    await MainActor.run {
                        withAnimation(.linear(duration: 0.2)) {
                            s.importProgress = combined
                        }
                    }
                }

                await withTaskGroup(of: Void.self) { parallelGroup in
                    parallelGroup.addTask {
                        var completed = 0.0
                        for batchStart in stride(from: 0, to: allPhotos.count, by: 8) {
                            let batch = Array(allPhotos[batchStart..<min(batchStart + 8, allPhotos.count)])
                            await withTaskGroup(of: Void.self) { group in
                                for photo in batch {
                                    group.addTask(priority: .background) {
                                        await QualityAnalyzer.analyze(photo: photo)
                                    }
                                }
                            }
                            completed += Double(batch.count)
                            analysisProgress = completed / totalPhotos
                            await reportProgress()
                        }
                    }

                    parallelGroup.addTask {
                        await c.preloadAllThumbnails(photos: allPhotos) { p in
                            thumbProgress = p
                            await reportProgress()
                        }
                    }

                    parallelGroup.addTask {
                        let ahead = Array(allPhotos.prefix(30))
                        let behind = Array(allPhotos.suffix(30))
                        let initialPreviews = ahead + behind.reversed()
                        await c.preloadAllPreviews(photos: initialPreviews) { p in
                            previewProgress = p
                            await reportProgress()
                        }
                    }
                }

                // Rank photos within each group
                for group in groups {
                    let scored = group.photos.map { (photo: $0, score: Self.qualityScore($0, in: group)) }
                    group.photos = scored.sorted { $0.score > $1.score }.map(\.photo)
                }

                await MainActor.run {
                    s.importProgress = 1.0
                    s.groups = groups
                    s.selectedGroupIndex = 0
                    s.selectedPhotoIndex = 0
                    s.isImporting = false
                    s.saveWorkspace()
                }
            } catch {
                await MainActor.run {
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
        .onKeyPress(.space) { session.cycleZoom(); return .handled }
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
                    ToolbarFilterButton(
                        activeIcon: "checkmark.circle.fill",
                        inactiveIcon: "checkmark.circle",
                        isActive: session.selectedPhoto?.flag == .pick,
                        isFiltered: session.hidePicks,
                        activeColor: .green,
                        action: { session.togglePick() },
                        filterAction: { session.togglePickFilter() },
                        help: "Pick (P) · ⌘Click to filter"
                    )

                    ToolbarFilterButton(
                        activeIcon: "xmark.circle.fill",
                        inactiveIcon: "xmark.circle",
                        isActive: session.selectedPhoto?.flag == .reject,
                        isFiltered: session.hideRejects,
                        activeColor: .red,
                        action: { session.toggleReject() },
                        filterAction: { session.toggleRejectFilter() },
                        help: "Reject (X) · ⌘Click to filter"
                    )
                }
            }

            ToolbarItem(placement: .automatic) {
                HStack(spacing: 2) {
                    ToolbarFilterButton(
                        activeIcon: "circle.slash",
                        inactiveIcon: "circle.slash",
                        isActive: session.selectedPhoto?.rating == 0,
                        isFiltered: session.hideUnrated,
                        activeColor: .secondary,
                        action: { session.clearRatingAndFlag() },
                        filterAction: { session.toggleUnratedFilter() },
                        help: "Unrated (0) · ⌘Click to filter"
                    )

                    ForEach(1...5, id: \.self) { star in
                        let isActive = star <= (session.selectedPhoto?.rating ?? 0)
                        let isFiltered = session.hiddenRatings.contains(star)
                        ToolbarFilterButton(
                            activeIcon: "star.fill",
                            inactiveIcon: "star",
                            isActive: isActive,
                            isFiltered: isFiltered,
                            activeColor: .yellow,
                            action: { session.setRating(star) },
                            filterAction: { session.toggleRatingFilter(star) },
                            help: "Rate \(star) · ⌘Click to filter"
                        )
                    }
                }
            }

            ToolbarItem(placement: .automatic) {
                Spacer()
            }

            ToolbarItem(placement: .automatic) {
                Button { showExportSheet = true } label: {
                    Image(systemName: "square.and.arrow.up.on.square")
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

extension ContentView {
    /// Quality score for ranking within a group. Higher = better.
    /// With faces: face sharpness (Laplacian on face crop) is the score.
    /// Without faces: global blur score relative to group peers.
    static func qualityScore(_ photo: Photo, in group: PhotoGroup) -> Double {
        let peers = group.photos
        var score: Double

        if let faceSharp = photo.faceSharpness, !photo.faceRegions.isEmpty {
            // Face detected — use face-region sharpness (Laplacian on face crop).
            // Normalize relative to peers who also have faces.
            let peerFaceScores = peers.compactMap(\.faceSharpness)
            if let maxF = peerFaceScores.max(), let minF = peerFaceScores.min(), maxF > minF {
                score = (faceSharp - minF) / (maxF - minF)
            } else {
                score = 0.5
            }
        } else {
            // No faces — use global blur score
            score = normalizedBlur(photo, peers: peers)
        }

        // Penalize photos with closed eyes
        if photo.eyeAspectRatios.contains(where: { $0 < 0.20 }) {
            score *= 0.3
        }

        return score
    }

    /// Normalize blur score relative to group peers (0-1 range)
    private static func normalizedBlur(_ photo: Photo, peers: [Photo]) -> Double {
        guard let blur = photo.blurScore else { return 0.5 }
        let peerBlurs = peers.compactMap(\.blurScore)
        guard let maxB = peerBlurs.max(), let minB = peerBlurs.min(), maxB > minB else { return 0.5 }
        return (blur - minB) / (maxB - minB)
    }

}

struct ToolbarFilterButton: View {
    let activeIcon: String
    let inactiveIcon: String
    let isActive: Bool
    let isFiltered: Bool
    let activeColor: Color
    let action: () -> Void
    let filterAction: () -> Void
    let help: String

    init(activeIcon: String, inactiveIcon: String, isActive: Bool, isFiltered: Bool, activeColor: Color, action: @escaping () -> Void, filterAction: @escaping () -> Void, help: String) {
        self.activeIcon = activeIcon
        self.inactiveIcon = inactiveIcon
        self.isActive = isActive
        self.isFiltered = isFiltered
        self.activeColor = activeColor
        self.action = action
        self.filterAction = filterAction
        self.help = help
    }

    var body: some View {
        Button {
            if NSEvent.modifierFlags.contains(.command) {
                filterAction()
            } else {
                action()
            }
        } label: {
            Image(systemName: isActive ? activeIcon : inactiveIcon)
                .foregroundStyle(isFiltered ? Color.gray.opacity(0.3) : (isActive ? activeColor : Color.secondary))
        }
        .help(help)
    }
}

struct ImportProgressView: View {
    let status: String
    let progress: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { timeline in
            let base = status.replacingOccurrences(of: "...", with: "")
            let dotCount = base.isEmpty ? 0 : Int(timeline.date.timeIntervalSinceReferenceDate / 0.4) % 4
            let visible = String(repeating: ".", count: dotCount)
            let invisible = String(repeating: ".", count: 3 - dotCount)

            VStack(spacing: 16) {
                HStack(spacing: 0) {
                    Text(base + visible)
                    Text(invisible).hidden()
                }
                .font(.title3)
                .foregroundStyle(.secondary)
                ProgressView(value: progress)
                    .frame(width: 300)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
