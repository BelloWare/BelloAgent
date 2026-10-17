import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import PiApp

/// Measures Settings beyond the initial viewport. The frozen lazy stack's
/// initial document estimate is recorded separately from its realized size;
/// every group and the complete native document must match the original lazy
/// page after realization. The eager copy is a supplemental content measure.
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
        var width: CGFloat, clipWidth: CGFloat, clipHeight: CGFloat
        var documentHeight: CGFloat, origin: CGFloat, knob: CGFloat
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
    /// Every view inside `group`'s band of the document, by origin: when the
    /// pages disagree, which row is taller is in the log.
    private func rows(_ root: NSView, document: NSView, within band: CGRect) -> [String] {
        var lines: [String] = []
        func walk(_ view: NSView) {
            let frame = view.convert(view.bounds, to: document)
            if frame.minY >= band.minY - 0.5, frame.maxY <= band.maxY + 0.5, view !== document {
                lines.append("\(type(of: view)) y=\(frame.minY - band.minY) h=\(frame.height) x=\(frame.minX) w=\(frame.width)")
                if let field = view as? NSTextField { lines.append("  field font=\(field.font?.fontName ?? "-") \(field.font?.pointSize ?? 0) intrinsic=\(field.intrinsicContentSize.height)") }
            }
            for child in view.subviews { walk(child) }
        }
        walk(document)
        return lines
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

    /// The native page, settled and recorded at its top, bottom and top again.
    private struct NativePage {
        let view: ProfileSettingsView, window: NSWindow, scroll: NSScrollView, page: VerticalStack, initial: Snapshot
    }
    private func measureNative(_ model: WorkspaceModel, _ controller: ConnectionSettingsController) async throws -> NativePage {
        let native = ProfileSettingsView(model: model, controller: controller, windowChrome: false, dismiss: {})
        let nativeWindow = mount(native, size: CGSize(width: 880, height: 780))
        native.layoutSubtreeIfNeeded()
        let nativeScroll = try XCTUnwrap(views(NSScrollView.self, in: native).first { $0.documentView is VerticalStack })
        nativeScroll.scrollerStyle = .legacy
        let page = try XCTUnwrap(nativeScroll.documentView as? VerticalStack)
        let nativeInitial = try await settle(native, window: nativeWindow, scroll: nativeScroll, phase: "native-initial") {
            controller.loaded && !controller.busy && page.items.count == 7
        }
        XCTAssertEqual(page.items.count, 7)
        let cards = page.items.compactMap { $0 as? SettingsCard }
        XCTAssertEqual(cards.map { $0.rows.count }, [11, 1, 5, 1, 1, 4], "Every saved-connection row and lower group is retained, then the Retries group (0.1.124)")
        let editor = try XCTUnwrap(views(CodeEditorView.self, in: native).first)
        XCTAssertEqual(editor.frame.height, 130, accuracy: 0.5, "The last capabilities group retains its full editor")
        try record("initial", kind: "native", snapshot: nativeInitial, groups: frames(page), window: nativeWindow)
        scroll(nativeScroll, toBottom: true)
        let nativeBottom = try await settle(native, window: nativeWindow, scroll: nativeScroll, phase: "native-bottom")
        XCTAssertGreaterThan(nativeBottom.origin, 0)
        XCTAssertGreaterThanOrEqual(nativeBottom.origin + nativeBottom.clipHeight, page.items[6].frame.maxY,
                                    "The entire final Retries group and footnote are reachable")
        try record("bottom", kind: "native", snapshot: nativeBottom, groups: frames(page), window: nativeWindow)
        scroll(nativeScroll, toBottom: false)
        let nativeTop = try await settle(native, window: nativeWindow, scroll: nativeScroll, phase: "native-returned-top")
        XCTAssertEqual(nativeTop.origin, 0, accuracy: 0.5)
        XCTAssertEqual(nativeTop.documentHeight, nativeInitial.documentHeight, accuracy: 0.5)
        try record("returned-top", kind: "native", snapshot: nativeTop, groups: frames(page), window: nativeWindow)
        return NativePage(view: native, window: nativeWindow, scroll: nativeScroll, page: page, initial: nativeInitial)
    }

    /// The frozen 0.1.119 page, the oracle: its lazy stack realized group by
    /// group (the strict oracle) and the same children eagerly (supplemental).
    private struct Oracle {
        var lazyInitial: Snapshot, lazyBottom: Snapshot, lazyTop: Snapshot, eager: Snapshot
        var lazyFrames: [SettingsReferenceGroup: CGRect], eagerFrames: [SettingsReferenceGroup: CGRect]
        let lazy: NSView, lazyScroll: NSScrollView, eagerView: NSView, eagerScroll: NSScrollView
        let lazyWindow: NSWindow, eagerWindow: NSWindow
        /// Each view inside the oracle pages' Connection band, as now laid out.
        @MainActor func rows(_ test: SettingsFullDocumentGeometryTests) -> String {
            // The lazy page is back at its top: its Connection group is realized there.
            var text = ""
            if let frame = lazyFrames[.connection], let document = lazyScroll.documentView {
                text += "SETTINGS-CONNECTION-ROWS frozen-lazy scale=\(lazyWindow.backingScaleFactor)\n" + test.rows(lazy, document: document, within: frame).joined(separator: "\n") + "\n"
            }
            if let frame = eagerFrames[.connection], let document = eagerScroll.documentView {
                text += "SETTINGS-CONNECTION-ROWS frozen-eager scale=\(eagerWindow.backingScaleFactor)\n" + test.rows(eagerView, document: document, within: frame).joined(separator: "\n")
            }
            return text
        }
    }
    private func measureOracle(_ model: WorkspaceModel, _ controller: ConnectionSettingsController, size: CGSize, attempt: Int) async throws -> Oracle {
        let suffix = attempt == 0 ? "" : "-remeasure-\(attempt)"
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
        try record("initial" + suffix, kind: "frozen-lazy", snapshot: lazyInitial, groups: lazyGeometry.groups, window: lazyWindow)

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
        let lazyBottomFrames = lazyGeometry.groups
        XCTAssertGreaterThan(lazyBottom.origin, 0)
        try record("bottom" + suffix, kind: "frozen-lazy", snapshot: lazyBottom, groups: lazyGeometry.groups, window: lazyWindow)
        // The header's id follows 24pt padding. Use the actual scroller's
        // top edge to return to 0 rather than anchoring that padded header.
        // The original LazyVStack estimates the off-screen groups again;
        // record that estimate separately from its complete bottom snapshot.
        scroll(lazyScroll, toBottom: false)
        let lazyTop = try await settle(lazy, window: lazyWindow, scroll: lazyScroll, phase: "frozen-lazy-returned-top")
        XCTAssertEqual(lazyTop.origin, 0, accuracy: 0.5, "The old page returns to its original reading position")
        try record("returned-top" + suffix, kind: "frozen-lazy", snapshot: lazyTop, groups: lazyGeometry.groups, window: lazyWindow)

        // Measure the same children eagerly as a supplemental check. SwiftUI's
        // different VStack context can round a wrapped footer a point shorter;
        // the original resolved LazyVStack remains the strict release oracle.
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
        try record("complete" + suffix, kind: "frozen-eager", snapshot: eagerComplete, groups: eagerGeometry.groups, window: eagerWindow)
        print("SETTINGS-LAZY-ESTIMATE attempt=\(attempt) initialHeight=\(lazyInitial.documentHeight) realizedHeight=\(lazyBottom.documentHeight) returnedTopHeight=\(lazyTop.documentHeight) initialKnob=\(lazyInitial.knob) realizedKnob=\(lazyBottom.knob) returnedTopKnob=\(lazyTop.knob)")
        return Oracle(lazyInitial: lazyInitial, lazyBottom: lazyBottom, lazyTop: lazyTop, eager: eagerComplete,
                      lazyFrames: lazyBottomFrames, eagerFrames: eagerGeometry.groups,
                      lazy: lazy, lazyScroll: lazyScroll, eagerView: eager, eagerScroll: eagerScroll, lazyWindow: lazyWindow, eagerWindow: eagerWindow)
    }

    /// Every way `oracle` differs from the native page; empty when the native
    /// page matches it. Strict against the realized lazy oracle; the eager
    /// copy is supplemental and allows the point its stack can round.
    private func differences(_ native: NativePage, _ oracle: Oracle) -> [String] {
        var found: [String] = []
        func check(_ actual: CGFloat, _ expected: CGFloat, _ accuracy: CGFloat, _ what: String) {
            if abs(actual - expected) > accuracy { found.append("\(what): native \(actual), oracle \(expected)") }
        }
        let nativeFrames = frames(native.page)
        for group in SettingsReferenceGroup.allCases {
            guard let actual = nativeFrames[group], let expected = oracle.lazyFrames[group], let eagerFrame = oracle.eagerFrames[group] else {
                found.append("\(group.rawValue): missing frame"); continue
            }
            check(actual.width, expected.width, 0.5, "\(group.rawValue) original complete width")
            check(actual.height, expected.height, 0.5, "\(group.rawValue) original complete height")
            check(actual.minY, expected.minY, 0.5, "\(group.rawValue) original complete position")
            check(actual.width, eagerFrame.width, 0.5, "\(group.rawValue) supplemental eager width")
            check(actual.height, eagerFrame.height, 1.01, "\(group.rawValue) supplemental eager height")
            check(actual.minY, eagerFrame.minY, 1.01, "\(group.rawValue) supplemental eager position")
        }
        let initial = native.initial, page = native.page
        check(initial.clipWidth, oracle.lazyBottom.clipWidth, 0.5, "lazy clip width")
        check(initial.clipHeight, oracle.lazyBottom.clipHeight, 0.5, "lazy clip height")
        // The Retries group (0.1.124) follows the frozen page's last group: the
        // native page is the original plus that group and its spacing.
        let retries = page.items[6].frame.maxY - page.items[5].frame.maxY
        if retries <= 100 { found.append("Retries group spans \(retries)") }
        check(initial.documentHeight - retries, oracle.lazyBottom.documentHeight, 0.5, "The native page retains the original complete content height")
        check(initial.knob, oracle.lazyBottom.knob * oracle.lazyBottom.documentHeight / initial.documentHeight, 0.002, "The native thumb matches the original fully realized page")
        check(initial.clipWidth, oracle.eager.clipWidth, 0.5, "eager clip width")
        check(initial.clipHeight, oracle.eager.clipHeight, 0.5, "eager clip height")
        check(initial.documentHeight - retries, oracle.eager.documentHeight, 1.01, "The native page retains the complete old content height")
        check(oracle.lazyBottom.knob, oracle.eager.knob, 0.001, "The old thumb at the bottom reflects the complete content")
        check(initial.knob, oracle.eager.knob * oracle.eager.documentHeight / initial.documentHeight, 0.002, "The native thumb reflects the complete content")
        return found
    }

    /// How the comparison came out: the oracle that matched (0 the first,
    /// 1 or 2 one built again), or every disagreement when none did.
    enum OracleOutcome: Equatable { case matched(attempt: Int), disagreed([String]) }
    /// The frozen SwiftUI oracle, not the product, rarely lays its Connection
    /// group out a point taller or shorter (784 or 782; the native page is 783
    /// in every run). When the oracle disagrees with the native page, the
    /// rows of all three pages are printed and a fresh oracle is built, up to
    /// twice more; the native page must match one of them exactly.
    /// `perturb` changes the oracle built at each attempt it is given, for the
    /// test of this path.
    private func compare(_ native: NativePage, _ model: WorkspaceModel, _ controller: ConnectionSettingsController,
                         perturb: (Int, inout Oracle) -> Void = { _, _ in }) async throws -> OracleOutcome {
        let size = CGSize(width: native.scroll.bounds.width, height: native.scroll.bounds.height)
        var all: [String] = []
        for attempt in 0...2 {
            var oracle = try await measureOracle(model, controller, size: size, attempt: attempt)
            perturb(attempt, &oracle)
            let found = differences(native, oracle)
            if found.isEmpty {
                if attempt > 0 { print("ORACLE-REMEASURED SettingsFullDocumentGeometry: oracle \(attempt + 1) of 3 matched the native page; the earlier ones disagreed:\n" + all.joined(separator: "\n")) }
                return .matched(attempt: attempt)
            }
            if let connection = frames(native.page)[.connection] {
                print("SETTINGS-CONNECTION-ROWS native scale=\(native.window.backingScaleFactor)\n" + rows(native.page, document: native.page, within: connection).joined(separator: "\n"))
            }
            print(oracle.rows(self))
            print("ORACLE-REMEASURED SettingsFullDocumentGeometry: oracle \(attempt + 1) of 3 disagrees with the native page: " + found.joined(separator: "; "))
            all += found.map { "oracle \(attempt + 1): " + $0 }
        }
        return .disagreed(all)
    }

    func testCompleteConnectionGroupsMatchAfterTheFrozenLazyPageIsRealized() async throws {
        let (model, controller) = try await fixture()
        let native = try await measureNative(model, controller)
        let outcome = try await compare(native, model, controller)
        if case .disagreed(let found) = outcome {
            XCTFail("No frozen oracle of three matched the native page:\n" + found.joined(separator: "\n"))
        }
    }

    /// The re-measuring path: a first oracle a point off (as the frozen
    /// SwiftUI page sometimes lays itself out) is measured again and the
    /// fresh one decides; one that stays off fails with every disagreement.
    func testAnOracleThatDisagreesIsMeasuredAgain() async throws {
        let (model, controller) = try await fixture()
        let native = try await measureNative(model, controller)
        func taller(_ oracle: inout Oracle) {
            oracle.lazyFrames[.connection]?.size.height += 1
            for group in [SettingsReferenceGroup.reasoning, .metadata, .routing, .capabilities] { oracle.lazyFrames[group]?.origin.y += 1 }
            oracle.lazyBottom.documentHeight += 1
        }
        let once = try await compare(native, model, controller) { attempt, oracle in if attempt == 0 { taller(&oracle) } }
        XCTAssertEqual(once, .matched(attempt: 1), "A fresh oracle decides after a first one a point off")
        let always = try await compare(native, model, controller) { _, oracle in taller(&oracle) }
        guard case .disagreed(let found) = always else { return XCTFail("An oracle off every time must fail: \(always)") }
        XCTAssertEqual(found.filter { $0.contains("connection original complete height") }.count, 3, "\(found)")
        XCTAssertTrue(found.contains { $0.hasPrefix("oracle 3: ") && $0.contains("original complete content height") }, "\(found)")
    }
}
