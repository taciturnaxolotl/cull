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
                            PhotoThumbnail(
                                photo: photo,
                                isSelected: index == session.selectedPhotoIndex
                            )
                            .id(photo.id)
                            .onTapGesture {
                                session.selectPhoto(at: index)
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
    let isSelected: Bool
    @Environment(ThumbnailCache.self) private var cache
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .topLeading) {
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

                // Flag badge
                if photo.flag != .none {
                    Image(systemName: photo.flag == .pick ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(photo.flag == .pick ? .green : .red)
                        .font(.caption)
                        .padding(4)
                }
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
}
