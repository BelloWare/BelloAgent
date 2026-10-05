// Frozen from 59ef8e0d for AppKit visual comparison only.
import AppKit
import SwiftUI
import UniformTypeIdentifiers
@testable import PiApp

/// No body pagination: both native entry points share this complete retained
/// body presentation. Expiry and prefix states remain visible above the bytes.
struct CapturedBodyViewReference: View {
    let source: CapturedBodySource
    let sessionID: String
    let attemptID: String
    let kind: String
    let retained: Bool
    var revision = 0
    /// Only the request inspector consumes this (Copy View and redaction).
    /// A card that ignores it must not be handed a second full copy of the body.
    var displayedText: Binding<String>? = nil
    var copySource: Binding<CapturedBodyCopySource?>? = nil
    var searchQuery = ""
    var searchHeaders: [String: WireValue] = [:]
    /// Retained bytes the owner's latest poll reported for a body that is
    /// still being written. Newer bytes are offered, never read on each poll.
    var growingBytes: Int? = nil
    /// Test-only readiness observation; leaves the frozen load/search flow intact.
    var onControllers: ((CapturedBodyController, PayloadSearchController) -> Void)? = nil
    @StateObject private var controller = CapturedBodyController()
    @StateObject private var search = PayloadSearchController()
    @State private var previousSelection: Selection?
    @State private var format = CapturedBodyFormat.json
    @State private var selection = ""
    @State private var expandRevision = 0
    @State private var expandAll = false
    @State private var outlineCommand: JSONOutlineCommand?
    @State private var hex = ""
    @State private var hexDocument: UUID?
    /// The retained bytes decoded as UTF-8, once per document.
    @State private var utf8 = ""
    @State private var utf8Document: UUID?
    /// The document and format the selection and disclosure state belong to.
    @State private var shown: FormatSelection?
    /// "Load latest" presses; each reads the growing body once more.
    @State private var latestRequests = 0
    private struct Selection: Equatable {
        let session: String, attempt: String, kind: String
        let retained: Bool
        let revision: Int
        let latest: Int
    }
    private struct FormatSelection: Equatable {
        let format: CapturedBodyFormat
        let document: UUID?
    }
    private struct SearchSelection: Equatable {
        let query: String
        let document: UUID?
        let format: CapturedBodyFormat
        let combined: Bool
        let headers: [String: WireValue]
    }
    init(model: WorkspaceModel, sessionID: String, attemptID: String, kind: String, retained: Bool,
         revision: Int = 0, displayedText: Binding<String>? = nil, copySource: Binding<CapturedBodyCopySource?>? = nil,
         initialFormat: CapturedBodyFormat = .json) {
        self.source = retained ? .archive(model.traces, attemptID: attemptID, kind: kind) : .live(model, sessionID: sessionID, attemptID: attemptID, kind: kind)
        self.sessionID = sessionID; self.attemptID = attemptID; self.kind = kind; self.retained = retained
        self.revision = revision; self.displayedText = displayedText; self.copySource = copySource
        _format = State(initialValue: initialFormat)
    }
    init(source: CapturedBodySource, sessionID: String, attemptID: String, kind: String, retained: Bool,
         revision: Int = 0, copySource: Binding<CapturedBodyCopySource?>? = nil,
         initialFormat: CapturedBodyFormat = .json, searchQuery: String = "", searchHeaders: [String: WireValue] = [:], growingBytes: Int? = nil) {
        self.source = source; self.sessionID = sessionID; self.attemptID = attemptID; self.kind = kind; self.retained = retained
        self.revision = revision; self.copySource = copySource; self.searchQuery = searchQuery; self.searchHeaders = searchHeaders
        self.growingBytes = growingBytes
        _format = State(initialValue: initialFormat)
    }
    private var identity: Selection { Selection(session: sessionID, attempt: attemptID, kind: kind, retained: retained, revision: revision, latest: latestRequests) }
    private var activeFormat: CapturedBodyFormat { controller.document?.resolvedFormat(format, kind: kind) ?? .json }
    private var selectedFormat: Binding<CapturedBodyFormat> {
        Binding(get: { activeFormat }, set: { format = $0 })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: PiSpacing.sm) {
            HStack(spacing: PiSpacing.sm) {
                PiTabs(selection: selectedFormat, items: controller.document?.availableFormats(kind: kind) ?? [(.json, "JSON"), (.text, "UTF-8"), (.hex, "Hex")])
                Spacer()
            }
            if !searchQuery.isEmpty {
                searchResults
            } else if let document = controller.document {
                if let json = document.structured(format: activeFormat) {
                    JSONOutlineReference(json: json, selection: $selection, expandRevision: expandRevision, expandAll: expandAll,
                                    command: outlineCommand, stateKey: "\(sessionID):\(attemptID):\(kind):\(activeFormat.rawValue)")
                        .piInset(sunken: true)
                    // Outside the scroll view: these controls remain reachable
                    // even at the end of a very large expanded request.
                    HStack(spacing: PiSpacing.sm) {
                        Button("Expand all") { expandAll = true; expandRevision += 1 }
                            .accessibilityIdentifier("payload-expand-all")
                        Button("Collapse section") { outlineCommand = JSONOutlineCommand(action: .collapseSection) }
                            .help("Collapse the selected section, or the section at your current scroll position")
                            .accessibilityIdentifier("payload-collapse-section")
                        Button("Collapse all") { selection = ""; expandAll = false; expandRevision += 1 }
                            .accessibilityIdentifier("payload-collapse-all")
                        Spacer(minLength: 0)
                        Button { outlineCommand = JSONOutlineCommand(action: .top) } label: { Label("Top", systemImage: "arrow.up.to.line") }
                            .help("Back to the start of this request or response")
                            .accessibilityIdentifier("payload-scroll-top")
                    }.buttonStyle(.piGhost).accessibilityIdentifier("payload-outline-controls")
                    if !selection.isEmpty {
                        PagedTextReference(text: selection, accessibilityLabel: "Selected JSON value")
                            .frame(height: 100).piInset(sunken: true)
                    }
                    Text(activeFormat == .combined ? document.combinedResponse?.notice ?? ""
                         : document.eventStream == nil
                         ? "Select a value to see its full contents. Formatting is a derived view; retained bytes are unchanged."
                         : "Events appear in captured order. Expand a frame and its data to inspect JSON. This is a formatted view; UTF-8, Hex and exports preserve the retained bytes.")
                        .font(PiFont.micro).foregroundStyle(Color.piInkTertiary)
                } else if activeFormat == .combined {
                    VStack { PiSpinner(controlSize: .regular); Text("Combining captured response events…").font(PiFont.caption) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    PagedTextReference(text: activeFormat == .hex ? hex : utf8, accessibilityLabel: "Complete retained HTTP body")
                        .piInset(sunken: true)
                    if activeFormat == .json { Text("Not a JSON document or UTF-8 event stream · showing retained UTF-8.").font(PiFont.micro).foregroundStyle(Color.piInkTertiary) }
                }
                Text(document.metadata.summary).font(PiFont.micro).foregroundStyle(Color.piInkSecondary).textSelection(.enabled)
                if let growingBytes, growingBytes > document.bytes.count {
                    HStack(spacing: PiSpacing.sm) {
                        Text("\(growingBytes.formatted()) bytes so far · showing the first \(document.bytes.count.formatted())")
                            .font(PiFont.micro).foregroundStyle(Color.piInkSecondary).monospacedDigit()
                        if controller.loading { Text("Loading…").font(PiFont.micro).foregroundStyle(Color.piInkTertiary) }
                        else { Button("Load latest") { latestRequests += 1 }.buttonStyle(.piGhost).font(PiFont.micro).accessibilityIdentifier("payload-load-latest") }
                    }
                }
            } else if controller.loading {
                VStack(spacing: PiSpacing.sm) {
                    PiProgressBar(value: Double(controller.loaded), total: Double(max(1, controller.total))).frame(maxWidth: 300)
                    Text("Loading all retained bytes · \(controller.loaded.formatted()) / \(controller.total.formatted())")
                        .font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(controller.notice.isEmpty ? "No retained body" : controller.notice)
                    .font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if !searchQuery.isEmpty, let document = controller.document {
                Text(document.metadata.summary).font(PiFont.micro).foregroundStyle(Color.piInkSecondary)
            }
            if controller.document != nil, !controller.notice.isEmpty {
                Text(controller.notice).font(PiFont.micro).foregroundStyle(Color.piWarning)
            }
        }
        .onAppear { onControllers?(controller, search) }
        .task(id: identity) {
            let preserve = previousSelection.map { $0.session == identity.session && $0.attempt == identity.attempt && $0.kind == identity.kind } ?? false
            previousSelection = identity
            // A newer read of the body on screen keeps what the reader is
            // looking at, and what Copy would copy, until its replacement lands.
            if !preserve {
                displayedText?.wrappedValue = ""; copySource?.wrappedValue = nil; selection = ""; hex = ""; utf8 = ""
                hexDocument = nil; utf8Document = nil
                expandAll = false; expandRevision = 0; outlineCommand = nil
            }
            await controller.load(kind: kind, source: source, preservingDocument: preserve, combine: preserve && activeFormat == .combined)
            guard !Task.isCancelled else { return }
            await updateDisplayedText()
        }
        .task(id: FormatSelection(format: activeFormat, document: controller.document?.id)) {
            let current = FormatSelection(format: activeFormat, document: controller.document?.id)
            // The same body, re-read, keeps its selection and open sections; the
            // outline carries them onto the new document. A new body or another
            // format starts fresh.
            let inPlace = controller.document?.replaces != nil && shown == FormatSelection(format: activeFormat, document: controller.document?.replaces)
            shown = current
            if !inPlace { selection = ""; expandAll = false; expandRevision = 0; outlineCommand = nil }
            if activeFormat == .combined { await controller.prepareCombined() }
            guard !Task.isCancelled else { return }
            await updateHexIfNeeded()
            await updateUTF8IfNeeded()
            await updateDisplayedText()
        }
        .task(id: SearchSelection(query: searchQuery, document: controller.document?.id, format: activeFormat,
                                  combined: controller.document?.combinationFinished ?? false, headers: searchHeaders)) {
            guard !searchQuery.isEmpty else { search.cancel(); return }
            if activeFormat == .combined, controller.document?.combinationFinished == false { return }
            await search.search(document: controller.document, format: activeFormat, headers: searchHeaders, kind: kind, query: searchQuery)
        }
        .onDisappear { controller.cancel(); search.cancel(); copySource?.wrappedValue = nil }
        .accessibilityIdentifier("captured-body-view")
    }
    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if let result = search.result {
                    Text(result.matches.isEmpty ? "No matches in body or headers" : "\(search.selected + 1) of \(result.matches.count)\(result.limited ? "+" : "") matches")
                        .font(PiFont.caption).monospacedDigit().accessibilityIdentifier("payload-search-count")
                    Spacer()
                    if search.loading { Text("Updating…").font(PiFont.micro).foregroundStyle(Color.piInkTertiary) }
                    Button { search.move(-1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.piGhost).disabled(result.matches.isEmpty).help("Previous match").accessibilityLabel("Previous match")
                    Button { search.move(1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.piGhost).disabled(result.matches.isEmpty).help("Next match").accessibilityLabel("Next match")
                } else if search.loading { PiShimmerText(text: "Searching body and headers…", size: 11) }
            }
            if let result = search.result {
                PayloadSearchTextReference(result: result, selected: search.selected).piInset(sunken: true)
            } else {
                Text(search.notice).font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    private func updateDisplayedText() async {
        guard let document = controller.document else { displayedText?.wrappedValue = ""; copySource?.wrappedValue = nil; return }
        let id = identity, requested = activeFormat
        let source = CapturedBodyCopySource(id: document.id, document: document, format: requested, hex: hex, plain: utf8)
        copySource?.wrappedValue = source
        // Legacy binding is used by native fixtures. The production inspector
        // requests full derived text only when Copy/Redacted Export is invoked.
        if let displayedText, let text = try? await source.render(), !Task.isCancelled,
           id == identity, controller.document?.id == document.id, requested == activeFormat { displayedText.wrappedValue = text }
    }
    /// The retained bytes as UTF-8, decoded once per document on a detached
    /// task. This used to run inside `body`, so every progress tick, poll,
    /// hover or resize re-decoded the whole payload on the main thread.
    private func updateUTF8IfNeeded() async {
        guard activeFormat != .hex, let document = controller.document, utf8Document != document.id,
              document.structured(format: activeFormat) == nil, !document.bytes.isEmpty else { return }
        let identity = identity, bytes = document.bytes, requested = activeFormat
        let decoding = Task.detached(priority: .userInitiated) { String(decoding: bytes, as: UTF8.self) }
        let value = await withTaskCancellationHandler(operation: { await decoding.value }, onCancel: { decoding.cancel() })
        guard !Task.isCancelled, identity == self.identity, activeFormat == requested, controller.document?.id == document.id else { return }
        utf8 = value; utf8Document = document.id
    }
    private func updateHexIfNeeded() async {
        guard activeFormat == .hex, let document = controller.document, hexDocument != document.id else { return }
        let identity = identity, bytes = document.bytes
        let rendering = Task.detached(priority: .userInitiated) { try CapturedBodyHex.render(bytes) }
        do {
            let value = try await withTaskCancellationHandler(operation: { try await rendering.value }, onCancel: { rendering.cancel() })
            guard !Task.isCancelled, identity == self.identity, format == .hex, controller.document?.id == document.id else { return }
            hex = value; hexDocument = document.id
        } catch { /* Leaving the view or format cancels expensive rendering. */ }
    }
}
