import SwiftUI
import AppKit

/// Per-message sheet: the message text, then one card per linked HTTP attempt
/// with routing identity, gateway cost/cache, timings and the request/response
/// bodies. Available retained bodies and masked headers display directly.
struct MessageDetailView: View {
    @ObservedObject var model: WorkspaceModel
    let sessionID: String
    let messageID: String
    @State private var attempts: [[String: WireValue]] = []
    @State private var liveOnly: Set<String> = []
    @State private var notice = ""
    @State private var loading = true
    @State private var nextOffset: Int?
    @Environment(\.dismiss) private var dismiss
    private var message: TranscriptMessage? { model.displays[sessionID]?.messages.first { $0.id == messageID } }
    private var editable: Bool { message?.role == "user" && message?.kind == nil && message?.isStreaming != true && model.record(sessionID)?.imported != true }
    private var editBlocker: String? { model.displays[sessionID].flatMap(model.editEntryBlocker) }
    var body: some View {
        PiSheet("Message details", subtitle: "Message \(PiFormat.shortID(messageID)) · session \(PiFormat.shortID(sessionID)) · app ↔ configured endpoint", symbol: "text.magnifyingglass", width: 960, height: 740) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: PiSpacing.md) {
                    if let message { MessageCard(message: message) } else { MissingMessageCard(model: model, sessionID: sessionID, messageID: messageID) }
                    PiSectionHeader("Linked requests", subtitle: loading ? "Looking up retained and live attempts…" : attempts.isEmpty ? "No attempt is linked to this message" : "\(attempts.count) attempt\(attempts.count == 1 ? "" : "s") using or producing this message")
                    if !loading && attempts.isEmpty { PiNote("Imported and unloaded history has no retroactive HTTP trace. Requests made while capture is off keep metadata only.") }
                    ForEach(attempts, id: \.attemptKey) { attempt in
                        AttemptCard(model: model, sessionID: sessionID, attempt: attempt, liveOnly: liveOnly.contains(attempt["attemptId"]?.string ?? ""))
                            .transition(AnyTransition.move(edge: .bottom).combined(with: .opacity))
                    }
                    if nextOffset != nil { Button("Load older linked requests") { Task { await load(older: true) } }.buttonStyle(.piSecondaryCompact).disabled(loading) }
                    PiStatusLine(text: notice, tone: .warning)
                }
                .padding(PiSpacing.xl)
                .animation(.easeOut(duration: 0.22), value: attempts.count)
            }
        } actions: {
            Button("Refresh") { Task { await load() } }.disabled(loading)
            if editable { Button { model.editMessage(messageID, sessionID: sessionID); dismiss() } label: { Label("Modify request…", systemImage: "pencil.line") }.disabled(editBlocker != nil).help(editBlocker ?? "Modify the complete original input") }
            Button { openInspector() } label: { Label("Open request inspector", systemImage: "ladybug") }
            Button("Done") { dismiss() }
        }
        .task { await load() }
    }
    private func openInspector() {
        dismiss()
        // Uncancelled on purpose: this sheet is already going away, and the
        // wait is for its dismissal to finish before the next one opens over
        // the same window. The model it wakes outlives every sheet.
        Task { try? await Task.sleep(for: .milliseconds(350)); model.inspect(sessionID, messageID: messageID) }
    }
    private func load(older: Bool = false) async {
        loading = true
        defer { loading = false }
        var durable: [[String: WireValue]] = []
        let offset = older ? nextOffset ?? 0 : 0
        do {
            durable = try await model.traces.list(sessionID: sessionID, messageID: messageID, workspaceID: model.record(sessionID)?.workspaceID, offset: offset)
            nextOffset = durable.count == 128 ? offset + durable.count : nil
            notice = ""
        }
        catch { notice = "Retained request metadata unavailable: \(error.localizedDescription)" }
        let previous = older ? attempts : []
        let refreshedIDs = Set(durable.compactMap { $0["attemptId"]?.string })
        var combined = previous.filter { !refreshedIDs.contains($0["attemptId"]?.string ?? "") } + durable
        if !older { liveOnly = [] }; liveOnly.subtract(refreshedIDs)
        var ids = Set(combined.compactMap { $0["attemptId"]?.string })
        // Live captures cover attempts not yet finalized in the archive.
        if let value = try? await model.debugRequest("debug.list", sessionID: sessionID, params: ["offset": .number(0)]) {
            for attempt in value["attempts"]?.array?.compactMap(\.object) ?? [] {
                guard let id = attempt["attemptId"]?.string, !ids.contains(id) else { continue }
                let linked = (attempt["messageIds"]?.array ?? []) + (attempt["outputMessageIds"]?.array ?? [])
                guard linked.contains(.string(messageID)) else { continue }
                ids.insert(id); combined.append(attempt); liveOnly.insert(id)
            }
        }
        attempts = combined
    }
}

