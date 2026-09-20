import AppKit
import SwiftUI
import XCTest
@testable import PiApp

/// The composer bar used to pick its form by laying out nine candidates —
/// three of the model/effort pills inside three of the run controls — on
/// every pass. It measures the strings once and picks now. These tests keep
/// the old candidate rows in the bundle as an oracle and insist the two
/// agree, for every pane width the narrow-pane test drives and for the label
/// sets that make the bar widest: the measured width is the width SwiftUI
/// lays out, the chosen form is the form the trial layouts would have taken,
/// and where a rung sits within the rounding allowance of the bar's edge the
/// arithmetic is the one that gives way.
final class ComposerBarLayoutTests: XCTestCase {

    /// The widths `ConversationPaneTests.testComposerBarFitsNarrowPanes`
    /// drives, plus the two halves of a split at the smallest window.
    static let widths: [CGFloat] = [1200, 900, 720, 560, 460]

    // MARK: Label sets

    struct LabelSet {
        let name: String
        let connection: String
        let model: String
        let effort: String
        let showsConnectionPill: Bool
        let loading: Bool
    }
    static func labelSets() -> [LabelSet] {
        var sets: [LabelSet] = []
        let connections = [("short", "Team", true), ("ordinary", "Team router · Responses", true),
                           ("long", "Production router · Responses · eu-west-1 failover", true),
                           ("hidden", "Only connection", false)]
        let models = [("short", "gpt-5"), ("ordinary", "ui-fixture"),
                      ("long", "anthropic/claude-opus-4-1-20250805-thinking")]
        for (connectionName, connection, shows) in connections {
            for (modelName, alias) in models {
                for level in ThinkingLevel.allCases {
                    sets.append(LabelSet(name: "\(connectionName)/\(modelName)/\(level.rawValue)",
                                         connection: connection, model: alias, effort: level.pillLabel,
                                         showsConnectionPill: shows, loading: false))
                }
            }
        }
        sets.append(LabelSet(name: "catalog loading", connection: "Team router · Responses", model: "ui-fixture",
                             effort: ThinkingLevel.profileDefault.pillLabel, showsConnectionPill: true, loading: true))
        return sets
    }
    /// The shapes the bar itself takes: what is on it besides the pills.
    static func furniture() -> [(name: String, apply: (inout ComposerBarMetrics) -> Void)] {
        [("idle", { $0.showsSteer = false; $0.hint = nil; $0.showsStop = false }),
         ("running", { $0.showsSteer = true; $0.hint = "Queue follow-up"; $0.showsStop = true }),
         ("queueing", { $0.showsSteer = false; $0.hint = "Queue follow-up"; $0.showsStop = false }),
         ("editing, busy", { $0.showsSteer = false; $0.hint = "Wait for idle to resend"; $0.showsStop = true }),
         ("editing, idle", { $0.showsSteer = false; $0.hint = "Resend from here"; $0.showsStop = false })]
    }
    @MainActor static func metrics(_ set: LabelSet, _ furniture: (inout ComposerBarMetrics) -> Void) -> ComposerBarMetrics {
        var value = ComposerBarMetrics(showsChanges: true, showsActions: true,
                                       showsConnectionPill: set.showsConnectionPill, connection: set.connection,
                                       model: set.model, effort: set.effort, modelLoading: set.loading)
        furniture(&value)
        return value
    }

    // MARK: The oracle

