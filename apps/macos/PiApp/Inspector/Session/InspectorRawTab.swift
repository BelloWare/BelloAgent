import SwiftUI
import AppKit

/// The capture as it was: the request and response bodies (formatted JSON,
/// events, UTF-8 or hex), the headers, the metadata record, the message links
/// and the event index. Searchable and copyable; capture settings, exports
/// and redaction in the ⋯ menu.
struct InspectorRawTab: View {
    @ObservedObject var inspector: SessionInspectorModel
    @ObservedObject var request: InspectorRequestModel
    let compact: Bool
    @State private var copySource: CapturedBodyCopySource?
    @State private var notice = ""
    @State private var pageText = ""
    @State private var pageTotal = 0
    @State private var pageOffset = 0
    @State private var pageLoading = false
    @FocusState private var searchFocused: Bool

    private var row: InspectorRequestRow? { request.row }
    private var showsBody: Bool { request.raw == .request || request.raw == .response }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            if let row {
                switch request.raw {
                case .request, .response: bodyView(row)
                case .headers: headers
                case .metadata: text(request.metadataText, empty: request.metadataLoaded ? "No metadata record." : "Reading the metadata record…", label: "Request metadata")
                case .links, .events: paged(row)
                }
            }
            if !notice.isEmpty { PiStatusLine(text: notice, tone: .warning) }
        }
        .padding(.horizontal, compact ? PiSpacing.lg : PiSpacing.xl).padding(.vertical, 12)
        .onChange(of: request.searchFocus) { _, _ in if showsBody { searchFocused = true } else { request.raw = .request; searchFocused = true } }
        .onChange(of: request.raw) { _, _ in copySource = nil; pageOffset = 0 }
        .onChange(of: row?.id) { _, _ in copySource = nil; pageOffset = 0; notice = "" }
        .accessibilityIdentifier("inspector-raw")
    }

    private var toolbar: some View {
        HStack(spacing: PiSpacing.sm) {
            PiTabs(selection: $request.raw, items: [(.request, "Request"), (.response, "Response"), (.headers, "Headers"),
                                                     (.metadata, "Metadata"), (.links, "Links"), (.events, "Events")])
                .accessibilityIdentifier("inspector-raw-parts")
            Spacer(minLength: 4)
            if showsBody { searchField }
            Button { copyView() } label: { Label("Copy", systemImage: "doc.on.doc") }
                .buttonStyle(.piGhost).disabled(showsBody ? copySource == nil : request.metadataText.isEmpty && pageText.isEmpty)
                .accessibilityIdentifier("inspector-raw-copy")
            PiMenuControl(label: "Capture settings and exports", identifier: "inspector-raw-menu", help: "Capture settings and exports") {
                menuEntries()
            } face: { hovering in
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(hovering ? Color.piInk : Color.piInkSecondary)
                    .frame(width: 28, height: 28).background(hovering ? Color.piFillStrong : Color.piFill, in: Circle()).contentShape(Circle())
            }
            .frame(width: 28, height: 28)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.piInkTertiary)
            TextField("Find in body and headers", text: $request.query).textFieldStyle(.plain).font(PiFont.caption)
                .focused($searchFocused).accessibilityIdentifier("inspector-raw-search")
            if !request.query.isEmpty {
                Button { request.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.piInkTertiary) }
                    .buttonStyle(.plain).piPointer().accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(Color.piSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(searchFocused ? Color.piAccent.opacity(0.5) : Color.piHairline, lineWidth: 1))
        .frame(width: compact ? 180 : 250)
    }

    private func bodyView(_ row: InspectorRequestRow) -> some View {
        let kind = request.raw == .request ? "request" : "response"
        return CapturedBodyView(source: source(row, kind: kind), sessionID: inspector.scope.sessionID, attemptID: row.id, kind: kind,
                                retained: row.source != .live, copySource: $copySource,
                                initialFormat: kind == "response" ? .combined : .json, searchQuery: request.query,
                                searchHeaders: request.metadata[kind + "Headers"]?.object ?? [:],
                                growingBytes: kind == "response" ? request.growingBytes : nil)
            .id(row.id + ":" + kind)
    }

    private func source(_ row: InspectorRequestRow, kind: String) -> CapturedBodySource {
        let state = request.metadata[kind]?.object?["state"]?.string ?? ""
        if row.source != .live, MessageBodyReader.canReadRetained(state) || inspector.workspace == nil {
            return .archive(inspector.archive, attemptID: row.id, kind: kind)
        }
        if let workspace = inspector.workspace { return .live(workspace, sessionID: inspector.scope.sessionID, attemptID: row.id, kind: kind) }
        return .archive(inspector.archive, attemptID: row.id, kind: kind)
    }

    private var headers: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                InspectorSectionTitle("Request headers", subtitle: "authentication values are masked")
                CapturedHeadersView(headers: request.metadata["requestHeaders"]?.object ?? [:])
                InspectorSectionTitle("Response headers")
                CapturedHeadersView(headers: request.metadata["responseHeaders"]?.object ?? [:])
            }
        }
        .accessibilityIdentifier("inspector-raw-headers")
    }

    private func text(_ value: String, empty: String, label: String) -> some View {
        ZStack {
            PagedTextView(text: value, accessibilityLabel: label).piInset(sunken: true)
            if value.isEmpty { Text(empty).font(PiFont.caption).foregroundStyle(Color.piInkTertiary) }
        }
    }

    /// Message links and the event index come a page at a time.
    private func paged(_ row: InspectorRequestRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            text(pageText, empty: pageLoading ? "Reading…" : "Nothing recorded.", label: request.raw == .links ? "Message links" : "Event index")
            HStack {
                if pageTotal > 128 {
                    PiPager(previous: { pageOffset = max(0, pageOffset - 128) }, next: { pageOffset += 128 },
                            canPrevious: pageOffset > 0, canNext: pageOffset + 128 < pageTotal) {
                        Text("\(pageOffset + 1)–\(min(pageTotal, pageOffset + 128)) of \(pageTotal)")
                    }
                }
                Spacer()
                Text(request.raw == .links ? "Messages this request used (context) and produced (output)." : "Server-sent event offsets into the retained response.")
                    .font(PiFont.micro).foregroundStyle(Color.piInkTertiary)
            }
        }
        .task(id: PageKey(attempt: row.id, part: request.raw, offset: pageOffset)) { await loadPage(row) }
    }
    private struct PageKey: Equatable { let attempt: String; let part: InspectorRequestModel.RawPart; let offset: Int }

    private func loadPage(_ row: InspectorRequestRow) async {
        pageLoading = true; pageText = ""
        defer { pageLoading = false }
        do {
            let value: [String: WireValue]
            if request.raw == .links {
                value = try await inspector.archive.messageLinks(attemptID: row.id, offset: pageOffset)
            } else if row.source != .live, let retained = try? await inspector.archive.eventIndices(attemptID: row.id, offset: pageOffset) {
                value = retained
            } else if let workspace = inspector.workspace {
                value = try await workspace.debugRequest("debug.raw-events", sessionID: inspector.scope.sessionID, params: ["attemptId": .string(row.id), "offset": .number(Double(pageOffset))])
            } else { throw HostError.failure("No event index was retained for this request.") }
            try Task.checkCancellation()
            let text = await Task.detached(priority: .userInitiated) { () -> String in
                if let links = value["links"]?.array {
                    return links.compactMap(\.object).map { ($0["relationship"]?.string ?? "").padding(toLength: 9, withPad: " ", startingAt: 0) + ($0["messageId"]?.string ?? "") }.joined(separator: "\n")
                }
                return WireValue.object(value).pretty
            }.value
            try Task.checkCancellation()
            pageText = text; pageTotal = Int(value["total"]?.number ?? 0)
        } catch is CancellationError {
        } catch { pageText = ""; notice = error.localizedDescription }
    }

    // MARK: Copy, capture settings and exports

    private func copyView() {
        if showsBody {
            guard let copySource else { return }
            Task {
                do { let text = try await copySource.render(); NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); notice = "" }
                catch { if !(error is CancellationError) { notice = error.localizedDescription } }
            }
        } else {
            let text = request.raw == .metadata ? request.metadataText : pageText
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        }
    }

    /// Built when the menu opens: the capture mode as it is then, and what can be exported.
    private func menuEntries() -> [PiMenuEntry] {
        guard let workspace = inspector.workspace, let row else { return [] }
        let sessionID = inspector.scope.sessionID
        let mode = workspace.displays[sessionID]?.captureMode ?? "persist"
        var modes = [("off", "Off"), ("memory", "Session memory")]
        if !workspace.isEphemeral(sessionID) { modes.append(("persist", "Persist locally")) }
        var entries: [PiMenuEntry] = [.note("Future body capture")]
        for (value, title) in modes {
            entries.append(.button(title, checked: mode == value, identifier: "inspector-capture-" + value) { Task { await setMode(value) } })
        }
        entries.append(.divider)
        entries.append(.button("Export Metadata…", enabled: row.source != .record, identifier: "inspector-export-metadata") { Task { await exportMetadata(row) } })
        entries.append(.button("Export Retained Body Bytes…", enabled: row.source != .record, identifier: "inspector-export-bodies") { Task { await exportBodies(row) } })
        entries.append(.button("Export a Redacted View…", enabled: showsBody && copySource != nil, identifier: "inspector-export-redacted") { Task { await exportRedacted(row) } })
        entries.append(.divider)
        entries.append(.button("Clear This Chat's Captures…", destructive: true, identifier: "inspector-clear-captures") { Task { await clear() } })
        return entries
    }

    private func setMode(_ mode: String) async {
        guard let workspace = inspector.workspace else { return }
        do { try await workspace.setCaptureMode(mode, sessionID: inspector.scope.sessionID); notice = "" } catch { notice = error.localizedDescription }
    }

    private func clear() async {
        guard let workspace = inspector.workspace else { return }
        guard await PiQuestion.shared.confirm("Clear this chat's capture bodies?", "Remove current memory bodies and this chat's retained payload references. Request metrics, message links, conversation history and exported copies stay.", action: "Clear", destructive: true) else { return }
        do { try await workspace.clearCaptures(sessionID: inspector.scope.sessionID); inspector.refresh() } catch { notice = error.localizedDescription }
    }

    private func exportMetadata(_ row: InspectorRequestRow) async {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "BelloAgent-request-metadata.json"
        guard let url = await PiQuestion.shared.save(panel) else { return }
        do { try Data(request.metadataText.utf8).write(to: url, options: .atomic); notice = "" } catch { notice = error.localizedDescription }
    }

    private func exportBodies(_ row: InspectorRequestRow) async {
        guard await PiQuestion.shared.confirm("Export sensitive retained body bytes?", "This exports request.bin, response.bin and a manifest of their completeness and hashes, including every retained byte and any secret in them. Prefixes and expired captures are labeled. Nothing is sent again.") else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.message = "Choose where to put a new trace folder."
        guard let destination = await PiQuestion.shared.open(panel).first else { return }
        do {
            let saved: URL
            if row.source != .live {
                saved = try await inspector.archive.exportRetained(sessionID: inspector.scope.sessionID, attemptID: row.id, destination: destination)
            } else if let workspace = inspector.workspace {
                saved = try await workspace.persistAttempt(sessionID: inspector.scope.sessionID, attemptID: row.id, destination: destination)
            } else { throw HostError.failure("This request's bytes are not available.") }
            notice = "Exported " + saved.path
        } catch { notice = error.localizedDescription }
    }

    /// Replaces a literal the reader names with [REDACTED] in the view on
    /// screen, shows the result, then saves it with a manifest that says so.
    private func exportRedacted(_ row: InspectorRequestRow) async {
        guard let copySource else { return }
        let ask = NSAlert(); ask.messageText = "Which literal should be redacted?"
        ask.informativeText = "Every occurrence is replaced with [REDACTED] in a copy of the view on screen. This is not a secret detector."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24)); ask.accessoryView = field
        ask.addButton(withTitle: "Preview"); ask.addButton(withTitle: "Cancel")
        guard await PiQuestion.shared.ask(ask) == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
        let literal = field.stringValue
        do {
            let text = try await copySource.render()
            let transformed = await Task.detached(priority: .userInitiated) { text.replacingOccurrences(of: literal, with: "[REDACTED]") }.value
            let preview = NSAlert(); preview.messageText = "Redacted view"
            preview.informativeText = "Only the literal you named is replaced. Check the preview before exporting."
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300)); let view = NSTextView(frame: scroll.bounds)
            view.isEditable = false; view.string = String(transformed.prefix(200_000)); scroll.documentView = view; scroll.hasVerticalScroller = true
            preview.accessoryView = scroll
            preview.addButton(withTitle: "Export…"); preview.addButton(withTitle: "Cancel")
            guard await PiQuestion.shared.ask(preview) == .alertFirstButtonReturn else { return }
            let panel = NSSavePanel(); panel.nameFieldStringValue = "BelloAgent-redacted-view.json"
            guard let url = await PiQuestion.shared.save(panel) else { return }
            let manifest: WireValue = .object(["attemptId": .string(row.id), "sourceView": .string(request.raw.rawValue), "byteExact": .bool(false),
                                               "transformations": .array([.string("The displayed view with a reader-named literal replaced by [REDACTED]. Other sensitive data may remain.")]),
                                               "view": .string(transformed)])
            try Data(manifest.pretty.utf8).write(to: url, options: .atomic)
        } catch { if !(error is CancellationError) { notice = error.localizedDescription } }
    }
}
