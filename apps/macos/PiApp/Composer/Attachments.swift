import Foundation
import CryptoKit
import AppKit
import UniformTypeIdentifiers

struct AttachmentRecord: Codable, Sendable, Identifiable, Hashable {
    let id: String; let path: String; let sha256: String; let bytes: Int; let mimeType: String
    var wire: WireValue { .object(["id": .string(id), "path": .string(path), "sha256": .string(sha256), "bytes": .number(Double(bytes)), "mimeType": .string(mimeType)]) }
    static func inspect(_ url: URL) throws -> Self {
        let canonical = url.resolvingSymlinksInPath(), values = try canonical.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey])
        guard values.isRegularFile == true, let expected = values.fileSize, expected > 0, expected <= 8 * 1024 * 1024 else { throw HostError.failure("Select a regular image file up to 8 MiB") }
        let handle = try FileHandle(forReadingFrom: canonical); defer { try? handle.close() }
        var hasher = SHA256(), count = 0, header = Data()
        while let data = try handle.read(upToCount: 65_536), !data.isEmpty {
            count += data.count; guard count <= expected else { throw HostError.failure("Image changed during selection") }
            if header.isEmpty { header = data.prefix(12) }; hasher.update(data: data)
        }
        let after = try canonical.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard count == expected, after.fileSize == values.fileSize, after.contentModificationDate == values.contentModificationDate else { throw HostError.failure("Image changed; select it again") }
        let mime: String
        if header.starts(with: [137,80,78,71,13,10,26,10]) { mime = "image/png" }
        else if header.starts(with: [255,216,255]) { mime = "image/jpeg" }
        else if String(decoding: header.prefix(6), as: UTF8.self).hasPrefix("GIF8") { mime = "image/gif" }
        else if String(decoding: header.prefix(4), as: UTF8.self) == "RIFF" && String(decoding: header.suffix(4), as: UTF8.self) == "WEBP" { mime = "image/webp" }
        else { throw HostError.failure("Supported image formats are PNG, JPEG, GIF and WebP") }
        return .init(id: UUID().uuidString, path: canonical.path, sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(), bytes: count, mimeType: mime)
    }
}
extension WorkspaceModel {
    func supportsImages(_ id: String) -> Bool { profiles.first(where: { $0.id == record(id)?.profileID })?.configuration["input"]?.array?.contains(.string("image")) == true }
    func attachImages(sessionID: String? = nil) {
        guard let id = sessionID ?? selectedID, supportsImages(id), displays[id] != nil else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]; panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        attachImageFiles(panel.urls, sessionID: id)
    }
    /// Shared by the file panel, paste and drag-and-drop.
    func attachImageFiles(_ urls: [URL], sessionID: String? = nil) {
        guard let id = sessionID ?? selectedID, let view = displays[id], !urls.isEmpty else { return }
        guard supportsImages(id) else { error = "The selected model does not declare image support, so images cannot be attached to this chat."; return }
        Task { do {
            let items = try await Task.detached { try urls.map(AttachmentRecord.inspect) }.value
            guard view.attachments.count + items.count <= 4, (view.attachments + items).reduce(0, { $0 + $1.bytes }) <= 16 * 1024 * 1024 else { throw HostError.failure("A submission supports four images and 16 MiB in total") }
            view.attachments.append(contentsOf: items); draftChanged(view)
        } catch { self.error = error.localizedDescription } }
    }
}
