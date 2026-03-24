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
    var faceQualityScore: Double?

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
