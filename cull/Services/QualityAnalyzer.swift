import CoreImage
import ImageIO
import Vision

struct QualityAnalyzer {

    /// Bump when the analysis changes in a way that invalidates stored results.
    /// Workspaces record the version they were analyzed with and re-run on mismatch,
    /// so a fix doesn't leave existing projects sitting on bad scores.
    ///
    /// 2: analyze the real image instead of the embedded EXIF thumbnail, and accept
    ///    the smaller faces typical of event photography
    /// 3: drop focus scoring entirely; faces and blink detection only
    /// 5: order faces as a left-to-right sweep rather than by size, so cycling doesn't hop
    static let analysisVersion = 5

    /// For RAW files, find the best image index to analyze.
    /// Delegates to ShotGrouper.bestImageSource which finds the largest embedded preview.
    private static func sourceForAnalysis(_ url: URL) -> (CGImageSource, Int)? {
        ShotGrouper.bestImageSource(for: url)
    }

    struct FaceResult {
        let regions: [CGRect]
        /// Per-face Eye Aspect Ratio, parallel to regions (0 = closed, ~0.3 = wide open)
        let eyeAspectRatios: [Double]
    }

    /// Pixel size the face pass runs at. Detection rate plateaus above this, and it
    /// keeps faces large enough for the landmark pass to read eyelids reliably:
    /// a typical event-photo face lands around 75px wide here versus 49px at 1024.
    private static let faceAnalysisSize = 1600

    /// Smallest face worth reporting, as a fraction of frame area. Faces in event and
    /// group photos run ~0.3% of the frame; a portrait-sized threshold discards
    /// essentially all of them.
    private static let minimumFaceArea: CGFloat = 0.001

    static func analyzeFaces(imageURL: URL) async -> FaceResult {
        guard let (source, imageIndex) = sourceForAnalysis(imageURL) else {
            return FaceResult(regions: [], eyeAspectRatios: [])
        }
        // FromImageAlways, never IfAbsent: cameras embed a tiny EXIF thumbnail (160px on
        // Sony bodies) and ImageIO hands that back instead of downsizing the real image,
        // which is far too small to find faces in.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: faceAnalysisSize,
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, imageIndex, options as CFDictionary) else {
            return FaceResult(regions: [], eyeAspectRatios: [])
        }

        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        let landmarksRequest = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([qualityRequest, landmarksRequest])

        guard let results = qualityRequest.results, !results.isEmpty else {
            return FaceResult(regions: [], eyeAspectRatios: [])
        }

        // Filter out small background faces and low-confidence detections
        let meaningful = results.filter { face in
            let area = face.boundingBox.width * face.boundingBox.height
            guard area >= minimumFaceArea, face.confidence >= 0.5 else { return false }
            return true
        }

        guard !meaningful.isEmpty else {
            return FaceResult(regions: [], eyeAspectRatios: [])
        }

        // Order faces left to right so cycling through them sweeps across the frame
        let regions = travelOrdered(meaningful.map(\.boundingBox))

        // Build per-face EAR map keyed by bounding box
        var earByBox: [CGRect: Double] = [:]
        if let landmarkResults = landmarksRequest.results {
            for face in landmarkResults {
                if let landmarks = face.landmarks {
                    let leftEAR = eyeAspectRatio(landmarks.leftEye)
                    let rightEAR = eyeAspectRatio(landmarks.rightEye)
                    if let l = leftEAR, let r = rightEAR {
                        earByBox[face.boundingBox] = (l + r) / 2.0
                    }
                }
            }
        }

        // Map to sorted regions order
        let eyeAspectRatios = regions.map { box in
            earByBox.first { closeEnough($0.key, box) }?.value ?? 0.3
        }

        return FaceResult(regions: regions, eyeAspectRatios: eyeAspectRatios)
    }

    /// Orders faces into a sweep across the frame: start at the leftmost, then repeatedly
    /// step to the nearest face not yet visited.
    ///
    /// Reads left to right like a plain x-sort when faces sit in a line, but handles rows
    /// properly — in a two-row group photo an x-sort bounces between the back and front
    /// row on every step, while this walks one row and comes back along the other.
    /// Starting anywhere but the leftmost (the largest face, say) makes it double back.
    private static func travelOrdered(_ boxes: [CGRect]) -> [CGRect] {
        let leftToRight = boxes.sorted {
            $0.midX != $1.midX ? $0.midX < $1.midX : $0.midY > $1.midY
        }
        guard leftToRight.count > 2 else { return leftToRight }

        var remaining = leftToRight
        var ordered = [remaining.removeFirst()]
        while !remaining.isEmpty {
            let from = ordered[ordered.count - 1]
            var nearestIndex = 0
            var nearestDistance = CGFloat.greatestFiniteMagnitude
            for (i, box) in remaining.enumerated() {
                let d = hypot(box.midX - from.midX, box.midY - from.midY)
                if d < nearestDistance {
                    nearestDistance = d
                    nearestIndex = i
                }
            }
            ordered.append(remaining.remove(at: nearestIndex))
        }
        return ordered
    }

    /// Bounding boxes from different Vision requests may differ slightly
    private static func closeEnough(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.origin.x - b.origin.x) < 0.01 &&
        abs(a.origin.y - b.origin.y) < 0.01 &&
        abs(a.width - b.width) < 0.01 &&
        abs(a.height - b.height) < 0.01
    }

    /// Eye Aspect Ratio (EAR) from Vision landmark points.
    /// Uses vertical vs horizontal distances to detect closed eyes.
    /// Returns nil if landmarks are unavailable.
    private static func eyeAspectRatio(_ eye: VNFaceLandmarkRegion2D?) -> Double? {
        guard let eye, eye.pointCount >= 6 else { return nil }
        let pts = eye.normalizedPoints
        // Vision eye landmarks: roughly ordered as outer corner, top points, inner corner, bottom points
        // For 6-point eyes: 0=outer, 1=top-outer, 2=top-inner, 3=inner, 4=bottom-inner, 5=bottom-outer
        // For 8-point eyes: 0=outer, 1=top-outer, 2=top, 3=top-inner, 4=inner, 5=bottom-inner, 6=bottom, 7=bottom-outer
        let count = eye.pointCount
        if count == 6 {
            let vertical1 = distance(pts[1], pts[5])
            let vertical2 = distance(pts[2], pts[4])
            let horizontal = distance(pts[0], pts[3])
            guard horizontal > 0 else { return nil }
            return Double((vertical1 + vertical2) / (2.0 * horizontal))
        } else if count >= 8 {
            let vertical1 = distance(pts[1], pts[7])
            let vertical2 = distance(pts[2], pts[6])
            let vertical3 = distance(pts[3], pts[5])
            let horizontal = distance(pts[0], pts[4])
            guard horizontal > 0 else { return nil }
            return Double((vertical1 + vertical2 + vertical3) / (3.0 * horizontal))
        }
        return nil
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    static func analyze(photo: Photo) async {
        let faceResult = await analyzeFaces(imageURL: photo.imageURL)
        await MainActor.run {
            photo.faceRegions = faceResult.regions
            photo.eyeAspectRatios = faceResult.eyeAspectRatios
        }
    }
}
