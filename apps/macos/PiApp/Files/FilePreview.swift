import SwiftUI
import PDFKit
import ImageIO

@MainActor final class FilePreview: ObservableObject {
    private final class PDF: @unchecked Sendable { let document: PDFDocument; init(_ document: PDFDocument) { self.document = document } }
    private final class Bitmap: @unchecked Sendable { let image: CGImage; init(_ image: CGImage) { self.image = image } }
    private struct Fingerprint: Equatable, Sendable { let modified: Date?; let size: UInt64; let inode: UInt64 }
    private enum Content: Sendable { case pdf(PDF), image(Bitmap), failed(String), unchanged }
    private struct Reading: Sendable { let fingerprint: Fingerprint?; let content: Content }
    let url: URL
    @Published private(set) var image: NSImage?
    @Published private(set) var pdf: PDFDocument?
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    var changed: (() -> Void)?
    private var task: Task<Void, Never>?
    private var fingerprint: Fingerprint?
    private var token = 0
    private var madePDFView: PDFView?
    var pdfView: PDFView {
        if let madePDFView { return madePDFView }
        let view = PDFView(frame: .zero)
        view.autoScales = true; view.displayMode = .singlePageContinuous
        view.backgroundColor = .piContent
        madePDFView = view
        return view
    }
    init(url: URL) { self.url = url }
    nonisolated static func kind(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "pdf": return "pdf"
        case "png", "jpg", "jpeg", "gif", "heic", "tiff", "tif", "webp", "bmp": return "image"
        default: return nil
        }
    }
    func load() {
        token &+= 1
        let token = token, url = url, previous = fingerprint
        task?.cancel()
        loading = image == nil && pdf == nil
        task = Task { [weak self] in
            let reading = await Task.detached(priority: .userInitiated) { () -> Reading in
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                let fingerprint = attributes.map { Fingerprint(modified: $0[.modificationDate] as? Date,
                    size: ($0[.size] as? NSNumber)?.uint64Value ?? 0, inode: ($0[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0) }
                if let fingerprint, fingerprint == previous { return Reading(fingerprint: fingerprint, content: .unchanged) }
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
            }.value
            guard let self, !Task.isCancelled, self.token == token else { return }
            self.loading = false; self.task = nil
            switch reading.content {
            case .pdf(let loaded):
                let index = self.madePDFView.flatMap { view in view.currentPage.flatMap { view.document?.index(for: $0) } }
                self.pdf = loaded.document; self.image = nil; self.error = nil
                if let view = self.madePDFView {
                    view.document = loaded.document
                    if let index, let page = loaded.document.page(at: min(index, max(0, loaded.document.pageCount - 1))) { view.go(to: page) }
                }
            case .image(let loaded): self.image = NSImage(cgImage: loaded.image, size: .zero); self.pdf = nil; self.error = nil
            case .failed(let reason): self.error = reason
            case .unchanged: return
            }
            self.fingerprint = reading.fingerprint
            self.changed?()
        }
    }
    func suspend() { token &+= 1; task?.cancel(); task = nil; loading = false }
    func close() { suspend(); image = nil; pdf = nil; madePDFView?.document = nil; madePDFView = nil; fingerprint = nil }
}

struct FilePreviewContent: View {
    @ObservedObject var preview: FilePreview
    var body: some View {
        Group {
            if let error = preview.error {
                Text(error).font(PiFont.body).foregroundStyle(Color.piInkSecondary).padding(PiSpacing.lg)
            } else if let pdf = preview.pdf {
                FilePDFHost(view: preview.pdfView, document: pdf)
            } else if let image = preview.image {
                Image(nsImage: image).resizable().scaledToFit().padding(PiSpacing.lg)
                    .accessibilityLabel(preview.url.lastPathComponent)
            } else { PiSpinner(size: 18) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.piContent)
        .onAppear { preview.load() }
    }
}

private struct FilePDFHost: NSViewRepresentable {
    let view: PDFView
    let document: PDFDocument
    func makeNSView(context: Context) -> TabContentContainerPlain {
        if view.document !== document { view.document = document }
        let container = TabContentContainerPlain(); container.place(view); return container
    }
    func updateNSView(_ container: TabContentContainerPlain, context: Context) {
        if view.document !== document { view.document = document }
        if view.superview !== container { container.place(view) }
    }
}
