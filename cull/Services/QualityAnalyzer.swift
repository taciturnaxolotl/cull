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
    }

    static func analyzeFaces(imageURL: URL) async -> FaceResult {
        guard let (source, imageIndex) = sourceForAnalysis(imageURL) else {
            return FaceResult(sharpness: nil, regions: [])
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024,
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, imageIndex, options as CFDictionary) else {
            return FaceResult(sharpness: nil, regions: [])
        }

        let request = VNDetectFaceCaptureQualityRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])

        guard let results = request.results, !results.isEmpty else {
            return FaceResult(sharpness: nil, regions: [])
        }

        // Filter out small background faces and low-confidence detections
        let meaningful = results.filter { face in
            let area = face.boundingBox.width * face.boundingBox.height
            guard area >= 0.015, face.confidence >= 0.5 else { return false }
            return true
        }

        guard !meaningful.isEmpty else {
            return FaceResult(sharpness: nil, regions: [])
        }

        // Sort faces by size (largest first) for better cycling order
        let regions = meaningful
            .map(\.boundingBox)
            .sorted { $0.width * $0.height > $1.width * $1.height }

        // Measure sharpness directly on the largest face crop
        // This is what actually matters — is the face in focus?
        let bestFaceRect = regions[0]
        let imageW = CGFloat(cgImage.width)
        let imageH = CGFloat(cgImage.height)
        // Vision rect (bottom-left origin) → pixel rect (top-left origin), padded 20%
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

        return FaceResult(sharpness: faceSharpness, regions: regions)
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
        }
    }
}
