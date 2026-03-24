import SwiftUI

struct PhotoViewer: View {
    @Environment(CullSession.self) private var session
    @Environment(ThumbnailCache.self) private var cache
    @State private var displayImage: NSImage?
    @State private var displayedPhotoID: UUID?

    private let lookaheadCount = 30
    private let lookbehindCount = 30

    /// Face quality threshold — below this, faces are considered blurry
    private let faceBlurThreshold: Double = 0.35

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

                            if let fq = photo.faceQualityScore {
                                HStack(spacing: 3) {
                                    Image(systemName: "face.smiling")
                                    Text(String(format: "%.0f%%", fq * 100))
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

                        Text(photo.url.lastPathComponent)
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
            } else if let thumb = cache.cachedThumbnail(for: photo) {
                displayImage = thumb
            }
        }
        .task(id: session.selectedPhoto?.id) {
            guard let photo = session.selectedPhoto else { return }
            let photoID = photo.id

            // If full-res is already cached, show it immediately
            if let cached = cache.cachedPreview(for: photo) {
                displayImage = cached
            }

            // Wait for user to stop navigating before doing any loading
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, displayedPhotoID == photoID else { return }

            // Load current photo's full-res preview
            if cache.cachedPreview(for: photo) == nil {
                if let full = await cache.previewImage(for: photo) {
                    guard displayedPhotoID == photoID else { return }
                    displayImage = full
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
                } else if let thumb = cache.cachedThumbnail(for: photo) {
                    displayImage = thumb
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
        let scored = group.photos.filter { $0.blurScore != nil || $0.faceQualityScore != nil }
        guard scored.count >= 2 else { return nil }

        let ranked = scored.sorted { qualityScore($0, in: group) > qualityScore($1, in: group) }
        guard let idx = ranked.firstIndex(where: { $0.id == photo.id }) else { return nil }
        return idx + 1
    }

    /// Composite quality score for ranking within a group.
    /// Higher = better. Uses relative ranking within the group's score range.
    private func qualityScore(_ photo: Photo, in group: PhotoGroup) -> Double {
        var score = 0.0
        let peers = group.photos

        if let blur = photo.blurScore {
            let peerBlurs = peers.compactMap(\.blurScore)
            if let maxBlur = peerBlurs.max(), let minBlur = peerBlurs.min(), maxBlur > minBlur {
                score += ((blur - minBlur) / (maxBlur - minBlur)) * 0.5
            } else {
                score += 0.25
            }
        }

        if let fq = photo.faceQualityScore {
            score += fq * 0.5
        } else if photo.blurScore != nil {
            // No faces — blur gets full weight
            let peerBlurs = peers.compactMap(\.blurScore)
            if let maxBlur = peerBlurs.max(), let minBlur = peerBlurs.min(), maxBlur > minBlur {
                score += ((photo.blurScore! - minBlur) / (maxBlur - minBlur)) * 0.5
            } else {
                score += 0.25
            }
        }

        return score
    }

    // MARK: - Blur detection (relative within group)

    /// Uses relative ranking: a photo is blurry only if it's significantly softer
    /// than its group peers. For faces, uses face quality score directly.
    private func isPhotoBlurry(_ photo: Photo) -> Bool {
        if !photo.faceRegions.isEmpty {
            guard let fq = photo.faceQualityScore else { return false }
            return fq < faceBlurThreshold
        }

        guard let blur = photo.blurScore,
              let group = session.selectedGroup else { return false }

        // Gather blur scores from group peers that have been analyzed
        let peerScores = group.photos.compactMap(\.blurScore)
        guard peerScores.count >= 2 else { return false }

        let median = peerScores.sorted()[peerScores.count / 2]
        // Only flag if this photo is less than 40% of the group median
        return blur < median * 0.4
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

        guard photo.faceRegions.indices.contains(zoomIndex) else {
            return ZoomInfo(scale: 1, offset: .zero)
        }

        let faceRect = photo.faceRegions[zoomIndex]
        // Vision coordinates: origin bottom-left, normalized 0-1
        // Calculate scale so the face takes up ~35% of the view width
        let faceW = faceRect.width
        let faceH = faceRect.height
        let scale = min(0.35 / max(faceW, faceH), 5.0)

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
            // Convert Vision rect (bottom-left origin) to SwiftUI overlay coords (top-left origin)
            let x = faceRect.origin.x * fittedSize.width
            let y = (1 - faceRect.origin.y - faceRect.height) * fittedSize.height
            let w = faceRect.width * fittedSize.width
            let h = faceRect.height * fittedSize.height

            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(Color.white.opacity(0.5), lineWidth: 1.5)
                .frame(width: w, height: h)
                .position(x: x + w / 2, y: y + h / 2)
        }
    }
}
