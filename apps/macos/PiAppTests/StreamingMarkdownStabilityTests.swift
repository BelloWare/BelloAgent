import XCTest
import SwiftUI
import AppKit
@testable import PiApp

final class StreamingMarkdownStabilityTests: XCTestCase {
    func testAmbiguousTailStaysLiteralAndDoesNotSwallowPartialFenceInfo() {
        for source in ["A **bold** and an unfinished [link](", "```sw", "# partial heading", "日本🙂 e\u{301} `unfinished"] {
            let blocks=TranscriptMarkdown.streamingBlocks(source)
            guard case .paragraph(let text) = blocks.first else { XCTFail("An unfinished tail should remain literal: \(source)"); continue }
            XCTAssertEqual(String(text.characters),source)
        }
    }
    @MainActor func testStreamingContainerSurvivesEightBlocksAndTerminalCompletion() {
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:700,height:700),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        let host=NSHostingView(rootView:MarkdownBodyView(source:"First paragraph",streaming:true))
        window.contentView=host; window.orderFront(nil)
        defer { window.contentView=nil; window.close() }
        func native(_ view:NSView)->NativeMarkdownContainer? { (view as? NativeMarkdownContainer) ?? view.subviews.lazy.compactMap(native).first }
        host.layoutSubtreeIfNeeded()
        guard let first=native(host) else { return XCTFail("Streaming must establish its persistent native container before eight blocks") }
        let source=(0..<12).map { "Paragraph \($0)." }.joined(separator:"\n\n")
        host.rootView=MarkdownBodyView(source:source,streaming:true); host.layoutSubtreeIfNeeded()
        XCTAssertTrue(native(host) === first)
        host.rootView=MarkdownBodyView(source:source,streaming:false); host.layoutSubtreeIfNeeded()
        XCTAssertTrue(native(host) === first,"Terminal reconciliation must retain selection and geometry ownership")
    }
}

