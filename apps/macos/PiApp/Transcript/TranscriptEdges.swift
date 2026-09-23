import SwiftUI
import AppKit

// The edges of the conversation: where the rows the page holds end and the
// rest of the chat begins. The page reads what lies beyond an edge as the
// reader reaches it, so an edge normally shows nothing at all. It speaks up
// only when it has to: a read that is slow shows a small spinner, one that
// failed says so with a way to try again, and rows the page will not read on
// its own (an older window opened on purpose, a short page that has filled
// itself as often as it may) wait behind one quiet control. Everything here
// floats over the conversation: nothing that comes or goes at an edge
// changes the transcript's frame, so no row ever moves for it.

/// What one edge of the conversation shows.
enum TranscriptEdge: Equatable {
    /// Nothing: no rows beyond it, or a read that is not slow yet.
    case quiet
    /// A read that has run longer than `quietLoad`: the small spinner.
    case loading
    /// Rows the page will not read on its own: the reader asks for them.
    case waiting
    /// A read that failed: its error, and Retry.
    case failed(String)
    /// The conversation changed under the page: why, and Reload.
    case changed(String)

    /// How long a read runs before its edge shows the spinner. Most pages
    /// land well inside it, and show nothing at all.
    static let quietLoad = Duration.milliseconds(300)

    static func earlier(_ boundary: ConversationPageBoundary, slow: Bool, waitsForReader: Bool) -> TranscriptEdge {
        if let error = boundary.error { return .failed(error) }
        if boundary.loading { return slow ? .loading : .quiet }
        return boundary.cursor != nil && waitsForReader ? .waiting : .quiet
    }
    static func newer(_ boundary: ConversationPageBoundary, slow: Bool) -> TranscriptEdge {
        // An error with no boundary left to read from is not a read that
        // failed: the page lost its place in the conversation, and only
        // reading it again helps.
        if let error = boundary.error { return boundary.cursor == nil ? .changed(error) : .failed(error) }
        if boundary.loading { return slow ? .loading : .quiet }
        return boundary.cursor != nil ? .waiting : .quiet
    }
    /// A short name for the marker checks read.
    var name: String {
        switch self {
        case .quiet: return "quiet"
        case .loading: return "loading"
        case .waiting: return "waiting"
        case .failed: return "failed"
        case .changed: return "changed"
        }
    }
}

/// What the top edge shows about the rows before the first one the page holds.
struct TranscriptEarlierEdge: View {
    let state: TranscriptEdge
    /// The question the turn at the top of the page began with, when that
    /// turn started before the page does.
    let partialTurnInput: String?
    let load: () -> Void
    let inspect: (String) -> Void
    var body: some View {
        ZStack {
            switch state {
            case .quiet: EmptyView()
            case .loading:
                TranscriptEdgeSpinner(label: "Loading earlier messages")
                    .background(TranscriptEdgeMarker(edge: "earlier", kind: state.name, text: ""))
                    .transition(.opacity)
            case .waiting:
                TranscriptEdgeSurface {
                    HStack(spacing: 2) {
                        Button("Load earlier messages", action: load).buttonStyle(TranscriptEdgeLinkStyle())
                            .accessibilityIdentifier("loadEarlierHistory")
                        if let partialTurnInput {
                            Text("·").foregroundStyle(TranscriptPalette.faint)
                            Button("Earlier work in this turn") { inspect(partialTurnInput) }.buttonStyle(TranscriptEdgeLinkStyle(quiet: true))
                        }
                    }
                }
                .background(TranscriptEdgeMarker(edge: "earlier", kind: state.name, text: "Load earlier messages", action: load))
                .transition(.opacity)
            case .failed(let error), .changed(let error):
                TranscriptEdgeProblem(title: "Couldn’t load earlier messages", detail: error, action: "Retry", perform: load,
                                      partial: partialTurnInput.map { input in { inspect(input) } })
                    .background(TranscriptEdgeMarker(edge: "earlier", kind: state.name, text: error, action: load))
                    .transition(.opacity)
            }
        }
    }
}

/// The way to the question a long turn began with, while the page starts
/// part way through that turn. It stays where it is for as long as that is
/// true, whatever the reader or the page's reads do, so it never flickers.
struct TranscriptPartialTurnChip: View {
    let input: String
    let inspect: (String) -> Void
    var body: some View {
        TranscriptEdgeSurface {
            Button { inspect(input) } label: {
                Label("Earlier work in this turn", systemImage: "arrow.up.to.line").labelStyle(.titleAndIcon)
            }
            .buttonStyle(TranscriptEdgeLinkStyle(quiet: true))
        }
        .background(TranscriptEdgeMarker(edge: "earlier", kind: "partial", text: "Earlier work in this turn", action: { inspect(input) }))
        .help("Show the question this turn began with")
    }
}

