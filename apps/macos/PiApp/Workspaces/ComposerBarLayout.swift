import AppKit
import SwiftUI

/// How much of itself the pill group shows, in the order the trial layouts
/// used to try: everything, then the connection and effort as icons with the
/// model's name kept short, then the model's name given up too. The model
/// being talked to is the last label to go.
enum ComposerPillsForm: Equatable, CaseIterable {
    case named
    case modelOnly
    case icons

    var connectionIsCompact: Bool { self != .named }
    var effortIsCompact: Bool { self != .named }
    var modelIsCompact: Bool { self == .icons }
    /// What `PillLabel` is told to cap the model alias at.
    var modelWidth: CGFloat {
        switch self {
        case .named: return 170
        case .modelOnly: return 110
        case .icons: return 0
        }
    }
}

/// How much of itself the run-control group shows, in the order the trial
/// layouts used to try: the steering button with its words and the send hint,
/// then the button as an icon, then without the hint. The bar gives up its
/// words rather than wrapping them down the middle.
enum ComposerRunControlsForm: Equatable {
    case labelled
    case compactSteer
    case steerOnly

    var steerIsCompact: Bool { self != .labelled }
    var showsHint: Bool { self != .steerOnly }
}

/// One form of the whole bar. The two groups used to choose independently,
/// each from its own `ViewThatFits`, which is why nine layouts were run for
/// one row; they are one ordered ladder now, widest first, and exactly one
/// rung is ever built.
struct ComposerBarForm: Equatable {
    var runControls: ComposerRunControlsForm
    var pills: ComposerPillsForm

    /// Widest first. Detail goes in the order the reader can most afford to
    /// lose it: the steering button's word, then the connection and effort
    /// names, then the send hint, then the model's name.
    static let ladder: [ComposerBarForm] = [
        ComposerBarForm(runControls: .labelled, pills: .named),
        ComposerBarForm(runControls: .compactSteer, pills: .named),
        ComposerBarForm(runControls: .compactSteer, pills: .modelOnly),
        ComposerBarForm(runControls: .steerOnly, pills: .modelOnly),
        ComposerBarForm(runControls: .steerOnly, pills: .icons)
    ]
    static let narrowest = ladder[ladder.count - 1]
}

/// What the composer bar is made of and how wide each piece is, so the widest
/// form that fits can be chosen without laying any of them out.
struct ComposerBarMetrics: Equatable {
    // MARK: The bar's fixed furniture

    /// `HStack(spacing: 4)` between every control on the bar.
    static let spacing: CGFloat = 4
    /// A `PiIconButton(size: 28)`: attach, skills, changes, session info, actions.
    static let iconButton: CGFloat = 28
    /// Send, and Stop beside it while a run is in flight.
    static let roundButton: CGFloat = 30
    /// `.padding(.horizontal, 10)` on the bar row.
    static let barPadding: CGFloat = 20
    /// `.padding(.horizontal, PiSpacing.lg)` on the composer card.
    static let cardPadding: CGFloat = PiSpacing.lg * 2
    /// `ModelSwitchPills(...).padding(.trailing, 2)`.
    static let pillsTrailing: CGFloat = 2
    /// Enough that a rounding difference between measurement and layout cannot
    /// push the send button past the card's edge.
    static let safetyMargin: CGFloat = 8
    /// Arithmetic over a dozen strings and glyphs lands within about two
    /// points of what SwiftUI then lays out. A rung has to clear the bar by
    /// that much before it is taken, so the difference is always spent on
    /// showing slightly less rather than on a control over the edge.
    static let roundingAllowance: CGFloat = 2

    // MARK: What this bar is showing

    /// The steering button, shown only while a run is in flight and nothing is
    /// being re-sent.
    var showsSteer = false
    /// The line beside it: "Queue follow-up", or what re-sending will do.
    var hint: String?
    /// The project's Changes button, and the chat's "…" menu.
    var showsChanges = false
    var showsActions = false
    /// Session info is always on the bar; Stop joins Send while busy.
    var showsStop = false
    /// The connection pill appears once there is more than one connection.
    var showsConnectionPill = false
    var connection = ""
    var model = ""
    var effort = ""
    /// The model pill shows a spinner while its catalog loads.
    var modelLoading = false

    // MARK: Widths

