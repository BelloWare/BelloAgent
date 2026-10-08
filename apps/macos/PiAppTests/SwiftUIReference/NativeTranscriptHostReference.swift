import SwiftUI
@testable import PiApp
import AppKit

// The SwiftUI side of the transcript: the pane's own view is AppKit
// (Transcript/NativeTranscriptView.swift, `NativeTranscriptPane`), and this
// file is all SwiftUI knows of it.

/// The conversation pane in a SwiftUI layout: `NativeTranscriptPane`, handed
/// the chat, its run state, the actions and the environment's values each
/// time the pane above is drawn.
struct NativeTranscriptView: NSViewRepresentable {
    let session: SessionDisplay
    /// The session's run state, observed by the pane and handed down so the live bar follows it.
    var state = "idle"
    let actions: TranscriptActions
    var onAnchorChanged: (TranscriptAnchor?) -> Void = { _ in }
    var onReadReply: (String, String) -> Void = { _, _ in }
    var onLoadEarlier: (String) -> Void = { _ in }
    var onLoadNewer: (String) -> Void = { _ in }
    var onLatest: (String) -> Void = { _ in }
    var onViewportReady: (String, UUID) -> Void = { _, _ in }

    func makeNSView(context: Context) -> NativeTranscriptPane { NativeTranscriptPane() }
    func updateNSView(_ pane: NativeTranscriptPane, context: Context) {
        pane.onAnchorChanged = onAnchorChanged; pane.onReadReply = onReadReply
        pane.onLoadEarlier = onLoadEarlier; pane.onLoadNewer = onLoadNewer; pane.onLatest = onLatest
        pane.onPrefetchEarlier = onLoadEarlier; pane.onPrefetchNewer = onLoadNewer
        pane.onViewportReady = onViewportReady
        pane.update(session: session, state: state, actions: actions, environment: TranscriptRowEnvironment(context.environment),
                    reduceMotion: context.environment.piReduceMotion)
    }
    /// The pane takes the room it is offered, whatever it shows: its note
    /// and edges never size it, as they never sized the SwiftUI pane.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeTranscriptPane, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height, width.isFinite, height.isFinite else { return nil }
        return CGSize(width: width, height: height)
    }
}

/// The pane is drawn again for every change to the workspace, and makes the
/// transcript's actions afresh each time, though each still reaches the chat
/// through the same model and session. For the same session, in the same run
/// state, offering the same actions, the transcript is the same: drawing it
/// again laid the live bar and every overlay out again for nothing. What the
/// session itself changes still reaches it, since the pane observes the session.
extension NativeTranscriptView: Equatable {
    nonisolated static func == (lhs: NativeTranscriptView, rhs: NativeTranscriptView) -> Bool {
        MainActor.assumeIsolated {
            lhs.session === rhs.session && lhs.state == rhs.state && lhs.actions.offered == rhs.actions.offered
        }
    }
}

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
