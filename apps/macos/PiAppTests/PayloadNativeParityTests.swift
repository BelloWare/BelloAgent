import AppKit
import SwiftUI
import XCTest
@testable import PiApp

@MainActor final class PayloadNativeParityTests: XCTestCase, SerialTestLane {
    override func setUp() async throws { PiKit.Motion.reducedOverride = true }
    override func tearDown() async throws { PiKit.Motion.reducedOverride = nil }
    private func check<V: View>(_ name: String, _ reference: V, _ native: NSView, width: CGFloat,
                               appearance: NSAppearance.Name, splitGeometry: Bool = false) async throws {
        let frames = PayloadSplitFrames()
        let measurement = splitGeometry ? Task { @MainActor in
            while !Task.isCancelled {
                frames.recordVisibleSplits()
                try? await Task.sleep(for: .milliseconds(20))
            }
        } : nil
        defer { measurement?.cancel() }
        let result = try await PiKitParity.compare(name + (appearance == .aqua ? "-light" : "-dark"), appearance: appearance,
                                                   swiftUI: reference, appKit: native, width: width)
        if splitGeometry {
            print("SPLIT \(name) \(appearance.rawValue): " + frames.description)
            if let old = frames.reference, let current = frames.native {
                XCTAssertEqual(old.width, current.width, accuracy: 0.5, "\(name): split viewport width")
                XCTAssertEqual(old.leading.width, current.leading.width, accuracy: 0.5, "\(name): initial leading pane width")
                XCTAssertEqual(old.trailing.width, current.trailing.width, accuracy: 0.5, "\(name): initial trailing pane width")
            } else { XCTFail("\(name): both visible split layouts must be measured") }
        }
        XCTAssertEqual(result.swiftUIFit.height, result.appKitFit.height, accuracy: 0.5, result.description)
        XCTAssertLessThanOrEqual(result.differing, Int(Double(result.total) * 0.012), result.description)
        let strong = PiKitParity.difference(result.swiftUIImage, result.appKitImage, tolerance: 64)
        XCTAssertLessThanOrEqual(strong.0, Int(Double(strong.1) * 0.002), result.description)
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