private extension Dictionary where Key == String, Value == WireValue {
    var attemptKey: String { self["attemptId"]?.string ?? "" }
}

private struct MessageCard: View {
    let message: TranscriptMessage
    @State private var copied = false
    private var who: String? { message.kind == "compaction" ? "Compaction summary" : message.kind == "branch" ? "Edit marker" : message.role == "tool" ? "Tool result" : message.role == "system" ? "Status" : nil }
    private var tone: PiTone { message.role == "user" ? .success : message.role == "assistant" ? .accent : .neutral }
    var body: some View {
        PiCard(padding: PiSpacing.md) {
            VStack(alignment: .leading, spacing: PiSpacing.sm) {
                HStack(spacing: PiSpacing.sm) {
                    if let who { PiBadge(text: who, tone: tone, dot: true) }
                    if let kind = message.kind { PiBadge(text: kind, tone: .info, icon: kind == "compaction" ? "arrow.down.right.and.arrow.up.left" : "arrow.triangle.branch") }
                    if let state = message.state, ["error", "aborted"].contains(state) { PiBadge(text: state, tone: .danger) }
                    if let tools = message.tools, !tools.isEmpty { PiBadge(text: "\(tools.count) tool call\(tools.count == 1 ? "" : "s")", icon: "wrench") }
                    if message.truncated == true { PiBadge(text: "preview truncated", tone: .warning) }
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string)
                        withAnimation(.easeOut(duration: 0.15)) { copied = true }
                        // Uncancelled on purpose: a second and a bit of "Copied",
                        // then back. It only writes this view's own @State, which
                        // is harmless once the view is gone.
                        Task { try? await Task.sleep(for: .seconds(1.2)); withAnimation { copied = false } }
                    } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                        .buttonStyle(.piSecondaryCompact).disabled(message.text.isEmpty)
                }
                if let detail = message.detail, !detail.isEmpty { Text(detail).font(PiFont.caption).foregroundStyle(Color.piInkSecondary) }
                ScrollView {
                    Text(message.text.isEmpty ? "No text content" : message.text).font(message.role == "tool" ? PiFont.mono : PiFont.body)
                        .foregroundStyle(message.text.isEmpty ? Color.piInkTertiary : Color.piInk).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(PiSpacing.md)
                }
                .frame(minHeight: 60, maxHeight: 220).piInset(sunken: true)
                if let thinking = message.thinking, !thinking.isEmpty {
                    DisclosureGroup { Text(thinking).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).textSelection(.enabled).padding(.top, 4) }
                        label: { Text("Exposed reasoning").font(PiFont.caption).foregroundStyle(Color.piInkSecondary) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(message.role) message")
    }
}

/// One linked HTTP attempt: routing, gateway metrics, timings and complete
/// retained bodies, with an expandable JSON presentation when applicable.
private struct AttemptCard: View {
    @ObservedObject var model: WorkspaceModel
    let sessionID: String
    let attempt: [String: WireValue]
    let liveOnly: Bool
    @State private var tab = "request"
    @State private var notice = ""
    @State private var loadRevision = 0
    private var attemptID: String { attempt["attemptId"]?.string ?? "" }
    private var ownerSession: String { attempt["sessionId"]?.string ?? sessionID }
    private var outcome: String { attempt["outcome"]?.string ?? "" }
    private var outcomeTone: PiTone { outcome == "completed" ? .success : ["failed", "interrupted"].contains(outcome) ? .danger : ["running", "streaming"].contains(outcome) ? .warning : .neutral }
    private var gateway: GatewayObservation { GatewayObservation(metadata: attempt) }
    private var metrics: [String: WireValue] { attempt["metrics"]?.object ?? [:] }
    private var bodyDescriptor: [String: WireValue] { attempt[tab]?.object ?? [:] }
    private var durableReadable: Bool { !liveOnly && MessageBodyReader.canReadRetained(bodyDescriptor["state"]?.string ?? "") }
    var body: some View {
        PiCard(padding: PiSpacing.md) {
            VStack(alignment: .leading, spacing: PiSpacing.sm) {
                HStack(spacing: PiSpacing.sm) {
                    Text(attempt["purpose"]?.string ?? "request").font(PiFont.heading).foregroundStyle(Color.piInk)
                    Text(InspectorAttemptLabel.ordinal(attempt["ordinal"]?.number) + " · " + (attempt["api"]?.string ?? "")).font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                    if liveOnly { PiBadge(text: "live capture", tone: .info, icon: "record.circle") }
                    if ownerSession != sessionID { Text("from \(ownerSession)").font(PiFont.caption).foregroundStyle(Color.piInkTertiary).lineLimit(1).truncationMode(.middle) }
                    Spacer()
                    if let status = attempt["status"]?.number { PiBadge(text: "HTTP \(Int(status))", tone: status >= 400 ? .danger : .neutral) }
                    if !outcome.isEmpty { PiBadge(text: outcome, tone: outcomeTone, dot: true) }
                }
                MessageModelReports(attempt: attempt)
                PiFlow(spacing: 6, rowSpacing: 6) {
                    MetricPill(symbol: "dollarsign.circle", label: "Cost", value: costLabel, tone: gateway.costStatus == "reported" ? .accent : gateway.costStatus == "unreported" ? .neutral : .danger)
                    MetricPill(symbol: "brain", label: "Reasoning cost · included", value: gateway.reasoningCostStatus == "reported" ? gatewayUSD(gateway.reasoningCostUSD) : gateway.reasoningCostStatus, tone: gateway.reasoningCostStatus == "reported" ? .accent : gateway.reasoningCostStatus == "unreported" ? .neutral : .danger)
                        .help("The reported reasoning portion is already included in the total cost; it is never added again.")
                    MetricPill(symbol: "memorychip", label: "Cache", value: gateway.cacheStatus, tone: gateway.cacheStatus == "hit" ? .success : gateway.cacheStatus == "miss" ? .warning : gateway.cacheStatus == "unreported" ? .neutral : .danger)
                    MetricPill(symbol: "arrow.down.to.line", label: "Input cached", value: tokens(gateway.cacheReadTokens))
                    MetricPill(symbol: "arrow.down", label: "Input not cached", value: tokens(gateway.uncachedInputTokens))
                    MetricPill(symbol: "arrow.up", label: "Output", value: tokens(gateway.outputTokens))
                    MetricPill(symbol: "brain", label: "Reasoning · in output", value: tokens(gateway.reasoningTokens))
                        .help("Reasoning tokens are a subset of output tokens, never an additional token charge.")
                    MetricPill(symbol: "arrow.up.doc", label: "Prompt-cache write", value: tokens(gateway.cacheWriteTokens))
                    MetricPill(symbol: "timer", label: "TTFT", value: milliseconds(metrics["observedTTFTms"]))
                    MetricPill(symbol: "waveform.path", label: "Stream", value: milliseconds(metrics["streamDurationMs"]))
                        .help("First output token to the last (hidden reasoning included): the span the output rate divides by. The wait for the terminal event is not in it.")
                    MetricPill(symbol: "network", label: "HTTP", value: milliseconds(metrics["httpDurationMs"]))
                }
                Rectangle().fill(Color.piHairline).frame(height: 1)
                HStack(spacing: PiSpacing.sm) {
                    PiTabs(selection: $tab, items: [("request", "Request"), ("response", "Response")])
                    Text(bodyState).font(PiFont.caption).foregroundStyle(Color.piInkTertiary).lineLimit(1)
                    Spacer()
                    Button { copyBody("request") } label: { Label("Copy raw request", systemImage: "doc.on.doc") }.buttonStyle(.piSecondaryCompact)
                    Button { copyBody("response") } label: { Label("Copy raw response", systemImage: "doc.on.doc") }.buttonStyle(.piSecondaryCompact)
                }
                CapturedHeadersView(headers: attempt[tab + "Headers"]?.object ?? [:])
                CapturedBodyView(model: model, sessionID: ownerSession, attemptID: attemptID, kind: tab,
                                 retained: !liveOnly && durableReadable, revision: loadRevision)
                    .frame(height: 340)
                PiStatusLine(text: notice, tone: .warning)
            }
        }
        .onChange(of: attempt) { _, _ in loadRevision += 1 }
    }
    private var costLabel: String {
        guard gateway.costStatus == "reported", let value = gateway.costUSD else { return gateway.costStatus }
        return gatewayUSD(value)
    }
    private var bodyState: String {
        let state = bodyDescriptor["state"]?.string ?? (liveOnly ? "live" : "unknown")
        let retained = bodyDescriptor["retainedBytes"]?.nonnegativeInteger.map(String.init) ?? "unavailable"
        return "\(state) · \(retained) bytes retained" + (liveOnly || durableReadable ? "" : " · reading live capture")
    }
    private func tokens(_ value: Double?) -> String {
        guard let value, let tokens = Int(exactly: value), tokens >= 0 else { return "n/a" }
        return tokens.formatted(.number.grouping(.automatic))
    }
    private func milliseconds(_ value: WireValue?) -> String { value?.number.map { String(format: "%.0f ms", $0) } ?? "n/a" }
    /// Asked on a sheet, so nothing else in the app stops while it is up.
    private func confirm(_ title: String, _ detail: String) async -> Bool { await PiQuestion.shared.confirm(title, detail) }
    /// Read retained prefixes as well as complete bodies. Their descriptor
    /// still identifies partial/truncated/interrupted captures after restart.
    private func page(_ kind: String, at offset: Int) async throws -> (Data, Int) {
        let descriptor = attempt[kind]?.object ?? [:]
        if !liveOnly, MessageBodyReader.canReadRetained(descriptor["state"]?.string ?? "") {
            let data = try await model.traces.body(attemptID: attemptID, body: kind, offset: offset)
            guard let length = descriptor["retainedBytes"]?.nonnegativeInteger else { throw TraceError.invalid }
            return (data, length)
        }
        let value = try await model.debugRequest("debug.body", sessionID: ownerSession, params: ["attemptId": .string(attemptID), "body": .string(kind), "offset": .number(Double(offset))])
        guard MessageBodyReader.canReadRetained(value["state"]?.string ?? ""), let bytes = value["bytes"]?.string.flatMap({ Data(base64Encoded: $0) }) else { throw HostError.failure("This body was not captured or is no longer available.") }
        guard let length = value["retainedBytes"]?.nonnegativeInteger else { throw TraceError.invalid }
        return (bytes, length)
    }
    private func assemble(_ kind: String, limit: Int) async throws -> Data? {
        let descriptor = attempt[kind]?.object ?? [:]
        // Whole-body reads walk the ordered manifest once. The paged
        // compatibility API re-read this attempt's metadata blob and rescanned
        // all of its chunk references for every 32 KiB page.
        if !liveOnly, MessageBodyReader.canReadRetained(descriptor["state"]?.string ?? "") {
            guard let length = descriptor["retainedBytes"]?.nonnegativeInteger, length <= limit else { return nil }
            return try await model.traces.completeBody(attemptID: attemptID, body: kind) { _, _ in }
        }
        return try await MessageBodyReader.assemble(limit: limit) { try await page(kind, at: $0) }
    }
    private func copyBody(_ kind: String) {
        Task {
            guard await confirm("Copy retained body text?", "The clipboard may be read by other applications and clipboard history tools. This copies the retained body as UTF-8 text, including sensitive content. Partial or truncated captures contain only the retained prefix.") else { return }
            do {
            guard let bytes = try await assemble(kind, limit: 8 * 1024 * 1024) else { notice = "The \(kind) body exceeds the 8 MiB copy limit. Export it from the request inspector instead."; return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(String(decoding: bytes, as: UTF8.self), forType: .string)
            notice = "Copied \(bytes.count) retained \(kind) bytes as UTF-8 text."
        } catch { notice = error.localizedDescription } }
    }
}

/// Clicking the inline model opens this sourced comparison. Header/body names
/// remain literal, including provider prefixes and date suffixes.
struct MessageModelReports: View {
    let attempt: [String: WireValue]
    private var modelIdentity: GatewayModelIdentity { GatewayModelIdentity(metadata: attempt) }
    var body: some View {
        let reports = modelIdentity
        VStack(alignment: .leading, spacing: 5) {
            if let response = reports.response {
                report("Response body", response)
            } else if let legacy = reports.legacyModel {
                PiKeyValue(key: "Gateway model", value: legacy, mono: true)
                Text("No sourced response-body model was recorded.").font(PiFont.micro).foregroundStyle(Color.piInkTertiary)
            } else {
                PiKeyValue(key: "Response body", value: "Model not reported", mono: true)
            }
            ForEach(Array(reports.headerReports.enumerated()), id: \.offset) { _, value in
                report("Response header", value)
            }
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 5) {
                    PiKeyValue(key: "Requested model", value: attempt["requestedModel"]?.string ?? "Not recorded", mono: true)
                    PiKeyValue(key: "Identity status", value: attempt["identity"]?.object?["status"]?.string ?? (reports.legacyModel == nil ? "unreported" : "reported"), mono: true)
                    ForEach(Array(reports.bodyReports.filter { $0 != reports.response }.enumerated()), id: \.offset) { _, value in
                        report("Other body report", value)
                    }
                    if reports.bodyReports.isEmpty && reports.headerReports.isEmpty {
                        let oldNames = PayloadArchive.reportedModels(attempt)
                        if !oldNames.isEmpty { PiKeyValue(key: "Legacy reports", value: oldNames.joined(separator: ", "), mono: true) }
                    }
                    Text("The displayed body name does not change routing verification or replay policy.")
                        .font(PiFont.micro).foregroundStyle(Color.piInkTertiary)
                }.padding(.top, 4)
            } label: { Text("Routing details").font(PiFont.caption).foregroundStyle(Color.piInkSecondary) }
        }
        .textSelection(.enabled)
        .accessibilityIdentifier("messageModelReports")
    }

