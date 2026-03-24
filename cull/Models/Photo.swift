import Foundation
import UniformTypeIdentifiers

enum PhotoFlag: Equatable {
    case none
    case pick
    case reject
}

@Observable
final class Photo: Identifiable {
    let id: UUID
    let url: URL
    let basename: String

    /// Paired file — e.g. if this is a RAW, pairedURL points to the JPEG (and vice versa)
    var pairedURL: URL?

    var rating: Int = 0 // 0 = unrated, 1–5
    var flag: PhotoFlag = .none

    // Populated asynchronously by QualityAnalyzer
    var blurScore: Double?
    /// Laplacian variance measured on the face crop — actual face sharpness
    var faceSharpness: Double?
    /// Normalized face bounding boxes (Vision coordinates: origin bottom-left, 0-1 range)
    var faceRegions: [CGRect] = []

    // Image metadata (populated during import)
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    var fileSize: Int64 = 0
    // Paired file metadata (only set when pairedURL exists)
    var pairedPixelWidth: Int = 0
    var pairedPixelHeight: Int = 0
    var pairedFileSize: Int64 = 0

    // Populated by ShotGrouper
    var captureDate: Date?

    var isRAW: Bool {
        guard let utType = UTType(filenameExtension: url.pathExtension) else { return false }
        return utType.conforms(to: .rawImage)
    }

    var isJPEG: Bool {
        guard let utType = UTType(filenameExtension: url.pathExtension) else { return false }
        return utType.conforms(to: .jpeg)
    }

    init(url: URL) {
        self.id = UUID()
        self.url = url
        self.basename = url.deletingPathExtension().lastPathComponent
    }
}

extension Photo: Hashable {
    static func == (lhs: Photo, rhs: Photo) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
