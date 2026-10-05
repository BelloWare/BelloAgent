import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import PiApp

/// Measures Settings beyond the initial viewport. The frozen lazy stack's
/// initial document estimate is recorded separately from its realized size;
/// every group and the complete native document must match the eager oracle.
@MainActor final class SettingsFullDocumentGeometryTests: XCTestCase, SerialTestLane {
    override func setUp() async throws { PiKit.Motion.reducedOverride = true }
    override func tearDown() async throws { PiKit.Motion.reducedOverride = nil }

    private func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views(type, in: $0) }
    }
    private func fixture() async throws -> (WorkspaceModel, ConnectionSettingsController) {
        let root = scratchRoot("settings-complete-document")
        var router = ProfileRecord()
        router.id = "settings-router"; router.name = "Team router · Responses"
        router.baseUrl = "http://127.0.0.1:59164"; router.catalogUrl = router.baseUrl + "/catalog"
        router.modelId = "ui-fixture"; router.miniModelId = "fixture-fast"
        router.contextWindow = 2_000_000; router.maxOutputTokens = 300_000; router.modelOutputLimit = 300_000
        router.advancedJSON = #"{"routing":{"replayPolicy":"portable","reference":"Synthetic UI gateway accounting contract v1","cacheHeader":"x-fixture-cache"}}"#
        var fast = router
        fast.id = "settings-fast"; fast.name = "Team fast · Responses"; fast.modelId = "fixture-fast"
        fast.contextWindow = 128_000; fast.maxOutputTokens = 16_000; fast.modelOutputLimit = 16_000
        var configuration = VaultConfiguration()
        configuration.profiles = [router, fast].map { VaultProfile(profile: $0, apiKey: "synthetic-loopback-only-key") }
        let vault = ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(configuration)))
        let model = WorkspaceModel(stateRoot: root, vault: vault)
        addTeardownBlock { @MainActor in model.shutdown(); try? FileManager.default.removeItem(at: root) }
        try await model.reloadConfiguration()
        model.settingsSection = .connections
        let controller = ConnectionSettingsController(model: model)
        await controller.load(discardingDrafts: false)
        XCTAssertTrue(controller.loaded)
        controller.draft.profile.name = "Team router · renamed"
        controller.preferences.playsCompletionSound.toggle()
        return (model, controller)
    }
    private func mount(_ view: NSView, size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentView = view; window.orderFront(nil)
        addTeardownBlock { @MainActor in window.orderOut(nil); window.contentView = nil; window.close() }
        return window
    }
    private struct Snapshot: Equatable {
        let width: CGFloat, clipWidth: CGFloat, clipHeight: CGFloat
        let documentHeight: CGFloat, origin: CGFloat, knob: CGFloat
        @MainActor init(_ scroll: NSScrollView) {
            width = scroll.bounds.width; clipWidth = scroll.contentView.bounds.width
            clipHeight = scroll.contentView.bounds.height; documentHeight = scroll.documentView?.frame.height ?? 0
            let visible = scroll.documentView?.convert(scroll.contentView.bounds, from: scroll.contentView) ?? .zero
            origin = scroll.documentView?.isFlipped == false ? documentHeight - visible.maxY : visible.minY
            knob = scroll.verticalScroller?.knobProportion ?? 0
        }
        var record: [String: Double] {
            ["width": Double(width), "clipWidth": Double(clipWidth), "clipHeight": Double(clipHeight),
             "documentHeight": Double(documentHeight), "origin": Double(origin), "knobProportion": Double(knob)]
        }
    }
    private func settle(_ root: NSView, window: NSWindow, scroll: NSScrollView, phase: String,
                        ready: () -> Bool = { true }) async throws -> Snapshot {
        var previous: Snapshot?, stable = 0
        try await eventually("Settings geometry settles at \(phase)", timeout: .seconds(5), poll: .milliseconds(50)) {
            root.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
            let current = Snapshot(scroll)
            stable = previous == current ? stable + 1 : 0; previous = current
            return ready() && current.documentHeight > current.clipHeight && stable >= 3
        }
        return try XCTUnwrap(previous)
    }
    private func record(_ phase: String, kind: String, snapshot: Snapshot, groups: [SettingsReferenceGroup: CGRect], window: NSWindow) throws {
        let frames = Dictionary(uniqueKeysWithValues: groups.map { id, frame in
            (id.rawValue, [Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)])
        })
        let data = try JSONSerialization.data(withJSONObject: ["phase": phase, "kind": kind, "scroll": snapshot.record, "groups": frames], options: [.sortedKeys])
        print("SETTINGS-DOCUMENT " + String(decoding: data, as: UTF8.self))
        if let path = testEnvironment("PI_COMPONENT_GALLERY"), !path.isEmpty {
            let folder = URL(fileURLWithPath: path).appendingPathComponent("settings-document-geometry")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = kind + "-" + phase
            try data.write(to: folder.appendingPathComponent(name + ".json"))
            let image = try PiKitParity.windowImage(window)
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name + ".png"))
        }
    }
    private func frames(_ page: VerticalStack) -> [SettingsReferenceGroup: CGRect] {
        Dictionary(uniqueKeysWithValues: zip(SettingsReferenceGroup.allCases, page.items).map { ($0.0, $0.1.frame) })
    }
    private func scroll(_ view: NSScrollView, toBottom: Bool) {
        guard let document = view.documentView else { return }
        let travel = max(0, document.frame.height - view.contentView.bounds.height)
        let y = document.isFlipped == toBottom ? travel : 0
        view.contentView.scroll(to: NSPoint(x: 0, y: y)); view.reflectScrolledClipView(view.contentView)
    }

    func testCompleteConnectionGroupsMatchAfterTheFrozenLazyPageIsRealized() async throws {
        let (model, controller) = try await fixture()
        let native = ProfileSettingsView(model: model, controller: controller, windowChrome: false, dismiss: {})
        let nativeWindow = mount(native, size: CGSize(width: 880, height: 780))
        native.layoutSubtreeIfNeeded()
        let nativeScroll = try XCTUnwrap(views(NSScrollView.self, in: native).first { $0.documentView is VerticalStack })
        nativeScroll.scrollerStyle = .legacy
        let page = try XCTUnwrap(nativeScroll.documentView as? VerticalStack)
        let nativeInitial = try await settle(native, window: nativeWindow, scroll: nativeScroll, phase: "native-initial") {
            controller.loaded && !controller.busy && page.items.count == 6
        }
        XCTAssertEqual(page.items.count, 6)
        let cards = page.items.compactMap { $0 as? SettingsCard }
        XCTAssertEqual(cards.map { $0.rows.count }, [11, 1, 5, 1, 1], "Every saved-connection row and lower group is retained")
        let editor = try XCTUnwrap(views(CodeEditorView.self, in: native).first)
        XCTAssertEqual(editor.frame.height, 130, accuracy: 0.5, "The last capabilities group retains its full editor")
        try record("initial", kind: "native", snapshot: nativeInitial, groups: frames(page), window: nativeWindow)
        scroll(nativeScroll, toBottom: true)
        let nativeBottom = try await settle(native, window: nativeWindow, scroll: nativeScroll, phase: "native-bottom")
        XCTAssertGreaterThan(nativeBottom.origin, 0)
        XCTAssertGreaterThanOrEqual(nativeBottom.origin + nativeBottom.clipHeight, try XCTUnwrap(frames(page)[.capabilities]).maxY,
                                    "The entire final capabilities group and footnote are reachable")
        try record("bottom", kind: "native", snapshot: nativeBottom, groups: frames(page), window: nativeWindow)
        scroll(nativeScroll, toBottom: false)
        let nativeTop = try await settle(native, window: nativeWindow, scroll: nativeScroll, phase: "native-returned-top")
        XCTAssertEqual(nativeTop.origin, 0, accuracy: 0.5)
        XCTAssertEqual(nativeTop.documentHeight, nativeInitial.documentHeight, accuracy: 0.5)
        try record("returned-top", kind: "native", snapshot: nativeTop, groups: frames(page), window: nativeWindow)

        // Use the real native scroll allocation, not a guessed content width.
        let size = CGSize(width: nativeScroll.bounds.width, height: nativeScroll.bounds.height)
        let lazyGeometry = SettingsReferenceGeometry()
        let lazy = NSHostingView(rootView: ProfileSettingsConnectionsV119Reference(model: model, controller: controller, geometry: lazyGeometry)
            .frame(width: size.width, height: size.height))
        let lazyWindow = mount(lazy, size: size)
        try await eventually("The frozen Settings scroll view is mounted") { lazy.layoutSubtreeIfNeeded(); return !views(NSScrollView.self, in: lazy).isEmpty }
        let lazyScroll = try XCTUnwrap(views(NSScrollView.self, in: lazy).max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
        lazyScroll.scrollerStyle = .legacy
        let lazyInitial = try await settle(lazy, window: lazyWindow, scroll: lazyScroll, phase: "frozen-lazy-initial") {
            lazyGeometry.groups[.connection] != nil
        }
        try record("initial", kind: "frozen-lazy", snapshot: lazyInitial, groups: lazyGeometry.groups, window: lazyWindow)

        // Visit each group, including those below the first Connection card.
        // The final visit is the bottom, then return to the original top.
        for group in SettingsReferenceGroup.allCases.dropFirst() {
            lazyGeometry.target = group
            _ = try await settle(lazy, window: lazyWindow, scroll: lazyScroll, phase: "realize-" + group.rawValue) {
                lazyGeometry.groups[group] != nil
            }
        }
        XCTAssertEqual(Set(lazyGeometry.groups.keys), Set(SettingsReferenceGroup.allCases))
        let lazyBottom = try await settle(lazy, window: lazyWindow, scroll: lazyScroll, phase: "frozen-lazy-bottom")
        XCTAssertGreaterThan(lazyBottom.origin, 0)
        try record("bottom", kind: "frozen-lazy", snapshot: lazyBottom, groups: lazyGeometry.groups, window: lazyWindow)
        // The header's id follows 24pt padding. Use the actual scroller's
        // top edge to return to 0 rather than anchoring that padded header.
        // The original LazyVStack estimates the off-screen groups again;
        // record that estimate separately from its complete bottom snapshot.
        scroll(lazyScroll, toBottom: false)
        let lazyTop = try await settle(lazy, window: lazyWindow, scroll: lazyScroll, phase: "frozen-lazy-returned-top")
        XCTAssertEqual(lazyTop.origin, 0, accuracy: 0.5, "The old page returns to its original reading position")
        try record("returned-top", kind: "frozen-lazy", snapshot: lazyTop, groups: lazyGeometry.groups, window: lazyWindow)

        // Identical frozen children measured eagerly reveal the actual full
        // document independently of the lazy stack's provisional estimate.
        let eagerGeometry = SettingsReferenceGeometry()
        let eager = NSHostingView(rootView: ProfileSettingsConnectionsV119Reference(model: model, controller: controller,
            geometry: eagerGeometry, layout: .eager).frame(width: size.width, height: size.height))
        let eagerWindow = mount(eager, size: size)
        try await eventually("The eager frozen Settings scroll view is mounted") { eager.layoutSubtreeIfNeeded(); return !views(NSScrollView.self, in: eager).isEmpty }
        let eagerScroll = try XCTUnwrap(views(NSScrollView.self, in: eager).max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
        eagerScroll.scrollerStyle = .legacy
        let eagerComplete = try await settle(eager, window: eagerWindow, scroll: eagerScroll, phase: "frozen-eager-complete") {
            eagerGeometry.groups.count == 6
        }
        try record("complete", kind: "frozen-eager", snapshot: eagerComplete, groups: eagerGeometry.groups, window: eagerWindow)

        let nativeFrames = frames(page)
        for group in SettingsReferenceGroup.allCases {
            let expected = try XCTUnwrap(eagerGeometry.groups[group])
            let actual = try XCTUnwrap(nativeFrames[group])
            let realized = try XCTUnwrap(lazyGeometry.groups[group])
            XCTAssertEqual(actual.width, expected.width, accuracy: 0.5, "\(group.rawValue) actual complete width")
            XCTAssertEqual(actual.height, expected.height, accuracy: 1.01, "\(group.rawValue) actual complete height")
            XCTAssertEqual(actual.minY, expected.minY, accuracy: 1.01, "\(group.rawValue) actual complete position")
            XCTAssertEqual(realized.height, expected.height, accuracy: 0.5, "\(group.rawValue) lazy and eager frozen heights")
        }
        XCTAssertEqual(nativeInitial.clipWidth, eagerComplete.clipWidth, accuracy: 0.5)
        XCTAssertEqual(nativeInitial.clipHeight, eagerComplete.clipHeight, accuracy: 0.5)
        XCTAssertEqual(nativeInitial.documentHeight, eagerComplete.documentHeight, accuracy: 1.01, "The native page retains the complete old content height")
        XCTAssertEqual(lazyBottom.documentHeight, eagerComplete.documentHeight, accuracy: 0.5, "The fully realized old page matches the complete content")
        XCTAssertEqual(lazyBottom.knob, eagerComplete.knob, accuracy: 0.001, "The old thumb at the bottom reflects the complete content")
        XCTAssertEqual(nativeInitial.knob, eagerComplete.knob, accuracy: 0.001, "The native thumb reflects the complete old content")
        print("SETTINGS-LAZY-ESTIMATE initialHeight=\(lazyInitial.documentHeight) realizedHeight=\(lazyBottom.documentHeight) returnedTopHeight=\(lazyTop.documentHeight) nativeHeight=\(nativeInitial.documentHeight) initialKnob=\(lazyInitial.knob) realizedKnob=\(lazyBottom.knob) returnedTopKnob=\(lazyTop.knob)")
    }
}
