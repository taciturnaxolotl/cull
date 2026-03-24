import SwiftUI

struct PhotoViewer: View {
    @Environment(CullSession.self) private var session
    @Environment(ThumbnailCache.self) private var cache
    @State private var displayImage: NSImage?
    @State private var displayedPhotoID: UUID?
    /// Tracks what quality level is currently displayed: "preview", "thumbnail", or "none"
    @State private var displayQuality: String = "none"

    private let lookaheadCount = 30
    private let lookbehindCount = 30


    var body: some View {
        ZStack {
            Color.black

            if let displayImage {
                GeometryReader { geo in
                    let imageSize = displayImage.size
                    let fitted = fittedSize(image: imageSize, in: geo.size)
                    let zoomInfo = currentZoomInfo(fittedSize: fitted, containerSize: geo.size)

                    ZStack {
                        Image(nsImage: displayImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .overlay {
                                // Face region overlays (only when not zoomed)
                                if session.zoomFaceIndex == nil, let photo = session.selectedPhoto, !photo.faceRegions.isEmpty {
                                    faceOverlays(photo: photo, fittedSize: fitted)
                                }
                            }
                    }
                    .frame(width: fitted.width, height: fitted.height)
                    .scaleEffect(zoomInfo.scale)
                    .offset(zoomInfo.offset)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .animation(.easeInOut(duration: 0.3), value: session.zoomFaceIndex)
                }
            }

            // Debug cache overlay
            if session.debugCacheOverlay, let photo = session.selectedPhoto {
                let _ = cache.cacheGeneration // observe changes
                let s = cache.stats()
                let allPhotos = session.allPhotos
                let currentFlatIndex = allPhotos.firstIndex(where: { $0.id == photo.id })

                HStack(alignment: .top, spacing: 0) {
                    Spacer()

                    // Stats panel
                    VStack(alignment: .leading, spacing: 3) {
                        let hasPreview = cache.cachedPreview(for: photo) != nil
                        let hasThumb = cache.cachedThumbnail(for: photo) != nil

                        Text("Current Photo")
                            .fontWeight(.semibold)
                        HStack(spacing: 4) {
                            Circle().fill(hasPreview ? .green : .red).frame(width: 8, height: 8)
                            Text("Preview")
                        }
                        HStack(spacing: 4) {
                            Circle().fill(hasThumb ? .green : .red).frame(width: 8, height: 8)
                            Text("Thumbnail")
                        }
                        Text("Displaying: \(displayQuality)")

                        Divider().overlay(Color.white.opacity(0.3))

                        Text("Cache")
                            .fontWeight(.semibold)
                        Text("Thumbs: \(s.thumbnailCount)/\(s.thumbnailLimit)")
                        Text("Previews: \(s.previewCount)/\(s.previewLimit)")

                        Divider().overlay(Color.white.opacity(0.3))

                        Text("Session")
                            .fontWeight(.semibold)
                        Text("Groups: \(session.groups.count)")
                        Text("Photos: \(allPhotos.count)")
                    }
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))

                    // Cache minimap — precompute states so SwiftUI can diff
                    let cacheStates: [Int] = allPhotos.map { p in
                        if cache.cachedPreview(for: p) != nil { return 2 }
                        if cache.cachedThumbnail(for: p) != nil { return 1 }
                        return 0
                    }

                    GeometryReader { geo in
                        let totalPhotos = cacheStates.count
                        let height = geo.size.height - 16
                        let rowH = totalPhotos > 0 ? max(height / CGFloat(totalPhotos), 1) : 1

                        Canvas { context, size in
                            let colors: [Color] = [.red, .yellow, .green]
                            for (i, state) in cacheStates.enumerated() {
                                let y = 8 + CGFloat(i) * rowH
                                context.fill(
                                    Path(CGRect(x: 0, y: y, width: size.width, height: max(rowH - 0.5, 0.5))),
                                    with: .color(colors[state].opacity(0.8))
                                )
                            }

                            if let idx = currentFlatIndex {
                                let y = 8 + CGFloat(idx) * rowH
                                context.fill(
                                    Path(CGRect(x: -2, y: y - 1, width: size.width + 4, height: max(rowH + 2, 3))),
                                    with: .color(.white)
                                )
                            }
                        }
                        .frame(width: 14)
                    }
                    .frame(width: 14)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 3))
                }
                .padding(8)
            }

            // Bottom bar overlay
            if let photo = session.selectedPhoto {
                VStack {
                    Spacer()
                    HStack(spacing: 12) {
                        if photo.flag == .pick {
                            Label("Pick", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else if photo.flag == .reject {
                            Label("Reject", systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                        }

                        // Resolution & file size
                        if photo.pixelWidth > 0 {
                            HStack(spacing: 8) {
                                // Primary file (RAW or standalone)
                                HStack(spacing: 4) {
                                    Text(photo.url.pathExtension.uppercased())
                                        .fontWeight(.medium)
                                    Text("\(photo.pixelWidth)×\(photo.pixelHeight)")
                                    Text(Self.formatFileSize(photo.fileSize))
                                }
                                // Paired file (JPEG sidecar)
                                if photo.pairedURL != nil, photo.pairedPixelWidth > 0 {
                                    Text("·")
                                    HStack(spacing: 4) {
                                        Text(photo.pairedURL!.pathExtension.uppercased())
                                            .fontWeight(.medium)
                                        Text("\(photo.pairedPixelWidth)×\(photo.pairedPixelHeight)")
                                        Text(Self.formatFileSize(photo.pairedFileSize))
                                    }
                                }
                            }
                            .foregroundStyle(.white.opacity(0.5))
                            .font(.caption)
                        }

                        Spacer()

                        // Quality scores
                        HStack(spacing: 10) {
                            if let blur = photo.blurScore {
                                HStack(spacing: 3) {
                                    Image(systemName: "scope")
                                    Text(String(format: "%.0f", blur))
                                }
                                .foregroundStyle(isPhotoBlurry(photo) ? .orange : .white.opacity(0.6))
                            }

                            if let fs = photo.faceSharpness {
                                HStack(spacing: 3) {
                                    Image(systemName: "face.smiling")
                                    Text(String(format: "%.0f", fs))
                                }
                                .foregroundStyle(.white.opacity(0.7))
                            }

                            if !photo.faceRegions.isEmpty {
                                HStack(spacing: 3) {
                                    Image(systemName: "person.crop.rectangle")
                                    Text("\(photo.faceRegions.count)")
                                }
                                .foregroundStyle(.white.opacity(0.6))
                            }

                            // Group rank
                            if let group = session.selectedGroup {
                                let rank = groupRank(photo: photo, in: group)
                                if let rank {
                                    HStack(spacing: 3) {
                                        Image(systemName: "number")
                                        Text("\(rank)/\(group.photos.count)")
                                    }
                                    .foregroundStyle(rank == 1 ? .green : .white.opacity(0.6))
                                }
                            }
                        }
                        .font(.caption)

                        // Eyes closed badge
                        if photo.eyeAspectRatios.contains(where: { $0 < 0.20 }) {
                            let closedCount = photo.eyeAspectRatios.filter { $0 < 0.20 }.count
                            HStack(spacing: 3) {
                                Image(systemName: "eye.slash")
                                Text("\(closedCount)")
                            }
                            .foregroundStyle(.yellow)
                            .font(.caption)
                        }

                        // Blur badge
                        if isPhotoBlurry(photo) {
                            Label("Blurry", systemImage: "eye.slash.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                        }

                        HStack(spacing: 2) {
                            ForEach(1...5, id: \.self) { star in
                                Image(systemName: star <= photo.rating ? "star.fill" : "star")
                                    .foregroundStyle(star <= photo.rating ? .yellow : .white.opacity(0.3))
                            }
                        }
                        .font(.title3)

                        Spacer()

                        HStack(spacing: 6) {
                            Text(photo.url.lastPathComponent)
                            if let date = photo.captureDate {
                                Text(date, format: .dateTime.month().day().year().hour().minute().second())
                            }
                        }
                        .foregroundStyle(.white.opacity(0.6))
                        .font(.caption)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                }
            }
        }
        .onChange(of: session.selectedPhoto?.id) {
            guard let photo = session.selectedPhoto else {
                displayImage = nil
                displayedPhotoID = nil
                return
            }
            displayedPhotoID = photo.id
            // Instant: show whatever we have cached synchronously
            if let cached = cache.cachedPreview(for: photo) {
                displayImage = cached
                displayQuality = "preview"
            } else if let thumb = cache.cachedThumbnail(for: photo) {
                displayImage = thumb
                displayQuality = "thumbnail"
            } else {
                displayQuality = "none"
            }
        }
        .task(id: session.selectedPhoto?.id) {
            guard let photo = session.selectedPhoto else { return }
            let photoID = photo.id

            // If full-res is already cached, show it immediately
            if let cached = cache.cachedPreview(for: photo) {
                displayImage = cached
                displayQuality = "preview"
            }

            // Wait for user to stop navigating before doing any loading
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, displayedPhotoID == photoID else { return }

            // Load current photo's full-res preview
            if cache.cachedPreview(for: photo) == nil {
                if let full = await cache.previewImage(for: photo) {
                    guard displayedPhotoID == photoID else { return }
                    displayImage = full
                    displayQuality = "preview"
                }
            }

            // Preload window fanning out from current position (closest first)
            guard !Task.isCancelled, displayedPhotoID == photoID else { return }
            let ahead = session.photosAhead(lookaheadCount)
            let behind = session.photosBehind(lookbehindCount)
            var fanOut: [Photo] = []
            let maxLen = max(ahead.count, behind.count)
            for i in 0..<maxLen {
                if i < ahead.count { fanOut.append(ahead[i]) }
                if i < behind.count { fanOut.append(behind[i]) }
            }
            let window = [photo] + fanOut
            cache.preloadPreviews(photos: window)
            cache.evictPreviews(keeping: window)
        }
        .onAppear {
            if let photo = session.selectedPhoto {
                displayedPhotoID = photo.id
                if let cached = cache.cachedPreview(for: photo) {
                    displayImage = cached
                    displayQuality = "preview"
                } else if let thumb = cache.cachedThumbnail(for: photo) {
                    displayImage = thumb
                    displayQuality = "thumbnail"
                }
                // Preload initial window
                let ahead = session.photosAhead(lookaheadCount)
                let behind = session.photosBehind(lookbehindCount)
                cache.preloadPreviews(photos: behind + [photo] + ahead)
            }
        }
    }

    // MARK: - Group ranking

    /// Ranks photo within its group by quality. Returns 1-based rank, or nil if no scores yet.
    private func groupRank(photo: Photo, in group: PhotoGroup) -> Int? {
        let scored = group.photos.filter { $0.blurScore != nil || $0.faceSharpness != nil }
        guard scored.count >= 2 else { return nil }

        let ranked = scored.sorted { qualityScore($0, in: group) > qualityScore($1, in: group) }
        guard let idx = ranked.firstIndex(where: { $0.id == photo.id }) else { return nil }
        return idx + 1
    }

    private func qualityScore(_ photo: Photo, in group: PhotoGroup) -> Double {
        ContentView.qualityScore(photo, in: group)
    }

    // MARK: - Blur detection (relative within group)

    /// Relative blur detection — blurry only if significantly softer than group peers.
    /// For faces: compares face sharpness. Without faces: compares global blur.
    private func isPhotoBlurry(_ photo: Photo) -> Bool {
        guard let group = session.selectedGroup else { return false }

        if !photo.faceRegions.isEmpty {
            guard let fs = photo.faceSharpness else { return false }
            let peerScores = group.photos.compactMap(\.faceSharpness)
            guard peerScores.count >= 2 else { return false }
            let median = peerScores.sorted()[peerScores.count / 2]
            return fs < median * 0.4
        }

        guard let blur = photo.blurScore else { return false }
        let peerScores = group.photos.compactMap(\.blurScore)
        guard peerScores.count >= 2 else { return false }
        let median = peerScores.sorted()[peerScores.count / 2]
        return blur < median * 0.4
    }

    // MARK: - Formatting

    private static func formatFileSize(_ bytes: Int64) -> String {
        if bytes >= 1_073_741_824 {
            return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
        } else if bytes >= 1_048_576 {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576)
        } else if bytes >= 1024 {
            return String(format: "%.0f KB", Double(bytes) / 1024)
        }
        return "\(bytes) B"
    }

    // MARK: - Zoom calculations

    private struct ZoomInfo {
        let scale: CGFloat
        let offset: CGSize
    }

    private func currentZoomInfo(fittedSize: CGSize, containerSize: CGSize) -> ZoomInfo {
        guard let zoomIndex = session.zoomFaceIndex,
              let photo = session.selectedPhoto else {
            return ZoomInfo(scale: 1, offset: .zero)
        }

        if zoomIndex == -1 {
            // Center zoom — 2.5x
            return ZoomInfo(scale: 2.5, offset: .zero)
        }

        // Zoomed to a face — adapt to current photo's faces
        guard !photo.faceRegions.isEmpty else {
            // No faces on this photo — fall back to center zoom
            return ZoomInfo(scale: 2.5, offset: .zero)
        }

        // Clamp to available faces
        let clampedIndex = min(zoomIndex, photo.faceRegions.count - 1)
        let faceRect = photo.faceRegions[clampedIndex]
        // Vision coordinates: origin bottom-left, normalized 0-1
        // Calculate scale so the face takes up ~35% of the view width
        let faceW = faceRect.width
        let faceH = faceRect.height
        let scale = min(max(0.35 / max(faceW, faceH), 1.5), 5.0)

        // Face center in normalized image coords (flip Y)
        let faceCenterX = faceRect.midX
        let faceCenterY = 1 - faceRect.midY

        // Face center in fitted image pixel coords
        let facePixelX = faceCenterX * fittedSize.width
        let facePixelY = faceCenterY * fittedSize.height

        // Image center in fitted coords
        let imageCenterX = fittedSize.width / 2
        let imageCenterY = fittedSize.height / 2

        // Offset to move face center to view center, then multiply by scale
        let offsetX = (imageCenterX - facePixelX) * scale
        let offsetY = (imageCenterY - facePixelY) * scale

        return ZoomInfo(scale: scale, offset: CGSize(width: offsetX, height: offsetY))
    }

    // MARK: - Eye indicator

    /// Draws two small eye shapes that reflect how open/closed the eyes are.
    /// EAR ~0.30 = wide open, ~0.20 = threshold, ~0.05 = shut.
    private struct EyeIndicator: View {
        let ear: Double
        let faceWidth: CGFloat

        var body: some View {
            let eyeW = min(faceWidth * 0.22, 20)
            // Map EAR to openness: 0.05→flat, 0.30→full open
            let openness = CGFloat(max(0, min(1, (ear - 0.05) / 0.25)))
            let eyeH = eyeW * 0.8 * openness
            let color: Color = ear < 0.20 ? .yellow : .white.opacity(0.7)

            EyeShape(openness: openness)
                .fill(color.opacity(0.9))
                .frame(width: eyeW, height: max(eyeH, 1.5))
                .shadow(color: .black.opacity(0.8), radius: 1.5)
        }
    }

    /// Almond-shaped eye that flattens as openness approaches 0.
    private struct EyeShape: Shape {
        let openness: CGFloat

        func path(in rect: CGRect) -> Path {
            var path = Path()
            let midY = rect.midY
            let bulge = rect.height / 2
            let cpInset = rect.width * 0.2

            // Top lid arc (cubic for rounder shape)
            path.move(to: CGPoint(x: rect.minX, y: midY))
            path.addCurve(
                to: CGPoint(x: rect.maxX, y: midY),
                control1: CGPoint(x: rect.minX + cpInset, y: midY - bulge),
                control2: CGPoint(x: rect.maxX - cpInset, y: midY - bulge)
            )
            // Bottom lid arc
            path.addCurve(
                to: CGPoint(x: rect.minX, y: midY),
                control1: CGPoint(x: rect.maxX - cpInset, y: midY + bulge),
                control2: CGPoint(x: rect.minX + cpInset, y: midY + bulge)
            )
            return path
        }
    }

    private func fittedSize(image: CGSize, in container: CGSize) -> CGSize {
        let scaleW = container.width / image.width
        let scaleH = container.height / image.height
        let s = min(scaleW, scaleH)
        return CGSize(width: image.width * s, height: image.height * s)
    }

    // MARK: - Face overlays

    @ViewBuilder
    private func faceOverlays(photo: Photo, fittedSize: CGSize) -> some View {
        ForEach(0..<photo.faceRegions.count, id: \.self) { i in
            let faceRect = photo.faceRegions[i]
            let ear = i < photo.eyeAspectRatios.count ? photo.eyeAspectRatios[i] : 0.3
            let isClosed = ear < 0.20
            // Convert Vision rect (bottom-left origin) to SwiftUI overlay coords (top-left origin)
            let x = faceRect.origin.x * fittedSize.width
            let y = (1 - faceRect.origin.y - faceRect.height) * fittedSize.height
            let w = faceRect.width * fittedSize.width
            let h = faceRect.height * fittedSize.height

            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(isClosed ? Color.yellow.opacity(0.8) : Color.white.opacity(0.5), lineWidth: 1.5)
                    .frame(width: w, height: h)

                // Eye openness indicator just under the chin
                EyeIndicator(ear: ear, faceWidth: w)
                    .offset(y: h * 0.55)
            }
            .position(x: x + w / 2, y: y + h / 2)
        }
    }
}
