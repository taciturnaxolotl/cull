import AppKit
import CryptoKit
import ImageIO

@MainActor @Observable
final class ThumbnailCache {
    private let memoryCache = NSCache<NSString, NSImage>()
    private let previewCache = NSCache<NSString, NSImage>()
    private var thumbnailKeys = Set<String>()
    private var previewKeys = Set<String>()
    /// Previews still wanted, highest priority first. Replaced (not cancelled) when the window moves.
    private var pendingPreviews: [(key: String, url: URL)] = []
    private var previewWorker: Task<Void, Never>?
    private var thumbnailSweep: Task<Void, Never>?
    /// Bumped whenever cache state changes, to trigger SwiftUI re-renders for debug overlay
    private(set) var cacheGeneration = 0
    /// Recent debug log entries (newest first), shown in debug overlay
    private(set) var debugLog: [String] = []
    private let diskCacheURL: URL
    private let maxPixelSize: Int

    init(maxPixelSize: Int = 400) {
        self.maxPixelSize = maxPixelSize
        self.diskCacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sh.dunkirk.Cull.thumbnails", isDirectory: true)

        memoryCache.countLimit = 500
        memoryCache.totalCostLimit = 100 * 1024 * 1024 // 100 MB

        // Previews are full-screen bitmaps (~17 MB each at 2560px), so the byte
        // budget is what actually bounds them. Without it NSCache purges under
        // memory pressure at unpredictable moments and the viewer falls back to
        // thumbnails. Keep the navigation window smaller than this budget.
        previewCache.countLimit = 72
        previewCache.totalCostLimit = 1024 * 1024 * 1024 // 1 GB

        try? FileManager.default.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
    }

    private func log(_ message: String) {
        let entry = "\(message) [\(previewKeys.count)/\(previewCache.countLimit)]"
        debugLog.insert(entry, at: 0)
        if debugLog.count > 20 { debugLog = Array(debugLog.prefix(20)) }
        cacheGeneration += 1
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
        let loadURL = photo.imageURL

        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached
        }

        let diskPath = diskCacheURL.appendingPathComponent(stableDiskKey(for: photo.url))
        let pixelSize = maxPixelSize

        let image: NSImage? = await Task.detached { () -> NSImage? in
            if let diskImage = NSImage(contentsOf: diskPath) {
                return diskImage
            }
            guard let extracted = Self.extractThumbnailSync(from: loadURL, maxPixelSize: pixelSize) else { return nil }
            Self.saveToDisk(extracted, at: diskPath)
            return extracted
        }.value

