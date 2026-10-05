import AppKit
import SwiftUI
import XCTest
@testable import PiApp

@MainActor final class PayloadNativeParityTests: XCTestCase, SerialTestLane {
    override func setUp() async throws { PiKit.Motion.reducedOverride = true }
    override func tearDown() async throws { PiKit.Motion.reducedOverride = nil }
    private func check<V: View>(_ name: String, _ reference: V, _ native: NSView, width: CGFloat,
                               appearance: NSAppearance.Name, splitGeometry: Bool = false,
                               ready: (@MainActor (NSView) async throws -> Void)? = nil) async throws {
        let frames = PayloadSplitFrames()
        let scrolls = PayloadScrollFrames()
        let scrollGeometry = name == "payload-resources-settings"
        let measurement = splitGeometry || scrollGeometry ? Task { @MainActor in
            while !Task.isCancelled {
                if splitGeometry { frames.recordVisibleSplits() }
                if scrollGeometry { scrolls.recordVisibleScrolls() }
                try? await Task.sleep(for: .milliseconds(20))
            }
        } : nil
        defer { measurement?.cancel() }
        let result = try await PiKitParity.compare(name + (appearance == .aqua ? "-light" : "-dark"), appearance: appearance,
                                                   swiftUI: reference, appKit: native, width: width, ready: ready)
        if scrollGeometry {
            print("SCROLL \(name) \(appearance.rawValue): " + scrolls.description)
            if let old = scrolls.reference, let current = scrolls.native {
                XCTAssertEqual(old.width, current.width, accuracy: 0.5, "The settings scroll view must occupy the same page width")
                XCTAssertEqual(old.clipWidth, current.clipWidth, accuracy: 0.5, "Scroll indicators must preserve the settings content width")
            } else { XCTFail("Both settings scroll viewports must be measured") }
            checkSettingsGeometry(in: native)
        }
        if splitGeometry {
            print("SPLIT \(name) \(appearance.rawValue): " + frames.description)
            if let old = frames.reference, let current = frames.native {
                XCTAssertEqual(old.width, current.width, accuracy: 0.5, "\(name): split viewport width")
                XCTAssertEqual(old.leading.width, current.leading.width, accuracy: 0.5, "\(name): initial leading pane width")
                XCTAssertEqual(old.trailing.width, current.trailing.width, accuracy: 0.5, "\(name): initial trailing pane width")
                XCTAssertEqual(old.leading.height, current.leading.height, accuracy: 0.5, "\(name): initial pane height")
            } else { XCTFail("\(name): both visible split layouts must be measured") }
        }
        XCTAssertEqual(result.swiftUIFit.height, result.appKitFit.height, accuracy: 0.5, result.description)
        XCTAssertLessThanOrEqual(result.differing, Int(Double(result.total) * 0.012), result.description)
        let strong = PiKitParity.difference(result.swiftUIImage, result.appKitImage, tolerance: 64)
        XCTAssertLessThanOrEqual(strong.0, Int(Double(strong.1) * 0.002), result.description)
    }
    private func checkSettingsGeometry(in view: NSView) {
        if let group = view as? PiKit.SettingsGroup {
            for row in group.rows {
                let controlEdge = row.control?.frame.maxX ?? row.bounds.maxX
                print("SETTINGS \(group.title) / \(row.label): group=\(group.bounds.width) row=\(row.bounds.width) controlRight=\(controlEdge) needsLayout=\(row.needsLayout)")
                XCTAssertEqual(row.bounds.width, group.bounds.width, accuracy: 0.5, "A settings row must fill its card after the scroll viewport changes")
                if row.control != nil { XCTAssertEqual(controlEdge, row.bounds.maxX - PiSpacing.lg, accuracy: 0.5, "A settings control must remain at its row's trailing inset") }
            }
        }
        for child in view.subviews { checkSettingsGeometry(in: child) }
    }
    private func source(_ bytes: Data) -> CapturedBodySource {
        CapturedBodySource(metadata: { CapturedBodyMetadata(body: ["state": .string("complete"), "retainedBytes": .number(Double(bytes.count)), "observedBytes": .number(Double(bytes.count))], hash: nil) },
                           page: { offset in (bytes.subdata(in: offset..<min(offset + 32768, bytes.count)), bytes.count) })
    }
    func testRetainedJSONTextHexAndCombinedBodySurfacesMatch() async throws {
        let json = Data(#"{"input":[{"role":"user","content":"Retained text 🌍"}],"model":"auto-router","stream":true,"tools":[],"metadata":{"project":"Preview"}}"#.utf8)
        let stream = Data("event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_preview\",\"model\":\"auto-router\",\"output\":[{\"content\":[{\"text\":\"The retained response.\"}]}],\"status\":\"completed\"}}\n\ndata: [DONE]\n\n".utf8)
        let cases: [(String, Data, CapturedBodyFormat, String)] = [("json", json, .json, "request"), ("text", json, .text, "request"), ("hex", json, .hex, "request"), ("combined", stream, .combined, "response")]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for (name, bytes, format, kind) in cases {
                let value = source(bytes)
                let reference = CapturedBodyViewReference(source: value, sessionID: "s", attemptID: name, kind: kind, retained: false, initialFormat: format).frame(width: 700, height: 500)
                let view = CapturedBodyView(source: value, sessionID: "s", attemptID: name, kind: kind, retained: false, initialFormat: format)
                try await check("payload-" + name, reference, PayloadViewport(view, height: 500), width: 700, appearance: appearance)
            }
        }
    }
    func testCapturedHeadersAndTurnSharesMatch() async throws {
        let headers: [String: WireValue] = ["content-type": .string("text/event-stream"), "authorization": .string("Bearer ••••abcd"), "x-litellm-model-name": .string("openai/gpt-5.4-mini")]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            try await check("payload-headers", CapturedHeadersViewReference(headers: headers).frame(width: 700), CapturedHeadersView(headers: headers), width: 700, appearance: appearance)
            let attempt: [String: WireValue] = ["requestedModel": .string("auto-router"), "model": .string("gpt-5.4-mini")]
            try await check("payload-model-reports", MessageModelReportsReference(attempt: attempt).frame(width: 700), MessageModelReports(attempt: attempt), width: 700, appearance: appearance)
            var accounting = TurnAccounting(requests: 2)
            accounting.input = 12_000; accounting.inputSamples = 2; accounting.cached = 6_000; accounting.cachedSamples = 2
            accounting.output = 3_800; accounting.outputSamples = 2; accounting.reasoning = 900; accounting.reasoningSamples = 2
            for input in [true, false] {
                let partition = TurnTokenPartition(accounting, input: input, running: false)
                try await check("payload-share-" + (input ? "input" : "output"), TurnTokenBarReference(partition: partition).frame(width: 300, alignment: .leading), TurnTokenBar(partition: partition), width: 300, appearance: appearance)
            }
        }
    }
    func testConversationHitRowsAndScrollersMatchForShortAndOverflowingResults() async throws {
        let seed = [ContentHit(id: "first", position: 1, preview: "Completed retained reply."),
                    ContentHit(id: "empty", position: 3, preview: ""),
                    ContentHit(id: "next", position: 4, preview: "The next retained preview follows the empty message.")]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for overflowing in [false, true] {
                let hits = overflowing ? seed + (5..<30).map { ContentHit(id: "hit-\($0)", position: $0, preview: "Retained result \($0) with selectable preview text.") } : seed
                let reference = ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(hits) { ConversationHitRowReference(hit: $0) }
                    }.padding(PiSpacing.sm)
                }.piInset().frame(width: 700, height: 180)
                let list = LazyStackView(frame: .zero), glide = PiKit.SelectionGlide()
                list.spacing = 2; list.insets = NSEdgeInsets(top: PiSpacing.sm, left: PiSpacing.sm, bottom: PiSpacing.sm, right: PiSpacing.sm)
                list.reload(.init(count: hits.count, key: { hits[$0].id },
                                  height: { ConversationHitRow.height(hits[$0], width: $1) },
                                  view: { index, _ in ConversationHitRow(hit: hits[index], glide: glide, action: {}) }))
                try await check("payload-conversation-results-" + (overflowing ? "overflow" : "short"), reference,
                                PayloadViewport(PiKit.inset(list), height: 180), width: 700, appearance: appearance)
            }
        }
    }
    func testSearchReaderInsetsAndSelectedMatchRevealMatch() async throws {
        @MainActor final class Selection: ObservableObject { @Published var index = 0 }
        @MainActor struct Reference: View {
            let result: PayloadSearchResult
            @ObservedObject var selection: Selection
            var body: some View { PayloadSearchTextReference(result: result, selected: selection.index) }
        }
        func editors(in root: NSView) -> [NSTextView] {
            ((root as? NSTextView).map { [$0] } ?? []) + root.subviews.flatMap { editors(in: $0) }
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for overflowing in [false, true] {
                let text = "Request headers\naccept: text/event-stream\n\nRequest body\n" + (overflowing
                    ? "README first match\n" + (1...90).map { "Retained line \($0)" }.joined(separator: "\n") + "\nREADME.md"
                    : "{\"path\":\"README.md\",\"content\":\"Retained request\"}")
                let result = try PayloadSearchResult.find(text: text, query: "README")
                let selection = Selection()
                let native = PayloadSearchTextView(result: result, selected: 0)
                let index = result.matches.count - 1
                try await check("payload-search-reader-" + (overflowing ? "overflow" : "fit"),
                                Reference(result: result, selection: selection).frame(width: 700, height: 300),
                                PayloadViewport(native, height: 300), width: 700, appearance: appearance, ready: { root in
                    // The frozen representable's initial update can run with
                    // a zero-sized clip view. Navigate after mounting instead,
                    // as an actual Next press does; both readers reveal it.
                    root.layoutSubtreeIfNeeded()
                    selection.index = index
                    if native.window === root.window { native.update(result: result, selected: index) }
                    try await eventually("The mounted reader reveals its chosen complete-body match", timeout: .seconds(3)) {
                        root.layoutSubtreeIfNeeded()
                        guard let editor = editors(in: root).first, let scroll = editor.enclosingScrollView,
                              let manager = editor.layoutManager, let container = editor.textContainer,
                              editor.selectedRange() == result.matches[index] else { return false }
                        let range = manager.glyphRange(forCharacterRange: result.matches[index], actualCharacterRange: nil)
                        let glyph = manager.boundingRect(forGlyphRange: range, in: container)
                        let visible = scroll.contentView.convert(glyph.offsetBy(dx: editor.textContainerOrigin.x,
                                                                                dy: editor.textContainerOrigin.y), from: editor)
                        return scroll.contentView.bounds.intersects(visible)
                            && (!overflowing || scroll.contentView.bounds.minY > 0)
                    }
                })
            }
        }
    }
    func testCompleteBodySearchCountChevronsAndPanelMatch() async throws {
        let bytes = Data(#"{"path":"README.md","content":"Read the retained README before editing."}"#.utf8)
        let headers: [String: WireValue] = ["accept": .string("text/event-stream")]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for query in ["README", "missing-query"] {
                @MainActor final class MountedReference {
                    var controller: CapturedBodyController?
                    var search: PayloadSearchController?
                    var frames: [String: CGRect] = [:]
                    var frozenReadyFrames: [String: CGRect] = [:]
                    var nativeReadyFrames: [String: CGRect] = [:]
                }
                let mounted = MountedReference()
                let value = source(bytes)
                var reference = CapturedBodyViewReference(source: value, sessionID: "s", attemptID: "search", kind: "request", retained: false,
                                                          searchQuery: query, searchHeaders: headers)
                reference.onControllers = { mounted.controller = $0; mounted.search = $1 }
                reference.onSearchFrame = { mounted.frames[$0] = $1 }
                let view = CapturedBodyView(source: value, sessionID: "s", attemptID: "search", kind: "request", retained: false,
                                            searchQuery: query, searchHeaders: headers)
                func findNative(in root: NSView) -> CapturedBodyView? {
                    if let native = root as? CapturedBodyView { return native }
                    return root.subviews.lazy.compactMap { findNative(in: $0) }.first
                }
                func searchBoxes(in root: NSView) -> [PiKit.Box] {
                    ((root as? PiKit.Box).map { [$0] } ?? []) + root.subviews.flatMap { searchBoxes(in: $0) }
                }
                let expectedMatches = query == "README" ? 2 : 0
                try await check("payload-complete-search-" + (query == "README" ? "matches" : "none"), reference.frame(width: 700, height: 500),
                                PayloadViewport(view, height: 500), width: 700, appearance: appearance, ready: { root in
                    try await eventually("The mounted body and \(query) search are complete before capture", timeout: .seconds(5)) {
                        root.layoutSubtreeIfNeeded()
                        let native = findNative(in: root)
                        let controller = native?.controller ?? mounted.controller
                        let search = native?.search ?? mounted.search
                        guard let controller, let search, let document = controller.document, let result = search.result else { return false }
                        return !controller.loading && document.bytes == bytes && !search.loading
                            && result.matches.count == expectedMatches && result.text.contains("README")
                            && result.text.hasPrefix("Request headers\naccept: text/event-stream\n\nRequest body\n")
                            && (native != nil || ["bar", "reader", "previous", "next", "previous-symbol", "next-symbol"]
                                .allSatisfy { (mounted.frames[$0]?.height ?? 0) > 0 })
                    }
                    if let native = findNative(in: root), let bar = native.previousMatch.superview,
                       let box = searchBoxes(in: native).first(where: { $0.content is PayloadSearchTextView }) {
                        let frames: [String: CGRect] = ["bar": bar.convert(bar.bounds, to: native),
                            "reader": box.convert(box.bounds, to: native),
                            "previous": native.previousMatch.convert(native.previousMatch.bounds, to: native),
                            "next": native.nextMatch.convert(native.nextMatch.bounds, to: native)]
                        mounted.nativeReadyFrames = frames
                        print("SEARCH-FRAMES native \(query): " + frames.keys.sorted().map { "\($0)=\(frames[$0]!)" }.joined(separator: " "))
                        let symbol = PiKit.Symbol("chevron.up", size: 12.5, weight: .medium)
                        print("SEARCH-SYMBOL native: layout=\(symbol.layoutSize) image=\(symbol.imageSize)")
                        for name in ["chevron.up", "chevron.down"] {
                            if let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12.5, weight: .medium)) {
                                print("SEARCH-SYMBOL-ALIGNMENT \(name): image=\(base.size) alignment=\(base.alignmentRect)")
                            }
                        }
                    } else {
                        mounted.frozenReadyFrames = mounted.frames
                        print("SEARCH-FRAMES frozen \(query): " + mounted.frames.keys.sorted().map { "\($0)=\(mounted.frames[$0]!)" }.joined(separator: " "))
                    }
                })
                for key in ["bar", "reader", "previous", "next"] {
                    let expected = try XCTUnwrap(mounted.frozenReadyFrames[key])
                    let actual = try XCTUnwrap(mounted.nativeReadyFrames[key])
                    XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.25, "\(key) complete-search leading edge")
                    XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.25, "\(key) complete-search top edge")
                    XCTAssertEqual(actual.width, expected.width, accuracy: 0.25, "\(key) complete-search width")
                    XCTAssertEqual(actual.height, expected.height, accuracy: 0.25, "\(key) complete-search height")
                }
            }
        }
    }
    func testWrappingDocumentsMatchWithShortAndVisibleLegacyScrollers() async throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for overflowing in [false, true] {
                let lines = (1...(overflowing ? 40 : 3)).map { "Retained instruction \($0): inspect the complete captured request." }
                let reference = ScrollView {
                    VStack(alignment: .leading, spacing: PiSpacing.sm) {
                        ForEach(lines, id: \.self) { Text($0).font(PiFont.body).foregroundStyle(Color.piInk).frame(maxWidth: .infinity, alignment: .leading) }
                    }.padding(PiSpacing.sm)
                }.frame(width: 700, height: 180)
                let column = ShellStack(.vertical, spacing: PiSpacing.sm, padding: NSEdgeInsets(top: PiSpacing.sm, left: PiSpacing.sm, bottom: PiSpacing.sm, right: PiSpacing.sm),
                                        lines.map { .view(ShellText($0, font: PiKit.Font.body, color: .piInk), .fill) })
                try await check("payload-wrapping-scroll-" + (overflowing ? "overflow" : "short"), reference,
                                PayloadViewport(PayloadScroll(column), height: 180), width: 700, appearance: appearance)
            }
        }
    }
    func testConversationAndResourceSheetsMatchWithEmptyRetainedData() async throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let root = scratchRoot("payload-sheet-parity")
            defer { try? FileManager.default.removeItem(at: root) }
            let model = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
            defer { model.shutdown() }
            try await check("payload-conversation", ConversationContentReference(model: model, sessionID: "missing"), ConversationContentView(model: model, sessionID: "missing"), width: 900, appearance: appearance)
            for tab in ["skills", "instructions", "settings", "mcp"] {
                try await check("payload-resources-" + tab, ResourceInspectorReference(model: model, initialTab: tab), ResourceInspector(model: model, initialTab: tab), width: 1100, appearance: appearance, splitGeometry: tab == "skills" || tab == "mcp")
            }
        }
    }
}