    private func report(_ title: String, _ value: GatewayModelIdentity.Report) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            PiKeyValue(key: title, value: value.name, mono: true)
            Text(value.source).font(PiFont.micro).foregroundStyle(Color.piInkTertiary)
        }
    }
}

enum MessageBodyReader {
    static func canReadRetained(_ state: String) -> Bool { ["complete", "credential-hashed", "credential-masked", "partial", "truncated", "interrupted", "recording"].contains(state) }

    /// A stable retained prefix must be copied completely or fail explicitly;
    /// an evicted/short page is never presented as a successful whole-body copy.
    /// `length` reads a body that is still being written up to the length it
    /// had when the read began: its bytes are only ever appended, so the pages
    /// may report a longer body, never a shorter one.
    @MainActor static func assemble(limit: Int, length target: Int? = nil, progress: (Int, Int) -> Void = { _, _ in }, page: (Int) async throws -> (Data, Int)) async throws -> Data? {
        var bytes = Data(), expected: Int?
        if let target {
            guard target >= 0 else { throw HostError.failure("The capture changed while reading. Refresh and try again.") }
            guard target <= limit else { return nil }
            while bytes.count < target {
                try Task.checkCancellation()
                let (chunk, count) = try await page(bytes.count)
                try Task.checkCancellation()
                guard count >= target, expected.map({ count >= $0 }) ?? true else { throw HostError.failure("The capture changed while reading. Refresh and try again.") }
                expected = count
                let wanted = min(chunk.count, target - bytes.count)
                guard wanted > 0 else { throw HostError.failure("The retained body is incomplete or changed while reading.") }
                bytes.append(chunk.prefix(wanted))
                progress(bytes.count, target)
            }
            return bytes
        }
        repeat {
            try Task.checkCancellation()
            let (chunk, count) = try await page(bytes.count)
            try Task.checkCancellation()
            guard count >= 0, expected == nil || expected == count else { throw HostError.failure("The capture changed while reading. Refresh and try again.") }
            guard count <= limit else { return nil }
            expected = count
            guard chunk.count <= count - bytes.count, !chunk.isEmpty || bytes.count == count else { throw HostError.failure("The retained body is incomplete or changed while reading.") }
            bytes.append(chunk)
            progress(bytes.count, count)
            if bytes.count == count { return bytes }
        } while true
    }
}

