import AppKit
import SwiftUI
import XCTest
@testable import PiApp

/// Each AppKit Pi component (DesignKit/) drawn next to its SwiftUI twin in
/// every state that can be shown without changing the twin: at rest, under
/// the pointer, disabled, selected or on, light and dark. They must match
/// pixel for pixel, apart from antialiasing (`PiKitParity`).
///
/// Serial: the windows are on screen and the hover cases move the pointer.
@MainActor final class PiKitParityTests: XCTestCase, SerialTestLane {
    /// No pixel of a capture without symbols may differ past the channel
    /// tolerance: the pictures are the same.
    static let allowedShare = 0.0
    /// A circle or curve drawn as a path (a badge's dot, a legend swatch, a
    /// stacked bar's rounded ends): its edge antialiased a fraction of a
    /// pixel apart, never more than this many channels.
    static let shapeShare = 0.006
    static let largestChannel = 48
    private var results: [PiKitParity.Result] = []

    override func setUp() async throws { PiKit.Motion.reducedOverride = true }
    override func tearDown() async throws {
        PiKit.Motion.reducedOverride = nil
        for result in results { print("PARITY " + result.description) }
    }

    private func check<V: View>(_ name: String, hover: Bool = false, canvas: NSColor = .piContent, width: CGFloat? = nil,
                                share: Double = PiKitParityTests.allowedShare,
                                _ swiftUI: @autoclosure () -> V, _ appKit: () -> NSView,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let result = try await PiKitParity.compare("\(name)-\(suffix)", appearance: appearance, hover: hover,
                                                       swiftUI: swiftUI().frame(width: width), appKit: appKit(), canvas: canvas, width: width)
            results.append(result)
            // A hosting controller reports SwiftUI's size rounded, not always
            // up: within a point. Where everything is drawn is the pixels' to say.
            XCTAssertEqual(result.swiftUIFit.width, result.appKitFit.width.rounded(.up), accuracy: 1.01, "\(result.name) width", file: file, line: line)
            XCTAssertEqual(result.swiftUIFit.height, result.appKitFit.height.rounded(.up), accuracy: 1.01, "\(result.name) height", file: file, line: line)
            XCTAssertLessThanOrEqual(Double(result.differing), Double(result.total) * share, result.description, file: file, line: line)
            // Without symbols the pictures are the same: no pixel further
            // apart than antialiasing of the same edge.
            if share != Self.symbolShare {
                XCTAssertLessThanOrEqual(result.largest, Self.largestChannel, result.description, file: file, line: line)
            }
            if hover {
                // The pointer reached both: each looks different from itself at rest.
                let rest = try await PiKitParity.compare("\(name)-\(suffix)-rest", appearance: appearance, hover: false,
                                                         swiftUI: swiftUI().frame(width: width), appKit: appKit(), canvas: canvas, width: width)
                XCTAssertGreaterThan(PiKitParity.difference(rest.swiftUIImage, result.swiftUIImage, tolerance: 0).0, 0, "\(result.name): SwiftUI shows no hover", file: file, line: line)
                XCTAssertGreaterThan(PiKitParity.difference(rest.appKitImage, result.appKitImage, tolerance: 0).0, 0, "\(result.name): AppKit shows no hover", file: file, line: line)
            }
        }
    }

    /// Symbols: placed as SwiftUI places them, rasterized by AppKit, whose
    /// antialiasing of a symbol's edges differs from SwiftUI's own.
    static let symbolShare = 0.03

    // MARK: Buttons

    func testPillButtons() async throws {
        let styles: [(String, PiKit.Button.Style, AnyView)] = [
            ("primary", .primary, AnyView(SwiftUI.Button("Save Changes") {}.buttonStyle(.piPrimary))),
            ("secondary", .secondary, AnyView(SwiftUI.Button("Reload") {}.buttonStyle(.piSecondary))),
            ("ghost", .ghost, AnyView(SwiftUI.Button("Show more") {}.buttonStyle(.piGhost))),
            ("ghostDanger", .ghostDanger, AnyView(SwiftUI.Button("Remove…") {}.buttonStyle(.piGhostDanger))),
            ("danger", .danger, AnyView(SwiftUI.Button("Delete") {}.buttonStyle(.piDanger))),
        ]
        let titles = ["primary": "Save Changes", "secondary": "Reload", "ghost": "Show more", "ghostDanger": "Remove…", "danger": "Delete"]
        for (name, style, view) in styles {
            try await check("button-\(name)", view) { PiKit.Button(titles[name]!, style: style) }
            try await check("button-\(name)-disabled", view.disabled(true)) { let button = PiKit.Button(titles[name]!, style: style); button.isEnabled = false; return button }
        }
        try await check("button-primary-compact", SwiftUI.Button("Send") {}.buttonStyle(.piPrimaryCompact)) { PiKit.Button("Send", style: .primary, compact: true) }
        try await check("button-secondary-compact", SwiftUI.Button("Copy") {}.buttonStyle(.piSecondaryCompact)) { PiKit.Button("Copy", style: .secondary, compact: true) }
        try await check("button-secondary-symbol", share: Self.symbolShare, SwiftUI.Button {} label: { Label("Previous", systemImage: "chevron.left") }.buttonStyle(.piSecondaryCompact)) {
            PiKit.Button("Previous", symbol: "chevron.left", style: .secondary, compact: true)
        }
    }

    func testIconButtons() async throws {
        let share = Self.symbolShare
        try await check("icon", share: share, PiIconButton(symbol: "xmark", label: "Close") {}) { PiKit.IconButton(symbol: "xmark", label: "Close") }
        try await check("icon-filled", share: share, PiIconButton(symbol: "plus", label: "Increase", size: 24, filled: true) {}) { PiKit.IconButton(symbol: "plus", label: "Increase", size: 24, filled: true) }
        try await check("icon-tone", share: share, PiIconButton(symbol: "trash", label: "Delete", tone: .danger) {}) { PiKit.IconButton(symbol: "trash", label: "Delete", tone: .danger) }
        try await check("icon-disabled", share: share, PiIconButton(symbol: "minus", label: "Decrease", size: 24, filled: true) {}.disabled(true)) {
            let button = PiKit.IconButton(symbol: "minus", label: "Decrease", size: 24, filled: true); button.isEnabled = false; return button
        }
    }

    // MARK: Controls

    func testSwitchesAndCheckboxes() async throws {
        for (name, on) in [("on", true), ("off", false)] {
            try await check("switch-\(name)", Toggle("Show tokens", isOn: .constant(on)).toggleStyle(.piSwitch).foregroundStyle(Color.piInk)) {
                PiKit.Switch(isOn: on, label: "Show tokens")
            }
            try await check("switch-small-\(name)", Toggle("", isOn: .constant(on)).toggleStyle(.piSwitch).controlSize(.small)) {
                PiKit.Switch(isOn: on, size: .small)
            }
            try await check("checkbox-\(name)", share: Self.symbolShare, Toggle("Include untracked", isOn: .constant(on)).toggleStyle(.piCheckbox).foregroundStyle(Color.piInk)) {
                PiKit.Checkbox(isOn: on, label: "Include untracked")
            }
        }
        try await check("switch-disabled", Toggle("Locked", isOn: .constant(true)).toggleStyle(.piSwitch).foregroundStyle(Color.piInk).disabled(true)) {
            let toggle = PiKit.Switch(isOn: true, label: "Locked"); toggle.isEnabled = false; return toggle
        }
    }

    func testProgressTabsAndStepper() async throws {
        try await check("progress", width: 160, PiProgressBar(value: 0.3, total: 1)) { PiKit.ProgressBar(value: 0.3) }
        try await check("tabs", PiTabs(selection: .constant(2), items: [(1, "Working tree"), (2, "History"), (3, "Stashes")])) {
            PiKit.Tabs(selection: 2, items: [(1, "Working tree"), (2, "History"), (3, "Stashes")])
        }
        try await check("stepper", width: 260, share: Self.symbolShare,
                        PiStepper(name: "Idle helper grace", unit: "seconds", value: .constant(30), range: 10...600, step: 10)) {
            PiKit.Stepper(name: "Idle helper grace", unit: "seconds", value: 30, range: 10...600, step: 10)
        }
        try await check("stepper-bound", width: 260, share: Self.symbolShare,
                        PiStepper(name: "Days", unit: "days", value: .constant(1), range: 1...30)) {
            PiKit.Stepper(name: "Days", unit: "days", value: 1, range: 1...30)
        }
    }

    // MARK: Fields, choices and rows

    func testFields() async throws {
        try await check("textfield-icon", width: 240, share: Self.symbolShare, PiTextField(placeholder: "Search", text: .constant(""), icon: "magnifyingglass")) {
            PiKit.TextField(placeholder: "Search", icon: "magnifyingglass")
        }
        try await check("textfield-text", width: 240, PiTextField(placeholder: "Name", text: .constant("Bello Agent"))) {
            PiKit.TextField(placeholder: "Name", text: "Bello Agent")
        }
        try await check("textfield-mono", width: 240, PiTextField(placeholder: "Key", text: .constant("sk-test"), mono: true)) {
            PiKit.TextField(placeholder: "Key", text: "sk-test", mono: true)
        }
        try await check("numberfield", PiNumberField(placeholder: "From", value: .constant(42), width: 110)) {
            PiKit.NumberField(placeholder: "From", value: 42, width: 110)
        }
    }

    func testDropdownsAndMenus() async throws {
        let share = Self.symbolShare
        try await check("dropdown-compact", share: share, PiDropdown(selection: .constant("PUT"), items: [("POST", "POST"), ("PUT", "PUT")], compact: true)) {
            PiKit.Dropdown(selection: "PUT", items: [("POST", "POST"), ("PUT", "PUT")], compact: true)
        }
        try await check("dropdown-icon", share: share, PiDropdown(selection: .constant(1), items: [(1, "Claude Opus"), (2, "GPT")], icon: "cpu")) {
            PiKit.Dropdown(selection: 1, items: [(1, "Claude Opus"), (2, "GPT")], icon: "cpu")
        }
        try await check("dropdown-cut", share: share, PiDropdown(selection: .constant(1), items: [(1, "A very long connection name that is cut")], maxLabelWidth: 120)) {
            PiKit.Dropdown(selection: 1, items: [(1, "A very long connection name that is cut")], maxLabelWidth: 120)
        }
        try await check("menubutton", share: share, PiMenuButton(title: "main", icon: "arrow.triangle.branch") { PiMenuEntry.button("Other") {} }) {
            PiKit.MenuButton(title: "main", icon: "arrow.triangle.branch") { PiMenuEntry.button("Other") {} }
        }
    }

    func testRowsAndGroups() async throws {
        func label(_ text: String) -> NSView { PiKit.TextLine(PiKit.Line(text, font: PiKit.Font.body, color: .piInk)) }
        for (name, selected, marked) in [("selected", true, false), ("plain", false, false), ("marked", false, true)] {
            try await check("row-\(name)", width: 240,
                            PiSelectableRow(selected: selected, marked: marked, action: {}) { Text("claude").font(PiFont.body).foregroundStyle(Color.piInk) }) {
                PiKit.SelectableRow(content: label("claude"), selected: selected, marked: marked)
            }
        }
        try await check("settings-group", width: 520, share: Self.symbolShare,
                        PiSettingsGroup(title: "Updates", footer: "Checks belloware.com once a day.") {
                            PiRow(label: "Check automatically", detail: "Daily") { Toggle("", isOn: .constant(true)).toggleStyle(.piSwitch) }
                            PiRow(label: "Idle helper grace", last: true) { PiStepper(name: "Idle helper grace", unit: "seconds", value: .constant(30), range: 10...600, step: 10) }
                        }) {
            PiKit.SettingsGroup(title: "Updates", footer: "Checks belloware.com once a day.", rows: [
                PiKit.Row(label: "Check automatically", detail: "Daily", control: PiKit.Switch(isOn: true)),
                PiKit.Row(label: "Idle helper grace", last: true, control: PiKit.Stepper(name: "Idle helper grace", unit: "seconds", value: 30, range: 10...600, step: 10)),
            ])
        }
        try await check("pager", share: Self.symbolShare,
                        PiPager(previous: {}, next: {}, canPrevious: false, canNext: true) { Text("Page 2 of 5") }.fixedSize()) {
            PiKit.Pager(center: PiKit.TextLine(PiKit.Line("Page 2 of 5", font: PiKit.Font.caption, color: .piInkSecondary)), canPrevious: false, canNext: true, previous: {}, next: {})
        }
    }

    // MARK: Display pieces

    func testBadgesAndChips() async throws {
        let share = Self.symbolShare
        try await check("badge", PiBadge(text: "Draft")) { PiKit.Badge(text: "Draft") }
        try await check("badge-dot", share: Self.shapeShare, PiBadge(text: "Running", tone: .success, dot: true)) { PiKit.Badge(text: "Running", tone: .success, dot: true) }
        try await check("badge-icon", share: share, PiBadge(text: "Pinned", tone: .accent, icon: "pin.fill")) { PiKit.Badge(text: "Pinned", tone: .accent, icon: "pin.fill") }
        try await check("badge-empty", share: Self.shapeShare, PiBadge(text: "", tone: .warning, dot: true)) { PiKit.Badge(text: "", tone: .warning, dot: true) }
        try await check("iconbadge", share: share, PiIconBadge(symbol: "gearshape", tone: .info)) { PiKit.IconBadge(symbol: "gearshape", tone: .info) }
        try await check("iconbadge-filled", share: share, PiIconBadge(symbol: "bolt.fill", size: 30, filled: true)) { PiKit.IconBadge(symbol: "bolt.fill", size: 30, filled: true) }
        try await check("chip", share: share, PiChip(text: "README.md", icon: "doc.text", remove: {})) { PiKit.Chip(text: "README.md", icon: "doc.text", remove: {}) }
    }

    func testSurfacesAndText() async throws {
        let text = { (value: String) in PiKit.TextLine(PiKit.Line(value, font: PiKit.Font.body, color: .piInk)) }
        try await check("card", width: 260, PiCard { Text("Inside a card").font(PiFont.body).foregroundStyle(Color.piInk) }) { PiKit.card(text("Inside a card")) }
        try await check("card-sunken", width: 260, PiCard(padding: 12, sunken: true) { Text("Sunken").font(PiFont.body).foregroundStyle(Color.piInk) }) { PiKit.card(text("Sunken"), padding: 12, sunken: true) }
        try await check("note", width: 260, share: Self.symbolShare, PiNote("The helper restarted after an update; earlier output is kept in the journal.")) {
            PiKit.Note("The helper restarted after an update; earlier output is kept in the journal.")
        }
        try await check("note-danger", share: Self.symbolShare, PiNote("Could not save.", tone: .danger)) { PiKit.Note("Could not save.", tone: .danger) }
        try await check("keyvalue", width: 320, PiKeyValue(key: "Model", value: "claude-opus-5-5")) { PiKit.KeyValue(key: "Model", value: "claude-opus-5-5") }
        try await check("section", width: 320, PiSectionHeader("Connections", subtitle: "Where requests go")) { PiKit.SectionHeader("Connections", subtitle: "Where requests go") }
        try await check("stattile", width: 160, share: Self.symbolShare, PiStatTile(title: "Requests", value: "1,284", caption: "Last 7 days", symbol: "arrow.up.arrow.down")) {
            PiKit.statTile(title: "Requests", value: "1,284", caption: "Last 7 days", symbol: "arrow.up.arrow.down")
        }
    }

    func testGaugesAndCharts() async throws {
        try await check("sharebar", width: 120, UsageShareBar(fraction: 0.35).frame(height: 6)) { let bar = PiKit.ShareBar(fraction: 0.35); bar.setFrameSize(NSSize(width: 120, height: 6)); return Fixed(bar, CGSize(width: 120, height: 6)) }
        try await check("ring", PiRing(fraction: 0.62, size: 14)) { PiKit.Ring(fraction: 0.62, size: 14) }
        try await check("contextring", ContextRing(fraction: 0.86, size: 14)) { PiKit.Ring.context(0.86, size: 14) }
        try await check("statpill", share: Self.symbolShare, PiStatPillFace(symbol: "chart.pie", label: "7.3K tok · $0.005")) { PiKit.StatPill(symbol: "chart.pie", label: "7.3K tok · $0.005") }
        try await check("statpill-warning", share: Self.symbolShare, PiStatPillFace(symbol: "dollarsign.circle", label: "$4.10", warningTail: "92%")) {
            PiKit.StatPill(symbol: "dollarsign.circle", label: "$4.10", warningTail: "92%")
        }
        try await check("figure", width: 160, PiFigure(value: "$12.40", title: "Spend", caption: "3/5 requests reported", partial: true)) {
            PiKit.Figure(value: "$12.40", title: "Spend", caption: "3/5 requests reported", partial: true)
        }
        try await check("chartheader", width: 300, PiChartHeader("Tokens per turn", subtitle: "Last 40 turns")) { PiKit.ChartHeader("Tokens per turn", subtitle: "Last 40 turns") }
        let segments = [PiBarSegment(id: "a", fraction: 0.6), PiBarSegment(id: "b", fraction: 0.3), PiBarSegment(id: "c", fraction: 0.005)]
        try await check("segmented", width: 240, share: Self.shapeShare, PiSegmentedBar(segments: segments, color: { $0 == "a" ? .piAccent : $0 == "b" ? .piInfo : .piSuccess })) {
            PiKit.SegmentedBar(segments: segments.map { PiKit.BarSegment(id: $0.id, fraction: $0.fraction) }, color: { $0 == "a" ? .piAccent : $0 == "b" ? .piInfo : .piSuccess })
        }
        try await check("legend", width: 300, share: Self.shapeShare, PiLegendRow(color: .piAccent, title: "Output", value: "12,400", share: "41%", detail: "reasoning 3,100")) {
            PiKit.LegendRow(color: .piAccent, title: "Output", value: "12,400", share: "41%", detail: "reasoning 3,100")
        }
    }

    func testIndicatorsAndSheet() async throws {
        try await check("backtobottom", share: Self.symbolShare, PiBackToBottomPill {}) { PiKit.BackToBottomPill {} }
        try await check("shimmer-still", PiShimmerText(text: "Generating response…")) { PiKit.ShimmerText("Generating response…") }
        try await check("sheet", share: Self.symbolShare,
                        PiSheet("Connections", subtitle: "Where requests go", symbol: "network", width: 480, height: 200) { Color.clear } footer: { Text("Footer").font(PiFont.caption) }) {
            let sheet = PiKit.Sheet("Connections", subtitle: "Where requests go", symbol: "network", content: NSView(), footer: PiKit.TextLine(PiKit.Line("Footer", font: PiKit.Font.caption, color: .piInk)))
            sheet.width = 480; sheet.height = 200
            return sheet
        }
    }

    // MARK: Lists and flow

    func testChoiceListAndFlow() async throws {
        let choices = [PiChoice(id: 1, title: "Claude Opus"), PiChoice(id: 2, title: "GPT", subtitle: "Needs a key"), PiChoice(id: 3, title: "Local", enabled: false)]
        try await check("choicelist", share: Self.symbolShare,
                        PiChoiceList(title: "Model", selection: 2, choices: choices, note: "Changes apply to the next turn.", actionTitle: "Manage connections…", action: {}, choose: { _ in }, cancel: {})) {
            PiKit.ChoiceList(title: "Model", selection: 2, choices: choices.map { PiKit.Choice(id: $0.id, title: $0.title, subtitle: $0.subtitle, enabled: $0.enabled) },
                             note: "Changes apply to the next turn.", actionTitle: "Manage connections…", action: {}, choose: { _ in }, cancel: {})
        }
        try await check("flow", width: 200, share: Self.shapeShare,
                        PiFlow { PiBadge(text: "Working tree"); PiBadge(text: "History", tone: .accent); PiBadge(text: "Stashes", dot: true); PiBadge(text: "Remote branches") }) {
            let flow = PiKit.FlowView()
            for badge in [PiKit.Badge(text: "Working tree"), PiKit.Badge(text: "History", tone: .accent), PiKit.Badge(text: "Stashes", dot: true), PiKit.Badge(text: "Remote branches")] { flow.addSubview(badge) }
            return flow
        }
    }

    // MARK: Parity gaps closed in 0.1.120 (kitfix)

    /// The ink's centre (x, y), in pixels, of a capture: every pixel weighted
    /// by how far it is from the canvas's colour.
    static func inkCentre(_ image: NSBitmapImageRep) -> CGPoint {
        var pixel = [Int](repeating: 0, count: 4), canvas = [Int](repeating: 0, count: 4)
        image.getPixel(&canvas, atX: 0, y: 0)
        var x = 0.0, y = 0.0, total = 0.0
        for row in 0..<image.pixelsHigh {
            for column in 0..<image.pixelsWide {
                image.getPixel(&pixel, atX: column, y: row)
                let weight = Double((0..<3).map { abs(pixel[$0] - canvas[$0]) }.max() ?? 0)
                guard weight > 4 else { continue }
                x += Double(column) * weight; y += Double(row) * weight; total += weight
            }
        }
        return total == 0 ? .zero : CGPoint(x: x / total, y: y / total)
    }

    /// A symbol sits where SwiftUI puts it: its ink's centre within a
    /// quarter point (half a pixel) of SwiftUI's, across and down, at every
    /// icon-button size (they sat up to half a point low).
    func testSymbolsSitWhereSwiftUIPutsThem() async throws {
        for name in ["xmark", "plus", "trash", "info.circle", "chevron.left", "gearshape"] {
            for size in [20, 24, 26, 28] as [CGFloat] {
                let result = try await PiKitParity.compare("symbol-\(name)-\(Int(size))", swiftUI: PiIconButton(symbol: name, label: "x", size: size) {},
                                                           appKit: PiKit.IconButton(symbol: name, label: "x", size: size))
                let swiftUI = Self.inkCentre(result.swiftUIImage), appKit = Self.inkCentre(result.appKitImage)
                print(String(format: "PARITY symbol %@ %.0f: ink centre off by %.2f, %.2f px", name, size, appKit.x - swiftUI.x, appKit.y - swiftUI.y))
                XCTAssertEqual(appKit.y, swiftUI.y, accuracy: 0.5, "\(name) at \(size): down")
                XCTAssertEqual(appKit.x, swiftUI.x, accuracy: 0.5, "\(name) at \(size): across")
            }
        }
    }

    /// A long label is offered half the row, as `PiRow`'s `HStack` offers
    /// it, not all the control leaves.
    func testALongRowLabelWrapsWhereSwiftUIWrapsIt() async throws {
        let label = "Keep finished helper processes running for a while so the next chat in this project starts at once"
        try await check("row-long-label", width: 520, PiRow(label: label, detail: "Applies to every project", last: true) { Toggle("", isOn: .constant(true)).toggleStyle(.piSwitch) }) {
            PiKit.Row(label: label, detail: "Applies to every project", last: true, control: PiKit.Switch(isOn: true))
        }
        let medium = "Keep finished helper processes running for a while"
        try await check("row-medium-label", width: 520, PiRow(label: medium, last: true) { Toggle("", isOn: .constant(true)).toggleStyle(.piSwitch) }) {
            PiKit.Row(label: medium, last: true, control: PiKit.Switch(isOn: true))
        }
        try await check("row-long-label-stepper", width: 600, share: Self.symbolShare,
                        PiRow(label: label, last: true) { PiStepper(name: "Grace", unit: "seconds", value: .constant(30), range: 10...600, step: 10) }) {
            PiKit.Row(label: label, last: true, control: PiKit.Stepper(name: "Grace", unit: "seconds", value: 30, range: 10...600, step: 10))
        }
    }

    /// A sheet's subtitle wraps where SwiftUI's does: the `Spacer()` before
    /// the actions keeps its room.
    func testASheetSubtitleWrapsWhereSwiftUIWrapsIt() async throws {
        let subtitle = "Where requests go: the gateway, its key, and the model each new chat starts with"
        // Ten points narrower than the subtitle's line, beside a badge: it
        // wraps only when the spacer's room is kept.
        let line = PiKit.Line(subtitle, font: PiKit.Font.caption, color: .black).size().width
        let fits = (line + PiSpacing.xl * 2 + 30 + PiSpacing.md * 2 + 8 - 10).rounded()
        for width in [fits, 400] as [CGFloat] {
            try await check("sheet-subtitle-\(Int(width))", share: Self.symbolShare,
                            PiSheet("Connections", subtitle: subtitle, symbol: "network", width: width, height: 160) { Color.clear }) {
                let sheet = PiKit.Sheet("Connections", subtitle: subtitle, symbol: "network", content: NSView())
                sheet.width = width; sheet.height = 160
                return sheet
            }
            try await check("sheet-subtitle-action-\(Int(width))", share: Self.symbolShare,
                            PiSheet("Connections", subtitle: subtitle, width: width + 120, height: 160) { Color.clear } actions: { SwiftUI.Button("Done") {}.buttonStyle(.piPrimary) }) {
                let sheet = PiKit.Sheet("Connections", subtitle: subtitle, content: NSView(), actions: [PiKit.Button("Done", style: .primary)])
                sheet.width = width + 120; sheet.height = 160
                return sheet
            }
        }
    }

    /// A note given a line limit stops there with "…", as `PiNote(…).lineLimit(2)`.
    func testANoteStopsAtItsLineLimit() async throws {
        let text = "The helper restarted after an update; earlier output is kept in the journal, and the chat can be resumed from its last saved turn."
        // Leading in its frame, as a note sits in a form (a frame would centre the narrower SwiftUI note).
        try await check("note-limit", width: 220, share: Self.symbolShare, PiNote(text).lineLimit(2).frame(width: 220, alignment: .leading)) { PiKit.Note(text, lineLimit: 2) }
        try await check("note-limit-one", width: 220, share: Self.symbolShare, PiNote(text, tone: .danger).lineLimit(1).frame(width: 220, alignment: .leading)) { PiKit.Note(text, tone: .danger, lineLimit: 1) }
    }

    /// A disabled row's controls look disabled, as SwiftUI's environment drew them.
    func testADisabledRowsControlsLookDisabled() async throws {
        try await check("row-disabled-controls", width: 240, share: Self.symbolShare,
                        PiSelectableRow(selected: false, action: {}) {
                            HStack { Text("claude").font(PiFont.body).foregroundStyle(Color.piInk); Spacer(); PiIconButton(symbol: "plus", label: "Add", size: 20) {} }
                        }.disabled(true)) {
            let content = RowContent(label: "claude", button: PiKit.IconButton(symbol: "plus", label: "Add", size: 20))
            let row = PiKit.SelectableRow(content: content)
            row.isEnabled = false
            return row
        }
    }

    /// A label cut in the middle keeps what SwiftUI keeps (Core Text kept a
    /// character more or fewer at about half of these widths).
    func testMiddleTruncationKeepsWhatSwiftUIKeeps() async throws {
        let cases: [(String, NSFont, Font, [CGFloat])] = [
            ("A very long connection name that is cut", PiKit.Font.body, PiFont.body, [70, 90, 100, 120, 150, 180]),
            (".agents/skills/release-checklist/agents", PiKit.Font.micro, PiFont.micro, [40, 65, 100, 110, 140, 150, 185]),
        ]
        for (text, font, swiftFont, widths) in cases {
            for width in widths {
                try await check("middle-\(text.prefix(6))-\(Int(width))", width: width,
                                Text(text).font(swiftFont).foregroundStyle(Color.piInk).lineLimit(1).truncationMode(.middle).frame(width: width, alignment: .leading)) {
                    let line = PiKit.TextLine(PiKit.Line(text, font: font, color: .piInk)); line.truncation = .middle
                    return Fixed(line, CGSize(width: width, height: line.intrinsicContentSize.height))
                }
            }
        }
    }

    // MARK: Hover

    /// Under a real pointer. Posting the pointer's events needs the test
    /// runner to be allowed to control the computer (Accessibility); without
    /// it the hover cannot be shown to either twin, and this is skipped.
    func testHoverStates() async throws {
        try XCTSkipUnless(CGPreflightPostEventAccess(), "Posting pointer events needs Accessibility permission for the test runner")
        for (name, style, view) in [("primary", PiKit.Button.Style.primary, AnyView(SwiftUI.Button("Save Changes") {}.buttonStyle(.piPrimary))),
                                    ("secondary", .secondary, AnyView(SwiftUI.Button("Reload") {}.buttonStyle(.piSecondary))),
                                    ("ghost", .ghost, AnyView(SwiftUI.Button("Show more") {}.buttonStyle(.piGhost))),
                                    ("danger", .danger, AnyView(SwiftUI.Button("Delete") {}.buttonStyle(.piDanger)))] {
            let title = ["primary": "Save Changes", "secondary": "Reload", "ghost": "Show more", "danger": "Delete"][name]!
            try await check("button-\(name)-hover", hover: true, view) { PiKit.Button(title, style: style) }
        }
        try await check("icon-hover", hover: true, share: Self.symbolShare, PiIconButton(symbol: "info.circle", label: "Info", size: 22) {}) { PiKit.IconButton(symbol: "info.circle", label: "Info", size: 22) }
        try await check("menubutton-hover", hover: true, share: Self.symbolShare, PiMenuButton(title: "Branches") { PiMenuEntry.button("Other") {} }) {
            PiKit.MenuButton(title: "Branches") { PiMenuEntry.button("Other") {} }
        }
        try await check("row-hover", hover: true, width: 240, PiSelectableRow(selected: false, action: {}) { Text("gpt-5").font(PiFont.body).foregroundStyle(Color.piInk) }) {
            PiKit.SelectableRow(content: PiKit.TextLine(PiKit.Line("gpt-5", font: PiKit.Font.body, color: .piInk)))
        }
    }
}


/// A view at a fixed size, for a parity check of something sized by its container.
private final class Fixed: NSView {
    let size: CGSize
    init(_ view: NSView, _ size: CGSize) { self.size = size; super.init(frame: NSRect(origin: .zero, size: size)); view.frame = bounds; view.autoresizingMask = [.width, .height]; addSubview(view) }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { size }
}

/// A selectable row's content for a parity check: a label and an icon
/// button at its trailing edge, as `HStack { Text; Spacer(); PiIconButton }`.
private final class RowContent: NSView {
    let label: PiKit.TextLine, button: PiKit.IconButton
    init(label: String, button: PiKit.IconButton) {
        self.label = PiKit.TextLine(PiKit.Line(label, font: PiKit.Font.body, color: .piInk)); self.button = button
        super.init(frame: .zero); addSubview(self.label); addSubview(button)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 20) }
    override func layout() {
        super.layout()
        let size = label.intrinsicContentSize
        label.frame = CGRect(x: 0, y: PiKit.round((bounds.height - size.height) / 2, 2), width: size.width, height: size.height)
        button.frame = CGRect(x: bounds.width - 20, y: PiKit.round((bounds.height - 20) / 2, 2), width: 20, height: 20)
    }
}
