import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Pi 0.85.1's image processing (coding-agent utils/image-process.ts and
/// image-resize-core.ts) for an image that reaches the model: a format the
/// providers take as it is, otherwise PNG; within 2,000 × 2,000 pixels and
/// 4.5 MB of base64, otherwise resized, trying PNG and then JPEG at falling
/// qualities, and shrunk by a quarter until one fits. Pi resizes with
/// Photon's Lanczos3 filter; ImageIO's high-quality interpolation stands in.
enum PiImage {
    static let maxWidth = 2000, maxHeight = 2000
    /// DEFAULT_MAX_BYTES: 4.5 MB of base64 payload.
    static let maxBytes = 4_718_592
    static let qualities = [80, 85, 70, 55, 40]
    static let resizeFailure = "[Image omitted: could not be resized below the inline image size limit.]"
    static let conversionFailure = "[Image omitted: could not be converted to a supported inline image format.]"

    /// detectSupportedImageMimeType (utils/mime.ts): the image type of a
    /// file's first 4,100 bytes, or nil for anything pi does not read as an
    /// image (JPEG-LS, an animated PNG, a malformed BMP).
    static func sniff(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(4100))
        func ascii(_ offset: Int, _ text: String) -> Bool { b.count >= offset + text.utf8.count && Array(b[offset..<offset + text.utf8.count]) == Array(text.utf8) }
        func u16(_ o: Int) -> Int { o + 1 < b.count ? Int(b[o]) | Int(b[o + 1]) << 8 : 0 }
        func u32le(_ o: Int) -> Int { o + 3 < b.count ? Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 : 0 }
        func u32be(_ o: Int) -> Int { o + 3 < b.count ? Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3]) : 0 }
        if b.starts(with: [0xff, 0xd8, 0xff]) { return b.count > 3 && b[3] == 0xf7 ? nil : "image/jpeg" }
        if b.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) {
            guard b.count >= 16, u32be(8) == 13, ascii(12, "IHDR") else { return nil }
            var offset = 8
            while offset + 8 <= b.count {
                if ascii(offset + 4, "acTL") { return nil }
                if ascii(offset + 4, "IDAT") { break }
                let next = offset + 8 + u32be(offset) + 4
                if next <= offset || next > b.count { break }
                offset = next
            }
            return "image/png"
        }
        if ascii(0, "GIF") { return "image/gif" }
        if ascii(0, "RIFF"), ascii(8, "WEBP") { return "image/webp" }
        if ascii(0, "BM"), b.count >= 26 {
            let size = u32le(2), pixels = u32le(10), header = u32le(14)
            if size != 0 && size < 26 { return nil }
            if pixels < 14 + header { return nil }
            if size != 0 && pixels >= size { return nil }
            let planes: Int, bits: Int
            if header == 12 { planes = u16(22); bits = u16(24) }
            else if (40...124).contains(header), b.count >= 30 { planes = u16(26); bits = u16(28) }
            else { return nil }
            return planes == 1 && [1, 4, 8, 16, 24, 32].contains(bits) ? "image/bmp" : nil
        }
        return nil
    }

    struct Processed: Equatable {
        let data: String, mimeType: String, hints: [String]
    }

    /// processImage: the image to send and pi's hints, or the message pi
    /// shows in its place.
    static func process(_ bytes: Data, mimeType: String) -> Result<Processed, Failure> {
        let base = mimeType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? mimeType.lowercased()
        var source = bytes, type = base, converted: String?
        switch base {
        case "image/png", "image/gif", "image/webp": break
        case "image/jpeg", "image/jpg": type = "image/jpeg"
        default:
            guard let png = pngData(bytes) else { return .failure(Failure(message: conversionFailure)) }
            source = png; type = "image/png"; converted = base
        }
        guard let resized = resize(source, mimeType: type) else { return .failure(Failure(message: resizeFailure)) }
        var hints: [String] = []
        if let converted, converted != resized.mimeType { hints.append("[Image converted from \(converted) to \(resized.mimeType).]") }
        if resized.resized {
            let scale = String(format: "%.2f", Double(resized.originalWidth) / Double(resized.width))
            hints.append("[Image: original \(resized.originalWidth)x\(resized.originalHeight), displayed at \(resized.width)x\(resized.height). Multiply coordinates by \(scale) to map to original image.]")
        }
        return .success(Processed(data: resized.data, mimeType: resized.mimeType, hints: hints))
    }
    struct Failure: Error, Equatable { let message: String }

    struct Resized {
        let data: String, mimeType: String
        let originalWidth: Int, originalHeight: Int, width: Int, height: Int
        let resized: Bool
    }
    /// resizeImageInProcess.
    static func resize(_ bytes: Data, mimeType: String) -> Resized? {
        guard let (width, height) = uprightSize(bytes) else { return nil }
        let base64Size = (bytes.count + 2) / 3 * 4
        if width <= maxWidth, height <= maxHeight, base64Size < maxBytes {
            return Resized(data: bytes.base64EncodedString(), mimeType: mimeType, originalWidth: width, originalHeight: height, width: width, height: height, resized: false)
        }
        guard let image = oriented(bytes) else { return nil }
        var targetWidth = width, targetHeight = height
        if targetWidth > maxWidth { targetHeight = Int((Double(targetHeight * maxWidth) / Double(targetWidth)).rounded()); targetWidth = maxWidth }
        if targetHeight > maxHeight { targetWidth = Int((Double(targetWidth * maxHeight) / Double(targetHeight)).rounded()); targetHeight = maxHeight }
        targetWidth = max(1, targetWidth); targetHeight = max(1, targetHeight)
        while true {
            if let scaled = scale(image, width: targetWidth, height: targetHeight) {
                // Pi's candidates in order, PNG and then each JPEG quality; the first that fits wins.
                let candidates: [(UTType, Int?, String)] = [(.png, nil, "image/png")] + qualities.map { (.jpeg, $0, "image/jpeg") }
                for (format, quality, type) in candidates {
                    guard let data = encode(scaled, type: format, quality: quality) else { continue }
                    let encoded = data.base64EncodedString()
                    if encoded.utf8.count < maxBytes {
                        return Resized(data: encoded, mimeType: type, originalWidth: width, originalHeight: height, width: targetWidth, height: targetHeight, resized: true)
                    }
                }
            }
            if targetWidth == 1 && targetHeight == 1 { return nil }
            let nextWidth = targetWidth == 1 ? 1 : max(1, targetWidth * 3 / 4)
            let nextHeight = targetHeight == 1 ? 1 : max(1, targetHeight * 3 / 4)
            if nextWidth == targetWidth && nextHeight == targetHeight { return nil }
            targetWidth = nextWidth; targetHeight = nextHeight
        }
    }

    /// The first frame's size once turned upright by its EXIF orientation.
    static func uprightSize(_ bytes: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 && orientation <= 8 ? (height, width) : (width, height)
    }
    /// The first frame, turned upright by its EXIF orientation (applyExifOrientation).
    static func oriented(_ bytes: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(width, height), kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
    static func scale(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        if image.width == width && image.height == height { return image }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
    static func encode(_ image: CGImage, type: UTType, quality: Int?) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        var options: [CFString: Any] = [:]
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = Double(quality) / 100 }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
    /// convertImageBytesToPng.
    static func pngData(_ bytes: Data) -> Data? {
        guard let image = oriented(bytes) else { return nil }
        return encode(image, type: .png, quality: nil)
    }

    /// normalizeToolResultImages: each image block processed; one that
    /// cannot be is kept as the tool returned it, and pi's hints follow an
    /// image that changed.
    static func normalize(_ blocks: [JSON]) -> [JSON] {
        var result: [JSON] = []
        for block in blocks {
            guard block["type"].text == "image", let data = block["data"].text, let bytes = Data(base64Encoded: data), let mime = block["mimeType"].text,
                  case .success(let processed) = process(bytes, mimeType: mime) else { result.append(block); continue }
            if processed.data == data && processed.mimeType == mime && processed.hints.isEmpty { result.append(block); continue }
            result.append(["type": "image", "data": JSON(processed.data), "mimeType": JSON(processed.mimeType)])
            if !processed.hints.isEmpty { result.append(textBlock(processed.hints.joined(separator: "\n"))) }
        }
        return result
    }
}
