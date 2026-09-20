import SwiftUI

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
