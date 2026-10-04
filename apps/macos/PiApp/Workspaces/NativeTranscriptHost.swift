import SwiftUI
import AppKit

// The SwiftUI side of the transcript: the pane's own view is AppKit
// (Transcript/), and this file is all SwiftUI knows of it.

extension TranscriptRowEnvironment {
    /// The values a row is drawn under, read from SwiftUI's environment.
    init(_ values: EnvironmentValues) {
        self.init()
        colorScheme = values.colorScheme == .dark ? .dark : .light
        increasedContrast = values.colorSchemeContrast == .increased
        layoutDirection = values.layoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
        locale = values.locale; isEnabled = values.isEnabled
        forks = values.transcriptForks; opensFiles = values.transcriptOpensFiles
    }
    /// The colour scheme and direction in SwiftUI's terms.
    var swiftUIColorScheme: ColorScheme { colorScheme == .dark ? .dark : .light }
    var swiftUILayoutDirection: LayoutDirection { layoutDirection == .rightToLeft ? .rightToLeft : .leftToRight }
}

/// Whether a file tool's path opens its file here (a chat's own pane). The
/// pane sets it; the transcript's rows carry it to each row.
private struct TranscriptOpensFilesKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var transcriptOpensFiles: Bool {
        get { self[TranscriptOpensFilesKey.self] }
        set { self[TranscriptOpensFilesKey.self] = newValue }
    }
}

/// Whether the chat on screen can fork from its replies (a saved chat of the
/// app's own). The pane sets it; the transcript's rows carry it to each row.
private struct TranscriptForksKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var transcriptForks: Bool {
        get { self[TranscriptForksKey.self] }
        set { self[TranscriptForksKey.self] = newValue }
    }
}

