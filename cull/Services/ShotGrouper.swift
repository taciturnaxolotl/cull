import Vision
import ImageIO

struct ShotGrouper {
    /// Largest gap between frames that still counts as one burst (seconds).
    /// Bursts are the unit of grouping and are never split: anything shot this close
    /// together is one moment, including the pauses while reframing a shot.
    static let burstGapThreshold: TimeInterval = 3

    /// How close two neighbouring bursts must be to be considered for merging (seconds)
    static let mergeTimeThreshold: TimeInterval = 10

    /// Feature print distance threshold for visual similarity (Revision 2, macOS 14+)
    /// Higher = more lenient grouping (different framings of same scene)
    static let similarityThreshold: Float = 0.6

    /// For RAW files with embedded previews, find the largest image index.
    /// Returns (source, imageIndex). Shared with QualityAnalyzer.
    static func bestImageSource(for url: URL) -> (CGImageSource, Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let count = CGImageSourceGetCount(source)
        if count > 1 {
            var bestIndex = 0
            var bestPixels = 0
            for i in 0..<count {
                if let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any],
                   let w = props[kCGImagePropertyPixelWidth as String] as? Int,
                   let h = props[kCGImagePropertyPixelHeight as String] as? Int {
                    let pixels = w * h
                    if pixels > bestPixels {
                        bestPixels = pixels
                        bestIndex = i
                    }
                }
            }
            return (source, bestIndex)
        }
        return (source, 0)
    }

    /// Groups a shoot into scenes, in the order they were taken.
    ///
    /// Two passes, and the order matters. First the timeline is cut into bursts — frames
    /// shot close enough together to be one moment — which are never broken up. Then
    /// neighbouring bursts are merged when they're close in time and look alike.
    ///
    /// Only *neighbouring* units ever merge, which is what keeps the browse order
    /// chronological. Gathering every similar shot within a window instead, as this used
    /// to, means two subjects photographed in alternation become two groups covering the
    /// same minutes, and walking from one to the next runs the clock backwards.
    static func group(photos: [Photo], progress: (@Sendable (Double) async -> Void)? = nil) async -> [PhotoGroup] {
        guard !photos.isEmpty else { return [] }

        let bursts = splitIntoBursts(photos)

        // Feature prints, needed to decide which neighbouring bursts belong together
        let fpWork: [(UUID, URL)] = photos.map { ($0.id, $0.imageURL) }
        var featurePrintMap: [UUID: VNFeaturePrintObservation] = [:]
        let totalWork = Double(photos.count)
        var completed = 0.0
        let batchSize = 8
        for batchStart in stride(from: 0, to: fpWork.count, by: batchSize) {
            let batch = Array(fpWork[batchStart..<min(batchStart + batchSize, fpWork.count)])
            await withTaskGroup(of: (UUID, VNFeaturePrintObservation?).self) { group in
                for (id, url) in batch {
                    group.addTask {
                        let fp = await generateFeaturePrint(url: url)
                        return (id, fp)
                    }
                }
                for await (id, fp) in group {
                    if let fp { featurePrintMap[id] = fp }
                    completed += 1
                    if let progress {
                        await progress(completed / totalWork)
                    }
                }
            }
        }

        return mergeAdjacentGroups(bursts.map { PhotoGroup(photos: $0) }, featurePrintMap: featurePrintMap)
    }

    /// Splits photos, in capture order, wherever the gap exceeds `burstGapThreshold`
    private static func splitIntoBursts(_ photos: [Photo]) -> [[Photo]] {
        let sorted = photos.sorted { ($0.captureDate ?? .distantPast) < ($1.captureDate ?? .distantPast) }
        var bursts: [[Photo]] = []
        var current: [Photo] = []

        for photo in sorted {
            if let last = current.last,
               let lastDate = last.captureDate,
               let thisDate = photo.captureDate,
               thisDate.timeIntervalSince(lastDate) > burstGapThreshold {
                bursts.append(current)
                current = []
            }
            current.append(photo)
        }
        if !current.isEmpty { bursts.append(current) }
        return bursts
    }

    /// Merge adjacent groups if they're within mergeTimeThreshold and visually similar
    private static func mergeAdjacentGroups(
        _ groups: [PhotoGroup],
        featurePrintMap: [UUID: VNFeaturePrintObservation]
    ) -> [PhotoGroup] {
        guard groups.count > 1 else { return groups }

        var merged: [PhotoGroup] = [groups[0]]

        for i in 1..<groups.count {
            let current = groups[i]
            let previous = merged[merged.count - 1]

            let shouldMerge = areGroupsCloseInTime(previous, current) &&
                              areGroupsVisuallySimilar(previous, current, featurePrintMap: featurePrintMap)

            if shouldMerge {
                // Build a new group with combined photos instead of mutating the existing one
                let combined = PhotoGroup(photos: previous.photos + current.photos)
                merged[merged.count - 1] = combined
            } else {
                merged.append(current)
            }
        }

        return merged
    }

    private static func areGroupsCloseInTime(_ a: PhotoGroup, _ b: PhotoGroup) -> Bool {
        guard let aLast = a.photos.last?.captureDate,
              let bFirst = b.photos.first?.captureDate else { return false }
        return abs(bFirst.timeIntervalSince(aLast)) <= mergeTimeThreshold
    }

    private static func areGroupsVisuallySimilar(
        _ a: PhotoGroup,
        _ b: PhotoGroup,
        featurePrintMap: [UUID: VNFeaturePrintObservation]
    ) -> Bool {
        // Compare representative photos (first of each group)
        guard let aRep = a.photos.first, let bRep = b.photos.first,
              let aFP = featurePrintMap[aRep.id], let bFP = featurePrintMap[bRep.id]
        else { return false }

        var distance: Float = 0
        do {
            try aFP.computeDistance(&distance, to: bFP)
        } catch {
            return false // Incompatible feature prints — treat as not similar
        }
        return distance < similarityThreshold
    }

    private static func generateFeaturePrint(url: URL) async -> VNFeaturePrintObservation? {
        guard let (source, imageIndex) = bestImageSource(for: url) else { return nil }

        // FromImageAlways, never IfAbsent: ImageIO returns the camera's embedded EXIF
        // thumbnail when one exists, which is 160px on Sony bodies — too coarse to tell
        // two similar scenes apart.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, imageIndex, options as CFDictionary) else { return nil }

        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])

        return request.results?.first
    }
}
