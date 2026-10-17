import AppKit
import Combine
import PDFKit
import ImageIO
import Darwin

@MainActor final class FilePreview: ObservableObject {
    private final class PDF: @unchecked Sendable { let document: PDFDocument; init(_ document: PDFDocument) { self.document = document } }
    private final class Bitmap: @unchecked Sendable { let image: CGImage; init(_ image: CGImage) { self.image = image } }
    private struct Fingerprint: Equatable, Sendable {
        let device: Int64, inode: UInt64, size: Int64
        let modified: Int64, modifiedNanoseconds: Int, changed: Int64, changedNanoseconds: Int
        init(_ value: stat) {
            device = Int64(value.st_dev); inode = UInt64(value.st_ino); size = Int64(value.st_size)
            modified = Int64(value.st_mtimespec.tv_sec); modifiedNanoseconds = value.st_mtimespec.tv_nsec
            changed = Int64(value.st_ctimespec.tv_sec); changedNanoseconds = value.st_ctimespec.tv_nsec
        }
    }
    private enum Content: Sendable { case pdf(PDF), image(Bitmap), failed(String), unchanged, cancelled }
    private struct Reading: Sendable { let fingerprint: Fingerprint?; let content: Content }
    let url: URL
    @Published private(set) var image: NSImage?
    @Published private(set) var pdf: PDFDocument?
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    var changed: (() -> Void)?
    private var task: Task<Void, Never>?
    private var loadAgain = false
    var readingTask: Task<Void, Never>? { task }
    private var fingerprint: Fingerprint?
    private var token = 0
    private var madePDFView: PDFView?
    private var suspended = false
    private var savedPage: Int?
    /// Held before decoding by generated-file lifecycle regressions.
    var beforeDecode: (@Sendable () async -> Void)?
    private(set) var decodeStarts = 0
    var hasPDFView: Bool { madePDFView != nil }
    var pdfView: PDFView {
        if let madePDFView { return madePDFView }
        let view = PDFView(frame: .zero)
        view.autoScales = true; view.displayMode = .singlePageContinuous
        view.backgroundColor = .piSurfaceSunken
        madePDFView = view
        return view
    }
    init(url: URL) { self.url = url.standardizedFileURL.resolvingSymlinksInPath() }
    nonisolated static func kind(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "pdf": return "pdf"
        case "png", "jpg", "jpeg", "gif", "heic", "tiff", "tif", "webp", "bmp": return "image"
        default: return nil
        }
    }
    func load() {
        guard !suspended else { return }
        // Folder activity must not retire a decode that is still running.
        // Check again after publication so a save during it is followed too.
        guard task == nil else { loadAgain = true; return }
        loadAgain = false
        token &+= 1
        let token = token, url = url, previous = error == nil ? fingerprint : nil
        loading = image == nil && pdf == nil
        let before = beforeDecode
        task = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { [weak self] () -> Reading in
                await before?()
                guard !Task.isCancelled else { return Reading(fingerprint: nil, content: .cancelled) }
                guard url.resolvingSymlinksInPath().path == url.path else {
                    return Reading(fingerprint: nil, content: .failed("The file's path changed. Open it again to check its location."))
                }
                var attributes = stat()
                let fingerprint = stat(url.path, &attributes) == 0 ? Fingerprint(attributes) : nil
                if let fingerprint, fingerprint == previous { return Reading(fingerprint: fingerprint, content: .unchanged) }
                guard !Task.isCancelled else { return Reading(fingerprint: nil, content: .cancelled) }
                await self?.noteDecodeStart()
                guard !Task.isCancelled else { return Reading(fingerprint: nil, content: .cancelled) }
                if Self.kind(for: url) == "pdf", let document = PDFDocument(url: url) {
                    return Reading(fingerprint: fingerprint, content: .pdf(PDF(document)))
                }
                if Self.kind(for: url) == "image",
                   let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                   let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2_048,
                        kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
                    return Reading(fingerprint: fingerprint, content: .image(Bitmap(image)))
                }
                return Reading(fingerprint: fingerprint, content: .failed("The file could not be previewed."))
            }
            let reading = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled, self.token == token else { return }
            self.loading = false; self.task = nil
            defer { if self.loadAgain { self.load() } }
            switch reading.content {
            case .pdf(let loaded):
                let index = self.madePDFView.flatMap { view in view.currentPage.flatMap { view.document?.index(for: $0) } } ?? self.savedPage
                self.pdf = loaded.document; self.image = nil; self.error = nil
                if let view = self.madePDFView {
                    view.document = loaded.document
                    if let index, let page = loaded.document.page(at: min(index, max(0, loaded.document.pageCount - 1))) { view.go(to: page) }
                }
            case .image(let loaded):
                // Keep the decoded pixels as the representation. NSImage's
                // CGImage initializer can create a display-scale snapshot
                // whose pixel dimensions exceed the thumbnail limit.
                let bitmap = NSBitmapImageRep(cgImage: loaded.image)
                let image = NSImage(size: bitmap.size)
                image.addRepresentation(bitmap)
                self.image = image; self.pdf = nil; self.error = nil
            case .failed(let reason): self.error = reason
            case .unchanged, .cancelled: return
            }
            self.fingerprint = reading.fingerprint
            self.changed?()
        }
    }
    private func noteDecodeStart() { decodeStarts += 1 }
    func suspend() {
        suspended = true; token &+= 1; task?.cancel(); task = nil; loadAgain = false; loading = false
        savedPage = madePDFView.flatMap { view in view.currentPage.flatMap { view.document?.index(for: $0) } } ?? savedPage
        image = nil; pdf = nil; madePDFView?.document = nil; fingerprint = nil
    }
    func resume() { guard suspended else { return }; suspended = false; load() }
    func close() { suspend(); madePDFView = nil; savedPage = nil }
}

