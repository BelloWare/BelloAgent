import Combine

@MainActor final class PiChartSelection: ObservableObject {
    @Published private(set) var index: Int?
    /// Every pointer event lands here; a step within the same item publishes nothing.
    func select(_ index: Int?) { if self.index != index { self.index = index } }
}

