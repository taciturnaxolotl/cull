import Foundation

@Observable
final class PhotoGroup: Identifiable {
    let id: UUID
    var photos: [Photo]

    var representativePhoto: Photo? { photos.first }

    var earliestDate: Date? {
        photos.compactMap(\.captureDate).min()
    }

    init(photos: [Photo]) {
        self.id = UUID()
        self.photos = photos
    }
}

extension PhotoGroup: Hashable {
    static func == (lhs: PhotoGroup, rhs: PhotoGroup) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
