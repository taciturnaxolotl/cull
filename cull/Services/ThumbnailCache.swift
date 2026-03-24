import AppKit
import CryptoKit
import ImageIO

@MainActor @Observable
final class ThumbnailCache {
    private let memoryCache = NSCache<NSString, NSImage>()
    private let previewCache = NSCache<NSString, NSImage>()
    private var previewKeys = Set<String>()
    private var preloadTask: Task<Void, Never>?
    private let diskCacheURL: URL
    private let maxPixelSize: Int

    init(maxPixelSize: Int = 400) {
        self.maxPixelSize = maxPixelSize
        self.diskCacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sh.dunkirk.Cull.thumbnails", isDirectory: true)

        memoryCache.countLimit = 500
        memoryCache.totalCostLimit = 100 * 1024 * 1024 // 100 MB

        previewCache.countLimit = 70

        try? FileManager.default.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
    }

    // MARK: - Synchronous lookups (instant, memory only)

    func cachedThumbnail(for photo: Photo) -> NSImage? {
        memoryCache.object(forKey: photo.url.absoluteString as NSString)
    }

    func cachedPreview(for photo: Photo) -> NSImage? {
        previewCache.object(forKey: photo.url.absoluteString as NSString)
    }

    // MARK: - Async loading

    func thumbnail(for photo: Photo) async -> NSImage? {
        let key = photo.url.absoluteString
        let sourceURL = photo.pairedURL ?? photo.url

        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached
        }

        let diskPath = diskCacheURL.appendingPathComponent(stableDiskKey(for: photo.url))
        let pixelSize = maxPixelSize

