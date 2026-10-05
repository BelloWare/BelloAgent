// Chart palette for frozen SwiftUI references.
import SwiftUI
@testable import PiApp

extension Color {
    static var monitorCanvas: Color { Color(nsColor: .monitorCanvas) }
    static func monitorModel(_ index: Int) -> Color { Color(nsColor: .monitorModel(index)) }
}
