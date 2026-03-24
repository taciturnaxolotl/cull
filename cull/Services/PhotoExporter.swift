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

struct ExportResult {
    let exported: Int
    let skipped: Int
    let errors: [String]
}

struct PhotoExporter {
    /// Export pre-filtered photos to destination
    static func export(
        photos: [Photo],
        destination: URL,
        fileType: ExportFileType,
        mode: ExportMode
    ) async -> ExportResult {
        let fm = FileManager.default

        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            return ExportResult(exported: 0, skipped: 0, errors: ["Cannot create destination: \(error.localizedDescription)"])
        }

        var exported = 0
        var skipped = 0
        var errors: [String] = []

        for photo in photos {
            let urls = urlsForExport(photo: photo, fileType: fileType)

            if urls.isEmpty {
                skipped += 1
                continue
            }

            for sourceURL in urls {
                let accessing = sourceURL.startAccessingSecurityScopedResource()
                defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }

                let destURL = destination.appendingPathComponent(sourceURL.lastPathComponent)
                do {
                    if fm.fileExists(atPath: destURL.path) {
                        try fm.removeItem(at: destURL)
                    }
                    switch mode {
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
            if photo.isRAW { return [photo.url] }
            if let paired = photo.pairedURL, PhotoImporter.isRAWExtension(paired.pathExtension) { return [paired] }
            return []
        case .jpeg:
            if photo.isJPEG { return [photo.url] }
            if let paired = photo.pairedURL, PhotoImporter.isJPEGExtension(paired.pathExtension) { return [paired] }
            return []
        }
    }
}