    /// What the bar itself has, from the width of the pane it sits in.
    static func available(paneWidth: CGFloat) -> CGFloat {
        guard paneWidth.isFinite else { return .infinity }
        return max(0, paneWidth - cardPadding - barPadding - safetyMargin)
    }

    /// One pill: `PillLabel`'s icon, its optional name capped at `maxText`,
    /// its optional spinner and its chevron, inside `HStack(spacing: 5)` and
    /// the capsule's own horizontal padding.
    @MainActor static func pillWidth(icon: String, text: String?, maxText: CGFloat, loading: Bool) -> CGFloat {
        let compact = text == nil
        var pieces: [CGFloat] = [PiTextWidth.symbol(icon, size: 11, weight: .semibold)]
        if let text, maxText > 0 {
            pieces.append(min(PiTextWidth.text(text, size: 12, weight: .medium), maxText))
        }
        if loading { pieces.append(10) }
        pieces.append(PiTextWidth.symbol("chevron.up.chevron.down", size: 9, weight: .semibold))
        let padding: CGFloat = (compact ? 7 : 9) * 2
        return padding + pieces.reduce(0, +) + CGFloat(pieces.count - 1) * 5
    }

    @MainActor func pillsWidth(_ form: ComposerPillsForm) -> CGFloat {
        var widths: [CGFloat] = []
        if showsConnectionPill {
            widths.append(Self.pillWidth(icon: "antenna.radiowaves.left.and.right",
                                         text: form.connectionIsCompact ? nil : connection, maxText: 150, loading: false))
        }
        widths.append(Self.pillWidth(icon: "cpu", text: form.modelIsCompact ? nil : model,
                                     maxText: form.modelWidth, loading: modelLoading))
        widths.append(Self.pillWidth(icon: "brain", text: form.effortIsCompact ? nil : effort,
                                     maxText: ModelSwitchPills.effortLabelWidth, loading: false))
        return widths.reduce(0, +) + CGFloat(widths.count - 1) * Self.spacing
    }

    /// `PiGhostButtonStyle`: 10 points of padding on each side of a 12.5 point
    /// medium label. A `Label` sets its icon and title this far apart, which
    /// SwiftUI does not publish; `ComposerBarLayoutTests` measures the button
    /// SwiftUI actually lays out and fails if this drifts from it.
    static let ghostPadding: CGFloat = 20
    static let labelSpacing: CGFloat = 9
    @MainActor func runControlsWidth(_ form: ComposerRunControlsForm) -> CGFloat {
        var widths: [CGFloat] = []
        if showsSteer {
            let glyph = PiTextWidth.symbol("arrow.turn.up.right", size: 12.5, weight: .medium)
            let word = form.steerIsCompact ? 0 : PiTextWidth.text("Steer run", size: 12.5, weight: .medium) + Self.labelSpacing
            widths.append(Self.ghostPadding + glyph + word)
        }
        if form.showsHint, let hint, !hint.isEmpty {
            widths.append(PiTextWidth.text(hint, size: PiFont.captionSize, weight: .regular))
        }
        guard !widths.isEmpty else { return 0 }
        return widths.reduce(0, +) + CGFloat(widths.count - 1) * Self.spacing
    }

    /// Everything on the bar in this form, gaps included.
    @MainActor func width(_ form: ComposerBarForm) -> CGFloat {
        // Attach, skills, session info, send: always there. Changes, the "…"
        // menu and Stop come and go; the spacer between the left pair and the
        // rest can go to nothing but still takes a gap on each side.
        var pieces: [CGFloat] = [Self.iconButton, Self.iconButton, 0]
        let controls = runControlsWidth(form.runControls)
        pieces.append(controls)
        if showsChanges { pieces.append(Self.iconButton) }
        pieces.append(Self.iconButton)
        if showsActions { pieces.append(Self.iconButton) }
        pieces.append(pillsWidth(form.pills) + Self.pillsTrailing)
        pieces.append(Self.roundButton)
        if showsStop { pieces.append(Self.roundButton) }
        return pieces.reduce(0, +) + CGFloat(pieces.count - 1) * Self.spacing
    }

    /// The widest rung of the ladder that fits, measured rather than tried.
    @MainActor func form(fitting available: CGFloat) -> ComposerBarForm {
        guard available.isFinite else { return ComposerBarForm.ladder[0] }
        for form in ComposerBarForm.ladder where width(form) + Self.roundingAllowance <= available { return form }
        return ComposerBarForm.narrowest
    }
}
