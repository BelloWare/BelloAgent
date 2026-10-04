import SwiftUI

// TEMPORARY: the SwiftUI pill face, kept only for the transcript's SwiftUI
// rows (Transcript/TranscriptSkillPills.swift) until they draw
// `SkillPillFaceView`. Nothing in the workspace shell uses it.

/// What a pill looks like: the command glyph, "/name" and, when there are
/// any, the arguments cut short after it.
struct SkillPillFace: View {
    let name: String
    var arguments = ""
    var hovered = false
    var open = false
    nonisolated static let height: CGFloat = 18
    var body: some View {
        let shortened = SkillPillLabel.arguments(arguments)
        HStack(spacing: 4) {
            Image(systemName: "command").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.piAccent)
            Text("/" + name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.piAccent)
                .lineLimit(1).truncationMode(.middle).layoutPriority(1)
            if !shortened.isEmpty {
                Text(shortened).font(.system(size: 12)).foregroundStyle(Color.piInkSecondary).lineLimit(1).truncationMode(.tail)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: Self.height)
        .background {
            // The card's own surface under a light orange tint, so the pill
            // reads the same in the white composer and on the tinted bubble,
            // and its labels keep their contrast on both.
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            shape.fill(Color.piSurface)
                .overlay { shape.fill(Color.piBrandOrange.opacity(hovered || open ? 0.19 : 0.12)) }
                .overlay { if open { shape.strokeBorder(Color.piAccent.opacity(0.55), lineWidth: 1) } }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityHidden(true)
    }
}