    /// `PillLabel` exactly as the pills draw it, so the arithmetic has
    /// something laid out by SwiftUI to be checked against.
    private struct OraclePill: View {
        let icon: String
        let text: String
        let compact: Bool
        let maxWidth: CGFloat
        let loading: Bool
        var body: some View {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                if !compact {
                    Text(text).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: maxWidth, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
                if loading { ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 10, height: 10) }
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .padding(.horizontal, compact ? 7 : 9).padding(.vertical, 4)
        }
    }
    private struct OraclePills: View {
        let set: LabelSet
        let form: ComposerPillsForm
        var body: some View {
            HStack(spacing: 4) {
                if set.showsConnectionPill {
                    OraclePill(icon: "antenna.radiowaves.left.and.right", text: set.connection,
                               compact: form.connectionIsCompact, maxWidth: 150, loading: false)
                }
                OraclePill(icon: "cpu", text: set.model, compact: form.modelIsCompact,
                           maxWidth: form.modelWidth, loading: set.loading)
                OraclePill(icon: "brain", text: set.effort, compact: form.effortIsCompact,
                           maxWidth: ModelSwitchPills.effortLabelWidth, loading: false)
            }
        }
    }
    /// The run controls exactly as the bar drew them before it measured.
    private struct OracleRunControls: View {
        let steer: Bool
        let hint: String?
        let form: ComposerRunControlsForm
        var body: some View {
            HStack(spacing: 4) {
                if steer {
                    Button {} label: {
                        if form.steerIsCompact { Image(systemName: "arrow.turn.up.right") }
                        else { Label("Steer run", systemImage: "arrow.turn.up.right") }
                    }.buttonStyle(.piGhost).fixedSize()
                }
                if form.showsHint, let hint {
                    Text(hint).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).lineLimit(1).fixedSize()
                }
            }
        }
    }

    /// What SwiftUI says a candidate wants to be. `ViewThatFits` takes the
    /// first candidate whose ideal width fits, so these widths are the whole
    /// of its decision.
    @MainActor private func idealWidth(_ view: some View) -> CGFloat {
        let hosting = NSHostingView(rootView: view.fixedSize())
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.width
    }

    // MARK: Tests

    /// The measured width of each group is the width SwiftUI lays it out at.
    /// This is the assertion a drifting font, a changed padding or a new
    /// glyph would break first.
    @MainActor func testTheMeasuredWidthsAreTheWidthsSwiftUILaysOut() throws {
        var worst = 0.0, worstName = "", checks = 0
        for set in Self.labelSets() {
            let metrics = Self.metrics(set) { $0.showsSteer = true; $0.hint = "Queue follow-up" }
            for form in ComposerPillsForm.allCases {
                let drawn = idealWidth(OraclePills(set: set, form: form))
                let measured = metrics.pillsWidth(form)
                checks += 1
                if abs(measured - drawn) > worst { worst = abs(measured - drawn); worstName = "\(set.name) pills \(form)" }
                XCTAssertEqual(measured, drawn, accuracy: ComposerBarMetrics.roundingAllowance,
                               "pills \(form) for \(set.name): measured \(measured), SwiftUI lays out \(drawn)")
            }
            for form in [ComposerRunControlsForm.labelled, .compactSteer, .steerOnly] {
                let drawn = idealWidth(OracleRunControls(steer: true, hint: "Queue follow-up", form: form))
                let measured = metrics.runControlsWidth(form)
                checks += 1
                if abs(measured - drawn) > worst { worst = abs(measured - drawn); worstName = "run controls \(form)" }
                XCTAssertEqual(measured, drawn, accuracy: ComposerBarMetrics.roundingAllowance,
                               "run controls \(form): measured \(measured), SwiftUI lays out \(drawn)")
            }
        }
        print(String(format: "PERF composer bar measurement: %d comparisons, worst disagreement %.2f pt (%@), on top of the %.0f pt safety margin",
                     checks, worst, worstName, ComposerBarMetrics.safetyMargin))
    }

    /// The form chosen by arithmetic is the form the old trial layouts would
    /// have chosen: the widest rung of the same ladder whose pieces, laid out
    /// by SwiftUI, fit the same available width.
    @MainActor func testTheChosenFormIsTheOneTheTrialLayoutsWouldHaveChosen() throws {
        var disagreements: [String] = [], checks = 0
        for set in Self.labelSets() {
            for (furnitureName, furniture) in Self.furniture() {
                let metrics = Self.metrics(set, furniture)
                for pane in Self.widths {
                    let available = ComposerBarMetrics.available(paneWidth: pane)
                    // The same ladder, but every rung's two variable groups
                    // measured by SwiftUI rather than by arithmetic.
                    let fixed = metrics.width(ComposerBarForm.narrowest)
                        - metrics.pillsWidth(.icons) - metrics.runControlsWidth(.steerOnly)
                    var oracle = ComposerBarForm.narrowest
                    for form in ComposerBarForm.ladder {
                        let drawn = fixed + idealWidth(OraclePills(set: set, form: form.pills))
                            + idealWidth(OracleRunControls(steer: metrics.showsSteer, hint: metrics.hint, form: form.runControls))
                        if drawn <= available { oracle = form; break }
                    }
                    let chosen = metrics.form(fitting: available)
                    checks += 1
                    guard chosen != oracle else { continue }
                    let rung = { (form: ComposerBarForm) in ComposerBarForm.ladder.firstIndex(of: form) ?? 0 }
                    // Arithmetic and layout can only disagree about a rung
                    // whose width is within the rounding allowance of the
                    // bar, and the arithmetic must always be the cautious one.
                    XCTAssertGreaterThan(rung(chosen), rung(oracle),
                                         "\(set.name)/\(furnitureName) at \(Int(pane))pt claimed room it has not got: \(chosen) over \(oracle)")
                    let gap = available - metrics.width(oracle)
                    XCTAssertLessThanOrEqual(gap, ComposerBarMetrics.roundingAllowance + 1,
                                             "\(set.name)/\(furnitureName) at \(Int(pane))pt gave up \(oracle) with \(Int(gap)) points to spare")
                    disagreements.append("\(set.name)/\(furnitureName) at \(Int(pane))pt: chose \(chosen), laid out \(oracle), \(String(format: "%.1f", gap)) pt from the edge")
                }
            }
        }
        print("PERF composer bar oracle: \(checks) comparisons, \(disagreements.count) rungs given up inside the rounding allowance"
              + (disagreements.isEmpty ? "" : " — " + disagreements.prefix(4).joined(separator: "; ")))
        XCTAssertLessThan(Double(disagreements.count) / Double(checks), 0.01,
                          "the arithmetic and the layout part company too often:\n" + disagreements.prefix(12).joined(separator: "\n"))
    }

    /// Whatever form is chosen has to fit the bar it is drawn in, at every
    /// width and for every label set, so nothing is ever pushed past the
    /// card's edge.
    @MainActor func testTheChosenFormAlwaysFitsTheBar() throws {
        var overflows: [String] = []
        var worstSlack = CGFloat.greatestFiniteMagnitude, tightest = ""
        for set in Self.labelSets() {
            for (furnitureName, furniture) in Self.furniture() {
                let metrics = Self.metrics(set, furniture)
                for pane in Self.widths {
                    let available = ComposerBarMetrics.available(paneWidth: pane)
                    let form = metrics.form(fitting: available)
                    let fixed = metrics.width(form) - metrics.pillsWidth(form.pills) - metrics.runControlsWidth(form.runControls)
                    let drawn = fixed + idealWidth(OraclePills(set: set, form: form.pills))
                        + idealWidth(OracleRunControls(steer: metrics.showsSteer, hint: metrics.hint, form: form.runControls))
                    // The narrowest rung has nothing left to give up; at 460
                    // points with a long connection name it is simply wider
                    // than the bar, exactly as it was before.
                    guard form != ComposerBarForm.narrowest else { continue }
                    if available - drawn < worstSlack { worstSlack = available - drawn; tightest = "\(set.name)/\(furnitureName) at \(Int(pane))pt" }
                    // The bar's real room is the available width plus the
                    // margin that was held back from it; nothing may reach
                    // past that, which is the card's edge.
                    let room = available + ComposerBarMetrics.safetyMargin
                    if drawn > room { overflows.append("\(set.name)/\(furnitureName) at \(Int(pane))pt: draws \(Int(drawn)), the card holds \(Int(room))") }
                }
            }
        }
        print(String(format: "PERF composer bar tightest fit: %.2f pt of slack (%@), on top of the %.0f pt safety margin",
                     worstSlack, tightest, ComposerBarMetrics.safetyMargin))
        XCTAssertTrue(overflows.isEmpty, "A chosen form does not fit the bar:\n" + overflows.prefix(12).joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(worstSlack, -ComposerBarMetrics.roundingAllowance,
                                    "a chosen form ate more of the safety margin than the rounding allowance")
    }

    /// The whole point: the strings are measured once, not once per pass.
    @MainActor func testTheLabelsAreMeasuredOncePerString() throws {
        PiTextWidth.forget()
        let set = Self.labelSets()[1]
        let metrics = Self.metrics(set) { $0.showsSteer = true; $0.hint = "Queue follow-up" }
        _ = metrics.form(fitting: 900)
        let afterFirst = PiTextWidth.measuredCount
        XCTAssertGreaterThan(afterFirst, 0)
        for _ in 0..<500 { _ = metrics.form(fitting: CGFloat.random(in: 200...1_600)) }
        XCTAssertEqual(PiTextWidth.measuredCount, afterFirst, "Asking again must not measure again")
        // The same bar on another pane is the same strings.
        for _ in 0..<100 { _ = Self.metrics(set) { $0.showsSteer = true; $0.hint = "Queue follow-up" }.form(fitting: 720) }
        XCTAssertEqual(PiTextWidth.measuredCount, afterFirst)
    }

    /// What the bar costs to build and lay out, the way it did and the way it
    /// does: the same controls, the same strings, the same pane width, with
    /// the form chosen by nine trial layouts and by arithmetic. One draft
    /// keystroke re-runs the bar's body, so this is what a keystroke pays.
    @MainActor func testWhatTheBarCostsToBuildAndLayOut() async throws {
        let root = URL(fileURLWithPath: scratchBase())
            .appendingPathComponent("composer-bar-cost-" + UUID().uuidString)
        let bench = try SmoothShellTests.workbench(root: root, names: ["Bar"], rows: 0)
        registerWorkspaceFixtureTeardown(bench.model, root: root)
        let model = bench.model, session = try XCTUnwrap(model.displays[bench.chats[0].id])
        model.selectedID = bench.chats[0].id; model.selected = session; model.focusedSessionID = session.id
        let pane: CGFloat = 900

        /// One pass: a keystroke's worth of change, then the layout it forces.
        @MainActor func cost(_ label: String, _ make: @escaping (Int) -> AnyView) -> Double {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: pane, height: 260),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: make(0))
            window.contentView = hosting; window.makeKeyAndOrderFront(nil)
            hosting.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let rounds = 40
            var worst = 0.0, total = 0.0
            for round in 1...rounds {
                hosting.rootView = make(round)
                let started = ProcessInfo.processInfo.systemUptime
                hosting.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1_000
                worst = max(worst, elapsed); total += elapsed
            }
            window.contentView = nil; window.close()
            print(String(format: "PERF composer bar %@: mean %.2f ms, worst %.2f ms over %d passes at %.0f points",
                         label, total / Double(rounds), worst, rounds, pane))
            return total / Double(rounds)
        }

        let before = cost("laid out nine times (as it was)") { round in
            AnyView(TrialLayoutBar(model: model, session: session, round: round).frame(width: pane))
        }
        let after = cost("measured once (as it is)") { round in
            AnyView(MeasuredBar(model: model, session: session, round: round, paneWidth: pane).frame(width: pane))
        }
        print(String(format: "PERF composer bar build and layout: %.2f ms -> %.2f ms a pass (%.0f%% of what it was)",
                     before, after, after / max(before, 0.0001) * 100))
        XCTAssertLessThan(after, before, "measuring the bar has to be cheaper than laying it out nine times")
    }

    /// What one pass of the decision costs, against what the nine trial
    /// layouts cost. Both are printed; only the ceiling is asserted.
    @MainActor func testDecidingTheFormCostsAlmostNothing() throws {
        let sets = Self.labelSets()
        PiTextWidth.forget()
        let cold = ProcessInfo.processInfo.systemUptime
        for set in sets { _ = Self.metrics(set) { $0.showsSteer = true; $0.hint = "Queue follow-up" }.form(fitting: 900) }
        let coldMilliseconds = (ProcessInfo.processInfo.systemUptime - cold) * 1_000
        let warm = ProcessInfo.processInfo.systemUptime
        let rounds = 200
        for _ in 0..<rounds {
            for set in sets { _ = Self.metrics(set) { $0.showsSteer = true; $0.hint = "Queue follow-up" }.form(fitting: 900) }
        }
        let each = (ProcessInfo.processInfo.systemUptime - warm) / Double(rounds * sets.count) * 1_000
        print(String(format: "PERF composer bar decision: %.3f ms per bar warm, %.2f ms to measure %d label sets cold",
                     each, coldMilliseconds, sets.count))
        XCTAssertLessThan(each, 0.1, "deciding the bar's form took \(each) ms")
    }
}

