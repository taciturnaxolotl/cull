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

    private static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

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

        // Read EXIF dates + image metadata in parallel batches
        let formatter = exifDateFormatter
        for batchStart in stride(from: 0, to: photos.count, by: 16) {
            let batch = Array(photos[batchStart..<min(batchStart + 16, photos.count)])
            await withTaskGroup(of: Void.self) { group in
                for photo in batch {
                    group.addTask {
                        readAllMetadata(photo: photo, formatter: formatter)
                    }
                }
            }
        }

        photos.sort { ($0.captureDate ?? .distantPast) < ($1.captureDate ?? .distantPast) }

        return ImportResult(photos: photos, paired: pairedCount)
    }

    /// Read all metadata from a single CGImageSource open — date, dimensions, file size, paired metadata
    nonisolated private static func readAllMetadata(photo: Photo, formatter: DateFormatter) {
        let url = photo.url

        // File size from filesystem
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64 {
            photo.fileSize = size
        }

        // Open image source once for date + dimensions
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            // Dimensions
            if let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
               let height = properties[kCGImagePropertyPixelHeight as String] as? Int {
                photo.pixelWidth = width
                photo.pixelHeight = height
            }
            // EXIF date
            if let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
               let dateString = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
                photo.captureDate = formatter.date(from: dateString)
            }
        }

        // Paired file metadata
        if let pairedURL = photo.pairedURL {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: pairedURL.path),
               let size = attrs[.size] as? Int64 {
                photo.pairedFileSize = size
            }
            if let source = CGImageSourceCreateWithURL(pairedURL as CFURL, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
               let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
               let height = properties[kCGImagePropertyPixelHeight as String] as? Int {
                photo.pairedPixelWidth = width
                photo.pairedPixelHeight = height
            }
        }
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
