import AppKit

enum TranscriptImageMetrics {
    static let side: CGFloat = 64
    static let gap: CGFloat = 6
    static func columns(width: CGFloat) -> Int { max(1, Int((max(0, width) + gap) / (side + gap))) }
    static func height(count: Int, width: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        let rows = (count + columns(width: width) - 1) / columns(width: width)
        return CGFloat(rows) * side + CGFloat(rows - 1) * gap
    }
}

/// Fixed slots under the question, in the composer's surface and outline.
/// Only mounted, visible buttons ask for pixels; arriving pixels redraw the
/// face without invalidating a measurement or changing any frame.
@MainActor final class TranscriptNativeImages: NSView {
    private(set) var buttons: [TranscriptImageButton] = []
    private var identity: Identity?
    private struct Identity: Equatable {
        let id: String; let count: Int; let reference: TranscriptImageReference?; let attachments: [AttachmentRecord]?
    }
    private var sheet: PiSheetWindow?
    private var rightToLeft = false
    private var visibilityObservation: NSObjectProtocol?
    override var isFlipped: Bool { true }
    deinit {
        MainActor.assumeIsolated { if let visibilityObservation { NotificationCenter.default.removeObserver(visibilityObservation) } }
    }

    func update(message: TranscriptMessage, actions: TranscriptActions, environment: TranscriptRowEnvironment) {
        let rtl = environment.layoutDirection == .rightToLeft
        if rtl != rightToLeft { rightToLeft = rtl; needsLayout = true }
        let count = max(0, message.imageCount ?? 0)
        let next = Identity(id: message.id, count: count, reference: message.imageReference, attachments: message.imageAttachments)
        if next != identity {
            identity = next
            buttons.forEach { $0.removeFromSuperview() }; buttons = []
            for index in 0..<count {
                let label = "Image \(index + 1) of \(count)"
                let load: @MainActor (Int) async throws -> TranscriptImageBitmap = { pixels in
                    guard let action = actions.loadImage else { throw HostError.failure("This image is unavailable.") }
                    return try await action(message, index, pixels)
                }
                let button = TranscriptImageButton(label: label, load: load)
                button.onPress = { [weak self, weak button] in
                    guard let self, let window = button?.window, window.attachedSheet == nil else { return }
                    self.sheet = AppKitSheets.present(on: window, size: CGSize(width: min(800, max(320, window.frame.width - 60)),
                                                                             height: min(620, max(300, window.frame.height - 80)))) { dismiss in
                        TranscriptImageViewer(label: label, load: load, dismiss: dismiss)
                    }
                    self.sheet?.onEnded = { [weak self] _ in self?.sheet = nil }
                }
                addSubview(button); buttons.append(button)
            }
            needsLayout = true
        }
        for button in buttons { button.isEnabled = environment.isEnabled }
    }
    override func layout() {
        super.layout()
        let columns = TranscriptImageMetrics.columns(width: bounds.width)
        for (index, button) in buttons.enumerated() {
            let rect = CGRect(x: CGFloat(index % columns) * (TranscriptImageMetrics.side + TranscriptImageMetrics.gap),
                              y: CGFloat(index / columns) * (TranscriptImageMetrics.side + TranscriptImageMetrics.gap),
                              width: TranscriptImageMetrics.side, height: TranscriptImageMetrics.side)
            button.frame = TranscriptMotion.mirrored(rect, width: bounds.width, rightToLeft)
            button.loadIfVisible()
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let visibilityObservation { NotificationCenter.default.removeObserver(visibilityObservation); self.visibilityObservation = nil }
        if window == nil { sheet?.end(animated: false, requested: true); sheet = nil; return }
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            visibilityObservation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.loadVisibleImages() }
            }
        }
        // Mounted rows are positioned after their measured children. Check
        // once that pass has settled, then only as the viewport changes.
        DispatchQueue.main.async { [weak self] in self?.loadVisibleImages() }
    }
    private func loadVisibleImages() { for button in buttons { button.loadIfVisible() } }
}

