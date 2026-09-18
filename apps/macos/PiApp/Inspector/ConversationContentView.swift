import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ConversationContentView: View {
    @ObservedObject var model: WorkspaceModel
    let sessionID: String
    @State private var query = ""
    @State private var selectedID: String?
    @State private var result = ContentSearch(hits: [], total: 0, next: nil, revision: "")
    @State private var first = 1
    @State private var last = 1
    @State private var busy = false
    @State private var notice = ""
    @Environment(\.dismiss) private var dismiss
    private var selected: ContentHit? { result.hits.first { $0.id == selectedID } }
    var body: some View {
        PiSheet("Search and copy conversation", subtitle: "Completed retained messages, including exposed reasoning and tool results. Opaque provider state and image bytes are omitted. Search covers the full retained branch; the transcript stays paged.", symbol: "magnifyingglass", width: 900, height: 700) {
            VStack(alignment: .leading, spacing: PiSpacing.md) {
                HStack(spacing: PiSpacing.sm) {
                    PiTextField(placeholder: "Find in retained conversation", text: $query, icon: "magnifyingglass", onSubmit: { search() })
                    Button("Search") { search() }.buttonStyle(.piPrimary).disabled(busy || query.count > 256)
                    if busy { ProgressView().controlSize(.small) }
                }
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(result.hits) { hit in
                            PiSelectableRow(selected: selectedID == hit.id, action: { selectedID = hit.id }) {
                                HStack(alignment: .top, spacing: PiSpacing.md) {
                                    Text("\(hit.position)").font(PiFont.caption.monospacedDigit()).foregroundStyle(Color.piInkTertiary).frame(width: 44, alignment: .trailing)
                                    Text(hit.preview).lineLimit(3).font(PiFont.body).foregroundStyle(Color.piInk)
                                }
                            }
                        }
                    }.padding(PiSpacing.sm)
                }
                .overlay { if result.hits.isEmpty { Text(busy ? "Searching…" : "No matches on this page").font(PiFont.caption).foregroundStyle(Color.piInkTertiary) } }
                .piInset().accessibilityLabel("Retained conversation search results")
                HStack(spacing: PiSpacing.sm) {
                    Text("\(result.hits.count) matches on this page · \(result.total) retained messages").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                    Spacer()
                    Button { search(start: result.next ?? 0) } label: { Label("Next Results", systemImage: "chevron.right") }.labelStyle(.trailingIcon).disabled(busy || result.next == nil)
                    Button { guard let selected else { return }; busy = true; Task { defer { busy = false }; do { try await model.revealConversationHit(sessionID, hit: selected); dismiss() } catch { notice = error.localizedDescription } } } label: { Label("Show in Transcript", systemImage: "text.viewfinder") }
                        .disabled(busy || selected == nil)
                }
                PiCard(padding: PiSpacing.md) {
                    VStack(alignment: .leading, spacing: PiSpacing.sm) {
                        Text("Copy range").font(PiFont.heading)
                        HStack(spacing: PiSpacing.sm) {
                            PiNumberField(placeholder: "From", value: $first, width: 110)
                            Text("through").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                            PiNumberField(placeholder: "Through", value: $last, width: 110)
                            Button("Start at Selection") { if let selected { first = selected.position } }.buttonStyle(.piSecondaryCompact).disabled(selected == nil || busy)
                            Button("End at Selection") { if let selected { last = selected.position } }.buttonStyle(.piSecondaryCompact).disabled(selected == nil || busy)
                            Spacer()
                        }
                    }
                }
                PiStatusLine(text: notice)
            }.padding(PiSpacing.xl)
        } actions: {
            Button("Done") { dismiss() }.disabled(busy)
        } footer: {
            HStack {
                Text("Copy limit: 8 MiB. Larger conversations can be copied in explicit ranges.").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                Spacer()
                Button { export() } label: { Label("Export…", systemImage: "square.and.arrow.up") }.disabled(busy || result.total == 0)
                    .help("Save the whole retained conversation as a Markdown text file")
                Button { copy(first: first, last: last) } label: { Label("Copy Range", systemImage: "doc.on.doc") }.disabled(busy || first < 1 || last < first || last > result.total)
                Button { copy(first: 1, last: result.total) } label: { Label("Copy Conversation", systemImage: "doc.on.doc.fill") }.buttonStyle(.piPrimary).disabled(busy || result.total == 0)
            }
        }
        .task { search() }
    }
    private func search(start: Int = 0) {
        guard !busy else { return }; busy = true
        Task { defer { busy = false }; do {
            let found = try await model.searchConversation(sessionID, query: query, start: start)
            if result.revision.isEmpty { last = max(1, found.total) }
            result = found; selectedID = nil; notice = ""
        } catch { notice = error.localizedDescription } }
    }
    private func collect(first: Int, last: Int, limit: Int, failure: String) async throws -> Data {
        let revision = result.revision
        var bytes = Data(), cursor: ContentCursor? = .init(index: first, offset: 0)
        while let next = cursor {
            let page = try await model.conversationPage(sessionID, first: first, last: last, cursor: next, revision: revision)
            guard bytes.count + page.text.utf8.count <= limit else { throw HostError.failure(failure) }
            bytes.append(contentsOf: page.text.utf8); cursor = page.next
        }
        return bytes
    }
    private func copy(first: Int, last: Int) {
        guard !busy else { return }; busy = true; notice = "Reading retained text…"
        Task { defer { busy = false }; do {
            let bytes = try await collect(first: first, last: last, limit: 8 * 1024 * 1024, failure: "This copy exceeds 8 MiB. Choose a smaller message range. The clipboard was not changed.")
            guard let text = String(data: bytes, encoding: .utf8) else { throw StoreError.invalidRecord }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            notice = "Copied messages \(first)–\(last) (\(bytes.count) UTF-8 bytes)."
        } catch { notice = error.localizedDescription } }
    }
    /// The same retained text as Copy Conversation, written to a file the user
    /// chooses, so a chat can leave the app without the clipboard size limit.
    private func export() {
        guard !busy, result.total > 0 else { return }
        let panel = NSSavePanel(); panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.nameFieldStringValue = (model.record(sessionID)?.title ?? "Conversation").replacingOccurrences(of: "/", with: "-") + ".md"
        panel.message = "Save the retained conversation as Markdown text."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; notice = "Reading retained text…"
        Task { defer { busy = false }; do {
            let bytes = try await collect(first: 1, last: result.total, limit: 64 * 1024 * 1024, failure: "This conversation exceeds 64 MiB. Copy explicit ranges instead. No file was written.")
            try bytes.write(to: url, options: .atomic)
            notice = "Exported \(result.total) messages (\(bytes.count) UTF-8 bytes) to \(url.lastPathComponent)."
        } catch { notice = error.localizedDescription } }
    }
}
