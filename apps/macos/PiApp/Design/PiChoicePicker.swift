import SwiftUI

/// App-owned selection rows, shared by composer, settings and report controls.
/// Saved choices stay separate from keyboard focus: moving through the list
/// never applies a connection, model or preference before Return/click.
struct PiChoice<Tag: Hashable>: Identifiable, Equatable {
    let id: Tag
    let title: String
    var subtitle: String? = nil
    var enabled = true
}

struct PiChoicePicker<Tag: Hashable, Label: View>: View {
    let title: String
    let selection: Tag?
    let choices: [PiChoice<Tag>]
    var note: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    let choose: (Tag) -> Void
    @ViewBuilder var label: Label
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: { label }
            .buttonStyle(.plain).piPointer()
            .popover(isPresented: $showing, arrowEdge: .top) {
                PiChoiceList(title: title, selection: selection, choices: choices, note: note,
                             actionTitle: actionTitle, action: action.map { action in
                                 { showing = false; action() }
                             }, choose: { value in
                                 showing = false
                                 choose(value)
                             }, cancel: { showing = false })
            }
    }
}

struct PiChoiceList<Tag: Hashable>: View {
    let title: String
    let selection: Tag?
    let choices: [PiChoice<Tag>]
    var note: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    let choose: (Tag) -> Void
    let cancel: () -> Void
    @State private var highlightedChoice: Tag?
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                .padding(.horizontal, 8).padding(.top, 4)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if choices.isEmpty {
                            Text("No available choices").font(PiFont.body).foregroundStyle(Color.piInkTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                        ForEach(choices) { choice in
                            Button { commit(choice.id) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: choice.id == selection ? "checkmark" : "circle")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(choice.id == selection ? Color.piAccent : Color.clear)
                                        .frame(width: 14)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(choice.title).font(PiFont.body).fixedSize(horizontal: false, vertical: true)
                                        if let subtitle = choice.subtitle {
                                            Text(subtitle).font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .foregroundStyle(choice.enabled ? Color.piInk : Color.piInkTertiary)
                                .padding(.horizontal, 8).padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(RoundedRectangle(cornerRadius: PiRadius.sm))
                            }
                            .buttonStyle(PiChoiceRowStyle(selected: choice.id == selection, focused: choice.id == highlightedChoice && listFocused))
                            .focusable(false)
                            .disabled(!choice.enabled)
                            .accessibilityAddTraits(choice.id == selection ? .isSelected : [])
                            .id(choice.id)
                        }
                    }
                }
                .frame(height: min(360, max(40, CGFloat(choices.count) * 40 + CGFloat(choices.filter { $0.subtitle != nil }.count) * 18)))
                // One keyboard focus target owns navigation. Per-row focus
                // registrations race initial presentation and can replace the
                // saved target; default-focus priority can then undo arrows.
                .focusable().focusEffectDisabled().focused($listFocused)
                .onKeyPress(.upArrow) {
                    highlightedChoice = Self.nextChoice(choices, after: highlightedChoice, delta: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    highlightedChoice = Self.nextChoice(choices, after: highlightedChoice, delta: 1)
                    return .handled
                }
                .onKeyPress(.return) {
                    // SwiftUI runs key handlers inside its update of the list:
                    // saving the choice from here published the caller's model
                    // during that update. The choice is saved on the next turn.
                    if let highlightedChoice { DispatchQueue.main.async { commit(highlightedChoice) } }
                    return .handled
                }
                .onChange(of: highlightedChoice) { _, value in
                    if let value { proxy.scrollTo(value) }
                }
                .onChange(of: choices) { _, values in
                    if !values.contains(where: { $0.id == highlightedChoice && $0.enabled }) {
                        highlightedChoice = Self.initialChoice(values, selection: selection)
                    }
                }
                .onAppear {
                    highlightedChoice = Self.initialChoice(choices, selection: selection)
                    listFocused = true
                }
            }
            if let note {
                Text(note).font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 8)
            }
            if let actionTitle, let action {
                Divider().overlay(Color.piHairline)
                Button(action: action) {
                    Text(actionTitle).font(PiFont.body).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(Color.piAccent).piPointer()
            }
        }
        .padding(8).frame(width: 310).background(Color.piSurface)
        .onExitCommand(perform: cancel)
        .accessibilityIdentifier("pi-choice-list")
    }

    private func commit(_ id: Tag) {
        guard choices.contains(where: { $0.id == id && $0.enabled }) else { return }
        choose(id)
    }

    static func initialChoice(_ choices: [PiChoice<Tag>], selection: Tag?) -> Tag? {
        choices.first { $0.id == selection && $0.enabled }?.id ?? choices.first { $0.enabled }?.id
    }

    static func nextChoice(_ choices: [PiChoice<Tag>], after current: Tag?, delta: Int) -> Tag? {
        let enabled = choices.filter(\.enabled).map(\.id)
        guard !enabled.isEmpty else { return nil }
        guard let index = enabled.firstIndex(where: { $0 == current }) else { return delta < 0 ? enabled.last : enabled.first }
        return enabled[min(enabled.count - 1, max(0, index + delta))]
    }
}

private struct PiChoiceRowStyle: ButtonStyle {
    let selected: Bool
    let focused: Bool
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(selected ? Color.piAccentSoft : (focused || hovering || configuration.isPressed) ? Color.piSurfaceSunken : Color.clear,
                        in: RoundedRectangle(cornerRadius: PiRadius.sm))
            .overlay(RoundedRectangle(cornerRadius: PiRadius.sm).stroke(focused ? Color.piAccent.opacity(0.45) : Color.clear, lineWidth: 1))
            .onHover { hovering = $0 }
    }
}
