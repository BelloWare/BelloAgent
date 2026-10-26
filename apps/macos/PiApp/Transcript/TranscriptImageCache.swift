import Foundation
import ImageIO
import CryptoKit
import Darwin

/// Where one user message's encoded images sit. No image data crosses into
/// the transcript window with its history page.
final class TranscriptImageReference: Codable, Hashable, Sendable {
    let path: String
    let id: String
    let offset: UInt64
    let length: Int
    let device: Int32
    let inode: UInt64
    init(path: String, id: String, offset: UInt64, length: Int, device: Int32, inode: UInt64) {
        self.path = path; self.id = id; self.offset = offset; self.length = length; self.device = device; self.inode = inode
    }
    static func == (lhs: TranscriptImageReference, rhs: TranscriptImageReference) -> Bool {
        lhs === rhs || lhs.path == rhs.path && lhs.id == rhs.id && lhs.offset == rhs.offset && lhs.length == rhs.length
            && lhs.device == rhs.device && lhs.inode == rhs.inode
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(path); hasher.combine(id); hasher.combine(offset); hasher.combine(length); hasher.combine(device); hasher.combine(inode)
    }
}

enum TranscriptImageSource: Hashable, Sendable {
    case journal(TranscriptImageReference)
    case attachment(AttachmentRecord)
}

final class TranscriptImageBitmap: @unchecked Sendable {
    let image: CGImage
    var cost: Int { image.bytesPerRow * image.height }
    init(_ image: CGImage) { self.image = image }
}

/// One background decoder, shared by a workspace. The actor serializes
/// transient journal/base64 reads as well as decoding; only downsampled
/// pixels survive a request. The LRU has a hard byte bound.
actor TranscriptImageCache {
    private static let imageLimit = 512
    private struct Key: Hashable { let source: TranscriptImageSource; let index: Int; let pixels: Int }
    private struct Entry { let bitmap: TranscriptImageBitmap; var used: UInt64 }
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    private(set) var retainedBytes = 0
    private(set) var decodeCount = 0
    let byteLimit: Int
    /// Generated-fixture tests observe the actual decoder's executor.
    var willDecode: (@Sendable (Bool) -> Void)?
    func observeDecodes(_ observer: (@Sendable (Bool) -> Void)?) { willDecode = observer }
    init(byteLimit: Int = 16 * 1_048_576) { self.byteLimit = max(0, byteLimit) }

    func image(source: TranscriptImageSource, index: Int, pixels: Int) throws -> TranscriptImageBitmap {
        try Task.checkCancellation()
        guard index >= 0 else { throw StoreError.unreadableRecord }
        let pixels = min(2_048, max(1, pixels))
        let key = Key(source: source, index: index, pixels: pixels)
        clock &+= 1
        if var entry = entries[key] { entry.used = clock; entries[key] = entry; return entry.bitmap }
        willDecode?(Thread.isMainThread)
        decodeCount += 1
        let data = try Self.bytes(source, index: index)
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: pixels,
                kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw HostError.failure("This image could not be previewed.")
        }
        try Task.checkCancellation()
        let bitmap = TranscriptImageBitmap(image)
        if bitmap.cost <= byteLimit {
            while entries.count >= Self.imageLimit || retainedBytes + bitmap.cost > byteLimit, let oldest = entries.min(by: { $0.value.used < $1.value.used }) {
                retainedBytes -= oldest.value.bitmap.cost; entries.removeValue(forKey: oldest.key)
            }
            entries[key] = Entry(bitmap: bitmap, used: clock); retainedBytes += bitmap.cost
        }
        return bitmap
    }

    private struct Record: Decodable {
        let type: String?
        let id: String?
        let message: Message?
        struct Message: Decodable { let role: String?; let content: [Block] }
        struct Block: Decodable { let type: String?; let data: String? }
    }
    private static func bytes(_ source: TranscriptImageSource, index: Int) throws -> Data {
        switch source {
        case .attachment(let attachment):
            guard index == 0, attachment.bytes > 0, attachment.bytes <= SubmissionLimits.imageBytes else { throw StoreError.unreadableRecord }
            let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: attachment.path)); defer { try? file.close() }
            guard let bytes = try file.read(upToCount: attachment.bytes + 1), bytes.count == attachment.bytes,
                  SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == attachment.sha256 else {
                throw HostError.failure("The attached image is missing or changed.")
            }
            return bytes
        case .journal(let reference):
            // The journal may have grown, but replacing it cannot reuse a
            // previous file's offsets. Check the descriptor, then the row id.
            guard reference.length > 0, reference.length <= 64 * 1_048_576 else { throw StoreError.unreadableRecord }
            let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: reference.path)); defer { try? file.close() }
            var attributes = stat()
            guard fstat(file.fileDescriptor, &attributes) == 0, attributes.st_dev == reference.device,
                  UInt64(attributes.st_ino) == reference.inode, attributes.st_mode & S_IFMT == S_IFREG,
                  attributes.st_size >= 0, reference.offset <= UInt64(attributes.st_size),
                  UInt64(reference.length) <= UInt64(attributes.st_size) - reference.offset else { throw StoreError.unreadableRecord }
            try file.seek(toOffset: reference.offset)
            guard let bytes = try file.read(upToCount: reference.length), bytes.count == reference.length else { throw StoreError.unreadableRecord }
            let record = try JSONDecoder().decode(Record.self, from: bytes)
            guard record.type == "message", (record.id ?? "record-\(reference.offset)") == reference.id,
                  let message = record.message, message.role == "user" else { throw StoreError.unreadableRecord }
            let images = message.content.filter { $0.type == "image" }
            guard images.indices.contains(index), let base64 = images[index].data, base64.utf8.count <= 32 * 1_048_576,
                  let data = Data(base64Encoded: base64), !data.isEmpty else { throw StoreError.unreadableRecord }
            return data
        }
    }
}
