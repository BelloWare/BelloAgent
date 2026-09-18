import SwiftUI
import AppKit

struct InspectorView: View {
    @ObservedObject var model: WorkspaceModel
    let sessionID: String
    var messageID: String? = nil
    var initialAttemptID: String? = nil
    var initialTab = "overview"
    @State private var attempts: [[String: WireValue]] = []
    @State private var selectedID = ""
    @State private var tab = "overview"
    @State private var mode = "persist"
    @State private var offset = 0
    @State private var total = 0
    @State private var text = ""
    @State private var notice = ""
    @State private var retained = true
    @State private var next: Double?
    @State private var redaction = ""
    @State private var loadRevision = 0
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        PiSheet("Request inspector", subtitle: "Session \(PiFormat.shortID(sessionID)) · app ↔ configured endpoint · upstream gateway traffic unavailable", symbol: "ladybug") {
            VStack(alignment: .leading, spacing: PiSpacing.md) {
                if let messageID { PiNote("Project requests using or producing message \(messageID), including its parent or side origin.") }
                HStack(spacing: PiSpacing.sm) {
                    PiTabs(selection: $retained, items: [(true, "Retained locally"), (false, "Live captures")])
                    Rectangle().fill(Color.piHairlineStrong).frame(width: 1, height: 18)
                    Text("Future body capture").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                    PiDropdown(selection: Binding(get: { mode }, set: { value in changeMode(value) }),
                               items: [("off", "Off"), ("memory", "Session memory")] + (model.isEphemeral(sessionID) ? [] : [("persist", "Persist locally")]), icon: "record.circle", compact: true)
                    Button { clear() } label: { Label("Clear Captures…", systemImage: "trash") }.buttonStyle(.piSecondaryCompact)
                    Spacer()
                }
                HSplitView {
                    VStack(spacing: PiSpacing.sm) {
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(attempts.enumerated()), id: \.offset) { _, attempt in
                                    let id = attempt["attemptId"]?.string ?? ""
                                    PiSelectableRow(selected: selectedID == id, action: { selectedID = id }) {
                                        AttemptRow(attempt: attempt, sessionID: sessionID, showsOwner: messageID != nil)
                                    }
                                }
                            }.padding(PiSpacing.sm)
                        }
                        .overlay { if attempts.isEmpty { Text("No captured attempts").font(PiFont.caption).foregroundStyle(Color.piInkTertiary) } }
                        .piInset()
                        if next != nil { Button { Task { await refresh(older: true) } } label: { Label("Older Attempts", systemImage: "clock.arrow.circlepath") }.buttonStyle(.piSecondaryCompact) }
                    }.frame(minWidth: 240, idealWidth: 280, maxWidth: 340).padding(.trailing, PiSpacing.sm)
                    VStack(alignment: .leading, spacing: PiSpacing.sm) {
                        HStack {
                            PiTabs(selection: $tab, items: [("overview", "Overview"), ("request", "Request"), ("response", "Response"), ("events", "Raw events"), ("pi", "Host events"), ("context", retained ? "Message links" : "Current context")])
                            Spacer()
                        }
                        if tab == "request" || tab == "response" {
                            CapturedHeadersView(headers: selectedHeaders)
                        }
                        if isBody {
                            CapturedBodyView(model: model, sessionID: sessionID, attemptID: selectedID, kind: tab,
                                             retained: retained, revision: loadRevision, displayedText: $text)
                        } else { PagedTextView(text: text).piInset() }
                        HStack(spacing: PiSpacing.sm) {
                            if !isBody {
                                PiPager(previous: { offset = max(0, offset - pageSize); load() }, next: { offset += pageSize; load() }, canPrevious: offset > 0, canNext: offset + pageSize < total, previousLabel: "Previous", nextLabel: "Next") {
                                    HStack(spacing: 6) {
                                        Text("Offset")
                                        PiNumberField(placeholder: "Offset", value: $offset, width: 84, onSubmit: { load() })
                                        Text("of \(total) \(tab == "events" ? "event indices" : retained && tab == "context" ? "message links" : "bytes")")
                                    }
                                }
                            }
                            Spacer()
                            Button { if confirm("Copy this inspector view?", "The clipboard may be read by other applications and clipboard history tools. This copies the displayed derived view, including any sensitive content.") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) } } label: { Label("Copy View…", systemImage: "doc.on.doc") }
                                .buttonStyle(.piSecondaryCompact).disabled(text.isEmpty)
                        }
                    }.frame(minWidth: 540).padding(.leading, PiSpacing.sm)
                }
            }
            .padding(PiSpacing.xl)
        } actions: {
            Button { Task { await refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            Button("Done") { dismiss() }
        } footer: {
            VStack(alignment: .leading, spacing: PiSpacing.sm) {
                PiStatusLine(text: notice)
                HStack(spacing: PiSpacing.sm) {
                    Button { Task { await exportMetadata() } } label: { Label("Export Metadata…", systemImage: "square.and.arrow.up") }.disabled(selectedID.isEmpty)
                    Button { Task { await exportBodies() } } label: { Label("Export Retained Body Bytes…", systemImage: "shippingbox") }.disabled(selectedID.isEmpty)
                    Spacer()
                    PiTextField(placeholder: "Literal to redact from this view", text: $redaction, icon: "eye.slash", secure: true).frame(width: 260)
                    Button("Preview Redacted Export…") { exportRedactedView() }.disabled(text.isEmpty || redaction.isEmpty)
                }
            }
        }
        .frame(minWidth: 1080, idealWidth: 1180, minHeight: 700, idealHeight: 780)
        .task {
            tab = initialTab
            mode = (try? await model.capturePreference(sessionID: sessionID).mode) ?? "persist"
            selectedID = initialAttemptID ?? ""
            await refresh()
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(1)); guard !Task.isCancelled else { return }; await refresh(reloadDetail: false) }
        }
        .onChange(of: retained) { _, _ in selectedID = ""; Task { await refresh() } }
        .onChange(of: selectedID) { _, _ in offset = 0; load() }
        .onChange(of: tab) { _, _ in offset = 0; load() }
        .onDisappear { loadRevision += 1 }
    }
    private var isBody: Bool { ["request", "response"].contains(tab) }
    private var pageSize: Int { tab == "events" || retained && tab == "context" ? 128 : 32_768 }
    private var selectedHeaders: [String: WireValue] {
        attempts.first { $0["attemptId"]?.string == selectedID }?[tab + "Headers"]?.object ?? [:]
    }
    private func refresh(older: Bool = false, reloadDetail: Bool = true) async {
        do {
            if retained {
                let start = older ? Int(next ?? 0) : 0
                let workspaceID = model.record(sessionID)?.workspaceID
                if messageID != nil && workspaceID == nil { throw HostError.failure("The message's project is unavailable. Reopen its chat before looking up related requests.") }
                let page = try await model.traces.list(sessionID: sessionID, messageID: messageID, workspaceID: workspaceID, offset: start)
                attempts = older ? attempts + page : page; next = page.count == 128 ? Double(start + page.count) : nil
                if let initialAttemptID, !attempts.contains(where: { $0["attemptId"]?.string == initialAttemptID }) {
                    let exact = try await model.traces.metadata(attempt: initialAttemptID)
                    guard exact["sessionId"]?.string == sessionID else { throw CaptureFailure.sequence }
                    attempts.insert(exact, at: 0)
                }
                notice = "Durable request metadata · new payloads stored unencrypted · retained storage format and expiry remain inspectable."
            }
            else {
                let value = try await model.debugRequest("debug.list", sessionID: sessionID, params: ["offset": .number(older ? next ?? 0 : 0)])
                let page = value["attempts"]?.array?.compactMap(\.object) ?? []
                attempts = older ? attempts + page : page; next = value["next"]?.number; mode = value["mode"]?.string ?? "memory"
                notice = "\(Int(value["workspaceRetainedBytes"]?.number ?? 0)) body bytes retained in project memory · 128 MiB project / 8 MiB body · \(Int(value["droppedMetadata"]?.number ?? 0)) live metadata records omitted. Durable records are in Retained locally."
            }
            if selectedID.isEmpty { selectedID = attempts.first?["attemptId"]?.string ?? "" }
            if reloadDetail { load() }
        } catch { notice = error.localizedDescription }
    }
    private func load() {
        loadRevision += 1
        let revision = loadRevision
        guard !selectedID.isEmpty else { text = "No captured attempts available."; return }
        // The complete-body view owns cancellable reads and formatted JSON.
        if isBody { text = ""; total = 0; return }
        let id = selectedID, requestedTab = tab, requestedOffset = offset, requestedRetained = retained
        Task { do {
            let value: [String: WireValue]
            if requestedRetained {
                if requestedTab == "events" { value = try await model.traces.eventIndices(attemptID: id, offset: requestedOffset) }
                else if requestedTab == "context" { value = try await model.traces.messageLinks(attemptID: id, offset: requestedOffset) }
                else { value = try await model.traces.metadata(attempt: id) }
                if requestedTab == "pi" {
                    guard revision == loadRevision else { return }
                    text = "Historical normalized host previews are unavailable. Original HTTP body bytes and raw SSE offsets are separate retained records."; return
                }
            } else {
                let method = requestedTab == "events" ? "debug.raw-events" : requestedTab == "pi" ? "session.event-page" : requestedTab == "context" ? "context.info" : "debug.attempt"
                value = try await model.debugRequest(method, sessionID: sessionID, params: ["attemptId": .string(id), "offset": .number(Double(requestedOffset)), "since": .number(0)])
            }
            guard revision == loadRevision, id == selectedID, requestedTab == tab else { return }
            text = WireValue.object(value).pretty; total = requestedTab == "events" || retained && requestedTab == "context" ? Int(value["total"]?.number ?? 0) : 0
            if requestedTab == "pi" { notice = "Normalized host preview journal, bounded to 256 events / 1 MiB; not raw HTTP. A sequence gap requires current snapshot; old normalized previews cannot be recovered." }
        } catch { guard revision == loadRevision else { return }; text = "Unavailable"; notice = error.localizedDescription } }
    }
    private func confirm(_ title: String, _ detail: String) -> Bool { let a = NSAlert(); a.messageText = title; a.informativeText = detail; a.addButton(withTitle: "Continue"); a.addButton(withTitle: "Cancel"); return a.runModal() == .alertFirstButtonReturn }
    private func changeMode(_ value: String) {
        Task { do { try await model.setCaptureMode(value, sessionID: sessionID); mode = value; await refresh() } catch { notice = error.localizedDescription } }
    }
    private func clear() {
        guard confirm("Clear this session's capture bodies?", "Remove current memory bodies and this session's retained payload references. Request metrics, message links, conversation history and already exported copies remain available.") else { return }
        Task { do { try await model.clearCaptures(sessionID: sessionID); await refresh() } catch { notice = error.localizedDescription } }
    }
    private func exportMetadata() async {
        do {
            let metadata = retained ? try await model.traces.metadata(attempt: selectedID) : try await model.debugRequest("debug.attempt", sessionID: sessionID, params: ["attemptId": .string(selectedID)])
            let panel = NSSavePanel(); panel.nameFieldStringValue = "PiTrace-metadata.json"; guard panel.runModal() == .OK, let url = panel.url else { return }
            try Data(WireValue.object(metadata).pretty.utf8).write(to: url, options: .atomic); notice = "Exported metadata only."
        } catch { notice = error.localizedDescription }
    }
    private func exportBodies() async {
        let attemptID = selectedID
        guard confirm("Export sensitive retained body bytes?", "This exports request.bin, response.bin and a completeness/hash manifest. It includes every retained body byte, including any embedded secrets. Prefixes or evicted captures are labeled. No request is replayed.") else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.message = "Choose the destination for a new trace folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let saved: URL
            if retained {
                let record = try await model.traces.metadata(attempt: attemptID)
                guard let owner = record["sessionId"]?.string else { throw CaptureFailure.corrupt }
                saved = try await model.traces.exportRetained(sessionID: owner, attemptID: attemptID, destination: url)
            } else { saved = try await model.persistAttempt(sessionID: sessionID, attemptID: attemptID, destination: url) }
            notice = "Exported \(saved.path)"
        } catch { notice = error.localizedDescription }
    }
    private func exportRedactedView() {
        let transformed = text.replacingOccurrences(of: redaction, with: "[REDACTED]")
        let preview = NSAlert(); preview.messageText = "Redacted derived-view preview"
        preview.informativeText = "Only your literal match is replaced. This is not a complete secret detector or a byte-exact body export. Inspect the preview before exporting."
        let scroll = NSScrollView(frame: NSRect(x: 0,y: 0,width: 600,height: 300)); let view = NSTextView(frame: scroll.bounds); view.isEditable = false; view.string = transformed; scroll.documentView = view; scroll.hasVerticalScroller = true; preview.accessoryView = scroll
        preview.addButton(withTitle: "Export Derived View…"); preview.addButton(withTitle: "Cancel"); guard preview.runModal() == .alertFirstButtonReturn else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "PiTrace-redacted-view.json"; guard panel.runModal() == .OK, let url = panel.url else { return }
        let manifest: WireValue = .object(["attemptId": .string(selectedID), "sourceView": .string(tab), "byteOffset": .number(Double(isBody ? 0 : offset)), "transformations": .array([.string("Decoded displayed view; replaced a user-supplied literal with [REDACTED]. Other sensitive data may remain. Search literal intentionally omitted.")]), "byteExact": .bool(false), "view": .string(transformed)])
        do { try Data(manifest.pretty.utf8).write(to: url, options: .atomic) } catch { notice = error.localizedDescription }
    }
}