@MainActor final class TranscriptImageButton: PiKit.ButtonBase {
    private let load: @MainActor (Int) async throws -> TranscriptImageBitmap
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private(set) var bitmap: TranscriptImageBitmap?
    private var drawnImage: NSImage?
    private var failure: String?
    init(label: String, load: @escaping @MainActor (Int) async throws -> TranscriptImageBitmap) {
        self.load = load
        super.init(frame: .zero)
        pressScales = false
        setAccessibilityLabel(label); setAccessibilityHelp("Open image")
        toolTip = label + " · Open image"
    }
    required init?(coder: NSCoder) { nil }
    deinit { task?.cancel() }
    override func cornerRadius(for size: CGSize) -> CGFloat { PiRadius.md }
    override func styleFace() {
        fill.backgroundColor = piCGColor(.piSurface)
        stroke.borderColor = piCGColor(.piHairlineStrong)
    }
    override func drawContent(in rect: CGRect) {
        if let drawnImage {
            let room = rect.insetBy(dx: 4, dy: 4), size = drawnImage.size
            let ratio = min(room.width / max(1, size.width), room.height / max(1, size.height))
            let fit = CGSize(width: size.width * ratio, height: size.height * ratio)
            drawnImage.draw(in: CGRect(x: room.midX - fit.width / 2, y: room.midY - fit.height / 2, width: fit.width, height: fit.height),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            PiKit.Symbol(failure == nil ? "photo" : "exclamationmark.triangle", size: 18)
                .draw(centredIn: rect, color: .piInkTertiary, scale: piScale)
        }
    }
    override func layout() { super.layout(); loadIfVisible() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { unload() } else { needsLayout = true }
    }
    override func viewDidHide() { super.viewDidHide(); unload() }
    override func viewDidUnhide() {
        super.viewDidUnhide(); needsLayout = true
        DispatchQueue.main.async { [weak self] in self?.loadIfVisible() }
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        unload(); needsLayout = true
        DispatchQueue.main.async { [weak self] in self?.loadIfVisible() }
    }
    private func unload() {
        generation = UUID(); task?.cancel(); task = nil
        bitmap = nil; drawnImage = nil; failure = nil; content.contents = nil; redrawContent()
    }
    fileprivate func loadIfVisible() {
        guard window != nil, !isHiddenOrHasHiddenAncestor, visibleRect.intersects(bounds),
              task == nil, bitmap == nil, failure == nil else { return }
        if let scroll = enclosingScrollView, let document = scroll.documentView {
            guard document.convert(bounds, from: self).intersects(scroll.documentVisibleRect) else { return }
        }
        let generation = generation, load = load, pixels = Int(ceil(TranscriptImageMetrics.side * piScale))
        task = Task { [weak self] in
            do {
                let bitmap = try await load(pixels)
                guard let self, !Task.isCancelled, self.generation == generation, self.window != nil else { return }
                self.bitmap = bitmap
                let representation = NSBitmapImageRep(cgImage: bitmap.image), image = NSImage(size: CGSize(width: bitmap.image.width, height: bitmap.image.height))
                image.addRepresentation(representation); self.drawnImage = image
                self.toolTip = (self.accessibilityLabel() ?? "Image") + " · Open image"
                self.setAccessibilityHelp("Open image")
                self.task = nil; self.redrawContent()
            } catch {
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                self.failure = error.localizedDescription; self.task = nil
                self.toolTip = error.localizedDescription + " Click to open the image again."
                self.setAccessibilityHelp(error.localizedDescription + " Open image to try again.")
                self.redrawContent()
            }
        }
    }
}

/// The same preview content Files and Changes use, in the app's own sheet.
@MainActor final class TranscriptImageViewer: NSView {
    let preview: FilePreview
    let imageView: FilePreviewView
    private let sheet: PiKit.Sheet
    private let dismiss: () -> Void
    init(label: String, load: @escaping @MainActor (Int) async throws -> TranscriptImageBitmap, dismiss: @escaping () -> Void) {
        self.dismiss = dismiss
        preview = FilePreview(imageName: label, load: { try await load(2_048) })
        imageView = FilePreviewView(preview: preview)
        let close = PiKit.Button("Close", style: .ghost, action: dismiss)
        sheet = PiKit.Sheet(label, symbol: "photo", content: imageView, actions: [close])
        super.init(frame: .zero)
        sheet.dismiss = { [weak self] in self?.dismiss() }
        addSubview(sheet)
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); sheet.frame = bounds }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { preview.close() }
    }
}
