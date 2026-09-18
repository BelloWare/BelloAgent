import SwiftUI
import AppKit

struct CapturedBodyMetadata: Equatable, Sendable {
    let body: [String: WireValue]
    let hash: WireValue?

    func count(limit: Int) throws -> Int {
        guard let number = body["retainedBytes"]?.number, number.isFinite,
              number >= 0, number.rounded() == number, number <= Double(limit) else {
            throw HostError.failure("The retained body length is invalid or exceeds the capture limit.")
        }
        return Int(number)
    }
    var summary: String {
        let state = body["state"]?.string ?? "unavailable"
        let retained = body["retainedBytes"]?.number.map { String(format: "%.0f", $0) } ?? "unknown"
        let observed = body["observedBytes"]?.number.map { String(format: "%.0f", $0) } ?? "unknown"
        let reason = body["reason"]?.string ?? ""
        return "\(state) · all \(retained) retained bytes loaded / \(observed) observed" + (reason.isEmpty ? "" : " · \(reason)")
    }
}

/// JSONSerialization containers and captured event frames are immutable. They
/// are parsed off the main actor and only read afterward; the outline's mutable
/// child cache is a separate main-actor object.
struct CapturedJSON: @unchecked Sendable {
    let id = UUID()
    let value: Any
    let formatted: String
    var rootLabel = "$"
}

/// Presentation of retained SSE frames, not a reconstruction of a Responses
/// object. Frame order, non-JSON data, sentinels and unfinished tails survive.
/// The original transport bytes remain on CapturedBodyDocument.
struct CapturedEventFrame: @unchecked Sendable {
    let number: Int
    let fields: [String]
    let data: String?
    let json: Any?
    let formattedData: String?
    let event: String?
    let terminated: Bool

    var name: String {
        if let event, !event.isEmpty { return event }
        if let type = (json as? [String: Any])?["type"] as? String, !type.isEmpty { return type }
        if data == "[DONE]" { return "[DONE]" }
        return data == nil ? "SSE fields" : "message"
    }
    var label: String { "\(number) · \(name)" }
    var summary: String {
        let type = json != nil ? "JSON data" : data == "[DONE]" ? "Stream sentinel" : data == nil ? "No data" : "Non-JSON data"
        return type + (terminated ? "" : " · unfinished frame")
    }
    var count: Int { data == nil ? 2 : 3 }
    func entry(_ index: Int) -> (String, Any) {
        if data != nil, index == 0 { return ("data", json ?? data!) }
        let index = data == nil ? index : index - 1
        return index == 0 ? ("SSE fields", fields) : ("frame", terminated ? "Terminated by an empty line" : "Retained bytes end before the frame terminator")
    }
    var formatted: String {
        var result = "Event \(label) — \(summary)\n"
        result += "SSE fields:\n" + fields.joined(separator: "\n")
        if let formattedData { result += "\n\nFormatted data:\n" + formattedData }
        return result
    }
}

struct CapturedEventStream: Sendable {
    let frames: [CapturedEventFrame]
    let outline: CapturedJSON

