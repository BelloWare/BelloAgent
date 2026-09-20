import SwiftUI
import AppKit

struct PagedTextView: NSViewRepresentable {
    let text: String
    var accessibilityLabel = "Read-only payload text"
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false; scroll.borderType = .noBorder
        scroll.drawsBackground = false; scroll.autohidesScrollers = true
        let editor = NSTextView(); editor.isEditable = false; editor.isSelectable = true; editor.isRichText = false; editor.drawsBackground = false
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular); editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.setAccessibilityLabel(accessibilityLabel); scroll.documentView = editor; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView, editor.string != text else { return }
        editor.string = text
        DispatchQueue.main.async { [weak editor] in editor?.scrollToBeginningOfDocument(nil) }
    }
}

struct RetainedMessageViewer: View {
    @ObservedObject var model: WorkspaceModel
    @State private var messageID = ""
    @State private var field = "text"
    @State private var text = ""
    @State private var offset = 0
    @State private var previousOffsets: [Int] = []
    @State private var total = 0
    @State private var error = ""
    @Environment(\.dismiss) private var dismiss
    private var pageLength: Int { (text as NSString).length }
    private var completedMessages: [TranscriptMessage] {
        (model.displays[model.messageViewerSessionID ?? model.selectedID ?? ""]?.messages ?? []).filter { !$0.id.hasPrefix("stream:") && $0.role != "system" }
    }
    private var messages: [(String, String)] {
        [("", "Choose completed message")] + completedMessages.enumerated().map { index, message in
            (message.id, "\(index + 1). " + (message.text.isEmpty ? "No text content" : String(message.text.prefix(55))))
        }
    }
    var body: some View {
        PiSheet("Retained message", subtitle: "A paged presentation of the retained message. This is not raw HTTP capture.", symbol: "doc.text.magnifyingglass", width: 900, height: 680) {
            VStack(alignment: .leading, spacing: PiSpacing.md) {
                HStack(spacing: PiSpacing.md) {
                    PiDropdown(selection: $messageID, items: messages, placeholder: "Choose completed message", icon: "text.bubble")
                        .accessibilityLabel("Retained message")
                        .accessibilityValue(completedMessages.first { $0.id == messageID }.map { "\($0.role) message: \(String($0.text.prefix(55)))" } ?? "Choose completed message")
                    Spacer()
                    PiTabs(selection: $field, items: [("text", "Text / tool output"), ("thinking", "Exposed reasoning")])
                }
                PagedTextView(text: text).piInset()
                PiStatusLine(text: error, tone: .danger)
            }.padding(PiSpacing.xl)
        } actions: {
            Button("Done") { dismiss() }
        } footer: {
            HStack {
                PiPager(previous: { offset = previousOffsets.popLast() ?? 0; load() }, next: { previousOffsets.append(offset); offset += pageLength; load() },
                        canPrevious: offset != 0, canNext: offset + pageLength < total) {
                    Text("UTF-16 characters \(offset)–\(offset + pageLength) of \(total)")
                }
                Spacer()
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) } label: { Label("Copy Page", systemImage: "doc.on.doc") }.disabled(text.isEmpty)
            }
        }
        .onChange(of: messageID) { _, _ in offset = 0; previousOffsets = []; load() }
        .onChange(of: field) { _, _ in offset = 0; previousOffsets = []; load() }
    }
    private func load() {
        guard !messageID.isEmpty else { return }
        let id = messageID, requestedField = field, requestedOffset = offset
        Task { do {
            let page = try await model.messagePage(id: id, field: requestedField, offset: requestedOffset, sessionID: model.messageViewerSessionID)
            guard id == messageID, requestedField == field, requestedOffset == offset else { return }
            text = page.0; total = page.1; error = ""
        } catch { self.error = error.localizedDescription; text = "" } }
    }
}
