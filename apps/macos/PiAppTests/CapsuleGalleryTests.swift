import AppKit
import XCTest
@testable import PiApp

final class CapsuleRenderingTests: XCTestCase {
    @MainActor private final class Canvas: NSView {
        override func draw(_ dirtyRect: NSRect) { NSColor.white.setFill(); bounds.fill() }
    }
    @MainActor func testCapsuleOutlineHasNoStraightSeamsOutsideItsArc() throws {
        let canvas = Canvas(frame: .init(x: 0, y: 0, width: 180, height: 70))
        let button = PiKit.ButtonBase(frame: .init(x: 20, y: 20, width: 140, height: 30))
        canvas.addSubview(button); button.needsLayout = true; button.layoutSubtreeIfNeeded()
        button.fill.backgroundColor = NSColor.white.cgColor
        button.stroke.borderColor = NSColor.black.cgColor
        for scale in [1, 2] {
            let image = try CapsuleGalleryTests.raster(canvas, scale: scale)
            var ink = 0, outside = 0, pixel = [Int](repeating: 0, count: 4)
            for y in 0..<image.pixelsHigh {
                for x in 0..<image.pixelsWide {
                    image.getPixel(&pixel, atX: x, y: y)
                    guard pixel[0] < 180 else { continue }
                    ink += 1
                    let px = (CGFloat(x) + 0.5) / CGFloat(scale)
                    let py = (CGFloat(y) + 0.5) / CGFloat(scale)
                    let centreX = min(145, max(35, px))
                    // Half a point of stroke plus a full point of raster
                    // tolerance; straight seams outside the end arcs exceed it.
                    if hypot(px - centreX, py - 35) - 15 > 1.5 { outside += 1 }
                }
            }
            XCTAssertGreaterThan(ink, 100, "The outline must actually be rendered at \(scale)x")
            XCTAssertEqual(outside, 0, "The capsule has stray outline pixels outside its arc at \(scale)x")
        }
    }
}

final class CapsuleGalleryTests: XCTestCase, SerialTestLane {
    @MainActor private final class Canvas: NSView {
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) { NSColor.piContent.setFill(); bounds.fill() }
    }
    @MainActor private final class Rectangle: PiKit.ButtonBase {
        override func cornerRadius(for size: CGSize) -> CGFloat { 5 }
        override func styleFace() {
            fill.backgroundColor = piCGColor(.piSurface)
            stroke.borderColor = piCGColor(.piHairlineStrong)
        }
        override var intrinsicContentSize: NSSize { .init(width: 140, height: 30) }
    }
    @MainActor static func raster(_ view: NSView, scale: Int) throws -> NSBitmapImageRep {
        let size = view.bounds.size
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
            pixelsHigh: Int(size.height) * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        image.size = size
        view.cacheDisplay(in: view.bounds, to: image)
        return image
    }
    @MainActor func testCapsuleUsersAtBothScalesAndAppearances() throws {
        guard let path = testEnvironment("PI_CAPSULE_GALLERY") else { throw XCTSkip("Set PI_CAPSULE_GALLERY for component captures") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        PiKit.Motion.reducedOverride = true; defer { PiKit.Motion.reducedOverride = nil }
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let family = FamilyPillButton(); family.title = "Sides and Agents · 4"
            let model = makeWorkspaceModel(stateRoot: scratchRoot("capsule-gallery"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
            model.prewarmsHelpers = false
            let project = PendingChatProjectChip(model: model)
            project.show(sessionID: "generated", project: WorkspaceRecord(id: "project", path: "/generated/Example", trusted: true), enabled: true)
            let controls: [(String, PiKit.ButtonBase)] = [
                ("Composer model", ComposerPillButton(icon: "sparkles", text: "Model alias", maxTextWidth: 160)),
                ("Composer effort", ComposerPillButton(icon: "brain", text: "High", active: true, maxTextWidth: 100)),
                ("Compact composer", ComposerPillButton(icon: "sparkles", text: "Model", maxTextWidth: 100, compact: true)),
                ("Choice pill", PiKit.Dropdown(selection: 0, items: [(0, "Persist locally"), (1, "Off")])),
                ("Compact choice", PiKit.Dropdown(selection: 0, items: [(0, "Automatic")], compact: true)),
                ("Family pill", family),
                ("Search scope menu face", PiKit.MenuButton(title: "All chats", icon: "magnifyingglass") { [] }),
                ("Chooser · one copy", PiKit.MenuButton(title: "1 saved copy") { [] }),
                ("Chooser · many copies", PiKit.MenuButton(title: "40 saved copies") { [] }),
                ("Project pill", project),
                ("Primary button", PiKit.Button("Save", style: .primary)),
                ("Secondary button", PiKit.Button("Cancel", style: .secondary)),
                ("Danger button", PiKit.Button("Delete", style: .danger)),
                ("Ghost button", PiKit.Button("Show more", style: .ghost)),
                ("Statistics pill", PiKit.StatPill(symbol: "clock", label: "2.4 seconds")),
                ("Circle icon", PiKit.IconButton(symbol: "plus", label: "Add", filled: true)),
                ("Back to bottom", PiKit.BackToBottomPill(action: {})),
                ("Noncapsule control", Rectangle())
            ]
            let canvas = Canvas(frame: .init(x: 0, y: 0, width: 720, height: 720))
            let window = NSWindow(contentRect: canvas.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearance)
            window.contentView = canvas; window.hasShadow = false
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            var geometry: [[String: Any]] = []
            for (index, pair) in controls.enumerated() {
                let (name, button) = pair
                let x = CGFloat(index % 2) * 360 + 24, y = CGFloat(index / 2) * 78 + 14
                let label = ShellText(name, font: PiKit.Font.caption, color: .piInkSecondary)
                label.frame = .init(x: x, y: y, width: 310, height: 18); canvas.addSubview(label)
                canvas.addSubview(button)
                let size = button.intrinsicContentSize
                button.frame = .init(x: x, y: y + 24, width: ceil(size.width), height: ceil(size.height))
                button.needsLayout = true; button.layoutSubtreeIfNeeded(); button.refreshFace(animated: false)
                geometry.append(["name": name, "x": x, "y": y + 24, "width": ceil(size.width), "height": ceil(size.height)])
            }
            window.orderFrontRegardless(); canvas.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
            for scale in [1, 2] {
                let image = try Self.raster(canvas, scale: scale)
                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("capsules-\(theme)-\(scale)x.png"))
            }
            try JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("geometry-\(theme).json"))
        }
    }
}