extension StreamingMarkdownStabilityTests {
    func testChunkedSyntaxKeepsRawSourceStableIDsAndCanonicalTerminalRendering() {
        let samples=[
            "Plain **bold** with [later][id].\n\nTail `incomplete\n\n[id]: https://example.com/ref\n",
            "```swift\nlet a = `literal`\n```\nImmediately after fence",
            "~~~~lang\n```inside\n~~~~\n\nEnding",
            "- one\n  - nested\n\n- two\n\n> quote\n> continuation\n\nHeading\n===\n",
            "| A | B |\n|---|---|\n| 中文🙂 | e\u{301} |\n| more | value |\n",
            "CJK 中文🙂 e\u{301} **text** <script>literal</script> [bad](javascript:evil)"
        ]
        for (sampleIndex, source) in samples.enumerated() {
            let state=StreamingMarkdownState(), bytes=Array(source.utf8)
            var offset=0, seed=UInt64(sampleIndex+1), stable:[MarkdownBlockIdentity:MarkdownBlock]=[:]
            while offset < bytes.count {
                seed = seed &* 6364136223846793005 &+ 1; offset=min(bytes.count,offset+1+Int(seed%13))
                guard let prefix=String(bytes:bytes[..<offset],encoding:.utf8) else { continue }
                let records=state.update(prefix,style:.prose,streaming:true,identity:"opaque-id/🙂")
                XCTAssertEqual(state.source,prefix); XCTAssertEqual(Set(records.map(\.id)).count,records.count)
                for record in records where !record.provisional {
                    if let previous=stable[record.id] { XCTAssertEqual(previous,record.block,"An unrelated append changed settled content") }
                    stable[record.id]=record.block
                }
            }
            let terminal=state.update(source,style:.prose,streaming:false,identity:"opaque-id/🙂")
            XCTAssertEqual(terminal.map(\.block),TranscriptMarkdown.parse(source)); XCTAssertEqual(state.source,source)
            XCTAssertEqual(Set(terminal.map(\.id)).count,terminal.count)
            let generation=state.generation
            let retry=state.update("Retry: fresh",style:.prose,streaming:true,identity:"opaque-id/🙂")
            XCTAssertGreaterThan(state.generation,generation); XCTAssertEqual(retry.count,1)
            XCTAssertEqual(state.source,"Retry: fresh")
        }
    }
    func testProvisionalSelectionMapsThroughCanonicalMarkupUsingSourcePositions() {
        let raw="Select **bold** here with [a link](https://example.com)."
        let range=(raw as NSString).range(of:"bold")
        let final="Select bold here with a link."
        XCTAssertEqual(MarkdownSelection.canonicalRange(range,literal:raw,source:raw,rendered:final,keepsSoftBreaks:false),(final as NSString).range(of:"bold"))
        let unicode="日本🙂 **e\u{301}**"; let displayed="日本🙂 e\u{301}"
        XCTAssertEqual(MarkdownSelection.canonicalRange((unicode as NSString).range(of:"e\u{301}"),literal:unicode,source:unicode,rendered:displayed,keepsSoftBreaks:false),(displayed as NSString).range(of:"e\u{301}"))
    }
    func testTextAfterConfirmedFenceAndTableRemainsVisibleBeforeCompletion() {
        for source in ["```swift\ncode\n```\nDo not hide this", "|a|b|\n|-|-|\n|1|2|\nDo not hide this"] {
            let preview=TranscriptMarkdown.streamingBlocks(source)
            let visible=preview.flatMap { block -> [String] in
                switch block {
                case .paragraph(let text): return [String(text.characters)]
                case .table(_,let header,let rows): return (header + rows.flatMap { $0 }).map { String($0.characters) }
                default: return []
                }
            }.joined(separator:"\n")
            XCTAssertTrue(visible.contains("Do not hide this"), "Content after a confirmed container must remain visible: \(source)")
        }
    }
    @MainActor func testOpenCodeSelectionOwnerSurvivesThresholdCloseAndCompletion() async throws {
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:650,height:500),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        let host=NSHostingView(rootView:MarkdownBodyView(source:"```sw",streaming:true,sourceIdentity:"reply"))
        window.contentView=host; window.makeKeyAndOrderFront(nil)
        defer { window.contentView=nil; window.close() }
        func descendants<T:NSView>(_ type:T.Type,_ view:NSView)->[T] { (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type,$0) } }
        func update(_ text:String,_ streaming:Bool) async {
            host.rootView=MarkdownBodyView(source:text,streaming:streaming,sourceIdentity:"reply")
            for _ in 0..<3 { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); await Task.yield() }
        }
        var source="```swift\nlet selected = 1\n"
        await update(source,true)
        let container=try XCTUnwrap(descendants(NativeMarkdownContainer.self,host).first)
        let owner=try XCTUnwrap(descendants(TranscriptCodeTextView.self,host).first)
        XCTAssertTrue(window.makeFirstResponder(owner))
        let selection=NSRange(location:4,length:8); owner.setSelectedRange(selection)
        let blockID=container.blockOwnerIdentities.first
        source += String(repeating:"// long line 中文🙂\n",count:1000)
        await update(source,true)
        XCTAssertTrue(descendants(TranscriptCodeTextView.self,host).contains { $0 === owner })
        XCTAssertEqual(owner.selectedRange(),selection); XCTAssertEqual(container.blockOwnerIdentities.first,blockID)
        source += "```\n\nFinished."
        await update(source,true); await update(source,false)
        XCTAssertTrue(descendants(NativeMarkdownContainer.self,host).first === container)
        XCTAssertTrue(descendants(TranscriptCodeTextView.self,host).contains { $0 === owner })
        XCTAssertEqual(owner.selectedRange(),selection); XCTAssertEqual(container.blockOwnerIdentities.first,blockID)
        XCTAssertFalse(owner.string.contains("```")); XCTAssertTrue(owner.string.contains("long line 中文🙂"))
    }
    @MainActor func testPresentationHasOneTrailingUpdateAndFlushesFirstFinalAndRebind() async throws {
        let session=SessionDisplay(id:"a"), page=TranscriptPage()
        session.messages=[TranscriptMessage(id:"u",role:"user",text:"ask")]; page.bind(session)
        session.messages.append(TranscriptMessage(id:"answer",role:"assistant",text:"first",state:"streaming"))
        XCTAssertEqual(page.snapshot?.messages.last?.text,"first","First useful text must be leading")
        for index in 0..<100 { session.messages[1].text="first \(index)" }
        XCTAssertEqual(session.messages.last?.text,"first 99","Authoritative display source is never held back")
        XCTAssertEqual(page.pendingPresentationCount,1)
        try await Task.sleep(for:.milliseconds(60))
        XCTAssertEqual(page.snapshot?.messages.last?.text,"first 99"); XCTAssertEqual(page.pendingPresentationCount,0)
        session.messages[1].text="pending tail"
        session.messages[1].state="error"
        XCTAssertEqual(page.snapshot?.messages.last?.text,"pending tail"); XCTAssertEqual(page.snapshot?.messages.last?.state,"error")
        XCTAssertEqual(page.pendingPresentationCount,0)
        session.messages[1].state="streaming"; session.messages[1].text="old pane"
        let side=SessionDisplay(id:"side"); page.bind(side)
        try await Task.sleep(for:.milliseconds(60))
        XCTAssertEqual(page.snapshot?.sessionID,"side"); XCTAssertFalse(page.snapshot?.messages.contains { $0.text == "old pane" } ?? true)
    }
}

