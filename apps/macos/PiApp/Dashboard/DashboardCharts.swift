import SwiftUI

// TEMPORARY (0.1.120): the monitor's colours for the SwiftUI views that still
// draw with them (the Session Inspector's charts until the Inspector batch,
// and Transcript/CompactTurnReport, another workstream's). Delete with the last.
extension Color {
    static var monitorCanvas: Color { Color(nsColor: .monitorCanvas) }
    static func monitorModel(_ index: Int) -> Color { Color(nsColor: .monitorModel(index)) }
}
