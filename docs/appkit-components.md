# AppKit Pi components

The AppKit twins of the SwiftUI Pi components, for moving a screen off SwiftUI
(0.1.120: no SwiftUI). They live in `apps/macos/PiApp/DesignKit/`, import
AppKit only, and are named `PiKit.X` so they never collide with the SwiftUI
ones they replace. Each looks the same as its SwiftUI twin pixel for pixel,
light and dark (`PiKitParityTests`), behaves the same, and tells VoiceOver at
least what the SwiftUI one did after A1 (`PiKitControlTests`).

## How they work

- **State.** A plain property sets the state from outside and calls nothing
  back; a reader's action calls the closure once (`onChange`, `onSelect`,
  `onPress`). Port a `Binding` as: set the property when the model changes,
  write the model in the closure.
- **Size.** Every component reports `intrinsicContentSize` (a flexible one
  `noIntrinsicMetric` on that axis). Views whose height depends on their
  width conform to `PiKit.WidthSizing`; `PiKit.height(of:width:)` asks either.
  Lay out with frames in `layout()` or with Auto Layout; both work.
- **Drawing.** Text is `PiKit.Line` / `PiKit.TextLine` (one line) or
  `PiKit.WrappedText`; symbols are `PiKit.Symbol` / `PiKit.SymbolView`. Both
  measure and place exactly as SwiftUI's `Text` and `Image(systemName:)` do.
  Colors are the `NSColor.pi*` tokens (`PiKitTokens.swift`), which SwiftUI's
  `Color.pi*` now read too.
- **Motion.** `PiKit.Motion` holds the durations, curves and springs of
  `PiMotion`, and `Motion.reducedOverride` stills them in a fixture.
  `PiKit.reveal`, `PiKit.appear` and `PiKit.arrive` replace `piChartReveal`,
  `piStaggered` and `PiMotion.arrival`. There is no `piStableLayout`: AppKit
  does not animate layout unless asked.
- **Pointer.** Clickable components show the pointing hand while enabled
  (`ButtonBase.showsPointer`), as `piPointer()` did.

## Components, with an example each

