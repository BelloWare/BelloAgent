import SwiftUI
import AppKit

// MARK: - Controls

/// Pill segmented control. The selected capsule glides to the chosen tab.
struct PiTabs<Tag: Hashable>: View {
    @Binding var selection: Tag
    let items: [(Tag, String)]
    @Namespace private var glide
    @Environment(\.piReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.0) { item in
                Button { selection = item.0 } label: {
                    // A tab is one word on one line. Squeezed into a narrow
                    // report the segmented control used to break "Requests"
                    // across two lines inside its own pill, which reads as a
                    // rendering fault rather than a tight fit; the control now
                    // keeps its width and lets its container scroll or wrap.
                    Text(item.1).font(.system(size: 12, weight: .medium)).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(selection == item.0 ? Color.piInk : Color.piInkSecondary)
                        .padding(.horizontal, 11).padding(.vertical, 5)
                        .background {
                            if selection == item.0 {
                                Capsule().fill(Color.piSurface).shadow(color: Color.piShadow, radius: 3, y: 1)
                                    .matchedGeometryEffect(id: "selected", in: glide)
                            }
                        }
                        .contentShape(Capsule())
                }.buttonStyle(.plain).piPointer()
            }
        }
        .padding(3)
        .background(Color.piFillStrong, in: Capsule())
        .animation(PiMotion.honouring(PiMotion.glide, reduceMotion: reduceMotion), value: selection)
    }
}

/// Pill dropdown backed by a system menu.
struct PiDropdown<Tag: Hashable>: View {
    @Binding var selection: Tag
    let items: [(Tag, String)]
    var placeholder = "Choose"
    var icon: String? = nil
    var compact = false
    private var current: String { items.first { $0.0 == selection }?.1 ?? placeholder }
    var body: some View {
        PiChoicePicker(title: placeholder, selection: selection,
                       choices: items.map { PiChoice(id: $0.0, title: $0.1) },
                       choose: { selection = $0 }) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.piInkSecondary) }
                Text(current).font(.system(size: compact ? 12 : 13, weight: .medium)).foregroundStyle(Color.piInk).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.piInkTertiary)
            }
            .padding(.horizontal, compact ? 10 : 12).padding(.vertical, compact ? 5 : 7)
            .background(Color.piSurface, in: Capsule())
            .overlay(Capsule().stroke(Color.piHairlineStrong, lineWidth: 1))
            .contentShape(Capsule())
        }
        .fixedSize()
    }
}

/// Pill-shaped menu button with a custom label.
struct PiMenuButton<Items: View>: View {
    let title: String
    var icon: String? = nil
    @ViewBuilder var items: Items
    var body: some View {
        Menu { items } label: {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 13, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.piInkTertiary)
            }
            .foregroundStyle(Color.piInk)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Color.piSurface, in: Capsule())
            .overlay(Capsule().stroke(Color.piHairlineStrong, lineWidth: 1))
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().piPointer()
    }
}

/// Rounded text field with an optional leading symbol.
struct PiTextField: View {
    let placeholder: String
    @Binding var text: String
    var icon: String? = nil
    var secure = false
    var mono = false
    var onSubmit: () -> Void = {}
    var body: some View {
        HStack(spacing: 7) {
            if let icon { Image(systemName: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.piInkTertiary) }
            Group {
                if secure { SecureField(placeholder, text: $text).onSubmit(onSubmit) }
                else { TextField(placeholder, text: $text).onSubmit(onSubmit) }
            }
            .textFieldStyle(.plain).font(mono ? PiFont.mono : PiFont.body).foregroundStyle(Color.piInk)
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .background(Color.piSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.piHairline, lineWidth: 1))
    }
}

/// Rounded numeric field.
struct PiNumberField: View {
    let placeholder: String
    @Binding var value: Int
    var width: CGFloat = 120
    var onSubmit: () -> Void = {}
    var body: some View {
        TextField(placeholder, value: $value, format: .number).onSubmit(onSubmit)
            .textFieldStyle(.plain).font(PiFont.body.monospacedDigit()).foregroundStyle(Color.piInk)
            .padding(.horizontal, 11).padding(.vertical, 7).frame(width: width)
            .background(Color.piSurface, in: RoundedRectangle(cornerRadius: PiRadius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PiRadius.sm, style: .continuous).stroke(Color.piHairlineStrong, lineWidth: 1))
    }
}

