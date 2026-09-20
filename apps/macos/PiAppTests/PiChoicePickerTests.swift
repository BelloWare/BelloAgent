import AppKit
import SwiftUI
import Vision
import XCTest
@testable import PiApp

final class PiChoicePickerTests: XCTestCase {
    @MainActor private final class ChoiceState: ObservableObject {
        @Published var choices: [PiChoice<String>]
        @Published var selection: String?
        var committed: [String] = []
        var cancelled = 0
        var actions = 0
        init(choices: [PiChoice<String>], selection: String?) {
            self.choices = choices; self.selection = selection
        }
        func choose(_ value: String) { committed.append(value); selection = value }
    }

    private struct ChoiceFixture: View {
        @ObservedObject var state: ChoiceState
        var body: some View {
            PiChoiceList(title: "Fixture choices", selection: state.selection, choices: state.choices,
                         actionTitle: "Manage fixture choices", action: { state.actions += 1 },
                         choose: state.choose, cancel: { state.cancelled += 1 })
        }
    }

    private struct PickerFixture: View {
        @ObservedObject var state: ChoiceState
        var body: some View {
            PiChoicePicker(title: "Connection", selection: state.selection, choices: state.choices,
                           note: "The selected connection applies to the next turn.",
                           actionTitle: "Manage fixture choices", action: { state.actions += 1 },
                           choose: state.choose) {
                Text("Choose fixture value").padding(12)
                    .background(Color.piSurfaceSunken, in: Capsule())
            }.padding(20).frame(width: 330, height: 100)
        }
    }

    @MainActor private func host<V: View>(_ view: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 180, y: 250, width: 330, height: 360),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Bello Agent — Synthetic Choice Fixture"
        window.contentView = NSHostingView(rootView: view)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    @MainActor private func close(_ window: NSWindow) { window.contentView = nil; window.close() }

    @MainActor private func settle(_ window: NSWindow, until condition: () -> Bool,
                                  file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
            window.contentView?.layoutSubtreeIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The native choice fixture did not settle", file: file, line: line)
    }