```swift
// Buttons: .piPrimary / .piSecondary / .piGhost / .piGhostDanger / .piDanger, compact forms
let save = PiKit.Button("Save All", style: .primary) { model.save() }
save.keyEquivalent = "\r"                       // .keyboardShortcut(.defaultAction)
let previous = PiKit.Button("Previous", symbol: "chevron.left", style: .secondary, compact: true) { … }

// Icon button (PiIconButton)
let remove = PiKit.IconButton(symbol: "xmark", label: "Remove", spokenLabel: "Remove follow-up 2") { … }

// Switch and checkbox (.piSwitch / .piCheckbox toggle styles)
let toggle = PiKit.Switch(isOn: prefs.autoUpdate, label: "Check automatically") { prefs.autoUpdate = $0 }
let tick = PiKit.Checkbox(isOn: true, label: "Include untracked") { … }

// Progress bar and spinner (PiProgressBar, PiSpinner)
let bar = PiKit.ProgressBar(value: done, total: all)
let spinner = PiKit.spinner(controlSize: .small)

// Tabs (PiTabs)
let scope = PiKit.Tabs(selection: Scope.checked, items: [(.checked, "Checked"), (.staged, "Staged")],
                       accessibilityName: "Commit scope") { model.scope = $0 }

// Stepper (PiStepper / PiStepper64): Int64 covers both
let grace = PiKit.Stepper(name: "Idle helper grace", unit: "seconds", value: 30, range: 10...600, step: 10) { … }

// Fields (PiTextField, PiNumberField, PiDateField)
let search = PiKit.TextField(placeholder: "Search", icon: "magnifyingglass", onChange: { model.query = $0 })
let from = PiKit.NumberField(placeholder: "From", value: 1, width: 110) { model.first = $0 }
let date = PiKit.dateField(Date())

// Dropdown and choice list (PiDropdown, PiChoicePicker / PiChoiceList)
let method = PiKit.Dropdown(selection: "PUT", items: [("POST", "POST"), ("PUT", "PUT")], compact: true,
                            accessibilityName: "Webhook method") { model.method = $0 }
let list = PiKit.ChoiceList(title: "Model", selection: current, choices: models.map { PiKit.Choice(id: $0.id, title: $0.name) },
                            choose: { … }, cancel: { … })     // show with PiKit.popover(list)

// Menus (PiMenuButton, PiMenuControl, PiMenuContent): entries are PiMenuEntry, built on the press
let branches = PiKit.MenuButton(title: "main", icon: "arrow.triangle.branch") { PiMenuEntry.button("Switch…") { … } }
let custom = PiKit.MenuControl(label: "Chat actions", face: myFaceView, onHover: { myFaceView.lit = $0 }) { … }
// A right-click menu: view.menu = PiMenus.menu(entries) in menu(for:).

// Selectable rows (PiSelectableRow): one SelectionGlide per list makes the highlight glide
let glide = PiKit.SelectionGlide()
let row = PiKit.SelectableRow(content: rowContent, selected: true, glide: glide, action: { … }, doubleClick: { … })

// Settings (PiSettingsGroup, PiRow)
let group = PiKit.SettingsGroup(title: "Updates", footer: "Checks once a day.", rows: [
    PiKit.Row(label: "Check automatically", detail: "Daily", control: toggle),
    PiKit.Row(label: "Idle helper grace", control: grace),
])

// Resize handle (PiResizeHandle): frame it hitThickness across, centred on the boundary
let handle = PiKit.ResizeHandle(orientation: .vertical, label: "Sidebar width", changed: { … }, ended: { … })

// Pager (PiPager) and flow (PiFlow)
let pager = PiKit.Pager(center: PiKit.TextLine(PiKit.Line("Page 2 of 5", font: PiKit.Font.caption, color: .piInkSecondary)),
                        canPrevious: false, canNext: true, previous: { … }, next: { … })
let flow = PiKit.FlowView(); [chipA, chipB].forEach(flow.addSubview)   // fillsRow / narrowest for PiFlowFillsRow

// Sheet chrome (PiSheet)
let sheet = PiKit.Sheet("Connections", subtitle: "Where requests go", symbol: "network", content: body,
                        actions: [save], footer: footerView)
sheet.onCancel = { model.askAboutUnsavedEdits() }     // or sheet.dismiss = { … }

// Badges and chips (PiBadge, PiIconBadge, PiChip)
let badge = PiKit.Badge(text: "Running", tone: .success, dot: true)
let header = PiKit.IconBadge(symbol: "bolt.fill", size: 30, filled: true)
let chip = PiKit.Chip(text: "README.md", icon: "doc.text", remove: { … })

// Surfaces (PiCard, .piInset, .piElevated) and text (PiSectionHeader, PiNote, PiStatusLine, PiKeyValue, PiStatTile)
let card = PiKit.card(content)                 // padding:, sunken:
let inset = PiKit.inset(list)
let raised = PiKit.elevated(panel)
let heading = PiKit.SectionHeader("Connections", subtitle: "Where requests go", accessory: addButton)
let note = PiKit.Note("Could not save.", tone: .danger)      // PiStatusLine: hide it when the text is empty
let row2 = PiKit.KeyValue(key: "Model", value: "claude-opus-5-5")
let tile = PiKit.statTile(title: "Requests", value: "1,284", caption: "Last 7 days", symbol: "arrow.up.arrow.down")

// Gauges and chart parts (UsageShareBar, PiRing, ContextRing, PiFigure, PiChartHeader, PiSegmentedBar, PiLegendRow)
let share = PiKit.ShareBar(fraction: 0.35)
let ring = PiKit.Ring(fraction: 0.62, size: 14); let context = PiKit.Ring.context(0.86, size: 14)
let figure = PiKit.Figure(value: "$12.40", title: "Spend", caption: "3/5 requests reported", partial: true)
let chartHeader = PiKit.ChartHeader("Tokens per turn", subtitle: "Last 40 turns")
let stacked = PiKit.SegmentedBar(segments: [PiKit.BarSegment(id: "a", fraction: 0.6)]) { _ in .piAccent }
let legend = PiKit.LegendRow(color: .piAccent, title: "Output", value: "12,400", share: "41%", detail: "reasoning 3,100")
PiKit.reveal(chartView, horizontal: true)

// Stat pills (PiStatPillFace, PiStatPopoverPill): update reading and scope together, so a chat switch never rolls
let pill = PiKit.StatPill(symbol: "chart.pie", label: "7.3K tok", scope: chatID)
pill.update(label: "7.4K tok", scope: chatID)
let usage = PiKit.StatPopoverPill(symbol: "chart.pie", label: "7.3K tok", presenter: presenter) { UsagePanel() }

// Working indicators (PiShimmerText, PiBackToBottomPill)
let working = PiKit.ShimmerText("Generating response…")
let jump = PiKit.BackToBottomPill { transcript.scrollToBottom() }

// Popovers and hover cards with AppKit content
presenter.toggle(from: anchor, width: 468, maximumHeight: 600, animates: true) { panelView }
hoverCards.hover(true, over: anchor, width: 280) { cardView }
```

`PiQuestion`, `PiMenus` / `PiMenuEntry`, `PiPopoverPresenter`, `PiHoverCardPresenter`,
`PiSpinnerView`, `PiTextWidth` and `MetricFormat` were already AppKit (or plain
Swift) and stay as they are.

## What is not identical

- **Symbol edges.** Symbols are placed and sized exactly as SwiftUI places
  them, but AppKit rasterizes their edges differently: a few pixels along a
  glyph's outline differ in antialiasing. The parity tests allow that much for
  symbols (`PiKitParityTests.symbolShare`) and nothing for anything else.
- **Middle truncation.** A label cut in the middle (`Dropdown`, `MenuButton`
  with `maxLabelWidth`) keeps one character more or fewer than SwiftUI at
  some widths: Core Text's truncation, not SwiftUI's.
- **Rolling digits.** A stat pill's reading rolls as a whole, not digit by
  digit as SwiftUI's numeric text transition did; the scope rule (no roll
  across chats) is the same.
- **How close the pictures are.** `PiKitParityTests` allows no pixel more
  than 8 channels apart, except symbols (3 per cent of a capture) and three
  path shapes (0.6 per cent: a badge's dot, a stacked bar's ends, a legend
  swatch). Those allowances cover the whole capture: they are not masked to
  the symbol or shape, so the test cannot prove a difference lies only there.
- **Hover, press and focus** are not compared with the SwiftUI twins in this
  environment: posting real pointer events needs Accessibility permission for
  the test runner, so `testHoverStates` skips here. Each style's hover fill,
  and keyboard and accessibility behaviour, are checked in `PiKitControlTests`.
- **A disabled selectable row** dims its content and takes all its clicks, but
  leaves each control inside it with its own enabled state (SwiftUI disabled
  them through the environment): to VoiceOver they still read as enabled.
- **Native popover growth.** A popover with AppKit content grows when a Pi
  component inside it changes size (`PiKit.sizeChanged`); other views must call
  that themselves.
