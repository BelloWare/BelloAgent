import SwiftUI
import AppKit

// Shared visual language for the native shell, aligned with Bello Box: cream
// surfaces with a soft orange wash, white cards on hairlines, gradient primary
// actions and tinted icon badges. Colors are dynamic NSColors so light and
// dark appearance resolve automatically.

enum PiSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
}

enum PiRadius {
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 22
}

extension Color {
    /// Appearance-aware color built from explicit light and dark values.
    static func piDynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
    /// Application canvas behind the sidebar and sheet chrome: Bello Box cream.
    static let piWindow = piDynamic(light: rgb(0xF6F1EA), dark: rgb(0x1E1B18))
    /// Main content canvas: transcript, editors, sheet bodies.
    static let piContent = piDynamic(light: rgb(0xFCF9F5), dark: rgb(0x26221E))
    /// Raised surfaces: cards, the composer, fields.
    static let piSurface = piDynamic(light: rgb(0xFFFFFF), dark: rgb(0x2E2925))
    static let piSurfaceSunken = piDynamic(light: rgb(0xF7F2EC), dark: rgb(0x211D1A))
    static let piInk = piDynamic(light: rgb(0x1F1B17), dark: rgb(0xF1ECE5))
    static let piInkSecondary = piDynamic(light: rgb(0x6F675E), dark: rgb(0xB0A79C))
    static let piInkTertiary = piDynamic(light: rgb(0x9E958A), dark: rgb(0x7C7469))
    static let piHairline = piDynamic(light: rgb(0x000000, 0.07), dark: rgb(0xFFFFFF, 0.09))
    static let piHairlineStrong = piDynamic(light: rgb(0x000000, 0.12), dark: rgb(0xFFFFFF, 0.16))
    static let piFill = piDynamic(light: rgb(0x000000, 0.045), dark: rgb(0xFFFFFF, 0.05))
    static let piFillStrong = piDynamic(light: rgb(0x000000, 0.075), dark: rgb(0xFFFFFF, 0.09))
    /// Decorative Bello Box orange; text and action fills use a deeper light
    /// variant so small labels remain readable on cream surfaces.
    static let piBrandOrange = piDynamic(light: rgb(0xD67520), dark: rgb(0xF0A052))
    static let piAccent = piDynamic(light: rgb(0x984709), dark: rgb(0xF0A052))
    static let piAccentDeep = piDynamic(light: rgb(0x873C08), dark: rgb(0xD9862E))
    static let piAccentSoft = piDynamic(light: rgb(0xD67520, 0.12), dark: rgb(0xF0A052, 0.18))
    static let piOnAccent = piDynamic(light: rgb(0xFFFFFF), dark: rgb(0x1E1B18))
    static let piSuccess = piDynamic(light: rgb(0x3D8A57), dark: rgb(0x7CC48F))
    static let piWarning = piDynamic(light: rgb(0xA8781C), dark: rgb(0xE3B15C))
    static let piDanger = piDynamic(light: rgb(0xC03A3A), dark: rgb(0xEA7C7C))
    static let piInfo = piDynamic(light: rgb(0x4A6FC7), dark: rgb(0x8FAAF0))
    static let piShadow = piDynamic(light: rgb(0x2A2418, 0.09), dark: rgb(0x000000, 0.34))
}

enum PiFont {
    static func display(_ size: CGFloat = 26) -> Font { .system(size: size, weight: .bold) }
    static func title(_ size: CGFloat = 17) -> Font { .system(size: size, weight: .semibold) }
    static let heading = Font.system(size: 14, weight: .semibold)
    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 11.5)
    static let micro = Font.system(size: 10.5, weight: .medium)
    static let mono = Font.system(size: 12, design: .monospaced)
}

enum PiTone {
    case neutral, accent, success, warning, danger, info
    var color: Color {
        switch self {
        case .neutral: return .piInkSecondary
        case .accent: return .piAccent
        case .success: return .piSuccess
        case .warning: return .piWarning
        case .danger: return .piDanger
        case .info: return .piInfo
        }
    }
    static func forSessionState(_ state: String) -> PiTone {
        switch state {
        case "queued", "running", "stopping", "compacting": return .warning
        case "error", "interrupted", "failed": return .danger
        case "paused": return .info
        default: return .success
        }
    }
}

// MARK: - Buttons

