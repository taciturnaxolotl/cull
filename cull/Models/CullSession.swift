import Foundation
import SwiftUI

@Observable
final class CullSession {
    var sourceFolder: URL?
    var groups: [PhotoGroup] = []
    var selectedGroupIndex: Int = 0
    var selectedPhotoIndex: Int = 0

    var isImporting: Bool = false
    var importProgress: Double = 0

    var selectedGroup: PhotoGroup? {
        guard groups.indices.contains(selectedGroupIndex) else { return nil }
        return groups[selectedGroupIndex]
    }

    var selectedPhoto: Photo? {
        guard let group = selectedGroup,
              group.photos.indices.contains(selectedPhotoIndex) else { return nil }
        return group.photos[selectedPhotoIndex]
    }

    var allPhotos: [Photo] {
        groups.flatMap(\.photos)
    }

    // MARK: - Navigation

    func moveToNextGroup() {
        guard !groups.isEmpty else { return }
        selectedGroupIndex = (selectedGroupIndex + 1) % groups.count
        selectedPhotoIndex = 0
    }

    func moveToPreviousGroup() {
        guard !groups.isEmpty else { return }
        selectedGroupIndex = (selectedGroupIndex - 1 + groups.count) % groups.count
        selectedPhotoIndex = 0
    }

    func moveToNextPhoto() {
        guard let group = selectedGroup else { return }
        if selectedPhotoIndex < group.photos.count - 1 {
            selectedPhotoIndex += 1
        } else {
            moveToNextGroup()
        }
    }

    func moveToPreviousPhoto() {
        if selectedPhotoIndex > 0 {
            selectedPhotoIndex -= 1
        } else {
            moveToPreviousGroup()
            selectedPhotoIndex = max(0, (selectedGroup?.photos.count ?? 1) - 1)
        }
    }

    func selectGroup(at index: Int) {
        guard groups.indices.contains(index) else { return }
        selectedGroupIndex = index
        selectedPhotoIndex = 0
    }

    func selectPhoto(at index: Int) {
        guard let group = selectedGroup, group.photos.indices.contains(index) else { return }
        selectedPhotoIndex = index
    }

    // MARK: - Lookahead

    /// Returns the next N photos from the current position across group boundaries
    func photosAhead(_ count: Int) -> [Photo] {
        var result: [Photo] = []
        var gi = selectedGroupIndex
        var pi = selectedPhotoIndex + 1

        while result.count < count && gi < groups.count {
            let group = groups[gi]
            while pi < group.photos.count && result.count < count {
                result.append(group.photos[pi])
                pi += 1
            }
            gi += 1
            pi = 0
        }
        return result
    }

    /// Returns the previous N photos from the current position across group boundaries
    func photosBehind(_ count: Int) -> [Photo] {
        var result: [Photo] = []
        var gi = selectedGroupIndex
        var pi = selectedPhotoIndex - 1

        while result.count < count && gi >= 0 {
            let group = groups[gi]
            while pi >= 0 && result.count < count {
                result.append(group.photos[pi])
                pi -= 1
            }
            gi -= 1
            if gi >= 0 { pi = groups[gi].photos.count - 1 }
        }
        return result
    }

    // MARK: - Culling Actions

    func setRating(_ rating: Int) {
        guard (1...5).contains(rating) else { return }
        selectedPhoto?.rating = rating
    }

    func togglePick() {
        guard let photo = selectedPhoto else { return }
        photo.flag = photo.flag == .pick ? .none : .pick
    }

    func toggleReject() {
        guard let photo = selectedPhoto else { return }
        photo.flag = photo.flag == .reject ? .none : .reject
    }

    func clearRatingAndFlag() {
        guard let photo = selectedPhoto else { return }
        photo.rating = 0
        photo.flag = .none
    }
}