    static func parse(_ bytes: Data) throws -> Self? {
        // Do not describe arbitrary binary data as decoded SSE. Partial UTF-8
        // still remains available through the unmodified raw and hex views.
        guard String(data: bytes, encoding: .utf8) != nil else { return nil }
        var frames: [CapturedEventFrame] = []
        var fields: [String] = []
        var hasSSEField = false

        func appendFrame(terminated: Bool) throws {
            guard !fields.isEmpty else { return }
            try Task.checkCancellation()
            var dataLines: [String] = [], event: String?
            for (index, line) in fields.enumerated() {
                if index % 64 == 0 { try Task.checkCancellation() }
                if line.hasPrefix(":") { hasSSEField = true; continue }
                let separator = line.firstIndex(of: ":")
                let name = separator.map { String(line[..<$0]) } ?? line
                var value = separator.map { String(line[line.index(after: $0)...]) } ?? ""
                if value.hasPrefix(" ") { value.removeFirst() }
                switch name {
                case "data": dataLines.append(value); hasSSEField = true
                case "event": event = value; hasSSEField = true
                case "id", "retry": hasSSEField = true
                default: break // Unknown and repeated fields remain visible.
                }
            }
            let data = dataLines.isEmpty ? nil : dataLines.joined(separator: "\n")
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8), options: [.fragmentsAllowed]) }
            let pretty = json.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) }
                .map { String(decoding: $0, as: UTF8.self) }
            frames.append(CapturedEventFrame(number: frames.count + 1, fields: fields, data: data, json: json,
                                             formattedData: pretty, event: event, terminated: terminated))
            fields.removeAll(keepingCapacity: true)
        }

        try bytes.withUnsafeBytes { raw in
            let buffer = raw.bindMemory(to: UInt8.self)
            // SSE permits one leading UTF-8 BOM. It is ignored for framing,
            // while the raw body continues to include it.
            var start = buffer.count >= 3 && buffer[0] == 0xef && buffer[1] == 0xbb && buffer[2] == 0xbf ? 3 : 0
            var cursor = start
            var nextCancellationCheck = cursor
            while cursor < buffer.count {
                if cursor >= nextCancellationCheck { try Task.checkCancellation(); nextCancellationCheck = cursor + 32_768 }
                let byte = buffer[cursor]
                guard byte == 10 || byte == 13 else { cursor += 1; continue }
                if cursor == start { try appendFrame(terminated: true) }
                else { fields.append(String(decoding: UnsafeBufferPointer(rebasing: buffer[start..<cursor]), as: UTF8.self)) }
                if byte == 13, cursor + 1 < buffer.count, buffer[cursor + 1] == 10 { cursor += 1 }
                cursor += 1; start = cursor
            }
            if start < buffer.count { fields.append(String(decoding: UnsafeBufferPointer(rebasing: buffer[start..<buffer.count]), as: UTF8.self)) }
            try appendFrame(terminated: false)
        }
        guard hasSSEField, !frames.isEmpty else { return nil }
        var formatted = "Server-sent events · formatted view of retained frames\n\n"
        for (index, frame) in frames.enumerated() {
            if index % 64 == 0 { try Task.checkCancellation() }
            if index > 0 { formatted += "\n\n" }
            formatted += frame.formatted
        }
        // Erase once: repeatedly casting [CapturedEventFrame] to [Any] from
        // the outline data source would copy the full frame list per row.
        return Self(frames: frames, outline: CapturedJSON(value: frames.map { $0 as Any }, formatted: formatted, rootLabel: "Server-sent events"))
    }
}

struct CapturedBodyDocument: Sendable {
    let id = UUID()
    let bytes: Data
    let metadata: CapturedBodyMetadata
    let json: CapturedJSON?
    let eventStream: CapturedEventStream?
    let combinedResponse: CombinedResponse?
    var structured: CapturedJSON? { json ?? eventStream?.outline }

    func availableFormats(kind: String) -> [(CapturedBodyFormat, String)] {
        var result: [(CapturedBodyFormat, String)] = []
        if kind == "response", combinedResponse != nil { result.append((.combined, "Combined JSON")) }
        result += [(.json, eventStream == nil ? "JSON" : "Events"), (.text, "UTF-8"), (.hex, "Hex")]
        return result
    }

    func resolvedFormat(_ requested: CapturedBodyFormat, kind: String) -> CapturedBodyFormat {
        availableFormats(kind: kind).contains { $0.0 == requested } ? requested : .json
    }

    func structured(format: CapturedBodyFormat) -> CapturedJSON? {
        format == .combined ? combinedResponse?.json : format == .json ? structured : nil
    }

    func displayedText(format: CapturedBodyFormat, hex: String = "") -> String {
        if format == .hex { return hex }
        return structured(format: format)?.formatted ?? String(decoding: bytes, as: UTF8.self)
    }