/// Minus/plus stepper with the value rendered as text.
struct PiStepper: View {
    let label: String
    @Binding var value: Int
    var range: ClosedRange<Int>
    var step = 1
    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(PiFont.body).foregroundStyle(Color.piInk).monospacedDigit()
            Spacer(minLength: 8)
            PiIconButton(symbol: "minus", label: "Decrease", size: 24, filled: true) { value = max(range.lowerBound, value - step) }.disabled(value <= range.lowerBound)
            PiIconButton(symbol: "plus", label: "Increase", size: 24, filled: true) { value = min(range.upperBound, value + step) }.disabled(value >= range.upperBound)
        }
    }
}
struct PiStepper64: View {
    let label: String
    @Binding var value: Int64
    var range: ClosedRange<Int64>
    var step: Int64 = 1
    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(PiFont.body).foregroundStyle(Color.piInk).monospacedDigit()
            Spacer(minLength: 8)
            PiIconButton(symbol: "minus", label: "Decrease", size: 24, filled: true) { value = max(range.lowerBound, value - step) }.disabled(value <= range.lowerBound)
            PiIconButton(symbol: "plus", label: "Increase", size: 24, filled: true) { value = min(range.upperBound, value + step) }.disabled(value >= range.upperBound)
        }
    }
}

/// Settings group: title, rows separated by hairlines, optional footnote.
struct PiSettingsGroup<Rows: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder var rows: Rows
    var body: some View {
        VStack(alignment: .leading, spacing: PiSpacing.sm) {
            Text(title).font(PiFont.micro).foregroundStyle(Color.piInkSecondary).textCase(.uppercase).tracking(0.5).padding(.leading, 4)
            VStack(spacing: 0) { rows }
                .background(Color.piSurface, in: RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous).stroke(Color.piHairline, lineWidth: 1))
            if let footer { Text(footer).font(PiFont.caption).foregroundStyle(Color.piInkTertiary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4) }
        }
    }
}
/// One settings row: label on the left, control on the right.
struct PiRow<Control: View>: View {
    let label: String
    var detail: String? = nil
    var last = false
    @ViewBuilder var control: Control
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: PiSpacing.lg) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(PiFont.body).foregroundStyle(Color.piInk)
                    if let detail { Text(detail).font(PiFont.caption).foregroundStyle(Color.piInkSecondary) }
                }.frame(minWidth: 180, alignment: .leading)
                Spacer(minLength: 0)
                control.frame(maxWidth: 380, alignment: .trailing)
            }
            .padding(.horizontal, PiSpacing.lg).padding(.vertical, 10)
            if !last { Rectangle().fill(Color.piHairline).frame(height: 1).padding(.leading, PiSpacing.lg) }
        }
    }
}

/// A one-point hairline that is also a drag handle: the boundary between the
/// sidebar and the content, above the terminal, and between the two panes of
/// a split. Every one of these used to be an invisible nine-point strip over
/// a plain hairline, so nothing on screen said it could be dragged. The grip
/// is always drawn, quietly, and the pointer only strengthens it — an
/// affordance may be reinforced by hover, never created by it.
struct PiResizeHandle: View {
    /// Which way the hairline runs: `.vertical` is a column boundary dragged
    /// left and right, `.horizontal` a row boundary dragged up and down.
    enum Orientation { case vertical, horizontal }
    /// The grip: 2 pt across the hairline, 18 pt along it.
    static let gripThickness: CGFloat = 2
    static let gripLength: CGFloat = 18
    /// What the pointer can actually grab, centred on the one-point line.
    static let hitThickness: CGFloat = 9
    /// Visible at rest, solid under the pointer or while dragging.
    static let restingGripOpacity: Double = 0.35

