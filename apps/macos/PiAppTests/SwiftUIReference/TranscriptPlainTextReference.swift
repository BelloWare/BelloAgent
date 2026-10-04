import SwiftUI
import AppKit
@testable import PiApp

// The SwiftUI views of Transcript/TranscriptPlainText.swift before the transcript was AppKit,
// kept as they were for the parity tests to draw against.

/// Literal text as one selectable text. A short text is SwiftUI's own; a
/// long one — a paste can be the composer's whole 256 KiB — is a TextKit leaf
/// that measures its height once per width, as a long code fence is, rather
/// than one enormous SwiftUI text laid out on every pass.
struct TranscriptPlainText: View, Equatable {
    /// From this many bytes on the text is laid out by TextKit.
    static var textKitBytes: Int { TranscriptPlainTextView.textKitBytes }
    let text: String
    let face: TranscriptPlainTextFace

    static func usesTextKit(_ text: String) -> Bool { TranscriptPlainTextView.usesTextKit(text) }

    var body: some View {
        Group {
            if text.isEmpty {
                // A message with nothing typed (its images or skills are the
                // message) still gives its bubble the full width.
                Color.clear.frame(height: 0)
            } else if Self.usesTextKit(text) {
                NativePlainText(text: text, face: face)
            } else {
                Text(verbatim: text)
                    .font(face.font).foregroundStyle(TranscriptPalette.text)
                    .lineSpacing(face.lineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    nonisolated static func == (a: Self, b: Self) -> Bool { a.face == b.face && a.text.hasSameUTF8(as: b.text) }
}

/// The TextKit leaf, as SwiftUI sizes it: its height is the one the text
/// view measured at the width it was offered.
struct NativePlainText: NSViewRepresentable {
    let text: String
    let face: TranscriptPlainTextFace
    func makeNSView(context: Context) -> TranscriptPlainTextView { TranscriptPlainTextView() }
    func updateNSView(_ view: TranscriptPlainTextView, context: Context) {
        view.update(text: text, face: face, environment: TranscriptRowEnvironment(context.environment))
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TranscriptPlainTextView, context: Context) -> CGSize? {
        nsView.measure(width: proposal.width)
    }
}

/// A reply's markdown source exactly as it arrived: one selectable
/// monospaced text in the panel the transcript's code sits in.
struct ReplySourceView: View, Equatable {
    let source: String
    var body: some View {
        TranscriptPlainText(text: source, face: .source).equatable()
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TranscriptPalette.codeBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(TranscriptPalette.hair, lineWidth: 1))
            .accessibilityIdentifier("reply-source")
    }
    nonisolated static func == (a: Self, b: Self) -> Bool { a.source.hasSameUTF8(as: b.source) }
}

extension TranscriptPlainTextFace {
    /// The face as SwiftUI's font.
    var font: Font {
        let weights: [CGFloat: Font.Weight] = [NSFont.Weight.medium.rawValue: .medium, NSFont.Weight.semibold.rawValue: .semibold, NSFont.Weight.bold.rawValue: .bold]
        let font = Font.system(size: size, weight: weights[weight] ?? .regular, design: monospaced ? .monospaced : serif ? .serif : .default)
        return monospacedDigits ? font.monospacedDigit() : font
    }
}