    static func parse(bytes: Data, metadata: CapturedBodyMetadata) throws -> Self {
        try Task.checkCancellation()
        var json: CapturedJSON?
        if let value = try? JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed]),
           let printed = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            json = CapturedJSON(value: value, formatted: String(decoding: printed, as: UTF8.self))
        }
        let eventStream = json == nil ? try CapturedEventStream.parse(bytes) : nil
        let combinedResponse = try eventStream.flatMap { try CombinedResponse.parse($0) }
        try Task.checkCancellation()
        return Self(bytes: bytes, metadata: metadata, json: json, eventStream: eventStream, combinedResponse: combinedResponse)
    }
}

@MainActor struct CapturedBodySource {
    let metadata: () async throws -> CapturedBodyMetadata
    let page: (Int) async throws -> (Data, Int)
    var whole: ((@escaping @MainActor @Sendable (Int, Int) -> Void) async throws -> Data)? = nil

    static func archive(_ archive: PayloadArchive, attemptID: String, kind: String) -> Self {
        Self(metadata: {
            let value = try await archive.metadata(attempt: attemptID)
            return CapturedBodyMetadata(body: value[kind]?.object ?? [:], hash: value[kind + "Hash"])
        }, page: { offset in
            let value = try await archive.metadata(attempt: attemptID)
            let metadata = CapturedBodyMetadata(body: value[kind]?.object ?? [:], hash: value[kind + "Hash"])
            return (try await archive.body(attemptID: attemptID, body: kind, offset: offset), try metadata.count(limit: CapturedBodyReader.limit(kind)))
        }, whole: { progress in
            try await archive.completeBody(attemptID: attemptID, body: kind) { loaded, total in
                await progress(loaded, total)
            }
        })
    }

    static func live(_ model: WorkspaceModel, sessionID: String, attemptID: String, kind: String) -> Self {
        Self(metadata: {
            let value = try await model.debugRequest("debug.attempt", sessionID: sessionID, params: ["attemptId": .string(attemptID)])
            return CapturedBodyMetadata(body: value[kind]?.object ?? [:], hash: value[kind + "Hash"])
        }, page: { offset in
            let value = try await model.debugRequest("debug.body", sessionID: sessionID, params: ["attemptId": .string(attemptID), "body": .string(kind), "offset": .number(Double(offset))])
            guard MessageBodyReader.canReadRetained(value["state"]?.string ?? ""),
                  let encoded = value["bytes"]?.string, let bytes = Data(base64Encoded: encoded) else {
                throw HostError.failure("This body was not captured or is no longer available.")
            }
            return (bytes, try CapturedBodyMetadata(body: value, hash: nil).count(limit: CapturedBodyReader.limit(kind)))
        })
    }
}

enum CapturedBodyReader {
    static func limit(_ kind: String) -> Int { kind == "request" ? 33_554_432 : 67_108_864 }

    @MainActor static func read(kind: String, source: CapturedBodySource, progress: @escaping @MainActor @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> CapturedBodyDocument {
        try Task.checkCancellation()
        let before = try await source.metadata()
        guard MessageBodyReader.canReadRetained(before.body["state"]?.string ?? "") else {
            throw HostError.failure("Body unavailable: \(before.body["state"]?.string ?? "not captured"). \(before.body["reason"]?.string ?? "")")
        }
        let count = try before.count(limit: limit(kind))
        let bytes: Data
        if let whole = source.whole { bytes = try await whole(progress) }
        else {
            guard let assembled = try await MessageBodyReader.assemble(limit: limit(kind), progress: progress, page: source.page) else {
                throw HostError.failure("The capture changed while reading. Refresh and try again.")
            }
            bytes = assembled
        }
        guard bytes.count == count else {
            throw HostError.failure("The capture changed while reading. Refresh and try again.")
        }
        try Task.checkCancellation()
        guard before == (try await source.metadata()) else {
            throw HostError.failure("The capture changed while reading. Refresh and try again.")
        }
        let parsing = Task.detached(priority: .userInitiated) { try CapturedBodyDocument.parse(bytes: bytes, metadata: before) }
        return try await withTaskCancellationHandler(operation: { try await parsing.value }, onCancel: { parsing.cancel() })
    }
}

@MainActor final class CapturedBodyController: ObservableObject {
    @Published private(set) var document: CapturedBodyDocument?
    @Published private(set) var loading = false
    @Published private(set) var loaded = 0
    @Published private(set) var total = 0
    @Published private(set) var notice = ""
    private var generation = 0