/// Pointing-hand cursor for custom controls. AppKit only changes the cursor for
/// stock controls, so every clickable Pi component opts in; disabled controls
/// keep the arrow.
struct PiPointerModifier: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    @State private var pushed = false
    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering && enabled && !pushed { NSCursor.pointingHand.push(); pushed = true }
                else if !hovering && pushed { NSCursor.pop(); pushed = false }
            }
            .onDisappear { if pushed { NSCursor.pop(); pushed = false } }
    }
}
extension View {
    /// Shows the pointing-hand cursor while hovering an enabled control.
    func piPointer() -> some View { modifier(PiPointerModifier()) }
}

/// Idle, hover and pressed fills for pill buttons, so a hovered button reads
/// as clickable before it is pressed.
private struct PiPillSurface: ViewModifier {
    let pressed: Bool
    let idle: Color, hover: Color, active: Color
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(pressed ? active : hovering ? hover : idle, in: Capsule())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Flat brand-orange pill for the single primary action on a surface.
struct PiPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(Color.piOnAccent)
            .padding(.horizontal, compact ? 12 : 16).padding(.vertical, compact ? 6 : 8)
            .modifier(PiPrimarySurface(pressed: configuration.isPressed))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Capsule())
            .piPointer()
    }
}
/// Shade the flat fill on interaction without fading its foreground label.
private struct PiPrimarySurface: ViewModifier {
    let pressed: Bool
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background {
                Capsule().fill(Color.piBrandOrange)
                    .overlay(Capsule().fill(Color.black.opacity(pressed ? 0.10 : hovering ? 0.05 : 0)))
            }
            .shadow(color: Color.piBrandOrange.opacity(0.22), radius: 5, y: 2)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
/// Soft, bordered pill for secondary actions.
struct PiSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .medium))
            .foregroundStyle(Color.piInk)
            .padding(.horizontal, compact ? 11 : 14).padding(.vertical, compact ? 5 : 7)
            .modifier(PiPillSurface(pressed: configuration.isPressed, idle: Color.piFill, hover: Color.piFillStrong, active: Color.piFillStrong))
            .overlay(Capsule().stroke(Color.piHairline, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Capsule())
            .piPointer()
    }
}
/// Text-only action that lights up on hover.
struct PiGhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var tone: PiTone = .neutral
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(tone == .neutral ? Color.piInkSecondary : tone.color)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .modifier(PiPillSurface(pressed: configuration.isPressed, idle: Color.clear, hover: Color.piFill, active: Color.piFillStrong))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Capsule())
            .piPointer()
    }
}
/// Destructive pill in a soft danger tint.
struct PiDangerButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.piDanger)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .modifier(PiPillSurface(pressed: configuration.isPressed, idle: Color.piDanger.opacity(0.12), hover: Color.piDanger.opacity(0.17), active: Color.piDanger.opacity(0.22)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Capsule())
            .piPointer()
    }
}
extension ButtonStyle where Self == PiPrimaryButtonStyle { static var piPrimary: PiPrimaryButtonStyle { PiPrimaryButtonStyle() }; static var piPrimaryCompact: PiPrimaryButtonStyle { PiPrimaryButtonStyle(compact: true) } }
extension ButtonStyle where Self == PiSecondaryButtonStyle { static var piSecondary: PiSecondaryButtonStyle { PiSecondaryButtonStyle() }; static var piSecondaryCompact: PiSecondaryButtonStyle { PiSecondaryButtonStyle(compact: true) } }
extension ButtonStyle where Self == PiGhostButtonStyle { static var piGhost: PiGhostButtonStyle { PiGhostButtonStyle() } }
extension ButtonStyle where Self == PiDangerButtonStyle { static var piDanger: PiDangerButtonStyle { PiDangerButtonStyle() } }

/// Symbol-only button with a soft hover circle.
struct PiIconButton: View {
    let symbol: String
    let label: String
    var tone: PiTone = .neutral
    var size: CGFloat = 28
    var filled = false
    var action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(tone == .neutral ? Color.piInkSecondary : tone.color)
                .frame(width: size, height: size)
                .background(filled || hovering ? Color.piFillStrong : Color.clear, in: Circle())
                .contentShape(Circle())
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain).piPointer()
        .opacity(enabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Badges and chips

/// Text helpers shared by headers and rows.
enum PiFormat {
    /// Abbreviates opaque identifiers (UUIDs, hashes) for headers; full IDs stay in help text and detail views.
    static func shortID(_ id: String, keep: Int = 8) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > keep + 3 else { return trimmed }
        return String(trimmed.prefix(keep)) + "…"
    }
}