    @MainActor private func key(_ code: UInt16, _ characters: String, in window: NSWindow) async throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil,
                                                  characters: characters, charactersIgnoringModifiers: characters,
                                                  isARepeat: false, keyCode: code))
        window.sendEvent(event)
        let release = try XCTUnwrap(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil,
                                                    characters: characters, charactersIgnoringModifiers: characters,
                                                    isARepeat: false, keyCode: code))
        window.sendEvent(release)
        try await Task.sleep(for: .milliseconds(20))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    @MainActor private func activateNextKeyView(in window: NSWindow) async throws {
        window.selectNextKeyView(nil)
        try await key(49, " ", in: window)
    }

    private func requireInteractiveDesktop() throws {
        guard testEnvironment("PI_APP_INTERACTIVE_POINTER_TESTS") == "1" else {
            throw XCTSkip("Requires an unlocked interactive desktop and native input delivery; the isolated XCTest host cannot activate ordinary SwiftUI buttons.")
        }
    }

    /// Opt-in only. The hosted test app cannot receive real pointer activation
    /// while WindowServer's lock window covers the interactive session.
    @MainActor private func clickText(_ title: String, in window: NSWindow) async throws {
        let lines = try await renderedLines(window)
        let line = try XCTUnwrap(lines.first { $0.text.localizedCaseInsensitiveContains(title) },
                                 "Rendered control missing: \(title). Visible: \(lines.map(\.text))")
        let point = NSPoint(x: line.bounds.midX * window.frame.width, y: line.bounds.midY * window.frame.height)
        let content = try XCTUnwrap(window.contentView)
        XCTAssertNotNil(content.hitTest(content.convert(point, from: nil)))
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                                   timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil,
                                                   eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime + 0.01,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: 2, clickCount: 1, pressure: 0))
        NSApp.postEvent(up, atStart: true); NSApp.sendEvent(down)
        if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
            if pending.windowNumber == window.windowNumber { NSApp.sendEvent(pending) }
            else { NSApp.postEvent(pending, atStart: true) }
        }
        try await Task.sleep(for: .milliseconds(30))
    }

    @MainActor private func renderedLines(_ window: NSWindow, capture: String? = nil) async throws -> [(text: String, bounds: CGRect)] {
        // Allow the window compositor to display SwiftUI's completed layout.
        // Keyboard readiness is verified by the resulting actions, not an
        // arbitrary delay standing in for an AX-selected/focused assertion.
        try await Task.sleep(for: .milliseconds(200))
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        typealias ListImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let symbol = try XCTUnwrap(dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage"))
        let create = unsafeBitCast(symbol, to: ListImage.self)
        let image = try XCTUnwrap(create(.null, CGWindowListOption.optionIncludingWindow.rawValue,
                                        UInt32(window.windowNumber), CGWindowImageOption.boundsIgnoreFraming.rawValue)?.takeRetainedValue())
        if let capture, let path = testEnvironment("PI_APP_CHOICE_CAPTURE_ROOT") {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let jpeg = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.82]))
            try jpeg.write(to: folder.appendingPathComponent(capture + ".jpg"), options: .atomic)
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]; request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { item in
            item.topCandidates(1).first.map { (text: $0.string, bounds: item.boundingBox) }
        }
    }

    private var standardChoices: [PiChoice<String>] {
        [PiChoice(id: "first", title: "First fixture option"),
         PiChoice(id: "disabled", title: "Disabled fixture option", enabled: false),
         PiChoice(id: "last", title: "Last fixture option")]
    }

    @MainActor func testImmediateReturnOnMountedListCommitsTheSavedChoice() async throws {
        let state = ChoiceState(choices: standardChoices, selection: "first"), window = host(ChoiceFixture(state: state))
        defer { close(window) }
        _ = try await renderedLines(window)
        try await key(36, "\r", in: window)
        try await settle(window) { state.committed == ["first"] }
        XCTAssertEqual(state.selection, "first")
    }

    @MainActor func testInitialKeyboardTargetKeepsAnEnabledSelectionAndSkipsUnavailableChoices() {
        XCTAssertEqual(PiChoiceList.initialChoice(standardChoices, selection: "last"), "last")
        XCTAssertEqual(PiChoiceList.initialChoice(standardChoices, selection: "disabled"), "first")
        XCTAssertEqual(PiChoiceList.initialChoice(standardChoices, selection: "removed"), "first")
        XCTAssertNil(PiChoiceList<String>.initialChoice([], selection: "removed"))
        XCTAssertNil(PiChoiceList.initialChoice([PiChoice(id: "only", title: "Unavailable", enabled: false)], selection: "only"))
    }

    @MainActor func testArrowNavigationSkipsDisabledChoicesAndStopsAtTheListEdges() {
        XCTAssertEqual(PiChoiceList.nextChoice(standardChoices, after: "first", delta: 1), "last")
        XCTAssertEqual(PiChoiceList.nextChoice(standardChoices, after: "last", delta: -1), "first")
        XCTAssertEqual(PiChoiceList.nextChoice(standardChoices, after: "first", delta: -1), "first")
        XCTAssertEqual(PiChoiceList.nextChoice(standardChoices, after: "last", delta: 1), "last")
        XCTAssertEqual(PiChoiceList.nextChoice(standardChoices, after: "removed", delta: 1), "first")
        XCTAssertEqual(PiChoiceList.nextChoice(standardChoices, after: "removed", delta: -1), "last")
        XCTAssertNil(PiChoiceList<String>.nextChoice([], after: nil, delta: 1))
    }

    @MainActor func testHostedKeyboardMovementDoesNotSaveUntilReturnAndEscapeCancels() async throws {
        let state = ChoiceState(choices: standardChoices, selection: "first"), window = host(ChoiceFixture(state: state))
        defer { close(window) }
        let visible = try await renderedLines(window).map(\.text).joined(separator: " ")
        XCTAssertTrue(visible.contains("First fixture option")); XCTAssertTrue(visible.contains("Last fixture option"))
        try await key(125, "\u{F701}", in: window)
        XCTAssertEqual(state.selection, "first", "Arrow navigation must not apply a connection or preference")
        XCTAssertTrue(state.committed.isEmpty)
        try await key(36, "\r", in: window)
        try await settle(window) { state.committed == ["last"] }
        XCTAssertEqual(state.selection, "last", "Return must commit the enabled row beyond the disabled option exactly once")
        try await key(126, "\u{F700}", in: window)
        XCTAssertEqual(state.selection, "last")
        try await key(53, "\u{1b}", in: window)
        try await settle(window) { state.cancelled == 1 }
        XCTAssertEqual(state.committed, ["last"], "Escape must not commit a row traversed with the keyboard")
    }

    @MainActor func testInteractivePointerSelectionHonorsDisabledRowsAndManagementAction() async throws {
        try requireInteractiveDesktop()
        let state = ChoiceState(choices: standardChoices, selection: "first"), window = host(ChoiceFixture(state: state))
        defer { close(window) }
        try await clickText("Disabled fixture option", in: window)
        XCTAssertTrue(state.committed.isEmpty)
        try await clickText("Last fixture option", in: window)
        try await settle(window) { state.committed == ["last"] }
        XCTAssertEqual(state.selection, "last")
        try await clickText("Manage fixture choices", in: window)
        try await settle(window) { state.actions == 1 }
        XCTAssertEqual(state.committed, ["last"])
    }

    @MainActor func testRefreshedChoicesReplaceRenderedRowsAndTheKeyboardTargetWhileOpen() async throws {
        let state = ChoiceState(choices: standardChoices, selection: "first"), window = host(ChoiceFixture(state: state))
        defer { close(window) }
        _ = try await renderedLines(window, capture: "selected-first")
        state.selection = "last"
        _ = try await renderedLines(window, capture: "selected-last")
        XCTAssertTrue(state.committed.isEmpty, "An external saved-choice update does not invoke the commit action")
        state.choices = [PiChoice(id: "new", title: "New catalog option"),
                         PiChoice(id: "blocked", title: "Unavailable new option", enabled: false)]
        let text = try await renderedLines(window).map(\.text).joined(separator: " ")
        XCTAssertTrue(text.contains("New catalog option")); XCTAssertFalse(text.contains("First fixture option"))
        try await key(36, "\r", in: window)
        try await settle(window) { state.committed == ["new"] }
        XCTAssertEqual(state.selection, "new", "A removed keyboard target must not commit a stale catalog value")
    }

    @MainActor func testEmptyAndAllDisabledChoicesNeverCommitAndShowTheManagementAction() async throws {
        let state = ChoiceState(choices: [], selection: nil), window = host(ChoiceFixture(state: state))
        defer { close(window) }
        let emptyText = try await renderedLines(window).map(\.text).joined(separator: " ")
        XCTAssertTrue(emptyText.contains("No available choices"))
        try await key(125, "\u{F701}", in: window); try await key(36, "\r", in: window)
        XCTAssertTrue(state.committed.isEmpty)
        try await key(53, "\u{1b}", in: window)
        try await settle(window) { state.cancelled == 1 }
        state.choices = [PiChoice(id: "blocked", title: "Unavailable fixture", enabled: false)]
        _ = try await renderedLines(window)
        try await key(126, "\u{F700}", in: window); try await key(36, "\r", in: window)
        XCTAssertTrue(state.committed.isEmpty)
        try await key(53, "\u{1b}", in: window)
        try await settle(window) { state.cancelled == 2 }
        let text = try await renderedLines(window).map(\.text).joined(separator: " ")
        XCTAssertTrue(text.contains("Manage fixture choices"))
    }

    @MainActor func testChoiceContentShowsTitlesAndSubtitlesInBothAppearances() async throws {
        let state = ChoiceState(choices: [
            PiChoice(id: "first", title: "First fixture option", subtitle: "Use the default connection"),
            PiChoice(id: "disabled", title: "Disabled fixture option", subtitle: "Unavailable while a turn is running", enabled: false),
            PiChoice(id: "last", title: "Last fixture option", subtitle: "Use the alternate connection")
        ], selection: "first")
        let window = host(ChoiceFixture(state: state)); defer { close(window) }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            let text = try await renderedLines(window, capture: "choices-" + name).map(\.text).joined(separator: " ")
            for expected in ["First fixture option", "Use the default connection", "Disabled fixture option", "Last fixture option", "Manage fixture choices"] {
                XCTAssertTrue(text.contains(expected), "Missing visible text in \(name): \(expected). Rendered: \(text)")
            }
        }
    }

    @MainActor func testInteractivePickerPopoverKeyboardActivationAndDismissal() async throws {
        try requireInteractiveDesktop()
        guard NSApp.isFullKeyboardAccessEnabled else { throw XCTSkip("Popover trigger activation also requires macOS full keyboard navigation.") }
        let state = ChoiceState(choices: [
            PiChoice(id: "first", title: "First fixture option", subtitle: "Use the default connection"),
            PiChoice(id: "disabled", title: "Disabled fixture option", subtitle: "Unavailable while a turn is running", enabled: false),
            PiChoice(id: "last", title: "Last fixture option", subtitle: "Use the alternate connection")
        ], selection: "first")
        let window = host(PickerFixture(state: state))
        defer { close(window) }
        let originalWindows = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
        func popup() -> NSWindow? { NSApp.windows.first { $0.isVisible && !originalWindows.contains($0.windowNumber) } }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            state.selection = "first"; state.committed.removeAll()
            _ = try await renderedLines(window)
            window.makeFirstResponder(nil)
            try await activateNextKeyView(in: window)
            try await settle(window) { popup() != nil }
            let firstPopup = try XCTUnwrap(popup())
            let visible = try await renderedLines(firstPopup, capture: "choices-" + name).map(\.text).joined(separator: " ")
            XCTAssertTrue(visible.contains("First fixture option")); XCTAssertTrue(visible.contains("Use the default connection"))
            XCTAssertTrue(visible.contains("Manage fixture choices"))
            try await key(36, "\r", in: firstPopup)
            try await settle(window) { state.committed == ["first"] && popup() == nil }
            XCTAssertEqual(state.selection, "first", "Return on a freshly opened popover must apply its saved choice, not a later row")
            state.committed.removeAll()
            _ = try await renderedLines(window)
            window.makeFirstResponder(nil)
            try await activateNextKeyView(in: window)
            try await settle(window) { popup() != nil }
            let cancellationPopup = try XCTUnwrap(popup())
            _ = try await renderedLines(cancellationPopup)
            try await key(125, "\u{F701}", in: cancellationPopup)
            XCTAssertEqual(state.selection, "first")
            try await key(53, "\u{1b}", in: cancellationPopup)
            try await settle(window) { popup() == nil }
            XCTAssertTrue(state.committed.isEmpty, "Dismissal must not apply the highlighted row")
            _ = try await renderedLines(window)
            window.makeFirstResponder(nil)
            try await activateNextKeyView(in: window)
            try await settle(window) { popup() != nil }
            let reopened = try XCTUnwrap(popup())
            _ = try await renderedLines(reopened)
            try await key(125, "\u{F701}", in: reopened)
            try await key(36, "\r", in: reopened)
            try await settle(window) { state.committed == ["last"] && popup() == nil }
            XCTAssertEqual(state.selection, "last")
        }
    }
}
