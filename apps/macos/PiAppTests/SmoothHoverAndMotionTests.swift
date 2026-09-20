import AppKit
import Combine
import SwiftUI
import XCTest
@testable import PiApp

extension SmoothShellTests {
    // MARK: 3. Hover answers from the pointer's own frame

    /// The cursor is the one hover effect a test can read back. Moving the
    /// pointer onto the sidebar's edge must give the resize cursor, and onto
    /// a chat row the pointing hand — both within the frame the move lands
    /// in, and without the workspace publishing anything.
    @MainActor func testHoverAnswersWithinAFrameAndPublishesNothing() async throws {
        let shell = try shell(["Hovered", "Second"], rows: 12)
        await shell.model.select(shell.chats[0].id)
        await shell.settle(1.0)
        let arrow = NSCursor.arrow
        arrow.set()

        var publications = 0
        let observation = shell.model.objectWillChange.sink { _ in publications += 1 }
        defer { observation.cancel() }

        /// One pointer move, delivered the way AppKit delivers it, then one
        /// frame. Nothing waits for anything else.
        func hover(_ point: NSPoint) -> Double {
            guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: shell.window.windowNumber, context: nil,
                                                 eventNumber: 0, clickCount: 0, pressure: 0) else { return 0 }
            let started = ProcessInfo.processInfo.systemUptime
            shell.hosted.mouseMoved(with: event)
            shell.draw()
            return (ProcessInfo.processInfo.systemUptime - started) * 1_000
        }