/// Rounded icon square: a soft tone tint like Bello Box's tool tiles, or the
/// accent gradient with a coloured shadow for a header.
struct PiIconBadge: View {
    let symbol: String
    var tone: PiTone = .accent
    var size: CGFloat = 28
    /// A solid brand-orange square with a white symbol, for sheet headers.
    var filled = false
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: filled ? .bold : .semibold))
            .foregroundStyle(filled ? Color.piOnAccent : tone.color)
            .frame(width: size, height: size)
            .background {
                let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                if filled { shape.fill(Color.piBrandOrange) } else { shape.fill(tone.color.opacity(0.13)) }
            }
            .accessibilityHidden(true)
    }
}

struct PiBadge: View {
    let text: String
    var tone: PiTone = .neutral
    var icon: String? = nil
    var dot = false
    var body: some View {
        HStack(spacing: 5) {
            if dot { Circle().fill(tone.color).frame(width: 6, height: 6) }
            if let icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)) }
            if !text.isEmpty { Text(text).font(PiFont.micro).lineLimit(1) }
        }
        .foregroundStyle(tone == .neutral ? Color.piInkSecondary : tone.color)
        .padding(.horizontal, text.isEmpty ? 6 : 8).padding(.vertical, 3.5)
        .background(tone == .neutral ? Color.piFill : tone.color.opacity(0.13), in: Capsule())
    }
}

struct PiChip: View {
    let text: String
    var icon: String? = nil
    var help: String? = nil
    var action: () -> Void = {}
    var remove: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 6) {
            Button(action: action) {
                HStack(spacing: 5) {
                    if let icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.piAccent) }
                    Text(text).font(PiFont.caption).foregroundStyle(Color.piInk).lineLimit(1)
                }
            }.buttonStyle(.plain).piPointer()
            if let remove {
                Button(action: remove) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain).piPointer().foregroundStyle(Color.piInkTertiary).help("Remove")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.piSurface, in: Capsule())
        .overlay(Capsule().stroke(Color.piHairlineStrong, lineWidth: 1))
        .help(help ?? text)
    }
}

// MARK: - Surfaces

struct PiCard<Content: View>: View {
    var padding: CGFloat = PiSpacing.lg
    var sunken = false
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(sunken ? Color.piSurfaceSunken : Color.piSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.piHairline, lineWidth: 1))
    }
}

/// Rounded, bordered container for lists and editors.
struct PiInset: ViewModifier {
    var sunken = false
    func body(content: Content) -> some View {
        content
            .background(sunken ? Color.piSurfaceSunken : Color.piSurface, in: RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous).stroke(Color.piHairline, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: PiRadius.md, style: .continuous))
    }
}
extension View {
    func piInset(sunken: Bool = false) -> some View { modifier(PiInset(sunken: sunken)) }
    /// Popup chrome: a flat surface, a light border and a deep soft shadow.
    /// A raised surface: white on a hairline with a short, soft shadow, so it
    /// sits on the canvas rather than floating above it.
    func piElevated(radius: CGFloat = 18) -> some View {
        self.background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.piSurface))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Color.piHairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .shadow(color: Color.piShadow, radius: 12, y: 4)
    }
}

struct PiSectionHeader<Accessory: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var accessory: Accessory
    init(_ title: String, subtitle: String? = nil, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title; self.subtitle = subtitle; self.accessory = accessory()
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(PiFont.heading).foregroundStyle(Color.piInk)
                if let subtitle { Text(subtitle).font(PiFont.caption).foregroundStyle(Color.piInkSecondary) }
            }
            Spacer()
            accessory
        }
    }
}

struct PiStatTile: View {
    let title: String
    let value: String
    var caption: String? = nil
    var symbol: String? = nil
    var tone: PiTone = .accent
    var body: some View {
        PiCard(padding: PiSpacing.md) {
            // A tinted glyph beside the label reads calmer than a filled badge,
            // and the caption reserves its two lines so a row of tiles keeps
            // one height however long the captions are.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if let symbol { Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(tone.color) }
                    Text(title).font(PiFont.micro).foregroundStyle(Color.piInkSecondary).textCase(.uppercase).tracking(0.5).lineLimit(1)
                }
                Text(value).font(.system(size: 20, weight: .semibold)).foregroundStyle(Color.piInk).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                if let caption {
                    Text(caption).font(PiFont.caption).foregroundStyle(Color.piInkTertiary)
                        .lineLimit(2, reservesSpace: true).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A quiet share bar for distribution rows: a tinted capsule over a faint
/// track. Unlike a meter it never turns to a warning color; a share is a fact.
struct UsageShareBar: View {
    let fraction: Double
    var tone: Color = .piAccent
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.piFillStrong)
                Capsule().fill(tone).frame(width: max(0, min(1, fraction)) * geometry.size.width)
            }
        }.accessibilityHidden(true)
    }
}

