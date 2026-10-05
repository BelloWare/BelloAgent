import SwiftUI
@testable import PiApp

// The SwiftUI views the markdown surface laid over its text before they
// were AppKit, kept as they were for the parity tests to draw against.

/// A fence's toolbar: its language and a copy of its whole code.
struct MarkdownCodeToolbar: View {
    let language: String?
    let code: String
    let environment: TranscriptRowEnvironment
    var body: some View {
        HStack(spacing: 6) {
            if let language {
                Text(language.lowercased()).font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(TranscriptPalette.faint).accessibilityLabel("Language \(language)")
            }
            CopyButton(target: MarkdownCopyTarget(kind: .code, label: "Copy code", text: code), visible: true)
        }
        .frame(height: 20)
        .environment(\.colorScheme, environment.swiftUIColorScheme)
    }
}

/// A heading's copy button: its section, as markdown.
struct MarkdownHeadingAction: View {
    let target: MarkdownCopyTarget
    let environment: TranscriptRowEnvironment
    var body: some View {
        CopyButton(target: target, visible: true).environment(\.colorScheme, environment.swiftUIColorScheme)
    }
}

/// "Open full table" for a table shown as a preview.
struct MarkdownTableAction: View {
    let mark: MarkdownTableMark
    let environment: TranscriptRowEnvironment
    var body: some View {
        Button("Open full table") { MarkdownTableWindow.open(header: mark.header, rows: mark.rows) }
            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(TranscriptPalette.accent)
            .piPointer()
            .environment(\.colorScheme, environment.swiftUIColorScheme)
    }
}