        let image: NSImage? = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            if let diskImage = NSImage(contentsOf: diskPath) {
                return diskImage
            }
            guard let extracted = Self.extractThumbnailSync(from: sourceURL, maxPixelSize: pixelSize) else { return nil }
            Self.saveToDisk(extracted, at: diskPath)
            return extracted
        }.value

        if let image {
            memoryCache.setObject(image, forKey: key as NSString)
        }
        return image
    }

    func previewImage(for photo: Photo) async -> NSImage? {
        let key = photo.url.absoluteString

        if let cached = previewCache.object(forKey: key as NSString) {
            return cached
        }

        let url = photo.pairedURL ?? photo.url

        let image: NSImage? = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            Self.loadFullPreviewSync(from: url)
        }.value

        if let image {
            previewCache.setObject(image, forKey: key as NSString)
            previewKeys.insert(key)
        }
        return image
    }

    // MARK: - Preloading

    /// Load all thumbnails into memory, awaiting completion. Reports progress.
    func preloadAllThumbnails(
        photos: [Photo],
        progress: (@Sendable (Double) async -> Void)? = nil
    ) async {
        let thumbWork: [(String, URL, URL)] = photos.map { photo in
            (photo.url.absoluteString, photo.pairedURL ?? photo.url, photo.url)
        }

        let totalItems = Double(thumbWork.count)
        var completed = 0.0
        let pixelSize = maxPixelSize
        let diskCache = diskCacheURL
        let mc = memoryCache
        let batchSize = 8

        for batchStart in stride(from: 0, to: thumbWork.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, thumbWork.count)
            let batch = Array(thumbWork[batchStart..<batchEnd])
            await withTaskGroup(of: (String, NSImage?).self) { group in
                for (key, sourceURL, photoURL) in batch {
                    let diskPath = diskCache.appendingPathComponent(Self.stableDiskKey(for: photoURL))
                    group.addTask {
                        if let diskImage = NSImage(contentsOf: diskPath) {
                            return (key, diskImage)
                        }
                        guard let extracted = Self.extractThumbnailSync(from: sourceURL, maxPixelSize: pixelSize) else {
                            return (key, nil)
                        }
                        Self.saveToDisk(extracted, at: diskPath)
                        return (key, extracted)
                    }
                }
                for await (key, image) in group {
                    if let image {
                        mc.setObject(image, forKey: key as NSString)
                    }
                    completed += 1
                    if let progress {
                        await progress(completed / totalItems)
                    }
                }
            }
        }
    }

    func preload(photos: [Photo]) {
        let work: [(String, URL, URL)] = photos.compactMap { photo in
            let key = photo.url.absoluteString
            guard memoryCache.object(forKey: key as NSString) == nil else { return nil }
            return (key, photo.pairedURL ?? photo.url, photo.url)
        }
        guard !work.isEmpty else { return }

        let pixelSize = maxPixelSize
        let diskCache = diskCacheURL
        let mc = memoryCache

        Task.detached(priority: .utility) {
            for batchStart in stride(from: 0, to: work.count, by: 8) {
                let batch = Array(work[batchStart..<min(batchStart + 8, work.count)])
                await withTaskGroup(of: (String, NSImage?).self) { group in
                    for (key, sourceURL, photoURL) in batch {
                        let diskPath = diskCache.appendingPathComponent(Self.stableDiskKey(for: photoURL))
                        group.addTask {
                            if let diskImage = NSImage(contentsOf: diskPath) {
                                return (key, diskImage)
                            }
                            guard let extracted = Self.extractThumbnailSync(from: sourceURL, maxPixelSize: pixelSize) else {
                                return (key, nil)
                            }
                            Self.saveToDisk(extracted, at: diskPath)
                            return (key, extracted)
                        }
                    }
                    for await (key, image) in group {
                        if let image {
                            await MainActor.run { mc.setObject(image, forKey: key as NSString) }
                        }
                    }
                }
            }
        }
    }

    /// Awaitable: load previews and report progress. Used during import.
    func preloadAllPreviews(
        photos: [Photo],
        progress: (@Sendable (Double) async -> Void)? = nil
    ) async {
        let work: [(String, URL)] = photos.map { photo in
            (photo.url.absoluteString, photo.pairedURL ?? photo.url)
        }

        let totalItems = Double(work.count)
        var completed = 0.0
        let pc = previewCache
        let batchSize = 4

        for batchStart in stride(from: 0, to: work.count, by: batchSize) {
            let batch = Array(work[batchStart..<min(batchStart + batchSize, work.count)])
            await withTaskGroup(of: (String, NSImage?).self) { group in
                for (key, url) in batch {
                    group.addTask {
                        (key, Self.loadFullPreviewSync(from: url))
                    }
                }
                for await (key, image) in group {
                    if let image {
                        pc.setObject(image, forKey: key as NSString)
                        previewKeys.insert(key)
                    }
                    completed += 1
                    if let progress {
                        await progress(completed / totalItems)
                    }
                }
            }
        }
    }

    /// Fire-and-forget: preload previews in background. Used during navigation.
    /// Cancels any previous preload so stale work doesn't compete.
    func preloadPreviews(photos: [Photo]) {
        preloadTask?.cancel()

        let work: [(String, URL)] = photos.compactMap { photo in
            let key = photo.url.absoluteString
            guard previewCache.object(forKey: key as NSString) == nil else { return nil }
            return (key, photo.pairedURL ?? photo.url)
        }
        guard !work.isEmpty else { return }

        let pc = previewCache

        preloadTask = Task.detached(priority: .utility) {
            for batchStart in stride(from: 0, to: work.count, by: 4) {
                guard !Task.isCancelled else { return }
                let batch = Array(work[batchStart..<min(batchStart + 4, work.count)])
                await withTaskGroup(of: (String, NSImage?).self) { group in
                    for (key, url) in batch {
                        group.addTask {
                            guard !Task.isCancelled else { return (key, nil) }
                            return (key, Self.loadFullPreviewSync(from: url))
                        }
                    }
                    for await (key, image) in group {
                        if let image {
                            await MainActor.run {
                                pc.setObject(image, forKey: key as NSString)
                                self.previewKeys.insert(key)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Remove previews that are outside the current window
    func evictPreviews(keeping photos: [Photo]) {
        let keepKeys = Set(photos.map { $0.url.absoluteString })
        for key in previewKeys where !keepKeys.contains(key) {
            previewCache.removeObject(forKey: key as NSString)
            previewKeys.remove(key)
        }
    }

    // MARK: - Sync image extraction

    nonisolated private static func extractThumbnailSync(from url: URL, maxPixelSize: Int) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    nonisolated private static func loadFullPreviewSync(from url: URL) -> NSImage? {
        // Use the thumbnail API with kCGImageSourceCreateThumbnailFromImageAlways
        // to force full decode + downscale while respecting EXIF orientation
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 2560,
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    // MARK: - Utilities

    private func stableDiskKey(for url: URL) -> String {
        Self.stableDiskKey(for: url)
    }

    nonisolated private static func stableDiskKey(for url: URL) -> String {
        let data = Data(url.absoluteString.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined() + ".jpg"
    }

    nonisolated private static func saveToDisk(_ image: NSImage, at url: URL) {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
        else { return }
        try? jpegData.write(to: url)
    }

    func clearCache() {
        memoryCache.removeAllObjects()
        previewCache.removeAllObjects()
        try? FileManager.default.removeItem(at: diskCacheURL)
        try? FileManager.default.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
    }
}
