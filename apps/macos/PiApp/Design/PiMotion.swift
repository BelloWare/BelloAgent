import SwiftUI

// MARK: - Motion

/// Motion tokens shared by every view: three eased durations for state
/// changes and two springs for things that move. `piAnimation` applies them
/// and drops the animation when the reader asked for reduced motion.
enum PiMotion {
    static let quickMilliseconds = 140
    static let baseMilliseconds = 220
    static let slowMilliseconds = 320
    static let quick = Animation.easeOut(duration: Double(quickMilliseconds) / 1_000)
    static let base = Animation.easeOut(duration: Double(baseMilliseconds) / 1_000)
    static let slow = Animation.easeInOut(duration: Double(slowMilliseconds) / 1_000)
    /// A short spring with a small overshoot, for things that pop in.
    static let spring = Animation.spring(response: 0.34, dampingFraction: 0.78)
    /// A tighter spring for things that slide: a selection highlight, a panel.
    static let glide = Animation.spring(response: 0.3, dampingFraction: 0.88)
    /// A row, a group of rows or a panel arriving in place: it comes from the
    /// edge it is attached to and fades as it comes, and leaves the same way.
    /// Used wherever something takes room the reader did not have to ask for.
    static func arrival(from edge: Edge) -> AnyTransition {
        .move(edge: edge).combined(with: .opacity)
    }
    /// The same, for a group that opens downwards under its header.
    static var reveal: AnyTransition { arrival(from: .top) }
    /// What every animated surface hands SwiftUI: the token, or nothing at
    /// all when the reader has asked for reduced motion. One decision in one
    /// place, so "Reduce Motion turns it off" is a rule a test can hold to
    /// rather than fifteen ternaries that each have to be right.
    static func honouring(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}
private struct PiAnimated<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View { content.animation(PiMotion.honouring(animation, reduceMotion: reduceMotion), value: value) }
}
/// Native text layout and scroll restoration must see the final geometry,
/// without inheriting an animation from a sibling's disclosure or status.
/// Local decorative animations inside the boundary may still opt in.
private struct PiStableLayout: ViewModifier {
    let reduceMotionOverride: Bool?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.transaction {
            $0.animation = nil
            if reduceMotionOverride ?? reduceMotion { $0.disablesAnimations = true }
        }
    }
}
/// A brief fade with four points of movement on first appearance. Siblings
/// start 20 ms apart, capped at 60 ms so content is fully visible within 200 ms.
private struct PiStaggeredAppearance: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 4)
            .animation(PiMotion.honouring(PiMotion.quick.delay(0.02 * Double(min(3, max(0, index)))), reduceMotion: reduceMotion), value: shown)
            .onAppear { shown = true }
    }
}
extension View {
    /// `animation(_:value:)` that honours Reduce Motion.
    func piAnimation<Value: Equatable>(_ animation: Animation, value: Value) -> some View { modifier(PiAnimated(animation: animation, value: value)) }
    /// Do not interpolate native text or scroll geometry for an ancestor's animation.
    func piStableLayout(reduceMotion: Bool? = nil) -> some View { modifier(PiStableLayout(reduceMotionOverride: reduceMotion)) }
    /// Brief first-appearance feedback with a capped stagger; no motion when reduced.
    func piStaggered(_ index: Int) -> some View { modifier(PiStaggeredAppearance(index: index)) }
}
/// The namespace a list shares so its selection highlight glides from row to row.
private struct PiSelectionNamespaceKey: EnvironmentKey { static var defaultValue: Namespace.ID? { nil } }
extension EnvironmentValues {
    var piSelectionNamespace: Namespace.ID? { get { self[PiSelectionNamespaceKey.self] } set { self[PiSelectionNamespaceKey.self] = newValue } }
}
