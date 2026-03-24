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

    static func importFolder(_ url: URL, recursive: Bool = true) async throws -> ImportResult {
        var allURLs: [URL] = []
        var filesByBasename: [String: [URL]] = [:]

        let urls: [URL]
        if recursive {
            let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .contentTypeKey]
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                throw ImportError.cannotReadFolder
            }
            urls = enumerator.compactMap { $0 as? URL }
        } else {
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            urls = contents
        }
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
        let metadataInputs: [(Int, URL, URL?)] = photos.enumerated().map { (i, photo) in
            (i, photo.url, photo.pairedURL)
        }

        for batchStart in stride(from: 0, to: metadataInputs.count, by: 16) {
            let batch = Array(metadataInputs[batchStart..<min(batchStart + 16, metadataInputs.count)])
            let results = await withTaskGroup(of: (Int, PhotoMetadata).self, returning: [(Int, PhotoMetadata)].self) { group in
                for (index, url, pairedURL) in batch {
                    group.addTask {
                        let meta = readAllMetadata(url: url, pairedURL: pairedURL, formatter: formatter)
                        return (index, meta)
                    }
                }
                var collected: [(Int, PhotoMetadata)] = []
                for await result in group {
                    collected.append(result)
                }
                return collected
            }
            // Apply on main actor
            for (index, meta) in results {
                let photo = photos[index]
                photo.captureDate = meta.captureDate
                photo.pixelWidth = meta.pixelWidth
                photo.pixelHeight = meta.pixelHeight
                photo.fileSize = meta.fileSize
                photo.pairedPixelWidth = meta.pairedPixelWidth
                photo.pairedPixelHeight = meta.pairedPixelHeight
                photo.pairedFileSize = meta.pairedFileSize
            }
        }

        photos.sort { ($0.captureDate ?? .distantPast) < ($1.captureDate ?? .distantPast) }

        return ImportResult(photos: photos, paired: pairedCount)
    }

    struct PhotoMetadata: Sendable {
        var captureDate: Date?
        var pixelWidth: Int = 0
        var pixelHeight: Int = 0
        var fileSize: Int64 = 0
        var pairedPixelWidth: Int = 0
        var pairedPixelHeight: Int = 0
        var pairedFileSize: Int64 = 0

        nonisolated init() {}
    }

    /// Read all metadata from a single CGImageSource open — date, dimensions, file size, paired metadata
    nonisolated static func readAllMetadata(url: URL, pairedURL: URL?, formatter: DateFormatter) -> PhotoMetadata {
        var meta = PhotoMetadata()

        // File size from filesystem
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64 {
            meta.fileSize = size
        }

        // Open image source once for date + dimensions
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            if let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
               let height = properties[kCGImagePropertyPixelHeight as String] as? Int {
                meta.pixelWidth = width
                meta.pixelHeight = height
            }
            if let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
               let dateString = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
                meta.captureDate = formatter.date(from: dateString)
            }
        }

        // Paired file metadata
        if let pairedURL {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: pairedURL.path),
               let size = attrs[.size] as? Int64 {
                meta.pairedFileSize = size
            }
            if let source = CGImageSourceCreateWithURL(pairedURL as CFURL, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
               let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
               let height = properties[kCGImagePropertyPixelHeight as String] as? Int {
                meta.pairedPixelWidth = width
                meta.pairedPixelHeight = height
            }
        }

        return meta
    }

    /// Quick file scan — returns (relativePath, Photo) pairs without reading metadata.
    /// Used by workspace reload to detect new files.
    static func scanFiles(in folder: URL, recursive: Bool) throws -> [(String, Photo)] {
        let urls: [URL]
        if recursive {
            let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .contentTypeKey]
            guard let enumerator = FileManager.default.enumerator(
                at: folder,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                throw ImportError.cannotReadFolder
            }
            urls = enumerator.compactMap { $0 as? URL }
        } else {
            urls = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        }

        var filesByBasename: [String: [URL]] = [:]
        for fileURL in urls {
            let ext = fileURL.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { continue }
            let basename = fileURL.deletingPathExtension().lastPathComponent
            filesByBasename[basename, default: []].append(fileURL)
        }

        var result: [(String, Photo)] = []
        var processed: Set<URL> = []

        for (_, urls) in filesByBasename {
            let rawURLs = urls.filter { isRAWExtension($0.pathExtension) }
            let jpegURLs = urls.filter { isJPEGExtension($0.pathExtension) }

            if let rawURL = rawURLs.first, let jpegURL = jpegURLs.first {
                let photo = Photo(url: rawURL)
                photo.pairedURL = jpegURL
                let relativePath = rawURL.relativePath(from: folder)
                result.append((relativePath, photo))
                processed.insert(rawURL)
                processed.insert(jpegURL)
            }

            for url in urls where !processed.contains(url) {
                let photo = Photo(url: url)
                let relativePath = url.relativePath(from: folder)
                result.append((relativePath, photo))
                processed.insert(url)
            }
        }

        return result
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