/// Header values have already been sanitized before helper IPC and persistence.
/// Keep their presentation separate from the byte-exact body paging controls.
struct CapturedHeadersView: View {
    let headers: [String: WireValue]
    private var text: String {
        headers.keys.sorted().map { "\($0): \(headers[$0]?.string ?? headers[$0]?.pretty ?? "")" }.joined(separator: "\n")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Headers").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                } label: { Label("Copy headers", systemImage: "doc.on.doc") }.buttonStyle(.piGhost).disabled(headers.isEmpty)
            }
            ScrollView {
                Text(text.isEmpty ? "No headers recorded" : text).font(PiFont.mono).foregroundStyle(Color.piInkSecondary)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: min(120, CGFloat(max(1, headers.count)) * 17 + 4))
            .padding(PiSpacing.sm).piInset(sunken: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Captured HTTP headers")
    }
}

private struct MetricPill: View {
    let symbol: String
    let label: String
    let value: String
    var tone: PiTone = .neutral
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(tone == .neutral ? Color.piInkTertiary : tone.color)
            Text(label).font(PiFont.micro).foregroundStyle(Color.piInkSecondary)
            Text(value).font(PiFont.micro).foregroundStyle(Color.piInk).monospacedDigit().lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.piFill, in: Capsule())
        .help("\(label): \(value)")
    }
}


