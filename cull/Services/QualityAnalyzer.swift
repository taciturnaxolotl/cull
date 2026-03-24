import Accelerate
import CoreImage
import ImageIO
import Vision

struct QualityAnalyzer {

    /// For RAW files, find the best image index to analyze.
    /// RAW files embed JPEG previews (with camera sharpening) as secondary images.
    /// Returns (source, imageIndex) so the thumbnail API can extract from the right image.
    private static func sourceForAnalysis(_ url: URL) -> (CGImageSource, Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let count = CGImageSourceGetCount(source)
        if count > 1 {
            // Find the largest embedded preview (usually a camera-processed JPEG)
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

    /// Laplacian variance sharpness detection using Accelerate (vDSP).
    /// Uses Apple's recommended 8-connected Laplacian kernel for better edge sensitivity.
    static func analyzeBlur(imageURL: URL) async -> Double? {
        guard let (source, imageIndex) = sourceForAnalysis(imageURL) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, imageIndex, options as CFDictionary) else { return nil }

        // Read ISO for noise compensation
        let iso = readISO(from: source)

        guard let variance = laplacianVariance(cgImage) else { return nil }

        // Compensate for high-ISO noise inflating the score
        if let iso, iso > 100 {
            let isoStops = log2(Double(iso) / 100.0)
            let noisePenalty = pow(1.3, isoStops)
            return variance / noisePenalty
        }
        return variance
    }

    /// 8-connected Laplacian variance via vDSP (Apple's recommended approach).
    private static func laplacianVariance(_ cgImage: CGImage) -> Double? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 4, height > 4 else { return nil }

        // Render to 8-bit grayscale
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixelData = context.data else { return nil }

        // Convert UInt8 → Float
        let pixelCount = width * height
        let uint8Ptr = pixelData.assumingMemoryBound(to: UInt8.self)
        var floatPixels = [Float](repeating: 0, count: pixelCount)
        vDSP.convertElements(of: UnsafeBufferPointer(start: uint8Ptr, count: pixelCount), to: &floatPixels)

        // 8-connected Laplacian: [-1,-1,-1; -1,8,-1; -1,-1,-1]
        // More sensitive than 4-connected, detects diagonal edges too
        let kernel: [Float] = [
            -1, -1, -1,
            -1,  8, -1,
            -1, -1, -1
        ]

        // vDSP convolution
        var result = [Float](repeating: 0, count: pixelCount)
        vDSP.convolve(floatPixels,
                      rowCount: height,
                      columnCount: width,
                      with3x3Kernel: kernel,
                      result: &result)

        // Variance via vDSP_normalize (stddev² = variance)
        var mean: Float = 0
        var stddev: Float = 0
        vDSP_normalize(result, 1, nil, 1, &mean, &stddev, vDSP_Length(pixelCount))

        return Double(stddev * stddev)
    }

    /// Read ISO speed from EXIF for noise compensation
    private static func readISO(from source: CGImageSource) -> Int? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let isoArray = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int],
              let iso = isoArray.first
        else { return nil }
        return iso
    }

    struct FaceResult {
        /// Sharpness of the best face region (Laplacian variance on face crop)
        let sharpness: Double?
        let regions: [CGRect]
        /// Per-face Eye Aspect Ratio, parallel to regions (0 = closed, ~0.3 = wide open)
        let eyeAspectRatios: [Double]
    }

    static func analyzeFaces(imageURL: URL) async -> FaceResult {
        guard let (source, imageIndex) = sourceForAnalysis(imageURL) else {
            return FaceResult(sharpness: nil, regions: [], eyeAspectRatios: [])
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024,
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, imageIndex, options as CFDictionary) else {
            return FaceResult(sharpness: nil, regions: [], eyeAspectRatios: [])
        }

        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        let landmarksRequest = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([qualityRequest, landmarksRequest])

        guard let results = qualityRequest.results, !results.isEmpty else {
            return FaceResult(sharpness: nil, regions: [], eyeAspectRatios: [])
        }

        // Filter out small background faces and low-confidence detections
        let meaningful = results.filter { face in
            let area = face.boundingBox.width * face.boundingBox.height
            guard area >= 0.015, face.confidence >= 0.5 else { return false }
            return true
        }

        guard !meaningful.isEmpty else {
            return FaceResult(sharpness: nil, regions: [], eyeAspectRatios: [])
        }

        // Sort faces by size (largest first) for better cycling order
        let regions = meaningful
            .map(\.boundingBox)
            .sorted { $0.width * $0.height > $1.width * $1.height }

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

        // Measure sharpness directly on the largest face crop
        let bestFaceRect = regions[0]
        let imageW = CGFloat(cgImage.width)
        let imageH = CGFloat(cgImage.height)
        let padX = bestFaceRect.width * 0.2
        let padY = bestFaceRect.height * 0.2
        let pixelRect = CGRect(
            x: (bestFaceRect.origin.x - padX) * imageW,
            y: (1 - bestFaceRect.origin.y - bestFaceRect.height - padY) * imageH,
            width: (bestFaceRect.width + padX * 2) * imageW,
            height: (bestFaceRect.height + padY * 2) * imageH
        ).intersection(CGRect(x: 0, y: 0, width: imageW, height: imageH))

        var faceSharpness: Double? = nil
        if pixelRect.width > 10, pixelRect.height > 10,
           let faceCrop = cgImage.cropping(to: pixelRect) {
            faceSharpness = laplacianVariance(faceCrop)
        }

        return FaceResult(sharpness: faceSharpness, regions: regions, eyeAspectRatios: eyeAspectRatios)
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
        let url = photo.imageURL
        async let blur = analyzeBlur(imageURL: url)
        async let faces = analyzeFaces(imageURL: url)

        let (blurResult, faceResult) = await (blur, faces)
        await MainActor.run {
            photo.blurScore = blurResult
            photo.faceSharpness = faceResult.sharpness
            photo.faceRegions = faceResult.regions
            photo.eyeAspectRatios = faceResult.eyeAspectRatios
        }
    }
}
