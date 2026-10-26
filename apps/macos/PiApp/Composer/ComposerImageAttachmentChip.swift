import AppKit
import ImageIO

/// The attached image itself beside its name. Reserve the preview's place
/// before reading it, so background decoding never moves the composer.
@MainActor final class ComposerImageAttachmentChip: NSView {
    let main: PreviewButton
    let removeButton: PiKit.Chip.RemoveButton
    private let capsule = CALayer(), outline = CALayer()
    private var reading: Task<Void, Never>?

    init(attachment: AttachmentRecord, action: @escaping () -> Void, remove: @escaping () -> Void) {
        let text = attachment.name ?? URL(fileURLWithPath: attachment.path).lastPathComponent
        main = PreviewButton(text: text); main.onPress = action
        removeButton = PiKit.Chip.RemoveButton(); removeButton.onPress = remove
        removeButton.setAccessibilityLabel("Remove " + text)
        super.init(frame: .zero)
        wantsLayer = true; addSubview(main); addSubview(removeButton)
        toolTip = attachment.path
        let file = URL(fileURLWithPath: attachment.path)
        reading = Task { [weak self] in
            let bitmap = await Task.detached(priority: .userInitiated) { Self.thumbnail(file) }.value
            guard let self, !Task.isCancelled else { return }
            self.main.thumbnail = bitmap.map { bitmap in
                let representation = NSBitmapImageRep(cgImage: bitmap.image)
                let image = NSImage(size: representation.size); image.addRepresentation(representation)
                return image
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    deinit { reading?.cancel() }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        let label = main.intrinsicContentSize
        return NSSize(width: label.width + 6 + removeButton.intrinsicContentSize.width + 20, height: label.height + 10)
    }
    override func layout() {
        super.layout()
        if capsule.superlayer == nil { layer?.insertSublayer(capsule, at: 0); layer?.addSublayer(outline); capsule.cornerCurve = .continuous; outline.cornerCurve = .continuous }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        capsule.frame = bounds; capsule.cornerRadius = 10
        outline.frame = bounds.insetBy(dx: -0.5, dy: -0.5); outline.cornerRadius = 10.5; outline.borderWidth = 1
        capsule.backgroundColor = piCGColor(.piSurface); outline.borderColor = piCGColor(.piHairlineStrong)
        CATransaction.commit()
        let trailing = removeButton.intrinsicContentSize
        main.frame = CGRect(x: 10, y: 5, width: max(0, bounds.width - trailing.width - 26), height: bounds.height - 10)
        removeButton.frame = CGRect(x: main.frame.maxX + 6, y: (bounds.height - trailing.height) / 2, width: trailing.width, height: trailing.height)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsLayout = true }

    private struct Bitmap: @unchecked Sendable { let image: CGImage }
    private nonisolated static func thumbnail(_ file: URL) -> Bitmap? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 96,
                kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        return Bitmap(image: image)
    }

    @MainActor final class PreviewButton: PiKit.ButtonBase {
        let text: String
        var thumbnail: NSImage? { didSet { redrawContent() } }
        init(text: String) {
            self.text = text
            super.init(frame: .zero)
            pressScales = false; setAccessibilityLabel(text)
        }
        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
        private var line: PiKit.Line { PiKit.Line(text, font: PiKit.Font.caption, color: .piInk) }
        override var intrinsicContentSize: NSSize { NSSize(width: 32 + 7 + min(200, line.size(scale: piScale).width), height: 32) }
        override func styleFace() { fill.backgroundColor = CGColor.clear; stroke.borderColor = CGColor.clear }
        override func drawContent(in rect: CGRect) {
            let preview = CGRect(x: 0, y: (rect.height - 32) / 2, width: 32, height: 32)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: preview, xRadius: 4, yRadius: 4).addClip()
            NSColor.piSurfaceSunken.setFill(); preview.fill()
            if let thumbnail {
                let ratio = min(preview.width / thumbnail.size.width, preview.height / thumbnail.size.height)
                let size = CGSize(width: thumbnail.size.width * ratio, height: thumbnail.size.height * ratio)
                thumbnail.draw(in: CGRect(x: preview.midX - size.width / 2, y: preview.midY - size.height / 2, width: size.width, height: size.height),
                               from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
            } else { PiKit.Symbol("photo", size: 16).draw(centredIn: preview, color: .piAccent, scale: piScale) }
            NSGraphicsContext.restoreGraphicsState()
            let height = line.size(scale: piScale).height
            line.draw(in: CGRect(x: 39, y: PiKit.round((rect.height - height) / 2, piScale), width: max(0, rect.width - 39), height: height),
                      truncation: .middle, scale: piScale)
        }
    }
}
