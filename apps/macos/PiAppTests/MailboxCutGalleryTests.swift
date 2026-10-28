import AppKit
import Darwin
import XCTest
@testable import PiApp

final class MailboxCutGalleryTests: XCTestCase, SerialTestLane {
    @MainActor func testCutMarkerAndCancelledCallScenes() async throws {
        guard let path = testEnvironment("PI_APP_CUTIN_GALLERY") else { throw XCTSkip("Set PI_APP_CUTIN_GALLERY") }
        let folder = URL(fileURLWithPath:path)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let fixture = try SubagentGalleryFixture(root:folder.appendingPathComponent("fixture"))
        addTeardownBlock { @MainActor in fixture.model.shutdown(); try? await fixture.model.traces.close(); await fixture.model.store?.close() }
        let previous = TranscriptDisplay.mode; TranscriptDisplay.use(.normal)
        defer { fixture.close(); TranscriptDisplay.use(previous) }
        var names: [String] = []
        for (appearance,theme) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            for width: CGFloat in [920,640] {
                fixture.window.appearance = NSAppearance(named:appearance); fixture.window.setContentSize(.init(width:width,height:760)); fixture.window.center()
                for scene in ["reasoning","commentary","cancelled-call"] {
                    fixture.showCodex("forked-start")
                    let session = fixture.parent
                    session.supportsMailboxCutin = true; session.runState = .running; session.receivingAgentMessage = true
                    var row = MailboxCutPresentationTests.row(text:scene == "reasoning" ? "" : "I have checked the request boundary and will apply the incoming agent message.",tool:scene == "cancelled-call")
                    row.turn = "question"; row.taskRootID = "question"
                    session.messages = [.init(id:"question",role:"user",text:"Check the stream and coordinate with the audit agent."),row]
                    await fixture.settle()
                    if scene == "cancelled-call" {
                        let revealed = await fixture.model.revealInTranscript(sessionID:session.id,messageID:row.id,toolCallID:"call-1")
                        XCTAssertTrue(revealed)
                        await fixture.settle()
                    }
                    let labels = accessibilityLabels(fixture.content)
                    XCTAssertTrue(labels.contains { $0.contains("Reply cut for agent message") },scene)
                    if scene == "cancelled-call" { XCTAssertTrue(labels.contains { $0.contains("Not run · agent message arrived") }) }
                    let name = "\(scene)-\(theme)-\(Int(width)).png"
                    try capture(fixture.window,to:folder.appendingPathComponent(name)); names.append(name)
                }
            }
        }
        XCTAssertEqual(names.count,12)
        try names.joined(separator:"\n").write(to:folder.appendingPathComponent("manifest.txt"),atomically:true,encoding:.utf8)
    }
    @MainActor private func accessibilityLabels(_ view: NSView) -> [String] {
        [view.accessibilityLabel()].compactMap { $0 } + view.subviews.flatMap { accessibilityLabels($0) }
    }
    @MainActor private func capture(_ window: NSWindow, to url: URL) throws {
        typealias ListImage = @convention(c) (CGRect,UInt32,UInt32,UInt32) -> Unmanaged<CGImage>?
        let symbol = try XCTUnwrap(dlsym(dlopen(nil,RTLD_NOW),"CGWindowListCreateImage"))
        let create = unsafeBitCast(symbol,to:ListImage.self)
        let screen = NSScreen.screens.first?.frame ?? .zero, frame = window.frame
        let bounds = CGRect(x:frame.minX,y:screen.height-frame.maxY,width:frame.width,height:frame.height)
        let options = CGWindowImageOption.bestResolution.rawValue | CGWindowImageOption.boundsIgnoreFraming.rawValue
        let captured = try XCTUnwrap(create(bounds,CGWindowListOption.optionIncludingWindow.rawValue,UInt32(window.windowNumber),options)?.takeRetainedValue())
        try XCTUnwrap(NSBitmapImageRep(cgImage:captured).representation(using:.png,properties:[:])).write(to:url)
    }
}
