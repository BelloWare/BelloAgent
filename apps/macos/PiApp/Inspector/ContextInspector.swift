import SwiftUI
import AppKit

/// Inspect the helper's authoritative request inputs, not the transcript page.
/// Original transport bytes remain in the separate captured-request inspector.
struct ContextInspector: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var session: SessionDisplay
    @State private var summary: [String: WireValue] = [:]
    @State private var section = "instructions"
    @State private var itemOffset = 0
    @State private var text = ""
    @State private var offset = 0
    @State private var previousOffsets: [Int] = []
    @State private var next: Int?
    @State private var total = 0
    @State private var busy = false
    @State private var notice = ""
    @State private var ticket = 0
    @State private var showCaptured = false
    @Environment(\.dismiss) private var dismiss
    private var revision: String { summary["revision"]?.string ?? "" }
    private var items: [[String: WireValue]] { summary["items"]?.array?.compactMap(\.object) ?? [] }
    private var countedContext: [String: WireValue] { PreparedContextMetrics.context(from: summary) ?? [:] }
    private var meter: ContextMeterPresentation { ContextMeterPresentation(context: countedContext) }

    var body: some View {
        PiSheet("Context", subtitle: "Inspect instructions, tool schemas and every item in the prepared model input.", symbol:"square.stack.3d.up",width:1080,height:750) {
            VStack(alignment:.leading,spacing:PiSpacing.md) {
                HStack(spacing:PiSpacing.lg) {
                    Label(summary["mode"]?.string == "active-context" ? "Current running context" : "Next request preview",systemImage:"doc.text.magnifyingglass").font(PiFont.heading)
                    if let model = summary["model"]?.string { Text(model).font(PiFont.caption).foregroundStyle(Color.piInkSecondary) }
                    Spacer()
                    if meter.fraction != nil {
                        ContextRing(fraction:meter.fraction)
                        Text(meter.fullLabel + " tokens").font(PiFont.caption.monospacedDigit()).help(meter.detailLabel)
                    }
                }
                Text(explanation).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).fixedSize(horizontal:false,vertical:true)
                if meter.fraction != nil { countDetails }
                HSplitView {
                    VStack(spacing:PiSpacing.sm) {
                        ScrollView {
                            LazyVStack(spacing:2) {
                                ForEach(Array(items.enumerated()),id:\.offset) { _, item in
                                    let id = item["id"]?.string ?? ""
                                    PiSelectableRow(selected:section == id,action:{ section = id; offset = 0; previousOffsets = []; loadSection() }) {
                                        Text(item["title"]?.string ?? id).font(PiFont.caption).foregroundStyle(Color.piInk).frame(maxWidth:.infinity,alignment:.leading)
                                    }
                                }
                            }.padding(PiSpacing.sm)
                        }.piInset()
                        PiPager(previous:{ loadItems(max(0,itemOffset - 32)) },next:{ loadItems(Int(summary["next"]?.number ?? 0)) },canPrevious:itemOffset > 0,canNext:summary["next"]?.number != nil) {
                            Text("\(Int(summary["inputItems"]?.number ?? 0)) input items")
                        }
                    }.frame(minWidth:235,idealWidth:260,maxWidth:300).padding(.trailing,PiSpacing.sm)
                    VStack(alignment:.leading,spacing:PiSpacing.sm) {
                        PagedTextView(text:text).piInset()
                        HStack {
                            PiPager(previous:{ offset = previousOffsets.popLast() ?? 0; loadSection() },next:{ previousOffsets.append(offset); offset = next ?? offset; loadSection() },canPrevious:!busy && !previousOffsets.isEmpty,canNext:!busy && next != nil) {
                                Text("Characters \(offset)–\(offset + (text as NSString).length) of \(total)")
                            }
                            Spacer()
                            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType:.string) } label: { Label("Copy Page",systemImage:"doc.on.doc") }.disabled(text.isEmpty || busy)
                        }
                    }.frame(minWidth:580).padding(.leading,PiSpacing.sm)
                }
                PiStatusLine(text:busy ? "Preparing context…" : notice)
            }.padding(PiSpacing.xl)
        } actions: {
            Button { refresh() } label: { Label("Refresh",systemImage:"arrow.clockwise") }.disabled(busy)
            Button("Done") { dismiss() }
        } footer: {
            HStack {
                Text("Request count and provenance match the context ring. Opaque provider state is shown as stored; captured HTTP remains separate.").font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                Spacer()
                Button { showCaptured = true } label: { Label("Actual Captured Requests",systemImage:"arrow.up.doc") }
            }
        }
        .task { refresh() }
        .sheet(isPresented:$showCaptured) { InspectorView(model:model,sessionID:session.id,initialTab:"request") }
        .onDisappear { ticket += 1; let saved = revision; Task { await model.clearPreparedContext(session.id,revision:saved) } }
    }
    private var countDetails: some View {
        VStack(alignment: .leading, spacing: PiSpacing.xs) {
            HStack(spacing: PiSpacing.md) {
                Text(meter.methodLabel + (meter.estimated ? " · estimated" : " · counted"))
                    .font(PiFont.caption.weight(.semibold)).foregroundStyle(Color.piInk)
                if let model = meter.modelLabel { Text(model).font(PiFont.caption).foregroundStyle(Color.piInkSecondary) }
                Spacer(minLength: 0)
            }
            if let source = countedContext["source"]?.string {
                Text(source).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(meter.warnings.enumerated()), id: \.offset) { _, warning in
                Text(warning).font(PiFont.caption).foregroundStyle(Color.piWarning).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("Counting details") {
                VStack(alignment: .leading, spacing: PiSpacing.xs) {
                    if let budget = meter.budgetLabel { Text(budget).font(PiFont.caption).fixedSize(horizontal: false, vertical: true) }
                    if let fingerprint = countedContext["requestFingerprint"]?.string {
                        Text("Request fingerprint: " + fingerprint).font(PiFont.micro.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Gateway-reported response usage is separate from this request count. A routed model may differ from the model used for counting unless the gateway guarantees the route.")
                        .font(PiFont.caption).fixedSize(horizontal: false, vertical: true)
                }.foregroundStyle(Color.piInkSecondary).padding(.top, PiSpacing.xs)
            }.font(PiFont.caption)
        }
    }
    private var explanation: String {
        guard !revision.isEmpty else { return "This view reads the authoritative session context without generating a response or running tools." }
        var value = summary["mode"]?.string == "active-context" ? "Frozen instructions for the running turn and current completed context. Streaming partial output and the unsent draft are excluded." : "The current conversation, refreshed instructions and tool schemas" + (summary["draftIncluded"]?.bool == true ? ", plus your unsent draft and selected skills/images." : ". No draft is included.")
        value += " No generation request is sent by this preview. Automatic compaction, source changes and future tool results can change the eventual request."
        if (summary["queueCount"]?.number ?? 0) > 0 { value += " Pending follow-ups and steering are not included." }
        if summary["credentialsRedacted"]?.bool == true { value += " Fields containing known credentials are fingerprinted." }
        return value
    }
    private func refresh() {
        ticket += 1; let expected = ticket; busy = true; notice = ""; text = ""
        Task { do {
            let result = try await model.preparedContext(session.id)
            guard expected == ticket else { return }
            summary = result; section = "instructions"; itemOffset = 0; offset = 0; previousOffsets = []; busy = false
            loadSection()
        } catch { guard expected == ticket else { return }; busy = false; notice = error.localizedDescription } }
    }
    private func loadSection() {
        guard !revision.isEmpty else { return }
        ticket += 1; let expected = ticket, snapshot = revision, selected = section, requestedOffset = offset
        busy = true; text = ""; notice = ""
        Task { do {
            let page = try await model.readPreparedContext(session.id,revision:snapshot,section:selected,offset:requestedOffset)
            guard expected == ticket, revision == snapshot, section == selected else { return }
            text = page["text"]?.string ?? ""; next = page["next"]?.number.map(Int.init); total = Int(page["total"]?.number ?? 0); busy = false
        } catch { guard expected == ticket else { return }; busy = false; notice = error.localizedDescription } }
    }
    private func loadItems(_ start: Int) {
        guard !revision.isEmpty, !busy else { return }
        ticket += 1; let expected = ticket, snapshot = revision; busy = true
        Task { do {
            let page = try await model.readPreparedContext(session.id,revision:snapshot,itemOffset:start)
            guard expected == ticket, revision == snapshot else { return }
            summary = page; itemOffset = start; busy = false
        } catch { guard expected == ticket else { return }; busy = false; notice = error.localizedDescription } }
    }
}
