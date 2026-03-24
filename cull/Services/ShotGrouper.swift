import Vision
import ImageIO

struct ShotGrouper {
    /// Time gap threshold for temporal clustering (seconds)
    static let timeGapThreshold: TimeInterval = 30

    /// Threshold for merging adjacent temporal clusters (seconds)
    /// Groups within this time window get merged if visually similar
    static let mergeTimeThreshold: TimeInterval = 5

    /// Feature print distance threshold for visual similarity (Revision 2, macOS 14+)
    static let similarityThreshold: Float = 0.35

    /// Full grouping: temporal + visual similarity + merge close shots
    static func group(photos: [Photo], progress: (@Sendable (Double) async -> Void)? = nil) async -> [PhotoGroup] {
        guard !photos.isEmpty else { return [] }

        // Step 1: Temporal clustering
        let timeClusters = clusterByTime(photos)
        let totalWork = Double(photos.count)
        var completed = 0.0

        // Step 2: Generate feature prints for all photos (batched to report smooth progress)
        let fpWork: [(UUID, URL)] = photos.map { ($0.id, $0.url) }
        var featurePrintMap: [UUID: VNFeaturePrintObservation] = [:]
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

        // Step 3: Sub-cluster by visual similarity within each time cluster
        var groups: [PhotoGroup] = []
        for cluster in timeClusters {
            if cluster.count <= 1 {
                groups.append(PhotoGroup(photos: cluster))
                continue
            }

            let fps = cluster.compactMap { photo -> (Photo, VNFeaturePrintObservation)? in
                guard let fp = featurePrintMap[photo.id] else { return nil }
                return (photo, fp)
            }

            if fps.isEmpty {
                groups.append(PhotoGroup(photos: cluster))
                continue
            }

            let subGroups = clusterByVisualSimilarity(fps, allPhotos: cluster)
            groups.append(contentsOf: subGroups)
        }

        // Step 4: Merge adjacent groups that are very close in time AND visually similar
        groups = mergeAdjacentGroups(groups, featurePrintMap: featurePrintMap)

        return groups
    }

    private static func clusterByTime(_ photos: [Photo]) -> [[Photo]] {
        let sorted = photos.sorted { ($0.captureDate ?? .distantPast) < ($1.captureDate ?? .distantPast) }
        var clusters: [[Photo]] = []
        var current: [Photo] = []

        for photo in sorted {
            if let last = current.last,
               let lastDate = last.captureDate,
               let thisDate = photo.captureDate,
               thisDate.timeIntervalSince(lastDate) > timeGapThreshold {
                clusters.append(current)
                current = []
            }
            current.append(photo)
        }
        if !current.isEmpty { clusters.append(current) }
        return clusters
    }

    private static func clusterByVisualSimilarity(
        _ featurePrints: [(Photo, VNFeaturePrintObservation)],
        allPhotos: [Photo]
    ) -> [PhotoGroup] {
        var assigned = Set<UUID>()
        var groups: [PhotoGroup] = []

        for (i, (photo, fp)) in featurePrints.enumerated() {
            guard !assigned.contains(photo.id) else { continue }

            var cluster = [photo]
            assigned.insert(photo.id)

            for j in (i + 1)..<featurePrints.count {
                let (otherPhoto, otherFP) = featurePrints[j]
                guard !assigned.contains(otherPhoto.id) else { continue }

                var distance: Float = 0
                try? fp.computeDistance(&distance, to: otherFP)

                if distance < similarityThreshold {
                    cluster.append(otherPhoto)
                    assigned.insert(otherPhoto.id)
                }
            }

            groups.append(PhotoGroup(photos: cluster))
        }

        // Add any photos that failed feature print generation
        let ungrouped = allPhotos.filter { !assigned.contains($0.id) }
        if !ungrouped.isEmpty {
            groups.append(PhotoGroup(photos: ungrouped))
        }

        return groups
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
                // Merge into previous
                previous.photos.append(contentsOf: current.photos)
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
        try? aFP.computeDistance(&distance, to: bFP)
        return distance < similarityThreshold
    }

    private static func generateFeaturePrint(url: URL) async -> VNFeaturePrintObservation? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])

        return request.results?.first
    }
}