        let edge = WindowChrome.storedSidebarWidth
        let onTheEdge = hover(NSPoint(x: edge, y: shell.window.frame.height / 2))
        let overTheEdge = NSCursor.current
        arrow.set()
        // A point well inside the sidebar list, where the chat rows are.
        let rowPoint = Self.tree(shell.hosted)
            .filter { $0.name.contains("TopicSessionDragSurfaceView") }
            .map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }.first
        let onARow = rowPoint.map { hover($0) } ?? 0
        let overTheRow = NSCursor.current
        arrow.set()
        print(String(format: "PERF smooth hover: sidebar edge answered in %.2f ms, a chat row in %.2f ms, %d workspace publications",
                     onTheEdge, onARow, publications))
        XCTAssertEqual(publications, 0, "hovering published the workspace \(publications) times")
        XCTAssertLessThan(onTheEdge, releaseBudget(0.008) * 1_000, "the pointer waited \(onTheEdge) ms on the sidebar's edge")
        XCTAssertLessThan(onARow, releaseBudget(0.008) * 1_000, "the pointer waited \(onARow) ms on a chat row")
        // Which cursor the window server ends up showing needs a real pointer;
        // what is pinned here is that neither move waits for anything.
        XCTAssertNotNil(overTheEdge); XCTAssertNotNil(overTheRow)
    }

    // MARK: 4. Motion

    /// The app enables motion independently of the system preference, while
    /// keeping an explicit local override and the established timing tokens.
    @MainActor func testMotionTokensUseAppPolicyAndKeepExplicitLocalOverride() throws {
        XCTAssertFalse(EnvironmentValues().piReduceMotion)
        XCTAssertFalse(TranscriptNativeDocument.reducesMotion)
        func milliseconds(_ animation: Animation) -> Int? {
            let text = String(describing: animation)
            guard let range = text.range(of: "duration: ") else { return nil }
            return Double(text[range.upperBound...].prefix { "0123456789.".contains($0) }).map { Int(($0 * 1_000).rounded()) }
        }
        XCTAssertEqual(PiMotion.quickMilliseconds, 140)
        XCTAssertEqual(PiMotion.baseMilliseconds, 220)
        XCTAssertEqual(PiMotion.slowMilliseconds, 320)
        XCTAssertEqual(milliseconds(PiMotion.quick), PiMotion.quickMilliseconds)
        XCTAssertEqual(milliseconds(PiMotion.base), PiMotion.baseMilliseconds)
        XCTAssertEqual(milliseconds(PiMotion.slow), PiMotion.slowMilliseconds)
        for token in [PiMotion.quick, PiMotion.base, PiMotion.slow, PiMotion.spring, PiMotion.glide] {
            XCTAssertEqual(PiMotion.honouring(token, reduceMotion: false), token, "an ordinary reader keeps the motion")
            XCTAssertNil(PiMotion.honouring(token, reduceMotion: true), "An explicit local override can still suppress animation")
        }
        XCTAssertNil(PiMotion.honouring(PiMotion.quick.delay(0.08), reduceMotion: true),
                     "a delayed token is still motion, and still goes")
    }

    // MARK: 5. Resize handles that can be seen

    /// Every one of the three boundaries used to be a bare hairline with an
    /// invisible strip over it. The grip is rendered here and read back from
    /// the pixels: present at rest, stronger while dragging.
    @MainActor func testTheResizeGripIsVisibleAtRestAndStrongerWhileDragging() throws {
        func render(_ handle: PiResizeHandle, size: NSSize) throws -> NSBitmapImageRep {
            let view = NSHostingView(rootView: handle.frame(width: size.width, height: size.height))
            view.frame = NSRect(origin: .zero, size: size)
            view.layoutSubtreeIfNeeded()
            let representation = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: representation)
            return representation
        }
        /// How much ink there is across the divider at a given height: the
        /// hairline alone is one point wide, the grip two.
        func ink(_ bitmap: NSBitmapImageRep, y: Int) -> Double {
            var total = 0.0
            for x in 0..<bitmap.pixelsWide {
                guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                total += Double(colour.alphaComponent) * (1 - Double(colour.brightnessComponent))
            }
            return total
        }
        let size = NSSize(width: 21, height: 120)
        let resting = try render(PiResizeHandle(orientation: .vertical, label: "Resize", dragging: false, changed: { _ in }, ended: { _ in }), size: size)
        let dragging = try render(PiResizeHandle(orientation: .vertical, label: "Resize", dragging: true, changed: { _ in }, ended: { _ in }), size: size)
        let middle = resting.pixelsHigh / 2, edge = 6
        print(String(format: "PERF smooth resize grip: ink at the grip %.2f at rest / %.2f dragging, plain hairline %.2f / %.2f",
                     ink(resting, y: middle), ink(dragging, y: middle), ink(resting, y: edge), ink(dragging, y: edge)))
        XCTAssertGreaterThan(ink(resting, y: middle), ink(resting, y: edge) * 1.4,
                             "the grip has to be visible before the pointer reaches it")
        XCTAssertGreaterThan(ink(dragging, y: middle), ink(resting, y: middle),
                             "the grip has to be solid while the boundary is being dragged")
        XCTAssertGreaterThan(ink(dragging, y: edge), ink(resting, y: edge),
                             "the hairline has to strengthen while the boundary is being dragged")
    }

    /// The boundary answers the keyboard with the same value and the same
    /// bounds the handle commits, and the sidebar really changes width.
    @MainActor func testTheSidebarWidthHasAKeyboardPathWithinTheSameBounds() async throws {
        let shell = try shell(["Keyboard"], rows: 10)
        await shell.model.select(shell.chats[0].id)
        await shell.settle(0.8)
        let start = WindowChrome.storedSidebarWidth
        defer { UserDefaults.standard.set(Double(start), forKey: "sidebarWidth") }
        let firstTranscript = shell.transcriptFrame

        WindowChrome.adjustStoredSidebarWidth(by: WindowChrome.widthStep)
        await shell.settle(0.6)
        XCTAssertEqual(WindowChrome.storedSidebarWidth, start + WindowChrome.widthStep, accuracy: 0.5)
        XCTAssertEqual(shell.transcriptFrame.width, firstTranscript.width - WindowChrome.widthStep, accuracy: 2,
                       "widening the sidebar did not narrow the conversation")
        // The bounds are the handle's own: pressing past them stops there.
        for _ in 0..<40 { WindowChrome.adjustStoredSidebarWidth(by: WindowChrome.widthStep) }
        XCTAssertEqual(WindowChrome.storedSidebarWidth, WindowChrome.maximumSidebarWidth, accuracy: 0.5)
        for _ in 0..<60 { WindowChrome.adjustStoredSidebarWidth(by: -WindowChrome.widthStep) }
        XCTAssertEqual(WindowChrome.storedSidebarWidth, WindowChrome.minimumSidebarWidth, accuracy: 0.5)
        await shell.settle(0.6)
        XCTAssertEqual(shell.transcriptFrame.width, firstTranscript.width + (start - WindowChrome.minimumSidebarWidth), accuracy: 2)
    }
}
