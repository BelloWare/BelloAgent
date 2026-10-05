import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import PiApp
@testable import GitView

/// The 310pt Changes pane in the released minimum-width main window. The
/// toolbar's nonshrinking menus and icon controls determine a shared minimum;
/// every child follows that width, including the History filters and rows.
@MainActor final class GitPanelNarrowParityTests: GitPanelTestCase, SerialTestLane {
    override func setUp() async throws { PiKit.Motion.reducedOverride = true }
    override func tearDown() async throws { PiKit.Motion.reducedOverride = nil }

    private func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views(type, in: $0) }
    }
    private func mount(_ view: NSView, size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentView = view; window.orderFront(nil)
        window.makeFirstResponder(nil)
        addTeardownBlock { @MainActor in window.orderOut(nil); window.contentView = nil; window.close() }
        return window
    }
    private func settle(_ root: NSView, window: NSWindow, minimumFrames: Int = 12, snapshot: () -> [GitNarrowReferencePart: CGRect]?) async throws -> [GitNarrowReferencePart: CGRect] {
        var previous: [GitNarrowReferencePart: CGRect] = [:], stable = 0
        try await eventually("The narrow Git frames settle", timeout: 5) {
            root.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
            guard let current = snapshot(), current.count >= minimumFrames else { return false }
            stable = current == previous ? stable + 1 : 0; previous = current
            return stable >= 3
        }
        return previous
    }
    private func frame(_ view: NSView, in panel: NSView) -> CGRect { view.convert(view.bounds, to: panel) }
    private func nativeFrames(_ panel: GitPanelView) -> [GitNarrowReferencePart: CGRect]? {
        guard let header = views(GitPanelHeader.self, in: panel).first,
              let toolbar = views(GitPanelToolbar.self, in: panel).first,
              let history = views(GitHistoryList.self, in: panel).first,
              let filter = views(PiKit.TextField.self, in: history).first(where: { $0.field.placeholderString == "Filter by message or hash" }),
              let author = views(PiKit.TextField.self, in: history).first(where: { $0.field.placeholderString == "Author" }),
              let branch = views(PiKit.MenuButton.self, in: toolbar).first(where: { $0.accessibilityIdentifier() == "git-branch-menu" }),
              let stash = views(PiKit.MenuButton.self, in: toolbar).first(where: { $0.accessibilityIdentifier() == "git-stash-menu" }),
              let remote = views(GitRemoteControls.self, in: toolbar).first,
              let tabs = views(PiKit.Tabs<GitController.Panel>.self, in: toolbar).first,
              let firstCommit = views(GitCommitRowView.self, in: history).first(where: { $0.row.accessibilityIdentifier() == "git-commit-" + (panel.controller.commits.first?.shortHash ?? "") }),
              let detail = views(GitPanelDetail.self, in: panel).first else { return nil }
        return [.header: frame(header, in: panel), .toolbar: frame(toolbar, in: panel),
                .branch: frame(branch, in: panel), .remote: frame(remote, in: panel), .stash: frame(stash, in: panel), .tabs: frame(tabs, in: panel),
                .history: frame(history, in: panel), .filter: frame(filter, in: panel), .author: frame(author, in: panel),
                .list: frame(history.list, in: panel), .firstCommit: frame(firstCommit, in: panel), .detail: frame(detail, in: panel)]
    }
    private func record(_ kind: String, frames: [GitNarrowReferencePart: CGRect], window: NSWindow, minimum: CGFloat? = nil) throws {
        var values: [String: Any] = ["frames": Dictionary(uniqueKeysWithValues: frames.map { part, rect in
            (part.rawValue, [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)])
        })]
        if let minimum { values["minimumWidth"] = Double(minimum) }
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        print("GIT-NARROW " + kind + " " + String(decoding: data, as: UTF8.self))
        if let path = testEnvironment("PI_COMPONENT_GALLERY"), !path.isEmpty {
            let folder = URL(fileURLWithPath: path).appendingPathComponent("git-narrow-geometry")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent(kind + ".json"))
            let image = try PiKitParity.windowImage(window)
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(kind + ".png"))
        }
    }

    func testHistoryChildrenShareTheReleasedToolbarMinimumInA310PointPane() async throws {
        let root = try repository("git-narrow-history")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try start(root)
        let file = root.appendingPathComponent("PaymentClient.swift")
        try "let delay = 1\n".write(to: file, atomically: true, encoding: .utf8)
        try git(["add", "."], in: root); try git(["commit", "-q", "-m", "Add the payment client and fixture notes"], in: root)
        try "let delay = 2\n".write(to: file, atomically: true, encoding: .utf8)
        try git(["commit", "-q", "-a", "-m", "Back off between attempts"], in: root)
        let controller = GitController(roots: [root.path]); controller.panel = .history
        addTeardownBlock { @MainActor in controller.letGo() }
        let pane = CGSize(width: 310, height: 540)
        let native = GitPanelView(controller: controller)
        let nativeWindow = mount(native, size: pane)
        try await eventually("The real repository and its two History rows are ready", timeout: 10) {
            controller.statusRead && !controller.loading && controller.status.branch == "main" && controller.commits.count == 2
        }
        controller.selectedCommit = try XCTUnwrap(controller.commits.first)
        try await eventually("The selected commit is ready", timeout: 10) { !controller.commitLoading && controller.detail != nil }
        let actual = try await settle(native, window: nativeWindow) { self.nativeFrames(native) }

        let geometry = GitNarrowReferenceGeometry()
        let reference = GitPanelNarrowV119Reference(controller: controller, geometry: geometry).environment(\.piReduceMotion, true)
        let minimum = NSHostingController(rootView: reference).sizeThatFits(in: CGSize(width: 0, height: pane.height)).width
        let frozen = NSHostingView(rootView: reference.frame(width: pane.width, height: pane.height)
            .coordinateSpace(name: GitNarrowReferenceGeometry.coordinateSpace))
        let frozenWindow = mount(frozen, size: pane)
        let expected = try await settle(frozen, window: frozenWindow, minimumFrames: GitNarrowReferencePart.allCases.count) { geometry.frames }
        try record("frozen-v119", frames: expected, window: frozenWindow, minimum: minimum)
        try record("native", frames: actual, window: nativeWindow)

        XCTAssertGreaterThan(minimum, pane.width, "The original nonshrinking toolbar determines the minimum at this real narrow pane width")
        let expectedPanel = try XCTUnwrap(expected[.panel])
        let actualToolbar = try XCTUnwrap(actual[.toolbar])
        XCTAssertEqual(actualToolbar.width, expectedPanel.width, accuracy: 0.5, "The minimum propagates to the whole panel, rather than only overflowing the toolbar")
        XCTAssertEqual(actualToolbar.minX, expectedPanel.minX, accuracy: 0.5, "The original wider panel is centered on the available pane")
        for part in [GitNarrowReferencePart.header, .toolbar, .branch, .remote, .stash, .tabs, .history, .filter, .author, .list, .firstCommit, .detail] {
            let old = try XCTUnwrap(expected[part]), new = try XCTUnwrap(actual[part])
            XCTAssertEqual(new.minX, old.minX, accuracy: 0.5, "\(part.rawValue) leading position")
            XCTAssertEqual(new.minY, old.minY, accuracy: 0.5, "\(part.rawValue) top position")
            XCTAssertEqual(new.width, old.width, accuracy: 0.5, "\(part.rawValue) width")
            XCTAssertEqual(new.height, old.height, accuracy: 0.5, "\(part.rawValue) height")
        }
    }
}