    func load(kind: String, source: CapturedBodySource) async {
        generation += 1
        let revision = generation
        document = nil; loaded = 0; total = 0; notice = ""; loading = true
        do {
            let result = try await CapturedBodyReader.read(kind: kind, source: source) { [weak self] loaded, total in
                guard let self, self.generation == revision else { return }
                // Coalesce UI progress without changing the archive's 32 KiB reads.
                if loaded == total || loaded - self.loaded >= 131_072 || self.total == 0 {
                    self.loaded = loaded; self.total = total
                }
            }
            try Task.checkCancellation()
            guard generation == revision else { return }
            document = result; loading = false
        } catch {
            guard generation == revision else { return }
            loading = false
            if !(error is CancellationError) { notice = error.localizedDescription }
        }
    }
    func cancel() { generation += 1; loading = false }
}

enum CapturedBodyFormat: String, CaseIterable { case json, combined, text, hex }

/// No body pagination: both native entry points share this complete retained
/// body presentation. Expiry and prefix states remain visible above the bytes.
struct CapturedBodyView: View {
    @ObservedObject var model: WorkspaceModel
    let sessionID: String
    let attemptID: String
    let kind: String
    let retained: Bool
    var revision = 0
    @Binding var displayedText: String
    @StateObject private var controller = CapturedBodyController()
    @State private var format = CapturedBodyFormat.combined
    @State private var selection = ""
    @State private var expandRevision = 0
    @State private var expandAll = false
    @State private var hex = ""
    private struct Selection: Equatable {
        let session: String, attempt: String, kind: String
        let retained: Bool
        let revision: Int
    }
    private struct FormatSelection: Equatable {
        let format: CapturedBodyFormat
        let document: UUID?
    }
    private var identity: Selection { Selection(session: sessionID, attempt: attemptID, kind: kind, retained: retained, revision: revision) }
    private var activeFormat: CapturedBodyFormat { controller.document?.resolvedFormat(format, kind: kind) ?? .json }
    private var selectedFormat: Binding<CapturedBodyFormat> {
        Binding(get: { activeFormat }, set: { format = $0 })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: PiSpacing.sm) {
            HStack(spacing: PiSpacing.sm) {
                PiTabs(selection: selectedFormat, items: controller.document?.availableFormats(kind: kind) ?? [(.json, "JSON"), (.text, "UTF-8"), (.hex, "Hex")])
                Spacer()
                if controller.document?.structured(format: activeFormat) != nil {
                    Button("Expand all") { expandAll = true; expandRevision += 1 }.buttonStyle(.piGhost)
                    Button("Collapse all") { expandAll = false; expandRevision += 1 }.buttonStyle(.piGhost)
                }
            }
            if let document = controller.document {
                if let json = document.structured(format: activeFormat) {
                    JSONOutlineView(json: json, selection: $selection, expandRevision: expandRevision, expandAll: expandAll)
                        .piInset(sunken: true)
                    if !selection.isEmpty {
                        PagedTextView(text: selection, accessibilityLabel: "Selected JSON value")
                            .frame(height: 100).piInset(sunken: true)
                    }
                    Text(activeFormat == .combined ? document.combinedResponse?.notice ?? ""
                         : document.eventStream == nil
                         ? "Select a value to see its full contents. Formatting is a derived view; retained bytes are unchanged."
                         : "Events appear in captured order. Expand a frame and its data to inspect JSON. This is a formatted view; UTF-8, Hex and exports preserve the retained bytes.")
                        .font(PiFont.micro).foregroundStyle(Color.piInkTertiary)
                } else {
                    PagedTextView(text: activeFormat == .hex ? hex : String(decoding: document.bytes, as: UTF8.self), accessibilityLabel: "Complete retained HTTP body")
                        .piInset(sunken: true)
                    if activeFormat == .json { Text("Not a JSON document or UTF-8 event stream · showing retained UTF-8.").font(PiFont.micro).foregroundStyle(Color.piInkTertiary) }
                }
                Text(document.metadata.summary).font(PiFont.micro).foregroundStyle(Color.piInkSecondary).textSelection(.enabled)
            } else if controller.loading {
                VStack(spacing: PiSpacing.sm) {
                    ProgressView(value: Double(controller.loaded), total: Double(max(1, controller.total))).frame(maxWidth: 300)
                    Text("Loading all retained bytes · \(controller.loaded.formatted()) / \(controller.total.formatted())")
                        .font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(controller.notice.isEmpty ? "No retained body" : controller.notice)
                    .font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .task(id: identity) {
            displayedText = ""; selection = ""; hex = ""; expandAll = false; expandRevision = 0
            let source = retained ? CapturedBodySource.archive(model.traces, attemptID: attemptID, kind: kind) : CapturedBodySource.live(model, sessionID: sessionID, attemptID: attemptID, kind: kind)
            await controller.load(kind: kind, source: source)
            guard !Task.isCancelled else { return }
            updateDisplayedText()
        }
        .task(id: FormatSelection(format: activeFormat, document: controller.document?.id)) {
            selection = ""; expandAll = false; expandRevision = 0
            await updateHexIfNeeded()
            updateDisplayedText()
        }
        .onChange(of: controller.loading) { _, loading in
            if !loading { updateDisplayedText() }
        }
        .onDisappear { controller.cancel() }
        .accessibilityIdentifier("captured-body-view")
    }
    private func updateDisplayedText() {
        guard let document = controller.document else { displayedText = ""; return }
        displayedText = document.displayedText(format: activeFormat, hex: hex)
    }
    private func updateHexIfNeeded() async {
        guard activeFormat == .hex, hex.isEmpty, let bytes = controller.document?.bytes else { return }
        let identity = identity
        let rendering = Task.detached(priority: .userInitiated) { try CapturedBodyHex.render(bytes) }
        do {
            let value = try await withTaskCancellationHandler(operation: { try await rendering.value }, onCancel: { rendering.cancel() })
            guard !Task.isCancelled, identity == self.identity, format == .hex else { return }
            hex = value
        } catch { /* Leaving the view or format cancels expensive rendering. */ }
    }
}

enum CapturedBodyHex {
    static func render(_ bytes: Data) throws -> String {
        var result = ""
        result.reserveCapacity(bytes.count * 4)
        let digits = Array("0123456789abcdef".utf8)
        for start in stride(from: 0, to: bytes.count, by: 16) {
            if start % 32_768 == 0 { try Task.checkCancellation() }
            result += String(format: "%08x  ", start)
            var line = [UInt8]()
            for byte in bytes[start..<min(start + 16, bytes.count)] { line += [digits[Int(byte >> 4)], digits[Int(byte & 15)], 32] }
            result += String(decoding: line, as: UTF8.self) + "\n"
        }
        return result
    }
}

@MainActor final class JSONOutlineNode {
    let key: String
    let value: Any
    private let formattedDetail: String?
    private var children: [Int: JSONOutlineNode] = [:]
    private lazy var keys = (value as? [String: Any])?.keys.sorted() ?? []
    init(key: String, value: Any, formattedDetail: String? = nil) {
        self.key = key; self.value = value; self.formattedDetail = formattedDetail
    }
    var count: Int { (value as? CapturedEventFrame)?.count ?? (value as? [String: Any])?.count ?? (value as? [Any])?.count ?? 0 }
    var cachedChildren: Int { children.count }
    func child(_ index: Int) -> JSONOutlineNode {
        if let result = children[index] { return result }
        let result: JSONOutlineNode
        if let frame = value as? CapturedEventFrame {
            let (key, value) = frame.entry(index)
            result = JSONOutlineNode(key: key, value: value)
        } else if let values = value as? [String: Any] { result = JSONOutlineNode(key: keys[index], value: values[keys[index]]!) }
        else {
            let value = (value as! [Any])[index]
            result = JSONOutlineNode(key: (value as? CapturedEventFrame)?.label ?? "[\(index)]", value: value)
        }
        children[index] = result
        return result
    }
    var summary: String {
        if let frame = value as? CapturedEventFrame { return frame.summary }
        if value is [String: Any] { return "{ \(count) \(count == 1 ? "key" : "keys") }" }
        if value is [Any] { return "[ \(count) \(count == 1 ? "item" : "items") ]" }
        if let string = value as? String {
            let preview = String(string.prefix(251))
            return "\"" + String(preview.prefix(250)).replacingOccurrences(of: "\n", with: "\\n") + (preview.count > 250 ? "…" : "") + "\""
        }
        return detail
    }
    var detail: String {
        if let formattedDetail { return formattedDetail }
        if let frame = value as? CapturedEventFrame { return frame.formatted }
        // Custom event values are not Foundation JSON containers. This
        // fallback also protects roots constructed outside the live viewer;
        // the viewer supplies its already formatted root to avoid this work.
        if let frames = value as? [CapturedEventFrame], !frames.isEmpty {
            return "Server-sent events · formatted view of retained frames\n\n" + frames.map(\.formatted).joined(separator: "\n\n")
        }
        if let string = value as? String { return string }
        guard let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: bytes, as: UTF8.self)
    }
}

struct JSONOutlineView: NSViewRepresentable {
    let json: CapturedJSON
    @Binding var selection: String
    let expandRevision: Int
    let expandAll: Bool
    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let outline = NSOutlineView(); outline.headerView = nil; outline.backgroundColor = .clear
        outline.rowHeight = 24; outline.intercellSpacing = NSSize(width: 10, height: 2); outline.indentationPerLevel = 14
        let key = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("key")); key.width = 240; key.minWidth = 100
        let value = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value")); value.width = 420; value.minWidth = 120
        outline.addTableColumn(key); outline.addTableColumn(value); outline.outlineTableColumn = key
        outline.dataSource = context.coordinator; outline.delegate = context.coordinator
        outline.setAccessibilityLabel("Expandable captured JSON")
        scroll.documentView = outline
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let outline = scroll.documentView as? NSOutlineView else { return }
        let coordinator = context.coordinator
        coordinator.selection = $selection
        // One controller document is immutable. Rebuild only after a new body,
        // not after selecting a row or changing the expanded state.
        if coordinator.documentID != json.id {
            coordinator.documentID = json.id
            coordinator.root = JSONOutlineNode(key: json.rootLabel, value: json.value, formattedDetail: json.formatted)
            coordinator.revision = expandRevision
            outline.reloadData(); outline.expandItem(coordinator.root)
        }
        if coordinator.revision != expandRevision {
            coordinator.revision = expandRevision
            if expandAll { outline.expandItem(nil, expandChildren: true) }
            else { outline.collapseItem(nil, collapseChildren: true); outline.expandItem(coordinator.root) }
        }
    }
    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var root: JSONOutlineNode?
        var documentID: UUID?
        var revision = 0
        var selection: Binding<String>
        init(selection: Binding<String>) { self.selection = selection }
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? JSONOutlineNode)?.count ?? (root == nil ? 0 : 1) }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? JSONOutlineNode)?.child(index) ?? root! }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { ((item as? JSONOutlineNode)?.count ?? 0) > 0 }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? JSONOutlineNode else { return nil }
            let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("value")
            let field = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTextField ?? NSTextField(labelWithString: "")
            field.identifier = identifier; field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.lineBreakMode = .byTruncatingTail; field.maximumNumberOfLines = 1
            field.stringValue = identifier.rawValue == "key" ? node.key : node.summary
            field.textColor = identifier.rawValue == "key" ? .labelColor : .secondaryLabelColor
            return field
        }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard let outline = notification.object as? NSOutlineView else { return }
            guard let node = outline.item(atRow: outline.selectedRow) as? JSONOutlineNode,
                  node.count == 0 || node === root || node.value is CapturedEventFrame else {
                selection.wrappedValue = ""; return
            }
            selection.wrappedValue = node.detail
        }
    }
}
