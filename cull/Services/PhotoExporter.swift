import Foundation

enum ExportFileType: String, CaseIterable, Identifiable {
    case raw = "RAW Only"
    case jpeg = "JPEG Only"
    case both = "RAW + JPEG"

    var id: String { rawValue }
}

enum ExportMode: String, CaseIterable, Identifiable {
    case copy = "Copy"
    case move = "Move"

    var id: String { rawValue }
}

struct ExportOptions {
    var destination: URL
    var fileType: ExportFileType = .both
    var mode: ExportMode = .copy
    var minimumRating: Int = 1 // export photos rated >= this
    var includePickedOnly: Bool = false
}

struct ExportResult {
    let exported: Int
    let skipped: Int
    let errors: [String]
}

struct PhotoExporter {
    static func export(photos: [Photo], options: ExportOptions) async throws -> ExportResult {
        let fm = FileManager.default
        try fm.createDirectory(at: options.destination, withIntermediateDirectories: true)

        var exported = 0
        var skipped = 0
        var errors: [String] = []

        let eligible = photos.filter { photo in
            if photo.flag == .reject { return false }
            if options.includePickedOnly { return photo.flag == .pick }
            return photo.rating >= options.minimumRating
        }

        for photo in eligible {
            let urlsToExport = urlsForExport(photo: photo, fileType: options.fileType)

            for sourceURL in urlsToExport {
                let destURL = options.destination.appendingPathComponent(sourceURL.lastPathComponent)
                do {
                    if fm.fileExists(atPath: destURL.path) {
                        try fm.removeItem(at: destURL)
                    }
                    switch options.mode {
                    case .copy:
                        try fm.copyItem(at: sourceURL, to: destURL)
                    case .move:
                        try fm.moveItem(at: sourceURL, to: destURL)
                    }
                    exported += 1
                } catch {
                    errors.append("\(sourceURL.lastPathComponent): \(error.localizedDescription)")
                }
            }

            skipped += urlsToExport.isEmpty ? 1 : 0
        }

        return ExportResult(exported: exported, skipped: skipped, errors: errors)
    }

    private static func urlsForExport(photo: Photo, fileType: ExportFileType) -> [URL] {
        switch fileType {
        case .both:
            var urls = [photo.url]
            if let paired = photo.pairedURL { urls.append(paired) }
            return urls
        case .raw:
            return photo.isRAW ? [photo.url] : (photo.pairedURL.map { [$0] } ?? [])
        case .jpeg:
            return photo.isJPEG ? [photo.url] : (photo.pairedURL.map { [$0] } ?? [])
        }
    }
}
