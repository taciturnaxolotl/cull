import SwiftUI

struct PhotoViewer: View {
    @Environment(CullSession.self) private var session
    @Environment(ThumbnailCache.self) private var cache
    @State private var displayImage: NSImage?
    @State private var displayedPhotoID: UUID?

    private let lookaheadCount = 30
    private let lookbehindCount = 30

    var body: some View {
        ZStack {
            Color.black

            if let displayImage {
                Image(nsImage: displayImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

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
}
