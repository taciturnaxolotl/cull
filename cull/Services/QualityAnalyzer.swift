import CoreImage
import Metal
import MetalPerformanceShaders
import Vision

struct QualityAnalyzer {
    static func analyzeBlur(imageURL: URL) async -> Double? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }

        let ciImage: CIImage?
        if let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceShouldCache: false,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                ciImage = CIImage(cgImage: cgImage)
            } else {
                ciImage = nil
            }
        } else {
            ciImage = nil
        }

        guard let ci = ciImage,
              let cgImage = CIContext().createCGImage(ci, from: ci.extent)
        else { return nil }

        let width = cgImage.width
        let height = cgImage.height

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: width, height: height, mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead, .shaderWrite]

        guard let sourceTexture = device.makeTexture(descriptor: textureDescriptor),
              let laplacianTexture = device.makeTexture(descriptor: textureDescriptor)
        else { return nil }

        // Convert to grayscale float texture
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 32, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue).rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let data = context.data else { return nil }
        sourceTexture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: width * 4
        )

        // Laplacian + variance
        guard let commandQueue = device.makeCommandQueue(),
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return nil }

        let laplacian = MPSImageLaplacian(device: device)
        laplacian.encode(commandBuffer: commandBuffer, sourceTexture: sourceTexture, destinationTexture: laplacianTexture)

        let varianceDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: 2, height: 1, mipmapped: false
        )
        varianceDesc.usage = [.shaderRead, .shaderWrite]
        guard let varianceTexture = device.makeTexture(descriptor: varianceDesc) else { return nil }

        let stats = MPSImageStatisticsMeanAndVariance(device: device)
        stats.encode(commandBuffer: commandBuffer, sourceTexture: laplacianTexture, destinationTexture: varianceTexture)

        commandBuffer.commit()
        await commandBuffer.completed()

        var result = [Float](repeating: 0, count: 2)
        varianceTexture.getBytes(
            &result,
            bytesPerRow: 8,
            from: MTLRegionMake2D(0, 0, 2, 1),
            mipmapLevel: 0
        )

        return Double(result[1]) // variance = sharpness score
    }

    static func analyzeFaceQuality(imageURL: URL) async -> Double? {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024,
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let request = VNDetectFaceCaptureQualityRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])

        guard let results = request.results, !results.isEmpty else { return nil }
        return results.map { Double($0.faceCaptureQuality ?? 0) }.max()
    }

    static func analyze(photo: Photo) async {
        async let blur = analyzeBlur(imageURL: photo.pairedURL ?? photo.url)
        async let face = analyzeFaceQuality(imageURL: photo.pairedURL ?? photo.url)

        let (blurResult, faceResult) = await (blur, face)
        await MainActor.run {
            photo.blurScore = blurResult
            photo.faceQualityScore = faceResult
        }
    }
}
