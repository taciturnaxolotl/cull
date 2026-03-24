import SwiftUI

struct GroupDetailView: View {
    @Environment(CullSession.self) private var session
    @Environment(ThumbnailCache.self) private var cache

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let group = session.selectedGroup {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(group.photos.enumerated()), id: \.element.id) { index, photo in
                            if !session.isPhotoFiltered(photo) {
                                PhotoThumbnail(
                                    photo: photo,
                                    group: group,
                                    isSelected: index == session.selectedPhotoIndex
                                )
                                .id(photo.id)
                                .onTapGesture {
                                    session.selectPhoto(at: index)
                                }
                            }
                        }
                    }
                    .padding(4)
                }
            }
            .onChange(of: session.selectedPhotoIndex) { _, _ in
                if let photo = session.selectedPhoto {
                    withAnimation {
                        proxy.scrollTo(photo.id, anchor: .center)
                    }
                }
            }
        }
    }
}

private struct PhotoThumbnail: View {
    let photo: Photo
    let group: PhotoGroup
    let isSelected: Bool
    @Environment(ThumbnailCache.self) private var cache
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 148, height: 100)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .frame(width: 148, height: 100)
                }

                // Badges
                VStack {
                    HStack {
                        // Flag badge
                        if photo.flag != .none {
                            Image(systemName: photo.flag == .pick ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(photo.flag == .pick ? .green : .red)
                                .font(.caption)
                        }
                        Spacer()
                        // Blur badge — hybrid: trust face quality for bokeh shots
                        if isPhotoBlurry() {
                            Image(systemName: "eye.slash.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                        }
                    }
                    Spacer()
                    HStack {
                        // Best-in-group badge
                        if isBestInGroup() {
                            Image(systemName: "star.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                        Spacer()
                        // Face count badge
                        if !photo.faceRegions.isEmpty {
                            HStack(spacing: 2) {
                                Image(systemName: "face.smiling")
                                Text("\(photo.faceRegions.count)")
                            }
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.black.opacity(0.5), in: Capsule())
                        }
                    }
                }
                .padding(4)
            }

            // Rating stars
            if photo.rating > 0 {
                HStack(spacing: 1) {
                    ForEach(1...5, id: \.self) { star in
                        Image(systemName: star <= photo.rating ? "star.fill" : "star")
                            .font(.system(size: 8))
                            .foregroundStyle(star <= photo.rating ? Color.yellow : Color.gray)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        }
        .opacity(photo.flag == .reject ? 0.5 : 1.0)
        .onAppear {
            if let cached = cache.cachedThumbnail(for: photo) {
                thumbnail = cached
            }
        }
        .task(id: photo.id) {
            guard thumbnail == nil else { return }
            thumbnail = await cache.thumbnail(for: photo)
        }
    }

    private func isBestInGroup() -> Bool {
        let scored = group.photos.filter { $0.blurScore != nil || $0.faceQualityScore != nil }
        guard scored.count >= 2 else { return false }
        let best = scored.max { qualityScore($0) < qualityScore($1) }
        return best?.id == photo.id
    }

    private func qualityScore(_ p: Photo) -> Double {
        var score = 0.0
        let peers = group.photos
        if let blur = p.blurScore {
            let peerBlurs = peers.compactMap(\.blurScore)
            if let maxB = peerBlurs.max(), let minB = peerBlurs.min(), maxB > minB {
                score += ((blur - minB) / (maxB - minB)) * 0.5
            } else {
                score += 0.25
            }
        }
        if let fq = p.faceQualityScore {
            score += fq * 0.5
        } else if let blur = p.blurScore {
            let peerBlurs = peers.compactMap(\.blurScore)
            if let maxB = peerBlurs.max(), let minB = peerBlurs.min(), maxB > minB {
                score += ((blur - minB) / (maxB - minB)) * 0.5
            } else {
                score += 0.25
            }
        }
        return score
    }

    private func isPhotoBlurry() -> Bool {
        if !photo.faceRegions.isEmpty {
            guard let fq = photo.faceQualityScore else { return false }
            return fq < 0.35
        }
        guard let blur = photo.blurScore else { return false }
        let peerScores = group.photos.compactMap(\.blurScore)
        guard peerScores.count >= 2 else { return false }
        let median = peerScores.sorted()[peerScores.count / 2]
        return blur < median * 0.4
    }
}
