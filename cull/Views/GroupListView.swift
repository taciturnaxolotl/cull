import SwiftUI

struct GroupListView: View {
    @Environment(CullSession.self) private var session
    @Environment(ThumbnailCache.self) private var cache

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(session.groups.enumerated()), id: \.element.id) { index, group in
                        if group.photos.contains(where: { !session.isPhotoFiltered($0) }) {
                            GroupThumbnail(
                                group: group,
                                index: index,
                                isSelected: index == session.selectedGroupIndex,
                                visibleCount: group.photos.filter { !session.isPhotoFiltered($0) }.count
                            )
                            .id(group.id)
                            .onTapGesture {
                                session.selectGroup(at: index)
                            }
                        }
                    }
                }
                .padding(4)
            }
            .onChange(of: session.selectedGroupIndex) { _, newIndex in
                if let group = session.groups[safe: newIndex] {
                    withAnimation {
                        proxy.scrollTo(group.id, anchor: .center)
                    }
                }
            }
        }
    }
}

private struct GroupThumbnail: View {
    let group: PhotoGroup
    let index: Int
    let isSelected: Bool
    let visibleCount: Int
    @Environment(CullSession.self) private var session
    @Environment(ThumbnailCache.self) private var cache
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 112, height: 80)
                    .clipped()
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 112, height: 80)
            }

            Text("\(visibleCount)")
                .font(.caption2.bold())
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        }
        .overlay(alignment: .topLeading) {
            if session.debugCacheOverlay {
                let _ = cache.cacheGeneration
                let allCached = group.photos.allSatisfy { cache.cachedPreview(for: $0) != nil }
                let anyCached = group.photos.contains { cache.cachedPreview(for: $0) != nil }
                let debugColor: Color = allCached ? .green : (anyCached ? .yellow : .red)
                Circle()
                    .fill(debugColor)
                    .frame(width: 6, height: 6)
                    .padding(4)
            }
        }
        .onAppear {
            guard let photo = group.representativePhoto else { return }
            if let cached = cache.cachedThumbnail(for: photo) {
                thumbnail = cached
            }
        }
        .task(id: group.representativePhoto?.id) {
            guard thumbnail == nil, let photo = group.representativePhoto else { return }
            thumbnail = await cache.thumbnail(for: photo)
        }
    }
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
