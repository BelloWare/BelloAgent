import AppKit
import Combine
import SwiftUI
import XCTest
@testable import PiApp


/// What the probe below saw, so a test can read it back.
@MainActor final class VisibilityRecorder {
    var reports: [Bool] = []
}

/// A view shaped like the sheets that watch their window: it keeps the answer
/// in its own `@State` and draws from it, which is what made the teardown
/// write a conflict.
struct WindowVisibilityProbe: View {
    let recorder: VisibilityRecorder
    @State private var onScreen = false
    var body: some View {
        Text(onScreen ? "on screen" : "not on screen")
            .piWindowVisibility { visible in
                onScreen = visible
                recorder.reports.append(visible)
            }
    }
}
