import Foundation
import CryptoKit
import AppKit
import UniformTypeIdentifiers

/// The app owns clipboard bytes, unlike files the reader chose. A launch's
/// lease protects pastes still being converted or waiting in an unsaved draft,
/// including from another app instance's sweep after restoration.
struct PastedImageStorage: Sendable {
    let root: URL
    private let lifetime = GenerationLease()
    var generation: String { lifetime.generation }
    var directory: URL { root.appendingPathComponent("PastedImages", isDirectory: true) }
    var prefix: String { "pasted-" + generation + "-" }
    init(root: URL) { self.root = root }
    func write(_ bytes: Data) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try lifetime.acquire(in: directory)
        let file = directory.appendingPathComponent(prefix + UUID().uuidString + ".png")
        try bytes.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }
    /// Copies held by background conversions share ownership with the model.
    /// Acquire before publishing the first image; the kernel releases on crash.
    private final class GenerationLease: @unchecked Sendable {
        let generation = UUID().uuidString
        private let mutex = NSLock()
        private var ownership: WorkspaceLock?
        func acquire(in directory: URL) throws {
            mutex.lock(); defer { mutex.unlock() }
            if ownership == nil { ownership = try WorkspaceLock(url: directory.appendingPathComponent("pasted-" + generation + ".lock")) }
        }
    }
    struct OldFiles: Sendable { let files: [URL]; let leases: [WorkspaceLock] }
    /// Claim abandoned generations before inventory reads. Retain the claims
    /// through deletion so a producer cannot commit and exit after the inventory.
    func oldFiles() throws -> OldFiles {
        guard FileManager.default.fileExists(atPath: directory.path) else { return OldFiles(files: [], leases: []) }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]).filter { file in
            let name = file.lastPathComponent
            guard !name.hasPrefix(prefix), Self.names(in: Data(name.utf8)).contains(name) else { return false }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values.isRegularFile == true && values.isSymbolicLink != true
        }
        let generations = Dictionary(grouping: files) { String($0.lastPathComponent.prefix("pasted-".count + 36)) }
        var abandoned: [URL] = [], leases: [WorkspaceLock] = []
        for (generation, files) in generations {
            guard let lease = try? WorkspaceLock(url: directory.appendingPathComponent(generation + ".lock")) else { continue }
            leases.append(lease); abandoned.append(contentsOf: files)
        }
        // Sidecars stay in place so all contenders use the same lock inode.
        return OldFiles(files: abandoned, leases: leases)
    }
    private static let pattern = try! NSRegularExpression(pattern: "pasted-[A-Fa-f0-9-]{36}-[A-Fa-f0-9-]{36}\\.png")
    static func names(in data: Data) -> Set<String> {
        let text = String(decoding: data, as: UTF8.self) as NSString
        return Set(pattern.matches(in: text as String, range: NSRange(location: 0, length: text.length)).map { text.substring(with: $0.range) })
    }
    /// Filenames contain only ASCII UUIDs, so they survive JSON escaping.
    /// Scan bytes in bounded pieces: queued inputs and old branches both
    /// retain paths, and neither is necessarily on the current history page.
    static func names(inJournal path: String) throws -> Set<String> {
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? file.close() }
        var names: Set<String> = [], tail = Data()
        while let bytes = try file.read(upToCount: 65_536), !bytes.isEmpty {
            try Task.checkCancellation()
            let data = tail + bytes; names.formUnion(Self.names(in: data)); tail = data.suffix(128)
        }
        return names
    }
}

struct PastedImageReferenceToken: Sendable, Equatable { let connection: UUID; let changes: Int64; let version: Int64 }
struct PastedImageReferences: Sendable { let token: PastedImageReferenceToken; let names: Set<String>; let journals: Set<String> }