/// The bar's row as it was: the run controls and the pills each pick their
/// own form by laying every candidate out. Kept here, next to the test that
/// times it, so the cost of the change is measured against the real thing
/// rather than against a sketch of it.
struct TrialLayoutBar: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var session: SessionDisplay
    /// Changes every pass, so the body is rebuilt as a keystroke rebuilds it.
    let round: Int
    var body: some View {
        HStack(spacing: 4) {
            PiIconButton(symbol: "photo.badge.plus", label: "Attach Image…", size: 28, filled: true) {}
            PiIconButton(symbol: "command", label: "Skills…", size: 28, filled: true) {}
            Spacer()
            ViewThatFits(in: .horizontal) {
                TrialRunControls(compactSteer: false, showsHint: true, round: round)
                TrialRunControls(compactSteer: true, showsHint: true, round: round)
                TrialRunControls(compactSteer: true, showsHint: false, round: round)
            }
            if let chat = model.record(session.id) {
                PiIconButton(symbol: "arrow.triangle.branch", label: "Changes", size: 28, filled: true) {}
                SessionUsageButton(model: model, chat: chat, footer: session.footer)
                ConversationActionsMenu(model: model, session: session, chat: chat)
            }
            ViewThatFits(in: .horizontal) {
                ModelSwitchPills(model: model, session: session, form: .named)
                ModelSwitchPills(model: model, session: session, form: .modelOnly)
                ModelSwitchPills(model: model, session: session, form: .icons)
            }.padding(.trailing, 2)
            Circle().fill(Color.piBrandOrange).frame(width: 30, height: 30)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }
}

