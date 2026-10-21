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
            let url = directory.appendingPathComponent("pasted-" + generation + ".lock")
            let lease = try ownership ?? WorkspaceLock(url: url)
            guard lease.matchesFile(at: url) else { throw StoreError.unavailable }
            ownership = lease
        }
    }
    struct OldFiles: Sendable { let files: [URL]; let leases: [String: WorkspaceLock] }
    static let sweepGenerationLimit = 32
    /// Include empty sidecars left by interrupted writes or earlier sweeps.
    /// Listing acquires no descriptors that survive this call.
    func oldGenerations() throws -> [String: [URL]] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [:] }
        var generations: [String: [URL]] = [:], occupied: Set<String> = []
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            let name = file.lastPathComponent
            guard !name.hasPrefix(prefix), name != "pasted-" + generation + ".lock" else { continue }
            // Unknown files, directories and symlinks prevent sidecar retirement.
            if name.hasPrefix("pasted-"), name.dropFirst(43).first == "-" { occupied.insert(String(name.prefix(43))) }
            let image = Self.names(in: Data(name.utf8)).contains(name)
            let sidecar = name.hasPrefix("pasted-") && name.hasSuffix(".lock") && name.count == 48 &&
                UUID(uuidString: String(name.dropFirst(7).dropLast(5))) != nil
            guard image || sidecar else { continue }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let generation = String(name.prefix(43))
            if image { generations[generation, default: []].append(file) }
            else if generations[generation] == nil { generations[generation] = [] }
        }
        return generations.filter { !$0.value.isEmpty || !occupied.contains($0.key) }
    }
    /// A pre-pass can only exclude work. Every claimed generation still needs
    /// a fresh inventory before deletion, with its lease held throughout.
    func claimOldFiles(_ generations: [String: [URL]], excluding names: Set<String>) -> OldFiles {
        var abandoned: [URL] = [], leases: [String: WorkspaceLock] = [:]
        // Spend spare capacity on empty sidecars only after collectable images.
        let ordered = generations.sorted {
            if $0.value.isEmpty != $1.value.isEmpty { return !$0.value.isEmpty }
            return $0.key < $1.key
        }
        for (generation, files) in ordered {
            guard leases.count < Self.sweepGenerationLimit else { break }
            guard files.isEmpty || files.contains(where: { !names.contains($0.lastPathComponent) }) else { continue }
            let url = directory.appendingPathComponent(generation + ".lock")
            guard let lease = try? WorkspaceLock(url: url), lease.matchesFile(at: url) else { continue }
            leases[generation] = lease; abandoned.append(contentsOf: files)
        }
        return OldFiles(files: abandoned, leases: leases)
    }
    func remove(_ candidates: OldFiles, keeping names: Set<String>) throws {
        for file in candidates.files where !names.contains(file.lastPathComponent) {
            let generation = String(file.lastPathComponent.prefix(43)), lock = directory.appendingPathComponent(generation + ".lock")
            guard candidates.leases[generation]?.matchesFile(at: lock) == true else { continue }
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
        // The generation cannot publish again. Keep the lease through unlink,
        // and check fresh directory contents, including unrecognized files.
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        for (generation, lease) in candidates.leases where !remaining.contains(where: { $0.hasPrefix(generation + "-") }) {
            let lock = directory.appendingPathComponent(generation + ".lock")
            if lease.matchesFile(at: lock) { try FileManager.default.removeItem(at: lock) }
        }
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

/// A file ready to attach. A private PNG converted from a file carries that
/// file's name for the composer's chip; one from clipboard bytes has none.
struct PreparedImageFile: Sendable, Equatable {
    let url: URL; var name: String? = nil
}

struct AttachmentRecord: Codable, Sendable, Identifiable, Hashable {
    let id: String; let path: String; let sha256: String; let bytes: Int; let mimeType: String
    /// What the chip shows for a private copy converted from a file: that
    /// file's name. Presentation only: saved with drafts, never sent to the
    /// helper (`wire`), and no part of the record's identity (`==`).
    var name: String? = nil
    var wire: WireValue { .object(["id": .string(id), "path": .string(path), "sha256": .string(sha256), "bytes": .number(Double(bytes)), "mimeType": .string(mimeType)]) }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.path == rhs.path && lhs.sha256 == rhs.sha256 && lhs.bytes == rhs.bytes && lhs.mimeType == rhs.mimeType
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id); hasher.combine(path); hasher.combine(sha256); hasher.combine(bytes); hasher.combine(mimeType)
    }
    /// The helper's own test (`loadImages`): the four formats OpenAI takes,
    /// by their first 12 bytes.
    static func mimeType(signature header: Data) -> String? {
        let header = Data(header.prefix(12))
        if header.starts(with: [137,80,78,71,13,10,26,10]) { return "image/png" }
        if header.starts(with: [255,216,255]) { return "image/jpeg" }
        if ["GIF87a", "GIF89a"].contains(String(decoding: header.prefix(6), as: UTF8.self)) { return "image/gif" }
        if String(decoding: header.prefix(4), as: UTF8.self) == "RIFF", String(decoding: header.suffix(4), as: UTF8.self) == "WEBP" { return "image/webp" }
        return nil
    }
    /// Every caller prepares the file first (`ComposerTextView.prepareImageFiles`),
    /// so a refusal here means the file changed after it was prepared.
    static func inspect(_ url: URL) throws -> Self {
        let canonical = url.resolvingSymlinksInPath(), values = try canonical.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey])
        guard values.isRegularFile == true, let expected = values.fileSize, expected > 0, expected <= 8 * 1024 * 1024 else { throw HostError.failure(changed) }
        let handle = try FileHandle(forReadingFrom: canonical); defer { try? handle.close() }
        var hasher = SHA256(), count = 0, header = Data()
        while let data = try handle.read(upToCount: 65_536), !data.isEmpty {
            count += data.count; guard count <= expected else { throw HostError.failure("Image changed during selection") }
            if header.isEmpty { header = data.prefix(12) }; hasher.update(data: data)
        }
        let after = try canonical.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard count == expected, after.fileSize == values.fileSize, after.contentModificationDate == values.contentModificationDate else { throw HostError.failure("Image changed; select it again") }
        guard let mime = mimeType(signature: header) else { throw HostError.failure(changed) }
        return .init(id: UUID().uuidString, path: canonical.path, sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(), bytes: count, mimeType: mime)
    }
    static let changed = "The image changed while it was being attached. Attach it again."
}
extension WorkspaceModel {
    /// Count from paste initiation, before conversion, through inspection and
    /// recovery. An edit switch invalidates the destination; queue rewrites
    /// keep the original draft parked and continue to receive its images.
    func beginImageImport(sessionID: String) -> ComposerImageImport {
        guard !installPreparing, !isShutDown, let view = displays[sessionID] else { return ComposerImageImport(isCurrent: { false }) }
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
            self.importImageFiles(urls, sessionID: id)
        }) { displays[id]?.notice = PiQuestion.busyNotice }
    }
    /// Chosen files take the conversion pasted and dropped ones take
    /// (`ComposerTextView.prepareImageFiles`), off the main thread, counted
    /// as an import from the choice until the images are inspected.
    func importImageFiles(_ urls: [URL], sessionID id: String) {
        guard let view = displays[id], !urls.isEmpty else { return }
        let importing = beginImageImport(sessionID: id), storage = pastedImages
        Task { defer { importing.finish() }; do {
            let prepared = try await Task.detached(priority: .userInitiated) { try ComposerTextView.prepareImageFiles(urls, storage: storage) }.value
            guard importing.isCurrent() else { throw HostError.failure("The draft changed while its image was being prepared. Attach it again.") }
            attachImageFiles(prepared, sessionID: id)
        } catch { view.notice = error.localizedDescription; self.error = error.localizedDescription } }
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
        var room = SubmissionLimits.imageTotalBytes
        guard existing.count + items.count <= SubmissionLimits.images, (existing + items).allSatisfy({ image in
            guard image.bytes >= 0, image.bytes <= room else { return false }; room -= image.bytes; return true
        }) else {
            view.notice = "The images could not be attached: a submission supports four images and \(SubmissionLimits.imageTotalBytes / 1_048_576) MiB in total."
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
    func attachImageFiles(_ urls: [URL], sessionID: String? = nil) {
        attachImageFiles(urls.map { PreparedImageFile(url: $0) }, sessionID: sessionID)
    }
    /// Shared by the file panel, paste and drag-and-drop, once each has
    /// prepared its files.
    func attachImageFiles(_ files: [PreparedImageFile], sessionID: String? = nil) {
        guard let id = sessionID ?? selectedID, let view = displays[id], !files.isEmpty else { return }
        guard supportsImages(id) else {
            view.notice = Self.imagesUnsupported; error = Self.imagesUnsupported; return
        }
        let importing = beginImageImport(sessionID: id)
        guard importing.isCurrent() else { importing.finish(); return }
        let inspect = attachmentInspect
        Task { defer { importing.finish() }; do {
            let items = try await Task.detached {
                try files.map { file in var record = try inspect(file.url); record.name = file.name; return record }
            }.value
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
        let storage = pastedImages
        let generations = try await Task.detached(priority: .utility) { try storage.oldGenerations() }.value
        guard !generations.isEmpty else { return }
        let preliminary = try await store.pastedImageReferences(root: root)
        let retained = try await scanPastedImageReferences(preliminary, files: generations.values.flatMap { $0 })
        guard pastedImageCleanupIsSafe else { return }
        let candidates = await Task.detached(priority: .utility) { storage.claimOldFiles(generations, excluding: retained) }.value
        defer { withExtendedLifetime(candidates) {} }
        guard !candidates.leases.isEmpty else { return }
        let inventory = try await store.pastedImageReferences(root: root)
        var names = try await scanPastedImageReferences(inventory, files: candidates.files)
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
        try storage.remove(candidates, keeping: names)
    }
    private func scanPastedImageReferences(_ inventory: PastedImageReferences, files: [URL]) async throws -> Set<String> {
        let read = pastedImageRead
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
        return try await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() }
    }
    private var pastedImageCleanupIsSafe: Bool {
        !Task.isCancelled && !isShutDown && !launching && !installPreparing && !hasActiveWork && attachmentImports == 0 &&
            draftWrites.tasks.isEmpty && draftWrites.recoveries.isEmpty && sideDraftTransfers.isEmpty && hostStarts.isEmpty && sessionOpenings.isEmpty &&
            !sides.values.contains(where: \.keeping) && !displays.values.contains(where: { $0.draftVersion.hasUnsavedConflict })
    }
}
