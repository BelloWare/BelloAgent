import AppKit
import SwiftUI

// The app's own switch, checkbox, progress bar and date field, in place of
// the stock AppKit ones. Each takes the stock control's room, so a row keeps
// its size, and keeps its keyboard and accessibility behaviour.

/// The app's switch: an accent track when on, a quiet one when off, and a
/// white knob, as large as AppKit's switch at the same control size (mini
/// 26×15, small 32×18, regular 38×22) and 8 points after its label, as the
/// stock switch sits, so a settings row keeps its size. A plain button
/// underneath gives it keyboard focus and Space. To accessibility it is the
/// stock switch, with its label and state.
///
/// `.labelsHidden()` does not reach a custom style before macOS 15: a hidden
/// label is written `Toggle("", …)`, and takes no room, gap included.
struct PiSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { PiSwitch(configuration: configuration) }
}

/// The app's checkbox, as the Changes panel draws its ticks: a filled accent
/// square with a check when on, an outlined one when off, 14 points and 5
/// before its label, as the stock checkbox. To accessibility it is the stock
/// checkbox.
struct PiCheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { PiCheckbox(configuration: configuration) }
}

extension ToggleStyle where Self == PiSwitchToggleStyle { static var piSwitch: PiSwitchToggleStyle { PiSwitchToggleStyle() } }
extension ToggleStyle where Self == PiCheckboxToggleStyle { static var piCheckbox: PiCheckboxToggleStyle { PiCheckboxToggleStyle() } }

/// AppKit's switch track per control size, which the stock SwiftUI switch
/// takes whole (`PiControlSizeTests`).
enum PiSwitchMetrics {
    static func track(_ size: ControlSize) -> CGSize {
        switch size {
        case .mini: return CGSize(width: 26, height: 15)
        case .small: return CGSize(width: 32, height: 18)
        default: return CGSize(width: 38, height: 22)
        }
    }
}

private struct PiSwitch: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.piReduceMotion) private var reduceMotion
    var body: some View {
        PiLabelledControl(spacing: 8) {
            configuration.label
            Button { configuration.isOn.toggle() } label: { track }
                .buttonStyle(.plain)
                .modifier(PiPointerModifier(active: isEnabled))
        }
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch) }
    }
    private var track: some View {
        let track = PiSwitchMetrics.track(controlSize)
        let knob = track.height - 4, on = configuration.isOn
        return ZStack(alignment: on ? .trailing : .leading) {
            Capsule().fill(on ? Color.piAccent : Color.piFillStrong)
                .overlay(Capsule().strokeBorder(on ? Color.clear : Color.piHairlineStrong, lineWidth: 1))
            Circle().fill(Color.white).frame(width: knob, height: knob)
                .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                .padding(2)
        }
        .frame(width: track.width, height: track.height)
        .opacity(isEnabled ? 1 : 0.45)
        .animation(reduceMotion ? nil : PiMotion.quick, value: on)
        .contentShape(Capsule())
    }
}

private struct PiCheckbox: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        Button { configuration.isOn.toggle() } label: {
            PiLabelledControl(spacing: 5, labelFirst: false) {
                configuration.label
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(configuration.isOn ? Color.piAccent : Color.piInkTertiary)
                    .frame(width: 14, height: 14)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(PiPointerModifier(active: isEnabled))
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.checkbox) }
    }
}

/// A toggle's label and its control, `spacing` apart and centred on one
/// line: the switch after its label, the checkbox before it. A label that
/// takes no width, as `Toggle("", …)`, leaves no gap either.
private struct PiLabelledControl: Layout {
    var spacing: CGFloat
    var labelFirst = true
    /// The label is always the first subview, the control the second.
    private func sizes(_ subviews: Subviews, width: CGFloat?) -> (label: CGSize, control: CGSize, gap: CGFloat) {
        let control = subviews[1].sizeThatFits(.unspecified)
        let label = subviews[0].sizeThatFits(ProposedViewSize(width: width.map { max(0, $0 - control.width - spacing) }, height: nil))
        return (label, control, label.width > 0 ? spacing : 0)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let (label, control, gap) = sizes(subviews, width: proposal.width)
        return CGSize(width: label.width + gap + control.width, height: max(label.height, control.height))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let (label, control, gap) = sizes(subviews, width: bounds.width)
        let first = labelFirst ? label : control, second = labelFirst ? control : label
        let (firstView, secondView) = labelFirst ? (subviews[0], subviews[1]) : (subviews[1], subviews[0])
        firstView.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(first))
        secondView.place(at: CGPoint(x: bounds.minX + first.width + gap, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(second))
    }
}

/// A determinate bar: a 4-point track and the share done in the accent, in
/// the room the stock bar took, so what sits under it stays where it was.
/// To accessibility it is the stock progress indicator, with its value.
struct PiProgressBar: View {
    let value: Double
    let total: Double
    private var fraction: Double { total > 0 && value.isFinite ? min(1, max(0, value / total)) : 0 }
    var body: some View {
        Capsule().fill(Color.piFill).frame(height: 4)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in Capsule().fill(Color.piAccent).frame(width: geometry.size.width * fraction) }
            }
            .frame(height: PiProgressBar.room)
            .accessibilityRepresentation { ProgressView(value: fraction) }
    }
    /// The height the stock bar's view took (`PiControlSizeTests`).
    static let room: CGFloat = 18
}

extension PiSpinner {
    /// The ring at the size AppKit's spinning indicator takes at a control
    /// size, for a place that had one: mini 10, small 16, regular 32 points.
    init(controlSize: ControlSize) {
        switch controlSize {
        case .mini: self.init(size: 10, lineWidth: 1.4)
        case .small: self.init(size: 16, lineWidth: 1.8)
        default: self.init(size: 32, lineWidth: 2.6)
        }
    }
}

/// A date and time the reader types, as AppKit's date field edits it (arrow
/// keys step each part, and it is a date field to accessibility), without its
/// bezel: the Pi pill around it is its frame. Caption type in body ink.
struct PiDateField: NSViewRepresentable {
    @Binding var date: Date
    var elements: NSDatePicker.ElementFlags = [.yearMonthDay, .hourMinute]
    func makeCoordinator() -> Coordinator { Coordinator(date: $date) }
    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textField
        picker.isBezeled = false; picker.isBordered = false; picker.drawsBackground = false
        picker.controlSize = .small
        picker.font = .systemFont(ofSize: PiFont.captionSize); picker.textColor = .piInk
        picker.datePickerElements = elements
        picker.target = context.coordinator; picker.action = #selector(Coordinator.changed(_:))
        picker.dateValue = date
        return picker
    }
    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.date = $date
        let environment = context.environment
        if picker.calendar != environment.calendar { picker.calendar = environment.calendar }
        if picker.locale != environment.locale { picker.locale = environment.locale }
        if picker.timeZone != environment.timeZone { picker.timeZone = environment.timeZone }
        if picker.isEnabled != environment.isEnabled { picker.isEnabled = environment.isEnabled }
        if picker.datePickerElements != elements { picker.datePickerElements = elements }
        // Only when it differs: the reader's own edit, already in the
        // binding, is not set again under them.
        if picker.dateValue != date { picker.dateValue = date }
    }
    @MainActor final class Coordinator: NSObject {
        var date: Binding<Date>
        init(date: Binding<Date>) { self.date = date }
        @objc func changed(_ sender: NSDatePicker) { if date.wrappedValue != sender.dateValue { date.wrappedValue = sender.dateValue } }
    }
}