struct PiMeter: View {
    let fraction: Double
    var height: CGFloat = 5
    private var tone: Color { fraction > 0.95 ? .piDanger : fraction > 0.8 ? .piWarning : .piAccent }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.piFillStrong)
                Capsule().fill(tone).frame(width: max(0, min(1, fraction)) * geometry.size.width)
                    .animation(.easeOut(duration: 0.4), value: fraction)
            }
        }.frame(height: height)
    }
}

/// Tiny ring gauge for ratios such as cache hit rate.
struct PiRing: View {
    let fraction: Double
    var size: CGFloat = 10
    var tone: Color = .piSuccess
    var body: some View {
        ZStack {
            Circle().stroke(Color.piFillStrong, lineWidth: 2)
            Circle().trim(from: 0, to: max(0, min(1, fraction))).stroke(tone, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: fraction)
        }.frame(width: size, height: size)
    }
}

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
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions
    @ViewBuilder var footer: Footer
    init(_ title: String, subtitle: String? = nil, symbol: String? = nil, width: CGFloat? = nil, height: CGFloat? = nil, minWidth: CGFloat? = nil, minHeight: CGFloat? = nil, windowChrome: Bool = false,
         @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions = { EmptyView() }, @ViewBuilder footer: () -> Footer = { EmptyView() }) {
        self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.width = width; self.height = height
        self.minWidth = minWidth; self.minHeight = minHeight; self.windowChrome = windowChrome
        self.content = content(); self.actions = actions(); self.footer = footer()
    }
    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .leading) {
                if windowChrome { PiWindowBar() }
                HStack(alignment: .center, spacing: PiSpacing.md) {
                    if let symbol { PiIconBadge(symbol: symbol, size: 30) }
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
    }
}

// MARK: - Text and notes

struct PiNote: View {
    let text: String
    var tone: PiTone = .neutral
    init(_ text: String, tone: PiTone = .neutral) { self.text = text; self.tone = tone }
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: tone == .danger ? "exclamationmark.triangle.fill" : tone == .warning ? "exclamationmark.circle" : "info.circle")
                .font(.system(size: 11)).foregroundStyle(tone == .neutral ? Color.piInkTertiary : tone.color).padding(.top, 1)
            Text(text).font(PiFont.caption).foregroundStyle(tone == .danger ? tone.color : Color.piInkSecondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
}

struct PiStatusLine: View {
    let text: String
    var tone: PiTone = .neutral
    var body: some View { if !text.isEmpty { PiNote(text, tone: tone) } }
}

struct PiKeyValue: View {
    let key: String
    let value: String
    var mono = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PiSpacing.md) {
            Text(key).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).frame(width: 120, alignment: .leading)
            Text(value).font(mono ? PiFont.mono : PiFont.caption).foregroundStyle(Color.piInk).textSelection(.enabled).lineLimit(2)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Controls

/// Pill segmented control.
struct PiTabs<Tag: Hashable>: View {
    @Binding var selection: Tag
    let items: [(Tag, String)]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.0) { item in
                Button { selection = item.0 } label: {
                    Text(item.1).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selection == item.0 ? Color.piInk : Color.piInkSecondary)
                        .padding(.horizontal, 11).padding(.vertical, 5)
                        .background(selection == item.0 ? Color.piSurface : Color.clear, in: Capsule())
                        .shadow(color: selection == item.0 ? Color.piShadow : .clear, radius: 3, y: 1)
                        .contentShape(Capsule())
                }.buttonStyle(.plain).piPointer()
            }
        }
        .padding(3)
        .background(Color.piFillStrong, in: Capsule())
        .animation(.easeOut(duration: 0.16), value: selection)
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
        Menu {
            ForEach(items, id: \.0) { item in Button(item.1) { selection = item.0 } }
        } label: {
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
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().piPointer()
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
    let action: () -> Void
    var doubleClick: (() -> Void)? = nil
    @ViewBuilder var content: Content
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(selected ? Color.piAccentSoft : hovering ? Color.piFill : Color.clear, in: RoundedRectangle(cornerRadius: PiRadius.sm, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: PiRadius.sm, style: .continuous))
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.18), value: selected)
        }
        .buttonStyle(.plain).piPointer()
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
