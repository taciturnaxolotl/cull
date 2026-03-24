import Accelerate
import CoreImage
import ImageIO
import Vision

struct QualityAnalyzer {

    /// Laplacian variance sharpness detection using Accelerate (vDSP).
    /// Uses Apple's recommended 8-connected Laplacian kernel for better edge sensitivity.
    static func analyzeBlur(imageURL: URL) async -> Double? {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

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
        let quality: Double?
        let regions: [CGRect]
    }

    static func analyzeFaces(imageURL: URL) async -> FaceResult {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else {
            return FaceResult(quality: nil, regions: [])
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024,
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return FaceResult(quality: nil, regions: [])
        }

        let request = VNDetectFaceCaptureQualityRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])

        guard let results = request.results, !results.isEmpty else {
            return FaceResult(quality: nil, regions: [])
        }

        // Filter out small background faces and low-confidence detections
        let meaningful = results.filter { face in
            let area = face.boundingBox.width * face.boundingBox.height
            // Must be at least 1.5% of image area and have decent confidence
            guard area >= 0.015, face.confidence >= 0.5 else { return false }
            // Skip very low quality faces (blurry background people)
            if let q = face.faceCaptureQuality, q < 0.15 { return false }
            return true
        }

        let quality = meaningful.map { Double($0.faceCaptureQuality ?? 0) }.max()
        // Sort faces by size (largest first) for better cycling order
        let regions = meaningful
            .map(\.boundingBox)
            .sorted { $0.width * $0.height > $1.width * $1.height }

        return FaceResult(quality: quality, regions: regions)
    }

    static func analyze(photo: Photo) async {
        let url = photo.pairedURL ?? photo.url
        async let blur = analyzeBlur(imageURL: url)
        async let faces = analyzeFaces(imageURL: url)

        let (blurResult, faceResult) = await (blur, faces)
        await MainActor.run {
            photo.blurScore = blurResult
            photo.faceQualityScore = faceResult.quality
            photo.faceRegions = faceResult.regions
        }
    }
}
