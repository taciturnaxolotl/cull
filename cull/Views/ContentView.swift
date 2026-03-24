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
                await MainActor.run { s.importStatus = "Scanning photos..." }
                let result = try await PhotoImporter.importFolder(url)

                await MainActor.run { s.importStatus = "Grouping similar shots..." }
                // Phase 1: Feature print grouping (0-30%)
                var lastReported = 0.0
                let groups = await ShotGrouper.group(photos: result.photos) { p in
                    let mapped = p * 0.30
                    guard mapped - lastReported > 0.01 else { return }
                    lastReported = mapped
                    await MainActor.run {
                        withAnimation(.linear(duration: 0.3)) {
                            s.importProgress = mapped
                        }
                    }
                }

                await MainActor.run { s.importStatus = "Generating thumbnails..." }
                // Phase 2: Thumbnails (30-60%)
                let allPhotos = groups.flatMap(\.photos)
                await c.preloadAllThumbnails(photos: allPhotos) { p in
                    let mapped = 0.30 + p * 0.30
                    await MainActor.run {
                        withAnimation(.linear(duration: 0.2)) {
                            s.importProgress = mapped
                        }
                    }
                }

                await MainActor.run { s.importStatus = "Loading previews..." }
                // Phase 3: Initial full-res previews (60-100%)
                let ahead = Array(allPhotos.prefix(30))
                let behind = Array(allPhotos.suffix(30))
                let initialPreviews = ahead + behind.reversed()
                await c.preloadAllPreviews(photos: initialPreviews) { p in
                    let mapped = 0.60 + p * 0.40
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