/// Read native HSplitView geometry while the existing comparison windows
/// are visible. This does not add a view or alter the frozen reference's
/// layout; it explains divider differences independently of rasterization.
@MainActor private final class PayloadSplitFrames {
    struct Frame {
        let width: CGFloat
        let divider: CGFloat
        let leading: NSRect, trailing: NSRect
        var description: String { "width=\(width) divider=\(divider) panes=\(leading) / \(trailing)" }
    }
    var reference: Frame?, native: Frame?
    var description: String { "SwiftUI \(reference?.description ?? "missing"); AppKit \(native?.description ?? "missing")" }
    func recordVisibleSplits() {
        for window in NSApp.windows where window.isVisible && window.styleMask.isEmpty {
            if let root = window.contentView { record(root) }
        }
    }
    private func record(_ view: NSView) {
        if let split = view as? NSSplitView, split.isVertical, split.arrangedSubviews.count == 2,
           abs(split.bounds.width - (ResourceInspector.size.width - PiSpacing.xl * 2)) < 1 {
            let left = split.arrangedSubviews[0], right = split.arrangedSubviews[1]
            let frame = Frame(width: split.bounds.width, divider: split.dividerThickness,
                              leading: left.frame, trailing: right.frame)
            if split is PayloadSplit { native = frame } else { reference = frame }
        }
        for child in view.subviews { record(child) }
    }
}