        if let image {
            memoryCache.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
            thumbnailKeys.insert(key)
        }
        return image
    }

    func previewImage(for photo: Photo) async -> NSImage? {
        let key = photo.url.absoluteString

        if let cached = previewCache.object(forKey: key as NSString) {
            return cached
        }

        let loadURL = photo.imageURL

        let image: NSImage? = await Task.detached { () -> NSImage? in
            Self.loadFullPreviewSync(from: loadURL)
        }.value

        if let image {
            previewCache.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
            previewKeys.insert(key)
            cacheGeneration += 1
        }
        return image
    }

    // MARK: - Preloading

    /// Load all thumbnails into memory, awaiting completion. Reports progress.
    func preloadAllThumbnails(
        photos: [Photo],
        progress: (@Sendable (Double) async -> Void)? = nil
    ) async {
        // key = RAW url for cache identity, loadURL = JPEG when available for fast decode
        let thumbWork: [(String, URL, URL)] = photos.map { photo in
            (photo.url.absoluteString, photo.imageURL, photo.url)
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
                for (key, loadURL, cacheKeyURL) in batch {
                    let diskPath = diskCache.appendingPathComponent(Self.stableDiskKey(for: cacheKeyURL))
                    group.addTask {
                        if let diskImage = NSImage(contentsOf: diskPath) {
                            return (key, diskImage)
                        }
                        guard let extracted = Self.extractThumbnailSync(from: loadURL, maxPixelSize: pixelSize) else {
                            return (key, nil)
                        }
                        Self.saveToDisk(extracted, at: diskPath)
                        return (key, extracted)
                    }
                }
                var batchKeys: [String] = []
                for await (key, image) in group {
                    if let image {
                        mc.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
                        batchKeys.append(key)
                    }
                    completed += 1
                    if let progress {
                        await progress(completed / totalItems)
                    }
                }
                for k in batchKeys { thumbnailKeys.insert(k) }
                if !batchKeys.isEmpty { cacheGeneration += 1 }
            }
        }
    }

    /// Fire-and-forget thumbnail sweep, used after a filter change brings new photos into view.
    /// Runs at background priority and stays cancellable so it can't starve preview loading:
    /// an unbounded full-library sweep is what makes the viewer fall back to thumbnails.
    func preload(photos: [Photo]) {
        thumbnailSweep?.cancel()

        let work: [(String, URL, URL)] = photos.compactMap { photo in
            let key = photo.url.absoluteString
            guard memoryCache.object(forKey: key as NSString) == nil else { return nil }
            return (key, photo.imageURL, photo.url)
        }
        guard !work.isEmpty else { return }

        log("sweep \(work.count) thumbs")

        let pixelSize = maxPixelSize
        let diskCache = diskCacheURL
        let mc = memoryCache

        thumbnailSweep = Task.detached(priority: .background) {
            for batchStart in stride(from: 0, to: work.count, by: 8) {
                guard !Task.isCancelled else { return }
                let batch = Array(work[batchStart..<min(batchStart + 8, work.count)])
                let batchKeys = await withTaskGroup(of: (String, NSImage?).self, returning: [String].self) { group in
                    for (key, loadURL, cacheKeyURL) in batch {
                        let diskPath = diskCache.appendingPathComponent(Self.stableDiskKey(for: cacheKeyURL))
                        group.addTask {
                            guard !Task.isCancelled else { return (key, nil) }
                            if let diskImage = NSImage(contentsOf: diskPath) {
                                return (key, diskImage)
                            }
                            guard let extracted = Self.extractThumbnailSync(from: loadURL, maxPixelSize: pixelSize) else {
                                return (key, nil)
                            }
                            Self.saveToDisk(extracted, at: diskPath)
                            return (key, extracted)
                        }
                    }
                    var keys: [String] = []
                    for await (key, image) in group {
                        if let image {
                            // NSCache is thread-safe, no need for MainActor
                            mc.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
                            keys.append(key)
                        }
                    }
                    return keys
                }
                // Key tracking and generation bump must happen on MainActor
                if !batchKeys.isEmpty {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        for k in batchKeys { self.thumbnailKeys.insert(k) }
                        self.cacheGeneration += 1
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
            (photo.url.absoluteString, photo.imageURL)
        }

        let totalItems = Double(work.count)
        var completed = 0.0
        let pc = previewCache
        let batchSize = 4

        for batchStart in stride(from: 0, to: work.count, by: batchSize) {
            let batch = Array(work[batchStart..<min(batchStart + batchSize, work.count)])
            await withTaskGroup(of: (String, NSImage?).self) { group in
                for (key, loadURL) in batch {
                    group.addTask {
                        (key, Self.loadFullPreviewSync(from: loadURL))
                    }
                }
                for await (key, image) in group {
                    if let image {
                        pc.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
                        previewKeys.insert(key)
                        cacheGeneration += 1
                    }
                    completed += 1
                    if let progress {
                        await progress(completed / totalItems)
                    }
                }
            }
        }
    }

    /// Fire-and-forget: preload previews in background, nearest first.
    ///
    /// Calling this replaces the wanted list rather than cancelling work in flight.
    /// Culling with a filter on moves the selection on every keypress, and the old
    /// cancel-and-restart meant the window never finished filling — you'd land on a
    /// photo that only had a thumbnail.
    func preloadPreviews(photos: [Photo]) {
        pendingPreviews = photos.compactMap { photo in
            let key = photo.url.absoluteString
            guard previewCache.object(forKey: key as NSString) == nil else { return nil }
            return (key, photo.imageURL)
        }
        guard !pendingPreviews.isEmpty else { return }

        log("queue \(pendingPreviews.count)/\(photos.count) previews")
        startPreviewWorker()
    }

    /// Drains `pendingPreviews` a batch at a time. Re-reads the queue between batches,
    /// so a window change takes effect on the next batch without losing decoded images.
    private func startPreviewWorker() {
        guard previewWorker == nil else { return }

        previewWorker = Task { @MainActor [weak self] in
            defer { self?.previewWorker = nil }

            while let self, !self.pendingPreviews.isEmpty {
                let batch = Array(self.pendingPreviews.prefix(4))
                self.pendingPreviews.removeFirst(batch.count)

                let loaded = await withTaskGroup(of: (String, NSImage?).self, returning: [(String, NSImage)].self) { group in
                    for (key, loadURL) in batch {
                        group.addTask {
                            (key, Self.loadFullPreviewSync(from: loadURL))
                        }
                    }
                    var results: [(String, NSImage)] = []
                    for await (key, image) in group {
                        if let image { results.append((key, image)) }
                    }
                    return results
                }

                for (key, image) in loaded {
                    self.previewCache.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
                    self.previewKeys.insert(key)
                }
                if !loaded.isEmpty { self.cacheGeneration += 1 }
            }
        }
    }

    /// Remove previews that are outside the current window
    func evictPreviews(keeping photos: [Photo]) {
        let keepKeys = Set(photos.map { $0.url.absoluteString })
        var evicted = 0
        for key in previewKeys where !keepKeys.contains(key) {
            previewCache.removeObject(forKey: key as NSString)
            previewKeys.remove(key)
            evicted += 1
        }
        if evicted > 0 {
            log("evict \(evicted) previews")
        }
    }

    /// Remove previews for photos that are no longer visible.
    /// Thumbnails are deliberately kept: they're small, disk-backed, and re-reading
    /// them all after a filter toggle is expensive enough to stall preview loading.
    func evictFiltered(keeping photos: [Photo]) {
        let keepKeys = Set(photos.map { $0.url.absoluteString })

        var evictedPreviews = 0
        for key in previewKeys where !keepKeys.contains(key) {
            previewCache.removeObject(forKey: key as NSString)
            previewKeys.remove(key)
            evictedPreviews += 1
        }

        if evictedPreviews > 0 {
            log("filter evict \(evictedPreviews)p")
        }
        cacheGeneration += 1
    }

    // MARK: - Stats

    struct CacheStats {
        let thumbnailCount: Int
        let previewCount: Int
        let previewLimit: Int
        let thumbnailLimit: Int
    }

    func stats() -> CacheStats {
        // NSCache can drop entries on its own under memory pressure, so the key sets
        // drift out of date. Prune before reporting or the overlay lies about coverage.
        previewKeys = previewKeys.filter { previewCache.object(forKey: $0 as NSString) != nil }
        thumbnailKeys = thumbnailKeys.filter { memoryCache.object(forKey: $0 as NSString) != nil }

        return CacheStats(
            thumbnailCount: thumbnailKeys.count,
            previewCount: previewKeys.count,
            previewLimit: previewCache.countLimit,
            thumbnailLimit: memoryCache.countLimit
        )
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

    /// Approximate decoded size in bytes, so NSCache's byte budget means something.
    nonisolated private static func cost(of image: NSImage) -> Int {
        guard let rep = image.representations.first else { return 1 }
        return max(rep.pixelsWide * rep.pixelsHigh * 4, 1)
    }

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
        previewWorker?.cancel()
        previewWorker = nil
        thumbnailSweep?.cancel()
        thumbnailSweep = nil
        pendingPreviews.removeAll()
        memoryCache.removeAllObjects()
        previewCache.removeAllObjects()
        thumbnailKeys.removeAll()
        previewKeys.removeAll()
        try? FileManager.default.removeItem(at: diskCacheURL)
        try? FileManager.default.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
    }
}