/// The same row as it is: one measured choice, one form built.
struct MeasuredBar: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var session: SessionDisplay
    let round: Int
    let paneWidth: CGFloat
    var body: some View {
        let pills = ModelSwitchPills.contents(model: model, session: session)
        let metrics = ComposerBarMetrics(showsChanges: true, showsActions: true,
                                         showsConnectionPill: pills.showsConnection, connection: pills.connection,
                                         model: pills.model, effort: pills.effort, modelLoading: pills.loading)
        let form = metrics.form(fitting: ComposerBarMetrics.available(paneWidth: paneWidth))
        HStack(spacing: 4) {
            PiIconButton(symbol: "photo.badge.plus", label: "Attach Image…", size: 28, filled: true) {}
            PiIconButton(symbol: "command", label: "Skills…", size: 28, filled: true) {}
            Spacer()
            TrialRunControls(compactSteer: form.runControls.steerIsCompact, showsHint: form.runControls.showsHint, round: round)
            if let chat = model.record(session.id) {
                PiIconButton(symbol: "arrow.triangle.branch", label: "Changes", size: 28, filled: true) {}
                SessionUsageButton(model: model, chat: chat, footer: session.footer)
                ConversationActionsMenu(model: model, session: session, chat: chat)
            }
            ModelSwitchPills(model: model, session: session, form: form.pills).padding(.trailing, 2)
            Circle().fill(Color.piBrandOrange).frame(width: 30, height: 30)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }
}

/// The run-control group both bars draw, with a value that changes each pass.
struct TrialRunControls: View {
    let compactSteer: Bool
    let showsHint: Bool
    let round: Int
    var body: some View {
        HStack(spacing: 4) {
            Button {} label: {
                if compactSteer { Image(systemName: "arrow.turn.up.right") }
                else { Label("Steer run", systemImage: "arrow.turn.up.right") }
            }.buttonStyle(.piGhost).fixedSize()
            if showsHint {
                Text("Queue follow-up").font(PiFont.caption).foregroundStyle(Color.piInkSecondary).lineLimit(1).fixedSize()
                    .accessibilityValue("\(round)")
            }
        }
    }
}
