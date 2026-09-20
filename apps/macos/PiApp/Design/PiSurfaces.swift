import SwiftUI

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

/// Tiny ring gauge for ratios such as cache hit rate.
struct PiRing: View {
    let fraction: Double
    var size: CGFloat = 10
    var tone: Color = .piSuccess
    var body: some View {
        ZStack {
            Circle().stroke(Color.piFillStrong, lineWidth: 2)
            Circle().trim(from: 0, to: max(0, min(1, fraction))).stroke(tone, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                .piAnimation(PiMotion.base, value: fraction)
        }.frame(width: size, height: size)
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
