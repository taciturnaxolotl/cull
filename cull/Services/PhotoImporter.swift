import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PhotoImporter {
    static let supportedExtensions: Set<String> = [
        "cr2", "cr3", "arw", "nef", "dng", "raf", "orf", "rw2",
        "jpg", "jpeg", "heic", "heif", "tiff", "tif", "png"
    ]

    struct ImportResult {
        let photos: [Photo]
        let paired: Int // count of RAW+JPEG pairs found
    }

    static func importFolder(_ url: URL) async throws -> ImportResult {
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .contentTypeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw ImportError.cannotReadFolder
        }

        var filesByBasename: [String: [URL]] = [:]
        var allURLs: [URL] = []

        let urls: [URL] = enumerator.compactMap { $0 as? URL }
        for fileURL in urls {
            let ext = fileURL.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { continue }
            allURLs.append(fileURL)
            let basename = fileURL.deletingPathExtension().lastPathComponent
            filesByBasename[basename, default: []].append(fileURL)
        }

        // Build photo objects (no I/O yet)
        var photos: [Photo] = []
        var pairedCount = 0
        var processed: Set<URL> = []

        for (_, urls) in filesByBasename {
            let rawURLs = urls.filter { isRAWExtension($0.pathExtension) }
            let jpegURLs = urls.filter { isJPEGExtension($0.pathExtension) }

            if let rawURL = rawURLs.first, let jpegURL = jpegURLs.first {
                let photo = Photo(url: rawURL)
                photo.pairedURL = jpegURL
                photos.append(photo)
                processed.insert(rawURL)
                processed.insert(jpegURL)
                pairedCount += 1
            }

            for url in urls where !processed.contains(url) {
                let photo = Photo(url: url)
                photos.append(photo)
                processed.insert(url)
            }
        }

        // Read EXIF dates sequentially (header-only reads are fast, ~1ms each)
        for photo in photos {
            let dateURL = photo.pairedURL ?? photo.url
            photo.captureDate = readCaptureDate(from: dateURL)
        }

        photos.sort { ($0.captureDate ?? .distantPast) < ($1.captureDate ?? .distantPast) }

        return ImportResult(photos: photos, paired: pairedCount)
    }

    nonisolated static func readCaptureDate(from url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let dateString = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String
        else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: dateString)
    }

    static func isRAWExtension(_ ext: String) -> Bool {
        let raw: Set<String> = ["cr2", "cr3", "arw", "nef", "dng", "raf", "orf", "rw2"]
        return raw.contains(ext.lowercased())
    }

    static func isJPEGExtension(_ ext: String) -> Bool {
        let jpeg: Set<String> = ["jpg", "jpeg"]
        return jpeg.contains(ext.lowercased())
    }
}

enum ImportError: LocalizedError {
    case cannotReadFolder

    var errorDescription: String? {
        switch self {
        case .cannotReadFolder: "Could not read the selected folder."
        }
    }
}