/// Observe the viewport separately from its rows, so a reserved scroller
/// cannot look like a control-alignment regression in the settings card.
@MainActor private final class PayloadScrollFrames {
    struct Frame {
        let width: CGFloat, clipWidth: CGFloat, documentWidth: CGFloat
        let style: NSScroller.Style
        let scrollerHidden: Bool
        var description: String { "width=\(width) clip=\(clipWidth) document=\(documentWidth) style=\(style.rawValue) hidden=\(scrollerHidden)" }
    }
    var reference: Frame?, native: Frame?
    var description: String { "SwiftUI \(reference?.description ?? "missing"); AppKit \(native?.description ?? "missing")" }
    func recordVisibleScrolls() {
        for window in NSApp.windows where window.isVisible && window.styleMask.isEmpty {
            if let root = window.contentView { record(root) }
        }
    }
    private func record(_ view: NSView) {
        if let scroll = view as? NSScrollView,
           abs(scroll.bounds.width - (ResourceInspector.size.width - PiSpacing.xl * 2)) < 1 {
            let frame = Frame(width: scroll.bounds.width, clipWidth: scroll.contentView.bounds.width,
                              documentWidth: scroll.documentView?.frame.width ?? 0, style: scroll.scrollerStyle,
                              scrollerHidden: scroll.verticalScroller?.isHidden ?? true)
            if scroll is PayloadScroll { native = frame } else { reference = frame }
        }
        for child in view.subviews { record(child) }
    }
}