/// Shown when the message is not on the visible transcript page: it may have
/// been replaced by an edit (its replies stay in the journal) or it lies on a
/// page that is not loaded. The retained text is read directly when possible.
private struct MissingMessageCard: View {
    @ObservedObject var model: WorkspaceModel
    let sessionID: String
    let messageID: String
    @State private var text = ""
    @State private var loaded = false
    @State private var failure = ""
    var body: some View {
        PiCard(padding: PiSpacing.md) {
            VStack(alignment: .leading, spacing: PiSpacing.sm) {
                PiNote("This message is not in the current conversation view. It was either replaced by an edit, so its replies were kept in the journal but left the active context, or it is outside the loaded transcript page. Its retained requests are still listed below.", tone: .warning)
                if !text.isEmpty {
                    ScrollView { Text(text).font(PiFont.body).foregroundStyle(Color.piInk).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 220).padding(PiSpacing.sm).piInset(sunken: true)
                } else if loaded {
                    Text(failure.isEmpty ? "No retained text for this message." : failure).font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                } else { ProgressView().controlSize(.small) }
            }
        }
        .task {
            do { text = try await model.messagePage(id: messageID, field: "text", offset: 0, sessionID: sessionID).0 }
            catch { failure = error.localizedDescription }
            loaded = true
        }
    }
}