private struct AttemptRow: View {
    let attempt: [String: WireValue]
    let sessionID: String
    let showsOwner: Bool
    private var outcome: String { attempt["outcome"]?.string ?? "" }
    private var tone: PiTone { outcome == "completed" ? .success : outcome == "failed" ? .danger : ["running", "streaming"].contains(outcome) ? .warning : .neutral }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(attempt["purpose"]?.string ?? "request").font(PiFont.heading).foregroundStyle(Color.piInk)
                Text("attempt \(Int(attempt["ordinal"]?.number ?? 0))").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                Spacer()
                if !outcome.isEmpty { PiBadge(text: outcome, tone: tone, dot: true) }
            }
            Text(attempt["requestedModel"]?.string ?? "").font(PiFont.caption).foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.middle)
            Text(((attempt["dispatchWallTimestamp"]?.number ?? attempt["wallTimestamp"]?.number).map { Date(timeIntervalSince1970: $0).formatted(.dateTime.hour().minute().second()) + " · " } ?? "") + "Turn \(String((attempt["turnId"]?.string ?? "auxiliary").prefix(18)))")
                .font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
            if showsOwner, let owner = attempt["sessionId"]?.string, owner != sessionID {
                Text("Source session \(owner)").font(PiFont.caption).foregroundStyle(Color.piInkTertiary).lineLimit(1).truncationMode(.middle)
            }
        }
    }
}
