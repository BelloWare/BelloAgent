import SwiftUI

// MARK: - Sheets

struct PiSheet<Content: View, Actions: View, Footer: View>: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    var width: CGFloat? = nil
    var height: CGFloat? = nil
    var minWidth: CGFloat? = nil
    var minHeight: CGFloat? = nil
    /// True when this content fills a window of its own rather than a sheet:
    /// the header then replaces the system title bar and leaves room for the
    /// window buttons.
    var windowChrome = false
    /// A sheet in the middle of a write it must not be closed under — a rename
    /// being saved, a project being removed — holds Escape back until the write
    /// finishes. Everything else leaves on Escape.
    var cancelDisabled = false
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions
    @ViewBuilder var footer: Footer
    @State private var badgeShown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    init(_ title: String, subtitle: String? = nil, symbol: String? = nil, width: CGFloat? = nil, height: CGFloat? = nil, minWidth: CGFloat? = nil, minHeight: CGFloat? = nil, windowChrome: Bool = false, cancelDisabled: Bool = false,
         @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions = { EmptyView() }, @ViewBuilder footer: () -> Footer = { EmptyView() }) {
        self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.width = width; self.height = height
        self.minWidth = minWidth; self.minHeight = minHeight; self.windowChrome = windowChrome
        self.cancelDisabled = cancelDisabled
        self.content = content(); self.actions = actions(); self.footer = footer()
    }
    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .leading) {
                if windowChrome { PiWindowBar() }
                HStack(alignment: .center, spacing: PiSpacing.md) {
                    if let symbol {
                        PiIconBadge(symbol: symbol, size: 30)
                            .scaleEffect(badgeShown || reduceMotion ? 1 : 0.6).opacity(badgeShown || reduceMotion ? 1 : 0)
                            .animation(PiMotion.honouring(PiMotion.spring.delay(0.08), reduceMotion: reduceMotion), value: badgeShown)
                            .onAppear { badgeShown = true }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(PiFont.title(17)).foregroundStyle(Color.piInk)
                        if let subtitle { Text(subtitle).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).lineLimit(2).textSelection(.enabled) }
                    }
                    Spacer()
                    actions
                }
                .padding(.leading, windowChrome ? PiWindowBar.trafficLightInset : PiSpacing.xl)
                .padding(.trailing, PiSpacing.xl)
                .padding(.top, windowChrome ? PiSpacing.md : PiSpacing.lg).padding(.bottom, PiSpacing.lg)
            }
            .background(Color.piWindow)
            Rectangle().fill(Color.piHairline).frame(height: 1)
            content.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.piContent)
            if Footer.self != EmptyView.self {
                Rectangle().fill(Color.piHairline).frame(height: 1)
                footer.padding(.horizontal, PiSpacing.xl).padding(.vertical, PiSpacing.md).background(Color.piWindow)
            }
        }
        .buttonStyle(.piSecondary)
        .toggleStyle(.switch)
        .foregroundStyle(Color.piInk)
        .background(Color.piWindow)
        .frame(width: width, height: height)
        .frame(minWidth: minWidth, minHeight: minHeight)
        .background(escapeKey)
        .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
    }

    /// Escape leaves the sheet. Each sheet used to need its own cancel button
    /// to get that, and most never had one: the inspector, the message and
    /// content viewers, the resource sheet, the sides sheet and the git panel
    /// could only be closed with the mouse. The sheet carries the cancel action
    /// itself, taking no room in the layout and nothing in the reading order.
    /// A window presenting this same chrome keeps the system's own behaviour.
    @ViewBuilder private var escapeKey: some View {
        if !windowChrome {
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(cancelDisabled)
                .frame(width: 0, height: 0).opacity(0)
                .accessibilityHidden(true)
        }
    }
}
