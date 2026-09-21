import SwiftUI

struct TimelinePartRow: View {
    let part: ResponseTimeline.Segment
    let message: TranscriptMessage
    let actions: TranscriptActions
    let open: Bool
    let toggle: () -> Void
    var source: TranscriptMessage {
        var value = message
        value.kind = nil; value.role = "assistant"; value.text = part.text
        value.thinking = nil; value.tools = nil; value.responseTimeline = nil
        value.accounting = nil; value.truncated = part.truncated
        value.state = message.isStreaming && part.state == "streaming" ? "streaming" : "complete"
        return value
    }
    var title: String {
        switch part.part.kind {
        case "reasoningSummary": return "Returned reasoning summary"
        case "reasoningText": return "Returned reasoning"
        case "toolArguments": return "Preparing \(part.part.name ?? "tool")"
        case "opaque": return "Opaque provider item"
        case "correction": return "Corrected response content"
        case "status": return part.text
        default: return "Response part"
        }
    }
    var body: some View {
        if ["text","refusal"].contains(part.part.kind) {
            MessageRowView(message:source,actions:actions,inlineAccounting:false).equatable().padding(.bottom,10)
        } else {
            VStack(alignment:.leading,spacing:6) {
                Button(action:toggle) {
                    HStack(spacing:6) {
                        Image(systemName:open ? "chevron.down":"chevron.right").font(.system(size:10))
                        Text(title).font(.system(size:12.5,weight:.medium))
                        if part.state == "interrupted" { Text("Interrupted").foregroundStyle(TranscriptPalette.warning) }
                    }.foregroundStyle(TranscriptPalette.muted)
                }.buttonStyle(.plain)
                if open {
                    if part.part.kind == "toolArguments" {
                        CodeBlockView(language:"json",code:part.text,streaming:source.isStreaming)
                    } else if part.part.kind != "status" { MarkdownBodyView(source:part.text,streaming:source.isStreaming).equatable() }
                    Text(part.part.evidence == "observed" ? "Observed delivery order" : "\(part.part.evidence) · arrival timing unavailable").font(.system(size:10.5)).foregroundStyle(TranscriptPalette.faint)
                    if part.truncated { Text("Partial preview · inspect retained request details when available").font(.system(size:11)).foregroundStyle(TranscriptPalette.warning) }
                    Button("Request details") { actions.inspect(message.id) }.buttonStyle(.plain).font(.system(size:11))
                }
            }.padding(.vertical,5)
        }
    }
}
struct RequestTimelineInfo: View {
    let message: TranscriptMessage
    let actions: TranscriptActions
    var body: some View {
        VStack(alignment:.leading,spacing:4) {
            if let accounting = message.accounting { MessageAccountingView(accounting:accounting,onInspect:{ actions.inspect(message.id) }) }
            if let detail = message.detail { Text(detail).font(.system(size:11)).foregroundStyle(TranscriptPalette.faint) }
            if let reason = message.stopReason, ["interrupted", "length"].contains(reason) { Text(reason == "interrupted" ? "Request interrupted · partial output retained" : "Output limit reached").font(.system(size:12)).foregroundStyle(TranscriptPalette.warning) }
        }.padding(.bottom,6)
    }
}
struct ToolResultTimelineRow: View {
    let message: TranscriptMessage
    let open: Bool
    let toggle: () -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            Button(action:toggle) { Label(message.detail ?? "Tool result recorded",systemImage:open ? "chevron.down":"chevron.right").font(.system(size:12.5)) }.buttonStyle(.plain).foregroundStyle(TranscriptPalette.muted)
            if open { MarkdownBodyView(source:message.text).equatable() }
        }.padding(.vertical,6)
    }
}
struct ExecutionTimelineRow: View {
    let message: TranscriptMessage
    let actions: TranscriptActions
    let open: Bool
    let toggle: () -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            Button(action:toggle) {
                Label(message.detail ?? message.text,systemImage:open ? "chevron.down":"chevron.right").font(.system(size:12.5,weight:.medium))
            }.buttonStyle(.plain).foregroundStyle(TranscriptPalette.muted)
            if open, let timeline = message.responseTimeline, timeline.supported {
                ForEach(timeline.segments) { part in
                    TimelinePartRow(part:part,message:message,actions:actions,open:true,toggle:{})
                }
                if timeline.terminal == nil { Text("No terminal receipt yet").font(.system(size:11)).foregroundStyle(TranscriptPalette.warning) }
            }
        }.padding(.vertical,8)
    }
}