/// What the bottom edge shows, beside the way back to the latest message,
/// when the page holds an older window: rows after its last one.
struct TranscriptNewerEdge: View {
    let state: TranscriptEdge
    let load: () -> Void
    let reload: () -> Void
    var body: some View {
        ZStack {
            switch state {
            case .quiet: EmptyView()
            case .loading:
                TranscriptEdgeSpinner(label: "Loading newer messages")
                    .background(TranscriptEdgeMarker(edge: "newer", kind: state.name, text: ""))
                    .transition(.opacity)
            case .waiting:
                TranscriptEdgeSurface {
                    Button("Load newer messages", action: load).buttonStyle(TranscriptEdgeLinkStyle())
                        .accessibilityIdentifier("loadNewerHistory")
                }
                .background(TranscriptEdgeMarker(edge: "newer", kind: state.name, text: "Load newer messages", action: load))
                .transition(.opacity)
            case .failed(let error):
                TranscriptEdgeProblem(title: "Couldn’t load newer messages", detail: error, action: "Retry", perform: load)
                    .background(TranscriptEdgeMarker(edge: "newer", kind: state.name, text: error, action: load))
                    .transition(.opacity)
            case .changed(let message):
                TranscriptEdgeProblem(title: "Changed outside this window", detail: message, action: "Reload", perform: reload, icon: "arrow.triangle.branch")
                    .background(TranscriptEdgeMarker(edge: "newer", kind: state.name, text: message, action: reload))
                    .transition(.opacity)
            }
        }
    }
}

/// The small spinner an edge shows while a slow read is under way.
struct TranscriptEdgeSpinner: View {
    let label: String
    static let diameter: CGFloat = 26
    var body: some View {
        SpinnerView()
            .frame(width: Self.diameter, height: Self.diameter)
            .background(TranscriptPalette.surface, in: Circle())
            .overlay(Circle().stroke(TranscriptPalette.hairStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.14), radius: 8, y: 2)
            .accessibilityElement()
            .accessibilityLabel(label)
    }
}

/// A read that failed, or a page that lost its place: one line saying so
/// with the thing to do about it, and the error under it.
private struct TranscriptEdgeProblem: View {
    let title: String
    let detail: String
    let action: String
    let perform: () -> Void
    var partial: (() -> Void)? = nil
    var icon = "exclamationmark.circle"
    var body: some View {
        TranscriptEdgeSurface(radius: 12) {
            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(TranscriptPalette.warning)
                    Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(TranscriptPalette.text)
                    Button(action, action: perform).buttonStyle(TranscriptEdgeLinkStyle())
                    if let partial {
                        Text("·").foregroundStyle(TranscriptPalette.faint)
                        Button("Earlier work in this turn", action: partial).buttonStyle(TranscriptEdgeLinkStyle(quiet: true))
                    }
                }
                Text(detail).font(.system(size: 10.5)).foregroundStyle(TranscriptPalette.muted)
                    .multilineTextAlignment(.center).lineLimit(3).textSelection(.enabled)
                    .padding(.horizontal, 6).padding(.bottom, 3)
            }
            .padding(.leading, 4)
        }
        .frame(maxWidth: 460)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title + ". " + detail)
    }
}

/// The floating surface every edge control stands on: the transcript's own
/// card colour, a hairline and a soft shadow, like the Back to bottom pill.
private struct TranscriptEdgeSurface<Content: View>: View {
    var radius: CGFloat = 14
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.horizontal, 4).padding(.vertical, 3)
            .background(TranscriptPalette.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(TranscriptPalette.hairStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
    }
}

/// A word to press inside an edge control: accent text that lights up on
/// hover. The quiet form reads as a secondary way somewhere.
private struct TranscriptEdgeLinkStyle: ButtonStyle {
    var quiet = false
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: quiet ? .medium : .semibold))
            .foregroundStyle(quiet && !hovering ? TranscriptPalette.muted : TranscriptPalette.accent)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(hovering ? TranscriptPalette.accentSoft : Color.clear, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .piPointer()
    }
}

/// Marks an edge control in the view tree, so a check can find what the
/// reader would see at an edge and press it. It draws nothing and takes no
/// clicks.
struct TranscriptEdgeMarker: NSViewRepresentable {
    let edge: String
    let kind: String
    let text: String
    var action: (() -> Void)? = nil
    func makeNSView(context: Context) -> TranscriptEdgeMarkerView { TranscriptEdgeMarkerView() }
    func updateNSView(_ view: TranscriptEdgeMarkerView, context: Context) {
        view.mark(edge: edge, kind: kind, text: text, action: action)
    }
}
final class TranscriptEdgeMarkerView: NSView {
    /// Which edge: "earlier" or "newer".
    private(set) var edge = ""
    /// What it shows: a `TranscriptEdge` name, "partial" or "latest".
    private(set) var kind = ""
    /// The words it shows, or the error it reports.
    private(set) var text = ""
    /// What pressing it does.
    private(set) var action: (() -> Void)?
    fileprivate func mark(edge: String, kind: String, text: String, action: (() -> Void)?) {
        self.edge = edge; self.kind = kind; self.text = text; self.action = action
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