extension StreamingMarkdownStabilityTests {
    @MainActor func testShortAnswerPresentationCostAndLiteralCaretSelection() async throws {
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:620,height:240),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        let host=NSHostingView(rootView:AnyView(EmptyView()))
        window.contentView=host; window.makeKeyAndOrderFront(nil)
        defer { window.contentView=nil; window.close() }
        var old:[Double]=[], current:[Double]=[]
        for index in 0..<20 {
            let source="A short plain answer \(index)."
            var start=ProcessInfo.processInfo.systemUptime
            host.rootView=AnyView(VStack(alignment:.leading,spacing:10) {
                MarkdownBlockView(block:TranscriptMarkdown.blocks(source)[0],style:.prose,capsWidth:true,caret:true)
            }.textSelection(.enabled))
            _=host.fittingSize; host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            old.append((ProcessInfo.processInfo.systemUptime-start)*1000)
            start=ProcessInfo.processInfo.systemUptime
            host.rootView=AnyView(MarkdownBodyView(source:source,streaming:true))
            _=host.fittingSize; host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            current.append((ProcessInfo.processInfo.systemUptime-start)*1000)
        }
        print(String(format:"REVIEW short-answer container: SwiftUI stack %.2f ms mean; persistent native %.2f ms mean (20 cold short answers)",old.reduce(0,+)/20,current.reduce(0,+)/20))
        func fields(_ view:NSView)->[NSTextField] {
            if let field=view as? NSTextField { return [field] }
            var result:[NSTextField]=[]
            for child in view.subviews { result.append(contentsOf:fields(child)) }
            return result
        }
        let field=try XCTUnwrap(fields(host).first { $0.isSelectable && $0.stringValue.hasPrefix("A short plain answer") })
        field.selectText(nil)
        let editor=try XCTUnwrap(field.currentEditor()); editor.selectedRange=NSRange(location:2,length:5)
        try await Task.sleep(for:.milliseconds(550)); host.layoutSubtreeIfNeeded()
        XCTAssertTrue(field.currentEditor() === editor); XCTAssertEqual(editor.selectedRange,NSRange(location:2,length:5))
        host.rootView=AnyView(MarkdownBodyView(source:"A short plain answer 19.",streaming:false)); host.layoutSubtreeIfNeeded()
        XCTAssertTrue(field.currentEditor() === editor,"Completion removes the decorative caret without replacing selectable prose")
        XCTAssertEqual(editor.selectedRange,NSRange(location:2,length:5))
    }
}


extension StreamingMarkdownStabilityTests {
    @MainActor func testSelectedLiteralBoldKeepsItsSelectionAfterCanonicalCompletion() async throws {
        for (raw, rendered) in [("Select **bold** here", "Select bold here"),
                                ("**one** **two** **three** **bold**", "one two three bold")] {
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:620,height:240),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        let host=NSHostingView(rootView:MarkdownBodyView(source:raw,streaming:true))
        window.contentView=host; window.makeKeyAndOrderFront(nil)
        defer { window.contentView=nil; window.close() }
        func fields(_ view:NSView)->[NSTextField] {
            if let field=view as? NSTextField { return [field] }
            return view.subviews.flatMap { fields($0) }
        }
        _=host.fittingSize; host.layoutSubtreeIfNeeded()
        let field=try XCTUnwrap(fields(host).first { $0.stringValue == raw })
        field.selectText(nil)
        let editor=try XCTUnwrap(field.currentEditor()); editor.selectedRange=(raw as NSString).range(of:"bold")
        host.rootView=MarkdownBodyView(source:raw,streaming:false)
        for _ in 0..<3 { _=host.fittingSize; host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); await Task.yield() }
        XCTAssertTrue(field.currentEditor() === editor)
        XCTAssertEqual(editor.string,rendered)
        XCTAssertEqual(editor.selectedRange,(rendered as NSString).range(of:"bold"))
        }
    }
}