@MainActor struct ComposerImageImport {
    var isCurrent: () -> Bool = { true }
    var finish: () -> Void = {}
}

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
    /// Count from paste initiation, before conversion, through inspection and
    /// recovery. An edit switch invalidates the destination; queue rewrites
    /// keep the original draft parked and continue to receive its images.
    func beginImageImport(sessionID: String) -> ComposerImageImport {
        guard let view = displays[sessionID] else { return ComposerImageImport(isCurrent: { false }) }
        let target = view.editingMessageID, generation = view.editGeneration
        view.imageImports += 1; attachmentImports += 1
        var finished = false
        return ComposerImageImport(isCurrent: { [weak self, weak view] in
            guard let self, let view else { return false }
            return !self.isShutDown && self.displays[sessionID] === view && view.editingMessageID == target && (target == nil || view.editGeneration == generation)
        }, finish: { [weak self, weak view] in
            guard !finished else { return }; finished = true
            guard let self else { return }
            self.attachmentImports -= 1
            guard let view else { return }
            view.imageImports -= 1
        })
    }
    static let imagesUnsupported = "This chat's model is not known to take images. List \"image\" in the model's catalog `input`, or add \"input\": [\"text\", \"image\"] to the connection's Model capabilities in Settings."
    /// What a chat's model takes: what its connection declares under Model
    /// capabilities, and what the model catalog lists for the model the chat
    /// uses, its own choice or the connection's model. Either one listing
    /// "image" lets images in.
    func modelInput(for chat: ChatRecord) -> Set<String> {
        guard let profile = profiles.first(where: { $0.id == chat.profileID }) else { return [] }
        var kinds = Set(Self.declaredInput(profile))
        if let listed = catalogEntry(for: profile).descriptor(for: TurnOverrides.normalizedModel(chat.model) ?? profile.modelId)?.input {
            kinds.formUnion(listed)
        }
        return kinds
    }
    static func declaredInput(_ profile: ProfileRecord) -> [String] { profile.configuration["input"]?.array?.compactMap(\.string) ?? [] }
    func supportsImages(_ id: String) -> Bool { record(id).map { modelInput(for: $0).contains("image") } ?? false }
    /// A chat's per-turn choices for the helper. When the catalog says the
    /// chat's model takes images and its connection does not, they say so
    /// too, and the helper accepts and sends the chat's images.
    func turnOverrides(for chat: ChatRecord, base: [String: WireValue] = [:]) -> [String: WireValue] {
        var params = TurnOverrides.params(for: chat, base: base)
        if let grants = subagentModels(for: chat) { params["subagentModels"] = grants }
        let kinds = modelInput(for: chat)
        if kinds.contains("image"), let profile = profiles.first(where: { $0.id == chat.profileID }), !Self.declaredInput(profile).contains("image") {
            params["input"] = .array(["text", "image"].filter(kinds.contains).map(WireValue.string))
        }
        return params
    }
    func attachImages(sessionID: String? = nil) {
        guard let id = sessionID ?? selectedID, supportsImages(id), displays[id] != nil else { return }
        // A sheet on the chat's window: choosing a file must not stop the run
        // that is streaming into it.
        if !questions.chooseImageFiles(about: id, { [weak self] urls in
            guard let self, !urls.isEmpty else { return }
            self.attachImageFiles(urls, sessionID: id)
        }) { displays[id]?.notice = PiQuestion.busyNotice }
    }
    /// Images inspected for `view`'s draft. A queued message's rewrite takes
    /// no images: ones that arrive while it is in the composer join the draft
    /// set aside for it, which they were chosen for.
    @discardableResult func receiveAttachments(_ items: [AttachmentRecord], into view: SessionDisplay) -> Bool {
        if let recovery = draftWrites.recoveries[view.id] {
            let importing = beginImageImport(sessionID: view.id)
            Task {
                defer { importing.finish() }
                await recovery.value
                if importing.isCurrent() { receiveAttachments(items, into: view) }
            }
            return true
        }
        // Resolve the destination before checking, without suspending between
        // validation and append. The visible queue rewrite has no images of
        // its own; its parked draft still has the same submission limits.
        let existing = view.queueEditingID != nil ? (view.draftBeforeQueueEdit?.attachments ?? []) : view.attachments
        var room = 16 * 1024 * 1024
        guard existing.count + items.count <= 4, (existing + items).allSatisfy({ image in
            guard image.bytes >= 0, image.bytes <= room else { return false }; room -= image.bytes; return true
        }) else {
            view.notice = "The images could not be attached: a submission supports four images and 16 MiB in total."
            // Streaming snapshots replace composer notices; the error strip stays until dismissed.
            error = view.notice
            return false
        }
        if view.queueEditingID != nil, var before = view.draftBeforeQueueEdit {
            before.attachments = (before.attachments ?? []) + items; view.draftBeforeQueueEdit = before
        } else { view.attachments.append(contentsOf: items) }
        draftChanged(view)
        return true
    }
    /// Shared by the file panel, paste and drag-and-drop.
    func attachImageFiles(_ urls: [URL], sessionID: String? = nil) {
        guard let id = sessionID ?? selectedID, let view = displays[id], !urls.isEmpty else { return }
        guard supportsImages(id) else {
            view.notice = Self.imagesUnsupported; error = Self.imagesUnsupported; return
        }
        let importing = beginImageImport(sessionID: id)
        Task { defer { importing.finish() }; do {
            let items = try await Task.detached { try urls.map(AttachmentRecord.inspect) }.value
            guard importing.isCurrent() else { throw HostError.failure("The draft changed while its image was being prepared. Attach it again.") }
            receiveAttachments(items, into: view)
        } catch { view.notice = error.localizedDescription; self.error = error.localizedDescription } }
    }
    func schedulePastedImageCleanup() {
        guard pastedImageCleanup == nil else { return }
        pastedImageCleanup = Task(priority: .utility) { [weak self] in
            // A failed or changing reference inventory simply defers cleanup
            // until next launch; retaining an orphan is always safe.
            try? await self?.cleanupPastedImages()
        }
    }
    func cleanupPastedImages() async throws {
        guard let store, pastedImageCleanupIsSafe else { return }
        let storage = pastedImages, read = pastedImageRead
        let candidates = try await Task.detached(priority: .utility) { try storage.oldFiles() }.value
        defer { withExtendedLifetime(candidates) {} }
        let files = candidates.files
        guard !files.isEmpty else { return }
        let inventory = try await store.pastedImageReferences(root: root)
        let scan = Task.detached(priority: .utility) {
            var names = inventory.names
            let candidates = Set(files.map(\.lastPathComponent))
            for path in inventory.journals {
                try Task.checkCancellation()
                if candidates.isSubset(of: names) { break }
                names.formUnion(try read(path))
            }
            return names
        }
        var names = try await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() }
        guard try await store.pastedImageReferencesUnchanged(inventory.token), pastedImageCleanupIsSafe else { return }
        // From this check through unlink, no MainActor suspension: typing,
        // imports and sends cannot acquire a new local reference in between.
        for view in displays.values {
            names.formUnion(PastedImageStorage.names(in: try JSONEncoder().encode(view.savedDraft)))
            names.formUnion(view.attachments.map { URL(fileURLWithPath: $0.path).lastPathComponent })
            for draft in [view.draftBeforeEdit, view.draftBeforeQueueEdit].compactMap({ $0 }) {
                names.formUnion(PastedImageStorage.names(in: try JSONEncoder().encode(draft)))
            }
        }
        for file in files where !names.contains(file.lastPathComponent) && FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }
    private var pastedImageCleanupIsSafe: Bool {
        !Task.isCancelled && !isShutDown && !launching && !installPreparing && !hasActiveWork && attachmentImports == 0 &&
            draftWrites.tasks.isEmpty && draftWrites.recoveries.isEmpty && sideDraftTransfers.isEmpty && hostStarts.isEmpty && sessionOpenings.isEmpty &&
            !sides.values.contains(where: \.keeping)
    }
}