    let orientation: Orientation
    let label: String
    var hint = "Drag to resize"
    /// Set by the owner of the value being dragged, so the line can thicken
    /// for the whole drag even after the pointer leaves the nine-point strip.
    var dragging = false
    /// Movement along the drag axis since the gesture began.
    let changed: (CGFloat) -> Void
    let ended: (CGFloat) -> Void
    @State private var hovering = false
    private var vertical: Bool { orientation == .vertical }
    private var lit: Bool { hovering || dragging }
    var body: some View {
        Rectangle().fill(dragging ? Color.piHairlineStrong : Color.piHairline)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .overlay {
                Capsule(style: .continuous).fill(Color.piHairlineStrong)
                    .frame(width: vertical ? Self.gripThickness : Self.gripLength,
                           height: vertical ? Self.gripLength : Self.gripThickness)
                    .opacity(lit ? 1 : Self.restingGripOpacity)
                    .piAnimation(PiMotion.quick, value: lit)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay {
                Rectangle().fill(Color.clear)
                    .frame(width: vertical ? Self.hitThickness : nil, height: vertical ? nil : Self.hitThickness)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        hovering = inside
                        if inside { (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set() } else { NSCursor.arrow.set() }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { changed(vertical ? $0.translation.width : $0.translation.height) }
                        .onEnded { ended(vertical ? $0.translation.width : $0.translation.height) })
                    .accessibilityElement()
                    .accessibilityLabel(label)
                    .accessibilityHint(hint)
                    .accessibilityIdentifier("resizeHandle")
            }
            .zIndex(1)
    }
}

struct PiPager<Center: View>: View {
    let previous: () -> Void
    let next: () -> Void
    var canPrevious: Bool
    var canNext: Bool
    var previousLabel = "Previous"
    var nextLabel = "Next"
    @ViewBuilder var center: Center
    var body: some View {
        HStack(spacing: PiSpacing.sm) {
            Button(action: previous) { Label(previousLabel, systemImage: "chevron.left") }.buttonStyle(.piSecondaryCompact).disabled(!canPrevious)
            center.font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
            Button(action: next) { Label(nextLabel, systemImage: "chevron.right") }.labelStyle(.trailingIcon).buttonStyle(.piSecondaryCompact).disabled(!canNext)
        }
    }
}

struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.title; configuration.icon }
    }
}
extension LabelStyle where Self == TrailingIconLabelStyle {
    static var trailingIcon: TrailingIconLabelStyle { TrailingIconLabelStyle() }
}

/// Selectable row for custom lists (replaces stock List selection).
struct PiSelectableRow<Content: View>: View {
    let selected: Bool
    /// One of several rows marked for a bulk action. A marked row is outlined
    /// rather than highlighted, so the single gliding selection stays unique.
    var marked = false
    /// A row whose pointer is handled in AppKit — a draggable sidebar chat —
    /// shows its cursor from there, and must not push a second one here.
    var providesCursor = true
    let action: () -> Void
    var doubleClick: (() -> Void)? = nil
    @ViewBuilder var content: Content
    @State private var hovering = false
    @Environment(\.piSelectionNamespace) private var selectionNamespace
    @Environment(\.piReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background {
                    let shape = RoundedRectangle(cornerRadius: PiRadius.sm, style: .continuous)
                    ZStack {
                        if selected, let selectionNamespace {
                            // Move the highlight, not the row's live usage labels.
                            shape.fill(Color.piAccentSoft).matchedGeometryEffect(id: "pi-selection", in: selectionNamespace)
                        } else {
                            // A marked row is outlined, not filled: the accent
                            // wash belongs to the one row that is open, so a
                            // reader marking five chats can still see which one
                            // they are reading. Filling both made them identical.
                            shape.fill(selected ? Color.piAccentSoft : marked || hovering ? Color.piFill : Color.clear)
                        }
                        if marked && !selected { shape.stroke(Color.piAccent.opacity(0.55), lineWidth: 1) }
                    }
                    .animation(PiMotion.honouring(PiMotion.quick, reduceMotion: reduceMotion), value: hovering)
                    .animation(PiMotion.honouring(PiMotion.glide, reduceMotion: reduceMotion), value: selected)
                }
                .contentShape(RoundedRectangle(cornerRadius: PiRadius.sm, style: .continuous))
        }
        .buttonStyle(.plain).modifier(PiPointerModifier(active: providesCursor))
        .simultaneousGesture(TapGesture(count: 2).onEnded { doubleClick?() })
        .onHover { hovering = $0 }
    }
}

/// Wrapping horizontal layout for chips and metric pills.
struct PiFlow: Layout {
    var spacing: CGFloat = 6
    var rowSpacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + rowSpacing; rowHeight = 0 }
            x += size.width + spacing; rowHeight = max(rowHeight, size.height); maxX = max(maxX, x - spacing)
        }
        return CGSize(width: width.isFinite ? width : maxX, height: y + rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > bounds.width { x = 0; y += rowHeight + rowSpacing; rowHeight = 0 }
            subview.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
    }
}
