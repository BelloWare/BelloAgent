import AppKit
import SwiftUI
@testable import PiApp
@testable import GitView

// Minimum-width probe for the real released RightPane topology. Its hidden
// side remains in the original ZStack. The two minimum-bearing pieces below
// are the original kept-side header and idle composer controls. Flexible
// transcript/editor space is clear because this probe only measures their
// surrounding controls' minimum; it does not claim pixel parity for a side.
@MainActor struct RightPaneMinimumV119Reference: View {
    let tab: ChangesTabNarrowV119Reference?
    let side: KeptSideMinimumV119Reference
    var body: some View {
        VStack(spacing: 0) {
            // The released horizontal TabStrip scroll view had no horizontal
            // content minimum; its fixed height is the original 36pt.
            if tab != nil {
                ScrollView(.horizontal, showsIndicators: false) { Color.clear.frame(width: 1, height: 36) }.frame(height: 36)
            }
            ZStack {
                side.opacity(tab == nil ? 1 : 0).allowsHitTesting(tab == nil).accessibilityHidden(tab != nil)
                if let tab {
                    KeptTabContentHostV119Reference(root: AnyView(tab.buttonStyle(.piSecondary).toggleStyle(.piSwitch).background(Color.piContent)))
                }
            }
        }.background(Color.piContent)
    }
}

@MainActor struct KeptSideMinimumV119Reference: View {
    let title: String
    let reading: ModelSwitchPills.Reading
    let paneWidth: CGFloat
    var kept = true
    var transcriptProbe: ((TranscriptNativeScrollView) -> Void)?
    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.piHairline).frame(height: 1)
            if let transcriptProbe { SideTranscriptSurfaceV119Reference(onMake: transcriptProbe) }
            else { Color.clear }
            composer
            Color.clear.frame(height: 30)
        }
    }
    private var header: some View {
        HStack(alignment: .center, spacing: PiSpacing.sm) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if kept {
                        Button {} label: { Text(title).foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.tail) }
                            .buttonStyle(.plain).font(PiFont.title(15))
                    } else {
                        Text("Side conversation").font(PiFont.title(15)).foregroundStyle(Color.piInk).fixedSize()
                    }
                    PiBadge(text: kept ? "Saved · Read-only" : "In memory", tone: kept ? .success : .warning, icon: "arrow.triangle.branch").fixedSize()
                }
                Text("Shares the parent's context as of when it opened")
                    .font(PiFont.caption).foregroundStyle(Color.piInkTertiary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: PiSpacing.sm)
            PiIconButton(symbol: "arrow.uturn.backward", label: "Bring Back to Parent Draft…") {}
            if !kept {
                Button {} label: { Label("Keep", systemImage: "pin") }.buttonStyle(.piSecondaryCompact)
            }
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).frame(width: 28, height: 28)
            PiIconButton(symbol: "xmark", label: "Close side", size: 26) {}
        }
        .padding(.horizontal, PiSpacing.lg).padding(.top, 10).padding(.bottom, 8)
        .background(Color.piContent)
    }
    private var form: ComposerBarForm {
        ComposerBarMetrics(showsConnectionPill: reading.contents.showsConnection, connection: reading.contents.connection,
                           model: reading.contents.model, effort: reading.contents.effort, modelLoading: reading.contents.loading)
            .form(fitting: ComposerBarMetrics.available(paneWidth: paneWidth))
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: PiSpacing.sm) {
            VStack(spacing: 0) {
                Color.clear.frame(height: 36)
                HStack(spacing: ComposerBarMetrics.spacing) {
                    PiIconButton(symbol: "photo.badge.plus", label: "Attach Image…", size: 28, filled: true) {}
                    PiIconButton(symbol: "command", label: "Skills…", size: 28, filled: true) {}
                    Spacer()
                    // The original runControlRow remained an empty HStack
                    // in an idle side; do not replace its spacing with a pad.
                    HStack(spacing: ComposerBarMetrics.spacing) { }
                    Image(systemName: "chart.pie").font(.system(size: 28 * 0.46, weight: .medium)).frame(width: 28, height: 28)
                    HStack(spacing: ComposerBarMetrics.spacing) {
                        if reading.contents.showsConnection {
                            RefPillLabel(icon: "antenna.radiowaves.left.and.right", text: reading.contents.connection,
                                         active: reading.connectionActive, loading: false, maxWidth: 150, compact: form.pills.connectionIsCompact).fixedSize()
                        }
                        Button {} label: {
                            RefPillLabel(icon: "cpu", text: reading.contents.model, active: reading.modelActive, loading: reading.contents.loading,
                                         maxWidth: form.pills.modelWidth, compact: form.pills.modelIsCompact)
                        }.buttonStyle(.plain).fixedSize()
                        RefPillLabel(icon: "brain", text: reading.contents.effort, active: reading.effortActive, loading: false,
                                     maxWidth: ModelSwitchPills.effortLabelWidth, compact: form.pills.effortIsCompact).fixedSize()
                    }.padding(.trailing, ComposerBarMetrics.pillsTrailing)
                    Button {} label: {
                        Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold))
                            .frame(width: 30, height: 30).background(Color.piFillStrong, in: Circle())
                    }.buttonStyle(.plain)
                }.padding(.horizontal, 10).padding(.bottom, 8).padding(.top, 0)
            }.piElevated(radius: 16)
        }.padding(.horizontal, PiSpacing.lg).padding(.top, PiSpacing.sm).padding(.bottom, 6)
    }
}

// The released TranscriptScrollSurface had no sizeThatFits override. Keep
// its actual native scroll class and configuration so default representable
// sizing, rather than an explicit width shim, supplies the width oracle.
// Rows are omitted: this probe asserts horizontal allocation, not height.
@MainActor private struct SideTranscriptSurfaceV119Reference: NSViewRepresentable {
    let onMake: (TranscriptNativeScrollView) -> Void
    func makeNSView(context: Context) -> TranscriptNativeScrollView {
        let scroll = TranscriptNativeScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true; scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false; scroll.borderType = .noBorder
        scroll.horizontalScrollElasticity = .none
        onMake(scroll)
        return scroll
    }
    func updateNSView(_ view: TranscriptNativeScrollView, context: Context) { }
}

// Original TabContentHost/TabContentContainer proposal and AppKit attachment.
// The NSHostingView keeps its root and is moved in, as the released tab did.
@MainActor private struct KeptTabContentHostV119Reference: NSViewRepresentable {
    let root: AnyView
    final class Container: NSView {
        var hosted: NSHostingView<AnyView>?
        @MainActor func show(_ root: AnyView) {
            if let hosted { hosted.rootView = root; return }
            let hosted = NSHostingView(rootView: root)
            hosted.frame = bounds; hosted.autoresizingMask = [.width, .height]
            addSubview(hosted); self.hosted = hosted
        }
    }
    func makeNSView(context: Context) -> Container { let view = Container(); view.show(root); return view }
    func updateNSView(_ view: Container, context: Context) { view.show(root) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Container, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}
